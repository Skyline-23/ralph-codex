#!/usr/bin/env python3
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parent


def run(args, *, cwd=None):
    return subprocess.run(
        args,
        cwd=cwd,
        text=True,
        input="",
        capture_output=True,
        check=False,
    )


def init_git_repo(path: pathlib.Path) -> None:
    run(["git", "init", "-q"], cwd=path)
    run(["git", "config", "user.name", "Codex Test"], cwd=path)
    run(["git", "config", "user.email", "codex@example.com"], cwd=path)
    (path / "README.md").write_text("test\n")
    run(["git", "add", "README.md"], cwd=path)
    run(["git", "commit", "-qm", "init"], cwd=path)


def expected_commands():
    return {
        f'/bin/bash "{REPO_ROOT}/scripts/hook.sh" session-start',
        f'/bin/bash "{REPO_ROOT}/scripts/hook.sh" user-prompt',
        f'/bin/bash "{REPO_ROOT}/scripts/hook.sh" stop',
    }


def commands_in_hooks(hooks_path: pathlib.Path):
    if not hooks_path.exists():
        return set()
    data = json.loads(hooks_path.read_text())
    hooks = data.get("hooks", {})
    commands = set()
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            for hook in group.get("hooks", []):
                if isinstance(hook, dict) and "command" in hook:
                    commands.add(hook["command"])
    return commands


class RalphRepoLocalHookTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="ralph-repo-local-"))

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_install_and_uninstall_touch_only_repo_local_codex_dir(self):
        repo = self.tmpdir / "repo"
        repo.mkdir()
        init_git_repo(repo)

        install = run(["/bin/bash", str(REPO_ROOT / "scripts" / "install.sh")], cwd=repo)
        self.assertEqual(install.returncode, 0, msg=install.stderr or install.stdout)

        repo_config = repo / ".codex" / "config.toml"
        repo_hooks = repo / ".codex" / "hooks.json"
        self.assertTrue(repo_config.exists())
        self.assertTrue(repo_hooks.exists())
        self.assertIn("codex_hooks = true", repo_config.read_text())
        self.assertTrue(expected_commands().issubset(commands_in_hooks(repo_hooks)))

        uninstall = run(["/bin/bash", str(REPO_ROOT / "scripts" / "uninstall.sh")], cwd=repo)
        self.assertEqual(uninstall.returncode, 0, msg=uninstall.stderr or uninstall.stdout)
        self.assertTrue(commands_in_hooks(repo_hooks).isdisjoint(expected_commands()))


if __name__ == "__main__":
    unittest.main()
