# Polished implementation tasks

状態: 2026-10-13、PR #41の4件を `open` から `polished` へ移動。
仕様と検証計画は実装着手可能。機能の実装・テスト完了を示す状態ではない。
source基点は [6f5e06a](https://github.com/gpui-mbt/turtles.mbt/commit/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2)
（turtles 0.4.6）。PRの初期HEADは `6dffe4e07822910e48b441cfc4359508104245f2`。

## 実装順と依存関係

| 優先度 | タスク | 確定した中心契約 | 着手条件 |
| --- | --- | --- | --- |
| P1 | [境界値変異](20261013-comparison-boundary-mutations.md) | 4変異、オプトイン、既存ID/順序維持 | 独立 |
| P1 | [差分限定選択](20261013-diff-aware-mutation-selection.md) | new側照合、byte交差、schema 4、subset表示 | 独立。共通selection変更を調整 |
| P1 | [永続診断](20261013-persistent-run-diagnostics.md) | phase証拠、保存上限、lifecycle、出力claim | 独立。ownership/生成物除外を先に実装 |
| P2 | [CI sharding](20261013-deterministic-ci-sharding.md) | round-robin-v1、全identity manifest、部分gate | pure helperは着手可。runner統合はownership完成後 |

1. boundaryとdiffはそれぞれ着手できる。diagnosticsは出力所有権/除外とログ保持を分けて実装する。
2. shardingはdiagnosticsのownership helperを利用する。`--retain-logs` の有効化は要求しない。
3. diffはshardingの必須先行依存ではないが、両方が存在する版では組合せテストが必須。
4. source変更前にcurrent mainと関連PRを再確認する。設計判断を覆す変更があれば該当issueをopenへ戻し理由を記録する。

## コードベースの対応表

| 責務 | 実装 |
| --- | --- |
| CLI/TOML・実行接続 | [config.mbt](../../cmd/turtles/config.mbt)、[main.mbt](../../cmd/turtles/main.mbt)、[types.mbt](../../cmd/turtles/types.mbt) |
| AST候補・byte範囲・skip/body | [scanner.mbt](../../cmd/turtles/scanner.mbt)、[parser境界](../../docs/moonbit-parser.md) |
| 一時reference・worker復元・check/test・timeout | [runner.mbt](../../cmd/turtles/runner.mbt)、[fs_ops.mbt](../../cmd/turtles/fs_ops.mbt) |
| target-active/観測package | [plan.mbt](../../cmd/turtles/plan.mbt) |
| kill attribution / PBT analysis | [oracle.mbt](../../cmd/turtles/oracle.mbt)、[amplify.mbt](../../cmd/turtles/amplify.mbt) |
| 完了report・survivor差分・再利用 | [report.mbt](../../cmd/turtles/report.mbt)、[iterate.mbt](../../cmd/turtles/iterate.mbt) |

通常経路は設定、AST discovery、target/test planning、pristine baseline、隔離したmutant分類、
任意のsurvivor analysis、report/exit。listingはbaseline前で止まる。
実行packageは [cmd/turtles/moon.pkg](../../cmd/turtles/moon.pkg)、moduleは [moon.mod](../../moon.mod)。
source調査に基づく対応表であり、新しいruntime qualificationではない。

## 比較調査と重複整理

[cargo-mutants book](https://mutants.rs/) のmutation、selection、output、baseline/workspace、
iteration、timeouts、performance、shardingを参考に、MoonBit向けに対象を限定した。

| 領域 | 調査基点のturtles | 今回の判断 |
| --- | --- | --- |
| AST、Boolean/arithmetic/comparison | 実装済み | opt-in boundaryだけ追加 |
| body置換・skip annotation | 実装済み。bodyはopt-in | 基本機能を再提案しない |
| jobs・warm workspace・baseline | 実装済み | isolation/順序を維持 |
| target・affected | 実装済み | Moonのplanを独自推定で置換しない |
| iterate・adaptive timeout | 実装済み | 全入力reuse guardを維持 |
| JSON、ID、survivor diff、kill attribution、PBT | 実装済み | reportを重複新設せず診断証拠を追加 |
| 変更行限定・独立runner分割・永続phase logs | 対応CLIなし | 本4件の追加対象 |
| Rust固有Cargo/nextest/Default | MoonBit APIではない | そのまま移植しない |
| in-place・baseline bypass | 今回の対象外 | pristine oracleを弱めない |
| JUnit、context表示、既定test scope変更 | follow-up候補 | 今回の暗黙の実装対象にしない |

個別参考は [boundary](https://mutants.rs/changelog.html)、[diff](https://mutants.rs/in-diff.html)、
[output](https://mutants.rs/mutants-out.html)、[sharding](https://mutants.rs/shards.html)。
upstream仕様と、今回決定したturtles固有仕様を混同しない。

PR #41作成時の調査ではopen/polishedは索引のみだった。既存
[PR #29](https://github.com/gpui-mbt/turtles.mbt/pull/29)のprocess cleanupを重複提案しない。
platform cleanupの新しいコードがmainにあるため、昔の症状を新規再現済み障害と記載しない。
過去の完了/保留範囲は [practical value](../closed/20260928-practical-value-milestone.md)、
[MoonBit/PBT](../closed/20260929-moonbit-idioms-and-pbt-integration.md)、
[survivor analysis](../closed/20260930-pbt-survivor-analysis.md)、
[target-aware](../closed/20260930-target-aware-mutation-testing.md) を参照する。
過去milestoneの保留事項を、今回一括で完了したものとして扱わない。

## 共通選択とreport契約

```text
path/operator/skip -> optional validated diff -> explicit-target active set
                  -> optional shard -> iterate -> baseline/classification/analysis
```

1. listingと実行は同じhelperを使用する。targetなしは現行どおり。target指定時のMoon planは一時reference内で取得する。
2. 全sources/tests/manifests/configのfingerprintを保持し、subsetによって入力集合を狭めない。
   generated outputはsource/copy/fingerprintから除外する。
3. diff除外、target-inactive、他shard所有、未実行を別扱いにする。subset完了とexecution未完了を混同しない。
4. boundary単独ではschema形を変更しない。diff/diagnostics/shardingが初めて共通report拡張を導入するとき3から4へ移行し、後続も4を使う。
5. schema 4は既存report fieldsに `execution: "completed"`、非空 `run_id`、nullable `diagnostics`、`selection` を追加する。
   run_idはrawログ有無にかかわらずinvocationを識別する。diagnosticsはnullまたは
   `{"version":1,"manifest":"runs/<run-id>/manifest.json"}`。
6. selection version=1。scopeはconfigured/diff/shard/diff+shard。discovered、diff_excluded、target_inactive、
   shard_excluded、selected、classifiedとnullable diff/shardを持つ。
   `discovered = diff_excluded + target_inactive + shard_excluded + selected`、完了時 `selected = classified = mutants.length`。
7. schema 4のcomplete reportだけをiterate対象にする。旧/未知schemaと進捗manifestはfresh扱い。
   tool versions/target/全入力/identityの照合と、SURVIVED/TIMEOUT/amplified killの再利用禁止を維持する。
   subset由来でも条件を満たす実在行は再利用可能であり、欠けた候補を補完しない。
8. `configured` も既存filterやparse skipを含み得るため「全sourceのcoverage保証」とは表示しない。
   完了した実行の終了1と、setup/outputの終了2を区別する。公開後export失敗の扱いはdiagnostics仕様に従う。

## MoonBit implementation rules

基準は公式 [agent guide](https://github.com/moonbitlang/skills/blob/8b9f1bad14bc62560dbe3537855379e561a4e066/skills/moonbit-agent-guide/SKILL.md)。

1. enclosing moon.mod/moon.pkgを確認する。file名はnamespaceではない。小さな責務別fileと `///|` を使い、parser型はscanner内へ閉じ込める。
2. 実toolchainの `moon ide doc` / outline / peek-defでAPIを確認する。parser、range、割当、lifecycleはowned型の純粋helperへ分ける。
3. UTF-8 byte、Unicode scalar、String indexingを混同しない。正規表現でMoonBit文法を推測しない。
4. private helperは `*_wbtest.mbt`、公開APIはblack-box/doc testsを使う。テスト名は観測動作を記述する。
   deterministic propertyとレビュー済みsnapshotを使う。
5. 新規オーケストレーションは `.mbtx`。新たなshell/Python companionをリポジトリへ追加しない。
   Asyncにawaitや不要なraiseを追加しない。
6. fmt/check/test/infoを実施し、生成mbtiを手編集しない。mutation oracleへ `--update` / `-u` を渡さない。
7. codeはHow、testsはWhat、commit messageはWhy、commentは非自明なWhy notを記載する。

## Verification plan

以下は将来の実装検証であり、この文書PRの実行結果ではない。

```sh
git diff --check
moon update
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon info --target native
moon -C fixtures/basic test
moon run cmd/turtles -- --dir fixtures/basic --timeout 30
```

各issueが指定する新設 `.mbtx` E2Eも実施する。期待survivorがあるCLI終了1は期待値と照合する。
turtles実行体のnative buildと、被験projectのnative/js/allを分けて記録する。
process/filesystem変更は既存のnative platform matrixで検証する。PASS/FAIL/未実行を区別する。

## Workflow

1. 未整理/新規の問題は [open](../open/) へ置く。
2. 仕様・依存・受入条件・テスト計画が確定したissueをここへ移す。
3. 実装と検証が完了したissueは証拠を記録し [closed](../closed/) へ移す。
