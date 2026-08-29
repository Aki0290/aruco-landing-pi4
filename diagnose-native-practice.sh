#!/usr/bin/env bash
set -uo pipefail

workspace="${ARUCO_NATIVE_WS:-$HOME/aruco_ws}"
failures=0
ok() { printf '[ OK ] %s\n' "$*"; }
bad() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }
info() { printf '[INFO] %s\n' "$*"; }

if [[ -f /opt/ros/humble/setup.bash ]]; then
  # shellcheck disable=SC1091
  source /opt/ros/humble/setup.bash
  ok "ROS 2 Humble"
else
  bad "/opt/ros/humble/setup.bash がありません"
fi
if [[ -f "$workspace/install/setup.bash" ]]; then
  # shellcheck disable=SC1090
  source "$workspace/install/setup.bash"
  ok "ワークスペース: $workspace"
else
  bad "$workspace/install/setup.bash がありません"
fi

if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null \
  | grep -qx aruco-landing-pi4; then
  bad "Docker版 aruco-landing-pi4 が実行中です（D455と競合します）"
  info "停止: cd ~/aruco-landing-pi4 && docker compose down"
else
  ok "競合するDockerコンテナなし"
fi

usb_listing="$(lsusb 2>&1)"
usb_tree="$(lsusb -t 2>&1)"
if grep -qiE 'Intel.*RealSense|RealSense' <<<"$usb_listing"; then
  ok "USB上にRealSenseを検出"
elif grep -q 'Class=Video' <<<"$usb_tree"; then
  info "USB 3上に映像デバイスはありますが、通常のlsusbでは機種を確認できません"
  grep -q 'unable to initialize libusb' <<<"$usb_listing" \
    && bad "libusbを初期化できません（udevルール適用後にD455を抜き差ししてください）"
else
  bad "USB上にRealSenseが見つかりません（青いUSB 3ポート、ケーブル、電源を確認）"
fi

speed="$(grep -E 'Class=Video' <<<"$usb_tree" | grep -Eo '(5000|10000)M' | head -n1 || true)"
if [[ -n "$speed" ]]; then ok "USB速度: $speed"; else info "USB 3速度を自動確認できませんでした。lsusb -tを確認してください"; fi
printf '%s\n' "$usb_tree"

if command -v rs-enumerate-devices >/dev/null 2>&1; then
  if timeout 15 rs-enumerate-devices -s >/tmp/aruco-rs-device.txt 2>&1 \
    && grep -qi 'Device Name' /tmp/aruco-rs-device.txt; then
    ok "librealsenseからD455を読めます"
    sed -n '1,20p' /tmp/aruco-rs-device.txt
  else
    bad "librealsenseからD455を開けません"
    sed -n '1,80p' /tmp/aruco-rs-device.txt
  fi
else
  bad "rs-enumerate-devices がありません"
fi

if (( failures )); then
  printf '\n診断結果: %d件の問題があります。\n' "$failures"
  exit 1
fi
printf '\n診断結果: 基本チェックは正常です。./run-native-practice.sh を実行できます。\n'
