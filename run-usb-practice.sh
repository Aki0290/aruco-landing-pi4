#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CAMERA_DRIVER=usb
exec "$root/run-practice.sh"
