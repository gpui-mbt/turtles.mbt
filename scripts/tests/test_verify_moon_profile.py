"""Offline adversarial parser/provenance tests, not solver qualification evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("verify_moon_profile", Path(__file__).parents[1] / "verify_moon_profile.py")
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.profile = {"schema": 1, "profile": V.PROFILE, "pilot_revision": "e58e2e2", "target": "wasm", "runtime_packages": ["text", "controls/text_field"],
                        "max_mutants": 64, "timeout_seconds": 60, "turtles_sha256": "a" * 64}

    def tearDown(self):
        self.tmp.cleanup()

    def test_profile_is_explicit_and_bounded(self):
        p = self.root / "profile.json"
        p.write_text(json.dumps(self.profile))
        self.assertEqual(V.load_profile(p), self.profile)
        for key, bad in (("schema", True), ("target", "native"), ("max_mutants", 65), ("max_mutants", 0),
                         ("timeout_seconds", 301), ("runtime_packages", []), ("turtles_sha256", ""), ("pilot_revision", "future-unreviewed")):
            with self.subTest(key=key, bad=bad):
                p.write_text(json.dumps({**self.profile, key: bad}))
                with self.assertRaises(ValueError):
                    V.load_profile(p)
        p.write_text(json.dumps({**self.profile, "command": "echo fake-green"}))
        with self.assertRaises(ValueError):
            V.load_profile(p)

    def test_duplicate_and_nonfinite_json_rejected(self):
        p = self.root / "bad.json"
        for text in ('{"schema":1,"schema":1}', '{"seconds":NaN}'):
            p.write_text(text)
            with self.assertRaises(ValueError):
                V.read_json(p)

    def test_artifact_escape_and_symlink_rejected(self):
        (self.root / "a").write_text("x")
        (self.root / "link").symlink_to(self.root / "a")
        for value in ("../a", str(self.root / "a"), "link", "missing", "a\\b"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                V.artifact(self.root, value)
        self.assertEqual(V.artifact(self.root, "a"), self.root / "a")

    def test_source_mapping_is_byte_exact_with_unicode_prefix(self):
        (self.root / "text").mkdir()
        (self.root / "text/range.mbt").write_text("// 日本語\npub struct TextRange { start : Int; end : Int }\n\npub fn TextRange::length(self : TextRange) -> Int { self.end - self.start }\n")
        (self.root / "text/document.mbt").write_text("fn utf8_scalar_width(scalar : Int) -> Int { if scalar <= 0x7F { 1 } else { 2 } }\nfn utf16_scalar_width(scalar : Int) -> Int { if scalar <= 0xFFFF { 1 } else { 2 } }\n")
        extracted, mappings = V.extract(self.root)
        offset = extracted.index(b"self.end - self.start") + len(b"self.end ")
        row = {"path": "implementation.mbt", "offset": offset, "end": offset + 1, "original": "-", "replacement": "+", "line": 1, "column": 1, "group": "arithmetic", "id": "fixture-discovery-id"}
        mapped = V.map_mutation(row, extracted, mappings, self.root)
        original = (self.root / mapped["path"]).read_bytes()
        self.assertEqual(original[mapped["offset"]:mapped["end"]], b"-")
        self.assertGreater(mapped["offset"], offset)
        for altered in ({**row, "original": "+"}, {**row, "offset": True}, {**row, "offset": 1, "end": 2, "original": extracted[1:2].decode()}):
            with self.assertRaises(ValueError):
                V.map_mutation(altered, extracted, mappings, self.root)

    def test_unsupported_syntax_and_ambiguous_source_are_not_guessed(self):
        for text in (b'fn f() { "}" }', b"fn f() { /* brace */ 1 }", b"fn f() { proof_assert true }", b"fn f() { 1 }\nfn f() { 2 }",
                     b'/*\nfn f() { 1 }\n*/\nfn f () { 2 }\n', b'let text = "fn f() { 1 }"\nfn f () { 2 }\n',
                     b'fn outer() {\nfn f() { 1 }\n}\n', b'#cfg(target = "native")\nfn f() -> Int { 1 }\n#cfg(target = "wasm")\nfn f () -> Int { 2 }\ntest { assert_eq(f(), 2) }',
                     b'#cfg(\n target = "native"\n)\nfn f() -> Int { 1 }\n', b'#coverage.skip\nfn f() { 1 }\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                V.source_span(text, "fn f(")

    def test_process_timeout_is_bounded(self):
        started = time.monotonic()
        row = V.run([sys.executable, "-c", "import time;time.sleep(20)"], self.root, {}, self.root / "timeout.log", .05)
        self.assertTrue(row["timed_out"])
        self.assertLess(time.monotonic() - started, 5)

    def test_source_copy_rejects_external_links_and_preserves_mode(self):
        source = self.root / "source"
        source.mkdir()
        (source / "a").write_text("source")
        (source / "a").chmod(0o755)
        (source / "internal").symlink_to("a")
        destination = self.root / "copy"
        V.copy_source(source, destination)
        self.assertEqual((destination / "a").stat().st_mode & 0o777, 0o755)
        self.assertEqual((destination / "internal").read_text(), "source")
        self.assertFalse((destination / "internal").is_symlink())
        baseline = V.snapshot(destination)
        (destination / "pollution").write_text("test-generated")
        self.assertNotEqual(V.snapshot(destination), baseline)
        (source / "external").symlink_to(self.root / "outside")
        with self.assertRaises(ValueError):
            V.copy_source(source, self.root / "bad-copy")

    def test_fresh_output_refuses_stale_success(self):
        output = self.root / "previous"
        output.mkdir()
        report = output / "verification-report.json"
        report.write_text('{"ok":true,"old":true}')
        from types import SimpleNamespace
        source = self.root / "source"
        source.mkdir()
        args = SimpleNamespace(source_root=source, moon_home=self.root, artifact_dir=output)
        with self.assertRaises(FileExistsError):
            V.execute(args)
        self.assertEqual(report.read_text(), '{"ok":true,"old":true}')

    def test_turtles_report_forgery_and_reuse_fail_closed(self):
        helper = self.root / "helper"
        helper.mkdir()
        extracted = b"pub fn f(x : Int) -> Int { x - 1 }\n"
        (helper / "implementation.mbt").write_bytes(extracted)
        (helper / "moon.mod").write_text('name = "fixture"\n')
        offset = extracted.index(b"-")
        row = {"path": "implementation.mbt", "offset": offset, "end": offset+1, "original": "-", "replacement": "+", "group": "arithmetic", "line": 1, "column": offset+1, "visibility": "public", "outcome": "SURVIVED", "reused": False, "duration_ms": "1"}
        row["id"] = "m-" + V.fnv(f'implementation.mbt\0{offset}\0{offset+1}\0-\0+\0arithmetic'.encode())
        report = {"schema": 3, "turtles_version": "0.4.0", "module": str(helper), "target": "native", "test_scope": "module", "skipped_files": [], "inactive_mutants": 0, "inactive_files": [], "files": {p.name: V.fnv(p.read_bytes()) for p in helper.iterdir()}, "mutants": [row], "summary": {"killed": 0, "survived": 1, "timeout": 0, "unviable": 0, "reused": 0}}
        self.assertEqual(len(V.audit_turtles(report, helper, extracted, 64)), 1)
        corruptions = [lambda r: r.update(schema=2), lambda r: r.update(schema=True), lambda r: r.update(inactive_mutants=False),
                       lambda r: r.update(mutants=[]), lambda r: r["mutants"].append(copy.deepcopy(r["mutants"][0])),
                       lambda r: r["mutants"][0].update(reused=True), lambda r: r["mutants"][0].update(id="forged"),
                       lambda r: r["files"].update({"implementation.mbt": "old"}), lambda r: r["mutants"][0].update(outcome="FAKE"),
                       lambda r: r["summary"].update(survived=True), lambda r: r["mutants"][0].update(outcome="KILLED", killed_by=True)]
        for corrupt in corruptions:
            candidate = copy.deepcopy(report)
            corrupt(candidate)
            with self.subTest(candidate=candidate), self.assertRaises(ValueError):
                V.audit_turtles(candidate, helper, extracted, 64)

    def test_runtime_failure_needs_concrete_test_json(self):
        def fake_run(command, cwd, env, log, timeout):
            is_test = command[1] == "test"
            Path(log).write_text("COMMAND " + json.dumps(command) + "\n" + (self.output if is_test else "check ok\n"))
            return {"command": command, "exit_code": self.code if is_test else 0, "timed_out": False, "seconds": .01, "log": str(log)}
        with patch.object(V, "run", fake_run):
            self.code, self.output = 2, "crashed test executable\n"
            self.assertEqual(V.runtime(Path("/moon"), self.root, {}, self.root, "wasm", ["text"], 1)["outcome"], "INCONCLUSIVE")
            self.code, self.output = 0, "Total tests: 0, passed: 0, failed: 0.\n"
            self.assertEqual(V.runtime(Path("/moon"), self.root, {}, self.root, "wasm", ["text"], 1)["outcome"], "INCONCLUSIVE")
            self.code, self.output = 2, json.dumps({"package": "f4ah6o/gpui/text", "filename": "text_test.mbt", "test_name": "boundary", "index": "0", "message": "assertion failed"}) + "\n"
            self.assertEqual(V.runtime(Path("/moon"), self.root, {}, self.root, "wasm", ["text"], 1)["outcome"], "KILLED")
            self.code = 255
            self.assertEqual(V.runtime(Path("/moon"), self.root, {}, self.root, "wasm", ["text"], 1)["outcome"], "INCONCLUSIVE")

    def test_unreviewed_producer_is_rejected_before_import(self):
        path = self.root / V.PRODUCER
        path.parent.mkdir(parents=True)
        sentinel = self.root / "must-not-execute"
        path.write_text(f'from pathlib import Path\nPath({str(sentinel)!r}).write_text("executed")\n')
        with self.assertRaisesRegex(ValueError, "producer differs"):
            V.load_producer(self.root)
        self.assertFalse(sentinel.exists())

    def test_tool_and_plugin_hash_mismatches_fail_closed(self):
        home = self.root / "home"
        why3 = self.root / "prefix/bin/why3"
        solver = self.root / "solver"
        files = [home / "bin/moon", home / "bin/moonc", why3, solver, self.root / "prefix/lib/why3/commands/why3prove.cmxs", home / "share/why3/driver"]
        for path in files:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("locked " + path.name)
        data = V.hashlib.sha256(b"driver\0" + bytes.fromhex(V.sha(files[-1]))).hexdigest()
        lock = {"artifact_sha256": {name: V.sha(home / name) for name in ("bin/moon", "bin/moonc")}, "solver": {"executable_sha256": V.sha(solver)},
                "export_backend": {"cli_sha256": V.sha(why3), "prove_plugin_sha256": V.sha(files[-2]), "moon_why3_datadir_sha256": data}}
        V.tool_identity(lock, home, why3, solver)
        for path in files:
            original = path.read_text()
            path.write_text("tampered")
            with self.subTest(path=path), self.assertRaises(ValueError):
                V.tool_identity(lock, home, why3, solver)
            path.write_text(original)

    def test_unreviewed_lock_blocks_before_any_tool_execution(self):
        from types import SimpleNamespace
        source = self.root / "source"
        template = source / "proofs/composition"
        template.mkdir(parents=True)
        fixed = {}
        for name in V.FIXED:
            (template / name).write_text("fixed fixture " + name)
            fixed[name] = V.sha(template / name)
        (template / "proof-toolchain.lock.json").write_text('{"unreviewed":true}')
        binary, why3, solver = (self.root / name for name in ("turtles", "why3", "z3"))
        for path in (binary, why3, solver):
            path.write_text("must not execute")
        profile = self.root / "profile.json"
        profile.write_text(json.dumps({**self.profile, "turtles_sha256": V.sha(binary)}))
        args = SimpleNamespace(source_root=source, moon_home=self.root, artifact_dir=self.root / "attempt", profile=profile,
                               turtles_bin=binary, why3=why3, solver=solver)
        with patch.dict(V.FIXED, fixed), patch.object(V, "load_producer", return_value=SimpleNamespace()), patch.object(V, "run", side_effect=AssertionError("unexpected execution")):
            self.assertEqual(V.execute(args), 2)
        result = V.read_json(self.root / "attempt/verification-report.json")
        self.assertIn("runtime lock differs", result["reason"])
        self.assertFalse(result["ok"])

    def test_replay_rejects_untyped_witness_and_checks_remutation(self):
        source = self.root / "source"
        (source / "text").mkdir(parents=True)
        content = b"pub fn TextRange::length(self : TextRange) -> Int { self.end - self.start }\n"
        (source / "text/range.mbt").write_bytes(content)
        offset = content.index(b"self.end -") + len(b"self.end ")
        candidate = {"source_edit": {"head": "pub fn TextRange::length(", "path": "text/range.mbt", "offset": offset, "end": offset+1, "original": "-", "replacement": "+"}}
        kill = {"filename": "model_pbt_wbtest.mbt", "test_name": "independent range reconstruction model fixed seeded PBT", "kind": "Property", "counterexample": "(-1, -1)"}
        campaign = self.root / "campaign"
        campaign.mkdir()
        for witness in ("(1,2)", "(1.0, 2)", "(2147483648, 2)", "__import__('os')"):
            row = {"killed_by": [{**kill, "counterexample": witness}]}
            self.assertEqual(V.regression_replay(candidate, row, source, campaign, Path("/moon"), {}, {})["status"], "unsupported")
        def fake_runtime(moon, root, env, out, target, packages, timeout):
            text = (root / "text/turtles_counterexample_regression_wbtest.mbt").read_text()
            self.assertIn("start: 2147483647, end: 2147483647", text)
            mutated = out.name == "regression-remutated"
            self.assertIn("self.end + self.start" if mutated else "self.end - self.start", (root / "text/range.mbt").read_text())
            return {"outcome": "KILLED" if mutated else "SURVIVED", "killed_by": [{"test_name": "turtles deterministic shrunk range regression", "filename": "turtles_counterexample_regression_wbtest.mbt"}] if mutated else []}
        with patch.object(V, "runtime", fake_runtime):
            replay = V.regression_replay(candidate, {"killed_by": [kill]}, source, campaign, Path("/moon"), {}, {"target": "wasm", "runtime_packages": ["text"], "timeout_seconds": 1})
            self.assertEqual(replay["status"], "replayed")


class ExportEvidenceTests(unittest.TestCase):
    """Synthetic records exercise rejection branches; no proof is claimed."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.module = self.out / "positive"
        self.module.mkdir()
        (self.module / "tasks").mkdir()
        self.home = self.out / "home"
        self.why3 = self.out / "prefix/bin/why3"
        self.solver = self.out / "z3"
        self.run_id = "b0a5403d-c5c2-4ed7-afc9-e35f7f0c41c0"
        self.impl = "source-corresponding fixture implementation"
        (self.module / "implementation.mbt").write_text(self.impl)
        (self.module / "implementation.mlw").write_text("fixture WhyML")
        self.fixed = {}
        for filename in ("spec.mbtp", "boundary_wbtest.mbt", "moon.pkg"):
            (self.module / filename).write_text("fixed fixture " + filename)
            self.fixed[filename] = V.sha(self.module / filename)
        self.lock = {"export_backend": {"expected_goal_ids": sorted(V.GOALS), "why3_version": "1.7.2", "cli_sha256": "a" * 64, "prove_plugin_sha256": "b" * 64, "moon_why3_datadir_sha256": "c" * 64}}
        libdir = self.why3.parent.parent / "lib/why3"
        datadir = self.home / "share/why3"
        config = f'[main]\nmagic = 14\nlibdir = "{libdir}"\ndatadir = "{datadir}"\nstdlib = false\nload_default_plugins = false\n'
        (self.out / "why3-export.conf").write_text(config)
        self.bindings = {"run_id": self.run_id, "config_text": config, "config_sha256": V.sha(self.out / "why3-export.conf"),
                         "compiled_libdir": str(libdir), "actual_prove_plugin": str(libdir / "commands/why3prove.cmxs"), "actual_prove_plugin_sha256": "b" * 64,
                         "effective_datadir": str(datadir), "effective_loadpaths": [str(self.home / "lib/prelude_proof"), str(datadir / "stdlib")], "stdlib": False,
                         "load_default_plugins": False, "plugin_entries": [], "cleared_environment_prefixes": ["WHY3"],
                         "sanitized_environment": {"WHY3CONFIG": None, "WHY3LOADPATH": None, "WHY3DATA": str(datadir), "WHY3LIB": str(libdir)},
                         "runtime": {"version": "Why3 platform, version 1.7.2", "cli_sha256": "a" * 64, "prove_plugin_sha256": "b" * 64, "moon_why3_datadir_sha256": "c" * 64}}
        self.steps = []
        self.record([str(self.home / "bin/moon"), "check"], "typecheck.log", "ok")
        self.record([str(self.home / "bin/moonc"), "prove", "implementation.mbt", "spec.mbtp", "-i", str(self.home / "lib/core/_build/wasm/release/bundle/prelude/prelude.mi") + ":prelude", "-pkg", "f4ah6o/composition_proof", "-pkg-type", "library", "-emit-only", "-whyml-output-path", str(self.module / "implementation.mlw"), "-proof-report-output-path", str(self.module / "emit-only.json")], "emit.log", "ok")
        prefix = [str(self.why3), "-C", str(self.out / "why3-export.conf"), "prove", "--no-load-default-plugins", "--no-stdlib"]
        for value in self.bindings["effective_loadpaths"]:
            prefix.extend(["-L", value])
        inventory = sorted(V.GOALS)
        self.record(prefix + ["--print-theory", str(self.module / "implementation.mlw")], "positive-goal-inventory.log", "\n".join("  goal " + g + " :" for g in inventory))
        self.record(prefix + ["-a", "inline_all", "-a", "remove_unused", "-D", str(self.home / "share/why3/drivers/z3_471.drv"), "-o", str(self.module / "tasks"), str(self.module / "implementation.mlw")], "positive-export.log", "ok")
        rows = []
        for index, goal in enumerate(inventory):
            task = self.module / "tasks" / f"fixture-{index}.smt2"
            task.write_text(';; Goal "' + goal + '"\n; offline synthetic fixture, not executable evidence\n')
            record = self.record([str(self.solver), "-smt2", "-T:5", str(task)], f"positive-goal-{index}-z3.log", "unsat")
            rows.append({**record, "goal": goal, "task": task.relative_to(self.out).as_posix(), "task_sha256": V.sha(task), "unmodified": True, "answer": "unsat", "stdout": "unsat", "solver_log": f"positive-goal-{index}-z3.log"})
        self.raw = {"schema_version": 1, "backend": "why3-export-z3", "run_id": self.run_id, "config_sha256": self.bindings["config_sha256"], "qualified": True, "whyml_sha256": V.sha(self.module / "implementation.mlw"), "goal_inventory": inventory, "goal_count": 5, "task_count": 5, "driver": "z3_471.drv", "transformations": ["inline_all", "remove_unused"], "tasks": rows,
                    "summary": {"valid": 5, "invalid": 0, "timeout": 0, "oom": 0, "step_limit": 0, "unknown": 0, "failure": 0}}

    def tearDown(self):
        self.tmp.cleanup()

    def record(self, command, filename, output):
        log = self.out / filename
        log.write_text("COMMAND " + json.dumps(command) + "\n" + output + "\n")
        record = {"command": command, "exit_code": 0, "timed_out": False, "seconds": .001, "log": str(log)}
        self.steps.append(record)
        return record

    def audit(self, expected_goal=None):
        V.write_json(self.out / "positive-export-report.json", self.raw)
        with patch.dict(V.FIXED, self.fixed):
            return V.audit_export(self.out, self.module, "positive", self.bindings, self.lock, self.why3, self.home, self.solver, self.run_id, self.steps, self.impl, expected_goal)

    def test_fixture_proved_and_sat_are_distinct(self):
        self.assertEqual(self.audit()["outcome"], "PROVED")
        row = self.raw["tasks"][0]
        row["answer"] = row["stdout"] = "sat"
        log = self.out / row["solver_log"]
        log.write_text(log.read_text().replace("\nunsat\n", "\nsat\n"))
        self.raw["summary"].update(valid=4, invalid=1)
        self.assertEqual(self.audit()["outcome"], "COUNTEREXAMPLE")
        with self.assertRaises(ValueError):
            self.audit("utf8_scalar_width'vc")

    def test_native_control_needs_exact_failure_site_and_values(self):
        command = [str(self.home / "bin/moon"), "test", "--target", "native"]
        expected = '[f4ah6o/composition_proof] test boundary_wbtest.mbt:2 ("range length machine limits and source-exact Unicode partitions") failed: boundary_wbtest.mbt:3:3-3:79@f4ah6o/composition_proof FAILED: `-2147483647 != 2147483647`\ndiff:\n--2147483647 +2147483647\nTotal tests: 1, passed: 0, failed: 1.'
        row = self.record(command, "negative-range-runtime.log", expected)
        row["exit_code"] = 2
        self.assertTrue(V.audit_native_control(self.out, "negative-range", self.steps, self.home)["qualified"])
        for bad in ("Total tests: 1, passed: 0, failed: 1.", expected.replace("boundary_wbtest.mbt:3:3-3:79", "unrelated.mbt:1:1"), expected.replace("-2147483647 != 2147483647", "3 != 4")):
            (self.out / "negative-range-runtime.log").write_text("COMMAND " + json.dumps(command) + "\n" + bad + "\n")
            with self.assertRaises(ValueError):
                V.audit_native_control(self.out, "negative-range", self.steps, self.home)

    def test_forged_stale_and_unknown_results_fail_closed(self):
        original = copy.deepcopy(self.raw)
        corruptions = [lambda r: r.update(run_id="stale"), lambda r: r.update(schema_version=True),
                       lambda r: r.update(goal_count=True), lambda r: r["summary"].update(valid=True),
                       lambda r: r["tasks"][0].update(answer="sat", stdout="sat"),
                       lambda r: r["tasks"][0].update(exit_code=1), lambda r: r["tasks"][0].update(timed_out=True),
                       lambda r: r["tasks"][0].update(seconds=True), lambda r: r["tasks"][0].update(task_sha256="0" * 64),
                       lambda r: r["tasks"].pop(), lambda r: r["tasks"].append(copy.deepcopy(r["tasks"][0])),
                       lambda r: r["goal_inventory"].__setitem__(0, r["goal_inventory"][1])]
        for corrupt in corruptions:
            self.raw = copy.deepcopy(original)
            corrupt(self.raw)
            with self.subTest(raw=self.raw), self.assertRaises(ValueError):
                self.audit()
        self.raw = original
        log = self.out / self.raw["tasks"][0]["solver_log"]
        for answer in ("unknown", "unsat\nextra", "timeout"):
            log.write_text("COMMAND " + json.dumps(self.raw["tasks"][0]["command"]) + "\n" + answer + "\n")
            with self.subTest(answer=answer), self.assertRaises(ValueError):
                self.audit()

    def test_weakened_contract_and_stale_executable_rejected(self):
        (self.module / "implementation.mbt").write_text("stale original template")
        with self.assertRaises(ValueError):
            self.audit()
        (self.module / "implementation.mbt").write_text(self.impl)
        (self.module / "spec.mbtp").write_text("proof_ensure: true")
        with self.assertRaises(ValueError):
            self.audit()

    def test_whyml_symlink_rejected_even_with_matching_hash(self):
        whyml = self.module / "implementation.mlw"
        target = self.out / "external-whyml"
        target.write_bytes(whyml.read_bytes())
        whyml.unlink()
        whyml.symlink_to(target)
        with self.assertRaises(ValueError):
            self.audit()

    def test_unqualified_plugin_configuration_and_failed_ledger_rejected(self):
        original = copy.deepcopy(self.bindings)
        for key, value in (("plugin_entries", ["/unqualified/plugin"]), ("effective_loadpaths", []), ("load_default_plugins", True), ("run_id", "old")):
            self.bindings = {**original, key: value}
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.audit()
        self.bindings = original
        self.steps[3]["exit_code"] = 2
        with self.assertRaises(ValueError):
            self.audit()


if __name__ == "__main__":
    unittest.main()
