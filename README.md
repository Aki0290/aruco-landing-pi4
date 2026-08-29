# ArUco Landing Pi 4B Training & Competition Package

Raspberry Pi 4B、Ubuntu 22.04 ARM64、RealSense D455、GPIO UART接続のArduPilot FC、
ROS 2 Humble向けの配布用パッケージです。初期状態は飛行指令を一切送らない
`practice`です。

初めてセットアップする場合は、最初に[`SETUP.md`](SETUP.md)を上から順番に
進めてください。このフォルダは一部のファイルだけではなく、フォルダごと共有します。

## 3つの安全モード

| モード | 必要機材 | 動作 | 飛行指令 |
| --- | --- | --- | --- |
| `practice` | Pi + C270 | 実カメラでArUco検出練習 | 送信しない。MAVROSも起動しない |
| `bench` | Pi + C270 + FC + RC | FC接続、CH7、LEDを確認 | コードで禁止 |
| `armtest` | Pi + FC + GPS + RC | CH7受付後に5秒間ARM | GUIDED、Arm、Disarmのみ |
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

標準のLogicool USBカメラでArUco検出のみ:

```bash
./run-usb-practice.sh
docker compose logs -f
```

RealSense D455へ戻す場合は`config/common.env`の`CAMERA_DRIVER`を`realsense`へ
変更して`./run-practice.sh`を実行します。RealSense用コードは削除していません。

USBカメラの個体別キャリブレーションが完了するまでは、マーカー検出結果の距離・
姿勢を飛行制御に使用しないでください。校正データは`config/usb_camera.yaml`へ置き、
`USB_CAMERA_INFO_URL=file:///config/usb_camera.yaml`を設定します。

### Dockerを使わないPractice

ホストへROS 2、librealsense、RealSense ROS、ArUcoノードを構築して実行できます。

```bash
./install-native-practice.sh       # 初回のみ
./diagnose-native-practice.sh
./run-native-practice.sh
```

D455はDocker版と同時使用できません。競合時は`docker compose down`でDocker版を
停止してください。ネイティブ版のログは`native-runtime/logs/`へ保存されます。
詳しくは[`SETUP.md`](SETUP.md)の「Dockerを使わないPractice」を参照してください。

FCとCH7まで確認（プロペラを外す）:

```bash
./run-bench.sh
```

`bench`でLEDが青になったら、CH7を一度OFFにしてからONへ1秒保持します。
LEDが緑になればRC経路は正常です。機体はArmしません。

プロペラをすべて外した状態で、GPS/CH7/GUIDED/ARM/DISARMを一連確認:

```bash
./run-armtest.sh
```

確認に`yes`と入力すると`armtest`が保存され、その後は電源投入時にも同じモードで
自動起動します。毎回CH7を一度LOWにしてからHIGHへ1秒保持するまでARMしません。
GPS 3D Fix、FC接続、Disarmが揃わない場合もARMしません。ARM後は5秒でDISARMし、
コンテナが動作している間は再実行しないワンショット動作です。

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

## ステータスLED配線

FuriousFPV Single Row LED Strip V2（FPV-LED1RV2、8灯、5V）を使用します。

| LED線 | Pi 4B |
| --- | --- |
| 黄（Signal） | GPIO18、物理12番 |
| 赤（5V） | 5V、物理2番または4番 |
| 黒（GND） | GND、物理6番など |

ストリップの信号入力側へ接続します。Piの3.3V信号で点灯が不安定な場合は、
GPIO18とSignalの間に74AHCT125等の3.3V→5Vレベル変換器を入れます。
輝度は`config/common.env`の`STATUS_LED_BRIGHTNESS`（0～255）で変更できます。

| 色 | 状態 |
| --- | --- |
| 赤（速い点滅） | 起動中・異常・ジオフェンス超過・手動介入 |
| 水色（遅い点滅） | Practice |
| 青（遅い点滅） | Bench/Flight準備完了・CH7待ち |
| 緑 | CH7受付成功 |
| 黄（速い点滅） | Flight開始カウントダウン |
| 緑（遅い点滅） | 自動航行中 |
| 黄（遅い点滅） | 自動着陸中 |

LED未接続でもソフトウェア動作には影響しません。

## FCのUART接続、D455、電源

- D455はPi 4Bの青いUSB 3ポートへ接続
- Pi GPIO14/TX（物理8番）をFC TELEM RXへ接続
- Pi GPIO15/RX（物理10番）をFC TELEM TXへ接続
- Pi GND（物理6番など）をFC TELEM GNDへ接続
- FCはPower Moduleから給電
- PiとD455は十分な容量の5V BECから給電
- FC TELEMの5V端子はPiへ接続しない
- D455のUSBケーブルとUART配線を機体へ固定

FCは`/dev/serial0`を115200 baudで使用します。PiでUARTを有効化し、FC側の
接続したTELEMポートをMAVLink 2、115200 baudに設定してください。詳細は
[`SETUP.md`](SETUP.md)を参照してください。信号は3.3V UARTです。

PiとDockerがFCより先に起動しても問題ありません。`READY_TIMEOUT=0`（標準）では、
MAVROSを起動したままFCのheartbeatとDisarm状態を待ち、FC接続後に自動で準備確認を
再開します。有限時間で再起動させたい場合だけ秒数を指定してください。

## ログと確認

```bash
docker compose ps
docker compose logs -f
tail -f runtime/logs/realsense.log
tail -f runtime/logs/mavros.log
tail -f runtime/logs/aruco_landing.log
```

probe検出結果はDocker内だけでなく、ホストの次の固定ファイルへ保存されます。

```text
runtime/probe_results.txt
```

各probeについて離陸点相対の`x`/`y`、1 m区画キー（例`X+0_Y-1`）、区画境界を
記録します。このキーは座標を曖昧なく表すための内部表記であり、Figure 11の名称を
推測して割り当てたものではありません。公式の最終対応表が確定したら変換表を追加します。
標準では離陸時の機首方向を審判座標の`+Y`、機体右方向を`+X`として出力します。
設置時は審判に`+Y`の向き（正方向）を確認してから機首を合わせてください。

Flightでは離陸地点から半径3 mまでを探索します。測位誤差と制動余裕を含む
`GEOFENCE_RADIUS=3.5`を超えると
探索・setpoint送信を停止して、FCがLANDへ移るまでLANDモードを繰り返し要求します。

自動飛行でGUIDEDへ入った後、送信機またはFCがGUIDED以外へ切り替わると手動介入を
永久ラッチし、Piからのsetpoint、GUIDED、LAND、Arm、Takeoff要求をすべて停止します。
Pi自身が着陸を開始済みの場合のLAND遷移だけは正常遷移として許可します。手動介入後に
自動飛行へ戻すには、着陸・Disarm後にコンテナを再起動する必要があります。

C270はレンズ中心が`base_link`から機首前方へ7.5 cm、下へ15 cmにある前提です。画像上を
機首前方、画像右を機体右、光軸を真下へ対応させる静的TFを起動します。実測後は
`USB_CAMERA_OFFSET_X/Y/Z`を調整してください（現在は`0.075, 0.0, -0.15` m）。

## 配布時のルール

- `.env`が`OPERATION_MODE=practice`であることを確認して渡す
- `flight.env`を削除・編集して安全機構を回避しない
- 後輩だけで`flight`を実行しない
- Benchまでは必ずプロペラを外す
- 飛行試験は大会規則、責任者、緊急停止手段、飛行区域を確認する
- 高耐久SDカードまたはSSDを使用し、電源・冷却・配線固定を確認する
