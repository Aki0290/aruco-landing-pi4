#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
"$root/preflight-check.sh"
exec "$root/select-mode.sh" flight
