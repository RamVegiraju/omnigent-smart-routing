# Smart Routing for Claude Code (Omnigent)

Route **cheap models to trivial tasks and capable models to hard ones**, using
[Omnigent](https://github.com/omnigent-ai/omnigent)'s built-in smart routing.

A small **judge LLM** reads your first message, classifies it
`SIMPLE`/`MODERATE`/`COMPLEX`, and picks a model sized for the work — you don't
pin a model or list candidates.

> Verified against **`omnigent 0.9.0`**. Uses the built-in ("oss") judge: one
> `llm:` block, no AI Gateway. Docs: <https://omnigent.ai/docs/build/routing>.

## The setup: one `llm:` block

`config.yaml` is the entire configuration:

```yaml
llm:
  model: databricks-claude-haiku-4-5   # the judge (classifier), not the coder
  profile: adb-984752964297111
```

The `llm:` model is the **judge** — a cheap model that only *classifies* each
task and picks a model. It is a separate connection from the coding harness and
does not do the coding.

## How it works

1. Your first message goes to the judge, which classifies it and picks a model
   from your live workspace catalog, ordered cheapest → most capable
   (`haiku → sonnet → opus`).
2. `SIMPLE → cheapest`, `MODERATE → middle`, `COMPLEX → most capable`.
3. The decision is made **once, on the first message**, and reused for the whole
   session — the model does not flip turn-to-turn. Start a **new session** to
   route a different first message.
4. Routing is **opt-in per session** (turned on in the UI, or via the CLI flag
   below).

## Run it

Start the server on this repo's `config.yaml`, then arm a session.

### CLI (recommended)

```bash
./run.sh
```

Equivalent to:

```bash
omnigent server --config config.yaml --port 6767 --background
omnigent claude --smart-routing --server http://localhost:6767
```

Type a **trivial** first message (`what git branch are we on?`) → runs on haiku.
A **complex** one (`refactor the auth module with tests`) → runs on opus. See
`try-these.md`. When done: `omnigent stop`.

### Web UI

```bash
omnigent server --config config.yaml --port 6767 --background
omnigent host --server http://localhost:6767      # second terminal: brings a host online
```

Open <http://localhost:6767> → pick the host + a working directory → harness
**Claude Code** → ⚙️ → **Model → Smart Routing** → Save → send your first message.

> **Why start the server explicitly?** The `llm:` judge block lives in this
> repo's `config.yaml`, so `run.sh` starts the server against it — keeping the
> demo **hermetic** (self-contained: works on any clone, reads no global config).
> `omnigent claude` has no `--config` flag; on its own it reads your global
> `~/.omnigent/config.yaml` instead, which a fresh clone won't have.

## Verify (no UI)

```bash
~/.local/share/uv/tools/omnigent/bin/python verify_routing.py
```

Runs the real judge against your endpoint. Expected: trivial →
`databricks-claude-haiku-4-5`, complex → `databricks-claude-opus-4-8`.

## Prerequisites

- **Python 3.12+**, `uv`, and Omnigent with the Databricks extra:
  ```bash
  uv tool install "omnigent[databricks]"
  ```
- A Databricks profile whose workspace serves `databricks-claude-haiku-4-5`,
  `-sonnet-4-6`, `-opus-4-8` (this repo uses `adb-984752964297111`). Re-auth if
  the token expired:
  ```bash
  databricks auth login --host https://<workspace>.azuredatabricks.net --profile <name>
  ```

## Files

| File | Purpose |
|---|---|
| `config.yaml` | The `llm:` judge block — the entire setup |
| `run.sh` | Starts the server + `omnigent claude --smart-routing` |
| `verify_routing.py` | Headless check: runs the real judge against your endpoint |
| `try-these.md` | Trivial vs. complex first-message prompts |

## Adapting it

- **Different workspace?** Change `llm.profile` in `config.yaml`.
- **Different provider?** Change `llm.model` (e.g. `anthropic/claude-haiku-4-5`)
  and give the judge credentials via `connection:`.
- **Note:** a Claude **subscription** authenticates the coding harness, not the
  judge — the `llm:` judge still needs its own `profile:` or `connection.api_key`.

## Source references (omnigent 0.9.0)

- **Built-in judge, no gateway** — `server/smart_routing.py` `LLMRoutingClient`
  (`:566` `route()`); `server/routes/_sessions/orchestration.py:6693`
  `_reject_ungatewayed_model_routing` (rejects only when neither a gateway nor an
  `llm:` model exists).
- **Candidates + rubric** — `smart_routing.py:395` (catalog fetch),
  `:384-448` (cost ordering), `:504-510` (`SIMPLE`/`MODERATE`/`COMPLEX` →
  first/middle/last), `:622` (clamps a hallucinated pick to cheapest).
- **Decides once, opt-in per session** — `orchestration.py:4615`
  (`cost_control_mode_override == "on"` gate).
- **CLI entry point** — `smart_routing_cli.py:225` (sets
  `cost_control_mode_override="on"`; binds the harness's own wrapper, not a
  custom agent).
- **Judge config schema** — `spec/types.py` `LLMConfig` (`model` required).
- **Docs** — <https://omnigent.ai/docs/build/routing>.
