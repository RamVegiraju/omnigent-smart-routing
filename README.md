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

Omnigent routes both the **model** (what this repo configures) and the
**harness** itself — see [Harness routing](#harness-routing-supported).

## What this demo routes across

This setup routes across a **Claude Code subscription**. Two separate
connections are in play, and keeping them straight is the whole trick:

| | What it is | Auth |
|---|---|---|
| **Coding harness** | Claude Code, doing the actual work. Routing picks among the **subscription's own models** — `claude-haiku-4-5`, `claude-sonnet-4-6`, `claude-opus-4-8`, … | Our **Claude subscription** (no per-token cost) |
| **Judge** | A cheap classifier that reads your first message, labels it `SIMPLE`/`MODERATE`/`COMPLEX`, and picks one of the above. Does **no** coding. | A small **Databricks** credential |

> [!IMPORTANT]
> A Claude subscription authenticates the **coding harness only — it cannot
> authenticate the judge.** `_resolve_server_llm_connection`
> (`runtime/policies/builder.py`) accepts only a `connection:` block
> (`base_url` + `api_key`) or a Databricks `profile:`; with neither it falls
> back to `ANTHROPIC_API_KEY` in the environment. That is why the judge below
> carries its own Databricks credential even though the coding runs on the
> subscription.

Because the harness is subscription-backed, the candidate list is the curated
subscription listing (`model_catalog.py` `_static_subscription_listing` →
`static_model_fallback("subscription", "claude")`) — **plain Anthropic model
ids, not `databricks-*` serving endpoints.**

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

Do this first. If it fails, the problem is your judge credential, not routing —
which saves you debugging a TUI that was never going to work. Expected output is
in [Verify (no UI)](#verify-no-ui).

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
> [Harness routing](#harness-routing-supported) below.

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
> **Never add `--background`.** On 0.9.0, `omnigent server --background` routes
> to `_run_background_server()` (`cli.py:4111`), which takes **no arguments**
> and silently discards both `--config` and `--port` — it starts the *managed*
> server against `~/.omnigent/config.yaml` instead. That file has no `llm:`
> block, so the judge never loads and **routing is silently off**, with no
> error. Verified: `--config … --port 6799 --background` reports port `6767`
> and `oss:false`, while the identical config in the foreground reports
> `oss:true`. The [official docs][docs] likewise show the foreground form,
> `omni server -c path/to/config.yaml`.

> **Why start the server explicitly?** The `llm:` judge block lives in this
> repo's `config.yaml`, so `run.sh` starts the server against it — keeping the
> demo **hermetic** (self-contained: works on any clone, reads no global config).
> `omnigent claude` has no `--config` flag; on its own it reads your global
> `~/.omnigent/config.yaml` instead, which a fresh clone won't have.

## Did it work? Inspecting the routing decision

The routed pick is stamped onto the session row, so you can verify a run after
the fact without reading logs. Omnigent stores sessions in a SQLite DB at
`~/.omnigent/chat.db`:

```bash
sqlite3 ~/.omnigent/chat.db \
  "SELECT datetime(created_at,'unixepoch','localtime'), title, session_overrides
     FROM conversations
    WHERE session_overrides LIKE '%cost_control%'
    ORDER BY created_at DESC LIMIT 5;"
```

A routed session looks like this — one trivial, one complex, from two web-UI
sessions two minutes apart:

```
2026-08-15 13:40:14|Describe Repository Files|{"model_override":"haiku","cost_control_mode_override":"on","subagent_routing_override":"on"}
2026-08-15 13:42:38|Design Mobile App System Architecture|{"model_override":"opus","cost_control_mode_override":"on","subagent_routing_override":"on"}
```

- `cost_control_mode_override: "on"` — Smart Routing was armed for this session.
- `model_override` — **the judge's pick, applied to the session.** This is the
  authoritative signal; upstream's own e2e test asserts exactly this field
  (`tests/e2e/routing/test_claude_ui_smart_routing_e2e.py`:
  `assert same_arm(snapshot.get("model_override"), decision["model"])`).
- `subagent_routing_override: "on"` — sub-agent launches route independently too,
  the behavior described in the [Databricks blog][blog].

The alias form (`haiku`/`opus` rather than `claude-haiku-4-5`) is Claude Code's
own model naming, which is what a **subscription-backed** harness reports.

Related tables, if you want to dig further:

| Table | Useful columns |
|---|---|
| `conversations` | `session_overrides` (routing decision), `title`, `created_at` |
| `conversation_items` | one row per message — confirms the session actually ran |
| `omnigent_conversation_metadata` | `workspace` (the directory the agent ran in), `session_usage` (per-model token + cost totals) |

## Harness routing (supported)

Everything above routes the **model** inside Claude Code. Omnigent also routes
the **harness itself** — Claude Code vs Codex vs Pi — which is the headline
capability of the [Databricks blog][blog] announcement.

Turn it on by picking the top-level **"Auto · smart routing"** row in the web-UI
harness picker instead of Claude Code. The [official docs][docs] describe this as
the per-session activation path: *"With a router configured, users see an **Auto**
option in the harness picker; picking it defers harness + model selection to the
router on the first message."*

Confirmed present in `omnigent 0.9.0`:

| What | Where |
|---|---|
| `harness_override="auto"` handling | `server/routes/_sessions/orchestration.py:4537`, `:6921`, `:7458` |
| The durable auto-harness label | `runner/subagent_routing.py:116` `AUTO_HARNESS_LABEL_KEY = "omnigent.routing.auto_harness"` |
| Harness resolution in the judge's verdict | `server/smart_routing.py` — `route()` returns a `harness` alongside the model |
| End-to-end coverage | `tests/e2e/routing/test_auto_harness_smart_routing_e2e.py` (model-only is `test_claude_ui_smart_routing_e2e.py`) |

Two things worth knowing:

- **It does not require the AI Gateway.** The built-in OSS judge returns a
  harness as well as a model, so `provider: external` is not needed.
- **It needs more than one vendor credential to be meaningful.** Auto picks
  *across* harnesses, so with only a Claude subscription configured the candidate
  menu contains Claude arms only and Auto degenerates into model-only routing.
  Add a second credential (a ChatGPT subscription or an OpenAI key) via
  `omnigent setup` before demoing it.

The Auto row is also the only context where cross-harness sub-agent spawns are
legal — a routed spawn may land on the counterpart family
(`test_auto_harness_smart_routing_e2e.py`).

## Verify (no UI)

```bash
~/.local/share/uv/tools/omnigent/bin/python verify_routing.py
```

Runs the real judge against your endpoint. Actual output on `omnigent 0.9.0`:

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

This is the fastest way to prove the judge works — it needs no server and no
TUI, so it isolates a credential problem from a routing problem.

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

## Scope & best practices

### What this demo is (and isn't)

Omnigent exposes smart routing at **two** levels. This demo is deliberately the
first — "basic" routing on a Claude subscription:

| | Routes | How you turn it on | Configured here |
|---|---|---|---|
| **Model-only** | The model, within Claude Code | `omnigent claude --smart-routing`, or ⚙️ → Model → Smart Routing | ✅ yes |
| **Harness + model** | *Both* the harness (Claude Code / Codex / …) and the model | The top-level **"Auto · smart routing"** harness row (`harness_override="auto"`) | Supported, not wired up — see [Harness routing](#harness-routing-supported) |

**Both are supported by Omnigent.** This repo simply configures the first,
because the goal is basic model routing on a Claude subscription. The Auto row
is not reachable from `omnigent claude --smart-routing` — there is no `auto`
path in `smart_routing_cli.py` — so it is a web-UI flow.

> [!NOTE]
> **The blog's cost numbers are not this demo's.** "65% of the cost per task"
> and "frontier quality at 30%+ lower cost" describe the **Unity AI Gateway**
> external router (`routing: provider: external`, `router_name: task_v0`)
> measured on Databricks' internal and public coding benchmarks. This demo runs
> the **built-in OSS judge** — no gateway, no benchmark behind it. Don't quote
> those figures for this setup.

### Practices worth keeping

- **Keep the judge small, cheap, and fast.** The blog calls for "a lightweight,
  low-latency model," and the implementation agrees: `ROUTING_REQUEST_TIMEOUT_S
  = 9.0`, one attempt, **no retry** — "on an interactive path a second try only
  doubles the stall." `haiku` is the right class of model here.
- **Routing is fail-open, so verify it explicitly.** If the judge errors or
  times out, `route()` returns `None` and the session quietly runs on the
  harness's default model — you get no error. That is why `run.sh` gates on
  `/v1/info` and why `verify_routing.py` exists. **Never assume routing is on
  because nothing broke.**
- **One decision per session — so keep sessions small.** The pick is made on the
  first message and reused. The blog names this as a known limitation
  ("sessions often get reused, making initial routing decisions stale") and
  recommends "designing smaller sessions." Start a new session per task rather
  than steering one long one.
- **Front-load detail in the first message.** The router sees only the opening
  prompt — no test results, no repo state. The blog: "opening prompts are rarely
  precise," since developers describe symptoms. A first message that states the
  scope gets a better pick than one that reveals it three turns in.
- **Track the outcome, not just the routing.** The blog's suggested measures:
  distribution of sessions across models, end-to-end completion rate, and
  dollars saved. A cheap model chosen badly costs more than it saves.

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
