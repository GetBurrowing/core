defmodule Platform.Agents.HistorianDispatcher do
  @moduledoc """
  Shared dispatch helpers for the Historian agent (ADR-0041 / T6).

  Multiple call sites can trigger a Historian run — `SystemEventScheduler`
  fires on the every-6h staggered cadence and on the 100k-token threshold
  sweep; `MeetingHistorianHandler` fires on `:meeting_ended` PubSub events
  per project. This module owns the dispatch pipeline so each caller only
  has to pick the right `template_slug` + metadata payload — agent lookup,
  runtime reachability check, system space + participant resolution,
  prompt rendering, and the final `AgentResponder.maybe_dispatch/1` call
  all live here once.

  ## Template slugs

  Callers pass a DB-backed prompt template slug:

    * `"historian.scheduled"` — every-6h anchor fire
    * `"historian.meeting_ended"` — `:meeting_ended` PubSub fire
    * `"historian.threshold"` — 100k-token sweep fire

  When the template row is missing (empty DB / first boot before
  `seed_defaults`), `post_instruction/4` falls back to the literal default
  documented in `SystemEventScheduler` so dispatch still succeeds.

  ## Metadata

  Extra metadata (e.g. `%{trigger: "meeting_ended", meeting_id: id,
  project_id: pid, chat_space_id: sid}`) is forwarded into the rendered
  template's variable map AND stamped on both the chat message metadata
  and the AgentResponder signal metadata so downstream tools see it.
  """

  require Logger

  alias Platform.Agents.{ActivityDigest, Agent}
  alias Platform.Chat
  alias Platform.Chat.AgentResponder
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles

  @daily_window_hours 24

  # Literal default used as a fallback for empty DB (when prompt_templates
  # has no `historian.*` row yet). DB-backed templates take precedence via
  # `PromptTemplates.render_template/2`.
  @default_historian_instruction """
  You are the Historian. Below is the activity from the last 24 hours \
  across all non-DM spaces in the organisation.

  {activity_digest}

  Review recent journal entries and short-term memory. Curate durable \
  knowledge into pages under `org/page/`, `project/<id>/page/`, and \
  `space/<id>/page/`. Write transient notes to today's journal at \
  `org/journal/{date}.md`. Be selective: only promote genuinely new \
  insights and preserve existing content that is still relevant.
  """

  @system_participant_sentinel "00000000-0000-0000-0000-000000000001"

  @doc """
  Dispatch the historian event end-to-end.

  Resolves the active historian-flagged agent, ensures the runtime is
  reachable, opens / reuses the agent's `system-<slug>` space, posts a
  synthetic instruction message rendered from the `template_slug`, then
  hands off to `AgentResponder.maybe_dispatch/1`.

  Returns `:ok` when no historian agent is configured (no crash — the
  feature is opt-in via agent config). Returns `{:error, reason}` on any
  resolved failure (runtime offline, space/participant creation failed,
  template render failed catastrophically, etc).
  """
  @spec dispatch(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def dispatch(event_type, template_slug, extra_metadata)
      when is_binary(event_type) and is_binary(template_slug) and is_map(extra_metadata) do
    case agent_for_event(event_type) do
      %Agent{} = agent ->
        Logger.info("[HistorianDispatcher] dispatching #{event_type} to agent=#{agent.slug}")
        dispatch_to_agent(agent, event_type, template_slug, extra_metadata)

      nil ->
        Logger.info("[HistorianDispatcher] no active agent flagged for #{event_type}, skipping")

        :ok
    end
  end

  @doc """
  Look up the single active agent pinned to the Historian role.

  Consults `Platform.Roles.agent_id_for_role("historian")` — the closed
  role roster (M4/ADR-0041) is now the source of truth for who owns the
  Historian responsibility. The `event_type` argument is preserved in the
  signature so `SystemEventScheduler.fire_now/1` and
  `MeetingHistorianHandler` keep compiling, but it is intentionally
  ignored: all three T6 events (`"historian"`, legacy `"daily_summary"`,
  legacy `"dreaming"`) resolve to the same Roles Historian. The
  `SystemEventScheduler` normalises legacy names to `"historian"` before
  we're called, so no legacy-key mapping lives here.

  Returns the `%Agent{}` when a Historian is pinned AND that agent's
  `status == "active"`; returns `nil` otherwise. The one-agent-per-role
  invariant is enforced by the `role_assignments.role_key` unique index,
  so the multi-agent-tiebreak branch of the old query is dead code and
  has been removed.
  """
  @spec agent_for_event(String.t()) :: Agent.t() | nil
  def agent_for_event(event_type) when is_binary(event_type) do
    case Roles.agent_id_for_role("historian") do
      nil ->
        nil

      agent_id when is_binary(agent_id) ->
        case Repo.get(Agent, agent_id) do
          %Agent{status: "active"} = agent ->
            agent

          %Agent{} ->
            # Role is pinned but the agent is paused/archived — treat as
            # "nobody home". Callers already log the skip via `dispatch/3`.
            nil

          nil ->
            # Shouldn't happen — the FK on `role_assignments.agent_id`
            # blocks this — but be defensive so a lost race doesn't crash
            # the every-6h fire.
            Logger.warning(
              "[HistorianDispatcher] historian role pinned to agent_id=#{agent_id} " <>
                "for event=#{event_type} but agent row not found; treating as unassigned"
            )

            nil
        end
    end
  end

  # ── Implementation ────────────────────────────────────────────────────────

  defp dispatch_to_agent(%Agent{} = agent, event_type, template_slug, extra_metadata) do
    with :ok <- ensure_runtime_reachable(agent, event_type),
         {:ok, space} <- ensure_system_space(agent),
         {:ok, system_participant} <- ensure_system_participant(space),
         {:ok, agent_participant} <-
           Chat.add_agent_participant(space.id, agent, display_name: agent.name),
         {:ok, message} <-
           post_instruction(space, system_participant, event_type, template_slug, extra_metadata) do
      signal = %{
        participant_id: agent_participant.id,
        message_id: message.id,
        space_id: space.id,
        reason: :system_event,
        metadata: Map.merge(%{event_type: event_type}, stringify_keys(extra_metadata))
      }

      AgentResponder.maybe_dispatch(signal)
    else
      {:error, reason} ->
        Logger.error(
          "[HistorianDispatcher] failed to dispatch #{event_type} to #{agent.slug}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  # Skip dispatch when the external agent's runtime is known to be offline
  # — avoids posting an instruction that will dead-letter immediately.
  # Built-in agents always pass this check.
  defp ensure_runtime_reachable(
         %Agent{runtime_type: "external", runtime_id: runtime_pk} = agent,
         event_type
       )
       when is_binary(runtime_pk) do
    case Federation.get_runtime(runtime_pk) do
      %{runtime_id: runtime_id} ->
        if RuntimePresence.online?(runtime_id) do
          :ok
        else
          Logger.warning(
            "[HistorianDispatcher] skipping #{event_type}: external runtime " <>
              "#{runtime_id} is offline"
          )

          {:error, :runtime_offline}
        end

      nil ->
        Logger.warning(
          "[HistorianDispatcher] skipping #{event_type}: agent #{agent.slug} " <>
            "runtime row not found (pk=#{runtime_pk})"
        )

        {:error, :runtime_not_found}
    end
  end

  defp ensure_runtime_reachable(%Agent{}, _event_type), do: :ok

  defp ensure_system_space(%Agent{} = agent) do
    slug = "system-#{agent.slug}"

    case Chat.get_space_by_slug(slug) do
      %Chat.Space{} = space ->
        {:ok, space}

      nil ->
        Chat.create_space(%{
          name: "#{agent.name} — System Events",
          slug: slug,
          kind: "system",
          metadata: %{"system_event_space" => true, "agent_id" => agent.id}
        })
    end
  end

  defp ensure_system_participant(space) do
    case Repo.get_by(Chat.Participant,
           space_id: space.id,
           participant_type: "user",
           participant_id: @system_participant_sentinel
         ) do
      %Chat.Participant{} = p ->
        {:ok, p}

      nil ->
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: @system_participant_sentinel,
          display_name: "System",
          joined_at: DateTime.utc_now()
        })
    end
  end

  defp post_instruction(space, system_participant, event_type, template_slug, extra_metadata) do
    date = Date.to_iso8601(Date.utc_today())
    digest = activity_digest()

    template_vars =
      Map.merge(
        %{date: date, activity_digest: digest},
        extra_metadata
      )

    content =
      case PromptTemplates.render_template(template_slug, template_vars) do
        {:ok, rendered} ->
          rendered

        {:error, :not_found} ->
          @default_historian_instruction
          |> String.replace("{date}", date)
          |> String.replace("{activity_digest}", digest)
      end

    Chat.post_message(%{
      space_id: space.id,
      participant_id: system_participant.id,
      content_type: "text",
      content: content,
      metadata:
        Map.merge(
          %{"source" => "system_event", "event_type" => event_type},
          stringify_keys(extra_metadata)
        )
    })
  end

  # Coerce atom/integer/etc metadata values into the shape AgentResponder /
  # downstream consumers expect (string keys); leave atom values alone.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp activity_digest do
    window_end = DateTime.utc_now()
    window_start = DateTime.add(window_end, -@daily_window_hours * 3_600, :second)
    ActivityDigest.build(window_start, window_end)
  end
end
