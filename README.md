# Smart Routing for Claude Code (Omnigent)

Route **cheap models to trivial tasks and capable models to hard ones**, using
[Omnigent][repo]'s built-in smart routing.

A small **judge LLM** reads your first message, classifies it
`SIMPLE`/`MODERATE`/`COMPLEX`, and picks a model sized for the work — you don't
pin a model or list candidates.

> Verified against **`omnigent 0.9.0`**. Uses the built-in ("oss") judge: one
> `llm:` block, no AI Gateway.

**Further reading:** [official routing docs][docs] · [Databricks Smart Routing
blog][blog] · [Omnigent launch post][intro] · [source repo][repo]

Omnigent routes the **model** (configured here) and the **harness** — see
[Harness routing](#harness-routing).

## What it routes across

Routing runs across a **Claude Code subscription**, over two separate
connections:

| | Role | Auth |
|---|---|---|
| **Coding harness** | Claude Code. Routing picks among the subscription's models — `claude-haiku-4-5`, `claude-sonnet-4-6`, `claude-opus-4-8`, … | Claude subscription |
| **Judge** | Classifies the first message `SIMPLE`/`MODERATE`/`COMPLEX` and picks one of the above. Does no coding. | Databricks credential |

> [!IMPORTANT]
> A Claude subscription authenticates the coding harness only — **not** the
> judge, which needs its own credential. `_resolve_server_llm_connection`
> (`runtime/policies/builder.py`) accepts a `connection:` block
> (`base_url` + `api_key`) or a Databricks `profile:`, otherwise falling back
> to `ANTHROPIC_API_KEY`.

Subscription-backed harnesses report the curated subscription listing
(`model_catalog.py` `_static_subscription_listing`) — plain Anthropic model ids,
not `databricks-*` serving endpoints.

## The setup: one `llm:` block

`config.yaml` is the entire configuration:

```yaml
llm:
  model: databricks-claude-haiku-4-5   # the judge (classifier), not the coder
  profile: <your-databricks-profile>
```

The `llm:` model is the **judge** — a cheap model that only *classifies* each
task and picks a model. It is a separate connection from the coding harness and
does not do the coding. Set `profile` to a profile in your `~/.databrickscfg`.

## How it works

1. Your first message goes to the judge, which classifies it and picks a model
   from the live session catalog — for a subscription-backed harness, your
   Claude plan's own models — ordered cheapest → most capable
   (`haiku → sonnet → opus`).
2. `SIMPLE → cheapest`, `MODERATE → middle`, `COMPLEX → most capable`.
3. The decision is made **once, on the first message**, and reused for the whole
   session — the model does not flip turn-to-turn. Start a **new session** to
   route a different first message.
4. Routing is **opt-in per session** (turned on in the UI, or via the CLI flag
   below).

## Run it

> [!IMPORTANT]
> **Every command below runs from this repo's root** — the directory holding
> `config.yaml`. The server must be started from here (or with an absolute
> `--config` path), because the `llm:` judge block lives in this repo's
> `config.yaml`, not in your global `~/.omnigent/config.yaml`.
>
> ```bash
> cd /path/to/omnigent-smart-routing     # the directory with config.yaml
> ```

### Step 0 — sanity check the judge (no server, no TUI)

**Directory:** repo root.

```bash
~/.local/share/uv/tools/omnigent/bin/python verify_routing.py
```

Run this first — it isolates a judge-credential failure from a routing failure.
Expected output: [Verify (no UI)](#verify-no-ui).

### Step 1a — the TUI (one terminal)

**Directory:** repo root.

```bash
./run.sh
```

That is the whole flow. `run.sh` stops any managed server, starts the foreground
server on this repo's `config.yaml`, waits for readiness, **aborts if routing
didn't turn on**, launches Claude Code, and stops its own server on exit.

It is equivalent to:

```bash
omnigent server --config config.yaml --port 6767 &   # foreground, shell-backgrounded
omnigent claude --smart-routing --server http://localhost:6767
```

Type a **trivial** first message (`what git branch are we on?`) → runs on haiku.
A **complex** one (`refactor the auth module with tests`) → runs on opus.

**Exit and re-run `./run.sh` for each prompt.** The pick is made once per session
and reused, so a second prompt in the same session will *not* re-route
(`orchestration.py:4615` on 0.9.0, `:4845` on main). More in `try-these.md`.

### Step 1b — the web UI (two terminals)

`run.sh` is TUI-only. For the browser, run the two processes yourself.

**Terminal 1 — the server. Directory: repo root.**

```bash
cd /path/to/omnigent-smart-routing     # must be here: config.yaml lives here
omnigent stop                          # clear the managed server off the port
omnigent server --config config.yaml --port 6767
```

**Terminal 2 — the host. Directory: anywhere.**

`omnigent host` registers *this machine* as a place sessions can run; it reads no
project config, so the directory doesn't matter.

```bash
omnigent host --server http://localhost:6767
```

**Then in the browser:** open <http://localhost:6767> → **New Chat** → pick your
machine as the host → **set the working directory to this repo** (that is the
directory the agent will actually operate in) → harness **Claude Code** → ⚙️ →
**Model → Smart Routing** → **Save** → send your first message.

New chat per prompt, same as the TUI.

> [!TIP]
> The harness picker also offers a top-level **"Auto · smart routing"** row.
> Picking that routes the **harness as well as the model** — see
> [Harness routing](#harness-routing) below.

### Step 2 — confirm routing is actually on

**Directory:** anywhere.

Routing is **fail-open**: if the judge errors or times out, the session quietly
runs on the harness's default model and you get *no error*. Never assume routing
is on because nothing broke.

```bash
curl -s localhost:6767/v1/info | python3 -m json.tool | grep -A3 smart_routing
```

Want:

```json
"smart_routing_enabled": true,
"smart_routing_sources": { "external": false, "oss": true }
```

`run.sh` runs this check for you; the manual web-UI path does not, so run it
there. If it reports `false`, see [Not seeing routing?](try-these.md).

### Cleanup

```bash
omnigent stop      # or Ctrl-C the foreground server
```

> [!WARNING]
> **Do not add `--background`.** On 0.9.0 it discards `--config` and `--port`
> and starts the managed server against `~/.omnigent/config.yaml`, which has no
> `llm:` block — routing is off, with no error
> (`_run_background_server()`, `cli.py:4111`). The [docs][docs] use the
> foreground form, `omni server -c path/to/config.yaml`.

> **Why start the server explicitly?** The `llm:` judge block lives in this
> repo's `config.yaml`. `omnigent claude` has no `--config` flag and reads the
> global `~/.omnigent/config.yaml`, which a fresh clone won't have.

## Inspecting the routing decision

The routed pick is stamped onto the session row in `~/.omnigent/chat.db`:

```bash
sqlite3 ~/.omnigent/chat.db \
  "SELECT datetime(created_at,'unixepoch','localtime'), title, session_overrides
     FROM conversations
    WHERE session_overrides LIKE '%cost_control%'
    ORDER BY created_at DESC LIMIT 5;"
```

```
2026-08-15 13:40:14|Describe Repository Files|{"model_override":"haiku","cost_control_mode_override":"on","subagent_routing_override":"on"}
2026-08-15 13:42:38|Design Mobile App System Architecture|{"model_override":"opus","cost_control_mode_override":"on","subagent_routing_override":"on"}
```

| Field | Meaning |
|---|---|
| `cost_control_mode_override` | `"on"` — Smart Routing armed for this session |
| `model_override` | the routed pick, applied to the session |
| `subagent_routing_override` | `"on"` — sub-agent launches route independently |

`model_override` is the field upstream's own test asserts on
(`tests/e2e/routing/test_claude_ui_smart_routing_e2e.py`). Subscription-backed
harnesses report Claude Code's aliases (`haiku`, `opus`) rather than full ids.

| Table | Columns |
|---|---|
| `conversations` | `session_overrides`, `title`, `created_at` |
| `conversation_items` | one row per message |
| `omnigent_conversation_metadata` | `workspace`, `session_usage` (per-model tokens + cost) |

## Harness routing

Omnigent routes the **harness** (Claude Code / Codex / Pi) as well as the model.
This repo configures model routing; harness routing is enabled by selecting the
top-level **"Auto · smart routing"** row in the web-UI harness picker.

Requires credentials for more than one vendor — with only a Claude subscription
the candidate menu contains Claude arms only. Add another via `omnigent setup`.

Does not require the AI Gateway: the built-in judge returns a harness alongside
the model.

Reference:

| | |
|---|---|
| `harness_override="auto"` | `server/routes/_sessions/orchestration.py:4537`, `:6921`, `:7458` |
| Auto-harness label | `runner/subagent_routing.py:116` `AUTO_HARNESS_LABEL_KEY` |
| Harness in the judge verdict | `server/smart_routing.py` `route()` |
| Cross-harness sub-agent spawns | `tests/e2e/routing/test_auto_harness_smart_routing_e2e.py` |
| Docs | [Smart routing][docs] |
| Announcement | [Databricks blog][blog] |

## Verify (no UI)

```bash
~/.local/share/uv/tools/omnigent/bin/python verify_routing.py
```

Runs the judge against your endpoint, without a server or TUI. Output on
`omnigent 0.9.0`:

```
classifier llm : databricks-claude-haiku-4-5
harness        : claude-sdk
candidate models (cheapest->most capable): ['claude-haiku-4-5', 'claude-sonnet-4-6', 'claude-opus-4-8']

[TRIVIAL] "What's the current git branch?"
   -> picked : claude-haiku-4-5
   -> why    : This is a SIMPLE task (quick git status lookup); selected cheapest model claude-haiku-4-5.

[COMPLEX] 'Refactor the auth module to use dependency injection and update all call sites, with tests.'
   -> picked : claude-opus-4-8
   -> why    : This is a COMPLEX task (multi-file refactor involving architecture changes, dependency
               injection pattern implementation, and comprehensive test writing); selected most capable
               model claude-opus-4-8.
```

## Prerequisites

- A **Claude Code subscription**, registered as Omnigent's default provider
  (`omnigent setup` → Subscription). Check with:
  ```bash
  grep -A3 'providers:' ~/.omnigent/config.yaml   # kind: subscription
  ```
- **Python 3.12+**, `uv`, and Omnigent with the Databricks extra. Pin 3.12
  explicitly — if your default `uv` Python is older, the install fails with
  *"the current Python version does not satisfy Python>=3.12"*:
  ```bash
  uv tool install --force --python 3.12 "omnigent[databricks]"
  ```
  The extra ships `databricks-sdk`. Without it, a token-less profile
  (`auth_type = databricks-cli`) cannot be resolved at all.
- A Databricks profile for the **judge only** — its workspace just needs to
  serve one cheap model, `databricks-claude-haiku-4-5`. It does **not** need to
  serve the models being routed across; those come from the subscription.
  Re-auth when the OAuth session expires (the SDK reports *"could not mint a
  token"*, the CLI *"stored credentials from older CLI versions are no longer
  used"*):
  ```bash
  databricks auth login --host https://<workspace>.cloud.databricks.com --profile <name>
  ```

## Files

| File | Purpose |
|---|---|
| `config.yaml` | The `llm:` judge block — the entire setup |
| `run.sh` | Starts the server + `omnigent claude --smart-routing` |
| `verify_routing.py` | Headless check: runs the real judge against your endpoint |
| `try-these.md` | Trivial vs. complex first-message prompts |

## Routing modes

| Mode | Routes | Enable with | Here |
|---|---|---|---|
| Model | The model, within Claude Code | `omnigent claude --smart-routing`, or ⚙️ → Model → Smart Routing | ✅ |
| Harness + model | The harness and the model | **"Auto · smart routing"** harness row (`harness_override="auto"`) | see [Harness routing](#harness-routing) |

Auto is a web-UI flow; `smart_routing_cli.py` has no `auto` path.

The routers are also distinct: this repo uses the **built-in judge**. The Unity
AI Gateway router (`routing: provider: external`) is a separate backend, and the
cost figures in the [blog][blog] describe that one. See [routing docs][docs].

## Practices

- **Keep the judge small and fast.** `ROUTING_REQUEST_TIMEOUT_S = 9.0`, one
  attempt, no retry (`server/smart_routing.py`).
- **Verify routing explicitly.** It is fail-open: on error or timeout `route()`
  returns `None` and the session runs on the harness default with no error.
  `run.sh` gates on `/v1/info`; `verify_routing.py` checks the judge directly.
- **One decision per session.** Start a new session per task.
- **Front-load detail in the first message.** The judge sees only the opening
  prompt — no test results, no repo state.
- **Track model distribution, completion rate, and spend**, not just that
  routing fired.

## Adapting it

- **Different workspace?** Change `llm.profile` in `config.yaml`.
- **No Databricks at all?** Drop `profile:` and give the judge an Anthropic key
  instead — this keeps the demo entirely off Databricks:
  ```yaml
  llm:
    model: claude-haiku-4-5
    connection:
      base_url: https://api.anthropic.com
      api_key: ${ANTHROPIC_API_KEY}
  ```
- **Reminder:** whichever you pick, the judge needs its **own** credential. The
  Claude subscription covers the coding harness only.

## Source references

Line numbers verified on **0.9.0** (the released version this demo targets);
where `main` has drifted, the `0.10.0.dev0` line is given too.

- **Built-in judge, no gateway** — `server/smart_routing.py` `LLMRoutingClient`
  (`:566` `route()`); `server/routes/_sessions/orchestration.py`
  `_reject_ungatewayed_model_routing` (rejects only when neither a gateway nor an
  `llm:` model exists) — **`:6693` on 0.9.0, `:7050` on main**.
- **Candidates + rubric** — `smart_routing.py:395` (catalog fetch),
  `:384-448` (cost ordering), `:504-510` (`SIMPLE`/`MODERATE`/`COMPLEX` →
  first/middle/last), `:622` (clamps a hallucinated pick to cheapest).
- **Subscription candidates** — `model_catalog.py` `_static_subscription_listing`
  → `model_fallbacks.static_model_fallback("subscription", "claude")`: the
  curated Anthropic ids a subscription-backed harness offers.
- **Judge auth has no subscription path** — `runtime/policies/builder.py`
  `_resolve_server_llm_connection` (`connection:` or Databricks `profile:` only).
- **Decides once, opt-in per session** — `orchestration.py`
  (`cost_control_mode_override == "on"` gate) — **`:4615` on 0.9.0, `:4845` on
  main**.
- **CLI entry point** — `smart_routing_cli.py:225` (sets
  `cost_control_mode_override="on"`; binds the harness's own wrapper, not a
  custom agent).
- **Judge config schema** — `spec/types.py` `LLMConfig` (`model` required).
- **Fail-open + no retry** — `smart_routing.py` `ROUTING_REQUEST_TIMEOUT_S = 9.0`
  and the `except … return None` in `route()`.
- **`--background` drops `--config`** — `cli.py:4111` `_run_background_server()`
  takes no arguments; `--config`/`--port` are parsed and discarded.
- **Auto (harness + model) routing** — `harness_override="auto"`, exercised by
  `tests/e2e/routing/test_auto_harness_smart_routing_e2e.py`; model-only routing
  by `test_claude_ui_smart_routing_e2e.py`.

### External references

- **Docs** — <https://omnigent.ai/docs/build/routing>
- **Blog** — [Smart Routing in Unity AI Gateway][blog] (the external
  gateway router and its benchmarks — see the note under *Scope*)
- **Omnigent launch** — [Introducing Omnigent][intro]

[docs]: https://omnigent.ai/docs/build/routing
[blog]: https://www.databricks.com/blog/smart-routing-unity-ai-gateway-match-frontier-quality-30-lower-cost-task
[intro]: https://www.databricks.com/blog/introducing-omnigent-meta-harness-combine-control-and-share-your-agents
[repo]: https://github.com/omnigent-ai/omnigent
