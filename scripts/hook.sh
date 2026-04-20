#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

event="${1:-}"
if [[ -z "$event" ]]; then
  echo "usage: hook.sh <session-start|user-prompt|stop>" >&2
  exit 1
fi

HOOK_PAYLOAD=$(cat)
export HOOK_PAYLOAD
export HOOK_SCRIPT_DIR="$SCRIPT_DIR"

python3 - "$event" <<'PY'
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys

event = sys.argv[1]
payload = json.loads(os.environ["HOOK_PAYLOAD"])


def repo_root_from(payload_cwd):
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=payload_cwd,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return pathlib.Path(result.stdout.strip())


def load_state(root):
    state_path = root / ".codex-ralph" / "state.json"
    if not state_path.exists():
        return None, state_path
    try:
        return json.loads(state_path.read_text()), state_path
    except json.JSONDecodeError:
        return None, state_path


def write_state(path, state):
    path.write_text(json.dumps(state, indent=2) + "\n")


def cleanup_hooks(root):
    script = pathlib.Path(os.environ["HOOK_SCRIPT_DIR"]) / "uninstall.sh"
    subprocess.run(
        ["/bin/bash", str(script), str(root)],
        text=True,
        capture_output=True,
        check=False,
    )


def summarize_state(state):
    turn_text = f'{state["turn_count"]}'
    if state.get("max_turns") is not None:
        turn_text = f'{turn_text}/{state["max_turns"]}'
    return (
        f'Ralph loop is active. Goal: {state["goal"]}. '
        f'Turn count: {turn_text}. '
        "Keep iterating until there is one verified outcome. "
        "If the user asks to stop or pivot, run scripts/ralph_loop.sh stop first. "
        f'Emit {state["done_marker"]} or run scripts/ralph_loop.sh stop to finish.'
    )


def has_done_marker(message, marker):
    for line in message.splitlines():
        if line.strip() == marker:
            return True
    return False


root = repo_root_from(payload["cwd"])
if root is None:
    sys.exit(0)

state, state_path = load_state(root)
if not state or not state.get("active"):
    cleanup_hooks(root)
    sys.exit(0)

if event in {"session-start", "user-prompt"}:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart" if event == "session-start" else "UserPromptSubmit",
                    "additionalContext": summarize_state(state),
                }
            }
        )
    )
    sys.exit(0)

if payload.get("stop_hook_active"):
    sys.exit(0)

last_message = payload.get("last_assistant_message") or ""
if has_done_marker(last_message, state["done_marker"]):
    state["active"] = False
    state["last_transition"] = "done-marker"
    state["stopped_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    state["updated_at"] = state["stopped_at"]
    write_state(state_path, state)
    cleanup_hooks(root)
    sys.exit(0)

state["turn_count"] += 1
state["last_transition"] = "continued"
state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
write_state(state_path, state)

events_path = root / ".codex-ralph" / "events.tsv"
log_path = root / ".codex-ralph" / "run.log"
label = last_message.splitlines()[0].strip()[:120] if last_message else "turn-complete"

with events_path.open("a", encoding="utf-8") as handle:
    handle.write(
        f'{dt.datetime.now(dt.timezone.utc).isoformat()}\t'
        f'{state["turn_count"]}\tstop\t{label}\n'
    )

with log_path.open("a", encoding="utf-8") as handle:
    handle.write(
        json.dumps(
            {
                "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
                "event": "stop",
                "turn_count": state["turn_count"],
                "label": label,
            }
        )
        + "\n"
    )

if state.get("max_turns") is not None and state["turn_count"] >= state["max_turns"]:
    state["active"] = False
    state["last_transition"] = "max-turns-reached"
    state["stopped_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    state["updated_at"] = state["stopped_at"]
    write_state(state_path, state)
    cleanup_hooks(root)
    print(
        json.dumps(
            {
                "continue": False,
                "stopReason": "ralph max_turns reached",
                "systemMessage": "Ralph loop stopped because max_turns was reached.",
            }
        )
    )
    sys.exit(0)

turn_text = f'{state["turn_count"]}'
if state.get("max_turns") is not None:
    turn_text = f'{turn_text}/{state["max_turns"]}'

reason = (
    f'Ralph loop is active for goal "{state["goal"]}". '
    f'Turn count: {turn_text}. '
    "Inspect the current state, choose the next concrete step, execute it, verify the result, "
    "and keep going until there is one verified outcome. If the user asks to stop or pivot, "
    "run scripts/ralph_loop.sh stop first. "
    f'Emit a line that is exactly {state["done_marker"]} '
    "or run scripts/ralph_loop.sh stop to finish."
)
print(json.dumps({"decision": "block", "reason": reason}))
PY
