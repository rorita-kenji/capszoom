# CapsZoom

Caps Lock 単独押しで画面を2倍ズーム／解除する macOS アプリ（OS の大文字ロックは動かさない）。
ズーム中心はマウス位置に毎フレーム追従し、下の画面はライブで更新される（Windows 版 WinZoom と同じ動き）。
Shift + Caps Lock は素通しするので、本当の Caps Lock はそちらで使える。

## インストール（ユーザー向け）

1. [Releases](https://github.com/rorita-kenji/capszoom/releases) から `CapsZoom.dmg` をダウンロード
2. DMG を開く
3. `CapsZoom.app` を `Applications` フォルダへドラッグ
4. `/Applications/CapsZoom.app` を起動。初回は **右クリック → 開く**（Apple の有料開発者IDで署名していないため、「開発元を確認できない」と出る。右クリックで開ければ使える）
5. 画面収録とアクセシビリティを許可して、アプリを再起動

詳しい手順（権限の画面操作つき）: [INSTALL.md](INSTALL.md)

## 使い方

1. `CapsZoom.app` を起動（`open CapsZoom.app`。ターミナルからバイナリ直実行はしない）
2. メニューバーに 🔍 が出る
3. **Caps Lock 単独押し** で 2倍ズーム ON / OFF（大文字入力にはならない）
4. オーバーレイはクリック透過。カーソル自体は拡大されない
5. 🔍 → **ログイン時に起動** で自動起動の ON / OFF
6. 終了: 🔍 → Quit CapsZoom

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
    -framework CoreGraphics -framework CoreImage -framework CoreMedia \
    -framework CoreVideo -framework IOKit -framework ServiceManagement \
    -framework ScreenCaptureKit \
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

- キャプチャ: ScreenCaptureKit `SCStream` で最大60fps。自窓を除外してフィードバックを防ぐ。カーソルがある画面を対象。Retina では `backingScaleFactor` を掛けたネイティブ解像度（`captureResolution = .best`）
- ズーム: CGContext を 2 倍。毎フレーム offset = カーソル位置 × (1 - 1/z)。パネルは `ignoresMouseEvents` でクリック透過
- Caps Lock: キーコード 57 を横取りしてトグル。イベント破棄だけでは HID のロックが残るので `IOHIDSetModifierLockState` でオフ。Shift/Ctrl/Option/Cmd 併用は素通し
- AppKit のみ（NSPanel + status item）
- bundle id: `com.makoto.capszoom`
- アイコン: `AppIcon.icns`（青い虫眼鏡に「2x」）。Info.plist の `CFBundleIconFile=AppIcon`
- DMG: Applications へのシンボリックリンクを同梱

```sh
mkdir -p dmg_stage && cp -R CapsZoom.app dmg_stage/ && ln -s /Applications dmg_stage/Applications
hdiutil create -volname CapsZoom -srcfolder dmg_stage -ov -format UDZO CapsZoom.dmg && rm -rf dmg_stage
```
