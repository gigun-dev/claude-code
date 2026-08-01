# WKWebView の中身は Simulator の外(ブラウザ)で検証する

iOS アプリの中の `WKWebView` に入っている HTML/JS を検証したいとき、
**Simulator を使うのは土俵の選択を間違えている。**

- `idb` の `describe-all` は WebView 内の DOM 要素を安定して返さない
  (アクセシビリティツリーに出るのはホスト側の要素が中心)。
- XCUITest 系でも WebView 内は扱いが弱く、Maestro を含めて open issue が残っている。
- 加えて Simulator 側の不確定要素(座標系・ジェスチャ排他バンド・HID)を丸ごと背負う。

**HTML をブラウザで開けば、これら全部が消える。** ワークアラウンドの積み増しではなく、
原因そのものの回避なので投資対効果が高い(2026-08-01 track4 の実測)。

---

## 実測でカバーできた範囲(track4)

Chrome(chrome-devtools MCP)+ 自作の最小ホスト shim で、**本番の実データを使って**
以下がすべて確認できた:

| 項目 | 結果 |
|---|---|
| 本物データでの描画(グルーピング・優先度・相対日付見出しなど表示ロジック) | ✅ 実測 |
| **セレクタで要素を取る**(a11y snapshot に DOM がそのまま出る) | ✅ 実測 |
| **クリックが効く**(ホストへのツール呼び出しが正しい引数で発火することもログで確認) | ✅ 実測 |
| スクロール(`scrollTo` は**ネイティブのジェスチャ層を経由しない**) | ✅ 実測 |
| コンソールエラー / JS 例外の検知 | ✅ 実測 |
| ライト/ダークテーマ | ✅ 実測(`emulate colorScheme`) |
| 狭い幅(iPhone 相当 393px) | ✅ 実測(`resize_page`) |
| ホストが申告する値(safeAreaInsets 等)を**任意に振る** | ✅ 実測。実機では「今ホストが言ってくる値」しか試せない |

Simulator で最も詰まっていた「スワイプがジェスチャ排他バンドに吸われる」問題は、
ブラウザのスクロールがネイティブ層を通らないので**原理的に発生しない**。

---

## 手順の骨格

1. **カードの HTML を実サーバーから取る**(MCP なら `resources/read`、
   一般には配信されている静的 HTML をそのまま取得する)。
2. **ホスト側のプロトコルを最小実装した shim ページを作る。**
   実装対象はホストの SDK 実体(例: `node_modules/.../dist/src/app.js`)を直接読んで確定させる。
   track4 のケースでは postMessage 越しの JSON-RPC 4 手で足りた:
   `ui/initialize` → 結果返却 → `ui/notifications/initialized` → `ui/notifications/tool-result`。
3. iframe は **`srcdoc` で埋め込む**(`about:srcdoc` origin になり postMessage の往復が素直に通る。
   `file://` 同士の cross-origin iframe より扱いが安定した)。
4. ブラウザ自動化(chrome-devtools MCP 等)で
   `take_snapshot` / `click` / `evaluate_script` / `emulate` / `resize_page` /
   `list_console_messages` を回す。

### 実際に踏んだ落とし穴

- **モック応答が実データを上書きする。** カードが起動直後に行う背景 refetch(SWR 経路)に
  汎用の空モックを返していたため、実データが「すべて完了しました」に化けた。
  → **read 系ツールだけは初期データをそのまま echo する。**
- **書き込み系ツールはプロキシしない。** 「本番データを壊さない」を、注意ではなく
  **構造(そもそもプロキシしない実装)**で満たす。
- 本番エンドポイントに CORS ヘッダが無いと、`file://` origin からの直プロキシはブロックされる。

---

## ブラウザに移せない「残り 2 割」(いずれも推論・要 Simulator/実機)

1. **WKWebView 固有の描画差**。shim は Chrome で動くので WebKit ではない。
   フォントレンダリング・flexbox/grid の際どい差・`backdrop-filter` 等は再現しない。
2. **ネイティブのジェスチャ排他バンド、セーフエリアの実物理値、WebView の高さ制約**。
3. **ホスト⇄WebView の実 JS ブリッジの実配線**(呼び出しが本当にサーバーまで届き、
   正しい権限で実行され、応答が戻る一連)。ただしこれも**ブラウザで完結する別経路**
   (実ホストの Inspector 等)でカバーできることが多い。
4. **表示モード遷移で WebView が document を再生成する**といったホスト実装依存の挙動。
5. **iOS のソフトキーボード**に依存する編集位置の問題(デスクトップ Chrome には仮想キーボードが無く
   原理的に再現できない)。

→ **この 2 割を潰すことに時間を使うより、WebView 側をホスト非依存に保つ設計努力の方が
レバレッジが大きい**、というのが track4 の結論。
