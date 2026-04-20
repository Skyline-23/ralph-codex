# Ralph Codex

Persistent operator-loop skill for OpenAI Codex.

This repository publishes a single skill, `ralph-codex`, which keeps a repo-local native-hook loop alive across turns until one verified outcome is complete.

## Install

Official `skills.sh` flow:

```bash
npx skills add https://github.com/Skyline-23/ralph-codex -a codex -g -y
```

Fallback if `npx skills` does not resolve correctly in your npm environment:

```bash
npm exec --package=skills@latest -- skills add https://github.com/Skyline-23/ralph-codex -a codex -g -y
```

## Use

Start the loop from the target repository:

```bash
bash scripts/ralph_loop.sh start --goal "Ship one verified outcome"
```

Optional guardrail:

```bash
bash scripts/ralph_loop.sh start --goal "Ship one verified outcome" --max-turns 12
```

Inspect or stop:

```bash
bash scripts/ralph_loop.sh status
bash scripts/ralph_loop.sh stop
bash scripts/ralph_loop.sh resume
```

## Notes

- The skill definition lives in [`SKILL.md`](./SKILL.md).
- Native hooks are experimental and intended for macOS/Linux-style environments.
- Loop state is written under `.codex-ralph/` in the target repository.
