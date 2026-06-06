# ViMouse ディレクトリ調査メモ

## ルート直下
- `README.md`: プロジェクト概要とキーバインドの説明。
- `ViMouse.xcodeproj/`: Xcode プロジェクト定義。`project.pbxproj` にターゲットやビルド設定、`xcuserdata/` には個人設定が格納。
- `ViMouse/`: メインアプリのソースコードとリソース。
- `ViMouseTests/`, `ViMouseUITests/`: 単体テストおよび UI テストターゲットのスケルトン。
- `Icon.png`, `Icon.svg`: アプリ用アイコン素材。
- `.gitignore`, `.git/`: バージョン管理関連。

## `ViMouse/`
- `AppDelegate.swift`: アプリケーションライフサイクルのエントリーポイント。
- `InputHook.swift`: キーボード入力をフックして処理するロジックを実装。
- `Helper.m` & `ViMouse-Bridging-Header.h`: Objective-C コードと Swift のブリッジング定義。Carbon や CoreGraphics などレガシー API を扱う可能性。
- `Assets.xcassets/`: アイコン (`AppIcon.appiconset/`) や画像リソース。
- `Base.lproj/Main.storyboard`: UI レイアウト定義。
- `ViMouse.xcdatamodeld/`: Core Data モデル (現在は `contents` ファイルのみ)。
- `Info.plist`: バンドル設定や権限。

## テストターゲット
- `ViMouseTests/ViMouseTests.swift`: XCTest ベースのユニットテスト。初期テンプレートのみで未実装。
- `ViMouseUITests/ViMouseUITests.swift`: UI テストのテンプレート。ここも未実装。
- 各ディレクトリに `Info.plist` があり、テストバンドル設定を保持。

## その他
- `Icon.png` と `Icon.svg` は README のブランド用素材。
- `.DS_Store` は macOS が生成するメタデータ。不要なら削除可能。

以上。

## ビルド・署名の知見（2025-12-04）
- 公開リポジトリのため、個人情報（メールアドレス・証明書ハッシュ・Team ID など）は記載しない。
- 署名はローカルの開発証明書を利用し、具体的な証明書名は残さないこと。
- CLI から署名する前に必須: `scripts/grant.sh` を実行して login.keychain を解錠し、`set-key-partition-list` を設定する。未実施だと `errSecInternalComponent` で失敗する。
- 手動署名コマンドの書式（ID は自分の証明書に置換）  
  `codesign --deep --force --options runtime --sign "<YOUR_APPLE_DEV_IDENTITY>" /Users/takiuchi/Library/Developer/Xcode/DerivedData/ViMouse-*/Build/Products/Release/ViMouse.app`
- 成果物: `dist/ViMouse-Release-signed-YYYYMMDD.zip`（署名済み Universal バイナリ）と、未署名版 `dist/ViMouse-Release-unsigned-YYYYMMDD.zip` を日付で管理。
- Xcode の自動署名はアカウント設定が無い環境では失敗するため、CI/ターミナルでは上記手動手順が確実。
