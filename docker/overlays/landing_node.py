import math
import os
import threading
import time
from datetime import datetime
from enum import IntEnum

import cv2
import cv2.aruco as aruco
import cv_bridge
import numpy as np
import rclpy
from rclpy.time import Time
from geometry_msgs.msg import PoseStamped
from mavros_msgs.msg import State
from mavros_msgs.srv import CommandBool, CommandTOL, SetMode
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CameraInfo
from sensor_msgs.msg import Image
from tf2_ros import Buffer, TransformException, TransformListener


class MissionState(IntEnum):
    WAITING_FOR_CONNECTION = 0
    SETTING_MODE = 1
    ARMING = 2
    TAKING_OFF = 3
    SEARCHING = 4
    CENTERING = 5
    LANDING = 6
    MISSION_COMPLETE = 7


class ArucoLandingNode(Node):
    def __init__(self):
        super().__init__("aruco_landing_node")

        self.declare_parameter("operation_mode", "practice")
        self.operation_mode = str(self.get_parameter("operation_mode").value)
        if self.operation_mode not in ("practice", "bench", "flight"):
            raise ValueError(f"Unsupported operation_mode: {self.operation_mode}")
        self.get_logger().warn(f"OPERATION MODE: {self.operation_mode.upper()}")

        self.declare_parameter("landing_marker_id", 102)
        self.landing_marker_id = int(self.get_parameter("landing_marker_id").value)
        self.declare_parameter("marker_length", 0.15)
        self.marker_length = float(self.get_parameter("marker_length").value)
        self.declare_parameter("detection_only", False)
        self.detection_only = bool(self.get_parameter("detection_only").value)
        self.declare_parameter("search_height", 2.0)
        self.search_height = float(self.get_parameter("search_height").value)
        self.declare_parameter("centering_tolerance", 0.15)
        self.centering_tolerance = float(
            self.get_parameter("centering_tolerance").value
        )
        self.declare_parameter("center_confirm_frames", 5)
        self.center_confirm_frames = int(
            self.get_parameter("center_confirm_frames").value
        )
        self.declare_parameter("marker_lost_timeout", 1.0)
        self.marker_lost_timeout = float(
            self.get_parameter("marker_lost_timeout").value
        )
        self.centered_frames = 0
        self.last_marker_seen_time = 0.0
        self.declare_parameter("geofence_radius", 3.0)
        self.geofence_radius = float(self.get_parameter("geofence_radius").value)
        self.geofence_breached = False
        self.guided_engaged_once = False
        self.manual_override_latched = False
        self.declare_parameter("probe_grid_size", 1.0)
        self.probe_grid_size = float(self.get_parameter("probe_grid_size").value)
        self.declare_parameter("probe_nose_points_positive_y", True)
        self.probe_nose_points_positive_y = bool(
            self.get_parameter("probe_nose_points_positive_y").value
        )
        self.declare_parameter("enable_probe_practice", True)
        self.enable_probe_practice = bool(
            self.get_parameter("enable_probe_practice").value
        )
        self.declare_parameter("practice_base_height", 2.0)
        self.practice_base_height = float(
            self.get_parameter("practice_base_height").value
        )

        self.mission_state = MissionState.WAITING_FOR_CONNECTION
        self.led_state_file = "/runtime/status-led.state"
        self.current_state = None
        self.current_pose = None
        self.takeoff_position = None
        self.last_action_time = 0.0
        self.last_wait_log_time = 0.0
        self.last_center_command_time = 0.0
        self.declare_parameter("centering_command_rate", 5.0)
        self.declare_parameter("centering_max_step", 0.04)
        self.declare_parameter("centering_min_step", 0.005)
        self.declare_parameter("centering_slow_radius", 0.75)
        self.centering_command_rate = float(
            self.get_parameter("centering_command_rate").value
        )
        self.centering_max_step = float(
            self.get_parameter("centering_max_step").value
        )
        self.centering_min_step = float(
            self.get_parameter("centering_min_step").value
        )
        self.centering_slow_radius = float(
            self.get_parameter("centering_slow_radius").value
        )

        # Practice has no MAVROS. Supply a fixed, level pose solely for safe
        # camera/probe geometry tests; control_loop is disabled in practice.
        if self.operation_mode == "practice" and self.enable_probe_practice:
            self.current_pose = PoseStamped()
            self.current_pose.header.frame_id = "map"
            self.current_pose.pose.position.z = self.practice_base_height
            self.current_pose.pose.orientation.w = 1.0
            self.takeoff_position = PoseStamped()
            self.takeoff_position.header.frame_id = "map"
            self.takeoff_position.pose.orientation.w = 1.0

        self.search_radius = 0.5
        self.declare_parameter("max_search_radius", 2.5)
        requested_search_radius = float(
            self.get_parameter("max_search_radius").value
        )
        # Keep a margin inside the independent geofence so the nominal search
        # pattern cannot itself trigger the breach response.
        self.max_search_radius = min(
            requested_search_radius, max(0.5, self.geofence_radius - 0.5)
        )
        self.search_angle = 0.0
        self.search_radius_step = 0.5
        self.declare_parameter("search_angle_step_deg", 0.36)
        self.search_angle_step = math.radians(
            float(self.get_parameter("search_angle_step_deg").value)
        )

        mavros_qos = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            durability=DurabilityPolicy.VOLATILE,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )
        self.state_sub = self.create_subscription(
            State, "/mavros/state", self.state_callback, mavros_qos
        )
        self.pose_sub = self.create_subscription(
            PoseStamped, "/mavros/local_position/pose", self.pose_callback, mavros_qos
        )
        self.declare_parameter("image_topic", "/camera/image")
        self.declare_parameter("camera_info_topic", "/camera/camera_info")
        self.image_topic = self.get_parameter("image_topic").value
        self.camera_info_topic = self.get_parameter("camera_info_topic").value
        self.image_sub = self.create_subscription(
            Image, self.image_topic, self.image_callback, mavros_qos
        )
        self.camera_info_sub = self.create_subscription(
            CameraInfo, self.camera_info_topic, self.camera_info_callback, mavros_qos
        )
        self.setpoint_pub = self.create_publisher(
            PoseStamped, "/mavros/setpoint_position/local", mavros_qos
        )
        self.arming_client = self.create_client(CommandBool, "/mavros/cmd/arming")
        self.set_mode_client = self.create_client(SetMode, "/mavros/set_mode")
        self.takeoff_client = self.create_client(CommandTOL, "/mavros/cmd/takeoff")

        self.bridge = cv_bridge.CvBridge()
        self.aruco_dict = aruco.getPredefinedDictionary(cv2.aruco.DICT_ARUCO_ORIGINAL)
        self.aruco_params = aruco.DetectorParameters_create()
        self.camera_matrix = np.array(
            [[205.46, 0.0, 320], [0.0, 205.46, 240], [0.0, 0.0, 1.0]]
        )
        self.dist_coeffs = np.zeros(5, dtype=np.float32)
        self.camera_info_received = False
        self.declare_parameter(
            "camera_frame", "usb_camera_color_optical_frame"
        )
        self.camera_frame = str(self.get_parameter("camera_frame").value)
        self.tf_buffer = Buffer()
        self.tf_listener = TransformListener(self.tf_buffer, self)
        self.last_tf_warning_time = 0.0

        # ERC probe is specified as yellow-green.  Keep these thresholds
        # configurable because sunlight and camera white balance change HSV.
        self.declare_parameter("probe_hue_min", 25)
        self.declare_parameter("probe_hue_max", 45)
        self.declare_parameter("probe_saturation_min", 100)
        self.declare_parameter("probe_value_min", 100)
        self.probe_hsv_lower = np.array(
            [
                int(self.get_parameter("probe_hue_min").value),
                int(self.get_parameter("probe_saturation_min").value),
                int(self.get_parameter("probe_value_min").value),
            ],
            dtype=np.uint8,
        )
        self.probe_hsv_upper = np.array(
            [int(self.get_parameter("probe_hue_max").value), 255, 255],
            dtype=np.uint8,
        )
        # These are configured as whole pixel counts in the env files. Declare
        # them as integers so ROS 2 parameter override typing stays consistent,
        # then convert to float for OpenCV comparisons below.
        self.declare_parameter("probe_min_area", 500)
        self.declare_parameter("probe_max_area", 60000)
        self.declare_parameter("probe_min_solidity", 0.80)
        self.declare_parameter("probe_min_aspect", 3.5)
        self.declare_parameter("probe_max_aspect", 10.0)
        self.declare_parameter("probe_min_rect_fill", 0.60)
        self.declare_parameter("probe_length", 0.20)
        self.declare_parameter("probe_min_diameter", 0.02)
        self.declare_parameter("probe_max_diameter", 0.03)
        self.declare_parameter("probe_size_tolerance", 0.55)
        self.declare_parameter("probe_confirm_frames", 3)
        self.declare_parameter("probe_confirm_radius", 0.25)
        self.min_object_area = float(self.get_parameter("probe_min_area").value)
        self.max_object_area = float(self.get_parameter("probe_max_area").value)
        self.probe_min_solidity = float(
            self.get_parameter("probe_min_solidity").value
        )
        self.probe_min_aspect = float(self.get_parameter("probe_min_aspect").value)
        self.probe_max_aspect = float(self.get_parameter("probe_max_aspect").value)
        self.probe_min_rect_fill = float(
            self.get_parameter("probe_min_rect_fill").value
        )
        self.probe_length = float(self.get_parameter("probe_length").value)
        self.probe_min_diameter = float(
            self.get_parameter("probe_min_diameter").value
        )
        self.probe_max_diameter = float(
            self.get_parameter("probe_max_diameter").value
        )
        self.probe_size_tolerance = float(
            self.get_parameter("probe_size_tolerance").value
        )
        self.probe_confirm_frames = int(
            self.get_parameter("probe_confirm_frames").value
        )
        self.probe_confirm_radius = float(
            self.get_parameter("probe_confirm_radius").value
        )
        self.probe_candidates = []

        self.max_objects_to_detect = 3
        self.min_distance_between_objects = 0.5
        self.detected_objects_positions = []

        self.object_log_filename = "/runtime/probe_results.txt"

        self.get_logger().info(f"Log file for this run: '{self.object_log_filename}'")

        self.detected_objects_positions = []
        self.detected_objects_camera_coords = []

        self.control_timer = self.create_timer(0.1, self.control_loop)
        self.get_logger().info(
            "Aruco Landing Node started. Waiting for MAVROS connection..."
        )

    def state_callback(self, msg):
        self.current_state = msg

    def pose_callback(self, msg):
        self.current_pose = msg

    def image_callback(self, msg):
        # camera_info YAML may have an empty frame_id. The image header is
        # authoritative and matches the static camera transform.
        if msg.header.frame_id:
            self.camera_frame = msg.header.frame_id
        if self.manual_override_latched:
            return
        try:
            frame = self.bridge.imgmsg_to_cv2(msg, "bgr8")
        except cv_bridge.CvBridgeError as e:
            self.get_logger().error(f"CV Bridge Error: {e}")
            return

        # Practice and bench modes never publish setpoints or call flight
        # services. They only exercise the real camera and marker detector.
        if self.operation_mode in ("practice", "bench"):
            tvec, detected_id = self.detect_aruco(frame)
            if detected_id == self.landing_marker_id:
                if tvec is None:
                    self.get_logger().info(
                        f"SAFE {self.operation_mode}: marker ID {detected_id} detected "
                        "(uncalibrated; distance unavailable)"
                    )
                else:
                    self.get_logger().info(
                        f"SAFE {self.operation_mode}: marker offset "
                        f"x={tvec[0]:+.3f}, y={tvec[1]:+.3f}, z={tvec[2]:+.3f}"
                    )
                    self.log_marker_axis_diagnostic(tvec)
            if (
                self.operation_mode == "practice"
                and self.enable_probe_practice
                and len(self.detected_objects_positions) < self.max_objects_to_detect
            ):
                self.detect_and_manage_objects(frame)
            return

        if self.current_pose is None or self.takeoff_position is None:
            return

        if self.mission_state in [MissionState.SEARCHING, MissionState.CENTERING]:
            tvec, detected_id = self.detect_aruco(frame)
            if detected_id == self.landing_marker_id and tvec is not None:
                self.last_marker_seen_time = time.monotonic()
                if self.mission_state == MissionState.SEARCHING:
                    self.get_logger().info(
                        f"Landing marker {self.landing_marker_id} found! Switching to CENTERING mode."
                    )
                    self.mission_state = MissionState.CENTERING
                self.center_over_marker(tvec)
            elif (
                self.mission_state == MissionState.CENTERING
                and time.monotonic() - self.last_marker_seen_time
                > self.marker_lost_timeout
            ):
                self.get_logger().warn(
                    "Landing marker lost; returning to SEARCHING."
                )
                self.centered_frames = 0
                self.mission_state = MissionState.SEARCHING

        if (
            self.mission_state >= MissionState.SEARCHING
            and len(self.detected_objects_positions) < self.max_objects_to_detect
        ):
            self.detect_and_manage_objects(frame)

    def camera_info_callback(self, msg):
        if self.camera_info_received:
            return

        self.camera_matrix = np.array(msg.k, dtype=np.float64).reshape(3, 3)

        if len(msg.d) >= 5:
            self.dist_coeffs = np.array(msg.d[:5], dtype=np.float32)
        else:
            self.dist_coeffs = np.zeros(5, dtype=np.float32)

        self.camera_info_received = True
        if msg.header.frame_id:
            self.camera_frame = msg.header.frame_id
        self.get_logger().info(
            f"Camera intrinsics loaded from {self.camera_info_topic}."
        )

    def log_marker_axis_diagnostic(self, tvec):
        """Log camera/body/map marker coordinates without sending commands."""
        try:
            camera_in_body = self.tf_buffer.lookup_transform(
                "base_link", self.camera_frame, Time()
            )
        except TransformException as exc:
            self.get_logger().warn(
                f"AXIS TEST: camera->body TF unavailable: {exc}",
                throttle_duration_sec=2.0,
            )
            return

        camera_offset_body = np.array(
            [
                camera_in_body.transform.translation.x,
                camera_in_body.transform.translation.y,
                camera_in_body.transform.translation.z,
            ],
            dtype=np.float64,
        )
        marker_body = camera_offset_body + self.rotate_vector_by_quaternion(
            np.asarray(tvec, dtype=np.float64),
            camera_in_body.transform.rotation,
        )
        message = (
            "AXIS TEST: "
            f"camera=({tvec[0]:+.3f},{tvec[1]:+.3f},{tvec[2]:+.3f}) m; "
            f"body=({marker_body[0]:+.3f},{marker_body[1]:+.3f},"
            f"{marker_body[2]:+.3f}) m "
            "[body +X=forward, +Y=left, +Z=up]"
        )
        if self.current_pose is not None and self.operation_mode == "bench":
            marker_world_delta = self.rotate_vector_by_quaternion(
                marker_body, self.current_pose.pose.orientation
            )
            marker_map = (
                self.current_pose.pose.position.x + marker_world_delta[0],
                self.current_pose.pose.position.y + marker_world_delta[1],
                self.current_pose.pose.position.z + marker_world_delta[2],
            )
            message += (
                f"; map=({marker_map[0]:+.3f},{marker_map[1]:+.3f},"
                f"{marker_map[2]:+.3f}) m"
            )
        self.get_logger().info(message, throttle_duration_sec=1.0)

    def control_loop(self):
        if self.operation_mode != "flight":
            return

        now = time.monotonic()

        if not self.current_state:
            if now - self.last_wait_log_time >= 5.0:
                self.get_logger().info("Waiting for /mavros/state...")
                self.last_wait_log_time = now
            return

        # Pilot/FC mode changes have priority over every companion-computer
        # command. Once GUIDED has actually engaged, leaving it is a permanent
        # manual-override latch until this node is restarted. LAND is allowed
        # only when this node already requested a landing.
        if self.should_latch_manual_override():
            self.manual_override_latched = True
            self.mission_state = MissionState.MISSION_COMPLETE
            self.get_logger().error(
                f"MANUAL OVERRIDE LATCHED: FC mode is {self.current_state.mode}. "
                "All companion flight commands are disabled until restart."
            )
            self.set_status_led("red", "fast")
        if self.manual_override_latched:
            return

        # Independent horizontal geofence. Stop all mission setpoints and
        # keep requesting LAND until the FC reports that LAND is active.
        if self.takeoff_position is not None and self.current_pose is not None:
            dx = (
                self.current_pose.pose.position.x
                - self.takeoff_position.pose.position.x
            )
            dy = (
                self.current_pose.pose.position.y
                - self.takeoff_position.pose.position.y
            )
            distance_from_takeoff = math.hypot(dx, dy)
            if distance_from_takeoff > self.geofence_radius:
                if not self.geofence_breached:
                    self.get_logger().error(
                        f"GEOFENCE BREACH: {distance_from_takeoff:.2f} m > "
                        f"{self.geofence_radius:.2f} m; requesting LAND"
                    )
                self.geofence_breached = True
                self.mission_state = MissionState.LANDING
                self.set_status_led("red", "fast")
                if (
                    self.current_state.mode != "LAND"
                    and now - self.last_action_time >= 1.0
                ):
                    self.set_mode_client.call_async(
                        SetMode.Request(custom_mode="LAND")
                    )
                    self.last_action_time = now
                return

        if self.mission_state == MissionState.WAITING_FOR_CONNECTION:
            if self.current_state.connected:
                self.get_logger().info("MAVROS Connected. Proceeding to set mode.")
                self.mission_state = MissionState.SETTING_MODE

        elif self.mission_state == MissionState.SETTING_MODE:
            if self.current_state.mode == "GUIDED":
                self.guided_engaged_once = True
                self.get_logger().info("Mode is now GUIDED. Proceeding to arm.")
                self.mission_state = MissionState.ARMING
                self.set_status_led("green", "slow")
                self.last_action_time = 0.0
            elif now - self.last_action_time >= 2.0:
                self.get_logger().info("Requesting GUIDED mode...")
                future = self.set_mode_client.call_async(
                    SetMode.Request(custom_mode="GUIDED")
                )
                future.add_done_callback(self.mode_response_callback)
                self.last_action_time = now

        elif self.mission_state == MissionState.ARMING:
            if self.current_state.armed:
                self.get_logger().info("Vehicle is armed. Proceeding to takeoff.")
                self.mission_state = MissionState.TAKING_OFF
                self.takeoff_position = self.current_pose
                self.last_action_time = 0.0
            elif now - self.last_action_time >= 2.0:
                self.get_logger().info("Requesting vehicle arm...")
                future = self.arming_client.call_async(
                    CommandBool.Request(value=True)
                )
                future.add_done_callback(self.arm_response_callback)
                self.last_action_time = now

        elif self.mission_state == MissionState.TAKING_OFF:
            if self.takeoff_position is None and self.current_pose is not None:
                self.takeoff_position = self.current_pose
            below_target = (
                self.current_pose is None
                or self.current_pose.pose.position.z < self.search_height - 0.3
            )
            if now - self.last_action_time >= 2.0 and below_target:
                self.get_logger().info(
                    f"Requesting takeoff to {self.search_height:.1f} m..."
                )
                future = self.takeoff_client.call_async(
                    CommandTOL.Request(
                        altitude=self.search_height,
                        latitude=float("nan"),
                        longitude=float("nan"),
                    )
                )
                future.add_done_callback(self.takeoff_response_callback)
                self.last_action_time = now
            if self.current_pose is None:
                if now - self.last_wait_log_time >= 5.0:
                    self.get_logger().warn(
                        "Takeoff requested; waiting for /mavros/local_position/pose..."
                    )
                    self.last_wait_log_time = now
            elif abs(self.current_pose.pose.position.z - self.search_height) < 0.3:
                self.get_logger().info("Takeoff complete. Switching to SEARCHING mode.")
                self.mission_state = MissionState.SEARCHING

        elif self.mission_state == MissionState.SEARCHING:
            self.execute_search_pattern()

        elif self.mission_state == MissionState.LANDING:
            if not self.current_state.armed:
                self.get_logger().info("Vehicle disarmed. Landing mission complete.")
                self.mission_state = MissionState.MISSION_COMPLETE
            elif (
                self.current_state.mode != "LAND"
                and now - self.last_action_time >= 1.0
            ):
                self.get_logger().warn("LAND not active; requesting LAND again.")
                self.set_mode_client.call_async(SetMode.Request(custom_mode="LAND"))
                self.last_action_time = now

    def should_latch_manual_override(self):
        if not self.guided_engaged_once or self.current_state is None:
            return False
        if self.current_state.mode == "GUIDED":
            return False
        if (
            self.mission_state == MissionState.LANDING
            and self.current_state.mode == "LAND"
        ):
            return False
        return True

    def set_status_led(self, colour, pattern="solid"):
        try:
            temporary = f"{self.led_state_file}.tmp"
            with open(temporary, "w", encoding="ascii") as state_file:
                state_file.write(f"{colour} {pattern}\n")
            os.replace(temporary, self.led_state_file)
        except OSError as exc:
            self.get_logger().warning(f"Unable to update status LED: {exc}")

    def mode_response_callback(self, future):
        try:
            if not future.result().mode_sent:
                self.get_logger().warn("GUIDED mode request was rejected; retrying.")
        except Exception as exc:
            self.get_logger().error(f"GUIDED mode request failed: {exc}")

    def arm_response_callback(self, future):
        try:
            if not future.result().success:
                self.get_logger().warn("Arm request was rejected; check PreArm messages.")
        except Exception as exc:
            self.get_logger().error(f"Arm request failed: {exc}")

    def takeoff_response_callback(self, future):
        try:
            if not future.result().success:
                self.get_logger().warn("Takeoff request was rejected; retrying.")
        except Exception as exc:
            self.get_logger().error(f"Takeoff request failed: {exc}")

    def detect_aruco(self, frame):
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        corners, ids, _ = aruco.detectMarkers(
            gray, self.aruco_dict, parameters=self.aruco_params
        )

        if ids is not None:
            self.get_logger().info(
                f"Found ArUco markers with IDs: {ids.flatten()}",
                throttle_duration_sec=1.0,
            )
            for i, marker_id in enumerate(ids):
                if marker_id[0] == self.landing_marker_id:
                    if self.detection_only:
                        return None, ids[i][0]
                    self.get_logger().info(
                        f">>> Target marker {self.landing_marker_id} FOUND! <<<"
                    )
                    rvecs, tvecs, _ = aruco.estimatePoseSingleMarkers(
                        [corners[i]],
                        self.marker_length,
                        self.camera_matrix,
                        self.dist_coeffs,
                    )
                    tvec = tvecs[0][0]
                    self.get_logger().info(
                        f"    - Position from camera (tvec): x={tvec[0]:.3f}, y={tvec[1]:.3f}, z={tvec[2]:.3f}"
                    )
                    return tvec, ids[i][0]

        return None, -1

    def center_over_marker(self, tvec):
        try:
            camera_in_body = self.tf_buffer.lookup_transform(
                "base_link", self.camera_frame, Time()
            )
        except TransformException as exc:
            self.get_logger().warn(
                f"Cannot center without camera TF: {exc}",
                throttle_duration_sec=2.0,
            )
            self.centered_frames = 0
            return

        # ArUco tvec uses optical axes (+x image-right, +y image-down,
        # +z forward). Convert it through the calibrated camera mount and the
        # live vehicle attitude before creating a local-map setpoint.
        marker_from_camera_body = self.rotate_vector_by_quaternion(
            np.asarray(tvec, dtype=np.float64),
            camera_in_body.transform.rotation,
        )
        camera_offset_body = np.array(
            [
                camera_in_body.transform.translation.x,
                camera_in_body.transform.translation.y,
                camera_in_body.transform.translation.z,
            ],
            dtype=np.float64,
        )
        # tvec starts at the optical centre. Add the camera's translation so
        # the error starts at base_link/FC centre; otherwise the camera, not
        # the aircraft centre, would be placed over the landing marker.
        marker_body = camera_offset_body + marker_from_camera_body
        marker_world = self.rotate_vector_by_quaternion(
            marker_body, self.current_pose.pose.orientation
        )
        horizontal_error = math.hypot(marker_body[0], marker_body[1])

        if horizontal_error < self.centering_tolerance:
            self.centered_frames += 1
            self.get_logger().info(
                f"Marker centered {self.centered_frames}/{self.center_confirm_frames}",
                throttle_duration_sec=0.5,
            )
            if self.centered_frames >= self.center_confirm_frames:
                self.get_logger().info("Marker confirmed centered. Requesting LAND mode.")
                self.mission_state = MissionState.LANDING
                self.set_status_led("yellow", "slow")
                self.set_mode_client.call_async(SetMode.Request(custom_mode="LAND"))
                self.last_action_time = time.monotonic()
            return

        self.centered_frames = 0
        now = time.monotonic()
        command_period = 1.0 / max(self.centering_command_rate, 0.1)
        if now - self.last_center_command_time < command_period:
            return
        self.last_center_command_time = now

        # Move the local target only a few centimetres per command. Inside the
        # slow radius, reduce the step linearly as the marker approaches the
        # acceptance radius, avoiding the aggressive full-offset jump.
        slowing_span = max(
            self.centering_slow_radius - self.centering_tolerance, 1e-3
        )
        approach_fraction = min(
            1.0,
            max(0.0, horizontal_error - self.centering_tolerance) / slowing_span,
        )
        step = max(
            self.centering_min_step,
            self.centering_max_step * approach_fraction,
        )
        step = min(step, horizontal_error)
        world_scale = step / horizontal_error
        self.get_logger().info(
            f"Centering... body error=({marker_body[0]:+.2f}, "
            f"{marker_body[1]:+.2f}) m, step={step:.3f} m",
            throttle_duration_sec=1.0,
        )
        target_pose = PoseStamped()
        target_pose.header.stamp = self.get_clock().now().to_msg()
        target_pose.header.frame_id = "map"
        target_pose.pose.position.x = (
            self.current_pose.pose.position.x + marker_world[0] * world_scale
        )
        target_pose.pose.position.y = (
            self.current_pose.pose.position.y + marker_world[1] * world_scale
        )
        target_pose.pose.position.z = self.search_height
        target_pose.pose.orientation = self.current_pose.pose.orientation
        self.setpoint_pub.publish(target_pose)

    def execute_search_pattern(self):
        if not self.takeoff_position:
            return
        x = self.takeoff_position.pose.position.x + self.search_radius * math.cos(
            self.search_angle
        )
        y = self.takeoff_position.pose.position.y + self.search_radius * math.sin(
            self.search_angle
        )
        target_pose = PoseStamped()
        target_pose.header.stamp = self.get_clock().now().to_msg()
        target_pose.header.frame_id = "map"
        target_pose.pose.position.x = x
        target_pose.pose.position.y = y
        target_pose.pose.position.z = self.search_height
        target_pose.pose.orientation = self.current_pose.pose.orientation
        self.setpoint_pub.publish(target_pose)
        self.search_angle += self.search_angle_step
        if self.search_angle >= 2 * math.pi:
            self.search_angle = 0.0
            self.search_radius += self.search_radius_step
            self.get_logger().info(
                f"Increasing search radius to {self.search_radius:.2f}m"
            )
            if self.search_radius > self.max_search_radius:
                self.get_logger().warn(
                    "Max search radius reached. Landing as failsafe."
                )
                self.mission_state = MissionState.LANDING
                self.set_mode_client.call_async(SetMode.Request(custom_mode="LAND"))

    def detect_and_manage_objects(self, frame):
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        mask = cv2.inRange(hsv, self.probe_hsv_lower, self.probe_hsv_upper)
        # Remove thin grass blades and isolated pixels, then fill small holes
        # in a solid probe-colour region.
        kernel = np.ones((3, 3), dtype=np.uint8)
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
        contours_result = cv2.findContours(
            mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        contours = contours_result[-2]

        valid_contours = []
        for contour in contours:
            area = cv2.contourArea(contour)
            if not self.min_object_area <= area <= self.max_object_area:
                continue
            hull_area = cv2.contourArea(cv2.convexHull(contour))
            solidity = area / hull_area if hull_area > 0.0 else 0.0
            (_, _), (rect_width, rect_height), _ = cv2.minAreaRect(contour)
            major = max(rect_width, rect_height)
            minor = min(rect_width, rect_height)
            aspect = major / minor if minor > 0.0 else 0.0
            rect_area = major * minor
            rect_fill = area / rect_area if rect_area > 0.0 else 0.0
            if solidity < self.probe_min_solidity:
                continue
            if not self.probe_min_aspect <= aspect <= self.probe_max_aspect:
                continue
            if rect_fill < self.probe_min_rect_fill:
                continue

            # At the current camera height, require the rotated rectangle to
            # be consistent with a 200 x 30 mm probe. This rejects long grass
            # edges even if their hue happens to be yellow-green.
            camera_height = self.estimated_camera_height()
            if camera_height is not None:
                focal = 0.5 * (
                    float(self.camera_matrix[0, 0])
                    + float(self.camera_matrix[1, 1])
                )
                expected_major = focal * self.probe_length / camera_height
                expected_minor_min = (
                    focal * self.probe_min_diameter / camera_height
                )
                expected_minor_max = (
                    focal * self.probe_max_diameter / camera_height
                )
                tolerance = self.probe_size_tolerance
                if not (
                    expected_major * (1.0 - tolerance)
                    <= major
                    <= expected_major * (1.0 + tolerance)
                    and expected_minor_min * (1.0 - tolerance)
                    <= minor
                    <= expected_minor_max * (1.0 + tolerance)
                ):
                    continue
            valid_contours.append(contour)

        if not valid_contours:
            return

        now = time.monotonic()
        self.probe_candidates = [
            candidate
            for candidate in self.probe_candidates
            if now - candidate["last_seen"] <= 2.0
        ]
        new_object_found = False
        for contour in valid_contours:
            if len(self.detected_objects_positions) >= self.max_objects_to_detect:
                break

            M = cv2.moments(contour)
            if M["m00"] == 0:
                continue
            center_u = int(M["m10"] / M["m00"])
            center_v = int(M["m01"] / M["m00"])

            result = self.transform_pixel_to_frames(
                center_u, center_v
            )
            if result is None:
                continue
            camera_coords, world_coords = result

            is_new = True
            for saved_pos in self.detected_objects_positions:
                dist = math.sqrt(
                    (world_coords[0] - saved_pos[0]) ** 2
                    + (world_coords[1] - saved_pos[1]) ** 2
                )
                if dist < self.min_distance_between_objects:
                    is_new = False
                    break

            if is_new:
                candidate = None
                for pending in self.probe_candidates:
                    if math.hypot(
                        world_coords[0] - pending["position"][0],
                        world_coords[1] - pending["position"][1],
                    ) <= self.probe_confirm_radius:
                        candidate = pending
                        break
                if candidate is None:
                    self.probe_candidates.append(
                        {
                            "position": world_coords,
                            "camera": camera_coords,
                            "count": 1,
                            "last_seen": now,
                        }
                    )
                    continue

                count = candidate["count"] + 1
                candidate["position"] = (
                    (candidate["position"][0] * candidate["count"] + world_coords[0])
                    / count,
                    (candidate["position"][1] * candidate["count"] + world_coords[1])
                    / count,
                )
                candidate["camera"] = camera_coords
                candidate["count"] = count
                candidate["last_seen"] = now
                if count < self.probe_confirm_frames:
                    continue

                world_coords = candidate["position"]
                camera_coords = candidate["camera"]
                self.get_logger().info(
                    f">>> Yellow-green probe CONFIRMED! Total: "
                    f"{len(self.detected_objects_positions) + 1}; "
                    f"estimated world position=({world_coords[0]:.3f}, "
                    f"{world_coords[1]:.3f}); pixel=({center_u}, {center_v}); "
                    f"vehicle=({self.current_pose.pose.position.x:.3f}, "
                    f"{self.current_pose.pose.position.y:.3f}, "
                    f"{self.current_pose.pose.position.z:.3f}); "
                    f"camera_xyz=({camera_coords[0]:.3f}, "
                    f"{camera_coords[1]:.3f}, {camera_coords[2]:.3f}); "
                    f"fx={self.camera_matrix[0, 0]:.2f}, "
                    f"fy={self.camera_matrix[1, 1]:.2f} <<<"
                )
                self.detected_objects_positions.append(world_coords)
                self.detected_objects_camera_coords.append(camera_coords)
                self.probe_candidates.remove(candidate)
                new_object_found = True

        if new_object_found:
            self.update_log_file()
            if len(self.detected_objects_positions) == self.max_objects_to_detect:
                self.get_logger().info(
                    f"Found all {self.max_objects_to_detect} objects. Stopping search."
                )

    def transform_pixel_to_frames(self, u, v):
        fx = self.camera_matrix[0, 0]
        fy = self.camera_matrix[1, 1]
        cx = self.camera_matrix[0, 2]
        cy = self.camera_matrix[1, 2]

        # Camera optical coordinates: +x right, +y down, +z forward.
        optical_ray = np.array([(u - cx) / fx, (v - cy) / fy, 1.0])

        try:
            camera_in_body = self.tf_buffer.lookup_transform(
                "base_link", self.camera_frame, Time()
            )
        except TransformException as exc:
            now = time.monotonic()
            if now - self.last_tf_warning_time >= 5.0:
                self.get_logger().warn(
                    f"Cannot transform camera frame '{self.camera_frame}' to "
                    f"base_link; object position skipped: {exc}"
                )
                self.last_tf_warning_time = now
            return None

        tf_rotation = camera_in_body.transform.rotation
        # TF directly maps ROS optical axes (+x right, +y down, +z forward)
        # into base_link. Applying another mount rotation would double-rotate.
        ray_body = self.rotate_vector_by_quaternion(optical_ray, tf_rotation)

        body_rotation = self.current_pose.pose.orientation
        ray_world = self.rotate_vector_by_quaternion(ray_body, body_rotation)

        camera_offset_body = np.array(
            [
                camera_in_body.transform.translation.x,
                camera_in_body.transform.translation.y,
                camera_in_body.transform.translation.z,
            ]
        )
        camera_offset_world = self.rotate_vector_by_quaternion(
            camera_offset_body, body_rotation
        )
        camera_world = np.array(
            [
                self.current_pose.pose.position.x,
                self.current_pose.pose.position.y,
                self.current_pose.pose.position.z,
            ]
        ) + camera_offset_world

        ground_z = self.takeoff_position.pose.position.z
        if ray_world[2] >= -1e-3:
            self.get_logger().warn(
                "Camera ray does not point toward the ground; object position skipped.",
                throttle_duration_sec=5.0,
            )
            return None

        distance = (ground_z - camera_world[2]) / ray_world[2]
        if distance <= 0.0:
            return None

        object_world = camera_world + distance * ray_world
        camera_coords = tuple((distance * optical_ray).tolist())
        world_coords = (float(object_world[0]), float(object_world[1]))
        return camera_coords, world_coords

    def estimated_camera_height(self):
        """Return optical-centre height above the takeoff ground plane."""
        if self.current_pose is None or self.takeoff_position is None:
            return None
        try:
            camera_in_body = self.tf_buffer.lookup_transform(
                "base_link", self.camera_frame, Time()
            )
        except TransformException:
            return None
        offset = np.array(
            [
                camera_in_body.transform.translation.x,
                camera_in_body.transform.translation.y,
                camera_in_body.transform.translation.z,
            ]
        )
        offset_world = self.rotate_vector_by_quaternion(
            offset, self.current_pose.pose.orientation
        )
        height = (
            self.current_pose.pose.position.z
            + offset_world[2]
            - self.takeoff_position.pose.position.z
        )
        return max(0.05, float(height))

    def erc_grid_sector(self, relative_x, relative_y):
        """Map coordinates to an unambiguous 1 m takeoff-relative cell."""
        if math.hypot(relative_x, relative_y) > self.geofence_radius:
            return "OUTSIDE", None
        column = math.floor(relative_x / self.probe_grid_size)
        row = math.floor(relative_y / self.probe_grid_size)
        x0 = column * self.probe_grid_size
        y0 = row * self.probe_grid_size
        sector = f"X{column:+d}_Y{row:+d}"
        bounds = (
            x0,
            x0 + self.probe_grid_size,
            y0,
            y0 + self.probe_grid_size,
        )
        return sector, bounds

    @staticmethod
    def rotate_vector_by_quaternion(vector, quaternion):
        q = np.array(
            [quaternion.x, quaternion.y, quaternion.z, quaternion.w],
            dtype=np.float64,
        )
        norm = np.linalg.norm(q)
        if norm == 0.0:
            return np.asarray(vector, dtype=np.float64)
        q /= norm
        xyz = q[:3]
        w = q[3]
        vector = np.asarray(vector, dtype=np.float64)
        return vector + 2.0 * np.cross(xyz, np.cross(xyz, vector) + w * vector)

    @staticmethod
    def rotate_vector_by_rpy(vector, roll, pitch, yaw):
        cr, sr = math.cos(roll), math.sin(roll)
        cp, sp = math.cos(pitch), math.sin(pitch)
        cy, sy = math.cos(yaw), math.sin(yaw)
        rotation = np.array(
            [
                [cy * cp, cy * sp * sr - sy * cr, cy * sp * cr + sy * sr],
                [sy * cp, sy * sp * sr + cy * cr, sy * sp * cr - cy * sr],
                [-sp, cp * sr, cp * cr],
            ]
        )
        return rotation @ np.asarray(vector, dtype=np.float64)

    def update_log_file(self):
        try:
            with open(self.object_log_filename, "w") as f:
                f.write(
                    f"# Detected Objects: {len(self.detected_objects_positions)} / {self.max_objects_to_detect}\n"
                )
                f.write(
                    "# Coordinates are relative to the takeoff point (meters).\n"
                )
                if self.probe_nose_points_positive_y:
                    f.write(
                        "# ERC alignment: nose at takeoff = +Y, aircraft right = +X.\n\n"
                    )
                else:
                    f.write("# Axes are MAVROS local-map X/Y.\n\n")

                takeoff_x = self.takeoff_position.pose.position.x
                takeoff_y = self.takeoff_position.pose.position.y

                for i, pos in enumerate(self.detected_objects_positions):
                    map_dx = pos[0] - takeoff_x
                    map_dy = pos[1] - takeoff_y
                    if self.probe_nose_points_positive_y:
                        takeoff_yaw = self.get_yaw_from_pose(
                            self.takeoff_position.pose
                        )
                        # Rotate fixed map displacement into the takeoff body
                        # frame. Body-forward becomes ERC +Y and body-right
                        # becomes ERC +X.
                        forward = (
                            math.cos(takeoff_yaw) * map_dx
                            + math.sin(takeoff_yaw) * map_dy
                        )
                        left = (
                            -math.sin(takeoff_yaw) * map_dx
                            + math.cos(takeoff_yaw) * map_dy
                        )
                        relative_x = -left
                        relative_y = forward
                    else:
                        relative_x = map_dx
                        relative_y = map_dy
                    sector, bounds = self.erc_grid_sector(relative_x, relative_y)

                    f.write(f"[Object {i+1}]\n")
                    f.write(f"x: {relative_x:.4f}\n")
                    f.write(f"y: {relative_y:.4f}\n")
                    f.write(f"sector_1m: {sector}\n")
                    if bounds is not None:
                        f.write(
                            f"sector_bounds: x=[{bounds[0]:.1f},{bounds[1]:.1f}), "
                            f"y=[{bounds[2]:.1f},{bounds[3]:.1f})\n"
                        )
                    f.write("\n")

            self.get_logger().info(
                f"Updated object locations in '{self.object_log_filename}'."
            )
        except IOError as e:
            self.get_logger().error(f"Could not write to file: {e}")

    def get_yaw_from_pose(self, pose):
        orientation = pose.orientation
        q_x, q_y, q_z, q_w = orientation.x, orientation.y, orientation.z, orientation.w
        t3 = +2.0 * (q_w * q_z + q_x * q_y)
        t4 = +1.0 - 2.0 * (q_y * q_y + q_z * q_z)
        yaw_z = math.atan2(t3, t4)
        return yaw_z


def main(args=None):
    rclpy.init(args=args)
    node = None
    try:
        node = ArucoLandingNode()
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        if node:
            node.destroy_node()
        # ROS 2 launch may already have shut the context down after SIGINT.
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
