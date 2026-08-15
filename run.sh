#!/usr/bin/env bash
# Smart routing demo: start the server, then launch Claude Code armed to route.
#
#   ./run.sh
#
# 1. Starts a project-scoped server on THIS repo's config.yaml (the `llm:` judge
#    that enables the built-in OSS router). Does not touch ~/.omnigent/config.yaml.
# 2. Launches the Claude Code TUI with `--smart-routing`.
#
# The coding runs on the Claude subscription; only the judge talks to
# Databricks. See README.
#
# `omnigent claude --smart-routing` creates the session with
# cost_control_mode_override="on" (smart_routing_cli.py:225), bound to the
# harness's own wrapper agent. The first typed message is what gets routed.
#
# Routing is decided once per session on the first message (orchestration.py:4615
# on 0.9.0, :4845 on main); exit and re-run for each prompt. See try-these.md.
#
# Do NOT use `omnigent server --background`: it discards `--config` and `--port`
# and starts the managed server against ~/.omnigent/config.yaml, which has no
# `llm:` block, leaving routing off with no error (_run_background_server(),
# cli.py:4111). The server runs in the foreground here, backgrounded by the
# shell.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${OMNIGENT_PORT:-6767}"
LOG="${HERE}/.server.log"

command -v omnigent >/dev/null 2>&1 || {
  echo "error: 'omnigent' not found. Install it:"
  echo "  uv tool install --force --python 3.12 \"omnigent[databricks]\""
  exit 1
}

# Clear the managed server off our port so it can't shadow this one.
omnigent stop >/dev/null 2>&1 || true

echo "==> Starting server on config.yaml (port ${PORT})…"
omnigent server --config "${HERE}/config.yaml" --port "${PORT}" >"${LOG}" 2>&1 &
SERVER_PID=$!

cleanup() {
  if kill -0 "${SERVER_PID}" 2>/dev/null; then
    echo
    echo "==> Stopping server (pid ${SERVER_PID})…"
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "==> Waiting for the server to come up…"
for _ in $(seq 1 60); do
  if curl -sf --max-time 2 "http://localhost:${PORT}/v1/info" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    echo "error: the server exited during startup. Log: ${LOG}" >&2
    tail -20 "${LOG}" >&2
    exit 1
  fi
  sleep 1
done

# Fail loudly rather than dropping into a TUI that silently isn't routing.
INFO="$(curl -sf --max-time 5 "http://localhost:${PORT}/v1/info" 2>/dev/null || true)"
case "${INFO}" in
  *'"smart_routing_enabled":true'*|*'"smart_routing_enabled": true'*)
    echo "==> Smart routing is ON (built-in judge loaded from config.yaml)."
    ;;
  "")
    echo "error: the server never became reachable on port ${PORT}. Log: ${LOG}" >&2
    exit 1
    ;;
  *)
    echo "error: the server is up but smart routing is OFF." >&2
    echo "       The judge in config.yaml did not load — usually an expired" >&2
    echo "       Databricks OAuth session. Re-auth and retry:" >&2
    echo "         databricks auth login --host https://<workspace> --profile <name>" >&2
    echo "       Server log: ${LOG}" >&2
    exit 1
    ;;
esac

echo "==> Launching Claude Code with smart routing. Type your first message."
echo
omnigent claude --smart-routing --server "http://localhost:${PORT}"
