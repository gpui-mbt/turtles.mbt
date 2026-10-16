# Open implementation tasks

現在も `issues/open/` に残る未着手・未解決の課題（2026-10-16確認）:

- [Ecosystem mutation-testing consumer運用](20261015-ecosystem-development-mutation-testing.md) — 開発専用CLIの導入、survivor改善、candidate SHA連携（P1）
- [Linux GNU timeout不在時の子プロセス回収](20261007-native-process-tree-timeout-cleanup.md) — PID単体cancelの残余リスク、実機再現・回帰試験（P1）
- [Windows cold native-asset / MSVC helper](20261014-windows-cold-native-compiler-helper.md) — 改変していないMSVC環境での起動・process-lifetime不一致（P1）
- [Python-free contributor maintenance](20261013-python-free-maintenance-scripts.md) — 開発・CI用スクリプト移植（P2/P3）

4件の実装仕様（comparison boundary / diff-aware selection / persistent diagnostics /
deterministic CI sharding）は [polished tasks](../polished/README.md) に整理済みです。
`polished` は実装済みや受入検証完了を意味しません。

## Workflow

1. 新規または未解決の問題をここへ記録する。
2. current main、関連PR、重複、実装証拠と照合する。
3. 実装方針・依存・受入条件・テスト計画を確定して [polished](../polished/) へ移す。
4. 実装・検証完了後はclosure recordを追加して [closed](../closed/) へ移す。

過去のマージ済みmilestoneの保留事項を、証拠なしに新規課題や完了済み機能とみなさない。
