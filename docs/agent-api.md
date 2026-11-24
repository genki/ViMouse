# ViMouse Agent API

メニューの「リモート操作を許可（LAN内）」でON/OFFを切り替える。初期状態はOFF。
設定 → Agent APIでも切り替えられ、接続先のIPを選んで認証URLを表示・コピーできる。
設定でのトークン更新は旧URLと待機中の操作を直ちに失効させる。
無効時にもURLは準備・コピーできるが、接続には有効化が必要。
有効状態は再起動後も保持する。トークンは256ビットの乱数で、有効期限はなく、
macOSキーチェーンに保存する。トークン更新またはAPI無効化でアクセスを止められる。

## 接続範囲

- ポート `8766`。IPv4ループバックと、稼働中の `en*` / `bridge*` の
  RFC1918 / IPv4リンクローカルアドレスに個別bindする。
- LAN接続は待受アドレスと同一サブネットのプライベートIPv4送信元だけを許可。
  `X-Forwarded-For` など転送ヘッダーは信用しない。
- IPv6、公衆IPv4、ポイントツーポイント/VPNインターフェースでは待ち受けない。
  インターフェースの変更時は接続を失効させ、待受を更新する。
- HTTP（TLSなし）。設定URLには操作権限を持つ秘密トークンが含まれるため、
  信頼できるLANとエージェントで利用する。ルーターのポート転送や外部公開プロキシは設定しない。
- 同一サブネット外の別VLANからは接続できない。IPv6のみのLANも対象外。

## API

設定画面からコピーした `http://<LAN-IP>:8766/agent/docs?token=<TOKEN>` は
認証付きJSON仕様書。すべてのエンドポイントでBearerまたはクエリtokenが必要。

| Method | Path | 内容 |
| --- | --- | --- |
| GET | `/agent/docs` | コマンド、座標系、認証方法、制限 |
| GET | `/agent/api/state` | カーソル座標、画面境界、APIが保持中のボタン、アクセシビリティ権限 |
| POST | `/agent/api/commands` | `{ "command": "…", "params": { … } }` |

```sh
curl -fsS -H "Authorization: Bearer $VIMOUSE_AGENT_TOKEN" \
  "http://$VIMOUSE_LAN_IP:8766/agent/api/state"

curl -fsS -H "Authorization: Bearer $VIMOUSE_AGENT_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"command":"cursor.move","params":{"x":300,"y":200}}' \
  "http://$VIMOUSE_LAN_IP:8766/agent/api/commands"
```

| command | params |
| --- | --- |
| `cursor.move` | 絶対座標 `{x,y}` または相対移動 `{dx,dy}`。混在不可、画面外は拒否 |
| `mouse.click` | `{button:"left"|"right"|"middle", count:1|2}`。既定は左・1回 |
| `mouse.down` | `{button:…}`。既定は左。保持中に他の押下は拒否 |
| `mouse.up` | `{button:…}`。API自身が保持しているボタンだけを解放 |
| `mouse.release` | `{}`。APIの保持ボタンをすべて解放 |
| `scroll` | `{dx,dy}`。符号付き整数ピクセル、各軸−10000〜10000 |

座標はCoreGraphicsのグローバルポイント。主画面の左上が `(0,0)`、右がx+、下がy+。
別画面には負座標がある。スクロールの正方向はCoreGraphicsのwheel1/wheel2の正方向。
ドラッグは `mouse.down` → `cursor.move`（複数可）→ `mouse.up`。
成功応答は `{ok:true,result:{…state…}}`。イベントをOSへ送ったことを表し、対象アプリの
処理完了を保証しないため、直後の座標状態には反映の遅れがあり得る。

5秒間操作がないと保持ボタンを解放する。無効化、トークン更新、ネットワーク変更、
アプリ終了でも解放する。入力イベントにはViMouseへのアクセシビリティ許可が必要。
権限がない場合は403で拒否する。

認証不正401、無効/権限/CORS拒否403、不正引数400、競合409、要求サイズ超過413。
HTTP/1.1の1接続1要求。最大64KiB、ヘッダー8KiB、受信期限5秒、同時接続16。
chunked転送、パイプライン、重複ヘッダー、ブラウザーCORSは非対応。

## 検証

MacのGUI Terminal内で実行（配布手順のGUI Terminal RPCを利用できる）。

```sh
swiftc ViMouse/RemoteAgentAPI.swift Tools/RemoteAgentSmoke.swift -o /tmp/vimouse-agent-smoke
/tmp/vimouse-agent-smoke
```

実TCPサーバーを起動し、認証・トークン更新・無効化・再bindを検証する。
プライベートIP/サブネット判定、HTTPの不正フレーミングを検査し、操作処理が生成する
イベントを捕捉して引数検証と押下解放を確認する。実カーソルへのイベント送信はしない。
テストにはポート8766が空いていることが必要。
