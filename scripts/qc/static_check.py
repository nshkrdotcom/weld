#!/usr/bin/env python3
"""Read-only source accounting. This is not an Elixir parser or runtime gate."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "7897ba6457d3ba725ee3a843bc863f2c38e90411"
CHECKPOINT = "0ff6f9ef7a66048abaf00f4f24e5464ca2d90c37"
ORIGINAL_LANES = {
    "fast", "source_consumption", "release", "formatter", "internal", "package",
    "runtime", "monolith", "prepare_cli", "monolith_tests", "package_config",
    "source_docs_output", "component_prepare", "graph_consumption",
    "bootstrap_relocation",
}


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args], stderr=subprocess.PIPE)


def tracked_at(ref: str) -> list[str]:
    return git("ls-tree", "-rz", "--name-only", ref).decode().rstrip("\0").split("\0")


def physical(text: str) -> int:
    return len(text.splitlines())


def metrics(files: dict[str, str], mixfile: str) -> dict:
    production = {p: s for p, s in files.items() if p.startswith("lib/") and p.endswith(".ex")}
    dependencies = re.search(r"defp deps do(.*?)\n  end", mixfile, re.S)
    dependency_names = re.findall(r"\{:(\w+),", dependencies.group(1)) if dependencies else []
    return {
        "production_files": len(production),
        "production_physical_lines": sum(map(physical, production.values())),
        "production_nonblank_noncomment_lines": sum(
            bool(line.strip()) and not line.lstrip().startswith("#")
            for text in production.values() for line in text.splitlines()
        ),
        "lexical_module_declarations": sum(len(re.findall(r"^\s*defmodule\s", s, re.M)) for s in production.values()),
        "lexical_function_declarations": sum(len(re.findall(r"^\s*def(?:p|macro|macrop|delegate)?\s", s, re.M)) for s in production.values()),
        "lexical_branch_keywords": sum(len(re.findall(r"\b(?:if|unless|case|cond|with|receive)\b", s)) for s in production.values()),
        "mix_task_files": sorted(p for p in production if p.startswith("lib/mix/tasks/")),
        "direct_dependencies": dependency_names,
        "direct_dependency_count": len(dependency_names),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="write the same JSON report at this explicit path")
    opts = parser.parse_args()
    paths = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").decode().rstrip("\0").split("\0")
    files = {p: (ROOT / p).read_text() for p in sorted(set(paths))
             if (ROOT / p).is_file() and not (ROOT / p).is_symlink()
             and (p.endswith((".ex", ".exs", ".md", ".json")) or p == "mix.lock")}
    checks = []

    def check(name: str, ok: bool, detail=None):
        checks.append({"name": name, "passed": bool(ok), "detail": detail})

    history = {}
    for ref in (BASELINE, CHECKPOINT):
        ref_paths = tracked_at(ref)
        ref_files = {p: git("show", f"{ref}:{p}").decode() for p in ref_paths
                     if p.startswith("lib/") and p.endswith(".ex")}
        history[ref] = metrics(ref_files, git("show", f"{ref}:mix.exs").decode())
    baseline_tests = sorted(p for p in tracked_at(BASELINE) if p.startswith("test/"))
    missing_tests = [p for p in baseline_tests if not (ROOT / p).exists()]
    check("baseline_test_paths_retained", not missing_tests,
          {"baseline_paths": len(baseline_tests), "missing": missing_tests})
    current_metrics = metrics(files, files["mix.exs"])
    check("one_public_mix_task", current_metrics["mix_task_files"] == ["lib/mix/tasks/weld.ex"],
          current_metrics["mix_task_files"])
    runtime_env = []
    etf = []
    removed_refs = []
    for path, content in files.items():
        if not path.startswith("lib/"):
            continue
        for number, line in enumerate(content.splitlines(), 1):
            if re.search(r"System\.(?:get_env|fetch_env!?|put_env|delete_env)\s*\(", line):
                runtime_env.append(f"{path}:{number}")
            if re.search(r":erlang\.(?:term_to_binary|binary_to_term)\s*\(", line):
                etf.append(f"{path}:{number}")
            if re.search(r"Weld\.(?:Projector\.(?:Monolith|Live|SourceProject)|Shell\.Inputs)\b", line):
                removed_refs.append(f"{path}:{number}")
    check("no_direct_runtime_os_env_calls_lexical", not runtime_env, runtime_env)
    check("no_production_etf_codec_lexical", not etf, etf)
    check("no_removed_module_references_lexical", not removed_refs, removed_refs)
    lanes = re.findall(r'\{"([^"\n]+)",\s*(?:nil|"[^"\n]+")\}', files["scripts/test_ci.exs"])
    check("original_independent_ci_lanes_retained", ORIGINAL_LANES <= set(lanes), lanes)
    check("additional_contract_lanes_present", {"qualification_faults", "hex_consumption"} <= set(lanes), lanes)
    checkpoint_lock = git("show", f"{CHECKPOINT}:mix.lock").decode()
    pin = lambda text: next((line for line in text.splitlines() if line.lstrip().startswith('"hex_core":')), None)
    check("resolved_hex_core_lock_pin_unchanged", pin(files["mix.lock"]) == pin(checkpoint_lock) and pin(files["mix.lock"]) is not None,
          {"sha256_of_lock_entry": hashlib.sha256((pin(files["mix.lock"]) or "").encode()).hexdigest()})
    vectors = json.loads((ROOT / "test/fixtures/canonical-vectors.json").read_text())
    failures = []
    for vector in vectors["raw_sha256"]:
        if hashlib.sha256(vector["utf8"].encode()).hexdigest() != vector["sha256"]:
            failures.append("raw_sha256")
    for vector in vectors["domain_vectors"]:
        canonical = json.dumps(vector["value"], sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        digest = hashlib.sha256(("weld/2/" + vector["domain"] + "\n" + canonical).encode()).hexdigest()
        if canonical != vector["canonical_utf8"] or digest != vector["sha256"]:
            failures.append(vector["domain"])
    check("supplied_vector_arithmetic_independent_python", not failures,
          {"vectors": len(vectors["raw_sha256"]) + len(vectors["domain_vectors"]), "failures": failures})
    required_drivers = ["architecture_check.exs", "benchmark.py", "benchmark_driver.exs",
                        "benchmark-cases.example.json", "qualify_layouts.exs", "signed_hex_consumer.exs",
                        "prepare_reuse.exs", "installed_weld.exs", "browser_docs.mjs", "authenticated_conformance.exs",
                        "loopback_transport.sh", "support.exs"]
    missing = [p for p in required_drivers if not (ROOT / "scripts/qc" / p).is_file()]
    check("runtime_qc_driver_sources_present", not missing, missing)
    whitespace = subprocess.run(["git", "-C", str(ROOT), "diff", "--check"], capture_output=True, text=True)
    check("git_diff_check", whitespace.returncode == 0, (whitespace.stdout + whitespace.stderr).strip())
    removed = sorted(p for p in tracked_at(CHECKPOINT) if not (ROOT / p).exists())
    report = {
        "schema": "weld.static-source-review/2", "runtime_executed": False,
        "limitations": "Lexical counts and source accounting do not parse/compile Elixir or validate runtime behavior, xref, formatting, docs or performance.",
        "baseline": history, "current": current_metrics,
        "removed_since_checkpoint": removed, "checks": checks,
        "passed": all(item["passed"] for item in checks),
    }
    output = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if opts.output:
        opts.output.parent.mkdir(parents=True, exist_ok=True)
        opts.output.write_text(output)
    sys.stdout.write(output)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"static source review failed: {error}", file=sys.stderr)
        raise SystemExit(2)
