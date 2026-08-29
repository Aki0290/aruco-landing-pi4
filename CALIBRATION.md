# Logicool C270 カメラキャリブレーション

## 必要なもの

- `config/calibration/checkerboard_8x6_25mm.svg`をA4横で印刷したもの
- 定規またはノギス
- 平らで硬い板
- 実際に使用するLogicool C270、解像度640x480

印刷設定は「実際のサイズ」または100%にし、「用紙に合わせる」は無効にします。
印刷後、黒白1マスが25 mmであることを複数箇所で測ります。紙を平らな板へ貼り、
反りや波打ちがない状態にします。

## 撮影方法

USB Practiceで画像を配信し、校正スクリプトを実行します。

```bash
./run-usb-practice.sh
./calibrate-usb-camera.sh
```

`8x6`はマス数ではなく内側の交点数、`0.025`は1マス25 mmをメートルで表した値です。

ボードを正面だけでなく、画面の上下左右・四隅、近距離・遠距離、上下左右へ傾けた
状態で撮影します。ボード全体が画面内に入り、ブレや反射がない画像を使います。
ツールのX/Y/Size/Skewが十分集まったら`CALIBRATE`、続いて`SAVE`、`COMMIT`を
実行してウィンドウを閉じます。スクリプトがYAMLを取り出して設定を更新します。

生成されたYAMLを次へ保存します。

```text
config/usb_camera.yaml
```

`config/common.env`へ次を設定して再起動します。

```env
USB_CAMERA_INFO_URL=file:///config/usb_camera.yaml
```

```bash
./run-usb-practice.sh
```

解像度、カメラ個体、レンズ、フォーカス状態を変えた場合は再校正します。他のC270の
公開校正値は初期確認には使えても、距離・姿勢推定や飛行制御には使用しません。
