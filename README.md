# ArUco Landing Pi 4B Training & Competition Package

Raspberry Pi 4B、Ubuntu 22.04 ARM64、RealSense D455、USB接続のArduPilot FC、
ROS 2 Humble向けの配布用パッケージです。初期状態は飛行指令を一切送らない
`practice`です。

初めてセットアップする場合は、最初に[`SETUP.md`](SETUP.md)を上から順番に
進めてください。このフォルダは一部のファイルだけではなく、フォルダごと共有します。

## 3つの安全モード

| モード | 必要機材 | 動作 | 飛行指令 |
| --- | --- | --- | --- |
| `practice` | Pi + D455 | 実カメラでArUco検出練習 | 送信しない。MAVROSも起動しない |
| `bench` | Pi + D455 + FC + RC | FC接続、CH7、LEDを確認 | コードで禁止 |
| `flight` | 全機材 | CH7受付後に自動航行 | GUIDED、Arm、Takeoffを要求 |

`practice`と`bench`では、着陸ノード内部でもサービス呼び出しとsetpoint送信を
停止します。設定ファイルだけでなくコード側にも安全境界があります。

## 初回セットアップ

```bash
cd ~/aruco-landing-pi4
docker compose build
chmod +x ./*.sh docker/*.sh docker/*.py
./install-autostart.sh
```

自動起動をインストールしても、配布時の標準は`practice`です。

## 練習の開始

ArUco検出のみ:

```bash
./run-practice.sh
docker compose logs -f
```

FCとCH7まで確認（プロペラを外す）:

```bash
./run-bench.sh
```

`bench`でLEDが青になったら、CH7を一度OFFにしてからONへ1秒保持します。
LEDが緑になればRC経路は正常です。機体はArmしません。

## Flightへの切り替え

`practice`と`bench`を完了し、責任者立会いのもとで実行します。

```bash
./preflight-check.sh
./run-flight.sh
```

確認質問へ正確に`yes`と入力しなければ切り替わりません。選択後は電源再投入でも
`flight`で復帰します。練習終了時には必ず戻してください。

```bash
./run-practice.sh
```

## Flightシーケンス

1. バッテリー投入
2. Pi、Docker、D455、MAVROSを自動起動
3. カメラ、FC接続、Disarm、自己位置を3回連続確認
4. LEDを青にしてCH7待機
5. CH7をLOWからHIGHへ切り替えて1秒保持
6. LED緑で受付、LED黄で5秒カウントダウン
7. 自動航行ノード起動、LED紫

起動時にCH7がONでも開始しません。一度LOWにする必要があります。ArduPilotの
PreArmチェック、安全スイッチ、RCフェイルセーフは無効化しないでください。

## CH7のArduPilot設定

1. 送信機の空いている2ポジションスイッチを受信機CH7へ割り当てる
2. Mission Plannerの`INITIAL SETUP > Mandatory Hardware > Radio Calibration`を開く
3. OFFで約1000、ONで約2000になることを確認する
4. Full Parameter Listで`RC7_OPTION = 0`（Do Nothing）にする
5. CH7が飛行モード、Arm/Disarm、RTL等に使われていないことを確認する

開始ゲートはMAVROSの`/mavros/rc/in`を読みます。閾値は`config/common.env`で
変更できます。

## RGB LED配線

共通カソードRGB LEDの各色へ220～330Ωの抵抗を直列に入れます。

| LED | BCM GPIO | 物理ピン |
| --- | ---: | ---: |
| 赤 | GPIO17 | 11 |
| 緑 | GPIO27 | 13 |
| 青 | GPIO22 | 15 |
| 共通カソード | GND | 14など |

| 色 | 状態 |
| --- | --- |
| 赤 | 起動中・機器待ち |
| 水色 | Practice |
| 青 | Bench/Flight準備完了・CH7待ち |
| 緑 | CH7受付成功 |
| 黄 | Flight開始カウントダウン |
| 紫 | 自動航行中 |

LED未接続でもソフトウェア動作には影響しません。共通アノード型は非対応です。

## USB接続と電源

- D455はPi 4Bの青いUSB 3ポートへ接続
- FCは別のUSBポートへ接続
- FCはPower Moduleから給電
- PiとD455は十分な容量の5V BECから給電
- 短いUSBケーブルを使用して両端を機体へ固定

FCは`/dev/serial/by-id`から自動検出します。複数FCがある場合は
`config/common.env`の`FCU_URL`へ固定パスを指定します。

## ログと確認

```bash
docker compose ps
docker compose logs -f
tail -f runtime/logs/realsense.log
tail -f runtime/logs/mavros.log
tail -f runtime/logs/aruco_landing.log
```

## 配布時のルール

- `.env`が`OPERATION_MODE=practice`であることを確認して渡す
- `flight.env`を削除・編集して安全機構を回避しない
- 後輩だけで`flight`を実行しない
- Benchまでは必ずプロペラを外す
- 飛行試験は大会規則、責任者、緊急停止手段、飛行区域を確認する
- 高耐久SDカードまたはSSDを使用し、電源・冷却・USB固定を確認する
