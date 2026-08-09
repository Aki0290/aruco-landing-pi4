#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"
failed=0
check() { if eval "$2" >/dev/null 2>&1; then echo "OK  $1"; else echo "NG  $1"; failed=1; fi; }
check "Docker" "docker info"
check "D455 USB" "lsusb | grep -qiE 'Intel.*RealSense|RealSense'"
check "ArduPilot USB" "find /dev/serial/by-id -maxdepth 1 -type l 2>/dev/null | grep -qiE 'ArduPilot|Pixhawk|Cube|PX4'"
check "Compose config" "docker compose config --quiet"
check "Container" "docker compose ps --status running | grep -q aruco-landing"
if docker compose ps --status running | grep -q aruco-landing; then
  check "D455 image topic" "docker compose exec -T aruco-landing ros2 topic list | grep -q /camera/camera/color/image_raw"
fi
(( failed == 0 )) || { echo "点検NGがあります。flightへ進まないでください。"; exit 1; }
echo "基本点検OK。flight時は機体・RC・飛行区域も責任者が確認してください。"
