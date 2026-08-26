#!/usr/bin/env bash
set -euo pipefail

children=()
led_pids=()
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
  local color="$1" red=0 green=0 blue=0 setting
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
  timeout 5 ros2 topic echo "$1" --once --qos-reliability best_effort >/dev/null 2>&1
}
mavros_connected() {
  timeout 5 ros2 topic echo /mavros/state --once --qos-reliability best_effort \
    2>/dev/null | grep -q '^connected: true$'
}
mavros_disarmed() {
  timeout 5 ros2 topic echo /mavros/state --once --qos-reliability best_effort \
    2>/dev/null | grep -q '^armed: false$'
}
wait_ready() {
  local require_pose="$1" deadline=$((SECONDS + READY_TIMEOUT)) stable=0
  while (( SECONDS < deadline )); do
    if has_message /camera/camera/color/image_raw && mavros_connected \
      && mavros_disarmed && { [[ "$require_pose" == false ]] \
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
  ros2 launch realsense2_camera rs_launch.py camera_name:=camera camera_namespace:=camera \
    enable_color:=true enable_depth:="${ENABLE_DEPTH:-true}" \
    enable_infra1:=false enable_infra2:=false enable_gyro:="${ENABLE_IMU:-false}" \
    enable_accel:="${ENABLE_IMU:-false}" pointcloud.enable:="${ENABLE_POINTCLOUD:-false}" \
    align_depth.enable:="${ALIGN_DEPTH:-false}" \
    rgb_camera.color_profile:="${COLOR_PROFILE:-640x480x15}" \
    depth_module.depth_profile:="${DEPTH_PROFILE:-640x360x15}" \
    >/runtime/logs/realsense.log 2>&1 & children+=("$!")
}
start_mavros() {
  ros2 launch mavros apm.launch fcu_url:="$1" gcs_url:="${GCS_URL:-}" \
    >/runtime/logs/mavros.log 2>&1 & children+=("$!")
}
start_landing_node() {
  ros2 run aruco_landing landing_node --ros-args \
    -p operation_mode:="${OPERATION_MODE}" -p search_height:="${SEARCH_HEIGHT:-2.0}" \
    -p image_topic:=/camera/camera/color/image_raw \
    -p camera_info_topic:=/camera/camera/color/camera_info \
    >/runtime/logs/aruco_landing.log 2>&1 & children+=("$!")
}

: "${OPERATION_MODE:=practice}"
: "${DEVICE_WAIT_TIMEOUT:=120}" "${READY_TIMEOUT:=180}" "${READY_STABLE_COUNT:=3}"
[[ "$OPERATION_MODE" =~ ^(practice|bench|flight)$ ]] || { log "ERROR: invalid mode"; exit 10; }
mkdir -p /runtime/logs
set_led red
wait_usb 'Intel.*RealSense|RealSense' 'D455' || exit 20
start_camera

if [[ "$OPERATION_MODE" == practice ]]; then
  until has_message /camera/camera/color/image_raw; do sleep 2; done
  start_landing_node; set_led cyan
  log "PRACTICE: ArUco検出のみ。FCへの指令経路は起動していません。"
else
  fcu_url="$(detect_fcu)" || { log "ERROR: FCが見つかりません"; exit 21; }
  start_mavros "$fcu_url"
  if [[ "$OPERATION_MODE" == bench ]]; then
    wait_ready false || exit 23
    start_landing_node; set_led blue
    log "BENCH: FC接続済みですが、飛行指令は禁止されています。CH7を試せます。"
    wait-for-rc-start && { set_led green; log "CH7開始操作は正常です（飛行しません）。"; }
  else
    [[ "${AUTONOMOUS_FLIGHT_ACK:-}" == I_ACCEPT_AUTONOMOUS_ARM_AND_TAKEOFF ]] \
      || { log "ERROR: flight acknowledgement missing"; exit 22; }
    wait_ready true || exit 23
    set_led blue; log "FLIGHT READY: CH${RC_START_CHANNEL:-7}を待機します。"
    wait-for-rc-start || exit 24
    set_led green; log "CH7開始指令を受理しました。"
    delay="${AUTO_START_DELAY:-5}"; set_led yellow
    while ((delay)); do log "開始まで ${delay} 秒"; sleep 1; delay=$((delay-1)); done
    start_landing_node; set_led purple; log "FLIGHT: 自動航行ノードを起動しました。"
  fi
fi

set +e
wait -n "${children[@]}"; status=$?
log "プロセス終了 status=${status}。コンテナを再起動します。"
exit "$status"
