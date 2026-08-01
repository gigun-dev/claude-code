# Skill Benchmark: ios-simulator — iteration-1

> ⚠️ **このファイルは `scripts/aggregate_benchmark.py` の生成物を人手で訂正したもの。**
> 生成直後の版は baseline を 0 とみなして `Config B 0% / Delta +0.32` と出すが、
> **without_skill は1本も走っていない**ので、それは「スキル無しなら全部 FAIL」という
> 未検証の主張になる。実測でない数字を残さない方針で N/A に置き換えた。
> **次に `aggregate_benchmark.py` を回したら、この訂正はまた消える。** baseline が
> 揃うまでは、生成のたびに delta を潰すこと(手順は `evals/README.md`)。

**Model**: 不明(2026-08-01 深夜のサブエージェント。モデル指定を記録していなかった)
**Date**: 2026-08-01(JST 深夜)
**Evals**: 1 (eval-demo-video), 2 (eval-caldav-account-sync) — **各 1 run、with_skill のみ**

## Summary

| Metric | with_skill (n=2) | without_skill | Delta |
|--------|------------------|---------------|-------|
| Pass Rate | 32% (0.32) | **未取得** | N/A |
| Time | 3240.3 s | **未取得** | N/A |
| Tokens | 231,132 | **未取得** | N/A |

## 内訳

| eval | pass | 時間 | トークン | 備考 |
|---|---|---|---|---|
| 1 eval-demo-video | 3/6 (0.50) | 3302 s | 258,665 | 成果物は得られたが、保護対象端末への誤 install を1件起こしている |
| 2 eval-caldav-account-sync | 1/7 (0.14) | 3178 s | 203,599 | **未達**。43 分で打ち切り。時間は「完遂に要した時間」ではない |

## この iteration から言えること / 言えないこと

**言える**

- スキルは 2/2 で自力ロードされた(トリガーは効いている)。失敗は SKILL.md 本文の到達性側。
- 両 run に共通して落ちた expectation は「ネットワーク操作の前にシステムプロキシを確認する」。
  事前チェックが実行順として効いていない。最も再現性のある改善対象。
- 1 run あたり 50〜55 分・20〜26 万トークン。**eval の運用コストはここで確定した。**

**言えない**

- スキルに価値があるかどうか。baseline が無いので比較対象がない。
- どの expectation が discriminating か(両構成で常に PASS するものを削る判断ができない)。
- ばらつき。1 eval あたり 1 run しかない。`stddev` は eval 間の差を見ているだけで意味がない。
