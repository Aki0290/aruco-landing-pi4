#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$mode" =~ ^(practice|bench|flight)$ ]] || {
  echo "Usage: $0 practice|bench|flight" >&2; exit 2;
}
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
echo "Mode selected: $mode"
docker compose -f "$root/compose.yaml" --project-directory "$root" up -d --force-recreate
