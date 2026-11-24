# ViMouse
Control mouse cursor using keyboard like the Vim keybind ;)

This is for Mac OS.
ViMouse introduce your Mac two modes Normal and Input Mode such like the Vim.
After you start up the ViMouse, the indigator will appear at the menu bar.
When Normal mode, the menu item is highlighted and you can controll cursor.
When Input mode, you can input any key except `^ ;` or `<fn> ;` that is the mode switch.

NOTE:
This product is tuned up for me, so I recommend you to see the source and adjust parameters or key mapping.

## Key mapping in Normal mode
* `h`, `j`, `k`, `l`: acts as you know in normal mode.
* `i`, `<英数>`, `<かな>`: switch to Input mode
* `<space>`: Left click
* `n`: Middle click
* `;`: Right click
* `a`: Very slow cursor speed
* `s`: Slow cursor speed
* `d`: Fast cursor speed
* `f`: Very fast cursor speed
* `g`: Acts as mouse wheel. Use combined with `h`,`j`,`k`,`l` and `a`, `s`, `d`, `f`.
* `y`: Yank
* `p`: Paste
* `v`: 日本語の音声入力。
* `u`: Undo 
* `r`: ⌘R, typically reload.
* Hold `b` and press `h`/`l`: move to the previous/next Space.
* Hold `b` and press `j`: show the front application's windows (App Exposé).
* Hold `b` and press `k`: show all windows (Mission Control).

The horizontal chords use the same Dock swipe as the trackpad and target the
display under the pointer when you press `h` or `l` while holding `b`.

## トラックパッドの端からSpaceを切り替える

すべてのモードで、1本指を左右どちらかの端から水平にスライドすると、
指を置いた時点のカーソルがある画面のSpaceを切り替えます。

| 操作 | 移動先 |
| --- | --- |
| 右端から内へ／左端から外へ | 次のSpace |
| 左端から内へ／右端から外へ | 前のSpace |

対象画面にその方向のSpaceがない場合は、画面を動かしません。
スライドアウトは端の近くから外側へ滑らせ、縁で指が離れたときに発動します。
内蔵トラックパッドと対応するMagic Trackpadが対象です。

## カーソルを見つける

同じ場所でカーソルを素早く小刻みに3往復させると、最後の位置に波紋が出ます。
ViMouseの移動キー、マウス、トラックパッドで使えます。通常入力モードでも反応します。

## Key mapping in Input mode
* `^;`, `<fn>;`: switch to Normal mode;
* `^H`, `^J`, `^K`, `^L`: acts as arrow keys

## 日本語の音声入力

macOS 26以降では、マウスモードの `v`、またはどちらのモードでも
`Fn+v` で録音を開始できます。同じ操作でもう一度押すと確定し、
自前変換と同じ方法で入力中のアプリに文字を入れます。
録音中はメニューバーに ● が表示され、`Esc` で取り消せます。
初回はマイクの許可と日本語モデルの準備が必要です。
WebshのTalker経由の音声入力と同じAppleの日本語認識をMac上で行います。

## LAN Agent API

The menu's **Allow remote operation (LAN)** toggle enables token-authenticated
cursor movement, clicks, button holds/drags, and scrolling. It is off by default.
Settings → Agent API displays/copies the authenticated documentation URL and
renews its token. The listener is limited to local private IPv4 subnets and localhost.
See [Agent API documentation](docs/agent-api.md) for commands and network limits.

## Distribution

The repeatable macOS installer, signing, and notarization procedure is documented in
[`docs/packaging-notarization.md`](docs/packaging-notarization.md).

## macOS更新後にCtrl+;が反応しない場合

build 50では、通常ユーザーのセッションでキー入力を監視し、macOSによる監視の中断や
権限の変更後も再接続します。メニューバーのViMouseを開くと現在の状態が表示されます。

- 「キーボード操作: 利用可能」なら、Ctrl+;またはFn+;でマウスモードへ切り替えます。
  キー割当を変更している場合は、設定の「マウスモードへ入る」に指定したキーを使います。
  「利用可能」は入力監視の接続状態で、マウスモードがオンであることや、直近のキーが届いたことを示す表示ではありません。
  切り替え後はH/J/K/Lでカーソルが動くことも確認できます。Iキーで通常入力へ戻ります。
- アクセシビリティや入力監視の許可が必要と表示されたら、メニューの対応する設定を開き、
  ViMouseを許可してください。続いて「キーボード操作を再接続」を選びます。
  許可不足だけを理由にViMouseが終了することはなく、許可後は自動でも再確認します。
- 「保護された入力の終了待ち」の間は、macOSの保護された入力を尊重して待機します。
  パスワード入力などが終わった後に復帰します。アプリから保護機能を無効化することはありません。
- 「再接続待ち」が続く場合は「キーボード操作を再接続」を選んでください。
  明示的な再接続では、古い押下状態とキーボード操作で保持中のマウスボタンを解放し、入力監視を作り直します。
  マウスモードはいったん終了するので、再接続後にCtrl+;で入り直してください。

監視が中断した場合はマウスモードを終了して押下状態を解放します。
変換途中の文字列と保存済みの設定・学習履歴は保持します。

入力監視の回帰検証はMacのGUI Terminalから以下を直接実行できます。
システムの権限や実際のキー入力を変更せず、実装へ障害条件を注入する23ケースです。

```sh
xcrun swiftc -swift-version 5 -parse-as-library ViMouse/InputHook.swift Tools/InputHookRecoverySmoke.swift -o /tmp/vimouse-input-hook-smoke
/tmp/vimouse-input-hook-smoke
```

## Start at login

ViMouse registers itself to start automatically when the user logs in. On macOS 13
and later this uses the system Login Items service; on older supported macOS versions
it uses `~/Library/LaunchAgents/com.s21g.ViMouse.plist`. The item can be disabled from
System Settings > General > Login Items.

## 自前変換の役物候補

役物だけの入力は端末内で変換し、変換サーバーへの通信を待ちません。
`,` は `、`・`，`、`.` は `。`・`．`・`・`を候補に含めます。
括弧、引用符、疑問符、感嘆符、長音、波線、その他の全角記号も選べ、元の入力は候補に残します。
`..`・`...` はそれぞれ `‥`・`…`も候補に含めます。
文字や数字を含む入力は従来の変換経路を使います。

## 接尾語を使う自前変換

変換中に **Ctrl+:** を押すと接尾語入力モードになります。本文と接尾語を合わせて候補を取得し、Tab/Enterでは本文に対応する部分だけを採用します。例えば `tan` → Ctrl+: → `ken` の候補 `探 │ 検` を選ぶと、確定されるのは `探` です。

本文と接尾語の境界は余白付きの薄い縦線、接尾語は青色で表示します。通常の空白文字はこのモード中だけ `␣` と表示します。これらは表示用で、確定文字列へは入りません。Deleteは接尾語を1文字ずつ削除し、空になってからもう一度押すと接尾語モードを終了します。境界を確認できない複合候補は採用せず、本文だけの候補へ戻します。Ctrl+Lまたは右矢印は従来どおり変換範囲を拡張します。

## 単語学習

未入力の変換窓で **Ctrl+K** を押すと、前回閉じた変換窓の入力を呼び出します。続けて押すと古い履歴を遡ります。入力・削除・候補選択・境界変更を行うと履歴の参照を終了し、Ctrl+Kは通常の候補選択へ戻ります。設定の「変換入力の履歴件数」は既定10件、0〜1000件で変更でき、0件にすると履歴を削除して保存を停止します。履歴はこの端末に保存し、確定・キャンセルのどちらで閉じた入力も対象とします。連続した同じ入力と空入力は重複保存しません。

候補の先頭以外を選択中に文字キーを入力すると、選択候補をTabと同じ部分確定として保持し、続く変換範囲へ入力を続けます。後続の入力があれば引き継ぎ、選択した語は部分確定の学習にも記録します。先頭候補を選択中は現在の読みへの追記を続けます。接尾語モードでは本文に対応する部分だけを部分確定します。

学習を有効にすると、Tab/Enterで確定した読みと語を1回目から端末内に保存し、次回は文脈が違っても候補へ追加します。分割確定した各語と最終的な読み・語の組も保存するため、`hojo`と`tan`から「補助探」を作った場合は、`hojotan`でも候補に出せます。接尾語モードでは捨てた接尾語を読みや確定語へ含めません。

ローマ字とひらがなの読みは同じキーに正規化します。読みはハッシュ化して保存し、確定語は端末内だけに保存します。90日・最大512件の保持、直前の学習取り消し、履歴削除、学習無効化に対応します。旧版の順位学習は残しますが、読みを保存していなかった過去の確定を単語学習へ復元することはできません。更新後に再度確定してください。

### ローカル変換とサーバー変換

設定の変換方式は「ローカル変換」が既定です。Apple Silicon・macOS 14以降では同梱の
Mozc系SDKと辞書を直接呼び出し、入力ごとに候補を更新します。デバウンスはありません。
処理はUIとは別の直列キューで行い、未処理の古い入力を省き、古い結果の表示を防ぎます。
接尾分割（Ctrl+:）とローカルの単語学習は両方式で利用できます。

候補選択中の **Ctrl+N / Ctrl+P** は、選択中の候補の文字部分を保ち、役物だけの組み合わせ集合を順送り / 逆送りします。右端の役物から変化し、端では循環します。候補行の移動は従来どおりCtrl+J / Ctrl+Kです。中黒、句読点、全角・半角、括弧、引用符、ダッシュなどが対象です。Enter / Tabは表示中の組み合わせを確定します。別の候補へ移動したり入力を編集すると組み合わせの状態をリセットします。接尾分割中は本文だけを変更します。URL、メール、バッククォートを含む候補、小数・数字間の区切り、かなに続く長音符は変更対象から除きます。役物のない候補ではビープ音だけで候補を維持します。

Intel Mac・macOS 13以前では設定で「サーバー変換」を選んでください。
サーバー方式は2秒のデバウンスを維持します。ローカルエンジンの失敗時は仮名等の候補を
表示し、設定の候補確認にエラー理由を表示します。サーバーへの自動切り替えは行いません。

ビルドには `../vimouse-ambiguous-ime/dist/vimouse-ime-macos-arm64-v2.tar.gz` が必要です。
別配置の場合は `VIMOUSE_LOCAL_SDK_ARCHIVE` で指定できます。SDKは固定SHA-256で照合し、
Xcodeのビルドフェーズでライブラリ・辞書・ライセンスをアプリに同梱します。

ローカル変換中は直前の候補表示を保ち、結果到着後に変更した行だけを更新します。
描画とサイズ計算はメインループ内でまとめ、変換中の波形アニメーションはローカル方式では表示しません。
ウィンドウは1回の入力セッション中に縮小・左右への再センタリングを行いません。
選択・確定時には最新入力の候補モデルを表示へ反映し、前の入力の候補を誤って確定しないようにします。

変換ウィンドウの文字入力は、macOSの英数キー配列と入力イベントのキーボード種別（JIS/ANSI/ISO）を使って判定します。
US固定の記号表はキー配列情報を取得できない場合のフォールバックとしてのみ使用します。
入力ソースの切り替えは行わず、かな入力ソースが選ばれていても英数配列からローマ字を読み取ります。

マウスモードの切り替えでは、上下左右の押下フラグ・移動量・加速速度をすべてリセットします。
変換モードが移動キーのキーアップを受け取った場合にも、前のモードの方向が再び有効になりません。
マウスモード開始の重複呼び出しで移動タイマーが複数作成されることも防ぎます。

接尾分割の Ctrl+: は実際のキー配列に従います。JIS配列では Ctrl+コロンキー、US配列では Ctrl+Shift+セミコロンキーです。
