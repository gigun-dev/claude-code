# unslop

[heydamir/unslop](https://github.com/heydamir/unslop) の skill を原本のまま配布する。作者は Damir Sokolovsky ([@heydamir](https://x.com/heydamir))、ライセンスは CC BY 4.0（`LICENSE`）。

`skills/unslop/` は `scripts/sync_upstream_skills.py` が `vendor/upstream-skills.json` の pin から複製したもので、手で編集しない。上流に Claude Code / Codex のプラグイン定義が無いため、ADR 0004 の上流参照ではなく複製で配る。

ライブサイトのスナップショットとストーリー動画には、実行するプロジェクトで Playwright（`npm install -D playwright && npx playwright install chromium`）と ffmpeg が要る。
