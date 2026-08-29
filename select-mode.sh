#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$mode" =~ ^(practice|bench|armtest|flight)$ ]] || {
  echo "Usage: $0 practice|bench|armtest|flight" >&2; exit 2;
}
if [[ "$mode" == armtest ]]; then
  echo "ARMTESTはプロペラを外した機体をGUIDEDでARMし、数秒後にDISARMします。"
  read -r -p "プロペラがすべて外れており、機体を監視していますか？ [yes/NO] " answer
  [[ "$answer" == yes ]] || { echo "中止しました。"; exit 3; }
fi
if [[ "$mode" == flight ]]; then
  echo "FLIGHTモードはGUIDED、Arm、Takeoffを自動要求します。"
  echo "プロペラなし試験、CH7、フェイルセーフ、飛行範囲を確認してください。"
  read -r -p "有資格の責任者が立ち会っていますか？ [yes/NO] " answer
  [[ "$answer" == yes ]] || { echo "中止しました。"; exit 3; }
fi
{
  echo "# Generated. Select mode with ./select-mode.sh"
  cat "$root/config/common.env"
  cat "$root/config/$mode.env"
} > "$root/.env"

# /dev/videoNはUSBの抜き差しや接続順で変わるため、C270の現在の番号を選ぶ。
camera_driver="${CAMERA_DRIVER:-$(awk -F= '$1 == "CAMERA_DRIVER" { print $2 }' "$root/.env")}"
if [[ "$camera_driver" == usb && -z "${USB_CAMERA_DEVICE:-}" ]]; then
  for name_file in /sys/class/video4linux/video*/name; do
    [[ -r "$name_file" ]] || continue
    if grep -qiE 'C270|Logitech.*Webcam|Logicool.*Webcam' "$name_file"; then
      camera_device="/dev/$(basename "$(dirname "$name_file")")"
      sed -i "s|^USB_CAMERA_DEVICE=.*|USB_CAMERA_DEVICE=$camera_device|" "$root/.env"
      echo "USB camera selected: $camera_device ($(cat "$name_file"))"
      break
    fi
  done
fi
echo "Mode selected: $mode"
docker compose -f "$root/compose.yaml" --project-directory "$root" up -d --force-recreate
