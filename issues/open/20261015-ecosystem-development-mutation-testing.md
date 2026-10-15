# turtles.mbt：ecosystemのテスト検出力を支える開発用mutation testing

Status: open — 設計課題。既存CLIと配布経路を前提にconsumer運用を定義する。
Priority: P1
Decision date: 2026-10-15
Parent: [ecosystem方針・共通マージ基準](https://github.com/gpui-mbt/gpui.mbt/pull/82)
Related: [dshの開発tool境界](https://github.com/f4ah6o/dsh.mbt/pull/65)

## 1. 役割

turtlesはcargo-mutantsの考え方をMoonBitへ移植し、意図的な小さなバグをテストが検出できるか調べる開発tool。gpui.mbt／Yami-kumo／dsh等のテストを強くするが、アプリへimportして動かす機能ではない。cargo-mutantsの全機能・全挙動との同一性を無条件に主張するものでもない。

GUIが動くかはvlmkit、gpui.rsとの差はgpui-conformance、処理時間はhotpathが担当する。mutation scoreだけでGUI実動作やproduction-readyを判定しない。

## 2. 現状

[README](../../README.md)にはMoonBit製native CLI、temporary copyでの変異実行、`moon check`／`moon test`との連携、JSON report、target選択、並列化、再利用等がある。通常のCLI利用にはturtles repoのcloneもPythonも不要と説明され、MoonBit toolchainは対象projectのcheck/testに必要。

新しい独自runnerやPython置換をゼロから作り直さず、既存の配布・CLI・結果分類・既存課題を再利用する。contributor用Pythonと、turtles利用者の実行依存を混同しない。

## 3. 依存・責務の境界

1. consumerは開発環境／CIに固定版の外部CLIを導入する。dsh等の通常`moon.mod`・workspace・配布runtimeへturtlesを追加しない。
2. 変異生成、隔離実行、baseline、結果分類とreportはturtlesが所有する。どのpackageを重要領域にするか、どの性質をテストすべきかはconsumerが所有する。
3. gpui.mbtのpure core・layout・routing、Yami-kumoの状態遷移、dshのpureなsession変換等から始める。実GUIや外部providerを全mutantで起動することは初期の必須要件にしない。
4. 任意のworking treeを破壊しない。未コミット変更をdiscard・clean・stashしない。隔離copyで処理し、開始前後の元tree不変を確認する。
5. test-only package importだけでmodule依存を除去したことにせず、consumerの解決graphと配布物も確認する。

## 4. 実装単位

1. **consumer recipe**：固定CLIの導入、対象directory／package、backend、baseline、deadline、report出力先を記録する最小手順を用意する。clone不要・Pythonなしの既存配布検証を維持する。
2. **重要領域の導入**：少数の決定的なpure fixtureで、検知される変異とテストが見逃す変異を用意し、結果を再現する。survivorからregression testへ戻す手順を記録する。
3. **reportの関連付け**：consumerのSHAと必要に応じたdirty tree hash、tool version、MoonBit/core、target、設定、seed、baseline結果を残す。最終PR gateでは対象HEADのsourceと一致する証拠を使う。既存schemaの拡張はversion付きで行う。
4. **段階的gate**：consumerが重要領域を宣言し、未説明SURVIVED/TIMEOUTを解消する。既存gpui.mbtのcritical-package gateを弱めず、任意の全体scoreだけで重要なsurvivorを免除しない。遅い全域検査とPR向けの範囲限定検査を区別する。

## 5. 受入条件

| 対象 | 合格条件 |
| --- | --- |
| 利用経路 | 固定版CLIを通常consumerから実行でき、turtles repo clone／Pythonを要求しない |
| baseline | 元テスト失敗・build失敗時は有効なmutation評価とせず、原因を分離する |
| KILLED / SURVIVED | 意図した検知例・見逃し例を正しく分類する |
| TIMEOUT / UNVIABLE等 | テスト検出成功へ数えず、元分類と件数・理由を残す |
| target・再利用 | source、test、toolchain、target、設定等が違う結果を無条件に再利用しない |
| working tree | 失敗・timeout・中断後も元の未コミット変更を保持する |
| runtime境界 | consumerの通常install/build/runはturtlesなしで成立する |
| gate | 重要領域の未説明survivor/timeoutや未実行をGreenとして扱わない |

scoreの分母・対象外・失敗分類を明示する。テストが存在しないケースや無効mutantを除外しただけでテスト品質の向上と報告しない。

## 6. 検証方法

READMEにある公開CLIで、専用の小さなconsumer fixtureを検証する例：

```sh
moon install f4ah6o/turtles/cmd/turtles@0.4.7
turtles --dir /path/to/fixture --target native --json /path/to/report.json
```

このversionは現時点のREADME例であり、更新時は対応するreleaseとtoolchainを明示して再検証する。source packageとnative assetの利用条件も区別する。CLI内部test、clean consumer、survivor/timeout反例、元tree不変を別結果にする。

上記は今後の受入検証。この文書追加ではコマンドは未実行。実行時は対象・コマンド・SHA・PASS/FAIL/未実行と理由を記録する。

## 7. マージ基準・完了条件

共通`ecosystem-merge-v1`に従う。**最新HEADの必要CIがすべてcompleted/success AND 同じHEADに対する実際の`gpt-6.1-sol/xhigh`のApprove相当**。モデル・effort・SHA・判定・指摘処置・証拠URLをGitHubへ残す。P0/P1、必要checkのskip、未実行、古い承認を合格にせず、HEAD更新後は再検証・再レビューする。既存保護を維持する。

1. [ ] 外部開発CLIとしてのconsumer recipeを実行できる。
2. [ ] 重要なpure fixtureでKILLED／SURVIVED／TIMEOUT等を区別できる。
3. [ ] survivorをテスト改善へ戻す実例と元tree不変の反例検査がある。
4. [ ] 通常アプリ非依存と、対象HEADへ結び付いたreportを保持する。
