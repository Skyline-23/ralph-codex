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
  path=$(state_file)
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

  ensure_hooks
  exclude_state_dir
  mkdir -p "$(state_dir)"
  touch "$(state_dir)/run.log"
  if [[ ! -f "$(state_dir)/events.tsv" ]]; then
    printf 'timestamp\tturn_count\tevent\tlabel\n' >"$(state_dir)/events.tsv"
  fi

  python3 - "$(state_file)" "$(repo_root)" "$goal" "$max_turns" <<'PY'
import json
import pathlib
import sys
import datetime as dt

path = pathlib.Path(sys.argv[1])
repo_root = sys.argv[2]
goal = sys.argv[3]
max_turns_raw = sys.argv[4]

state = {
    "version": 1,
    "active": True,
    "last_transition": "start",
    "goal": goal,
    "max_turns": int(max_turns_raw) if max_turns_raw else None,
    "turn_count": 0,
    "done_marker": "RALPH_DONE",
    "repo_root": repo_root,
    "events_path": ".codex-ralph/events.tsv",
    "log_path": ".codex-ralph/run.log",
    "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "stopped_at": None,
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(state, indent=2) + "\n")
print(json.dumps(state, indent=2))
PY
}

toggle_active() {
  local value="$1"
  python3 - "$(state_file)" "$value" <<'PY'
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
}

reset_loop() {
  rm -rf "$(state_dir)"
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
