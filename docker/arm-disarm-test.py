#!/usr/bin/env python3
import os
import struct
import sys
import time

import rclpy
from mavros_msgs.msg import GPSRAW, Mavlink, RCIn, State
from mavros_msgs.srv import CommandBool, SetMode
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy


class ArmDisarmTest(Node):
    def __init__(self):
        super().__init__("arm_disarm_test")
        self.rc_index = int(os.getenv("RC_START_CHANNEL", "7")) - 1
        self.rc_low = int(os.getenv("RC_LOW_THRESHOLD", "1200"))
        self.rc_high = int(os.getenv("RC_HIGH_THRESHOLD", "1800"))
        self.hold = float(os.getenv("RC_HIGH_HOLD_SECONDS", "1.0"))
        self.armed_seconds = float(os.getenv("ARM_TEST_SECONDS", "5.0"))
        self.led_state_file = os.getenv("STATUS_LED_STATE_FILE", "/runtime/status-led.state")
        self.state = None
        self.fix_type = 0
        self.low_seen = False
        self.high_since = None
        self.running = False
        self.done = False

        qos = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )
        self.create_subscription(State, "/mavros/state", self.on_state, 10)
        self.create_subscription(GPSRAW, "/mavros/gpsstatus/gps1/raw", self.on_gps, qos)
        self.create_subscription(RCIn, "/mavros/rc/in", self.on_rc, qos)
        self.create_subscription(Mavlink, "/uas1/mavlink_source", self.on_mavlink, qos)
        self.mode_client = self.create_client(SetMode, "/mavros/set_mode")
        self.arm_client = self.create_client(CommandBool, "/mavros/cmd/arming")
        self.get_logger().info("ARM TEST: GPS 3D FixとCH7 LOW→HIGHを待機します")

    def set_status_led(self, colour, pattern="solid"):
        try:
            with open(self.led_state_file, "w", encoding="ascii") as state_file:
                state_file.write(f"{colour} {pattern}\n")
        except OSError as exc:
            self.get_logger().error(f"LED状態の更新に失敗しました: {exc}")

    def on_state(self, msg):
        self.state = msg

    def on_gps(self, msg):
        self.fix_type = int(msg.fix_type)

    def on_rc(self, msg):
        if self.done or self.running or self.rc_index >= len(msg.channels):
            return
        self.process_rc(int(msg.channels[self.rc_index]))

    def on_mavlink(self, msg):
        # GPS_RAW_INT (message ID 24): fix_type and satellites_visible are
        # bytes 28 and 29 in both MAVLink 1 and 2 payloads.
        if msg.msgid == 24 and msg.payload64:
            payload = b"".join(
                int(word).to_bytes(8, byteorder="little", signed=False)
                for word in msg.payload64
            )
            if len(payload) >= 30:
                old_fix = self.fix_type
                self.fix_type = int(payload[28])
                if self.fix_type != old_fix:
                    self.get_logger().info(
                        f"GPS fix_type={self.fix_type}, satellites={int(payload[29])}"
                    )
            return
        # RC_CHANNELS fallback for receivers that incorrectly report chancount=0.
        if msg.msgid != 65 or not msg.payload64 or not 0 <= self.rc_index < 18:
            return
        payload = b"".join(
            int(word).to_bytes(8, byteorder="little", signed=False)
            for word in msg.payload64
        )
        if len(payload) < 42:
            return
        value = int(struct.unpack_from("<I18HBB", payload)[1 + self.rc_index])
        if value not in (0, 65535):
            self.process_rc(value)

    def process_rc(self, value):
        if self.done or self.running:
            return
        if value <= self.rc_low:
            if not self.low_seen:
                self.get_logger().info("CH7 LOW確認。GPS 3D Fix後にHIGHへ切り替えてください")
            self.low_seen = True
            self.high_since = None
            return
        ready = self.state and self.state.connected and not self.state.armed and self.fix_type >= 3
        if not self.low_seen or not ready or value < self.rc_high:
            self.high_since = None
            return
        now = time.monotonic()
        if self.high_since is None:
            self.high_since = now
            self.get_logger().info("CH7 HIGH確認中...")
        elif now - self.high_since >= self.hold:
            self.running = True
            self.set_status_led("green")
            self.get_logger().info("CH7受付成功。LEDを緑に変更しました")

    def call(self, client, request, timeout=8.0):
        if not client.wait_for_service(timeout_sec=timeout):
            raise RuntimeError("MAVROS service unavailable")
        future = client.call_async(request)
        rclpy.spin_until_future_complete(self, future, timeout_sec=timeout)
        if not future.done() or future.result() is None:
            raise RuntimeError("MAVROS service timeout")
        return future.result()

    def wait_state(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        while rclpy.ok() and time.monotonic() < deadline:
            rclpy.spin_once(self, timeout_sec=0.1)
            if self.state and predicate(self.state):
                return True
        return False

    def disarm(self):
        for _ in range(3):
            try:
                self.call(self.arm_client, CommandBool.Request(value=False), 5.0)
            except RuntimeError as exc:
                self.get_logger().error(f"DISARM要求エラー: {exc}")
            if self.wait_state(lambda s: not s.armed, 3.0):
                self.set_status_led("green")
                self.get_logger().info("DISARM確認。ARMテスト完了")
                return True
        self.get_logger().fatal("DISARMを確認できません。送信機から直ちにDISARMしてください")
        return False

    def execute(self):
        try:
            if not (self.state and self.state.connected and not self.state.armed and self.fix_type >= 3):
                raise RuntimeError("開始直前の安全条件が変化しました")
            mode = self.call(self.mode_client, SetMode.Request(base_mode=0, custom_mode="GUIDED"))
            if not mode.mode_sent or not self.wait_state(lambda s: s.mode == "GUIDED", 5.0):
                raise RuntimeError("GUIDEDへの変更が拒否されました")
            armed = self.call(self.arm_client, CommandBool.Request(value=True))
            if not armed.success or not self.wait_state(lambda s: s.armed, 5.0):
                raise RuntimeError("ARMが拒否されました。PreArmメッセージを確認してください")
            self.get_logger().warning(f"ARM確認。{self.armed_seconds:.1f}秒後にDISARMします")
            deadline = time.monotonic() + self.armed_seconds
            while rclpy.ok() and time.monotonic() < deadline:
                rclpy.spin_once(self, timeout_sec=0.1)
        except Exception as exc:
            self.get_logger().error(f"ARMテスト中止: {exc}")
        finally:
            self.done = self.disarm()
            self.running = False


def main():
    rclpy.init()
    node = ArmDisarmTest()
    rc = 0
    try:
        while rclpy.ok() and not node.running:
            rclpy.spin_once(node, timeout_sec=0.2)
        if node.running:
            node.execute()
        # One shot per boot/container start. Remain alive so restart policy cannot rerun it.
        while rclpy.ok():
            rclpy.spin_once(node, timeout_sec=1.0)
    except KeyboardInterrupt:
        node.disarm()
        rc = 130
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()
    return rc


if __name__ == "__main__":
    sys.exit(main())
