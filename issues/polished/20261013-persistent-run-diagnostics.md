# 一時workspaceとは独立して実行診断とphaseログを保存する

Status: polished
Model: GPT-6 Astra Pro
Created: 2026-10-13
Updated: 2026-10-13
Branch: feat/persistent-run-diagnostics
Priority: P1
Type: implementation

## 概要

`--retain-logs` でbaseline・mutant・PBTのコマンド証拠を上限付きで保存する。
進捗、完了した分類、出力公開、品質ゲートの結果を区別する。
出力所有権の保護はフラグに依存させず、将来のCI shardingからも利用できるようにする。
このPRは文書変更のみであり、診断機能を実装しない。

## 背景

調査基点は turtles 0.4.6、`6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2`。

- [runner.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/runner.mbt): `run_moon_command` はworkspace隣の同じログを再利用し、外側のtmpdirは終了時に消える。
- [main.mbt](../../cmd/turtles/main.mbt)、[report.mbt](../../cmd/turtles/report.mbt): runner復帰後にreportと関連成果物を書き込む。
- [types.mbt](../../cmd/turtles/types.mbt): `CommandResult` はsuccess/failure/timeoutのみでprocess metadataを持たない。
- [cargo-mutants artifacts](https://mutants.rs/mutants-out.html): baseline/mutant logs、進捗、出力lockの価値が参考。ファイル形式の互換性は要求しない。

## 問題

timeoutやattribution不足を後から調査しにくい。baseline失敗時は以前のreportが残るため、
それを今回の成功と誤読するおそれがある。ログの単純コピーではphase上書き、並列競合、
無制限の保存、部分結果の再利用を防げない。

## 目標

1. 実行したコマンドだけをphase/attempt単位で識別し、失敗時にも証拠を残す。
2. 未完了の進捗をreportや `--iterate` へ流用しない。
3. 生成物をsource/fingerprintから除外し、安全な出力所有権を提供する。
4. 既存の分類・attribution・プロセスcleanupを変えない。

## 対象外

部分実行のresume、web UI、JUnit/SARIF、リモートupload、自動秘匿化、全workspace保存、
新しいprocess supervisor、SIGKILL/電源断後の最終状態書込み保証は対象外。
複数filesystem上のファイルを一括でatomic commitする仕組みは導入しない。

## 提案する方針

### CLIと保存内容

初版は値なし `--retain-logs` だけを追加する。TOML・保存上限指定・自動世代削除は追加しない。
`--list` と併用しても実行用出力を作らず、ログ保存が対象外であることを表示する。
相対 `--output-dir` / `--json` は既存どおり起動時cwd基準、既定出力は `<module>/.turtles`。

実行前に `runs/<run-id>/` を排他的に作成する。run-idはUTC時刻とランダムsuffixを用い、
衝突した場合は再生成する。IDを時刻だけやPIDだけから決定しない。

```text
<output>/runs/<run-id>/
  manifest.json
  commands/<command-id>.json
  logs/<command-id>.log
  artifacts/                  # このrunに属する成果物の保持用copy
```

command-idはrun内の単調増加番号。metadataに `mutant_identity`（baseline等はnull）、
`phase`、1始まりのattemptを必ず保存する。ファイル名にsource pathを埋め込まない。
phaseは `plan` / `baseline-check` / `baseline-test` / `mutant-check` / `mutant-test` /
`amplify-check` / `amplify-test` / `witness` とし、実装がさらに分割する場合はmanifest versionを扱う。
初期version取得やtimeout helper probeはこの初版のraw保持対象外と明記する。

各commandはexact executable/argv配列、cwd、target、package scope、開始・終了時刻、単調時計によるduration、
command classification、観測できたexit code/signal、保持byte数、元byte数またはunknown、truncation理由を記録する。
wrapperのexit codeとMoon本体のexit codeは分け、観測していない内側の値を推定しない。
baseline-testは通常2回だが、1回目timeout等で2回目を実行していなければ架空のログを作らない。

### 捕捉位置・上限

1. 共通command runnerへ診断contextを渡す。phase/attemptは呼出側が指定し、worker番号から推測しない。
   dry-run planningにも同じ記録sinkを渡す。sourceコピー以前の失敗はrun-level errorとして扱う。
2. 次のcommandがログを上書きする前に証拠を保持する。attributionの完全な入力は維持し、
   保存用切詰めを `last_test_failures` やbaseline安定性判定の入力へ適用しない。
3. retained raw bytesは1 invocationあたり先頭1,048,576 bytes、run合計67,108,864 bytesまで。
   出力総量に比例した追加bufferは作らずchunk copyする。並列workerは共有budgetを原子的に予約する。
   合計を超えたcommandもmetadataは保存し、`per-command-limit` / `run-limit` を区別する。
4. これは保存raw outputの上限であり、Moonの一時ログやmetadata総量の上限ではない。
   バイト境界で切るため末尾UTF-8は不完全になり得る。rawファイルを暗黙に修復しない。
5. 再利用行は `reused: true`、出典report/identity、`commands: []` を記録する。
   新しい実行時間・argv・現在runのlogを捏造しない。

### lifecycleと公開境界

manifest schemaは独立した `version: 1` とする。
`state` は `running` / `completed` / `failed` / `cancelled`。
`stage` はsetup、baseline、classification、analysis、publicationを区別する。
一度分類されたSURVIVEDでもamplify等が未完了なら最終分類とはしない。
`quality_exit_code` は通常のscore判定0/1、`process_exit_code` は実際のCLI結果、
`publication` は各出力先のpending/published/failed/unknownを表す。

- baseline/setup/worker/必須診断保存の失敗は、公開前ならfailed・終了2。以前のreportを置換しない。
- 制御されたcancelはcancelledとしcleanupを行う。既存CLIの終了規約を維持し、保存できた実値だけを記録する。
- 全候補とanalysisを終え、canonical `report.json` を公開したrunはcompleted。
  SURVIVED/TIMEOUTやthreshold未達による終了1もcompletedであり、成功ゲートを意味しない。
- hard crash後に残るrunningはunfinished/liveness unknownであり、PIDが生きている証拠ではない。

全candidate分類・analysisと保持用成果物を準備してから、同じdirectory内のtemp fileをrenameして
canonical `report.json` を置換する。これを完了reportの公開点とし、その前に部分reportを置かない。
manifest/command metadataも個別のatomic replaceを使う。破損JSONを読者へ公開しない。
保持用 `artifacts/` とrun-idによって以前のrunの証拠も辿れるようにする。

複数出力への一括atomicityは保証しない。canonical公開後の `--json` exportや表示用copyの失敗は
「completed execution / publication error」と記録し、CLIは終了2とする。
既に公開した完全なreportを不完全と偽らず、出力先と失敗した操作を明示する。
この区別により、実行失敗の部分reportと、実行完了後のexport失敗を混同しない。
manifest更新自体が失敗したときはstderrで公開済みrun-idと最後に確認できた状態を示す。

report schema 4に `execution: "completed"`、`run_id`、nullable `diagnostics` を追加する。
`run_id` はraw保持の有無にかかわらずinvocationを識別する非空文字列。
`diagnostics` は `{"version":1,"manifest":"runs/<run-id>/manifest.json"}`、raw保持なしではnull。
共通 `selection.version=1` はscope、discovered、diff_excluded、target_inactive、shard_excluded、
selected、classified、nullable diff/shardを持ち、件数式は
`discovered = diff_excluded + target_inactive + shard_excluded + selected`。
完了時は `selected = classified = mutants.length`。schema 4が既にあれば同じ契約へ統合する。
`--iterate` はcomplete reportのみを読み、進捗JSONは読まない。schema 3/未知schemaはfresh実行。
全入力fingerprint/tool versions/target/identityと既存のoutcome再利用制限を維持する。

### 出力所有権: retain-logsに依存しない共通helper

対応範囲は同一OSユーザーによるローカルfilesystemへの協調的な同時実行。
ネットワークfilesystemの分散lockや悪意ある別processへの防御は保証しない。

1. `OutputPlan` で出力root全体と外部JSONのexact pathを解決する。同じcanonical `report.json` を
   `--json` に指定した場合は1宛先へまとめる。他の予約済みartifact pathとの衝突は終了2。
2. root外/内いずれもcanonical pathを使用し、Windowsの同一path表記差を同一資源として扱う。
   未作成pathは既存親を解決する。symlink/reparse-point経由の出力は拒否する。
   module root・その祖先、入力source/manifest、sourceを含むdirectoryを出力として予約しない。
3. OSのユーザー専用cache領域に共通claim registryを置く。短時間の排他的mkdir guard下で
   全claimの追加/削除を行い、activeなdirectory同士の祖先/子孫重複とexact-file重複を検査する。
   複数宛先は一括でclaimし、一部だけ確保した状態で実行を開始しない。
4. registry guardは処理後に解放し、実行中はclaimだけを保持する。stale guard/claimをPIDだけで盗まない。
   異常終了後は利用者が該当runの終了を確認して回復する。エラーにはclaim path、run-id、
   owner metadataと手動回復手順を表示する。自動削除フラグは追加しない。
5. claim取得はbaselineと成果物変更より前、解放は子process cleanupと出力処理より後。
   ログ無効でも適用する。OS path/cache API不足の場合は狭いnative helperで補い、lockを黙って省略しない。

shardでは出力base自体でなく `<base>/shards/<k>-of-<n>/` を予約する。
通常runによるbase全体のclaimとは競合するが、異なるshard同士は競合しない。
これにより同一JSON宛先、通常runとshard、異なるmoduleからの出力衝突も保護する。

### source保護・実装箇所

出力planはdiscovery/copy/fingerprint以前に解決する。
既存生成物も含め予約output treeとJSON/lock metadataを明示的に除外し、path/operatorフィルタで
入力fingerprint自体を狭めない。custom出力内の生成 `.mbt` が再入力されないことを検証する。
stale artifactの削除はturtlesの生成marker/所有manifestで確認できるファイルに限定する。
拡張子が同じだけの利用者ファイルを削除せず、以前のreportとrunの証拠を保持する。
raw logには秘密が含まれ得る。POSIXはuser-only permission、Windowsはuser-private ACLの領域を使い、
環境変数dump・自動upload・秘匿化済みとの表示をしない。

新設 `diagnostics.mbt` / `output_ownership.mbt` と既存runner/main/report/fs_ops/plan/typesへ接続する。
GNU timeout、Darwin supervisor、Windows Job Objectの停止・wait・cleanup順は維持する。
cleanupをdiagnostic errorで短絡しない。[PR #29](https://github.com/gpui-mbt/turtles.mbt/pull/29)のprocess cleanupを再提案しない。

## 受け入れ条件

- [ ] Givenbaseline失敗/timeout/不安定、when実行、then実在するattemptのログを保持し、終了2、以前のreportは不変。
- [ ] Given並列分類とPBT、whenログ保持あり/なしで実行、then最終ID/outcome/attributionが一致しphaseが混線しない。
- [ ] Given分類途中の制御失敗/cancel、when終了、then進捗だけを残し、新しいcomplete reportを公開しない。
- [ ] Given完全分類後にSURVIVEDがある、when通常ゲート、thenstate=completed、quality_exit_code=1となる。
- [ ] Givencanonical公開後のexport失敗、when終了、then完全reportを保持しpublication errorとCLI終了2を明示する。
- [ ] Given同一/祖先子孫/alias宛先への同時実行、whenclaim、then片方がbaseline前に安全に拒否される。
  異なるshard宛先は並行可能。部分claim漏れ・deadlock・無関係ファイル削除がない。
- [ ] Givenhard crashのclaim、when次回実行、then自動奪取せずliveness unknownと回復手順を示す。
- [ ] Given上限超えログ、when並列保持、thenraw総量とinvocation上限を守り、完全attributionは変化しない。
- [ ] Given再利用候補、wheniterate、then架空logを作らず、partial manifestを再利用しない。
- [ ] Givencustom出力がmodule内にある、when次回scan/fingerprint、then生成物を入力へ混入させない。

## テスト計画

純粋なlifecycle/budget/claim重複テストを `diagnostics_wbtest.mbt` / `output_ownership_wbtest.mbt` に追加する。
新設 `scripts/verify-diagnostics.mbtx` は実プロセス2本の衝突、権限不足、rename/export失敗、
baseline failure、timeout、cancel、oversized output、stale claimを一時領域で検証する。
異常注入はtest専用seamとし、通常ユーザー向け故障フラグは追加しない。

```sh
moon update
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon info --target native
moon run scripts/verify-diagnostics.mbtx
```

Linux・macOS・Windowsの既存native CI matrixでprocess/filesystem E2Eを実行する。
対象環境がない検証は未実行として残す。このdocs-only変更では上記は未実行。

## リスク

診断自体の書込み失敗、ログ内の秘密、stale claim、path alias、保存容量が主なリスク。
保存失敗をPASSとせず、場所・観測した操作エラー・回復方法を表示する。
runの自動削除はないため、利用者が過去runを手動整理する必要がある。
report schema移行では以前のiterate cacheをfresh扱いする。

## 変更履歴

- 2026-10-13: PR #41でP1提案を作成。
- 2026-10-13: phase、上限、lifecycle/公開後失敗、claim、schema移行、実環境試験を確定しpolishedへ移動。
- 実装リリース時: `CHANGELOG.md`、help、保存形式、秘密/容量、stale claimの回復手順を更新する。

## 注記

実装を妨げる未解決事項なし。まず出力所有権と生成物除外、次に診断捕捉・公開・E2Eの順で着手する。
[sharding](20261013-deterministic-ci-sharding.md)は所有権helperの完成に依存するが、rawログ保持は要求しない。
[共通索引](README.md)のMoonBit規約を適用し、新規自動化は `.mbtx` とする。
`issues/open/20261013-persistent-run-diagnostics.md` から移動。実装完了ではない。
