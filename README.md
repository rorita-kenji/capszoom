# CapsZoom

Caps Lock を押している間、画面を2倍ズームする macOS アプリ。
ズームの中心は押した瞬間のマウス位置。トラックパッドのスクロールでパンできる。

## 使い方

1. `CapsZoom.app` を起動（`open CapsZoom.app`。ターミナルからバイナリ直実行はしない）
2. メニューバーに 🔍 が出る
3. **Caps Lock を押している間だけ** 2倍ズーム
4. ズーム中にスクロールでパン
5. 終了: 🔍 → Quit CapsZoom

### 権限（初回）

- システム設定 → プライバシーとセキュリティ → **画面収録** で CapsZoom を許可
- 同じく → **アクセシビリティ** で CapsZoom を許可
- 許可後、一度終了して `open` で再起動

再署名で TCC が切れたら `tccutil reset Accessibility com.makoto.capszoom` と `tccutil reset ScreenCapture com.makoto.capszoom` のあと、設定から再登録する。

ビルドは固定署名 `CapsZoomDev` を使う（ad-hoc だと再ビルドのたびに許可が死ぬ）。

ターミナルから本体を直実行すると画面収録が Terminal 扱いになり失敗する。必ず `open CapsZoom.app`。

## ビルド

```sh
cd ~/ai/capszoom
mkdir -p CapsZoom.app/Contents/MacOS
swiftc -parse-as-library -O \
    -framework AppKit -framework ApplicationServices \
    -framework CoreGraphics -framework ScreenCaptureKit \
    CapsZoomApp.swift -o CapsZoom.app/Contents/MacOS/CapsZoom
codesign --force --deep -s CapsZoomDev CapsZoom.app
# CapsZoomDev が無い場合のみ: codesign --force --deep -s - CapsZoom.app
open CapsZoom.app
```

## ファイル

| パス | 内容 |
|---|---|
| `CapsZoomApp.swift` | 全ソース |
| `CapsZoom.app/` | ビルド済みアプリ |
| `CapsZoom.app/Contents/Info.plist` | LSUIElement=true（Dock 非表示） |

## 実装

- キャプチャ: ScreenCaptureKit `SCScreenshotManager`。表示前に1枚撮る（黒パネル自身を撮らない）。カーソルがある画面を対象
- ズーム: CGContext を 2 倍。offset = カーソル位置 × (1 - 1/z) で、拡大前の点が同じ画面位置に残る
- Caps Lock: CGEventTap + `maskAlphaShift`
- AppKit のみ（NSPanel + status item）
- bundle id: `com.makoto.capszoom`
