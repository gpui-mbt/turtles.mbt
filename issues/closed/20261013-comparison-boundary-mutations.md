# 比較演算子の境界値変異をオプトインで追加する

Status: closed (implemented 2026-10-20)
Model: GPT-6 Astra Pro
Created: 2026-10-13
Updated: 2026-10-20
Branch: feat/comparison-boundary-mutations
Priority: P1
Type: implementation

## 概要

`boundary` グループを追加し、等号が成立する入力だけで差が出る比較変異を生成する。
既定の変異集合・順序・既存IDは変更しない。この文書は実装仕様であり、機能の実装完了を示さない。

## 背景

調査基点は turtles 0.4.6、`6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2`。
PR #41 の初期HEAD `6dffe4e07822910e48b441cfc4359508104245f2` でも実装は同一。

- [scanner.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/scanner.mbt): `operator_specs`、`record_operator`、`record`、重複抑止。
- [types.mbt](https://github.com/gpui-mbt/turtles.mbt/blob/6f5e06a70e7de1b49a3249f1d91a98e5f0f7e2b2/cmd/turtles/types.mbt): グループ変換、`ProjectConfig::operator_enabled`。
- [scanner_wbtest.mbt](../../cmd/turtles/scanner_wbtest.mbt)、[config_wbtest.mbt](../../cmd/turtles/config_wbtest.mbt): 既存の候補生成・既定値テスト。
- [cargo-mutants 25.1.0](https://mutants.rs/changelog.html): `< -> <=` と `> -> >=` の導入が参考。本仕様の逆方向2種は turtles 側の追加判断。

## 問題

`x < 10` に対して9と11だけを検証していると、既存の `< -> >` は検出できても
`< -> <=` は検出できない。`record_operator` は最初に一致した仕様で停止するため、
単に同じ original の項目を追加しても一対多の変異は生成されない。
また既定値の `None => group != Body` を維持すると、新グループが意図せず有効になる。

## 目標

1. 次の4変異を、明示された場合だけ生成する。
2. 比較反転と境界値変異を同時に指定でき、境界値だけでも生成できる。
3. AST位置、UTF-8編集、skip、可視性、target、再利用の既存安全条件を維持する。

## 対象外

数値リテラル変異、算術・ビット演算の拡張、型推論、parser更新、既定グループの拡大、
新しい outcome、score式の変更は行わない。NaNやユーザー定義演算子に対し、
等価性・型適合性・必ず検出できることは保証しない。`moon check` が適合性の判定元である。

## 提案する方針

### 入力と変異表

| original | replacement | group |
| --- | --- | --- |
| `<` | `<=` | `boundary` |
| `>` | `>=` | `boundary` |
| `<=` | `<` | `boundary` |
| `>=` | `>` | `boundary` |

`--operators boundary` と `turtles.toml` の `operators = ["boundary"]` を受理する。
初版の新しい綴りは `boundary` のみ。既存aliasは維持する。
CLI指定はTOMLの演算子リスト全体を置換し、両者を暗黙にマージしない。
未指定時は Comparison / Boolean / Arithmetic / Literal / Condition だけを有効にし、
Body / Boundary は無効とする。既存の明示的な空リストの意味も変更しない。

```sh
# 実装後の利用例。現時点の実行結果ではない。
turtles --dir . --operators boundary --list
turtles --dir . --operators comparison,boundary --target native
```

### 生成と互換性

1. `OperatorGroup` に Boundary を追加し、変換・help・configエラー文を更新する。
2. `operator_specs` の既存項目の順序を保ち、末尾へ上記表の順に追加する。
   `record_operator` は original が一致する全仕様を表順に `record` へ渡す。
   無効グループに一致しても探索を終了しない。
3. 同じAST位置では既存 comparison が先、boundary が後になる。
   CLIでグループを指定する順番は生成順に影響しない。
4. `record` による元テキスト照合と Unicode scalar -> UTF-8 byte の変換を維持する。
   演算子以外の空白・コメント・改行を変更しない。`<=` の一部だけを `<` として扱わない。
5. 重複判定は既存の path / start / end / replacement のまま。
   ID生成の既存タプル・ハッシュは変更せず、新グループを既存IDへ混入させない。
   一対多化を理由に既存候補全体を再ソートしない。
6. レポートでは `group: "boundary"` を使用する。既存の4 outcome、visibility、
   target-inactive、`killed_by`、PBT処理を変更しない。

### 実装箇所・移行

`cmd/turtles/{scanner,types,config}.mbt` と対応する `*_wbtest.mbt`、CLI説明を変更する。
`main.mbt` のCLI/TOML優先順位は維持する。parser型をrunnerへ公開せず、lexical fallbackを追加しない。
新規E2E fixture は `fixtures/boundary/`、実行用 `.mbtx` は `scripts/verify-boundary.mbtx` とする。

この機能単独では report schema 3 の形を変更しない。別タスクでschema 4に移行済みなら4を維持する。
リリース時は通常の版更新を行い、`--iterate` の turtles/moon version、target、全入力fingerprint、
mutant identity の照合を維持する。SURVIVED / TIMEOUT / amplification由来KILLEDは再利用しない。

## 受け入れ条件

- [ ] Given 4種類の比較だけを含むソース、when boundaryだけでscan、then 上記4候補だけが生成される。
- [ ] Given comparisonとboundary、when両方有効、then各位置で既存反転と境界値変異が1件ずつ生成される。
- [ ] Given既定設定または既存グループの明示設定、when新旧scan結果を比較、then全既存ID・候補数・順序が一致する。
- [ ] Given CLI/TOMLの競合と指定順反転、when設定を適用、thenCLI優先と固定生成順を維持する。
- [ ] Given各比較関数に閾値の前後だけのテスト、when変異実行、then対応boundaryはSURVIVED。
  等値テスト追加後は同じ4つがKILLEDになる。テスト追加による再利用無効化も確認する。
- [ ] Given非ASCII文字、CRLF、入れ子式、skip宣言、コメント・文字列、when scan/apply、then正確なbyte範囲だけを編集する。
- [ ] Given target fixture、when native / js / allでlistingと実行、then有効候補が一致し、inactiveをSURVIVEDにしない。
- [ ] Given決定的fixture、when jobs=1と並列で実行、thenIDとoutcomeが一致する。実測時間は比較対象外。
- [ ] Given保存レポート、when再読込・iterate、thenboundaryを復元でき、既存の不正・古い報告拒否条件を維持する。

## テスト計画

1. `scanner_wbtest.mbt` に表駆動・一対多・byte範囲テスト、`config_wbtest.mbt` に既定値と選択テストを追加する。
2. fixtureは独立した4関数に分け、等値テストなし/ありで期待IDとoutcomeを厳密に検証する。
   実行オーケストレーションは `.mbtx` とし、テスト名は観測する動作を表す。
3. 次を実装後に実行する。snapshot更新フラグはmutation oracleへ渡さない。

```sh
moon update
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon info --target native
moon run scripts/verify-boundary.mbtx
```

fixtureのSURVIVEDを意図したCLI終了1は、期待値との一致をもってE2EのPASSとする。
ツール自体はnativeで検証し、被験プロジェクトのtargetとは区別する。
この文書変更では上記MoonBitテストは未実行。

## リスク

一対多化による既存順序の変化、既定有効化、UTF-8範囲の破損が主な回帰点。
全既存候補のsnapshot差分を確認する。候補数増加に伴う所要時間はオプトイン利用時だけ発生し、
速度向上や全変異の型適合を主張しない。

## 変更履歴

- 2026-10-13: PR #41でP1提案を作成。
- 2026-10-13: 入力・固定順序・移行・実装箇所・検証条件を確定し、openからpolishedへ移動。
- 実装リリース時: `CHANGELOG.md` とCLI説明へオプトインの新機能を記載する。このdocs-only PRでは版を更新しない。

## 注記

実装を妨げる未解決事項なし。他3件の実装を待たず着手できる。
[共通索引](../polished/README.md)のMoonBit規約を適用するが、上記仕様はこのファイル単独で実装判断できる。
`issues/open/20261013-comparison-boundary-mutations.md` から移動。完了時は実行証拠を追記して `issues/closed/` へ移す。

## 実装記録 (2026-10-20)

branch `feat/comparison-boundary-mutations`、基点 `ce66494`（v0.4.7）。
仕様からの逸脱なし。report schema 3 のまま、`--iterate` の条件も変更していない。

### 実装

| ファイル | 変更 |
| --- | --- |
| `cmd/turtles/types.mbt` | `OperatorGroup::Boundary`、`"boundary"` の解析（別名なし）、`operator_group_name`、`operator_group_default_enabled` による既定集合の明示化（`None => group != Body` を廃止） |
| `cmd/turtles/scanner.mbt` | `operator_specs()` 末尾へ境界値4件を追加（既存14件の順序は不変）、`record_operator` の `break` を削除して一対多生成へ |
| `cmd/turtles/config.mbt` | `--operators` のhelpを `body and boundary are opt-in` に更新 |
| `fixtures/boundary/` | `below`/`above`（前後値のみ検証）と `at_most`/`at_least`（等値を検証） |
| `scripts/verify-boundary.mbtx` | 境界値レポートの検証と、その自己テスト |
| `.github/workflows/ci.yml` | fixture baseline、既定/boundary/comparison+boundary の3実行、validator |
| `README.md`、`docs/verification.md`、`CHANGELOG.md` | グループ説明・検証手順・Unreleased |

### 実行証拠

moon 0.1.20261012。サンドボックスでは `~/.moon` が読み取り専用のため、
`MOON_HOME` にワークスペース内で完結する複製を指定して実行した。

```text
moon fmt --check                                    PASS
moon fmt scripts/verify-boundary.mbtx --check       PASS
moon check --target native --deny-warn              PASS
moon test --target native                           203 tests / 0 failed (PASS)
moon test scripts/self_report.mbtx                  3 tests / 0 failed (PASS)
moon test scripts/verify-boundary.mbtx              4 tests / 0 failed (PASS)
moon -C fixtures/basic test                         5 tests / 0 failed (PASS)
moon -C fixtures/boundary test                      4 tests / 0 failed (PASS)
sh scripts/self_e2e.sh                              PASS (fixture sweep 2回)
```

期待survivorによるCLI終了1は期待値と照合済み。

| 実行 | 結果 |
| --- | --- |
| `--dir fixtures/basic`（既定） | 6 mutants 全KILLED、exit 0（既存E2Eと一致） |
| `--dir fixtures/boundary`（既定） | comparison 4件、全KILLED、`group` は `comparison` のみ、exit 0 |
| `--dir fixtures/boundary --operators boundary` | boundary 4件、`<→<=` SURVIVED、`<=→<` KILLED、`>→>=` SURVIVED、`>=→>` KILLED（2/2、score 50）、exit 1。`scripts/verify-boundary.mbtx` PASS |
| 同 `--operators comparison,boundary` | 8件、各位置で comparison が先、`killed 6 / survived 2`、exit 1 |

validatorは `group` を `comparison` に改変したレポートを終了1で拒否することを確認した。

### 等値テスト追加による全KILLEDの確認

一時コピーの `comparisons_test.mbt` を `below(10)`/`above(10)` も含む形に置き換え、同じ
`--operators boundary` を実行した。結果は schema 3・4件すべてKILLED
（killed 4 / survived 0 / timeout 0 / unviable 0 / score 100、exit 0）で、
`<→<=` と `>→>=` が `below includes the threshold comparison`、
`above includes the threshold comparison` によって検出された。
恒久fixtureは2 KILLED / 2 SURVIVEDの混合のまま残し、両方の分岐をCIで常時観測する。

### 未完了

- CI（GitHub Actions）での実行結果はローカルcommit時点では未取得。PRのチェックで確認する。
- バージョン更新はリリース手順で行う（この変更では `moon.mod` / `turtles_version` を0.4.7のまま維持）。
