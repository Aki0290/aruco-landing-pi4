#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
container="aruco-landing-pi4"
display="${DISPLAY:-:0}"
output="$root/config/usb_camera.yaml"
temp_dir="$(mktemp -d)"
cleanup() {
  xhost -SI:localuser:root >/dev/null 2>&1 || true
  rm -rf "$temp_dir"
}
trap cleanup EXIT

docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true || {
  echo "ERROR: 先に ./run-usb-practice.sh を実行してください。" >&2
  exit 2
}
command -v xhost >/dev/null 2>&1 || {
  echo "ERROR: xhostがありません。sudo apt install x11-xserver-utils を実行してください。" >&2
  exit 2
}

echo "印刷物: config/calibration/checkerboard_8x6_25mm.svg"
echo "A4横、100%、1マス25 mmであることを確認してください。"
echo "ウィンドウ内のX/Y/Size/Skewを集め、CALIBRATE、SAVE、COMMITの順に押します。"
xhost +SI:localuser:root >/dev/null
docker exec -e DISPLAY="$display" "$container" bash -lc '
  source /opt/ros/humble/setup.bash
  source /opt/aruco_ws/install/setup.bash
  rm -f /tmp/calibrationdata.tar.gz
  ros2 run camera_calibration cameracalibrator \
    --size 8x6 --square 0.025 \
    --ros-args \
    -r image:=/camera/camera/color/image_raw \
    -r camera:=/camera/camera/color
'

if docker cp "$container:/tmp/calibrationdata.tar.gz" \
  "$temp_dir/calibrationdata.tar.gz" >/dev/null 2>&1; then
  tar -xOf "$temp_dir/calibrationdata.tar.gz" ost.yaml >"$output"
  echo "校正ファイルを保存しました: $output"
  if grep -q '^USB_CAMERA_INFO_URL=' "$root/config/common.env"; then
    sed -i 's|^USB_CAMERA_INFO_URL=.*|USB_CAMERA_INFO_URL=file:///config/usb_camera.yaml|' \
      "$root/config/common.env"
  fi
  sed -i 's|^DETECTION_ONLY=.*|DETECTION_ONLY=false|' "$root/config/common.env"
  echo "./run-usb-practice.sh で校正値を反映してください。"
else
  echo "ERROR: SAVEされた校正データがありません。もう一度実行してください。" >&2
  exit 3
fi
