#!/usr/bin/env bash
# Smart routing demo: start the server, then launch Claude Code armed to route.
#
#   ./run.sh
#
# 1. Starts a project-scoped background server on config.yaml (the `llm:` judge
#    that enables the built-in OSS router). Does not touch ~/.omnigent/config.yaml.
# 2. Launches the Claude Code TUI with `--smart-routing`.
#
# `omnigent claude --smart-routing` is the source-documented entry point
# (smart_routing_cli.py): it creates the session with cost_control_mode_override
# ="on" (smart_routing_cli.py:225) bound to the harness's own built-in wrapper
# agent, and your FIRST typed message is what gets routed. No custom agent
# needed — "Smart Routing rides on the session row, not the agent"
# (smart_routing_cli.py:_routing_agent_id).
#
# Routing is decided once per session on the first message (orchestration.py:4615),
# so to see haiku vs. opus, exit and re-run for each prompt. See try-these.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${OMNIGENT_PORT:-6767}"

command -v omnigent >/dev/null 2>&1 || {
  echo "error: 'omnigent' not found. Install it:"
  echo "  uv tool install --python 3.12 \"omnigent[databricks]\""
  exit 1
}

echo "==> Starting server on config.yaml (port ${PORT})…"
omnigent stop >/dev/null 2>&1 || true
omnigent server --config "${HERE}/config.yaml" --port "${PORT}" --background

echo "==> Launching Claude Code with smart routing. Type your first message."
echo
omnigent claude --smart-routing --server "http://localhost:${PORT}"

# When done:  omnigent stop
