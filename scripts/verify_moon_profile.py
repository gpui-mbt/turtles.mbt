#!/usr/bin/env python3
"""Opt-in, bounded source-exact MoonBit composition-helper verification.

This companion CLI does not change turtles' native runtime score or schema.
It supports exactly the reviewed three-helper official-export pilot, not an
arbitrary command hook, a general prover, or a Kani-compatible safety model.
"""
from __future__ import annotations

import argparse
from collections import Counter
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

PROFILE = "moonbit-composition-helpers-v1"
PRODUCER = "infra/linux-desktop/composition-proof.py"
PRODUCER_SHA256 = "78ba554319eba17e50034fc59f14c531c539d2929d53bb012497363360b6975a"
LOCK_SHA256 = "493e83579177583ef993a098afcb102ee529dc01afd807719ce88c3b138041f2"
PILOTS = {
    "e58e2e2": {"producer_sha256": PRODUCER_SHA256, "template": "proofs/composition"},
    "packaging-39b1275": {"producer_sha256": "41ca263e8dd0c99ec8fd120c19ed0043c2068feb8ade9928a7311dd209f90122", "template": "testing/composition_proof"},
}
FIXED = {
    "implementation.mbt": "d5800067064e5131865c88a96591586fe729deb7f0849e80b5841b505f3164ed",
    "spec.mbtp": "f25112ca6066b1f2b43220a6f00dffa82ec38646cf93df82d4b40991cf4a781b",
    "boundary_wbtest.mbt": "0cfd9ddc59cb42a370e7536084ab63274dc9cc498d2c99f8af4c8781bc09a30e",
    "moon.pkg": "14f61a444631b7cfc3a27f71868b2610b09c9144ca6e8a2e3d4e20705cb4e4eb",
}
TARGETS = (
    ("text/range.mbt", "pub struct TextRange {", None),
    ("text/range.mbt", "pub fn TextRange::length(", "mbtp___40f4ah6o_2fcomposition_proof_2eTextRange_3a_3alength'vc"),
    ("text/document.mbt", "fn utf8_scalar_width(", "utf8_scalar_width'vc"),
    ("text/document.mbt", "fn utf16_scalar_width(", "utf16_scalar_width'vc"),
)
GOALS = {"preconditions_are_inhabited'vc", "range_preconditions_are_inhabited'vc", *(row[2] for row in TARGETS if row[2])}
IGNORED = {".git", "_build", ".mooncakes", ".moon", ".turtles", "node_modules", "__pycache__"}
SEEDS = [1, 1777, 4242, 65535]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fnv(data):
    value = 0xCBF29CE484222325
    for byte in data:
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def read_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError("nonfinite JSON: " + value)))


def write_json(path, data):
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        tmp = Path(stream.name)
        json.dump(data, stream, indent=2, allow_nan=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def artifact(directory, relative):
    if type(relative) is not str or not relative or "\\" in relative:
        raise ValueError("invalid artifact path")
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise ValueError("escaping artifact path")
    selected = directory / path
    if any((directory / Path(*path.parts[:i])).is_symlink() for i in range(1, len(path.parts) + 1)):
        raise ValueError("artifact symlink")
    if not selected.is_file() or not selected.resolve().is_relative_to(directory.resolve()):
        raise ValueError("missing artifact")
    return selected


def load_profile(path):
    obj = read_json(path)
    expected = {"schema", "profile", "pilot_revision", "target", "runtime_packages", "max_mutants", "timeout_seconds", "turtles_sha256"}
    if type(obj) is not dict or set(obj) != expected or type(obj["schema"]) is not int or obj["schema"] != 1 or obj["profile"] != PROFILE:
        raise ValueError("unsupported verification profile/schema/keys")
    if type(obj["pilot_revision"]) is not str or obj["pilot_revision"] not in PILOTS:
        raise ValueError("unsupported or unreviewed proof pilot revision")
    if obj["target"] != "wasm" or obj["runtime_packages"] != ["text", "controls/text_field"]:
        raise ValueError("this profile requires the reviewed wasm text + text-field package scope")
    for name, maximum in (("max_mutants", 64), ("timeout_seconds", 300)):
        if type(obj[name]) is not int or not 1 <= obj[name] <= maximum:
            raise ValueError(name + " is outside the bounded range")
    if type(obj["turtles_sha256"]) is not str or not re.fullmatch(r"[0-9a-f]{64}", obj["turtles_sha256"]):
        raise ValueError("profile needs the reviewed turtles executable SHA-256")
    return obj


def terminate(proc):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def run(argv, cwd, env, log, timeout):
    started = time.monotonic()
    with Path(log).open("x") as stream:
        stream.write("COMMAND " + json.dumps(argv) + "\n")
        stream.flush()
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = proc.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            terminate(proc)
            code, timed_out = proc.returncode, True
        finally:
            terminate(proc)
    return {"command": argv, "exit_code": code, "timed_out": timed_out, "seconds": time.monotonic() - started, "log": str(log)}


def check_log(row, path, command, exit_code=0):
    if type(row) is not dict or row.get("command") != command or row.get("log") != str(path) or type(row.get("exit_code")) is not int or row["exit_code"] != exit_code or row.get("timed_out") is not False:
        raise ValueError("unsuccessful/mismatched process evidence")
    seconds = row.get("seconds")
    if type(seconds) not in (int, float) or not math.isfinite(seconds) or seconds < 0:
        raise ValueError("invalid process duration")
    lines = path.read_text().splitlines()
    if not lines or lines[0] != "COMMAND " + json.dumps(command):
        raise ValueError("raw command identity mismatch")
    return lines[1:]


def brace_end(data, opening):
    # This profile deliberately supports primitive bodies only. Comments,
    # strings, attributes and contract additions inside an executable body
    # are unsupported instead of being parsed by a permissive regex.
    depth = 0
    for i in range(opening, len(data)):
        depth += (data[i:i+1] == b"{") - (data[i:i+1] == b"}")
        if depth == 0:
            body = data[opening:i+1]
            if any(token in body for token in (b'"', b"'", b"//", b"/*", b"#", b"proof_", b"where")):
                raise ValueError("unsupported executable syntax in helper extraction")
            return i + 1
    raise ValueError("unclosed helper declaration")


def active_code(data):
    """Preserve byte coordinates while removing comments/string contents.

    This is only an extraction rejection guard; official Moon/turtles parsing
    still validates every accepted program. Unknown prefixes fail closed.
    """
    masked = bytearray(data)
    i = 0
    while i < len(data):
        start, end = i, None
        if data[i:i+2] == b"//":
            end = data.find(b"\n", i)
            if end < 0:
                end = len(data)
        elif data[i:i+2] == b"/*":
            # Such syntax is unsupported by the pinned compiler, but masking
            # it prevents a decoy from being extracted before that rejection.
            end = data.find(b"*/", i+2)
            if end < 0:
                raise ValueError("unterminated comment")
            end += 2
        elif data[i:i+1] in (b'"', b"'"):
            quote = data[i:i+1]
            end = i + 1
            while end < len(data):
                if data[end:end+1] == b"\\":
                    end += 2
                elif data[end:end+1] == quote:
                    end += 1
                    break
                else:
                    end += 1
            else:
                raise ValueError("unterminated quoted literal")
        elif data[i:i+2] in (b"#|", b"$|") and not data[data.rfind(b"\n", 0, i)+1:i].strip():
            end = data.find(b"\n", i)
            if end < 0:
                end = len(data)
        if end is not None:
            for position in range(start, min(end, len(data))):
                if data[position] not in (10, 13):
                    masked[position] = 32
            i = end
        else:
            i += 1
    return bytes(masked)


def source_span(data, head):
    marker = head.encode()
    code = active_code(data)
    if code.count(marker) != 1:
        raise ValueError("ambiguous or missing helper declaration: " + head)
    start = code.index(marker)
    if start and data[start-1:start] != b"\n":
        raise ValueError("helper must begin at a declaration boundary")
    name = head.split("fn ", 1)[1].rstrip("(") if "fn " in head else head.split("struct ", 1)[1].rstrip(" {")
    name_pattern = re.escape(name).replace(r"::", r"\s*::\s*")
    declaration_pattern = rb"\b" + (b"fn" if "fn " in head else b"struct") + rb"\s+" + name_pattern.encode() + (rb"\s*\(" if "fn " in head else rb"\s*\{")
    if len(re.findall(declaration_pattern, code)) != 1:
        raise ValueError("alternate/duplicate helper declaration spelling is unsupported")
    depth, previous_boundary = 0, 0
    for index, char in enumerate(code[:start]):
        if char == 123:
            depth += 1
        elif char == 125:
            depth -= 1
            if depth == 0:
                previous_boundary = index + 1
        if depth < 0:
            raise ValueError("malformed declaration nesting")
    if depth != 0 or b"#" in code[previous_boundary:start]:
        raise ValueError("helper is nested or has an unsupported attribute/target prefix")
    opening = data.index(b"{", start)
    if b"where" in data[start:opening]:
        raise ValueError("production proof contracts are unsupported in this extraction profile")
    end = brace_end(data, opening)
    return start, opening, end


def extract(root):
    data = b""
    mappings = []
    for relative, head, goal in TARGETS:
        original = (root / relative).read_bytes()
        start, opening, end = source_span(original, head)
        begin = len(data)
        data += original[start:end] + b"\n\n"
        if goal:
            mappings.append({"path": relative, "head": head, "goal": goal,
                             "extracted_start": begin, "extracted_body": begin + opening - start,
                             "extracted_end": begin + end - start, "source_start": start, "source_body": opening, "source_end": end})
    return data, mappings


def map_mutation(row, extracted, mappings, root):
    if type(row) is not dict or row.get("path") != "implementation.mbt" or any(type(row.get(k)) is not int for k in ("offset", "end", "line", "column")):
        raise ValueError("mutation lacks exact byte coordinates")
    start, end = row["offset"], row["end"]
    original, replacement = row.get("original"), row.get("replacement")
    if type(original) is not str or type(replacement) is not str or not original or not replacement or not 0 <= start < end <= len(extracted) or extracted[start:end] != original.encode():
        raise ValueError("mutation edit does not match extracted source bytes")
    matches = [m for m in mappings if m["extracted_body"] < start and end < m["extracted_end"]]
    if len(matches) != 1:
        raise ValueError("mutation is outside a declared executable helper body")
    mapping = matches[0]
    source_start = mapping["source_start"] + start - mapping["extracted_start"]
    source_end = source_start + end - start
    source = (root / mapping["path"]).read_bytes()
    if source[source_start:source_end] != original.encode():
        raise ValueError("production mutation source correspondence failed")
    identity = f'{mapping["path"]}\0{source_start}\0{source_end}\0{original}\0{replacement}\0{row["group"]}'
    return {**mapping, "offset": source_start, "end": source_end, "original": original, "replacement": replacement,
            "production_mutant_id": "m-" + fnv(identity.encode()), "discovery_id": row["id"]}


def regenerate(producer, template, root):
    # Retain the reviewed header/contracts and replace executable bodies only.
    result = template
    for relative, head, goal in TARGETS:
        actual = producer.declaration((root / relative).read_text(), head)
        old = producer.declaration(result, head)
        if not goal:
            if producer.canonical(actual) != producer.canonical(old):
                raise ValueError("TextRange fields changed")
            continue
        marker = result.index(head)
        contract_open = result.index("{", marker)
        if "where" not in result[marker:contract_open]:
            raise ValueError("missing fixed contract")
        contract_end = producer.block_end(result, contract_open)
        body_start = result.index("{", contract_end)
        body_end = producer.block_end(result, body_start)
        actual_body = actual[actual.index("{"):]
        result = result[:body_start] + actual_body + result[body_end:]
        if producer.canonical(producer.declaration(result, head)) != producer.canonical(actual):
            raise ValueError("regenerated mutant body is not production-exact")
    return result


def fixed_contracts(producer, implementation):
    value = implementation
    for _, head, goal in reversed(TARGETS):
        if goal:
            start = value.index(head)
            first = value.index("{", start)
            body = value.index("{", producer.block_end(value, first))
            end = producer.block_end(value, body)
            value = value[:body] + "{__FIXED_EXECUTABLE_BODY__}" + value[end:]
    return hashlib.sha256(value.encode()).hexdigest()


def copy_source(root, destination):
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if any(part in IGNORED for part in relative.parts):
            continue
        if path.is_symlink() and (not path.resolve().is_file() or not path.resolve().is_relative_to(root)):
            raise ValueError("source symlink escapes checkout or is not a file")
    shutil.copytree(root, destination, symlinks=False,
                    ignore=lambda _, names: [name for name in names if name in IGNORED])


def snapshot(root):
    files = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if any(part in IGNORED for part in relative.parts):
            continue
        if path.is_file():
            files[relative.as_posix()] = {"sha256": sha(path), "mode": path.stat().st_mode & 0o777,
                                         "link": str(path.readlink()) if path.is_symlink() else None}
    return files


def runtime(moon, root, env, out, target, packages, timeout):
    check = run([str(moon), "check", *packages, "--target", target, "--deny-warn"], root, env, out / "runtime-check.log", timeout)
    if check["timed_out"] or check["exit_code"] != 0:
        return {"outcome": "TIMEOUT" if check["timed_out"] else "UNVIABLE", "check": check, "killed_by": []}
    argv = [str(moon), "test", *packages, "--target", target, "--deny-warn", "--test-failure-json"]
    test = run(argv, root, env, out / "runtime-test.log", timeout)
    kills = []
    for line in (out / "runtime-test.log").read_text().splitlines()[1:]:
        if line.startswith("{"):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if type(row) is dict and all(type(row.get(k)) is str for k in ("package", "filename", "test_name", "message")) and type(row.get("index")) in (str, int):
                kills.append(row)
    if test["timed_out"]:
        outcome = "TIMEOUT"
    elif test["exit_code"] == 0 and not kills and re.search(r"Total tests: [1-9]\d*, passed: [1-9]\d*, failed: 0\.", (out / "runtime-test.log").read_text()):
        outcome = "SURVIVED"
    elif test["exit_code"] == 2 and kills:
        outcome = "KILLED"
    else:
        outcome = "INCONCLUSIVE"
    return {"outcome": outcome, "check": check, "test": test, "killed_by": kills}


def load_producer(root, pilot_revision="e58e2e2"):
    path = artifact(root, PRODUCER)
    if pilot_revision not in PILOTS or sha(path) != PILOTS[pilot_revision]["producer_sha256"]:
        raise ValueError("proof producer differs from the explicitly reviewed revision/layout pair")
    spec = importlib.util.spec_from_file_location("turtles_reviewed_proof_producer", path)
    module = importlib.util.module_from_spec(spec)
    old = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = old
    return module


def tool_identity(lock, home, why3, solver):
    observed = {name: sha(home / name) for name in lock["artifact_sha256"]}
    if observed != lock["artifact_sha256"] or sha(solver) != lock["solver"]["executable_sha256"] or sha(why3) != lock["export_backend"]["cli_sha256"]:
        raise ValueError("runtime toolchain hash mismatch")
    plugin = why3.parent.parent / "lib/why3/commands/why3prove.cmxs"
    data = hashlib.sha256()
    for file in sorted((home / "share/why3").rglob("*")):
        if file.is_file():
            data.update(str(file.relative_to(home / "share/why3")).encode() + b"\0" + bytes.fromhex(sha(file)))
    if sha(plugin) != lock["export_backend"]["prove_plugin_sha256"] or data.hexdigest() != lock["export_backend"]["moon_why3_datadir_sha256"]:
        raise ValueError("actual plugin or Why3 data/driver tree differs from reviewed lock")
    return {"moon": observed, "solver": sha(solver), "why3": sha(why3), "prove_plugin": sha(plugin), "why3_data": data.hexdigest()}


def audit_export(out, module, name, bindings, lock, why3, home, solver, run_id, steps, expected_implementation, expected_goal=None):
    if expected_goal is not None and expected_goal not in GOALS:
        raise ValueError("unrecognized expected counterexample goal")
    raw = read_json(artifact(out, name + "-export-report.json"))
    config = artifact(out, "why3-export.conf")
    if bindings["run_id"] != run_id or config.read_text() != bindings["config_text"] or sha(config) != bindings["config_sha256"]:
        raise ValueError("stale/forged backend configuration")
    libdir = (why3.parent.parent / "lib/why3").resolve()
    datadir = (home / "share/why3").resolve()
    expected_config = f'[main]\nmagic = 14\nlibdir = "{libdir}"\ndatadir = "{datadir}"\nstdlib = false\nload_default_plugins = false\n'
    if config.read_text() != expected_config or bindings.get("compiled_libdir") != str(libdir) or bindings.get("actual_prove_plugin") != str(libdir / "commands/why3prove.cmxs") or bindings.get("actual_prove_plugin_sha256") != lock["export_backend"]["prove_plugin_sha256"] or bindings.get("effective_datadir") != str(datadir) or bindings.get("effective_loadpaths") != [str((home / "lib/prelude_proof").resolve()), str(datadir / "stdlib")] or bindings.get("stdlib") is not False or bindings.get("load_default_plugins") is not False or bindings.get("plugin_entries") != [] or bindings.get("cleared_environment_prefixes") != ["WHY3"] or bindings.get("sanitized_environment") != {"WHY3CONFIG": None, "WHY3LOADPATH": None, "WHY3DATA": str(datadir), "WHY3LIB": str(libdir)}:
        raise ValueError("unqualified backend config/plugin/loadpath context")
    expected_runtime = {"version": "Why3 platform, version " + lock["export_backend"]["why3_version"],
                        **{key: lock["export_backend"][key] for key in ("cli_sha256", "prove_plugin_sha256", "moon_why3_datadir_sha256")}}
    if bindings.get("runtime") != expected_runtime:
        raise ValueError("unqualified export runtime identity")
    if artifact(out, name + "/implementation.mbt").read_text() != expected_implementation:
        raise ValueError("compiled proof executable differs from source-corresponding candidate")
    for filename in ("spec.mbtp", "boundary_wbtest.mbt", "moon.pkg"):
        if sha(artifact(out, name + "/" + filename)) != FIXED[filename]:
            raise ValueError("weakened or stale contract/test input")
    if type(steps) is not list or any(type(row) is not dict for row in steps):
        raise ValueError("missing process ledger")
    def attempt_for(command, log):
        found = [row for row in steps if row.get("command") == command]
        if len(found) != 1:
            raise ValueError("missing/duplicate exact process ledger command")
        return found[0], check_log(found[0], log, command)
    check = [str(home / "bin/moon"), "check"]
    check_rows = [row for row in steps if row.get("command") == check and Path(str(row.get("log", ""))).name in (name + "-check.log", "typecheck.log")]
    if len(check_rows) != 1:
        raise ValueError("proof lacks one exact typecheck for this scenario")
    check_log(check_rows[0], artifact(out, Path(check_rows[0]["log"]).name), check)
    emit = [str(home / "bin/moonc"), "prove", "implementation.mbt", "spec.mbtp", "-i", str(home / "lib/core/_build/wasm/release/bundle/prelude/prelude.mi") + ":prelude", "-pkg", "f4ah6o/composition_proof", "-pkg-type", "library", "-emit-only", "-whyml-output-path", str(module / "implementation.mlw"), "-proof-report-output-path", str(module / "emit-only.json")]
    emit_rows = [row for row in steps if row.get("command") == emit]
    if len(emit_rows) != 1:
        raise ValueError("proof lacks one exact source-to-WhyML lowering")
    check_log(emit_rows[0], artifact(out, Path(emit_rows[0]["log"]).name), emit)
    whyml = artifact(out, name + "/implementation.mlw")
    if type(raw.get("schema_version")) is not int or raw["schema_version"] != 1 or raw.get("backend") != "why3-export-z3" or raw.get("run_id") != run_id or raw.get("config_sha256") != sha(config) or type(raw.get("goal_count")) is not int or raw["goal_count"] != 5 or type(raw.get("task_count")) is not int or raw["task_count"] != 5 or raw.get("driver") != "z3_471.drv" or raw.get("transformations") != ["inline_all", "remove_unused"] or raw.get("whyml_sha256") != sha(whyml):
        raise ValueError("incomplete or unrelated exported proof report")
    inventory = raw.get("goal_inventory")
    if type(inventory) is not list or len(inventory) != 5 or set(inventory) != GOALS or set(lock["export_backend"]["expected_goal_ids"]) != GOALS:
        raise ValueError("missing/duplicate/unknown proof goals")
    prefix = [str(why3), "-C", str(config), "prove", "--no-load-default-plugins", "--no-stdlib"]
    for loadpath in bindings["effective_loadpaths"]:
        prefix.extend(["-L", loadpath])
    inventory_log = artifact(out, name + "-goal-inventory.log")
    _, inventory_lines = attempt_for(prefix + ["--print-theory", str(module / "implementation.mlw")], inventory_log)
    if re.findall(r"^  goal (.+?)\s*:", "\n".join(inventory_lines), re.MULTILINE) != inventory:
        raise ValueError("proof inventory raw command/source mismatch")
    export_log = artifact(out, name + "-export.log")
    export_command = prefix + ["-a", "inline_all", "-a", "remove_unused", "-D", str(home / "share/why3/drivers/z3_471.drv"), "-o", str(module / "tasks"), str(module / "implementation.mlw")]
    attempt_for(export_command, export_log)
    rows = raw.get("tasks")
    if type(rows) is not list or len(rows) != 5 or any(type(row) is not dict for row in rows) or {row.get("goal") for row in rows} != GOALS:
        raise ValueError("missing/duplicated proof tasks")
    tasks, logs, answers = set(), set(), {}
    for row in rows:
        task = artifact(out, row.get("task"))
        log = artifact(out, row.get("solver_log"))
        if task.parent != module / "tasks" or task.suffix != ".smt2" or row.get("task_sha256") != sha(task) or row.get("unmodified") is not True or re.findall(r'^;; Goal "([^"\n]+)"', task.read_text(), re.MULTILINE) != [row["goal"]]:
            raise ValueError("proof task does not bind its unchanged exported source goal")
        lines = check_log(row, log, [str(solver), "-smt2", "-T:5", str(task)])
        ledger_row, _ = attempt_for(row["command"], log)
        if any(row.get(key) != ledger_row.get(key) for key in ("command", "exit_code", "timed_out", "seconds", "log")):
            raise ValueError("solver row differs from live process ledger")
        if lines not in (["sat"], ["unsat"]) or row.get("answer") != lines[0] or row.get("stdout") != lines[0]:
            raise ValueError("unknown/malformed/forged solver answer")
        tasks.add(task)
        logs.add(log)
        answers[row["goal"]] = lines[0]
    if len(tasks) != 5 or len(logs) != 5 or set((module / "tasks").glob("*.smt2")) != tasks:
        raise ValueError("undeclared or duplicate tasks/logs")
    counts = {"valid": list(answers.values()).count("unsat"), "invalid": list(answers.values()).count("sat"), "timeout": 0, "oom": 0, "step_limit": 0, "unknown": 0, "failure": 0}
    if raw.get("summary") != counts or any(type(raw["summary"].get(k)) is not int for k in counts):
        raise ValueError("proof counts differ from actual solver results")
    if expected_goal is not None and any(value != ("sat" if goal == expected_goal else "unsat") for goal, value in answers.items()):
        raise ValueError("negative oracle did not isolate its expected faulty goal")
    return {"outcome": "COUNTEREXAMPLE" if counts["invalid"] else "PROVED", "answers": answers, "summary": counts,
            "counterexample_values": "UNSUPPORTED: unchanged official task export does not request a model", "report_sha256": sha(out / (name + "-export-report.json"))}


def audit_native_control(out, name, steps, home):
    command = [str(home / "bin/moon"), "test", "--target", "native"]
    log = artifact(out, name + "-runtime.log")
    rows = [row for row in steps if type(row) is dict and row.get("command") == command and row.get("log") == str(log)]
    if len(rows) != 1:
        raise ValueError("missing/duplicate exact native boundary control process")
    lines = check_log(rows[0], log, command, 0 if name == "positive" else 2)
    identity = '[f4ah6o/composition_proof] test boundary_wbtest.mbt:2 ("range length machine limits and source-exact Unicode partitions") failed: '
    expected = {
        "positive": ["Total tests: 1, passed: 1, failed: 0."],
        "negative-range": [identity + "boundary_wbtest.mbt:3:3-3:79@f4ah6o/composition_proof FAILED: `-2147483647 != 2147483647`", "diff:", "--2147483647 +2147483647", "Total tests: 1, passed: 0, failed: 1."],
        "negative-utf8": [identity + "boundary_wbtest.mbt:19:5-19:49@f4ah6o/composition_proof FAILED: `2 != 1`", "diff:", "-2 +1", "Total tests: 1, passed: 0, failed: 1."],
    }
    if name not in expected or lines != expected[name]:
        raise ValueError("native control lacks its exact fixed boundary identity/site/value/summary")
    return {"qualified": True, "log_sha256": sha(log)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--turtles-bin", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--moon-home", type=Path, required=True)
    parser.add_argument("--why3", type=Path, required=True)
    parser.add_argument("--solver", type=Path, required=True)
    args = parser.parse_args(argv)
    return execute(args)


def execute(args):
    started = time.monotonic()
    root, home = args.source_root.resolve(strict=True), args.moon_home.resolve(strict=True)
    out = args.artifact_dir.absolute()
    if out.is_symlink() or out.resolve() == root or out.resolve().is_relative_to(root):
        raise ValueError("artifact directory must be a fresh directory outside the source checkout")
    # Refuse reuse without overwriting a previous success or consuming its files.
    out.mkdir(parents=True, exist_ok=False)
    out = out.resolve(strict=True)
    result = {"schema": 1, "profile": PROFILE, "run_id": str(uuid.uuid4()), "terminal": False,
              "started_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "status": "initializing", "ok": False,
              "mutants": [], "runtime_score_modified_by_proof": False,
              "excluded": ["composition transaction correctness", "Result lowering", "GUI/FFI/IME", "general machine overflow", "caller precondition establishment"],
              "solver_model_extraction": "UNSUPPORTED: no model requested; SAT alone is not a concrete replay input"}
    result["coverage"] = {"declarations": [{"source": path, "declaration": head, "role": "proved helper" if goal else "source-equivalent carrier", "goal": goal} for path, head, goal in TARGETS],
                          "discovery_target": "native", "production_runtime_target": "wasm", "proof_integer_model": "mathematical with explicit Int-fit preconditions",
                          "discovered_mutants": None, "evaluated_mutants": 0, "unexecuted_discovery_ids": [], "inventory_complete": False}
    write_json(out / "verification-report.json", result)
    before = None
    handlers = {}
    def interrupted(signum, _frame):
        raise KeyboardInterrupt("received signal " + str(signum))
    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            handlers[signum] = signal.signal(signum, interrupted)
        profile = load_profile(args.profile)
        pilot = PILOTS[profile["pilot_revision"]]
        binary, why3, solver = (p.resolve(strict=True) for p in (args.turtles_bin, args.why3, args.solver))
        if sha(binary) != profile["turtles_sha256"]:
            raise ValueError("turtles executable differs from profile pin")
        producer = load_producer(root, profile["pilot_revision"])
        template = root / pilot["template"]
        for name, expected in FIXED.items():
            if sha(artifact(template, name)) != expected:
                raise ValueError("reviewed proof input changed: " + name)
        if sha(artifact(template, "proof-toolchain.lock.json")) != LOCK_SHA256:
            raise ValueError("proof runtime lock differs from the independently reviewed pilot")
        implementation = (template / "implementation.mbt").read_text()
        contracts_hash = fixed_contracts(producer, implementation)
        lock = read_json(template / "proof-toolchain.lock.json")
        toolchain = tool_identity(lock, home, why3, solver)
        env = producer.sanitized_environment(dict(os.environ), home, solver)
        if any(env.get(name) for name in ("CC", "CFLAGS", "LDFLAGS", "MOON_CC")):
            raise ValueError("this bounded runtime profile does not qualify compiler overrides")
        cc = Path(shutil.which("cc", path=env["PATH"]) or "").resolve(strict=True)
        runtime_support = {"moonrun_sha256": sha(home / "bin/moonrun"), "cc": str(cc), "cc_sha256": sha(cc)}
        timeout = profile["timeout_seconds"]
        moon, moonc = home / "bin/moon", home / "bin/moonc"
        before = snapshot(root)
        origin = {}
        for name, reference in (("commit", "HEAD"), ("tree", "HEAD^{tree}")):
            log = out / ("origin-" + name + ".log")
            probe = run(["git", "rev-parse", reference], root, env, log, min(timeout, 10))
            text = check_log(probe, log, ["git", "rev-parse", reference])
            if len(text) != 1 or not re.fullmatch(r"[0-9a-f]{40}", text[0]):
                raise ValueError("cannot bind original production commit/tree")
            origin[name] = text[0]
        result["identity"] = {"profile_sha256": sha(args.profile), "adapter_sha256": sha(Path(__file__)),
                              "turtles_sha256": sha(binary), "producer_sha256": sha(root / PRODUCER),
                              "pilot_revision": profile["pilot_revision"], "proof_fixture_path": pilot["template"],
                              "fixed_inputs": FIXED, "fixed_contracts_sha256": contracts_hash,
                              "lock_sha256": sha(template / "proof-toolchain.lock.json"), "tools": toolchain,
                              "source_before": before, "target": profile["target"], "runtime_packages": profile["runtime_packages"],
                              "source_origin": origin,
                              "runtime_support": runtime_support,
                              "model_pbt_seeds": SEEDS, "model_pbt_count_per_seed": 1000}
        # A disposable source snapshot ensures even baseline-generated state
        # cannot alter the caller's checkout or a later mutant.
        source = out / "source"
        copy_source(root, source)
        git_env = {**{key: value for key, value in env.items() if not key.startswith("GIT_")}, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        for index, command in enumerate((["git", "init"], ["git", "add", "."],
                ["git", "-c", "user.name=turtles verification", "-c", "user.email=turtles@local.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "isolated verification source snapshot"])):
            attempt = run(command, source, git_env, out / f"snapshot-git-{index}.log", timeout)
            if attempt["exit_code"] != 0 or attempt["timed_out"]:
                raise ValueError("cannot establish isolated source snapshot")
        extracted, mappings = extract(source)
        if regenerate(producer, implementation, source) != implementation:
            # Whitespace is allowed by correspondence, but the baseline stays
            # byte-for-byte the reviewed proof template.
            for relative, head, _ in TARGETS:
                if producer.canonical(producer.declaration((source / relative).read_text(), head)) != producer.canonical(producer.declaration(implementation, head)):
                    raise ValueError("pristine proof body no longer corresponds to production")
        baseline_out = out / "baseline-proof"
        result["status"] = "qualifying-baseline"
        write_json(out / "verification-report.json", result)
        command = [sys.executable, str(source / PRODUCER), "--source-root", str(source), "--artifact-dir", str(baseline_out),
                   "--moon-home", str(home), "--why3", str(why3), "--solver", str(solver), "--timeout", str(timeout)]
        attempt = run(command, source, env, out / "baseline-proof-driver.log", timeout * 20)
        if attempt["exit_code"] != 0 or attempt["timed_out"]:
            raise ValueError("pristine proof/control qualification failed")
        baseline = read_json(artifact(baseline_out, "proof-result.json"))
        if baseline.get("terminal") is not True or baseline.get("ok") is not True or baseline.get("status") != "passed" or baseline.get("backend") != "why3-export-z3" or baseline.get("source_correspondence_verified") is not True or baseline.get("source_stable") is not True:
            raise ValueError("baseline proof is incomplete/inconclusive")
        baseline_id = baseline.get("run_id")
        uuid.UUID(baseline_id)
        source_binding = baseline.get("source_binding", {})
        expected_snapshot = producer.source_snapshot(source, out, env, "baseline-current", timeout, [])
        if source_binding.get("snapshot_before") != expected_snapshot or source_binding.get("snapshot_after") != expected_snapshot or source_binding.get("runner_sha256") != pilot["producer_sha256"] or source_binding.get("files") != {name: sha(source / name) for name in ("text/range.mbt", "text/document.mbt")} or source_binding.get("proof_files") != {pilot["template"] + "/" + name: sha(template / name) for name in (*FIXED, "proof-toolchain.lock.json")}:
            raise ValueError("baseline source/contract snapshot is stale or forged")
        bindings = baseline["toolchain"]["export_bindings"]
        baseline_audits = {}
        controls = {row.get("name"): row for row in baseline.get("negative_controls", []) if type(row) is dict}
        if set(controls) != {"negative-range", "negative-utf8"} or len(baseline.get("negative_controls", [])) != 2:
            raise ValueError("missing/duplicated negative controls")
        for name in ("positive", "negative-range", "negative-utf8"):
            target = None if name == "positive" else TARGETS[1 if name == "negative-range" else 2][2]
            expected = implementation
            if name != "positive":
                old, new = ("self.end - self.start", "self.start - self.end") if name == "negative-range" else ("if scalar <= 0x7F {", "if scalar < 0x7F {")
                index = expected.rfind(old) if name == "negative-range" else expected.index(old)
                expected = expected[:index] + new + expected[index + len(old):]
            audit = audit_export(baseline_out, baseline_out / name, name, bindings, lock, why3, home, solver, baseline_id, baseline.get("steps"), expected, target)
            audit["native_control"] = audit_native_control(baseline_out, name, baseline["steps"], home)
            if name == "positive" and audit["outcome"] != "PROVED":
                raise ValueError("pristine baseline has an actual solver counterexample")
            if name != "positive" and any(controls[name].get(k) is not True for k in ("runtime_counterexample", "sat_counterexample", "rejected")):
                raise ValueError("negative proof oracle is not runtime-sensitive")
            if name != "positive" and (controls[name].get("mutation") != [old, new] or controls[name].get("solver_verdict") != "unproved"):
                raise ValueError("negative control metadata describes an unrelated edit/verdict")
            baseline_audits[name] = audit
        result["baseline_proof"] = baseline_audits
        baseline_runtime_out = out / "baseline-runtime"
        baseline_runtime_out.mkdir()
        plan_command = [str(moon), "test", *profile["runtime_packages"], "--target", profile["target"], "--dry-run"]
        plan_log = out / "production-target-plan.log"
        plan = run(plan_command, source, env, plan_log, timeout)
        plan_lines = check_log(plan, plan_log, plan_command)
        active_sources = set()
        for line in plan_lines:
            words = shlex.split(line)
            if len(words) < 2 or Path(words[0]).name != "moonc" or words[1] != "build-package" or "-pkg" not in words or words[words.index("-pkg") + 1] != "f4ah6o/gpui/text" or "-target" not in words or words[words.index("-target") + 1] != profile["target"]:
                continue
            for word in words[2:]:
                if word.endswith(".mbt"):
                    path = Path(word)
                    actual = path if path.is_absolute() else source / path
                    if actual.resolve().is_relative_to(source):
                        active_sources.add(actual.resolve().relative_to(source).as_posix())
        if not {"text/range.mbt", "text/document.mbt"}.issubset(active_sources):
            raise ValueError("declared production source file is inactive or absent from Moon's actual target plan")
        result["identity"]["production_target_plan_sha256"] = sha(plan_log)
        pristine_files = snapshot(source)
        result["baseline_runtime"] = runtime(moon, source, env, baseline_runtime_out, profile["target"], profile["runtime_packages"], timeout)
        if result["baseline_runtime"]["outcome"] != "SURVIVED" or snapshot(source) != pristine_files:
            raise ValueError("pristine production runtime/PBT baseline failed")
        repeat_out = out / "baseline-runtime-repeat"
        repeat_out.mkdir()
        repeat_source = repeat_out / "source"
        copy_source(source, repeat_source)
        repeat_pristine = snapshot(repeat_source)
        result["baseline_runtime_repeat"] = runtime(moon, repeat_source, env, repeat_out, profile["target"], profile["runtime_packages"], timeout)
        if result["baseline_runtime_repeat"]["outcome"] != "SURVIVED" or snapshot(repeat_source) != repeat_pristine:
            raise ValueError("restored production runtime/PBT baseline was unstable or polluted source")
        helper = out / "helper-discovery"
        result["status"] = "discovering-mutants"
        helper.mkdir()
        (helper / "implementation.mbt").write_bytes(extracted)
        (helper / "moon.mod").write_text('name = "f4ah6o/composition_proof"\nversion = "0.0.0"\n')
        (helper / "moon.pkg").write_text('import { "moonbitlang/core/quickcheck", } for "wbtest"\n')
        shutil.copyfile(template / "boundary_wbtest.mbt", helper / "boundary_wbtest.mbt")
        (helper / "model_pbt_wbtest.mbt").write_text(MODEL_PBT)
        (helper / "turtles.toml").write_text('include = ["implementation.mbt"]\noperators = ["comparison", "boolean", "arithmetic", "literal", "condition"]\n')
        discovery_run = run([str(binary), "--dir", str(helper), "--target", "native", "--list"], helper, env, out / "helper-discovery.log", timeout)
        discovery_text = (out / "helper-discovery.log").read_text()
        inventory_count = re.findall(r"^Found (\d+) mutation\(s\)\.$", discovery_text, re.MULTILINE)
        if discovery_run["timed_out"] or discovery_run["exit_code"] != 0 or len(inventory_count) != 1 or not 1 <= int(inventory_count[0]) <= profile["max_mutants"] or "Skipped " in discovery_text or "target-inactive:" in discovery_text:
            raise ValueError("discovery must be nonempty, complete, active, and within max_mutants before execution")
        discovery_rows = re.findall(r"^(implementation\.mbt):(\d+):(\d+): (.*?) -> (.*?) \[(public|private)\]$", discovery_text, re.MULTILINE)
        if len(discovery_rows) != int(inventory_count[0]) or len(set(discovery_rows)) != len(discovery_rows):
            raise ValueError("discovery inventory contains unsupported multiline/duplicate candidate entries")
        result["coverage"]["discovered_mutants"] = len(discovery_rows)
        result["coverage"]["discovery_inventory"] = discovery_rows
        result["coverage"]["discovery_log_sha256"] = sha(out / "helper-discovery.log")
        write_json(out / "verification-report.json", result)
        report_path = out / "helper-runtime-report.json"
        turtle_command = [str(binary), "--dir", str(helper), "--target", "native", "--jobs", "1", "--timeout", str(timeout),
                          "--fail-under", "0", "--emit-regressions", "--json", str(report_path), "--output-dir", str(out / "helper-runtime-artifacts")]
        turtle_run = run(turtle_command, helper, env, out / "helper-turtles.log", timeout * (profile["max_mutants"] * 2 + 20))
        if turtle_run["exit_code"] != 0 or turtle_run["timed_out"]:
            raise ValueError("helper mutation discovery/runtime oracle failed")
        raw = read_json(report_path)
        rows = audit_turtles(raw, helper, extracted, profile["max_mutants"])
        if len(rows) != int(inventory_count[0]):
            raise ValueError("runtime campaign differs from fresh discovery inventory")
        if [(r["path"], str(r["line"]), str(r["column"]), r["original"], r["replacement"], r["visibility"]) for r in rows] != discovery_rows:
            raise ValueError("runtime mutation identities differ from fresh discovery")
        write_json(out / "discovered-mutants.json", rows)
        result["coverage"].update(inventory_complete=True, inventory="discovered-mutants.json", inventory_sha256=sha(out / "discovered-mutants.json"),
                                  discovery_ids=[row["id"] for row in rows])
        result["helper_runtime_report"] = {"path": report_path.name, "sha256": sha(report_path), "summary": raw["summary"]}
        write_json(out / "source-mappings.json", mappings)
        result["status"] = "evaluating-mutants"
        # Each edit is applied to actual isolated production, then the proof
        # module is rebuilt from that production body with fixed contracts.
        for index, row in enumerate(rows):
            mapped = map_mutation(row, extracted, mappings, source)
            campaign = out / f"mutant-{index:03}"
            campaign.mkdir()
            mutated = campaign / "source"
            copy_source(source, mutated)
            file = mutated / mapped["path"]
            original = file.read_bytes()
            file.write_bytes(original[:mapped["offset"]] + mapped["replacement"].encode() + original[mapped["end"]:])
            mutant_before = snapshot(mutated)
            candidate = {"id": mapped["production_mutant_id"], "discovery_id": row["id"], "source_edit": mapped,
                         "source_before_sha256": sha(source / mapped["path"]), "source_mutant_sha256": sha(file),
                         "helper_runtime": {"outcome": row["outcome"], "killed_by": row.get("killed_by", []), "regressions": [p for p in raw.get("regressions", []) if row["id"] in p]},
                         "proof": {"outcome": "INCONCLUSIVE"}}
            candidate["runtime"] = runtime(moon, mutated, env, campaign, profile["target"], profile["runtime_packages"], timeout)
            proof_out = campaign / "proof"
            proof_out.mkdir()
            try:
                regenerated = regenerate(producer, implementation, mutated)
                if fixed_contracts(producer, regenerated) != contracts_hash:
                    raise ValueError("mutant generation changed a reviewed contract/witness")
                candidate["proof_binding"] = {"implementation_sha256": hashlib.sha256(regenerated.encode()).hexdigest(), "fixed_contracts_sha256": contracts_hash,
                                               "source_sha256": sha(file), "run_id": str(uuid.uuid4())}
                module = proof_out / "positive"
                module.mkdir()
                for name in ("spec.mbtp", "boundary_wbtest.mbt", "moon.pkg"):
                    shutil.copyfile(template / name, module / name)
                (module / "implementation.mbt").write_text(regenerated)
                (module / "moon.mod").write_text('name = "f4ah6o/composition_proof"\nversion = "0.0.0"\nsource = "."\n')
                candidate["proof_binding"]["tools"] = tool_identity(lock, home, why3, solver)
                steps = []
                mutant_env = producer.sanitized_environment(dict(os.environ), home, solver)
                mutant_bindings = producer.bind_export_runtime(why3, home, proof_out, mutant_env, lock, timeout, steps, candidate["proof_binding"]["run_id"])
                candidate["proof_binding"]["export_context"] = mutant_bindings
                for label, command in (("typecheck", [str(moon), "check"]), ("emit", [str(moonc), "prove", "implementation.mbt", "spec.mbtp", "-i", str(home / "lib/core/_build/wasm/release/bundle/prelude/prelude.mi") + ":prelude", "-pkg", "f4ah6o/composition_proof", "-pkg-type", "library", "-emit-only", "-whyml-output-path", str(module / "implementation.mlw"), "-proof-report-output-path", str(module / "emit-only.json")])):
                    attempt = producer.run(command, module, mutant_env, proof_out / (label + ".log"), timeout)
                    steps.append({"stage": label, **attempt})
                    if attempt["timed_out"] or attempt["exit_code"] != 0:
                        raise ValueError("proof lowering/typecheck unsupported or failed: " + label)
                try:
                    original_run = producer.run
                    def recorded_run(*arguments, **keywords):
                        attempt = original_run(*arguments, **keywords)
                        steps.append(attempt)
                        return attempt
                    producer.run = recorded_run
                    producer.export_solve("positive", module, proof_out, why3, home, solver, mutant_env, timeout, lock, mutant_bindings)
                except ValueError as error:
                    # Only this exact terminal expectation mismatch is allowed
                    # through to raw independent audit. All other errors stop.
                    if str(error) != "positive did not establish its exact expected solver outcomes":
                        raise
                finally:
                    producer.run = original_run
                    write_json(proof_out / "process-ledger.json", steps)
                candidate["proof"] = audit_export(proof_out, module, "positive", mutant_bindings, lock, why3, home, solver, candidate["proof_binding"]["run_id"], steps, regenerated)
                sat_goals = [goal for goal, answer in candidate["proof"]["answers"].items() if answer == "sat"]
                if any(goal != mapped["goal"] for goal in sat_goals):
                    raise ValueError("candidate proof counterexample affects an unrelated helper/witness")
                if sha(module / "implementation.mbt") != candidate["proof_binding"]["implementation_sha256"] or fixed_contracts(producer, (module / "implementation.mbt").read_text()) != contracts_hash:
                    raise ValueError("candidate executable/contracts changed during verification")
                if tool_identity(lock, home, why3, solver) != toolchain:
                    raise ValueError("tools changed during candidate verification")
            except (OSError, ValueError, KeyError, TypeError) as error:
                candidate["proof"] = {"outcome": "INCONCLUSIVE", "reason": str(error)}
            if snapshot(mutated) != mutant_before:
                candidate["runtime"] = {"outcome": "INCONCLUSIVE", "reason": "source changed during isolated runtime/proof checks"}
                candidate["proof"] = {"outcome": "INCONCLUSIVE", "reason": "source changed during isolated runtime/proof checks"}
            if candidate["proof"]["outcome"] == "PROVED" and candidate["helper_runtime"]["outcome"] == "KILLED":
                candidate["proof"] = {"outcome": "INCONCLUSIVE", "reason": "proof/model-oracle disagreement on a declared valid-input helper", "observed_solver": candidate["proof"]}
            if candidate["proof"]["outcome"] == "PROVED" and candidate["runtime"]["outcome"] == "SURVIVED" and candidate["helper_runtime"]["outcome"] == "SURVIVED":
                candidate["equivalence"] = {"classification": "EQUIVALENT_UNDER_DECLARED_CONTRACT", "reason": "All five actual goals are UNSAT for the source-corresponding mutant with the fixed exact range/Unicode width postconditions. This covers only valid inputs under these contracts."}
            try:
                candidate["regression_replay"] = regression_replay(candidate, row, source, campaign, moon, env, profile)
            except (OSError, ValueError, KeyError, TypeError) as error:
                candidate["regression_replay"] = {"status": "inconclusive", "reason": str(error)}
            write_json(proof_out / "candidate-evidence.json", candidate)
            result["mutants"].append(candidate)
            write_json(campaign / "replay.json", {"schema": 1, "production_mutant_id": candidate["id"], "source_edit": mapped,
                                                  "source_sha256": candidate["source_before_sha256"], "target": profile["target"], "runtime_packages": profile["runtime_packages"],
                                                  "seeds": SEEDS, "regression_templates": candidate["helper_runtime"]["regressions"],
                                                  "solver_values": "unsupported", "automatic_test_repair": False})
            write_json(out / "verification-report.json", result)
        runtime_counts = Counter(row["runtime"]["outcome"] for row in result["mutants"])
        proof_counts = Counter(row["proof"]["outcome"] for row in result["mutants"])
        viable = sum(runtime_counts[k] for k in ("KILLED", "SURVIVED", "TIMEOUT"))
        result["summary"] = {"mutants": len(rows), "production_runtime": dict(runtime_counts), "proof": dict(proof_counts),
                             "runtime_viable": viable, "runtime_score": 100 * runtime_counts["KILLED"] / viable if viable else None,
                             "proof_counterexamples_added_to_runtime_kills": 0,
                             "equivalents_under_contract": sum("equivalence" in row for row in result["mutants"])}
        if sha(home / "bin/moonrun") != runtime_support["moonrun_sha256"] or sha(cc) != runtime_support["cc_sha256"]:
            raise ValueError("runtime support binaries changed during campaign")
        result["ok"] = not proof_counts["INCONCLUSIVE"] and not runtime_counts["INCONCLUSIVE"] and not runtime_counts["TIMEOUT"] and all(row["regression_replay"]["status"] in ("replayed", "unsupported") for row in result["mutants"])
        result["status"] = "complete" if result["ok"] else "inconclusive"
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result["status"] = "blocked"
        result["reason"] = str(error)
    except KeyboardInterrupt as error:
        result["status"] = "interrupted"
        result["reason"] = str(error) or "interrupted"
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
        if before is not None:
            after = snapshot(root)
            result["source_after"] = after
            result["source_stable"] = before == after
            if before != after:
                result["ok"], result["status"], result["reason"] = False, "inconclusive", "caller source changed during campaign"
        result["terminal"] = True
        result["coverage"]["evaluated_mutants"] = len(result["mutants"])
        evaluated = {row["discovery_id"] for row in result["mutants"]}
        result["coverage"]["unexecuted_discovery_ids"] = [identity for identity in result["coverage"].get("discovery_ids", []) if identity not in evaluated]
        result["finished_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        result["seconds"] = time.monotonic() - started
        write_json(out / "verification-report.json", result)
    print(json.dumps({key: result.get(key) for key in ("ok", "status", "reason", "summary")}))
    return 0 if result["ok"] else 2


def regression_replay(candidate, row, source, campaign, moon, env, profile):
    """Replay only the known range-model tuple format; never guess a model.

    This adds a test to disposable snapshots only. It is not an automatic
    production edit, and solver SAT still carries no concrete model values.
    """
    if candidate["source_edit"]["head"] != "pub fn TextRange::length(":
        return {"status": "unsupported", "reason": "no concrete typed replay input exposed for this helper"}
    witnesses = [kill.get("counterexample") for kill in row.get("killed_by", []) if kill.get("filename") == "model_pbt_wbtest.mbt" and kill.get("test_name") == "independent range reconstruction model fixed seeded PBT" and kill.get("kind") == "Property"]
    if len(witnesses) != 1 or type(witnesses[0]) is not str:
        return {"status": "unsupported", "reason": "no unique concrete range-model PBT witness"}
    match = re.fullmatch(r"\((-?\d+), (-?\d+)\)", witnesses[0])
    if not match:
        return {"status": "unsupported", "reason": "unrecognized shrunk tuple representation"}
    values = [int(value) for value in match.groups()]
    if any(not -2147483648 <= value <= 2147483647 for value in values):
        return {"status": "unsupported", "reason": "shrunk tuple outside signed Int model"}
    start, end = sorted(value & 0x7FFFFFFF for value in values)
    test_name = "turtles deterministic shrunk range regression"
    code = f'///|\ntest "{test_name}" {{\n  assert_eq(({{ start: {start}, end: {end} }} : TextRange).length(), {end - start})\n}}\n'
    (campaign / "counterexample_regression.mbt").write_text(code)
    result = {"status": "checking", "origin": "independent helper-model QuickCheck shrunk witness", "raw_input": witnesses[0],
              "concrete_valid_input": {"start": start, "end": end}, "expected": end - start,
              "regression_file": "counterexample_regression.mbt", "regression_sha256": sha(campaign / "counterexample_regression.mbt"), "automatic_source_repair": False}
    for name in ("regression-pristine", "regression-remutated"):
        out = campaign / name
        out.mkdir()
        checkout = out / "source"
        copy_source(source, checkout)
        if name == "regression-remutated":
            mapped = candidate["source_edit"]
            path = checkout / mapped["path"]
            data = path.read_bytes()
            if data[mapped["offset"]:mapped["end"]] != mapped["original"].encode():
                raise ValueError("regression remutation source mismatch")
            path.write_bytes(data[:mapped["offset"]] + mapped["replacement"].encode() + data[mapped["end"]:])
        (checkout / "text/turtles_counterexample_regression_wbtest.mbt").write_text(code)
        tested = runtime(moon, checkout, env, out, profile["target"], profile["runtime_packages"], profile["timeout_seconds"])
        result[name] = tested
    if result["regression-pristine"]["outcome"] != "SURVIVED" or result["regression-remutated"]["outcome"] != "KILLED" or not any(kill["test_name"] == test_name and kill["filename"] == "turtles_counterexample_regression_wbtest.mbt" for kill in result["regression-remutated"]["killed_by"]):
        raise ValueError("deterministic regression/re-mutation replay did not establish its exact assertion control")
    result["status"] = "replayed"
    return result


def audit_turtles(report, helper, extracted, maximum):
    if type(report) is not dict or type(report.get("schema")) is not int or report["schema"] != 3 or report.get("turtles_version") != "0.3.0" or report.get("module") != str(helper) or report.get("target") != "native" or report.get("test_scope") != "module" or report.get("skipped_files") != [] or type(report.get("inactive_mutants")) is not int or report["inactive_mutants"] != 0 or report.get("inactive_files") != []:
        raise ValueError("requires a fresh exact schema-3 native helper campaign without skips")
    expected_files = {p.name: fnv(p.read_bytes()) for p in helper.iterdir() if p.is_file()}
    if report.get("files") != expected_files or (helper / "implementation.mbt").read_bytes() != extracted:
        raise ValueError("helper campaign source/tests/configuration binding changed")
    rows = report.get("mutants")
    if type(rows) is not list or not 1 <= len(rows) <= maximum:
        raise ValueError("empty or unbounded helper mutant inventory")
    identities = set()
    counts = Counter()
    for row in rows:
        if type(row) is not dict or row.get("reused") is not False or row.get("path") != "implementation.mbt" or row.get("group") not in {"comparison", "boolean", "arithmetic", "literal", "condition"} or row.get("outcome") not in {"KILLED", "SURVIVED", "TIMEOUT", "UNVIABLE"}:
            raise ValueError("invalid/reused helper mutant verdict")
        identity = f'{row["path"]}\0{row["offset"]}\0{row["end"]}\0{row["original"]}\0{row["replacement"]}\0{row["group"]}'
        if row.get("id") != "m-" + fnv(identity.encode()) or row["id"] in identities:
            raise ValueError("forged/duplicate helper mutant identity")
        if any(type(row.get(k)) is not int for k in ("offset", "end", "line", "column")) or type(row.get("original")) is not str or type(row.get("replacement")) is not str:
            raise ValueError("invalid helper mutation coordinates/text")
        if type(row.get("duration_ms")) is not str or not row["duration_ms"].isdigit():
            raise ValueError("missing helper runtime timing")
        if row["outcome"] == "KILLED" and (not row.get("killed_by") or row.get("attribution") == "unavailable"):
            raise ValueError("helper runtime kill lacks actual test attribution")
        if row["outcome"] == "KILLED" and (type(row["killed_by"]) is not list or any(type(kill) is not dict or any(type(kill.get(key)) is not str for key in ("package", "filename", "test_name")) or type(kill.get("index")) is not int or kill.get("kind") not in {"Property", "Snapshot", "DocTest", "Assertion"} for kill in row["killed_by"])):
            raise ValueError("malformed concrete helper kill attribution")
        identities.add(row["id"])
        counts[row["outcome"].lower()] += 1
    if any(type(report.get("summary", {}).get(k)) is not int or report["summary"][k] != counts[k] for k in ("killed", "survived", "timeout", "unviable")) or type(report.get("summary", {}).get("reused")) is not int or report["summary"]["reused"] != 0:
        raise ValueError("helper runtime summary differs from actual rows")
    return rows


MODEL_PBT = '''///|
test "independent Unicode bit-width model over all valid scalars" {
  for scalar = 0; scalar <= 0x10FFFF; scalar = scalar + 1 {
    if scalar < 0xD800 || scalar > 0xDFFF {
      let width8 = if scalar / 128 == 0 { 1 } else if scalar / 2048 == 0 { 2 } else if scalar / 65536 == 0 { 3 } else { 4 }
      let width16 = if scalar / 65536 == 0 { 1 } else { 2 }
      assert_eq(utf8_scalar_width(scalar), width8)
      assert_eq(utf16_scalar_width(scalar), width16)
    }
  }
}

///|
test "independent range reconstruction model fixed seeded PBT" {
  for seed in [1UL, 1777UL, 4242UL, 65535UL] {
    @quickcheck.check((input : (Int, Int)) => {
      let (a, b) = input
      let left = a & 0x7FFFFFFF
      let right = b & 0x7FFFFFFF
      let start = if left <= right { left } else { right }
      let end = if left <= right { right } else { left }
      let length = ({ start, end } : TextRange).length()
      length >= 0 && length <= 2147483647 && start + length == end
    }, count=1000, seed~)
  }
}
'''


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(json.dumps({"ok": False, "status": "blocked", "reason": str(error)}))
        sys.exit(2)
