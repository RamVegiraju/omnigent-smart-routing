# Smart Routing for Claude Code (Omnigent)

Route **cheap models to trivial tasks, expensive models to hard ones** — using
[Omnigent](https://github.com/omnigent-ai/omnigent)'s built-in smart routing.
Docs: <https://omnigent.ai/docs/build/routing>.

A small **judge LLM** reads your first message, classifies it
`SIMPLE`/`MODERATE`/`COMPLEX`, and picks a model sized for the work. You don't
pin a model or list candidates.

> Verified against installed **`omnigent 0.9.0`**. Uses the **built-in ("oss")
> judge** — one `llm:` block, no AI Gateway.

---

## The whole setup: one `llm:` block

`config.yaml` is the entire configuration:

```yaml
llm:
  model: databricks-claude-haiku-4-5
  profile: adb-984752964297111
```

Per the docs: *"Configure a server `llm:` block and the server uses the built-in
judge backed by it, with no `routing:` block required."* On boot the server
reports `smart_routing_sources: {external: false, oss: true}` at `/v1/info`.

The `llm:` model is the **judge** — a cheap model that only *classifies* the
task and picks a model. It is a **separate connection from the coding harness**
and does **not** do the coding.

---

## How it works

1. **Judge = your `llm:` block.** Backs the built-in `LLMRoutingClient`
   (`server/smart_routing.py:566` `route()`); no gateway needed
   (`orchestration.py:6693` `_reject_ungatewayed_model_routing` only rejects when
   *neither* a gateway *nor* an `llm:` model exists).
2. **Candidates come from your live workspace.** At routing time the server
   fetches the runner catalog (`/v1/sessions/{id}/models`,
   `smart_routing.py:395`), ordered cheapest → most capable by cost tier
   (`smart_routing.py:384-448`). For Claude in this workspace:
   `haiku-4-5 → sonnet-4-6 → opus-4-8`.
3. **The rubric** maps `SIMPLE → first / MODERATE → middle / COMPLEX → last`
   model (`smart_routing.py:504-510`).
4. **Decides once, on the first message, then persists**
   (`orchestration.py:4615`). The model does **not** flip turn-to-turn within a
   session — start a **new session** to route a different first message.
5. **Opt-in per session.** Routing runs only when the session has
   `cost_control_mode_override == "on"` (`orchestration.py:4615`). You turn that
   on either in the UI (Model → Smart Routing) or via the CLI flag below.

---

## Run it

Two equivalent ways to arm a session. Both use the same `config.yaml` judge.

### A. Web UI

```bash
omnigent server --config config.yaml --port 6767 --background
```

The UI also needs a **host daemon** online to run on (the CLI path spawns its
own; the UI does not). In a second terminal:

```bash
omnigent host --server http://localhost:6767
```

Then open <http://localhost:6767> and:

1. Harness = **Claude Code**; pick your online host and a **Working directory**
   (otherwise the send button stays disabled — "No hosts" means no host is online).
2. Click the **⚙️ gear** → **Configure Claude Code**.
3. **Model → Smart Routing** → **Save**.
4. Type your **first message** — it gets routed.

(In the UI, "Smart Routing" is the `__smart__` value in the Model dropdown; it
appears whenever the server reports `smart_routing_enabled: true`.)

### B. CLI

```bash
./run.sh
```

Starts the server and launches the Claude Code TUI armed for routing —
equivalent to:

```bash
omnigent server --config config.yaml --port 6767 --background
omnigent claude --smart-routing --server http://localhost:6767
```

`omnigent claude --smart-routing` is the source-documented entry point
(`smart_routing_cli.py`): it creates the session with
`cost_control_mode_override="on"` (`smart_routing_cli.py:225`) bound to the
harness's own built-in wrapper — *"Smart Routing rides on the session row, not
the agent"* (`smart_routing_cli.py:_routing_agent_id`). No custom agent needed.
Your first typed message is what gets routed.

Either way, a trivial first message runs on haiku; a complex one on opus. See
**`try-these.md`**. When done: `omnigent stop`.

> **Model id note:** the native harness reports Unity Catalog ids
> (`system.ai.claude-haiku-4-5`); the raw serving endpoints are
> `databricks-claude-haiku-4-5`. Same models, different id namespace.

---

## Verify headlessly (no UI)

`verify_routing.py` runs the real judge (`LLMRoutingClient.route`) against your
live endpoint with a trivial and a complex prompt:

```bash
~/.local/share/uv/tools/omnigent/bin/python verify_routing.py
```

Expected (verified on 0.9.0): trivial → `databricks-claude-haiku-4-5`, complex →
`databricks-claude-opus-4-8`.

---

## Troubleshooting

- **`routing judge call failed: 403 Forbidden`** — a long-running server can
  outlive its OAuth token; the judge then calls the serving endpoint with an
  expired bearer. Fix: `omnigent stop` and restart the server so it mints a
  fresh token.
- **`Denied by policy (policy evaluation error)`** — the server merges
  `~/.omnigent/config.yaml`, so a misconfigured policy there fail-closes every
  session even when `--config` points elsewhere. Check that file's `policies:`
  block (or remove it) if routing picks a model but the run is denied.
- **Send button disabled / "No hosts"** — the web UI needs an online host and a
  working directory set. Start one with `omnigent host --server <url>` and pick
  the folder. (The CLI path spawns its own host, so it doesn't hit this.)

---

## Subscription vs. API/Databricks

The routing **mechanism is identical** regardless of how the coding harness is
billed — only *what a tier costs* changes.

- **The judge always needs its own credentials.** The `llm:` block is a
  separate connection from the harness (`spec/types.py` `LLMConfig`: `model` is
  the only required field). A **Claude subscription authenticates the
  *harness*, not the judge** — subscription OAuth doesn't expose a raw
  model-inference API for the judge's structured-output call. So you must give
  the judge a `profile:` or `connection.api_key`. This sample uses a Databricks
  `profile:`.
- **Candidates come from what the harness reports it can serve.** On a
  subscription the tiers surface as Claude aliases (`fable/opus/sonnet/haiku`,
  `claude_model_vocabulary.py:37`); with Databricks they're the
  `databricks-claude-*` endpoints. Same routing either way.
- **What differs is the payoff.** With per-token billing (API/Databricks),
  routing cheap→expensive saves money. On a flat subscription, there's no
  per-token charge, so routing instead saves **usage quota / rate-limit budget
  and latency** on trivial turns.

---

## Prerequisites

- **Python 3.12+**, `uv` — install with the Databricks extra:
  ```bash
  uv tool install "omnigent[databricks]"
  ```
  The extra pulls in `databricks-sdk`, needed for the token-less OAuth profiles
  in `~/.databrickscfg`.
- A Databricks profile whose workspace serves `databricks-claude-haiku-4-5`,
  `-sonnet-4-6`, `-opus-4-8`. Wired to **`adb-984752964297111`** in
  `config.yaml`. Re-auth if the token expired:
  ```bash
  databricks auth login --host https://adb-984752964297111.11.azuredatabricks.net --profile adb-984752964297111
  ```

---

## What's in here

```
model-routing/
├── README.md          ← you are here
├── config.yaml        ← the llm: judge block — the entire setup
├── run.sh             ← starts the server + launches omnigent claude --smart-routing
├── try-these.md       ← trivial vs. complex first-message prompts
└── verify_routing.py  ← headless check: runs the real judge against your endpoint
```

---

## Adapting it

- **Different workspace?** Change `llm.profile` in `config.yaml`; make sure that
  workspace serves the Claude endpoints.
- **Different provider?** Change `llm.model` (e.g. `anthropic/claude-haiku-4-5`)
  and give the judge matching credentials via `connection:`.
- **Cheaper judge?** Swap `llm.model` for a smaller model — it only classifies
  difficulty.

---

## References (verified against installed omnigent 0.9.0)

- **Built-in vs external router** — `server/routing_backend.py:1-6`: `oss-llm`
  (built-in judge) vs `databricks-aigw` (external `task_v1` gateway). We use the
  built-in one. Docs describe both; the external one needs a `routing:` block
  (docs show `router_name: task_v0`; installed source uses `task_v1`,
  `smart_routing.py:778` — external-only, doesn't affect this sample).
- **No gateway needed** — `orchestration.py:6693` `_reject_ungatewayed_model_routing`.
- **The judge & rubric** — `server/smart_routing.py:504-510` (SIMPLE/MODERATE/
  COMPLEX), `:566` `route()`, `:395` catalog fetch, `:384-448` cost ordering,
  `:622` clamps a hallucinated pick to the cheapest model.
- **Decides on first message, opt-in per session** — `orchestration.py:4615`.
- **CLI entry point** — `smart_routing_cli.py:225` (`cost_control_mode_override
  ="on"`), `_routing_agent_id` (binds the harness's own wrapper, not a custom
  agent).
- **Judge config schema** — `spec/types.py` `LLMConfig` (`model` required;
  `profile`/`connection` for auth).
- **Docs** — <https://omnigent.ai/docs/build/routing>.
```
