#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace="${ARUCO_NATIVE_WS:-$HOME/aruco_ws}"
log_dir="$root/native-runtime/logs"
camera_pid="" landing_pid=""

cleanup() {
  trap - INT TERM EXIT
  [[ -n "$landing_pid" ]] && kill -INT "$landing_pid" 2>/dev/null || true
  [[ -n "$camera_pid" ]] && kill -INT "$camera_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

[[ -f /opt/ros/humble/setup.bash ]] || { echo "ERROR: ROS 2 Humble未導入。./install-native-practice.sh を先に実行してください。" >&2; exit 2; }
[[ -f "$workspace/install/setup.bash" ]] || { echo "ERROR: $workspace が未ビルドです。" >&2; exit 2; }
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1090
source "$workspace/install/setup.bash"
set -a
# shellcheck disable=SC1091
source "$root/config/common.env"
source "$root/config/practice.env"
set +a
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}"
mkdir -p "$log_dir"

if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aruco-landing-pi4; then
  echo "ERROR: Docker版が実行中でD455が競合します。先に 'docker compose down' を実行してください。" >&2
  exit 3
fi

echo "RealSense RGBを起動します。ログ: $log_dir/realsense.log"
ros2 launch realsense2_camera rs_launch.py \
  camera_name:=camera camera_namespace:=camera \
  enable_color:=true enable_depth:="${ENABLE_DEPTH:-false}" \
  enable_infra1:=false enable_infra2:=false \
  enable_gyro:="${ENABLE_IMU:-false}" enable_accel:="${ENABLE_IMU:-false}" \
  pointcloud.enable:="${ENABLE_POINTCLOUD:-false}" \
  align_depth.enable:="${ALIGN_DEPTH:-false}" \
  rgb_camera.color_profile:="${COLOR_PROFILE:-640x480x15}" \
  depth_module.depth_profile:="${DEPTH_PROFILE:-640x360x15}" \
  >"$log_dir/realsense.log" 2>&1 &
camera_pid=$!

deadline=$((SECONDS + ${DEVICE_WAIT_TIMEOUT:-120}))
until timeout 5 ros2 topic echo /camera/camera/color/image_raw --once \
  --qos-reliability best_effort >/dev/null 2>&1; do
  if ! kill -0 "$camera_pid" 2>/dev/null; then
    echo "ERROR: RealSenseノードが終了しました。" >&2
    tail -80 "$log_dir/realsense.log" >&2
    exit 4
  fi
  if (( SECONDS >= deadline )); then
    echo "ERROR: RGB画像が時間内に届きませんでした。" >&2
    tail -80 "$log_dir/realsense.log" >&2
    exit 5
  fi
  echo "RGB画像を待っています..."
  sleep 2
done

echo "RGB画像を確認しました。ArUco practiceノードを起動します。"
ros2 run aruco_landing landing_node --ros-args \
  -p operation_mode:=practice -p search_height:="${SEARCH_HEIGHT:-2.0}" \
  -p image_topic:=/camera/camera/color/image_raw \
  -p camera_info_topic:=/camera/camera/color/camera_info \
  >"$log_dir/aruco_landing.log" 2>&1 &
landing_pid=$!
printf 'Practice実行中（飛行指令なし）。終了は Ctrl+C。\n画像レート確認: ros2 topic hz /camera/camera/color/image_raw\n'

set +e
wait -n "$camera_pid" "$landing_pid"
status=$?
set -e
echo "ノードが終了しました (status=$status)"
tail -40 "$log_dir/realsense.log" || true
tail -40 "$log_dir/aruco_landing.log" || true
exit "$status"
