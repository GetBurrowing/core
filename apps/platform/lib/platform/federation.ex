defmodule Platform.Federation do
  @moduledoc """
  Context module for agent federation — runtime registration,
  token management, and runtime ↔ agent linking.
  """

  require Logger
  import Ecto.Query
  alias Ecto.Multi

  alias Platform.Access.RuntimeProfiles
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Federation.AttentionDispatch
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo

  # ── Runtime registration ────────────────────────────────────────────

  @doc "Register a new external runtime."
  def register_runtime(owner_user_id, attrs) do
    modules = Map.get(attrs, :allowed_bundles, Map.get(attrs, "allowed_bundles"))
    tool_profile = modules || AgentRuntime.default_allowed_bundles()
    restriction =
      if is_nil(modules), do: nil, else: RuntimeProfiles.translated_permissions(modules)

    Multi.new()
    |> Multi.insert(
      :runtime,
      AgentRuntime.changeset(%AgentRuntime{}, Map.put(attrs, :owner_user_id, owner_user_id))
    )
    |> Multi.run(:profile, fn _repo, %{runtime: runtime} ->
      RuntimeProfiles.create_for_runtime(runtime, tool_profile, restriction)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{runtime: runtime}} -> {:ok, runtime}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc "Fetch a runtime by its primary key."
  def get_runtime(id), do: Repo.get(AgentRuntime, id)

  @doc "Fetch a runtime by its human-readable runtime_id."
  def get_runtime_by_runtime_id(runtime_id) do
    Repo.get_by(AgentRuntime, runtime_id: runtime_id)
  end

  @doc "Fetch a runtime by verifying a raw auth token."
  def get_runtime_by_token(raw_token) when is_binary(raw_token) do
    hash = AgentRuntime.hash_token(raw_token)

    Repo.one(
      from(r in AgentRuntime,
        where: r.auth_token_hash == ^hash and r.status == "active"
      )
    )
  end

  @doc "List all runtimes owned by a user."
  def list_runtimes(owner_user_id) do
    Repo.all(from(r in AgentRuntime, where: r.owner_user_id == ^owner_user_id))
  end

  @doc "Activate a runtime and generate an auth token."
  def activate_runtime(%AgentRuntime{} = runtime) do
    {raw_token, hash} = generate_token_pair()

    case runtime
         |> AgentRuntime.changeset(%{status: "active", auth_token_hash: hash})
         |> Repo.update() do
      {:ok, updated} -> {:ok, updated, raw_token}
      error -> error
    end
  end

  @doc "Suspend a runtime."
  def suspend_runtime(%AgentRuntime{} = runtime) do
    runtime
    |> AgentRuntime.changeset(%{status: "suspended"})
    |> Repo.update()
  end

  @doc "Revoke a runtime (permanent)."
  def revoke_runtime(%AgentRuntime{} = runtime) do
    runtime
    |> AgentRuntime.changeset(%{status: "revoked", auth_token_hash: nil})
    |> Repo.update()
  end

  @doc """
  Shallow-merge new top-level keys into a runtime's `metadata` map and
  persist the result via the regular changeset path.

  Existing top-level keys not present in `new_keys` are preserved. The
  merge is intentionally shallow at the top level: setting
  `"client_info"` REPLACES the nested map under that key — the caller is
  responsible for assembling the full nested structure they want stored.

  Writes through `AgentRuntime.changeset/2` so validations and
  `updated_at` stay consistent with the rest of the runtime mutations.
  """
  @spec update_metadata(AgentRuntime.t(), map()) ::
          {:ok, AgentRuntime.t()} | {:error, Ecto.Changeset.t()}
  def update_metadata(%AgentRuntime{} = runtime, new_keys) when is_map(new_keys) do
    merged = Map.merge(runtime.metadata || %{}, new_keys)

    runtime
    |> AgentRuntime.changeset(%{metadata: merged})
    |> Repo.update()
  end

  @doc """
  Replace a runtime's `allowed_bundles` set.

  Bundles are validated against `AgentRuntime.valid_bundles/0` via the
  changeset's `validate_subset`. Pass an empty list to deny all bundles
  (the runtime will still authenticate but `tools/list` returns nothing).
  """
  @spec update_allowed_bundles(AgentRuntime.t(), [String.t()]) ::
          {:ok, AgentRuntime.t()} | {:error, Ecto.Changeset.t()}
  def update_allowed_bundles(%AgentRuntime{} = runtime, bundles) when is_list(bundles) do
    Multi.new()
    |> Multi.update(:runtime, AgentRuntime.changeset(runtime, %{allowed_bundles: bundles}))
    |> Multi.run(:profile, fn _repo, %{runtime: updated} ->
      with {:ok, _} <- RuntimeProfiles.set_tool_profile(updated, bundles),
           {:ok, profile} <-
             RuntimeProfiles.restrict(updated, RuntimeProfiles.translated_permissions(bundles)) do
        {:ok, profile}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{runtime: updated}} -> {:ok, updated}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Register and activate a second runtime row for an agent that will carry
  its voice — the "mouth" — without touching the row that carries its brain.

  ## Why a separate row (task 01a06686)

  An agent's brain (the OpenClaw / claude_channel bridge that answers
  dispatches) and its voice worker (the LiveKit participant that joins a
  meeting) are different processes with different lifecycles, and they
  declare different `client_info.features`. Both used to share ONE
  `agent_runtimes` row, so whichever connected last overwrote the other's
  declaration, and `Meetings.join_capability/1` flipped to `:incapable` the
  moment the brain reconnected after the voice worker. Giving the voice
  worker its own row means each process declares only what it is, and the
  capability question is answered over the set (`runtimes_for_agent/1`).

  ## What this does and does not write

  - Inserts an `AgentRuntime` via `register_runtime/2` with
    `agent_id: agent.id`, `display_name: "<agent name> voice"` and
    `metadata["role"] == "voice"`, then activates it so the returned raw
    token authenticates `PlatformWeb.RuntimeSocket` immediately.
  - Does NOT call `link_agent/2` and does NOT write `agent.runtime_id`.
    `agent.runtime_id` is the brain pointer that every dispatch path reads
    through `get_runtime_for_agent/1`; rebinding it to the voice row would
    route the agent's work to a process that cannot do it.

  `attrs` may override `runtime_id`, `display_name`, and add metadata keys;
  `"role" => "voice"` always wins so the row is recognisable as a mouth.
  Returns `{:ok, runtime, raw_token}` (the shape of `activate_runtime/1`)
  or `{:error, changeset}`.
  """
  @spec register_voice_runtime(binary(), Agent.t(), map()) ::
          {:ok, AgentRuntime.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def register_voice_runtime(owner_user_id, %Agent{} = agent, attrs \\ %{}) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    metadata =
      attrs
      |> Map.get("metadata", %{})
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("role", "voice")

    runtime_attrs = %{
      runtime_id: Map.get(attrs, "runtime_id") || "#{agent.slug}-voice-#{short_suffix()}",
      display_name: Map.get(attrs, "display_name") || "#{agent.name} voice",
      agent_id: agent.id,
      transport: "websocket",
      status: "pending",
      metadata: metadata
    }

    with {:ok, runtime} <- register_runtime(owner_user_id, runtime_attrs) do
      activate_runtime(runtime)
    end
  end

  defp short_suffix do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  @doc "Generate a new auth token for a runtime, replacing any existing one."
  def generate_runtime_token(%AgentRuntime{} = runtime) do
    {raw_token, hash} = generate_token_pair()

    case runtime
         |> AgentRuntime.changeset(%{auth_token_hash: hash})
         |> Repo.update() do
      {:ok, updated} -> {:ok, updated, raw_token}
      error -> error
    end
  end

  # ── Declared client features ────────────────────────────────────────

  @doc """
  The feature list a runtime DECLARED at join, or `:undeclared`.

  Reads `metadata["client_info"]["features"]`, the shape
  `PlatformWeb.RuntimeChannel` persists from the join payload. A
  `client_info` that exists but carries no `features` key is `:undeclared`
  rather than `[]`: only a list that is actually present is evidence about
  what the client can do. One reader for every "does this runtime advertise
  feature X" question (task 01a0db5f; `Platform.Meetings` voice capability
  and the play module's host discovery both call it), so the two cannot
  drift into reading different keys.
  """
  @spec declared_features(map() | nil) :: [String.t()] | :undeclared
  def declared_features(metadata) when is_map(metadata) do
    with %{} = client_info <- Map.get(metadata, "client_info"),
         features when is_list(features) <- Map.get(client_info, "features") do
      features
    else
      _ -> :undeclared
    end
  end

  def declared_features(_), do: :undeclared

  @doc """
  Active runtimes that are CONNECTED right now and declare `feature`.

  Presence is `RuntimePresence.list_online/0`, keyed by the human-readable
  `runtime_id`; the declaration is `declared_features/1`. Sorted by
  `runtime_id` so a caller that takes the first one is deterministic.
  """
  @spec present_runtimes_with_feature(String.t()) :: [AgentRuntime.t()]
  def present_runtimes_with_feature(feature) when is_binary(feature) do
    case RuntimePresence.list_online() do
      [] ->
        []

      online ->
        from(r in AgentRuntime,
          where: r.runtime_id in ^online and r.status == "active",
          order_by: [asc: r.runtime_id]
        )
        |> Repo.all()
        |> Enum.filter(fn %AgentRuntime{metadata: metadata} ->
          case declared_features(metadata) do
            features when is_list(features) -> feature in features
            :undeclared -> false
          end
        end)
    end
  end

  # ── Runtime ↔ Agent linking ─────────────────────────────────────────

  @doc "Link an agent to a runtime, setting it as external."
  def link_agent(%AgentRuntime{} = runtime, %Agent{} = agent) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :agent,
      Agent.changeset(agent, %{runtime_type: "external", runtime_id: runtime.id})
    )
    |> Ecto.Multi.update(
      :runtime,
      AgentRuntime.changeset(runtime, %{agent_id: agent.id})
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{agent: agent}} ->
        auto_roster_federated_agent(agent)
        {:ok, agent}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  def link_agent(%AgentRuntime{} = runtime, agent_attrs) when is_map(agent_attrs) do
    attrs =
      agent_attrs
      |> Map.put(:runtime_type, "external")
      |> Map.put(:runtime_id, runtime.id)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:agent, Agent.changeset(%Agent{}, attrs))
    |> Ecto.Multi.run(:runtime, fn _repo, %{agent: agent} ->
      runtime
      |> AgentRuntime.changeset(%{agent_id: agent.id})
      |> Repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{agent: agent}} ->
        auto_roster_federated_agent(agent)
        {:ok, agent}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Add a federated agent to the roster of every non-archived channel space
  in its workspace.

  Runs best-effort: idempotent via `Chat.ensure_space_agent/3` (no-op when
  the agent is already on a space's roster), logs-but-ignores per-space
  errors so a single misbehaving space never blocks agent creation. The
  roster add emits `{:roster_changed, space_id}` pubsub so any open shell
  LiveView refreshes automatically.

  Rationale: until a federated agent is in a space's roster, it is not
  @-mentionable from that space, which makes newly-provisioned agents
  effectively invisible until an operator manually adds them. Auto-adding
  to every channel in the workspace mirrors the UX of a human user being
  added to an org — they can see every room by default; operators remove
  from specific spaces later if needed. (See ADR 0019 for the roster
  model.)
  """
  @spec auto_roster_federated_agent(Agent.t()) :: :ok
  def auto_roster_federated_agent(%Agent{id: agent_id, workspace_id: workspace_id} = agent) do
    # `workspace_id` may be nil in single-tenant / default-org setups; in that
    # case we roster against the channel spaces that also have a nil
    # workspace_id. `Chat.list_spaces/1` handles the nil semantics with
    # `is_nil/1` internally.
    spaces = Chat.list_spaces(workspace_id: workspace_id, kind: "channel")

    Enum.each(spaces, fn %Space{id: space_id} ->
      case Chat.ensure_space_agent(space_id, agent_id, role: "member") do
        {:ok, _space_agent} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Federation] auto-roster failed for agent=#{agent.slug} space=#{space_id} reason=#{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  @doc "Ensure the runtime's linked agent has a participant in the given space."
  def ensure_runtime_agent_participant(%AgentRuntime{agent_id: agent_id} = _runtime, space_id)
      when is_binary(agent_id) do
    Chat.add_agent_participant(space_id, agent_id)
  end

  def ensure_runtime_agent_participant(_runtime, _space_id) do
    {:error, :no_linked_agent}
  end

  # ── Query helpers ───────────────────────────────────────────────────

  @doc "Fetch the runtime linked to an agent (by the agent's runtime_id FK)."
  def get_runtime_for_agent(%Agent{runtime_id: nil}), do: nil
  def get_runtime_for_agent(%Agent{runtime_id: rid}), do: get_runtime(rid)

  @doc """
  Every runtime row bound to an agent — the brain row (`agent.runtime_id`)
  first, then the rest (voice rows registered by `register_voice_runtime/3`)
  in insertion order.

  `agent_runtimes.agent_id` is a non-unique index, so an agent may own
  several rows; `get_runtime_for_agent/1` only ever sees the one
  `agent.runtime_id` points at. Use this when the question is about what
  the agent as a whole can do (`Meetings.join_capability/1`), and
  `get_runtime_for_agent/1` when the question is where to send its work.

  Returns `[]` for an agent with nothing linked.
  """
  @spec runtimes_for_agent(Agent.t()) :: [AgentRuntime.t()]
  def runtimes_for_agent(%Agent{id: agent_id, runtime_id: brain_id}) do
    rows =
      Repo.all(
        from(r in AgentRuntime,
          where: r.agent_id == ^agent_id,
          order_by: [asc: r.inserted_at, asc: r.id]
        )
      )

    {brain, rest} = Enum.split_with(rows, &(&1.id == brain_id))
    brain ++ rest
  end

  @doc """
  The agent's non-brain runtime rows — `runtimes_for_agent/1` minus the row
  `agent.runtime_id` points at. `[]` when the agent has only a brain, or
  nothing at all.
  """
  @spec voice_runtimes_for_agent(Agent.t()) :: [AgentRuntime.t()]
  def voice_runtimes_for_agent(%Agent{runtime_id: brain_id} = agent) do
    agent
    |> runtimes_for_agent()
    |> Enum.reject(&(&1.id == brain_id))
  end

  @doc """
  Lookup `{agent, runtime}` for an external runtime_id string.

  Returns `{nil, nil}` if no runtime exists, `{nil, %AgentRuntime{}}` if the
  runtime exists but isn't linked to an agent, or `{%Agent{}, %AgentRuntime{}}`
  for fully-linked entries. Used by orchestration to resolve a dispatch
  assignee map (`%{type: :federated, id: "rowan-claude-agent-1"}`) into the
  agent + runtime structs needed for provider-aware behavior.
  """
  @spec lookup_assignment(String.t() | nil) :: {Agent.t() | nil, AgentRuntime.t() | nil}
  def lookup_assignment(runtime_id) when is_binary(runtime_id) do
    case get_runtime_by_runtime_id(runtime_id) do
      nil -> {nil, nil}
      %AgentRuntime{agent_id: nil} = runtime -> {nil, runtime}
      %AgentRuntime{agent_id: agent_id} = runtime -> {Repo.get(Agent, agent_id), runtime}
    end
  end

  def lookup_assignment(_), do: {nil, nil}

  @doc """
  Dispatch a meeting-scribe attention signal to the given agent's linked runtime.

  This is the meeting-completion counterpart of
  `Platform.Orchestration.TaskRouter.dispatch_attention/5` — it broadcasts an
  `"attention"` event to `runtime:<runtime_id>` with a `%{signal: payload}`
  envelope so the receiving agent can pattern-match `signal.reason` the same
  way it does for `"task_assigned"` / `"task_heartbeat"`.

  Progressive-enhancement contract: this function always returns `:ok`. Every
  failure path (agent not found, runtime not linked, broadcast error, endpoint
  not ready) is swallowed and reported through
  `[:platform, :meetings, :scribe_dispatch, :assignee_unresolvable]` telemetry
  so the transcript-completion caller can invoke it inline without risking the
  existing Summarizer path.

  The broadcast goes through `Platform.Federation.AttentionDispatch`, which
  first puts the target agent in a writable posture in `payload.space_id` —
  see that module on why the invite must commit before the signal leaves, and
  why a refused invite never blocks delivery.
  """
  @spec dispatch_scribe_attention(binary(), map()) :: :ok
  def dispatch_scribe_attention(agent_id, payload)
      when is_binary(agent_id) and is_map(payload) do
    case Repo.get(Agent, agent_id) do
      nil ->
        emit_scribe_dispatch_fallback(agent_id, :agent_not_found)
        :ok

      %Agent{} = agent ->
        case get_runtime_for_agent(agent) do
          nil ->
            emit_scribe_dispatch_fallback(agent_id, :runtime_unresolvable)
            :ok

          %AgentRuntime{runtime_id: runtime_id} ->
            broadcast_scribe_attention(agent_id, runtime_id, payload)
        end
    end
  end

  # Broadcast through the funnel, which invites the agent into
  # `payload.space_id` first. `Meetings.maybe_dispatch_scribe_attention/1`
  # already puts `transcript.space_id` there, and it is nullable — a nil space
  # is a clean `:no_space_named` skip inside the funnel, with the signal still
  # delivered.
  #
  # The `:broadcast_failed` / `:endpoint_not_ready` split and the always-`:ok`
  # return are unchanged; only the primitive underneath moved. This function
  # keeps its own telemetry name and log line rather than sharing the funnel's
  # so a scribe dispatch failure stays greppable on its own — see the moduledoc
  # on `dispatch_triage_attention/2` for why the three are parallel by design.
  defp broadcast_scribe_attention(agent_id, runtime_id, payload) do
    topic = AttentionDispatch.topic(runtime_id)

    case AttentionDispatch.broadcast(runtime_id, %{signal: payload},
           space_id: Map.get(payload, :space_id),
           agent_id: agent_id,
           source: :meeting_scribe
         ) do
      :ok ->
        Logger.info(
          "[Federation] dispatched meeting_scribe_completion to #{topic} for agent #{agent_id}"
        )

        :ok

      {:error, reason} ->
        emit_scribe_dispatch_fallback(agent_id, reason)
        :ok
    end
  end

  defp emit_scribe_dispatch_fallback(agent_id, reason) do
    metadata = %{
      agent_id: agent_id,
      reason: reason,
      actor_type: "system",
      resource_type: "agent",
      resource_id: agent_id
    }

    :telemetry.execute(
      [:platform, :meetings, :scribe_dispatch, :assignee_unresolvable],
      %{count: 1},
      metadata
    )
  end

  @doc """
  Dispatch a meeting-triage attention signal to the given agent's linked runtime.

  Verbatim mirror of `dispatch_scribe_attention/2` — kept as a parallel function
  rather than a shared helper so the telemetry event name and log string stay
  greppable at the callsite. This is called from
  `Platform.Meetings.on_scribe_canvas_created/2` after the scribe emits a
  completion canvas, so the triage_officer agent can pick up the canvas and
  convert action items into tasks.

  Progressive-enhancement contract: this function always returns `:ok`. Every
  failure path (agent not found, runtime not linked, broadcast error, endpoint
  not ready) is swallowed and reported through
  `[:platform, :meetings, :triage_dispatch, :assignee_unresolvable]` telemetry
  so the domain-hook caller can invoke it inline without risking the
  canvas-create path.

  Broadcasts through `Platform.Federation.AttentionDispatch`, same as its two
  siblings, tagged `source: :meeting_triage` so an auto-invite into a meeting
  space is attributable to the triage dispatch rather than the scribe one.
  """
  @spec dispatch_triage_attention(binary(), map()) :: :ok
  def dispatch_triage_attention(agent_id, payload)
      when is_binary(agent_id) and is_map(payload) do
    case Repo.get(Agent, agent_id) do
      nil ->
        emit_triage_dispatch_fallback(agent_id, :agent_not_found)
        :ok

      %Agent{} = agent ->
        case get_runtime_for_agent(agent) do
          nil ->
            emit_triage_dispatch_fallback(agent_id, :runtime_unresolvable)
            :ok

          %AgentRuntime{runtime_id: runtime_id} ->
            broadcast_triage_attention(agent_id, runtime_id, payload)
        end
    end
  end

  # Same funnel, same ordering guarantee, different `:source` — which is the
  # whole reason `:source` exists: scribe and triage dispatch into the SAME
  # meeting space, so `[:platform, :chat, :dispatch_auto_invite]` would be
  # unattributable without it.
  defp broadcast_triage_attention(agent_id, runtime_id, payload) do
    topic = AttentionDispatch.topic(runtime_id)

    case AttentionDispatch.broadcast(runtime_id, %{signal: payload},
           space_id: Map.get(payload, :space_id),
           agent_id: agent_id,
           source: :meeting_triage
         ) do
      :ok ->
        Logger.info(
          "[Federation] dispatched meeting_triage_dispatch to #{topic} for agent #{agent_id}"
        )

        :ok

      {:error, reason} ->
        emit_triage_dispatch_fallback(agent_id, reason)
        :ok
    end
  end

  defp emit_triage_dispatch_fallback(agent_id, reason) do
    metadata = %{
      agent_id: agent_id,
      reason: reason,
      actor_type: "system",
      resource_type: "agent",
      resource_id: agent_id
    }

    :telemetry.execute(
      [:platform, :meetings, :triage_dispatch, :assignee_unresolvable],
      %{count: 1},
      metadata
    )
  end

  @doc """
  Dispatch a meeting-intent attention signal to the given agent's linked runtime.

  The third parallel of `dispatch_scribe_attention/2` and
  `dispatch_triage_attention/2` — same `Repo.get(Agent, agent_id) ->
  get_runtime_for_agent/1 -> broadcast on `runtime:<runtime_id>`` chain,
  same always-`:ok` contract, its own telemetry event name so a
  meeting-producer dispatch failure is greppable on its own. Called from
  `Platform.Meetings.IntentRuntimeAdapter.send_attention/2` once a
  classified intent has been claimed by the per-meeting queue's serial
  cursor and marked `:dispatched`.

  Note the topic is keyed by the AgentRuntime's external `runtime_id`
  STRING, not by `agent_id` — that is the topic
  `PlatformWeb.RuntimeChannel.join/3` matches, and the one every live
  runtime is already subscribed to.

  Progressive-enhancement contract: this function always returns `:ok`.
  Every failure path (agent not found, runtime not linked, broadcast
  error, endpoint not ready) is swallowed and reported through
  `[:platform, :meetings, :intent_dispatch, :assignee_unresolvable]`
  telemetry.

  That is why the caller resolves the runtime FIRST, through
  `IntentRuntimeAdapter.resolve_target/1`: the intent queue must
  distinguish "handed to a runtime" from "there is no runtime to hand it
  to" in order to choose between `:dispatched` and
  `:dispatch_failed{:no_runtime}`, and this function deliberately cannot
  tell it. A failure observed HERE — after resolution succeeded — is a
  race or a dead endpoint, and the row's ack window resolves it as
  `:timed_out` rather than as a red failure we cannot prove.

  Broadcasts through `Platform.Federation.AttentionDispatch`, naming the space
  the envelope carries as `target_space_id` — the meeting's own chat space,
  resolved by `Platform.Meetings.IntentDispatcher`. The target agent is
  therefore a participant of that space before this signal leaves.

  The key is read as `:target_space_id`, NOT `:space_id`, and the two siblings
  above are not inconsistent with that: their payloads legitimately carry a
  top-level `space_id` because nothing pins a client-side permission prompt to
  a scribe or triage envelope. See
  `Platform.Meetings.IntentRuntimeAdapter.attention_payload/2` for why the
  intent envelope must name a space without claiming that slot. An envelope
  with no `target_space_id` (meeting row gone) resolves to `:no_space_named`
  and is still delivered.
  """
  @spec dispatch_intent_attention(binary(), map()) :: :ok
  def dispatch_intent_attention(agent_id, payload)
      when is_binary(agent_id) and is_map(payload) do
    case Repo.get(Agent, agent_id) do
      nil ->
        emit_intent_dispatch_fallback(agent_id, :agent_not_found)
        :ok

      %Agent{} = agent ->
        case get_runtime_for_agent(agent) do
          nil ->
            emit_intent_dispatch_fallback(agent_id, :runtime_unresolvable)
            :ok

          %AgentRuntime{runtime_id: runtime_id} ->
            broadcast_intent_attention(agent_id, runtime_id, payload)
        end
    end
  end

  # `:target_space_id`, not `:space_id`. The meeting-intent envelope built by
  # `Meetings.IntentRuntimeAdapter.attention_payload/2` deliberately keeps the
  # top-level `signal.space_id` slot free, because a live client pins a pending
  # permission prompt's answer space to it. Reading the key the envelope
  # actually uses is what lets the funnel invite into a space the wire payload
  # does not claim. Do not "unify" this with the two siblings above by renaming
  # either half — the adapter's docs explain the whole constraint.
  defp broadcast_intent_attention(agent_id, runtime_id, payload) do
    topic = AttentionDispatch.topic(runtime_id)

    case AttentionDispatch.broadcast(runtime_id, %{signal: payload},
           space_id: Map.get(payload, :target_space_id),
           agent_id: agent_id,
           source: :meeting_intent
         ) do
      :ok ->
        Logger.info(
          "[Federation] dispatched meeting_intent_dispatch to #{topic} for agent #{agent_id}"
        )

        :ok

      {:error, reason} ->
        emit_intent_dispatch_fallback(agent_id, reason)
        :ok
    end
  end

  defp emit_intent_dispatch_fallback(agent_id, reason) do
    metadata = %{
      agent_id: agent_id,
      reason: reason,
      actor_type: "system",
      resource_type: "agent",
      resource_id: agent_id
    }

    :telemetry.execute(
      [:platform, :meetings, :intent_dispatch, :assignee_unresolvable],
      %{count: 1},
      metadata
    )
  end

  @doc "List spaces an agent participates in, with the participant's attention_mode."
  def agent_spaces(%Agent{id: agent_id}) do
    from(p in Participant,
      join: s in Space,
      on: s.id == p.space_id,
      where: p.participant_type == "agent" and p.participant_id == ^agent_id,
      select: %{
        space_id: s.id,
        space_name: s.name,
        space_slug: s.slug,
        attention_mode: p.attention_mode
      },
      order_by: [asc: s.name]
    )
    |> Repo.all()
  end

  # ── Observability ───────────────────────────────────────────────────

  @doc """
  Returns the federation health status for all active runtimes.

  Combines DB records with live presence data. Each row carries three groups
  of facts that are reported SEPARATELY because they routinely disagree:

    * connection — `online`, `connected_at`, `last_seen_at`,
      `last_connected_at`. Whether a socket is up.
    * build — `client_build`, `client_build_status`, `client_build_error`,
      `process_started_at`. Which code the process is running, AS THE CLIENT
      REPORTS IT. Read from the DB row, so an OFFLINE runtime still reports
      the build it declared on its last handshake. `client_build` is nil
      unless `client_build_status` is `"reported"`; the status says why it is
      absent (`"unresolved"` / `"not_reported"` / `"no_client_info"`, see
      `AgentRuntime.client_build_status/1`) so absence is never one
      undifferentiated blank.
    * proven — `%{capability => DateTime}` of what core actually OBSERVED
      arrive from this runtime, `%{}` when offline or nothing was observed.

  `declared_features` comes last and is what the runtime CLAIMED. It is
  included for provenance, not because it answers anything: measured across
  the capability boundary that motivated this, the plugin builds either side
  of `63229eb` send an identical feature list.

  The three groups are never collapsed into one another. A runtime can be
  connected for twenty seconds, running six-day-old code, and have never
  proven the one capability someone needs — that sentence is the deliverable.
  """
  def federation_status do
    runtimes = Repo.all(from(r in AgentRuntime, where: r.status == "active"))
    presence = RuntimePresence.list_all()

    # Build agent lookup — AgentRuntime has agent_id as a raw field, no association
    agent_ids = runtimes |> Enum.map(& &1.agent_id) |> Enum.reject(&is_nil/1)

    agents =
      if agent_ids != [] do
        from(a in Platform.Agents.Agent, where: a.id in ^agent_ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
      else
        %{}
      end

    Enum.map(runtimes, fn runtime ->
      online_info = Map.get(presence, runtime.runtime_id)
      agent = Map.get(agents, runtime.agent_id)

      %{
        runtime_id: runtime.runtime_id,
        agent_name: agent && agent.name,
        agent_slug: agent && agent.slug,
        agent_id: runtime.agent_id,
        status: runtime.status,

        # Connection facts. `online` is the socket and ONLY the socket: it goes
        # true the instant a process completes a handshake, whatever code that
        # process is running. Build age and proof state are deliberately NOT
        # folded in — a green dot that already accounted for staleness would
        # hide the disagreement between these three groups, and that
        # disagreement is what this surface exists to show.
        online: online_info != nil,
        connected_at: online_info && online_info.connected_at,
        last_seen_at: online_info && online_info.last_seen_at,
        last_connected_at: runtime.last_connected_at,

        # Build facts, read off the DB row and therefore independent of
        # liveness: an offline runtime still reports the build it declared on
        # its last handshake. Both are nil when the client has not told us —
        # never a fabricated sha, never a `utc_now/0` stand-in.
        client_build: AgentRuntime.client_build(runtime),
        client_build_status: AgentRuntime.client_build_status(runtime),
        client_build_error: AgentRuntime.client_build_error(runtime),
        process_started_at: AgentRuntime.client_started_at(runtime),

        # What core OBSERVED: %{capability => DateTime}. `%{}` when the runtime
        # is offline (presence holds no entry) or when nothing has been proven
        # this session. Rendering an absent capability is the caller's job.
        proven: (online_info && Map.get(online_info, :proven, %{})) || %{},

        # What the runtime CLAIMED. Last on purpose, and below the two groups
        # above: everything before this was measured by core, this was asserted
        # by the process whose competence is in question. It also cannot
        # discriminate the boundary this ticket was filed from — the plugin
        # builds either side of `63229eb` declare an identical feature list.
        declared_features: AgentRuntime.client_features(runtime)
      }
    end)
  end

  @doc """
  Broadcast a ping event to a runtime channel.

  The runtime client is expected to respond with a "pong" event,
  which will update the last_seen_at via RuntimePresence.touch/1.
  """
  def ping_runtime(runtime_id) do
    topic = "runtime:#{runtime_id}"
    PlatformWeb.Endpoint.broadcast(topic, "ping", %{timestamp: DateTime.utc_now()})
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp generate_token_pair do
    raw = AgentRuntime.generate_token()
    hash = AgentRuntime.hash_token(raw)
    {raw, hash}
  end
end
