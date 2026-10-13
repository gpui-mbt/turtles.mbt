# mutant集合を決定的に分割して独立したCI runnerへ割り当てる

Status: polished
Model: GPT-6 Astra Pro
Created: 2026-10-13
Updated: 2026-10-13
Branch: feat/deterministic-ci-sharding
Priority: P2
Type: implementation

## 概要

`--shard k/n` でactive候補を0始まりのshardへ割り当てる。
入力列挙順、checkout絶対path、worker数、ローカルのreuse状況に左右されない割当を定義する。
分割集合の監査材料は出力するが、global scoreの集約器や自動合格判定は追加しない。
この文書変更では機能を実装しない。

## 背景

調査基点は turtles 0.4.6、`6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2`。

- [runner.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/runner.mbt): `run_mutation_pool` は1 invocation内のactive集合をindex-aligned slotsで実行する。
- [main.mbt](../../cmd/turtles/main.mbt): listingと実行でtarget partitionの経路が分かれる。
- [config.mbt](../../cmd/turtles/config.mbt)、[iterate.mbt](../../cmd/turtles/iterate.mbt): shard入力はなく、既存reuseには全入力の一致条件がある。
- [cargo-mutants sharding](https://mutants.rs/shards.html): 0始まりk/nと全runnerで入力を揃えるモデルが参考。
  upstreamにはsliceとround-robinがあるが、turtles初版は下記のround-robinだけに限定する。

## 問題

`--jobs` は同じmachine内の並列度であり、CI runner間の割当ではない。
単純な配列切出しでは列挙順やreuseの差で重複・欠落が生じ得る。
部分scoreへ全体用thresholdを適用しても、global weighted scoreの判定にはならない。

## 目標

1. 入力が同じなら全shardで同じ候補全体・所有者を計算する。
2. sourceを変更せずbaselineとworker isolationを維持する。
3. shard別の出力・reuse・scoreを明示し、将来の監査に必要な完全identity manifestを保存する。

## 対象外

リモートworker protocol、queue、動的負荷分散、random sampling mode、baseline省略、
共有workspace/build cache、report merger、global threshold gate、artifact収集サービスは対象外。
同数のmutantで同時間になるとは保証しない。

## 提案する方針

### CLI

初版はCLIの `--shard <k>/<n>` のみ。TOMLやalgorithm切替は追加しない。
ASCII十進数字の `k/n` を受け取り、各値は0〜2,147,483,647に収まることを検査する。
`n > 0`、`0 <= k < n`。符号、空白、小数、空値、複数slash、overflow、重複指定は終了2。
先頭ゼロは許容するが、metadata/出力pathでは通常の十進表現へ正規化する。

`--shard 0/1` はactive集合の全件を選ぶ。`n > 1` と `--fail-under` の併用は
値にかかわらず終了2とし、baselineより前に拒否する。`0/1` は既存thresholdを使用できる。

### 候補集合とround-robin-v1

1. path/operator/skip、任意のvalidated diff、explicit targetのactive partitionをこの順に適用する。
   targetなしの挙動は現行と同じ。Moon dry-runは一時reference内で行う。
2. active集合を次のタプルで昇順sortする。文字列はlocale非依存のUTF-8 byte辞書順、offsetは整数順。

```text
(module-relative slash path, start byte, end byte,
 canonical group name, original UTF-8 text, replacement UTF-8 text)
```

3. pathはcaseを保持し、Unicode正規化やcheckout絶対pathを含めない。実filesystemの同一性検査とは区別する。
   同一タプルの重複、または異なるタプルが同じ既存mutation IDへ衝突した場合は終了2。
   IDを新しいアルゴリズムへ置き換えたり、重複行を黙って落としたりしない。
4. canonical順序の0始まりordinal `i` を `i % n` に割り当てる。`i % n == k` だけを実行する。
   `n` 件の空配列を先に確保せず、このinvocationの集合だけを選ぶ。
5. 分割後にその集合のreuse配列を作る。旧reuse配列の添字でfilter済みmutationをzipしない。
   jobs数や前回reportの有無は割当を変えない。shard内のreport順はcanonical順。
6. `--shard` 無指定では新sortを適用せず、既存ID・候補順序・出力pathを維持する。
   `0/1` は全件選択だが、明示shardとしてcanonical順になることをhelpへ記載する。

`selection.mbt` の共通target-resolved結果に純粋な `sharding.mbt` helperを適用する。
listingも同じhelperを使い、baseline/mutant testsやreport書込みは行わない。
通常実行では空shardにもpristine baselineを実施する。activeだが他shard所有の候補は
inactiveでも未検出でもなく、`shard_excluded` として扱う。

### 出力・依存関係

出力は `<base>/shards/<k>-of-<n>/`。
base既定値は `<module>/.turtles`、明示 `--output-dir` は起動時cwd基準。
`0/1` もこの配置を使い、通常runのreportを上書きしない。
`--iterate` はこの最終directoryのreportだけを読む。他shard/通常runのreportを自動探索しない。

先に [persistent diagnostics](20261013-persistent-run-diagnostics.md) の `OutputPlan` / 出力claim /
生成物除外helperを完成させる。helperはrawログフラグと独立して利用する。
最終shard directory全体と外部 `--json` をclaimし、同じ宛先への同時書込みはbaseline前に終了2。
異なるshard directoryは独立claim、通常runによるbase全体claimは全shardと競合する。
base配下の全shard生成物をdiscovery/copy/fingerprintから除外する。自分のshardだけの除外では不十分。

### report schema 4と監査manifest

schema 4、`execution: "completed"`、非空のinvocation `run_id`、nullable `diagnostics`、共通selectionを使用する。
diagnosticsは通常null、ログ保持時は `{"version":1,"manifest":"runs/<run-id>/manifest.json"}`。
selection version=1、scopeはshard指定時 `shard` または `diff+shard`。
`discovered = diff_excluded + target_inactive + shard_excluded + selected`、
完了時 `selected = classified = mutants.length`。既存 `inactive_mutants` はtarget-inactiveだけ。

selection.shardの必須項目は次のとおり。

```json
{
  "version": 1,
  "index": 0,
  "count": 3,
  "algorithm": "round-robin-v1",
  "partial": true,
  "universe_count": 8,
  "assigned_count": 3,
  "manifest": "manifests/<run-id>-candidates.json",
  "fingerprint_algorithm": "fnv1a64-v1",
  "candidate_fingerprint": "<canonical identity array fingerprint>"
}
```

`partial = count > 1`、`universe_count = selected + shard_excluded`、`assigned_count = selected`。
nullable diffにはraw diff fingerprintと `validation: "represented-new-side-v1"` を格納する。
無shard時はshard=null。無diff時はdiff=null。

manifestはrunごとにimmutable sidecarへ先に保存し、reportがそのpathを参照する。
内容はversion=1、algorithm、n、canonical順の各 `(id, identity tuple, ordinal, owner index)`、
入力file fingerprint map、turtles/moon version、target、effective設定とする。
`candidate_fingerprint` はidentity tupleを6要素JSON配列にした配列全体を
compact UTF-8 JSONへserializeして既存fnv1a/fingerprint_hexを適用する。
JSON objectのmap反復順やambiguousな文字列連結に依存させない。

共通入力に含めるeffective設定はinclude/exclude/file、演算子集合、diff fingerprint、target、
requested/effective test scope、timeoutとmultiplier、PBT各設定。各shard固有のindex、output絶対path、
run-id、jobs、reuse availability、実測時間は共通候補fingerprintから除外し、別の実行metadataへ記録する。
manifestの全identityを比較すれば短いhashの一致だけに依存せず欠落/重複を監査できる。
このhashはセキュリティ境界ではない。

`--iterate` はschema 4/complete reportと全入力fingerprint、tool versions、target、identityを照合する。
SURVIVED/TIMEOUT/amplification由来KILLEDは再利用しない。unknown schemaと進捗manifestはfresh実行。
subset reportの実在する再利用可能行だけを採用し、他shardの未実行行を推定しない。

### CIでの結果解釈

`n > 1` のconsole/reportは常にshard/subsetと表示する。score式は既存のkilled/viableで、
他shardを分母に入れない。`0/1` も既存filterやparse skipがあれば全ソースcoverageを保証しない。

CI例は同じrevision、toolchain、OS/runtime依存、target、diff、effective引数、nを使用し、
`0..n-1` をすべて起動する。matrixは `fail-fast: false`、成果物名にはk/nを含め、失敗時も収集する。
デフォルトの「SURVIVED/TIMEOUTがあれば失敗」というgateでは全entryの成功が必要。
欠落・failed・cancelledを成功扱いしない。単独shardの成功をglobal成功として広告しない。

全shardを結合する汎用verifierは初版に含めない。partition invariantsとfixtureのunion比較は
このタスクのテストで実装するが、任意の外部artifactを自動検証する機能とは区別する。
環境変数全体・外部サービス・native library等は完全fingerprintしていないため、
異なるmachine環境で結果が等価と保証しない。

## 受け入れ条件

- [ ] Given空/1件/多数の候補とn=1またはn>候補数、when全shardを計算、thenpairwise disjoint、union=active集合、件数差は最大1。
- [ ] Given列挙順・checkout root・jobs・reuseを変更、when同一identity集合を割当、then所有indexは一致する。
- [ ] Given等しいpath/spanでreplacementだけが違う候補、when割当、then全タプルを区別し既存IDを保つ。
- [ ] Given対象外targetやdiff除外候補、when実行、then各除外理由を分離し、他shardをinactive/outcomeへ混入させない。
- [ ] Given決定的fixture、whenunshardedと全shardを実行、then結合したID/outcome mapが一致する。時間と順序は比較対象外。
- [ ] Given空shard、when通常実行、thenbaselineを実施してselected=0と明示する。listingではbaselineを実行しない。
- [ ] Given不正syntax/overflow/重複指定またはn>1とfail-under、when実行、thenbaseline前に終了2。
- [ ] Given並列shardと共有JSON宛先、when出力予約、then衝突を安全に拒否する。別宛先では互いの成果物/reuseを上書きしない。
- [ ] Given異なるn・候補・設定・欠落index、whenmanifestをテスト用照合、then不整合を判別できる。CLIが汎用集約済みと表示しない。
- [ ] Given--shardなし、when既存suite、thenID/順序/path/threshold/target forwarding/reuse guardsを維持する（schema移行を除く）。

## テスト計画

1. 新設 `sharding_wbtest.mbt` に決定性、byte順、numeric offset順、disjoint/union/property testsを追加する。
2. config/main/report/iterateの既存テストへ入力境界、全件/空件、metadata、schema migrationを追加する。
3. `scripts/verify-sharding.mbtx` を新設し、`fixtures/basic` と `fixtures/targets` の独立複製を用いて
   unsharded・全shard・並行出力を比較する。diff実装済みならdiffとの組合せも必須とする。

```sh
moon update
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon info --target native
moon run scripts/verify-sharding.mbtx
```

E2Eは期待したCLI終了1もassertし、単純な終了0だけをテスト成功としない。
新規自動化は `.mbtx`、snapshot更新フラグはmutation oracleへ渡さない。
このdocs-only変更では上記は未実行。

## リスク

baselineの重複で総computeが増える。count均等でも時間均等とは限らない。
異なる環境・設定・nの混在、短いfingerprintの衝突、共有出力競合を検証する。
速度向上は同じfixture/toolchain/machine条件で測定するまで主張しない。

## 変更履歴

- 2026-10-13: PR #41でP2提案を作成。
- 2026-10-13: input bounds、canonical割当、manifest形式、CI gate、所有権依存を確定しpolishedへ移動。
- 実装リリース時: `CHANGELOG.md`、CLI/README、matrix例、partial score、schema移行を記載する。

## 注記

実装を妨げる未解決の設計事項なし。純粋な割当処理は着手可能。
runner/output統合はdiagnostics側のownership helper完成後。diffは必須依存ではなく、存在する場合の結合を必須とする。
[共通索引](README.md)のMoonBit規約を適用する。
`issues/open/20261013-deterministic-ci-sharding.md` から移動。実装完了ではない。
