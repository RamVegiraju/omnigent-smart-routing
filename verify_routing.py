"""Verify the built-in judge end-to-end against the live Databricks endpoint.

Reproduces the wiring omnigent/cli.py:_build_local_llm_routing_client uses:
    parse_server_llm -> _resolve_server_llm_connection ->
    _build_policy_llm_client -> LLMRoutingClient(...).route(msg, models)

Routes a TRIVIAL and a COMPLEX prompt and prints the judge's pick. Exercises
the real source path (LLMRoutingClient, omnigent/server/smart_routing.py:566
route()) without the TUI. Verified on omnigent 0.9.0: trivial -> haiku,
complex -> opus.
"""

import asyncio

import yaml

from omnigent.spec import parse_server_llm
from omnigent.runtime.policies.builder import (
    _build_policy_llm_client,
    _resolve_server_llm_connection,
)
from omnigent.server.smart_routing import LLMRoutingClient

CONFIG = "config.yaml"
HARNESS = "claude-sdk"

# At run time the candidate list comes from the LIVE runner catalog
# (/v1/sessions/{id}/models, fetched at smart_routing.py:395). For this offline
# judge test we pass the same three claude endpoints directly, ordered
# cheapest -> most capable, exactly as the runner reports them.
CANDIDATE_MODELS = [
    "databricks-claude-haiku-4-5",
    "databricks-claude-sonnet-4-6",
    "databricks-claude-opus-4-8",
]

PROMPTS = {
    "TRIVIAL": "What's the current git branch?",
    "COMPLEX": (
        "Refactor the auth module to use dependency injection and "
        "update all call sites, with tests."
    ),
}


async def main() -> None:
    raw = yaml.safe_load(open(CONFIG).read())
    server_llm = parse_server_llm(raw.get("llm"))
    conn = _resolve_server_llm_connection(server_llm)
    client = _build_policy_llm_client(server_llm, conn)
    assert client is not None, "no llm: block parsed"

    router = LLMRoutingClient(client)
    available = {HARNESS: CANDIDATE_MODELS}

    print(f"classifier llm : {server_llm.model}")
    print(f"harness        : {HARNESS}")
    print(f"candidate models (cheapest->most capable): {CANDIDATE_MODELS}\n")

    for label, prompt in PROMPTS.items():
        result = await router.route(prompt, available)
        if result is None:
            print(f"[{label}] router returned None (fail-open)\n")
            continue
        print(f"[{label}] {prompt!r}")
        print(f"   -> picked : {result.model}")
        print(f"   -> why    : {result.rationale}\n")


if __name__ == "__main__":
    asyncio.run(main())
