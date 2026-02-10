# Folder Tidy

macOS向けのフォルダ整理アプリです。SwiftUIで作成されています。

## 機能

- 📁 ダウンロードフォルダのファイルを拡張子ごとに自動分類
- 👀 プレビュー機能 - 実行前に移動されるファイルを確認
- ↩️ 元に戻す機能 - 整理したファイルを元の場所に復元

## カテゴリ

| カテゴリ | 拡張子 |
|---------|--------|
| Documents | .pdf, .doc, .docx, .rtf |
| Text | .txt, .md, .markdown |
| Spreadsheets | .xls, .xlsx, .csv |
| Presentations | .ppt, .pptx |
| Images | .jpg, .jpeg, .png, .gif, .webp, .heic, .bmp, .svg |
| Videos | .mp4, .mov, .mkv, .avi, .wmv, .webm |
| Audio | .mp3, .wav, .m4a, .aac, .flac |
| Archives | .zip, .rar, .7z, .tar, .gz, .tgz |
| Installers | .dmg, .pkg, .msi, .exe |

## 要件

- macOS 13.0以上
- Xcode 15.0以上

## ビルド方法

1. Xcodeでプロジェクトを開く
2. Product > Build (⌘B)
3. Product > Run (⌘R)

## ライセンス

MIT License

## ドラッグ&ドロップ型アップデートDMGの作成

一般的なMacアプリのように「`Applications` へドラッグ」できる配布形式は、
アプリ本体ではなく配布用 `.dmg` の作り方で実現します。

### 1. 先に `.app` をビルド

例:

```bash
xcodebuild -project DownloadsOrganizer.xcodeproj \
  -scheme DownloadsOrganizer \
  -configuration Release \
  -derivedDataPath /tmp/FolderTidyRelease \
  CODE_SIGNING_ALLOWED=NO build
```

生成物:
`/tmp/FolderTidyRelease/Build/Products/Release/Folder Tidy.app`

### 2. ドラッグ&ドロップDMGを生成

```bash
scripts/create_dragdrop_dmg.sh \
  --app "/tmp/FolderTidyRelease/Build/Products/Release/Folder Tidy.app" \
  --output "build/Folder-Tidy.dmg" \
  --volume-name "Folder Tidy"
```

オプション:
- `--background /path/to/background.png` を指定すると、DMGウィンドウ背景を設定できます。

### 3. GitHub ReleasesにDMGを添付

アプリ内アップデートはGitHub Releasesの最新アセットを参照します。
`.dmg` を添付すると、アプリ側から開いたときにそのままドラッグ&ドロップで更新できます。

## 再発防止: バージョン不一致チェック付きリリース

「ファイル名は新しいのに中身が古いDMG」を防ぐため、以下の検証スクリプトを追加しています。

- `scripts/verify_app_version.sh`:
  `.app` の `CFBundleShortVersionString` が期待値と一致するか確認
- `scripts/verify_dmg_version.sh`:
  `.dmg` を一時マウントして中の `.app` バージョンを確認
- `scripts/build_release_dmg.sh`:
  Releaseビルド -> DMG作成 -> DMG内バージョン検証を一括実行

例（推奨フロー）:

```bash
scripts/build_release_dmg.sh --version 1.3.1
```

このコマンドは、バージョン不一致がある場合に失敗して停止します。
