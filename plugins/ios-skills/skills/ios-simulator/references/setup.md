# 導入(idb の2コンポーネント)

**開くタイミング**: `idb` が入っていない / `idb list-targets` に端末が出ない /
`No Companion Connected` のまま `idb ui *` が無反応。**それ以外では開かなくてよい**
(導入済みの環境なら SKILL.md 本文の事前チェックだけで足りる)。

---

## 必要なもの

- **フル Xcode**(Command Line Tools だけでは idb-companion がビルド・動作しない)。
  `xcrun simctl list devices booted` が動くこと。
- **idb は2コンポーネントある**。片方だけ入れて「idb を入れた」と思い込むのが最初の罠:
  - **`idb-companion`**(ネイティブ gRPC デーモン。端末側に張り付く)
    → **nixpkgs にある**(`idb-companion`, aarch64-darwin)。dotfiles の nix で入れるのが推奨。
      Homebrew の `idb-companion` でも可。
  - **`fb-idb`**(Python 製 CLI。`idb ui tap` 等を叩く側)← **nixpkgs に無い**
    ```bash
    uv tool install fb-idb        # => ~/.local/bin/idb
    ```

## 初回のアタッチ

```bash
idb connect <UDID>              # ← UDID を明示する
idb list-targets                # Booted な simulator と companion socket を確認
```

`idb list-targets` の該当行が `... | /tmp/idb/<UDID>_companion.sock` になっていれば繋がっている。

> **⚠️ `idb connect`(引数なし)ではアタッチされない(2026-07-31 訂正)。**
> 本スキルの旧版はそう書いていたが、fb-idb の現行 CLI では効かない。該当行が
> `No Companion Connected` のままになり、**以降の `idb ui *` がエラーも出さずに無反応**になる。
> 「idb が壊れている」に見えるが、単に繋がっていないだけ。
>
> **Why not 引数なしを残さないか**: 無反応の症状が「タップが無言で失敗する」(SKILL.md の
> ハマりどころ 1)と区別が付かず、誤診の起点になる。まず `list-targets` で socket を見る。

## idb 無しでどこまでやれるか

**screenshot / launch / openurl / pbcopy は `xcrun simctl` だけで動く。**
idb が要るのは **tap / swipe / text / button とアクセシビリティ走査**だけ。
= 「アプリを起動して画面を撮るだけ」の検証なら idb の導入を待たずに始められる。
