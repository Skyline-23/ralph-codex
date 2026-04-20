#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command_name="${1:-}"
if [[ -z "$command_name" ]]; then
  echo "usage: ralph_loop.sh <start|status|stop|resume|reset> [args]" >&2
  exit 1
fi
shift

repo_root() {
  git rev-parse --show-toplevel
}

state_dir() {
  printf '%s/.codex-ralph\n' "$(repo_root)"
}

state_file() {
  printf '%s/state.json\n' "$(state_dir)"
}

ensure_hooks() {
  /bin/bash "$SCRIPT_DIR/install.sh" >/dev/null
}

remove_hooks() {
  /bin/bash "$SCRIPT_DIR/uninstall.sh" >/dev/null
}

register_root() {
  python3 "$SCRIPT_DIR/registry.py" add "$1" >/dev/null
}

unregister_root() {
  python3 "$SCRIPT_DIR/registry.py" remove "$1" >/dev/null
}

resolve_state_path() {
  python3 - "$PWD" <<'PY'
import json
import pathlib
import subprocess
import sys

cwd = pathlib.Path(sys.argv[1]).resolve()
result = subprocess.run(
    ["git", "rev-parse", "--show-toplevel"],
    cwd=cwd,
    text=True,
    capture_output=True,
    check=False,
)
if result.returncode != 0:
    raise SystemExit("not inside a git repo")
root = pathlib.Path(result.stdout.strip())
state_path = root / ".codex-ralph" / "state.json"
if state_path.exists():
    print(state_path)
    raise SystemExit(0)
pointer_path = root / ".codex-ralph" / "session.json"
if pointer_path.exists():
    print(json.loads(pointer_path.read_text())["state_path"])
    raise SystemExit(0)
raise SystemExit(f"no ralph state for {root}")
PY
}

exclude_state_dir() {
  local root info exclude
  root=$(repo_root)
  info="$root/.git/info"
  exclude="$info/exclude"
  mkdir -p "$info"
  touch "$exclude"
  if ! grep -Fxq '.codex-ralph/' "$exclude"; then
    printf '\n.codex-ralph/\n' >>"$exclude"
  fi
}

load_state() {
  local path
  path=$(resolve_state_path)
  if [[ ! -f "$path" ]]; then
    echo "no ralph state at $path" >&2
    exit 1
  fi
  cat "$path"
}

start_loop() {
  local goal="" max_turns=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --goal)
        goal="$2"
        shift 2
        ;;
      --max-turns)
        max_turns="$2"
        shift 2
        ;;
      *)
        echo "unknown start flag: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$goal" ]]; then
    echo "start requires --goal" >&2
    exit 1
  fi

  local state_json primary_root
  ensure_hooks
  exclude_state_dir
  mkdir -p "$(state_dir)"
  touch "$(state_dir)/run.log"
  if [[ ! -f "$(state_dir)/events.tsv" ]]; then
    printf 'timestamp\tturn_count\tevent\tlabel\n' >"$(state_dir)/events.tsv"
  fi

  state_json=$(python3 - "$(state_file)" "$(repo_root)" "$goal" "$max_turns" <<'PY'
import json
import pathlib
import sys
import datetime as dt

path = pathlib.Path(sys.argv[1])
repo_root = sys.argv[2]
goal = sys.argv[3]
max_turns_raw = sys.argv[4]

state = {
    "version": 2,
    "active": True,
    "last_transition": "start",
    "goal": goal,
    "max_turns": int(max_turns_raw) if max_turns_raw else None,
    "turn_count": 0,
    "done_marker": "RALPH_DONE",
    "primary_repo": repo_root,
    "repo_root": repo_root,
    "events_path": ".codex-ralph/events.tsv",
    "log_path": ".codex-ralph/run.log",
    "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "stopped_at": None,
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(state, indent=2) + "\n")
(path.parent / "session.json").write_text(
    json.dumps({"state_path": str(path), "primary_repo": repo_root}, indent=2) + "\n"
)
print(json.dumps(state, indent=2))
PY
)
  primary_root=$(python3 - <<'PY' "$state_json"
import json
import sys
print(json.loads(sys.argv[1])["primary_repo"])
PY
)
  register_root "$primary_root"
  printf '%s\n' "$state_json"
}

toggle_active() {
  local value="$1"
  local state_json primary_root
  state_json=$(python3 - "$(resolve_state_path)" "$value" <<'PY'
import json
import pathlib
import sys
import datetime as dt

path = pathlib.Path(sys.argv[1])
value = sys.argv[2] == "true"
state = json.loads(path.read_text())
state["active"] = value
state["last_transition"] = "resume" if value else "manual-stop"
state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
state["stopped_at"] = None if value else state["updated_at"]
path.write_text(json.dumps(state, indent=2) + "\n")
print(json.dumps(state, indent=2))
PY
)
  primary_root=$(python3 - <<'PY' "$state_json"
import json
import sys
print(json.loads(sys.argv[1])["primary_repo"])
PY
)
  if [[ "$value" == "true" ]]; then
    register_root "$primary_root"
  else
    unregister_root "$primary_root"
  fi
  printf '%s\n' "$state_json"
}

reset_loop() {
  local state_path primary_root
  state_path=$(resolve_state_path)
  primary_root=$(python3 - <<'PY' "$state_path"
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["primary_repo"])
PY
)
  python3 - "$state_path" <<'PY'
import json
import pathlib
import shutil
import sys

state_path = pathlib.Path(sys.argv[1])
state = json.loads(state_path.read_text())
state_dir = state_path.parent
session_file = state_dir / "session.json"
if session_file.exists():
    session_file.unlink()
shutil.rmtree(state_dir, ignore_errors=True)
PY
  unregister_root "$primary_root"
}

case "$command_name" in
  start)
    start_loop "$@"
    ;;
  status)
    load_state
    ;;
  stop)
    toggle_active false
    remove_hooks
    ;;
  resume)
    ensure_hooks
    toggle_active true
    ;;
  reset)
    reset_loop
    remove_hooks
    ;;
  *)
    echo "unknown command: $command_name" >&2
    exit 1
    ;;
esac
