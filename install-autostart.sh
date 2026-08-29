#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
service_file="/etc/systemd/system/aruco-landing.service"

if [[ ! -f "${project_dir}/.env" ]]; then
  cp "${project_dir}/.env.example" "${project_dir}/.env"
  echo "${project_dir}/.env を作成しました。内容を確認してから再実行してください。"
  exit 2
fi

sudo tee "${service_file}" >/dev/null <<EOF
[Unit]
Description=ArUco Landing Competition Stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${project_dir}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable docker.service aruco-landing.service
sudo systemctl restart aruco-landing.service
echo "自動起動を有効にしました: ${service_file}"
