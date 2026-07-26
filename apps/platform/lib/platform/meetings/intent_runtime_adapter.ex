defmodule Platform.Meetings.IntentRuntimeAdapter do
  @moduledoc """
  The one place a meeting intent meets a runtime (task 019f70b8 stage 4).

  Two things flow from a meeting's intent queue out to a target agent's
  runtime, and both go through here:

    * **dispatch** — "here is an intent, spawn a subagent and ack it"
    * **cancel** — "the producer pulled intent X; stop the subagent you
      told us about"

  Both land on the SAME topic, `runtime:<runtime_id>`, so a runtime that
  is already joined for task dispatch needs no new subscription.

  ## `runtime_id`, not `agent_id`

  The task description called for `runtime:<target_agent_id>`. The
  convention on main is `runtime:<runtime_id>` — the AgentRuntime's
  external, human-readable `runtime_id` STRING, which is what
  `PlatformWeb.RuntimeChannel.join/3` matches and what
  `Platform.Federation.dispatch_triage_attention/2` and
  `dispatch_scribe_attention/2` already broadcast on. Using the agent
  UUID would publish into a topic with no subscribers: a silent,
  green-tests, zero-delivery failure. The plan resolved the drift in
  favour of the real convention and this module implements that.

  ## Resolution is explicit here, swallowed in `Federation`

  `Platform.Federation.dispatch_intent_attention/2` keeps the
  progressive-enhancement contract every sibling dispatcher has: it
  always returns `:ok` and reports failures through
  `[:platform, :meetings, :intent_dispatch, :assignee_unresolvable]`
  telemetry. That is right for a fire-and-forget domain hook and wrong
  for the intent queue, which has to decide between "this row is with a
  runtime" (`:dispatched`, ack window armed) and "this row can never
  reach anyone" (`:dispatch_failed` with `dispatch_failure_reason:
  :no_runtime`, retained and visible to the producer).

  So resolution happens HERE, explicitly, via `resolve_target/1`, and
  the caller branches on the result BEFORE the row is marked
  `:dispatched`. The broadcast itself then goes through
  `Federation.dispatch_intent_attention/2` unchanged. The double lookup
  is deliberate: it costs two `Repo.get/2` calls on a path that already
  does two, and it keeps the federation function a faithful parallel of
  its two siblings instead of a special case that returns errors to one
  caller and `:ok` to the others.

  A broadcast-level failure (endpoint down, PubSub error) is NOT
  `:dispatch_failed`. We could not have known the runtime received it
  even on success — that is precisely what the ack contract exists to
  establish — so a row whose broadcast failed is left to the ack window
  and lands `:timed_out`. Amber, not red, per the stage-1 status
  semantics.

  ## Cancel payload shape

  The plan writes the cancel as
  `{:intent_cancelled, intent_id, subagent_id, reason, corrected_intent,
  corrected_target}`. That tuple notation describes the payload's
  CONTENT, not its wire form: `runtime:<runtime_id>` is a Phoenix
  Channel topic whose subscribers are channel processes serialising to
  a websocket, and a bare Elixir tuple cannot cross that boundary. We
  therefore broadcast the event name `"intent_cancelled"` with a map
  payload carrying exactly those fields — the same shape decision
  `"attention"` already made for dispatch. An in-VM test collector sees
  `%Phoenix.Socket.Broadcast{event: "intent_cancelled", payload: %{...}}`.

  ## One shape for every runtime

  There is deliberately no branching on runtime type. A Claude Code
  runtime returns Task-tool `agentId`s and an openclaw runtime returns
  slugs like `higgins.moon`, but both are just a `subagent_id` string
  as far as this module is concerned. The difference is expressed once,
  in prose, in the `dispatch.intent_attention` prompt template (stage
  5) — not as a branch here that would have to be kept in sync with
  every new runtime product.
  """

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation
  alias Platform.Repo

  @attention_reason "meeting_intent_dispatch"
  @cancel_event "intent_cancelled"

  @type target :: %{
          agent: Agent.t(),
          runtime: AgentRuntime.t(),
          runtime_id: binary(),
          topic: binary()
        }

  @type resolve_error :: :no_target_agent | :agent_not_found | :no_runtime

  # ── Reflection ─────────────────────────────────────────────────────────────

  @doc "The `signal.reason` every intent-dispatch attention carries."
  @spec attention_reason() :: binary()
  def attention_reason, do: @attention_reason

  @doc "The channel event name a cancel is broadcast under."
  @spec cancel_event() :: binary()
  def cancel_event, do: @cancel_event

  @doc """
  The runtime topic for an external `runtime_id` string.

  Note the argument is the AgentRuntime's `runtime_id` field (e.g.
  `"rowan-claude-agent-1"`), NOT its primary key and NOT the agent's id.
  """
  @spec runtime_topic(binary()) :: binary()
  def runtime_topic(runtime_id) when is_binary(runtime_id), do: "runtime:#{runtime_id}"

  # ── Resolution ─────────────────────────────────────────────────────────────

  @doc """
  Resolve a target agent to the runtime that can actually receive an
  intent, returning the topic to publish on.

  Accepts an `%Agent{}` (the dispatcher already holds one after role
  resolution — no reason to re-read it), an agent id, or `nil`.

  Errors are three distinct facts, not one:

    * `:no_target_agent` — the row never named an agent
    * `:agent_not_found` — it named one that no longer exists
    * `:no_runtime` — the agent exists but has no linked AgentRuntime,
      so nothing is listening for it anywhere

  All three are dispatch failures, but they say different things to the
  producer, and the queue keeps whichever one happened.
  """
  @spec resolve_target(Agent.t() | binary() | nil) :: {:ok, target()} | {:error, resolve_error()}
  def resolve_target(nil), do: {:error, :no_target_agent}

  def resolve_target(%Agent{} = agent) do
    case Federation.get_runtime_for_agent(agent) do
      %AgentRuntime{runtime_id: runtime_id} = runtime when is_binary(runtime_id) ->
        {:ok,
         %{
           agent: agent,
           runtime: runtime,
           runtime_id: runtime_id,
           topic: runtime_topic(runtime_id)
         }}

      _ ->
        {:error, :no_runtime}
    end
  end

  def resolve_target(agent_id) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      nil -> {:error, :agent_not_found}
      %Agent{} = agent -> resolve_target(agent)
    end
  end

  # ── Dispatch ───────────────────────────────────────────────────────────────

  @doc """
  The attention envelope for one intent row.

  Read off the row rather than rebuilt from the dispatcher's locals, so
  the payload and the ETS row can never disagree about which agent an
  intent went to. Callers must therefore build this from the row
  AFTER it has been transitioned to `:dispatched` (which is when
  `target_agent_id` is stamped).
  """
  @spec attention_payload(map()) :: map()
  def attention_payload(row) when is_map(row) do
    %{
      reason: @attention_reason,
      intent_id: row.id,
      meeting_id: row.meeting_id,
      room_id: row.room_id,
      transcript_chunk_excerpt: row.chunk_excerpt,
      classified_intent: row.classified_intent,
      target_role: row.target_role,
      target_agent_id: row.target_agent_id,
      confidence: row.confidence
    }
  end

  @doc """
  Send an intent's attention signal to an already-resolved target.

  Always `:ok` — the delivery guarantee is the ack, not the broadcast.
  See the moduledoc for why a broadcast failure is not
  `:dispatch_failed`.
  """
  @spec send_attention(map(), target()) :: :ok
  def send_attention(row, %{agent: %Agent{id: agent_id}}) when is_map(row) do
    Federation.dispatch_intent_attention(agent_id, attention_payload(row))
  end

  # ── Cancel ─────────────────────────────────────────────────────────────────

  @doc """
  The cancel envelope for one intent row.

  `subagent_id` is read off the ROW, which means it is whatever the
  target stamped when it acked — the exact handle it needs to signal
  the right subagent. It is `nil` only when the row was cancelled
  between `:dispatched` and its first ack, in which case the runtime
  had not yet told us a subagent existed.

  `corrected_intent` / `corrected_target_agent_id` are the pencil-edit
  fields (stage 7). They are `nil` for a plain X.
  """
  @spec cancel_payload(map(), term(), binary() | nil, binary() | nil) :: map()
  def cancel_payload(row, reason, corrected_intent \\ nil, corrected_target_agent_id \\ nil)
      when is_map(row) do
    %{
      intent_id: row.id,
      meeting_id: row.meeting_id,
      subagent_id: row.subagent_id,
      reason: reason,
      corrected_intent: corrected_intent,
      corrected_target_agent_id: corrected_target_agent_id,
      status: row.status
    }
  end

  @doc """
  Tell the runtime holding this intent to stop.

  Resolves the row's `target_agent_id` the same way dispatch did and
  broadcasts `"intent_cancelled"` on that runtime's topic. Returns
  `{:error, reason}` when no runtime can be reached, so the caller can
  decide what to do with a row nobody can be asked to cancel — see
  `Platform.Meetings.IntentQueue.cancel/3`.

  Opts:

    * `:reason` — `:wrong_intent | :wrong_target | :not_actionable |
      :other`, forwarded verbatim (stage 6's correction reasons)
    * `:corrected_intent`, `:corrected_target_agent_id` — pencil edit
  """
  @spec cancel(map(), keyword()) :: :ok | {:error, resolve_error() | term()}
  def cancel(row, opts \\ []) when is_map(row) do
    with {:ok, target} <- resolve_target(row.target_agent_id) do
      payload =
        cancel_payload(
          row,
          Keyword.get(opts, :reason),
          Keyword.get(opts, :corrected_intent),
          Keyword.get(opts, :corrected_target_agent_id)
        )

      send_cancel(target, payload)
    end
  end

  @doc """
  Broadcast a prepared cancel payload to a resolved target.

  Unlike `send_attention/2` this DOES surface broadcast errors: a
  cancel that never left the box has no ack contract behind it to
  eventually resolve the row, so the caller has to know.
  """
  @spec send_cancel(target(), map()) :: :ok | {:error, term()}
  def send_cancel(%{topic: topic, runtime_id: runtime_id}, payload) when is_map(payload) do
    case PlatformWeb.Endpoint.broadcast(topic, @cancel_event, payload) do
      :ok ->
        Logger.info(
          "[IntentRuntimeAdapter] cancelled intent=#{payload.intent_id} " <>
            "runtime=#{runtime_id} subagent=#{inspect(payload.subagent_id)}"
        )

        :ok

      {:error, err} ->
        {:error, {:broadcast_failed, err}}
    end
  rescue
    error in ArgumentError ->
      # Endpoint not started (release boot order, or a test that never
      # brought the web app up). Same rescue the federation dispatchers
      # carry, reported rather than swallowed.
      {:error, {:endpoint_not_ready, Exception.message(error)}}
  end
end
