# Try these — watch the judge pick a model

Routing is decided on the **first message of a session** and reused for that
session (`orchestration.py:4615`). To see the model change, start a **new
session** for each prompt below.

- **CLI:** run `./run.sh`, type the message. (Exit and re-run for a new session.)
- **UI:** at <http://localhost:6767>, set host + working directory, Model →
  Smart Routing, then send the message.

## Trivial → cheap model (haiku)

- `what git branch are we on?`
- `Fix the typo in the README title.`
- `Rename the variable "tmp" to "buffer" in utils.py.`

The judge classifies these `SIMPLE` and picks the first (cheapest) model. In the
CLI TUI you'll see: *"Smart Routing selected `system.ai.claude-haiku-4-5`;
rerunning your message on it."*

## Complex → most-capable model (opus)

- `Refactor the auth module to use dependency injection and update all call sites, with tests.`
- `We have a race condition when two requests write the same cache key — find it and fix it.`
- `Audit this service for injection vulnerabilities and propose fixes.`

Classified `COMPLEX` → the last (most capable) model.

## Not seeing routing?

- CLI: make sure you launched via `./run.sh` (i.e. `omnigent claude
  --smart-routing`), not a plain `omnigent claude`.
- Confirm the server has routing on: `curl -s localhost:6767/v1/info` →
  `smart_routing_enabled: true`.
- Headless check without any TUI:
  `~/.local/share/uv/tools/omnigent/bin/python verify_routing.py`
  → trivial → haiku, complex → opus.
