#!/usr/bin/env python3
"""Reproducible Weld benchmarks; all mutable inputs live in disposable runs.

Cold means empty Weld/work caches in a new input copy, not a flushed kernel page
cache. Tool dependency resolution/compilation is recorded outside the samples.
Each operation receives exactly one cold and five warm, fresh-VM observations.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import shutil
import signal
import statistics
import subprocess
import sys
import time
import uuid

BASELINE = "7897ba6457d3ba725ee3a843bc863f2c38e90411"
CHECKPOINT = "0ff6f9ef7a66048abaf00f4f24e5464ca2d90c37"
IGNORED = {".git", ".weld", "deps", "_build"}
OPERATIONS = {"plan", "full", "live", "full_cache", "live_cache", "verify", "docs", "native"}
ROOT = Path(__file__).resolve().parents[2]


def write_json(path: Path, value: object) -> None:
    temporary = path.with_name(path.name + ".new")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def relative(value: str) -> Path:
    path = Path(value)
    if path.is_absolute() or not path.parts or any(p in (".", "..") for p in path.parts):
        raise ValueError(f"expected a confined relative path: {value}")
    return path


def safe_tree(root: Path) -> None:
    for parent, directories, files in os.walk(root, followlinks=False):
        directories[:] = sorted(d for d in directories if d not in IGNORED)
        for name in directories + files:
            path = Path(parent, name)
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise ValueError(f"benchmark inputs require regular files/directories: {path}")


def inventory(root: Path) -> dict:
    entries = []
    for parent, directories, files in os.walk(root, followlinks=False):
        directories[:] = sorted(d for d in directories if d not in IGNORED)
        for name in sorted(files):
            path = Path(parent, name)
            stat = path.stat()
            entries.append([path.relative_to(root).as_posix(), stat.st_mode & 0o777,
                            stat.st_size, hashlib.sha256(path.read_bytes()).hexdigest()])
    encoded = json.dumps(sorted(entries), separators=(",", ":")).encode()
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "files": len(entries),
            "bytes": sum(row[2] for row in entries)}


def disk_bytes(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())


def cache_bytes(source: Path) -> int:
    candidates = [source / "deps", source / "_build"]
    state = source / ".weld"
    if state.exists():
        candidates.extend(path for path in state.rglob("*") if path.name in {"cache", "deps", "_build"} and path.is_dir() and not path.is_symlink())
    selected = []
    for path in sorted(candidates, key=lambda item: len(item.parts)):
        if not any(parent == path or parent in path.parents for parent in selected):
            selected.append(path)
    return sum(disk_bytes(path) for path in selected)


def synthetic(target: Path, projects: int, files: int, artifacts: int) -> dict:
    if projects < 4 or not 1 <= artifacts <= projects or files < projects * 2:
        raise ValueError("synthetic needs >=4 projects, 1..projects artifacts and >=2 files/project")
    target.mkdir(parents=True, exist_ok=False)
    edges = []
    scopes = ("runtime", "compile", "test", "docs", "optional")
    for index in range(projects):
        project = target / "projects" / f"p{index:04d}"
        (project / "lib").mkdir(parents=True)
        dependencies = []
        # Always keep an acyclic runtime spine, plus another scope when possible.
        candidates = [(index - 1, "runtime")] if index else []
        if index >= 2:
            candidates.append((index - 2, scopes[index % len(scopes)]))
        for dependency, scope in candidates:
            options = {"runtime": "", "compile": ", runtime: false",
                       "test": ", only: :test", "docs": ", only: :docs, runtime: false",
                       "optional": ", optional: true"}[scope]
            dependencies.append(f'{{:weld_bench_p{dependency:04d}, path: "../p{dependency:04d}"{options}}}')
            edges.append({"from": index, "to": dependency, "scope": scope})
        (project / "mix.exs").write_text(
            f"defmodule WeldBench.P{index:04d}.MixProject do\n  use Mix.Project\n"
            f"  def project, do: [app: :weld_bench_p{index:04d}, version: \"0.1.0\", "
            f"elixir: \"~> 1.18\", deps: [{', '.join(dependencies)}]]\n"
            "  def application, do: []\nend\n")
        (project / "lib" / f"p{index:04d}.ex").write_text(
            f"defmodule WeldBench.P{index:04d} do\n  def value, do: {index}\nend\n")
    for index in range(files - projects * 2):
        project = target / "projects" / f"p{index % projects:04d}" / "priv" / "assets"
        project.mkdir(parents=True, exist_ok=True)
        (project / f"f{index:07d}.txt").write_text(f"weld deterministic benchmark input {index}\n")
    identifiers = [f"bench_{index:03d}" for index in range(artifacts)]
    for family in ("baseline", "current"):
        definitions = []
        for index, artifact in enumerate(identifiers):
            root_index = ((index + 1) * projects // artifacts) - 1
            layout = "layout: :components, " if family == "current" else ""
            publish = "hex_publish_check" if family == "current" else "hex_publish"
            output_key = "files" if family == "current" else "output"
            definitions.append(
                f"    {artifact}: [{layout}roots: [\"projects/p{root_index:04d}\"], "
                f"package: [name: \"{artifact}\", otp_app: :{artifact}, version: \"0.1.0\", "
                "description: \"Deterministic Weld benchmark\", licenses: [\"MIT\"], "
                "links: %{\"Source\" => \"https://example.test/weld-benchmark\"}], "
                f"{output_key}: [docs: [\"README.md\"]], "
                f"verify: [hex_build: false, {publish}: false]]")
        key = "projects" if family == "current" else "project_globs"
        schema = "  schema: 2,\n" if family == "current" else ""
        (target / f"benchmark-{family}.exs").write_text(
            f"[\n{schema}  workspace: [root: \".\", {key}: [\"projects/*\"]],\n"
            "  artifacts: [\n" + ",\n".join(definitions) + "\n  ]\n]\n")
    (target / "README.md").write_text("# Deterministic Weld benchmark\n")
    (target / ".gitignore").write_text(".weld/\n_build/\ndeps/\n")
    actual = list((target / "projects").rglob("*"))
    observed = {"projects": len(list((target / "projects").glob("*/mix.exs"))),
                "project_files": sum(path.is_file() for path in actual), "artifacts": len(identifiers)}
    if observed != {"projects": projects, "project_files": files, "artifacts": artifacts}:
        raise RuntimeError(f"synthetic count mismatch: {observed}")
    result = {"schema": "weld.benchmark-synthetic/2", **observed, "artifact_ids": identifiers,
              "edges": edges, "edge_scopes": sorted({edge["scope"] for edge in edges}),
              "file_count_scope": "regular files under projects/, including mix.exs and source",
              "manifest_adapters": {"baseline": "benchmark-baseline.exs", "current": "benchmark-current.exs"}}
    write_json(target / "synthetic.json", result)
    result["workspace_inventory"] = inventory(target)
    return result


def environment(tool: Path) -> dict[str, str]:
    env = dict(os.environ)
    archives = Path(env.get("MIX_ARCHIVES", str(Path(env.get("MIX_HOME", str(Path.home() / ".mix"))) / "archives"))).expanduser().absolute()
    for key in list(env):
        if key.startswith("GIT_") or key in {"MIX_EXS", "MIX_LOCKFILE", "MIX_TARGET", "MIX_BUILD_PATH",
                "MIX_DEPS_PATH", "MIX_ENV", "ELIXIR_ERL_OPTIONS", "HEX_API_KEY", "HEX_API_KEY_NAME",
                "HEX_API_TOKEN", "HEX_TOKEN", "HEX_USERNAME", "HEX_PASSWORD", "WELD_QC_SANDBOX_API_KEY"}:
            env.pop(key, None)
    env.update({"MIX_ENV": "dev", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C.UTF-8",
                "MIX_BUILD_PATH": str(tool / "_build"), "MIX_DEPS_PATH": str(tool / "deps"),
                "MIX_HOME": str(tool.parent / "mix-home"), "HEX_HOME": str(tool.parent / "hex-home"),
                "MIX_ARCHIVES": str(archives), "MIX_REBAR3": str(tool.parent / "mix-home/rebar3")})
    return env


def session_members(leader: int) -> list[int]:
    processes = []
    for record in Path("/proc").glob("[0-9]*/stat"):
        try:
            fields = record.read_text().rsplit(") ", 1)[1].split()
            if int(fields[3]) == leader and fields[0] != "Z":
                processes.append(int(record.parent.name))
        except (OSError, ValueError, IndexError):
            continue
    return processes


def signal_session(leader: int, sig: int) -> None:
    # GNU timeout and native tools may create child process groups. On Linux,
    # terminate every process in our isolated session, not only its first group.
    for pid in sorted(session_members(leader), key=lambda pid: pid == leader):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass
    try:
        os.killpg(leader, sig)
    except ProcessLookupError:
        pass


def command(argv: list[str], cwd: Path, env: dict, log: Path, timeout: int) -> int:
    """Bound logs and terminate the entire disposable process group on timeout."""
    started = time.monotonic()
    with log.open("xb") as output:
        os.fchmod(output.fileno(), 0o600)
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True, umask=0o077)
        try:
            size = 0
            forced = None
            while True:
                if time.monotonic() - started > timeout:
                    forced = 124
                    break
                ready, _, _ = select.select([process.stdout], [], [], 0.5)
                if ready:
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > 32 * 1024 * 1024:
                        forced = 125
                        break
                    output.write(chunk)
            if forced is None:
                try:
                    return process.wait(timeout=max(0.1, timeout - (time.monotonic() - started)))
                except subprocess.TimeoutExpired:
                    forced = 124
            output.write(f"\nbenchmark stopped process session: exit {forced}\n".encode())
            return forced
        finally:
            # Also runs after Ctrl-C or a reader error; no detached benchmark
            # compiler should survive a stopped driver.
            signal_session(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                signal_session(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            signal_session(process.pid, signal.SIGKILL)
            deadline = time.monotonic() + 2
            while session_members(process.pid):
                if time.monotonic() >= deadline:
                    raise RuntimeError("benchmark process session did not terminate after SIGKILL")
                time.sleep(0.02)
            process.stdout.close()


def git(cwd: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=cwd, stderr=subprocess.PIPE,
                                   env=environment(cwd), timeout=60, text=True).strip()


def copy_input(source: Path, destination: Path) -> dict:
    safe_tree(source)
    before = inventory(source)
    shutil.copytree(source, destination, ignore=lambda _path, names: sorted(set(names) & IGNORED))
    if inventory(destination) != before or inventory(source) != before:
        raise RuntimeError("input changed while copying; benchmark refused")
    git(destination, "init", "--quiet")
    git(destination, "config", "user.name", "Weld benchmark")
    git(destination, "config", "user.email", "benchmark@example.test")
    return before


def load_cases(path: Path) -> list[dict]:
    document = json.loads(path.read_text())
    if document.get("schema") != "weld.benchmark-cases/2" or not isinstance(document.get("cases"), list):
        raise ValueError("expected weld.benchmark-cases/2 with a cases list")
    seen = set()
    for case in document["cases"]:
        name = case["name"]
        if not name or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789_-" for c in name) or name in seen:
            raise ValueError("case names must be unique lowercase path-safe identifiers")
        seen.add(name)
        case["path"] = str(Path(case["path"]).expanduser().resolve(strict=True))
        if not case.get("operations") or not set(case["operations"]) <= OPERATIONS:
            raise ValueError(f"invalid operations for {name}")
        for configuration in case["configs"].values():
            relative(configuration["manifest"])
            if not configuration.get("artifacts") or not all(isinstance(a, str) and a for a in configuration["artifacts"]):
                raise ValueError(f"explicit artifact list required for {name}")
            if configuration.get("manifest_source"):
                supplied = Path(configuration["manifest_source"]).expanduser()
                configuration["manifest_source"] = str((path.parent / supplied).resolve(strict=True))
        if "native" in case["operations"] and not case.get("native_command"):
            raise ValueError(f"native operation requires an explicit native_command for {name}")
    return document["cases"]


def summaries(samples: list[dict]) -> list[dict]:
    groups = {}
    for sample in samples:
        groups.setdefault((sample["revision_index"], sample["requested_ref"], sample["revision"], sample["case"], sample["operation"]), []).append(sample)
    output = []
    for (revision_index, requested_ref, revision, case, operation), values in groups.items():
        successful = [v for v in values if v["status"] == "ok" and v["sample"] != "cold"]
        metrics = {}
        keys = sorted({key for value in values for key, number in value["metrics"].items()
                       if number is None or (isinstance(number, (int, float)) and not isinstance(number, bool))})
        for key in keys:
            numbers = [v["metrics"][key] for v in successful if isinstance(v["metrics"].get(key), (int, float))]
            metrics[key] = {"median": statistics.median(numbers) if numbers else None,
                            "max": max(numbers) if numbers else None, "n": len(numbers),
                            "availability": "measured" if numbers else "not_available"}
        output.append({"revision_index": revision_index, "requested_ref": requested_ref, "revision": revision, "case": case, "operation": operation,
                       "status": "ok" if len(values) == 6 and all(v["status"] == "ok" for v in values) else "failed",
                       "cold": next((v["metrics"] for v in values if v["sample"] == "cold"), None),
                       "warm_successes": len(successful), "warm": metrics})
    return output


def benchmark(args: argparse.Namespace) -> int:
    missing = [name for name in ("git", "elixir", "erl", "mix", "time") if not shutil.which(name)]
    if missing:
        raise RuntimeError("benchmark prerequisites unavailable: " + ", ".join(missing))
    gnu_time = shutil.which("time")
    if "GNU" not in subprocess.check_output([gnu_time, "--version"], text=True, stderr=subprocess.STDOUT):
        raise RuntimeError("benchmark requires GNU time for peak RSS and elapsed observations")
    # Only the product's setup command creates state ownership. This harness
    # creates a new QC directory inside already initialized, ignored state.
    owner = ROOT / ".weld/v2/OWNER"
    if owner.is_symlink() or not owner.is_file() or owner.read_bytes() != b"weld.state/2\n":
        raise RuntimeError("run mix weld setup in this checkout before the benchmark")
    for ancestor in (ROOT / ".weld", ROOT / ".weld/v2", ROOT / ".weld/v2/runs", ROOT / ".weld/v2/runs/qc"):
        if ancestor.is_symlink():
            raise ValueError(f"unsafe benchmark scratch ancestor: {ancestor}")
    run = ROOT / ".weld/v2/runs/qc" / ("benchmark-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:8])
    run.mkdir(parents=True, exist_ok=False)
    print(run, flush=True)
    report = {"schema": "weld.benchmark-report/2", "status": "running", "run": str(run),
              "machine": {"platform": platform.platform(), "cpu_count": os.cpu_count(), "load_average": os.getloadavg()},
              "method": "one cold empty-Weld-cache input and five warm fresh VMs; no kernel cache flush; tool compilation excluded",
              "runtime_status": "execution_requested", "samples": [], "preparation": [], "revisions": [],
              "source_worktree_dirty": bool(git(ROOT, "status", "--porcelain=v1", "--untracked-files=all")),
              "revision_policy": "explicit Git commits only; dirty working-tree edits are never silently overlaid onto HEAD",
              "metric_notes": {"peak_rss_kib": "GNU time maximum resident set; not concurrent process-tree RSS sum",
                "subprocess_count": "spawn_executable open_port calls in the benchmark VM; descendant VM/native launches excluded; null if unsupported",
                "phase_times": "*_call_ms are Erlang call_time counters; other *_ms are monotonic wall durations; nested phases must not be summed",
                "copied_bytes": "successful outermost Erlang file.copy return byte counts; generated writes are separate from copies",
                "cache_bytes": "topmost cache/deps/_build directories in input state, including private verification run caches",
                "native_compile_ms": "compiler command inclusive time only for declared native cases; isolated native command has native_ms",
                "unavailable": "null means no instrumentation in this revision; zero is a measured zero"}}
    path = run / "report.json"
    write_json(path, report)
    try:
        if args.synthetic:
            source = run / "synthetic-input"
            facts = synthetic(source, args.projects, args.files, args.artifacts)
            report["synthetic"] = facts
            cases = [{"name": "synthetic", "path": str(source), "operations": ["plan", "full", "live", "full_cache", "live_cache"],
                      "configs": {family: {"manifest": f"benchmark-{family}.exs", "artifacts": facts["artifact_ids"]}
                                  for family in ("baseline", "current")}}]
        else:
            cases = load_cases(Path(args.cases).resolve())
        for number, ref in enumerate(args.refs or ["HEAD"]):
            revision = git(ROOT, "rev-parse", "--verify", ref + "^{commit}")
            family = "baseline" if revision == BASELINE else "checkpoint" if revision == CHECKPOINT else "current"
            directory = run / f"revision-{number:02d}-{revision[:12]}"
            directory.mkdir()
            tool = directory / "tool"
            git(ROOT, "clone", "--quiet", "--no-hardlinks", "--no-checkout", "--", str(ROOT), str(tool))
            git(tool, "checkout", "--quiet", "--detach", revision)
            env = environment(tool)
            report["revisions"].append({"index": number, "requested": ref, "commit": revision, "family": family, "tool_path": str(tool)})
            ready = True
            for index, argv in enumerate((["mix", "local.rebar", "--force"], ["mix", "deps.get"],
                                           ["git", "diff", "--exit-code", "--", "mix.lock"], ["mix", "compile"])):
                log = directory / f"prepare-{index}.log"
                status = command(argv, tool, env, log, args.timeout)
                report["preparation"].append({"revision": revision, "argv": argv, "exit_status": status, "log": str(log)})
                write_json(path, report)
                if status:
                    ready = False
                    break
            if not ready:
                continue
            for case in cases:
                configuration = case["configs"].get(ref) or case["configs"].get(revision) or case["configs"].get(family)
                if not configuration and family == "checkpoint":
                    configuration = case["configs"].get("current")
                if not configuration:
                    raise ValueError(f"no manifest configuration for {case['name']} at {ref}")
                for operation in case["operations"]:
                    work = directory / case["name"] / operation
                    work.mkdir(parents=True)
                    source = work / "input"
                    source_facts = copy_input(Path(case["path"]), source)
                    manifest = source / relative(configuration["manifest"])
                    if configuration.get("manifest_source"):
                        manifest.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(configuration["manifest_source"], manifest)
                    if not manifest.is_file() or manifest.is_symlink():
                        raise ValueError(f"missing benchmark manifest: {manifest}")
                    request = {"manifest": str(manifest), "artifacts": configuration["artifacts"],
                               "source": str(source), "native": case.get("native", False),
                               "native_command": case.get("native_command"), "docs_command": case.get("docs_command"),
                               "native_env": case.get("native_env", {}), "qualification_context": case.get("qualification_context", {}),
                               "log_root": str(work), "timeout": args.timeout}
                    request_path = work / "request.json"
                    write_json(request_path, request)
                    driver = ["mix", "run", "--no-compile", "--no-start", str(ROOT / "scripts/qc/benchmark_driver.exs"), "--",
                              "--request", str(request_path)]
                    setup_status = command(driver + ["--operation", "setup", "--report", str(work / "setup.json")], tool, env, work / "setup.log", args.timeout)
                    if setup_status:
                        report["preparation"].append({"revision": revision, "case": case["name"], "operation": operation, "exit_status": setup_status, "log": str(work / "setup.log")})
                        write_json(path, report)
                        continue
                    git(source, "add", "--all")
                    git(source, "commit", "--quiet", "-m", "Disposable benchmark input")
                    for sample in ["cold"] + [f"warm-{index}" for index in range(1, 6)]:
                        observed = work / f"{sample}.json"
                        usage = work / f"{sample}-time.json"
                        log = work / f"{sample}.log"
                        argv = [gnu_time, "-f", '{"wall_seconds":%e,"peak_rss_kib":%M,"exit_status":%x}', "-o", str(usage), "--"] + driver + ["--operation", operation, "--sample", sample, "--report", str(observed)]
                        status = command(argv, tool, env, log, args.timeout)
                        runtime = json.loads(observed.read_text()) if observed.exists() else {"status": "missing_runtime_report", "metrics": {}}
                        # GNU time adds a diagnostic line on failed commands.
                        time_rows = [line for line in usage.read_text().splitlines() if line.startswith("{")] if usage.exists() else []
                        timed = json.loads(time_rows[-1]) if time_rows else {"wall_seconds": None, "peak_rss_kib": None}
                        metrics = {**runtime.get("metrics", {}), **{k: timed.get(k) for k in ("wall_seconds", "peak_rss_kib")},
                                   "cache_bytes": cache_bytes(source) + disk_bytes(work / "command-cache"),
                                   "state_bytes": disk_bytes(source / ".weld"), "tool_cache_bytes": sum(disk_bytes(p) for p in [tool / "_build", tool / "deps", directory / "mix-home", directory / "hex-home"])}
                        record = {"revision_index": number, "revision": revision, "requested_ref": ref, "case": case["name"], "operation": operation, "sample": sample,
                                  "status": "ok" if status == 0 and runtime.get("status") == "ok" else "failed", "exit_status": status,
                                  "metrics": metrics, "runtime": runtime, "source_inventory": source_facts,
                                  "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(), "log": str(log), "argv": argv}
                        report["samples"].append(record)
                        report["summaries"] = summaries(report["samples"])
                        write_json(path, report)
        report["status"] = "ok" if report["samples"] and all(s["status"] == "ok" for s in report["samples"]) and all(p["exit_status"] == 0 for p in report["preparation"]) else "failed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = f"{type(error).__name__}: {error}"
    write_json(path, report)
    print(json.dumps({"status": report["status"], "report": str(path)}, sort_keys=True))
    return 0 if report["status"] == "ok" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", dest="refs", action="append", help="repeat for baseline, checkpoint and HEAD")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--cases", help="explicit external inputs and per-revision manifest configurations")
    group.add_argument("--synthetic", action="store_true")
    group.add_argument("--generate-only", type=Path, metavar="NEW_PATH", help="generate/count synthetic input without Elixir")
    parser.add_argument("--projects", type=int, default=100)
    parser.add_argument("--files", type=int, default=5000, help="exact regular project files, excluding root harness files")
    parser.add_argument("--artifacts", type=int, default=10)
    parser.add_argument("--timeout", type=int, default=3600, help="seconds per subprocess/sample")
    args = parser.parse_args()
    try:
        if args.generate_only:
            print(json.dumps(synthetic(args.generate_only.absolute(), args.projects, args.files, args.artifacts), indent=2, sort_keys=True))
            return 0
        if args.timeout <= 0:
            raise ValueError("timeout must be positive")
        return benchmark(args)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "failed", "error": str(error), "runtime_pass_claimed": False}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
