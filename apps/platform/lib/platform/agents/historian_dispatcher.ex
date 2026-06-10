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

  import Ecto.Query

  alias Platform.Agents.{ActivityDigest, Agent}
  alias Platform.Chat
  alias Platform.Chat.AgentResponder
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

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
  Look up the single active agent flagged for the given system event.

  Returns the agent or `nil` (no eligible agent). When multiple agents
  claim the same event a warning is logged and the oldest is picked —
  the UI's one-agent-per-event invariant should keep this from happening
  in practice.
  """
  @spec agent_for_event(String.t()) :: Agent.t() | nil
  def agent_for_event(event_type) when is_binary(event_type) do
    # The post-T6 whitelist is just ["historian"], but we still resolve by
    # event_type so legacy callers passing "daily_summary" / "dreaming"
    # land on whichever agent is flagged for the matching event (after
    # the SystemEventScheduler maps legacy → "historian", this is just
    # "historian" in practice).
    agents =
      from(a in Agent,
        where: a.status == "active",
        where: fragment("? @> ?", a.system_events, ^[event_type]),
        order_by: [asc: a.inserted_at],
        limit: 2
      )
      |> Repo.all()

    case agents do
      [] ->
        nil

      [agent] ->
        agent

      [agent | _rest] = multiple ->
        Logger.warning(
          "[HistorianDispatcher] multiple agents flagged for #{event_type}: " <>
            "#{inspect(Enum.map(multiple, & &1.slug))} — using #{agent.slug}"
        )

        agent
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
