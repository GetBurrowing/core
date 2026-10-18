"""Configuration for the meeting voice agent.

Everything that affects the experiment surface this task declares (LLM model
switch, VAD/endpointing thresholds) — and everything that points at a specific
backend deployment (moon's speaches STT/TTS, Dalton's wave LLM endpoint) — is
read from the environment here and nowhere else. No module outside this file
should hard-code a base_url, model name, or threshold; they should all accept
an `AgentConfig` (or a value pulled from one) as an argument.

Every value has a documented default so the service is runnable out of the
box against moon/wave's currently-known addresses, but every one of those
defaults is expected to be overridden per-deployment via env vars. The one
exception is `MVA_MCP_BASE_URL`, the Burrow install this agent talks to: it has
no default, because any default would name one particular install, and an
empty or unset value raises `ConfigError`. See README.md for the full list.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


class ConfigError(ValueError):
    """A required environment variable is missing or empty."""


def _env_required_str(name: str, hint: str) -> str:
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        raise ConfigError(f"{name} is required and has no default: {hint}")
    return value


def _env_str(name: str, default: str) -> str:
    value = os.environ.get(name)
    return value if value not in (None, "") else default


def _env_optional_str(name: str) -> str | None:
    value = os.environ.get(name)
    return value if value not in (None, "") else None


def _env_float(name: str, default: float) -> float:
    value = os.environ.get(name)
    if value in (None, ""):
        return default
    try:
        return float(value)
    except ValueError as exc:
        raise ValueError(f"{name}={value!r} is not a valid float") from exc


def _env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value in (None, ""):
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise ValueError(f"{name}={value!r} is not a valid int") from exc


def _env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value in (None, ""):
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class VadConfig:
    """Silero VAD thresholds. Part of the declared experiment surface."""

    min_speech_duration: float = 0.05
    min_silence_duration: float = 0.55
    activation_threshold: float = 0.5
    prefix_padding_duration: float = 0.5
    sample_rate: int = 16000

    @classmethod
    def from_env(cls) -> VadConfig:
        return cls(
            min_speech_duration=_env_float("MVA_VAD_MIN_SPEECH_DURATION", 0.05),
            min_silence_duration=_env_float("MVA_VAD_MIN_SILENCE_DURATION", 0.55),
            activation_threshold=_env_float("MVA_VAD_ACTIVATION_THRESHOLD", 0.5),
            prefix_padding_duration=_env_float("MVA_VAD_PREFIX_PADDING_DURATION", 0.5),
            sample_rate=_env_int("MVA_VAD_SAMPLE_RATE", 16000),
        )


@dataclass(frozen=True)
class TurnDetectorConfig:
    """Turn-detector model selection and threshold. Experiment surface."""

    # "english", "multilingual", or "none" (VAD-only endpointing, no ML turn model).
    model: str = "english"
    unlikely_threshold: float | None = None

    @classmethod
    def from_env(cls) -> TurnDetectorConfig:
        model = _env_str("MVA_TURN_DETECTOR_MODEL", "english").strip().lower()
        if model not in ("english", "multilingual", "none"):
            raise ValueError(
                f"MVA_TURN_DETECTOR_MODEL={model!r} must be one of "
                "'english', 'multilingual', 'none'"
            )
        threshold_raw = _env_optional_str("MVA_TURN_DETECTOR_UNLIKELY_THRESHOLD")
        threshold = float(threshold_raw) if threshold_raw is not None else None
        return cls(model=model, unlikely_threshold=threshold)


@dataclass(frozen=True)
class BackendEndpoint:
    """An OpenAI-compatible backend: base_url + model + optional api_key."""

    base_url: str
    model: str
    api_key: str = "not-needed"


@dataclass(frozen=True)
class LlmConfig:
    """LLM backend config: the model switch is the declared experiment surface."""

    base_url: str
    model: str
    fallback_model: str
    api_key: str = "not-needed"
    thinking_enabled: bool = False
    extra_body: dict | None = None

    @classmethod
    def from_env(cls) -> LlmConfig:
        thinking_enabled = _env_bool("MVA_LLM_THINKING", False)
        extra_body_json = _env_optional_str("MVA_LLM_EXTRA_BODY_JSON")
        if extra_body_json is not None:
            import json

            extra_body = json.loads(extra_body_json)
        else:
            # qwen3.5's OpenAI-compatible chat/completions endpoint (as served by
            # llama.cpp / llama-swap on Dalton's wave box) toggles thinking mode
            # through chat_template_kwargs.enable_thinking. This default keeps
            # thinking off unless MVA_LLM_THINKING=true, without hard-coding the
            # toggle shape outside config.
            extra_body = {"chat_template_kwargs": {"enable_thinking": thinking_enabled}}
        return cls(
            base_url=_env_str("MVA_LLM_BASE_URL", "http://192.0.2.107:8090/v1"),
            model=_env_str("MVA_LLM_MODEL", "qwen3.5-9b"),
            fallback_model=_env_str("MVA_LLM_FALLBACK_MODEL", "granite4.1-8b"),
            api_key=_env_str("MVA_LLM_API_KEY", "not-needed"),
            thinking_enabled=thinking_enabled,
            extra_body=extra_body,
        )


@dataclass(frozen=True)
class InterruptionConfig:
    """Barge-in tuning. Bounds how quickly the agent yields the floor."""

    allow_interruptions: bool = True
    # Seconds of overlapping speech VAD must see before TTS is cut — this is
    # the "bounded, short window" the stage requires. Keep it small.
    min_interruption_duration: float = 0.3
    min_interruption_words: int = 0

    @classmethod
    def from_env(cls) -> InterruptionConfig:
        return cls(
            allow_interruptions=_env_bool("MVA_ALLOW_INTERRUPTIONS", True),
            min_interruption_duration=_env_float("MVA_MIN_INTERRUPTION_DURATION", 0.3),
            min_interruption_words=_env_int("MVA_MIN_INTERRUPTION_WORDS", 0),
        )


@dataclass(frozen=True)
class EndpointingConfig:
    """How long the session waits for silence before treating a turn as over."""

    min_endpointing_delay: float = 0.4
    max_endpointing_delay: float = 6.0

    @classmethod
    def from_env(cls) -> EndpointingConfig:
        return cls(
            min_endpointing_delay=_env_float("MVA_MIN_ENDPOINTING_DELAY", 0.4),
            max_endpointing_delay=_env_float("MVA_MAX_ENDPOINTING_DELAY", 6.0),
        )


@dataclass(frozen=True)
class AskFloorConfig:
    """Hold-to-ask listening-window gating (task 01a0e47c stage 2).

    Core (Elixir) signals "listening window open" over the room's LiveKit
    data channel the instant `Platform.Meetings.AskFloor.claim/5` succeeds
    for this agent, and "closed" on release (or the existing stuck-claim
    timeout) -- see `ask_floor_gate.py`. Before the first "open" and after
    every "closed", this session's own audio INPUT is detached
    (`AgentSession.input.set_audio_enabled(False)`), which the SDK's
    `_ParticipantAudioInputStream._forward_task` (room_io/_input.py) turns
    into an outright DISCARD at the source -- frames are read off the
    track and dropped, never queued or buffered -- so nothing ever crosses
    from one hold into the next.

    `grace_ms` is the ONE declared experiment surface for this gate: how
    many milliseconds of audio still reach VAD/STT after a "closed" signal
    before the pipe is force-detached. It exists because release and the
    LAST word spoken are not simultaneous -- a human's finger comes up
    slightly before their sentence finishes, or the "closed" signal simply
    arrives a beat after the true release. Zero grace clips trailing
    words (false cutoff, measured as truncated final syllables/words in a
    hold's transcript); too much grace lets ambient/next-turn speech leak
    into a reply that was never asked for (false bleed-through, measured
    as a reply generated from audio spoken after the human's own release).
    Tune by replaying recorded hold sessions and counting each rate
    against this value -- never hard-coded, always this field.

    ## Why the default is 1000 ms, not 300 (task 01a1265f stage 3)

    Input is only ever turned into an STT request when Silero VAD ends a
    speech segment, and VAD ends one only after `VadConfig.min_silence_duration`
    (0.55 s) of silence has reached it. Detaching the input stops VAD from
    seeing anything, so a hold whose speech runs right up to the release
    must keep the input attached for at least that long after "closed".
    300 ms never could. Measured on a dev worker against a throwaway
    `livekit-server --dev` (livekit-agents 1.8.5): control holds that went
    silent before release made their STT request 0.71-0.75 s after the last
    spoken sample. Three holds that spoke up to release made NO STT request
    of their own; their audio sat in VAD's open segment and was transcribed,
    glued to the next hold's words, as soon as that hold attached. Frames
    kept reaching the worker after every release, even in holds where the
    publisher stopped sending (the receiving AudioStream keeps yielding
    frames), and the web client never mutes its mic on release. So the
    frames are there to end the segment; the input was just detached too
    soon, and a longer grace is the fix. Once the STT request has started,
    detaching does not stop the reply: a measured control reply was
    generated after its input detached. The hard floor is therefore VAD
    silence plus inference, about 0.75 s. The default is held above the more
    conservative `min_silence_duration` plus
    `EndpointingConfig.min_endpointing_delay` (0.95 s), and tests pin that
    relation, so raising either of those means raising this too. The cost:
    up to 1 s of speech after release can reach the reply (bleed-through).
    """

    grace_ms: int = 1000

    @classmethod
    def from_env(cls) -> AskFloorConfig:
        return cls(grace_ms=_env_int("MVA_ASK_FLOOR_GRACE_MS", 1000))


@dataclass(frozen=True)
class McpConfig:
    """Core's MCP tool surface (task 01a0d4a0 stage 3).

    Points at Core's `/mcp` endpoint (`PlatformWeb.MCPController`, guarded by
    `PlatformWeb.Plugs.RuntimeBearerAuth`) using the auth token minted for the
    "meeting-assistant" voice runtime by stage 2's
    `mix platform.seed_meeting_voice_agent`. `allowed_tools` is deliberately
    NOT filtered client-side: Core's `Platform.Federation.ToolAuthorization`
    already enforces `allowed_bundles` server-side (fail-closed) for this
    exact runtime row, so duplicating that list here would just be a second
    copy that can drift from the one source of truth.
    """

    base_url: str
    auth_token: str
    client_session_timeout_seconds: float = 10.0

    @classmethod
    def from_env(cls) -> McpConfig:
        return cls(
            # Must be the public host, not an in-cluster `:4000` URL: Core
            # redirects that (e.g. to its canonical host or to https), and
            # the MCP client correctly refuses to follow a redirect rather
            # than silently re-POSTing — so the *URL* has to be right, not
            # the client's redirect handling (Dalton's moon run, rollup
            # space 01a0b5bf). Required, with no default: a default would
            # name one particular Burrow install (task 01a116de).
            base_url=_env_required_str(
                "MVA_MCP_BASE_URL",
                "set it to this deployment's public Burrow MCP URL, "
                "e.g. https://suite.example.com/mcp",
            ),
            auth_token=_env_str("MVA_MCP_AUTH_TOKEN", ""),
            client_session_timeout_seconds=_env_float("MVA_MCP_TIMEOUT", 10.0),
        )


@dataclass(frozen=True)
class AgentConfig:
    """Top-level config assembled from the environment. See README.md."""

    stt: BackendEndpoint
    tts: BackendEndpoint
    tts_voice: str
    llm: LlmConfig
    vad: VadConfig
    turn_detector: TurnDetectorConfig
    interruption: InterruptionConfig
    endpointing: EndpointingConfig
    ask_floor: AskFloorConfig
    mcp: McpConfig
    preemptive_generation: bool
    agent_name: str
    instructions: str
    worker_agent_name: str = field(default="")

    @classmethod
    def from_env(cls) -> AgentConfig:
        stt = BackendEndpoint(
            base_url=_env_str("MVA_STT_BASE_URL", "http://build-host.local:8081/v1"),
            model=_env_str("MVA_STT_MODEL", "faster-distil-whisper-small.en"),
            api_key=_env_str("MVA_STT_API_KEY", "not-needed"),
        )
        tts = BackendEndpoint(
            base_url=_env_str("MVA_TTS_BASE_URL", "http://build-host.local:8081/v1"),
            model=_env_str("MVA_TTS_MODEL", "kokoro"),
            api_key=_env_str("MVA_TTS_API_KEY", "not-needed"),
        )
        tts_voice = _env_str("MVA_TTS_VOICE", "af_heart")
        return cls(
            stt=stt,
            tts=tts,
            tts_voice=tts_voice,
            llm=LlmConfig.from_env(),
            vad=VadConfig.from_env(),
            turn_detector=TurnDetectorConfig.from_env(),
            interruption=InterruptionConfig.from_env(),
            endpointing=EndpointingConfig.from_env(),
            ask_floor=AskFloorConfig.from_env(),
            mcp=McpConfig.from_env(),
            preemptive_generation=_env_bool("MVA_PREEMPTIVE_GENERATION", True),
            agent_name=_env_str("MVA_AGENT_NAME", "meeting-voice-agent"),
            # Task 01a0d4a0 stage 4 round 2 tightened this once already
            # (name the one hand-off tool, call it exactly once, never
            # substitute mail on failure). Stage 5 round 3's live moon run
            # found three MORE failure modes the round-2 wording still let
            # through:
            #
            #   1. Over-firing: "2 plus 2" handed off to chat in 3 of 7
            #      asks. The old wording ("anything long, multi-part, or out
            #      of scope for a spoken answer") gave the model no anchor
            #      for what counts as short -- a trivial question could
            #      always be rationalized as "better read than heard".
            #      Fixed below with concrete short-question examples
            #      (arithmetic, yes/no, one-sentence lookup) that must
            #      always be answered directly, and an explicit "not just
            #      because it COULD be written down" carve-out.
            #   2. Retrying despite "never retry": the old wording said not
            #      to retry "the hand-off with a different tool", which a
            #      weaker local model read as still permitting a SECOND call
            #      to the SAME tool. Fixed below by stating plainly that one
            #      call -- succeed or fail -- IS the complete action, so
            #      there is nothing to retry, period.
            #   3. Hallucinated tool calls: it invented and called
            #      `meeting_say` and `space_search_messages` in prod, both
            #      refused. Fixed below by naming the actual, complete
            #      granted toolset (task 01a0d4a0 stage 5's narrowed
            #      `messaging`+`context_read` `allowed_bundles` --
            #      see `mix platform.seed_meeting_voice_agent`) and saying
            #      explicitly that no other tool exists to call.
            #
            # Task 01a0e8c1-c1c1 stage 3: Dalton's live moon run also found
            # the tool-call e2e case's own example prompt ("what's the
            # context of this space?") triggered NO tool call at all. Naming
            # space_get_context as an available tool (above) never told the
            # model WHEN to reach for it. Fixed below by calling out that
            # exact phrasing -- "context of this space" / "going on in this
            # space" -- as the trigger for calling space_get_context, rather
            # than answering from what it already believes it knows.
            #
            # Task 01a0f8f5 stage 2, and independently task 01a0f842 stage 4
            # (round 2 of Harper's Burrow ticket, item 4 / commit 43a14172):
            # Burrow's `allowed_bundles` (`mix
            # platform.seed_meeting_voice_agent`) already exclude `canvas`
            # (the write bundle), `task`, and `plan` server-side -- this is
            # not a tool-grant gap. The gap was this prompt giving her no
            # guidance for what to say when a participant asks her to build
            # one anyway, so she either hallucinated a tool call outside her
            # granted list or verbally committed to implementation work she
            # structurally cannot do. Fixed below with a generic-category
            # fallback: name the KIND of specialized agent that actually
            # handles that work and route the ask through the existing
            # post_to_meeting_chat hand-off, instead of attempting or
            # offering to do it herself. Both tasks landed the identical
            # fallback text here independently (neither had the other's
            # commit merged yet when its stage ran); reconciled at the
            # 01a0f8f5 deploy merge on 2026-10-01 -- the text itself never
            # needed de-duplicating since the two additions were
            # byte-identical, only this comment did.
            instructions=_env_str(
                "MVA_INSTRUCTIONS",
                "You are a concise meeting assistant. Answer briefly by voice. "
                "The ONLY tools that exist in this conversation are: "
                "post_to_meeting_chat (the chat hand-off described below), "
                "space_get_context, space_get_messages, space_search_messages, "
                "and react. There is no other tool -- never call meeting_say, "
                "mail_draft_create, or any other tool by name; if you are not "
                "certain a tool is in this exact list, do not call it, and "
                "just answer in words or say plainly that you cannot do that. "
                'If asked something like "what\'s the context of this space?" '
                'or "what\'s going on in this space?" -- or any similar '
                "question about the space itself -- call space_get_context to "
                "answer from real data; never guess or answer from memory. "
                "For a short, simple, directly-answerable question -- basic "
                "arithmetic, a yes/no fact, a one-sentence lookup -- just "
                "answer it briefly by voice, right away. Do NOT hand off a "
                "simple question to chat just because the answer COULD be "
                "written down; the hand-off exists for answers a human could "
                "not comfortably follow by ear, not for every answer. "
                "Only for a genuinely long, multi-part, or out-of-scope-for-"
                "speech answer -- several steps, a list, or detail dense "
                "enough to need rereading -- say ONE short acknowledgement "
                'sentence (for example "I\'ll drop the details in chat"), '
                "then call post_to_meeting_chat exactly once with the full "
                "answer as its content. Do not speak the long answer aloud, "
                "and do not call any other tool as a substitute hand-off "
                "path. Calling post_to_meeting_chat ONE time -- whether it "
                "succeeds or returns an error -- IS the complete hand-off "
                "action; there is nothing left to retry, ever, under any "
                "circumstance. If it returns an error, say briefly that you "
                "couldn't post it and stop there: do not call "
                "post_to_meeting_chat again for the same answer, do not try "
                "a different tool instead, and never use a mail or email "
                "tool for any purpose in a meeting. "
                "You are a PM/helper, not an implementer: if a participant "
                "asks you to build or create a canvas, a task, a plan, or "
                "any other structured artifact, you cannot do this "
                "yourself -- you have no canvas, task, or plan tools, and "
                "none are coming. Do not attempt it, do not pretend to do "
                "it, and do not offer to do it yourself. Instead, name the "
                "specific kind of specialized agent that actually handles "
                "that kind of work out loud -- for example, a design or "
                "canvas agent for a canvas request, a task-management "
                "agent for a task or plan request -- and call "
                "post_to_meeting_chat exactly once asking the room to loop "
                "that agent in to build it. This is the same hand-off tool "
                "and the same one-call rule as above: one call, succeed or "
                "fail, is the complete action.",
            ),
            worker_agent_name=_env_str("MVA_WORKER_AGENT_NAME", "meeting-voice-agent"),
        )
