# 検証済みdiffの変更行と交差するmutantだけを選択する

Status: polished
Model: GPT-6 Astra Pro
Created: 2026-10-13
Updated: 2026-10-13
Branch: feat/diff-aware-mutation-selection
Priority: P1
Type: implementation

## 概要

`--in-diff <FILE>` でunified diffを読み、new側の追加行と編集範囲が交差するmutantだけを選択する。
Gitの実行やpatch適用はしない。差分限定の完了と、全モジュールの検証成功を区別する。
この文書は実装可能な仕様であり、機能はこのPRで実装しない。

## 背景

調査基点は turtles 0.4.6、`6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2`。

- [main.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/main.mbt): discovery、listing、fingerprint、reuseの接続。
- [runner.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/runner.mbt): target-active分割とpristine baseline。
- [fs_ops.mbt](../../cmd/turtles/fs_ops.mbt)、[iterate.mbt](../../cmd/turtles/iterate.mbt): 全入力の収集と再利用条件。
- [cargo-mutants --in-diff](https://mutants.rs/in-diff.html): 変更領域で候補を絞るモデルと、テストだけの変更を検証できない限界が参考。

## 問題

`--file` はパスの部分文字列指定で、変更行の指定ではない。`--affected` は実行するテストの選択であり、
mutantの位置を絞らない。`--iterate` も入力変更を無視する機構ではない。
不正・古いdiffを空選択へ変換すると、検証していない変更が成功に見える。

## 目標

1. hunkと現在のnew側ソースを照合し、正確なbyte範囲で選択する。
2. listing、通常実行、将来のshardで同じ選択処理を使う。
3. 空選択、対象外、target-inactive、未実行を区別し、全入力の再利用条件を維持する。

## 対象外

GitHub連携、PR自動検出、branch名解決、patch適用、coverage-based test selection、
元commit全体の同一性保証、テストのみの変更に対する完全な評価、baseline省略は対象外。
既存のsurvivor diff出力 `diff.mbt` を入力parserへ転用しない。

## 提案する方針

### CLIと対応形式

`Config.in_diff : String?` を追加する。初版はCLIだけで、TOMLキーや標準入力 `-` は追加しない。
相対的なFILEは起動時cwd基準、diff内のパスは `--dir` が選ぶモジュール基準。
値欠落、空値、重複指定、読込不能、64 MiB超の入力は終了2。引数検証とdiff検証をbaselineより先に行う。

1. 通常のGit unified diffとprefixなしunified diffを受理する。0 byteのdiffは有効な空選択。
   非空の未認識テキストを空選択へ変換しない。`diff --cc` / `diff --combined` は拒否する。
2. `---` / `+++` の対でnew側パスを選ぶ。対応するold/newが `a/` / `b/` を持つ場合だけ
   その1階層を除く。片側が `/dev/null` の場合は他側の対応する `a/` または `b/` を除く。
   `/dev/null` は特別値であり実ファイルを読まない。
   Gitの `diff --git`、rename、mode情報との不一致は拒否する。prefixを推測して探索しない。
3. Gitの引用パスは `\\`、`\"`、制御文字escape、3桁octalのbyte列として復号し、UTF-8を検証する。
   復号後のNUL・制御文字・残存backslashは拒否する。空白と非ASCII文字は許可する。
   prefixなし非引用unified headerではTAB以降だけをtimestampとして扱い、空白では分割しない。
4. 絶対パス、drive/UNC、空component、`.` / `..`、root外への解決、symlink経由のソース参照は拒否する。
   Git symlink/gitlink modeの `.mbt` も拒否する。new側が存在すべき `.mbt` の欠落はエラー。
5. 複数hunk、追加、内容変更を伴うrename、CRLF、最終改行なしを扱う。
   hunkの開始位置・行数はoverflowを検査し、省略行数は1として解釈する。
   同一newパスの重複section、逆順・重複するhunk、不整合な行数は拒否する。
6. 非 `.mbt` の通常hunkや認識済みbinary/mode-only sectionは候補を作らない。
   binary payloadはUTF-8として解釈しない。`.mbt` のbinary sectionは照合できないため終了2。
   全sectionのheaderと構造を検査し、include/excludeによって不正パスを隠さない。

### new側の検証と選択

1. パス安全検査後、既存collector規約に従い、生成物とnested module内のsectionを対象外として理由を表示する。
   root module入力となるnew側 `.mbt` のcontext行と追加行を現在のファイルへ位置どおり照合する。
   テストファイルや `--file` 等で候補から除外されるroot moduleの `.mbt` も照合対象。
   削除行の旧テキストは現在のnew側にはないため検証済みとは主張しない。
2. 行内容はbyte単位で照合する。LF/CRLFの行終端は正規化して比較し、最終改行の有無は
   `\ No newline at end of file` を含めて検証する。bare CRは行内容として扱う。
   オフセット計算には正規化前のソースbyteを使用する。
3. new行数0のhunkは削除位置の範囲だけを検証できる。contextのない削除やpure renameから
   元revisionの一致を証明しない。表示・metadataの検証範囲は常に `represented-new-side-v1` とする。
   変更がdiff外にある場合も検出保証はない。staleなcontext/追加行があれば終了2とする。
4. new側の `+` 行を、改行があればそれを含む半開byte区間へ変換して合併する。
   mutant `[start,end)` との交差は `start < line_end && line_start < end`。
   context行と削除行は選択しない。body変異は開始行でなく全spanで判定する。
5. 検証と候補生成は同一のソースsnapshotに結び付ける。実行用referenceへコピー後、
   照合対象とした全 `.mbt` のbyte一致を再確認する。listingでも確定前に同じ確認を行う。
   読み直して別内容になった場合は終了2。ユーザー作業treeをロック・変更しない。

診断はFILE、new側source path、hunk番号、期待範囲、観測した不一致/操作エラーを示す。
不一致の原因が未確定なら「古いcommit」と断定しない。fuzzy matchingは行わない。

### 共通選択処理とreport schema 4

純粋な `diff_selection.mbt` にparser・行区間・交差処理、`selection.mbt` に選択結果を置く。
名称は新設予定であり既存APIではない。既存順序を保って、次の順に適用する。

```text
path/operator/skip -> validated diff -> explicit-target active partition
                  -> optional shard -> iterate lookup -> baseline/execution
```

targetなしでは現行どおり候補をactiveとして扱う。target指定時はMoonのdry-runを一時reference内で行う。
`--list` はdry-runまでで、baseline・mutant test・report保存をしない。
`--affected` はテスト選択だけを変える。mutation/reuse配列は最終集合から構築し直し、古い添字でzipしない。

初めてこの共通変更を導入する実装で report schemaを3から4にする。他タスクが導入済みなら4を共有する。
既存フィールドを保ち、`execution: "completed"`、非空のinvocation `run_id`、nullable `diagnostics`、
次の必須 `selection` を追加する。diagnosticsは通常nullで、ログ保持を実装した版では
`{"version":1,"manifest":"runs/<run-id>/manifest.json"}` を使用する。

```json
{
  "version": 1,
  "scope": "diff",
  "discovered": 12,
  "diff_excluded": 5,
  "target_inactive": 1,
  "shard_excluded": 0,
  "selected": 6,
  "classified": 6,
  "diff": {
    "fingerprint_algorithm": "fnv1a64-v1",
    "fingerprint": "<existing fingerprint_hex(fnv1a(raw_diff_bytes))>",
    "validation": "represented-new-side-v1"
  },
  "shard": null
}
```

scopeは `configured` / `diff` / `shard` / `diff+shard`。
無指定時は `configured`、diffはnull、diff/shard除外数は0。
`discovered = diff_excluded + target_inactive + shard_excluded + selected`、
完了時は `classified = selected = mutants.length`、既存 `inactive_mutants = target_inactive`。
配置や表示の違いから全モジュールcoverageを推定しない。parserでskipしたファイルは既存の別一覧に残す。
FNV fingerprintは変更検出用であり、衝突耐性・改ざん検知は保証しない。

score式と通常終了0/1は維持する。空選択でも通常実行のbaselineは省略せず、
「選択0件・scoreは空集合上100%・全体の検証結果ではない」と表示する。
テスト/manifestのみのdiffには、`--in-diff` を外したfull runを案内する。

`--iterate` はschema 4かつexecution=completedだけを読む。schema 3/未知schema/進捗manifestはfresh run。
全sources/tests/manifests/configのfingerprint、tool versions、target、identityを照合し、
SURVIVED/TIMEOUT/amplification由来KILLEDは再利用しない。選択元がsubsetでも、
上記条件を満たす実在のKILLED/UNVIABLE行だけは再利用できる。欠けた行を補完・推定しない。

## 受け入れ条件

- [ ] Given2関数中1か所だけの追加行、when選択、then交差する演算子とbodyだけが残り、listingと実行IDが一致する。
- [ ] Given複数hunk・追加・rename・引用空白/非ASCII・CRLF・最終改行なし、when照合、then正確なbyte編集になる。
- [ ] Givencontextだけの行・pure deletion・pure rename・binary-only・test-only、when選択、then候補を捏造せずsubset/空選択を明示する。
- [ ] Givenstale行、counts不正、escape/パス不正、combined diff、source binary、読込不能、when実行、thenbaseline前に終了2。
- [ ] Given検証後のsource変更、whenreference照合、then不一致を終了2にし、完了reportを作らない。
- [ ] GivenCLI/TOML/skip/targetの組合せ、when選択、then除外理由と上記件数式が一致する。nested module/生成物は理由を表示して対象外とする。
- [ ] Given選択範囲外のtest/manifest変更、wheniterate、then再利用せずfresh分類する。
- [ ] Given空選択、when通常実行とlisting、then前者だけbaselineを実行し、100%を全体coverageと表示しない。
- [ ] Givensharding導入済み、when全shardを比較、thenunionがdiff適用後のactive集合に一致する。

## テスト計画

1. `diff_selection_wbtest.mbt` にbyte parserの正常系・全拒否条件、半開区間交差の境界/property testsを追加する。
2. `main_wbtest.mbt`、`report_wbtest.mbt`、`iterate_wbtest.mbt` に件数式・schema・再利用とリスト一致を追加する。
3. `fixtures/diff-selection/` と新設 `scripts/verify-diff-selection.mbtx` で終了コード、
   baseline呼出回数、source変更、target native/js/allを実プロセス検証する。

```sh
moon update
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon info --target native
moon run scripts/verify-diff-selection.mbtx
```

実装後の利用例。Gitは利用者が実行するものでturtlesから起動しない。

```sh
git diff --relative --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/ BASE...HEAD -- . > /tmp/turtles-change.diff
turtles --dir . --in-diff /tmp/turtles-change.diff --target native
```

BASE/HEADは利用者が選ぶrevisionで、checkoutはnew側と整合させる。
上記テスト・新規CLIはこの文書変更では未実行。snapshot更新をmutation oracleに渡さない。

## リスク

差分限定では、変更していない実装に対するテストの弱体化を検出できない。
UTF-8・Git escape・改行・検証時と実行時のsource差を重点検証する。
schema更新で以前のiterate最適化は一度失われるが、安全でない再利用よりfresh実行を優先する。

## 変更履歴

- 2026-10-13: PR #41でP1提案を作成。
- 2026-10-13: 入力形式、検証可能な範囲、byte交差、空選択、schema 4を確定しpolishedへ移動。
- 実装リリース時: `CHANGELOG.md` とREADME/helpに新CLI、対応形式、制限、schema移行を記載する。

## 注記

実装を妨げる未解決事項なし。diagnostics/boundaryとは独立に着手できる。
[sharding](20261013-deterministic-ci-sharding.md)導入後は選択helperとschemaを共有し、別の並べ替えを追加しない。
[共通索引](README.md)のMoonBit規約を適用し、新規自動化は `.mbtx` とする。
`issues/open/20261013-diff-aware-mutation-selection.md` から移動。実装完了ではない。
