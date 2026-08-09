# ArUco Landing 環境セットアップ手順

このフォルダは、Raspberry Pi 4B、RealSense D455、USB接続のArduPilot FCを使って、
ArUco検出練習、FC接続練習、本番用自動航行を行うための配布パッケージです。

初期状態は必ず`practice`です。`practice`ではMAVROSを起動せず、FCへ飛行指令を
送ることはありません。

## 1. 必要なもの

- Raspberry Pi 4B（4GB以上、8GB推奨）
- 64-bit版Ubuntu Server 22.04
- 32GB以上の高耐久microSDカード、またはUSB SSD
- RealSense D455と短いUSB 3ケーブル
- ArduPilot対応FCとUSBケーブル
- RC送信機・受信機
- 共通カソードRGB LED
- 220～330Ω抵抗を3本
- PiとD455へ給電できる安定した5V BEC
- ファン付きヒートシンク

## 2. Raspberry Pi OSの準備

Raspberry Pi ImagerでUbuntu Server 22.04 64-bitを書き込みます。Imagerの設定で、
ユーザー名、パスワード、Wi-Fi、SSHを設定しておくと初回作業が簡単です。

Piを起動してログイン後、更新します。

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

## 3. Dockerのインストール

Ubuntu公式パッケージを使う場合は次を実行します。

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

グループ設定を反映するため、一度ログアウトして入り直すか再起動します。

```bash
sudo reboot
```

確認します。

```bash
docker version
docker compose version
```

## 4. このフォルダをPiへコピーする

Macからコピーする例です。ユーザー名とIPアドレスは実際のPiに合わせます。

```bash
scp -r ~/Desktop/aruco-landing-pi4 ubuntu@192.168.1.100:~/
```

USBメモリや共有ドライブで、`aruco-landing-pi4`フォルダを丸ごとコピーしても
構いません。コピー後はPiで次の場所へ移動します。

```bash
cd ~/aruco-landing-pi4
chmod +x ./*.sh docker/*.sh docker/*.py
```

## 5. 機器を接続する

- D455はPi 4Bの青いUSB 3ポートへ接続します。
- ArduPilot FCはPiの別のUSBポートへ接続します。
- FCはPower Moduleから給電します。
- PiとD455は十分な容量の5V BECから給電します。
- USBケーブルは振動で抜けないよう、両端を機体へ固定します。

認識を確認します。

```bash
lsusb
ls -l /dev/serial/by-id/
```

## 6. RGB LEDを接続する

共通カソードRGB LEDの各色へ220～330Ωの抵抗を直列に入れます。

| LED端子        | BCM GPIO | Pi物理ピン |
| -------------- | -------: | ---------: |
| 赤（抵抗経由） |   GPIO17 |         11 |
| 緑（抵抗経由） |   GPIO27 |         13 |
| 青（抵抗経由） |   GPIO22 |         15 |
| 共通カソード   |      GND |     14など |

LEDを接続していなくてもソフトウェアは動作します。共通アノード型には対応して
いません。

## 7. Dockerイメージを作る

```bash
cd ~/aruco-landing-pi4
docker compose build
```

初回はARM64向けlibrealsenseをコンパイルするため時間がかかります。途中で電源を
切らないでください。失敗した場合は、まず同じコマンドを再実行します。

## 8. Practiceモードで確認する

```bash
./run-practice.sh
docker compose logs -f
```

PracticeではD455とArUco検出だけを起動します。FCへ指令は送りません。LEDは
水色になります。

ArUco ID 102をD455へ見せ、ログに検出結果が表示されることを確認します。

```bash
tail -f runtime/logs/aruco_landing.log
```

## 9. BenchモードでFCとCH7を確認する

必ずプロペラを外してください。

```bash
./run-bench.sh
```

BenchではD455、MAVROS、FC、RCを確認しますが、着陸コードはArm、モード変更、
Takeoff、setpoint送信を行いません。

LEDが青になったらCH7を一度OFFにし、その後ONで1秒保持します。LEDが緑になれば、
送信機からFC、MAVROS、Piまでの開始信号は正常です。機体は飛行しません。

## 10. CH7をMission Plannerで設定する

1. 送信機の空いている2ポジションスイッチを受信機CH7へ割り当てます。
2. Mission PlannerでFCへ接続します。
3. `INITIAL SETUP > Mandatory Hardware > Radio Calibration`を開きます。
4. OFFでCH7が約1000、ONで約2000になることを確認します。
5. Full Parameter Listで`RC7_OPTION = 0`にします。
6. CH7が飛行モード、Arm/Disarm、RTLなどに使われていないことを確認します。

起動時にCH7がONでも開始しません。一度OFFを認識した後、ONを1秒保持する必要が
あります。

## 11. 電源投入時の自動起動を設定する

最初はPracticeモードのまま設定します。

```bash
./run-practice.sh
./install-autostart.sh
```

再起動して確認します。

```bash
sudo reboot
```

再接続後、状態を確認します。

```bash
sudo systemctl status aruco-landing
docker compose ps
```

## 12. Flightモードへ切り替える

Flightは責任者立会いの飛行試験または大会本番でのみ使います。

```bash
./preflight-check.sh
./run-flight.sh
```

確認質問に正確に`yes`と入力した場合のみFlightへ切り替わります。

Flightでは次の順番で動作します。

1. D455、FC、MAVROSを起動
2. カメラ画像、FC接続、Disarm、自己位置を3回連続確認
3. LEDを青にしてCH7待機
4. CH7をLOWからHIGHへ切り替え、1秒保持
5. LED緑で受付
6. LED黄で5秒カウントダウン
7. 自動航行ノード起動、LED紫

練習や飛行終了後は必ずPracticeへ戻します。

```bash
./run-practice.sh
```

## 13. LED表示

| 色   | 状態                          |
| ---- | ----------------------------- |
| 赤   | 起動中、機器待ち              |
| 水色 | Practiceモード                |
| 青   | Bench/Flight準備完了、CH7待ち |
| 緑   | CH7受付成功                   |
| 黄   | 自動航行開始前カウントダウン  |
| 紫   | 自動航行中                    |

## 14. トラブル確認

```bash
docker compose ps
docker compose logs --tail=200
tail -100 runtime/logs/realsense.log
tail -100 runtime/logs/mavros.log
tail -100 runtime/logs/aruco_landing.log
```

D455確認:

```bash
docker compose exec aruco-landing rs-enumerate-devices
docker compose exec aruco-landing ros2 topic hz /camera/camera/color/image_raw
```

FC確認:

```bash
docker compose exec aruco-landing ros2 topic echo /mavros/state --once
docker compose exec aruco-landing ros2 topic echo /mavros/rc/in --once
```

## 安全上の注意

- Benchまでは必ずプロペラを外します。
- ArduPilotのPreArmチェック、安全スイッチ、RCフェイルセーフを無効化しません。
- Flightは大会規則、責任者、飛行区域、緊急停止手段を確認して実施します。
- モーター動作時の低電圧、USB切断、Piの過熱を事前に確認します。
- 本パッケージは安全な段階練習を補助しますが、飛行安全を保証するものではありません。
