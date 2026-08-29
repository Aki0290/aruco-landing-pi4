#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"
failed=0
check() { if eval "$2" >/dev/null 2>&1; then echo "OK  $1"; else echo "NG  $1"; failed=1; fi; }
check "Docker" "docker info"
camera_driver="$(awk -F= '$1 == "CAMERA_DRIVER" { print $2 }' config/common.env)"
if [[ "$camera_driver" == usb ]]; then
  camera_device="$(awk -F= '$1 == "USB_CAMERA_DEVICE" { print $2 }' .env)"
  check "USB camera $camera_device" "test -c '$camera_device'"
  check "USB camera calibration" "test -s config/usb_camera.yaml"
  check "USB camera calibration URL" \
    "grep -qx 'USB_CAMERA_INFO_URL=file:///config/usb_camera.yaml' config/common.env"
else
  check "D455 USB" "lsusb | grep -qiE 'Intel.*RealSense|RealSense'"
fi
check "FC UART /dev/serial0" "test -e /dev/serial0"
check "Compose config" "docker compose config --quiet"
check "Container" "docker compose ps --status running | grep -q aruco-landing"
if docker compose ps --status running | grep -q aruco-landing; then
  if docker compose exec -T aruco-landing bash -lc \
    'source /opt/ros/humble/setup.bash; source /opt/aruco_ws/install/setup.bash; timeout 20 ros2 topic echo /camera/camera/color/image_raw --field header --once --qos-reliability best_effort' \
    >/dev/null 2>&1; then
    echo "OK  Camera image stream"
  else
    echo "NG  Camera image stream"
    failed=1
  fi
fi
(( failed == 0 )) || { echo "点検NGがあります。flightへ進まないでください。"; exit 1; }
echo "基本点検OK。flight時は機体・RC・飛行区域も責任者が確認してください。"
