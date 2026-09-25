"""Live confirmation: the LLM model-switch config actually selects a
different model on a real completion against Dalton's wave endpoint.

Not run by default — see tests/live/README.md. `pytest -m live_infra` to run.
"""

from __future__ import annotations

import httpx
import pytest

from meeting_voice_agent.config import AgentConfig

pytestmark = pytest.mark.live_infra


def _chat_completion(config, *, use_fallback: bool) -> dict:
    model = config.llm.fallback_model if use_fallback else config.llm.model
    url = f"{config.llm.base_url.rstrip('/')}/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": "Reply with exactly one word: pong",
            }
        ],
        "max_tokens": 16,
        "temperature": 0,
        **(config.llm.extra_body or {}),
    }
    headers = {"Authorization": f"Bearer {config.llm.api_key}"}

    try:
        response = httpx.post(url, json=payload, headers=headers, timeout=15.0)
    except httpx.ConnectError as exc:
        pytest.skip(
            f"wave LLM endpoint unreachable at {url} (model={model}): {exc!r}. "
            "This is a LAN-only address (Dalton's box) — see tests/live/README.md. "
            f"Reproduce: curl -m 5 {url}"
        )
    except httpx.TimeoutException as exc:
        pytest.skip(f"wave LLM endpoint timed out at {url} (model={model}): {exc!r}")

    if response.status_code != 200:
        pytest.fail(
            f"wave LLM endpoint reachable but returned {response.status_code} for "
            f"model={model}: {response.text[:500]}"
        )

    return response.json()


def test_default_model_round_trips_a_real_completion():
    config = AgentConfig.from_env()
    assert config.llm.model == "qwen3.5-9b"

    body = _chat_completion(config, use_fallback=False)

    content = body["choices"][0]["message"]["content"]
    assert isinstance(content, str) and content.strip() != ""


def test_fallback_model_round_trips_a_real_completion():
    config = AgentConfig.from_env()
    assert config.llm.fallback_model == "granite4.1-8b"

    body = _chat_completion(config, use_fallback=True)

    content = body["choices"][0]["message"]["content"]
    assert isinstance(content, str) and content.strip() != ""
