# Live integration tests (task 01a0d4a0 stage 3)

Everything under `tests/` at the top level (stage 1) mocks every backend —
no network, no real model load. Everything in THIS directory is the
opposite: a genuinely live round trip against real infra. All of it is
marked `@pytest.mark.live_infra` and excluded from the default `pytest` run
(`addopts = "-m 'not live_infra'"` in `pyproject.toml`), so:

- `pytest` — stage 1's fast, always-green unit suite plus stage 3's unit
  seam tests (`tests/test_mcp_tools.py`). No network required.
- `pytest -m live_infra` — this directory. Requires real endpoints to be
  reachable; individual tests `pytest.skip(...)` with the exact command/error
  when their target isn't reachable, rather than failing, since "unreachable
  from wherever this happens to run" is an infra fact, not a code defect.

## What each file needs

- `test_wave_llm_live.py` — Dalton's wave LLM endpoint
  (`MVA_LLM_BASE_URL`, default `http://192.0.2.107:8090/v1`). Confirms the
  model-switch config (`qwen3.5-9b` / `granite4.1-8b`) actually selects a
  different model on a real completion.
- `test_moon_speech_live.py` — moon's speaches STT/TTS
  (`MVA_STT_BASE_URL` / `MVA_TTS_BASE_URL`, default `http://build-host.local:8081/v1`).
  Confirms real audio in, real transcript out (STT) and real text in, real
  audio bytes out (TTS) — not mocks.
- `test_mcp_live.py` — a running Core instance's `/mcp` endpoint
  (`MVA_MCP_BASE_URL`, `MVA_MCP_AUTH_TOKEN` — a real, active voice-runtime
  token, e.g. printed once by `mix platform.seed_meeting_voice_agent`).
  Confirms the MCP tool-call path executes a REAL Burrow tool
  (`space_create`, `space_get_context`) and that the `post_to_meeting_chat`
  hand-off tool posts into the derived chat space for real, readable back
  via `space_get_context`.

Both `192.0.2.107:8090` and `build-host.local:8081` are LAN addresses on
Dalton/moon's physical network — this sandbox has no route to that LAN
(confirmed: every attempt times out at the TCP level, not refused/DNS-failed
in a way that would indicate a config bug on this end). `MVA_MCP_BASE_URL`
has no such constraint — Core is a service this repo can run locally
(`mix phx.server` against a local Postgres) or reach at its real deployed
URL, so `test_mcp_live.py` is not LAN-gated the way the other two are.
