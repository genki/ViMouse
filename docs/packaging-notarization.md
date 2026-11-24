---
title: macOS インストーラー
permalink: /packaging-notarization/
---

# macOS インストーラー

Developer IDで署名し、Appleの公証を受けたUniversalインストーラーは
[GitHub Releases](https://github.com/genki/ViMouse/releases) から取得できます。
同梱のSHA-256と照合してから、パッケージを開いてください。

ソースからビルドする場合は、macOS 26 SDKを備えたXcodeを使います。
READMEに記載したローカル変換SDKを用意し、ViMouseスキームをビルドしてください。
