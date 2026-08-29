#!/usr/bin/env bash
set -euo pipefail

children=()
led_pids=()
led_state_file=/runtime/status-led.state
log() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*"; }

shutdown() {
  trap - INT TERM EXIT
  for pid in "${children[@]:-}" "${led_pids[@]:-}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap shutdown INT TERM EXIT

set_led() {
  local color="$1" pattern="${2:-solid}" red=0 green=0 blue=0 setting
  if [[ "${STATUS_LED_TYPE:-ws281x}" == ws281x ]]; then
    printf '%s %s\n' "$color" "$pattern" >"$led_state_file"
    return
  fi
  for pid in "${led_pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  led_pids=()
  case "$color" in
    red) red=1;; green) green=1;; blue) blue=1;;
    yellow) red=1; green=1;; purple) red=1; blue=1;;
    cyan) green=1; blue=1;; off) ;;
  esac
  for setting in "${RGB_LED_RED_GPIO:-17}=$red" \
    "${RGB_LED_GREEN_GPIO:-27}=$green" "${RGB_LED_BLUE_GPIO:-22}=$blue"; do
    gpioset --mode=signal gpiochip0 "$setting" >>/runtime/logs/status-led.log 2>&1 &
    led_pids+=("$!")
  done
}

start_led_controller() {
  [[ "${STATUS_LED_TYPE:-ws281x}" == ws281x ]] || return
  printf 'red fast\n' >"$led_state_file"
  status-led-ws281x red --pattern fast --watch "$led_state_file" \
    --gpio "${STATUS_LED_GPIO:-18}" --count "${STATUS_LED_COUNT:-8}" \
    --brightness "${STATUS_LED_BRIGHTNESS:-64}" \
    >>/runtime/logs/status-led.log 2>&1 &
  led_pids+=("$!")
}

wait_usb() {
  local pattern="$1" label="$2" deadline=$((SECONDS + DEVICE_WAIT_TIMEOUT))
  until lsusb | grep -qiE "$pattern"; do
    (( SECONDS >= deadline )) && { log "ERROR: ${label} timeout"; return 1; }
    log "${label}を待機しています..."; sleep 2
  done
}

detect_fcu() {
  if [[ "${FCU_URL:-auto}" != auto ]]; then
    local configured_url="$FCU_URL" configured_device=""
    if [[ "$configured_url" =~ ^serial://(/dev/[^:]+)(:.*)?$ ]]; then
      configured_device="${BASH_REMATCH[1]}"
      local deadline=$((SECONDS + DEVICE_WAIT_TIMEOUT))
      until [[ -e "$configured_device" ]]; do
        (( SECONDS >= deadline )) && return 1
        sleep 2
      done
    fi
    echo "$configured_url"
    return
  fi
  local deadline=$((SECONDS + DEVICE_WAIT_TIMEOUT)) devices=()
  while (( SECONDS < deadline )); do
    shopt -s nullglob
    devices=(/dev/serial/by-id/*ArduPilot* /dev/serial/by-id/*Pixhawk* \
      /dev/serial/by-id/*Cube* /dev/serial/by-id/*PX4*)
    shopt -u nullglob
    ((${#devices[@]})) && { echo "serial://${devices[0]}:${FCU_BAUD:-115200}"; return; }
    sleep 2
  done
  return 1
}

has_message() {
  # 画像全体をCLIで文字列化するとPi 4ではタイムアウトしやすいためheaderだけ読む。
  timeout "${ROS_TOPIC_TIMEOUT:-12}" ros2 topic echo "$1" --field header --once \
    --qos-reliability best_effort >/dev/null 2>&1
}
mavros_connected_and_disarmed() {
  # Pi 4ではros2 CLIの起動とdiscoveryだけで5秒を超えることがある。
  # stateを1回だけ読み、接続とDisarmを同じスナップショットで判定する。
  local state
  state="$(timeout "${ROS_TOPIC_TIMEOUT:-12}" ros2 topic echo /mavros/state \
    --once --qos-reliability best_effort 2>/dev/null)" || return 1
  grep -q '^connected: true$' <<<"$state" \
    && grep -q '^armed: false$' <<<"$state"
}
wait_ready() {
  local require_pose="$1" timeout_seconds="${READY_TIMEOUT:-0}" deadline=0 stable=0
  # READY_TIMEOUT=0 means that startup may wait forever.  This is intentional:
  # the Pi/container is commonly powered before the FC, and MAVROS can safely
  # keep the serial link open until the FC starts sending heartbeats.
  (( timeout_seconds > 0 )) && deadline=$((SECONDS + timeout_seconds))
  while (( deadline == 0 || SECONDS < deadline )); do
    if has_message /camera/camera/color/image_raw && mavros_connected_and_disarmed \
      && { [[ "$require_pose" == false ]] \
      || has_message /mavros/local_position/pose; }; then
      stable=$((stable + 1)); log "準備確認 ${stable}/${READY_STABLE_COUNT}"
      (( stable >= READY_STABLE_COUNT )) && return 0
    else
      stable=0; log "カメラ・FC・Disarm・自己位置を確認中..."
    fi
    sleep 2
  done
  return 1
}

start_camera() {
  if [[ "${CAMERA_DRIVER:-realsense}" == usb ]]; then
    local info_args=()
    [[ -n "${USB_CAMERA_INFO_URL:-}" ]] \
      && info_args=(-p camera_info_url:="${USB_CAMERA_INFO_URL}")
    ros2 run v4l2_camera v4l2_camera_node --ros-args \
      -r __ns:=/camera/camera \
      -r image_raw:=color/image_raw -r camera_info:=color/camera_info \
      -p video_device:="${USB_CAMERA_DEVICE:-/dev/video0}" \
      -p image_size:="[${USB_CAMERA_WIDTH:-640},${USB_CAMERA_HEIGHT:-480}]" \
      -p time_per_frame:="[1,${USB_CAMERA_FPS:-15}]" \
      -p pixel_format:="${USB_CAMERA_PIXEL_FORMAT:-YUYV}" \
      -p output_encoding:="${USB_CAMERA_OUTPUT_ENCODING:-rgb8}" \
      -p camera_frame_id:="${USB_CAMERA_FRAME:-usb_camera_color_optical_frame}" \
      "${info_args[@]}" \
      >/runtime/logs/usb_camera.log 2>&1 & children+=("$!")
  else
    ros2 launch realsense2_camera rs_launch.py camera_name:=camera camera_namespace:=camera \
      enable_color:=true enable_depth:="${ENABLE_DEPTH:-true}" \
      enable_infra1:=false enable_infra2:=false enable_gyro:="${ENABLE_IMU:-false}" \
      enable_accel:="${ENABLE_IMU:-false}" pointcloud.enable:="${ENABLE_POINTCLOUD:-false}" \
      align_depth.enable:="${ALIGN_DEPTH:-false}" \
      rgb_camera.color_profile:="${COLOR_PROFILE:-640x480x15}" \
      depth_module.depth_profile:="${DEPTH_PROFILE:-640x360x15}" \
      >/runtime/logs/realsense.log 2>&1 & children+=("$!")
  fi
}
start_usb_camera_tf() {
  # Centered below base_link and facing down. Image top is vehicle-forward.
  # Optical axes map as: right -> body-right, image-down -> body-rear,
  # optical-forward -> body-down.
  ros2 run tf2_ros static_transform_publisher \
    --x "${USB_CAMERA_OFFSET_X:-0.0}" \
    --y "${USB_CAMERA_OFFSET_Y:-0.0}" \
    --z "${USB_CAMERA_OFFSET_Z:--0.10}" \
    --qx 0.7071067812 --qy -0.7071067812 --qz 0.0 --qw 0.0 \
    --frame-id base_link \
    --child-frame-id "${USB_CAMERA_FRAME:-usb_camera_color_optical_frame}" \
    >/runtime/logs/camera_tf.log 2>&1 & children+=("$!")
}
start_mavros() {
  local launch_args=(fcu_url:="$1")
  [[ -n "${GCS_URL:-}" ]] && launch_args+=(gcs_url:="$GCS_URL")
  ros2 launch mavros apm.launch "${launch_args[@]}" \
    >/runtime/logs/mavros.log 2>&1 & children+=("$!")
}
start_landing_node() {
  ros2 run aruco_landing landing_node --ros-args \
    -p operation_mode:="${OPERATION_MODE}" -p search_height:="${SEARCH_HEIGHT:-2.0}" \
    -p landing_marker_id:="${LANDING_MARKER_ID:-102}" \
    -p marker_length:="${MARKER_LENGTH:-0.15}" \
    -p centering_tolerance:="${CENTERING_TOLERANCE:-0.15}" \
    -p center_confirm_frames:="${CENTER_CONFIRM_FRAMES:-5}" \
    -p marker_lost_timeout:="${MARKER_LOST_TIMEOUT:-1.0}" \
    -p centering_command_rate:="${CENTERING_COMMAND_RATE:-5.0}" \
    -p centering_max_step:="${CENTERING_MAX_STEP:-0.04}" \
    -p centering_min_step:="${CENTERING_MIN_STEP:-0.005}" \
    -p centering_slow_radius:="${CENTERING_SLOW_RADIUS:-0.75}" \
    -p search_angle_step_deg:="${SEARCH_ANGLE_STEP_DEG:-0.36}" \
    -p max_search_radius:="${MAX_SEARCH_RADIUS:-3.0}" \
    -p geofence_radius:="${GEOFENCE_RADIUS:-3.5}" \
    -p probe_grid_size:="${PROBE_GRID_SIZE:-1.0}" \
    -p probe_nose_points_positive_y:="${PROBE_NOSE_POINTS_POSITIVE_Y:-true}" \
    -p enable_probe_practice:="${ENABLE_PROBE_PRACTICE:-true}" \
    -p probe_hue_min:="${PROBE_HUE_MIN:-25}" \
    -p probe_hue_max:="${PROBE_HUE_MAX:-45}" \
    -p probe_saturation_min:="${PROBE_SATURATION_MIN:-100}" \
    -p probe_value_min:="${PROBE_VALUE_MIN:-100}" \
    -p probe_min_area:="${PROBE_MIN_AREA:-500}" \
    -p probe_max_area:="${PROBE_MAX_AREA:-60000}" \
    -p probe_min_solidity:="${PROBE_MIN_SOLIDITY:-0.80}" \
    -p probe_min_aspect:="${PROBE_MIN_ASPECT:-3.5}" \
    -p probe_max_aspect:="${PROBE_MAX_ASPECT:-10.0}" \
    -p probe_min_rect_fill:="${PROBE_MIN_RECT_FILL:-0.60}" \
    -p probe_length:="${PROBE_LENGTH:-0.20}" \
    -p probe_min_diameter:="${PROBE_MIN_DIAMETER:-0.02}" \
    -p probe_max_diameter:="${PROBE_MAX_DIAMETER:-0.03}" \
    -p probe_size_tolerance:="${PROBE_SIZE_TOLERANCE:-0.55}" \
    -p probe_confirm_frames:="${PROBE_CONFIRM_FRAMES:-5}" \
    -p probe_confirm_radius:="${PROBE_CONFIRM_RADIUS:-0.25}" \
    -p practice_base_height:="${PRACTICE_BASE_HEIGHT:-2.0}" \
    -p camera_frame:="${USB_CAMERA_FRAME:-usb_camera_color_optical_frame}" \
    -p detection_only:="${DETECTION_ONLY:-true}" \
    -p image_topic:=/camera/camera/color/image_raw \
    -p camera_info_topic:=/camera/camera/color/camera_info \
    >/runtime/logs/aruco_landing.log 2>&1 & children+=("$!")
}

: "${OPERATION_MODE:=practice}"
: "${DEVICE_WAIT_TIMEOUT:=120}" "${READY_TIMEOUT:=0}" "${READY_STABLE_COUNT:=3}"
[[ "$OPERATION_MODE" =~ ^(practice|bench|armtest|flight)$ ]] || { log "ERROR: invalid mode"; exit 10; }
mkdir -p /runtime/logs
start_led_controller
set_led red fast
if [[ "${CAMERA_DRIVER:-realsense}" == realsense ]]; then
  wait_usb 'Intel.*RealSense|RealSense' 'D455' || exit 20
elif [[ "${CAMERA_DRIVER:-realsense}" == usb ]]; then
  [[ -e "${USB_CAMERA_DEVICE:-/dev/video0}" ]] \
    || { log "ERROR: USBカメラ ${USB_CAMERA_DEVICE:-/dev/video0} がありません"; exit 20; }
else
  log "ERROR: CAMERA_DRIVERはrealsenseまたはusbを指定してください"; exit 10
fi
start_camera
if [[ "${CAMERA_DRIVER:-realsense}" == usb ]]; then
  start_usb_camera_tf
fi

if [[ "$OPERATION_MODE" == practice ]]; then
  until has_message /camera/camera/color/image_raw; do sleep 2; done
  start_landing_node; set_led cyan slow
  log "PRACTICE: ArUco検出のみ。FCへの指令経路は起動していません。"
else
  fcu_url="$(detect_fcu)" || { log "ERROR: FCが見つかりません"; exit 21; }
  start_mavros "$fcu_url"
  if [[ "$OPERATION_MODE" == bench ]]; then
    wait_ready false || exit 23
    start_landing_node; set_led blue slow
    log "BENCH: FC接続済みですが、飛行指令は禁止されています。CH7を試せます。"
    wait-for-rc-start && { set_led green; log "CH7開始操作は正常です（飛行しません）。"; }
  elif [[ "$OPERATION_MODE" == armtest ]]; then
    wait_ready false || exit 23
    set_led blue slow
    log "ARMTEST READY: GPS 3D FixとCH${RC_START_CHANNEL:-7} LOW→HIGHを待機します。"
    arm-disarm-test >/runtime/logs/arm-disarm-test.log 2>&1 & children+=("$!")
  else
    [[ "${AUTONOMOUS_FLIGHT_ACK:-}" == I_ACCEPT_AUTONOMOUS_ARM_AND_TAKEOFF ]] \
      || { log "ERROR: flight acknowledgement missing"; exit 22; }
    wait_ready true || exit 23
    set_led blue slow; log "FLIGHT READY: CH${RC_START_CHANNEL:-7}を待機します。"
    wait-for-rc-start || exit 24
    set_led green; log "CH7開始指令を受理しました。"
    delay="${AUTO_START_DELAY:-5}"; set_led yellow fast
    while ((delay)); do log "開始まで ${delay} 秒"; sleep 1; delay=$((delay-1)); done
    start_landing_node; set_led green slow; log "FLIGHT: 自動航行ノードを起動しました。"
  fi
fi

set +e
wait -n "${children[@]}"; status=$?
log "プロセス終了 status=${status}。コンテナを再起動します。"
exit "$status"
