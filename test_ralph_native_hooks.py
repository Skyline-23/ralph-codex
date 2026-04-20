#!/usr/bin/env python3
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


SKILL_ROOT = pathlib.Path(__file__).resolve().parent


def run(args, *, cwd=None, env=None, input_text=None):
    return subprocess.run(
        args,
        cwd=cwd,
        env=env,
        input=input_text,
        text=True,
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


class RalphNativeHookTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="ralph-hooks-"))
        self.codex_home = self.tmpdir / "codex-home"
        self.env = os.environ | {"CODEX_HOME": str(self.codex_home)}

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_install_tolerates_trailing_garbage_in_hooks_json(self):
        self.codex_home.mkdir(parents=True, exist_ok=True)
        hooks_path = self.codex_home / "hooks.json"
        hooks_path.write_text('{"hooks":{"Stop":[]}}\nTRAILING_GARBAGE\n')

        result = run(
            ["/bin/bash", str(SKILL_ROOT / "scripts" / "install.sh")],
            env=self.env,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr or result.stdout)
        data = json.loads(hooks_path.read_text())
        commands = {
            hook["command"]
            for groups in data["hooks"].values()
            for group in groups
            for hook in group["hooks"]
            if isinstance(hook, dict) and "command" in hook
        }
        self.assertIn(
            f'/bin/bash "{SKILL_ROOT}/scripts/hook.sh" session-start',
            commands,
        )
        self.assertIn(
            f'/bin/bash "{SKILL_ROOT}/scripts/hook.sh" user-prompt',
            commands,
        )
        self.assertIn(
            f'/bin/bash "{SKILL_ROOT}/scripts/hook.sh" stop',
            commands,
        )

    def test_uninstall_keeps_hooks_when_another_ralph_loop_is_active(self):
        self.codex_home.mkdir(parents=True, exist_ok=True)
        hooks_path = self.codex_home / "hooks.json"
        commands = [
            f'/bin/bash "{SKILL_ROOT}/scripts/hook.sh" session-start',
            f'/bin/bash "{SKILL_ROOT}/scripts/hook.sh" user-prompt',
            f'/bin/bash "{SKILL_ROOT}/scripts/hook.sh" stop',
        ]
        hooks_path.write_text(
            json.dumps(
                {
                    "hooks": {
                        "SessionStart": [{"hooks": [{"type": "command", "command": commands[0]}]}],
                        "UserPromptSubmit": [{"hooks": [{"type": "command", "command": commands[1]}]}],
                        "Stop": [{"hooks": [{"type": "command", "command": commands[2]}]}],
                    }
                }
            )
            + "\n"
        )

        active_repo = self.tmpdir / "active-repo"
        active_repo.mkdir()
        init_git_repo(active_repo)
        state_dir = active_repo / ".codex-ralph"
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / "state.json").write_text(
            json.dumps(
                {
                    "active": True,
                    "primary_repo": str(active_repo),
                    "goal": "keep hooks alive",
                    "turn_count": 1,
                    "done_marker": "RALPH_DONE",
                }
            )
            + "\n"
        )
        (self.codex_home / "ralph-codex-registry.json").write_text(
            json.dumps({"roots": [str(active_repo)]}) + "\n"
        )

        result = run(
            ["/bin/bash", str(SKILL_ROOT / "scripts" / "uninstall.sh")],
            env=self.env,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr or result.stdout)
        data = json.loads(hooks_path.read_text())
        remaining = {
            hook["command"]
            for groups in data["hooks"].values()
            for group in groups
            for hook in group["hooks"]
            if isinstance(hook, dict) and "command" in hook
        }
        for command in commands:
            self.assertIn(command, remaining)

    def test_hook_reads_state_via_session_pointer(self):
        primary_repo = self.tmpdir / "primary-repo"
        secondary_repo = self.tmpdir / "secondary-repo"
        primary_repo.mkdir()
        secondary_repo.mkdir()
        init_git_repo(primary_repo)
        init_git_repo(secondary_repo)

        primary_state_dir = primary_repo / ".codex-ralph"
        primary_state_dir.mkdir(parents=True, exist_ok=True)
        state_path = primary_state_dir / "state.json"
        state_path.write_text(
            json.dumps(
                {
                    "version": 2,
                    "active": True,
                    "goal": "follow pointer",
                    "turn_count": 3,
                    "max_turns": None,
                    "done_marker": "RALPH_DONE",
                    "primary_repo": str(primary_repo),
                }
            )
            + "\n"
        )

        secondary_state_dir = secondary_repo / ".codex-ralph"
        secondary_state_dir.mkdir(parents=True, exist_ok=True)
        (secondary_state_dir / "session.json").write_text(
            json.dumps(
                {
                    "state_path": str(state_path),
                    "primary_repo": str(primary_repo),
                }
            )
            + "\n"
        )

        payload = json.dumps({"cwd": str(secondary_repo)})
        result = run(
            ["/bin/bash", str(SKILL_ROOT / "scripts" / "hook.sh"), "session-start"],
            env=self.env,
            input_text=payload,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr or result.stdout)
        response = json.loads(result.stdout)
        context = response["hookSpecificOutput"]["additionalContext"]
        self.assertIn("follow pointer", context)
        self.assertIn("Turn count: 3", context)


if __name__ == "__main__":
    unittest.main()
