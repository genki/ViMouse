# ViMouse の Space 切替経路

## バイナリ解析で確認した Dock の処理

macOS 26.5.1 の Dock と WindowManager の実装を確認すると、Space 切替は
`CGSManagedDisplaySetCurrentSpace` の単独呼び出しではない。Dock は次の状態を
組み立ててから遷移を開始する。

1. Dock 内部の `DockSpacesMessage` が切替方向を受け取る。
2. `SpaceSwitcher` / `SpaceSwitchTransition` が対象 Space とウィンドウの状態を作る。
3. WindowManager の管理接続から `RemoteTransitionCoordinator` を取得し、各ウィンドウと
   ディスプレイに `animated` 遷移を割り当てる。
4. freeform layout ではその取得に失敗するため、Dock は `LayoutControl` を取得する。
5. SLS transaction、ウィンドウ変換、表示 Space の変更をまとめてコミットし、完了後に
   `Space display finished animating` となる。

`com.apple.dock.spaces` と WindowManager の管理接続は、Apple の専用 entitlement と
Dock 内部の接続コンテキストを要求する。ViMouse から同じ Swift ABI を呼ぶ試験では
WindowManager まで到達するが、`NSCocoaErrorDomain 4101` / `4097` で応答が得られない。
Dock の Space endpoint も第三者接続を `com.apple.private.dock.spaces` 不足として拒否する。

`SLSNewTransition` などの残存エクスポートは呼び出せるが、Space の内容を Dock 標準の
スライドとして合成する経路ではない。実機のフレーム比較でも表示が段階的に移動せず、
CGS の即時切替と同じ結果になった。

## ViMouse 1.1 の実装

端のスワイプと `b+h`・`b+l` は水平の DockSwipe を使う。開始・移動・終了の各段階を
Dock に送り、macOS 27 以降では各イベントに HID データを付ける。
ジェスチャーは最初の接触時、キー操作は方向キーに割り当てた `h` または `l`
の押下時にカーソルの画面を記録する。
