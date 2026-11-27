#!/usr/bin/env python3
"""Exercise disposable Git primitives, separately from Elixir qualification.

No source checkout refs are changed. The temporary working repository and bare
remote are created under --scratch (default .weld/v2/runs/git-primitives) and
removed on exit. The JSON report is real execution evidence for these primitives
only; run the ExUnit release and crash suites to qualify Weld itself.
"""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch", default=".weld/v2/runs/git-primitives")
    parser.add_argument("--report")
    args = parser.parse_args()
    scratch = Path(args.scratch).resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="git-contract-", dir=scratch) as directory:
        root = Path(directory) / "repo"
        root.mkdir()
        remote = Path(directory) / "remote.git"

        def git(*arguments):
            return subprocess.run(
                ["git", *arguments], cwd=root, check=True, capture_output=True,
                timeout=30,
            ).stdout.decode().strip()

        git("init", "--quiet")
        git("config", "user.name", "Weld disposable probe")
        git("config", "user.email", "probe@example.invalid")
        readme = root / "README.md"
        readme.write_bytes(b"exact frozen bytes\n")
        blob = git("hash-object", "-w", "--no-filters", "--", str(readme))
        empty = root / "empty-object"
        empty.write_bytes(b"")
        empty_oid = git("hash-object", "-w", "-t", "tree", "--no-filters", "--", str(empty))
        tree_file = root / "tree-object"
        tree_file.write_bytes(
            b"100644 README.md\0" + bytes.fromhex(blob)
            + b"40000 empty\0" + bytes.fromhex(empty_oid)
        )
        tree = git("hash-object", "-w", "-t", "tree", "--no-filters", "--", str(tree_file))
        message = root / "message"
        message.write_text("Disposable Git protocol probe\n")
        commit = git("commit-tree", tree, "-F", str(message))
        tag_file = root / "tag-object"
        tag_file.write_text(
            f"object {commit}\ntype commit\ntag probe-v1\n"
            f"tagger {git('var', 'GIT_COMMITTER_IDENT')}\n\nProbe\n"
        )
        tag = git("hash-object", "-w", "-t", "tag", "--no-filters", "--", str(tag_file))
        process = subprocess.Popen(
            ["git", "update-ref", "--stdin"], cwd=root,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            commands = (
                f"start\nupdate refs/heads/projection/probe {commit} {'0' * 40}\n"
                f"update refs/tags/probe-v1 {tag} {'0' * 40}\nprepare\ncommit\n"
            )
            process.stdin.write(commands.encode())
            process.stdin.flush()
            output = b""
            for _ in range(3):
                ready, _, _ = select.select([process.stdout], [], [], 5)
                if not ready:
                    raise RuntimeError("No transaction acknowledgment before stdin EOF")
                output += os.read(process.stdout.fileno(), 4096)
                if b"commit: ok\n" in output:
                    break
            assert b"commit: ok\n" in output, output
            process.stdin.close()
            assert process.wait(timeout=5) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
        assert git("show-ref", "--verify", "--hash", "refs/heads/projection/probe") == commit
        stale = subprocess.run(
            ["git", "update-ref", "--stdin"], cwd=root, capture_output=True, timeout=10,
            input=(f"start\nupdate refs/heads/projection/probe {commit} {'0' * 40}\n"
                   f"update refs/tags/should-not-exist {tag} {'0' * 40}\nprepare\ncommit\n").encode(),
        )
        assert stale.returncode != 0
        assert subprocess.run(
            ["git", "show-ref", "--verify", "--quiet", "refs/tags/should-not-exist"],
            cwd=root, timeout=10,
        ).returncode != 0
        git("init", "--bare", "--quiet", str(remote))
        git("push", "--atomic", "--", str(remote), "refs/heads/projection/probe", "refs/tags/probe-v1")
        assert f"040000 tree {empty_oid}\tempty" in git("ls-tree", "-r", "-t", "--full-tree", commit)
        message.write_text("Local review before pushing\n")
        local_commit = git("commit-tree", tree, "-p", commit, "-F", str(message))
        git("update-ref", "refs/heads/projection/probe", local_commit, commit)
        remote_tip = git("ls-remote", "--refs", "--", str(remote), "refs/heads/projection/probe").split("\t")[0]
        assert remote_tip == commit
        git("merge-base", "--is-ancestor", remote_tip, local_commit)
        tag_file.write_text(
            f"object {local_commit}\ntype commit\ntag probe-v2\n"
            f"tagger {git('var', 'GIT_COMMITTER_IDENT')}\n\nLocal review\n"
        )
        local_tag = git("hash-object", "-w", "-t", "tag", "--no-filters", "--", str(tag_file))
        git("update-ref", "refs/tags/probe-v2", local_tag, "0" * 40)
        git("push", "--atomic", "--", str(remote), "refs/heads/projection/probe", "refs/tags/probe-v2")
        remote_refs = dict(
            (ref, oid) for oid, ref in (
                line.split("\t") for line in git(
                    "ls-remote", "--refs", "--", str(remote),
                    "refs/heads/projection/probe", "refs/tags/probe-v2",
                ).splitlines()
            )
        )
        assert remote_refs == {
            "refs/heads/projection/probe": local_commit,
            "refs/tags/probe-v2": local_tag,
        }
        message.write_text("Divergent projection history\n")
        divergent = git("commit-tree", tree, "-p", commit, "-F", str(message))
        for unproved_tip in (divergent, "f" * len(local_commit)):
            unproved = subprocess.run(
                ["git", "merge-base", "--is-ancestor", unproved_tip, local_commit],
                cwd=root, capture_output=True, timeout=10,
            )
            assert unproved.returncode != 0
        nested = root / "nested"
        nested.mkdir()
        (nested / "tracked.txt").write_text("Nested tracked path\n")
        git("add", "--", "nested/tracked.txt")
        nested_names = subprocess.run(
            ["git", "ls-files", "--full-name", "-z"], cwd=nested,
            check=True, capture_output=True, timeout=10,
        ).stdout.split(b"\0")
        assert b"nested/tracked.txt" in nested_names and b"tracked.txt" not in nested_names
        result = {
            "schema": "weld.git-primitive-report/2", "git_version": git("--version"),
            "transaction_ack_before_stdin_eof": True, "cas_rejects_companion_ref": True,
            "empty_tree_object_retained": True, "atomic_local_bare_push": True,
            "local_first_fast_forward_push": True,
            "divergent_or_missing_ancestry_rejected": True,
            "nested_tracked_paths_are_checkout_relative": True,
            "scope": "disposable Git primitives only; no Elixir qualification claim",
        }
    encoded = json.dumps(result, sort_keys=True, indent=2) + "\n"
    if args.report:
        report = Path(args.report)
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    main()
