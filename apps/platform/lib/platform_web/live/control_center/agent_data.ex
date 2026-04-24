defmodule PlatformWeb.ControlCenter.AgentData do
  @moduledoc """
  Pure data functions for the Control Center LiveView.

  Handles agent directory listing, runtime snapshots, memory/session queries,
  form builders, config attribute parsing, and agent deletion. No socket or
  assign access — all functions take and return plain data.
  """

  import Ecto.Query
  import Phoenix.Component, only: [to_form: 2]
  import PlatformWeb.ControlCenter.Helpers

  alias Ecto.Multi

  alias Platform.Agents.{
    Agent,
    AgentServer,
    ContextShare,
    Memory,
    MemoryContext,
    Router,
    Session,
    WorkspaceBootstrap,
    WorkspaceFile
  }

  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.{ActiveAgentStore, Participant, Space}
  alias Platform.Federation
  alias Platform.Federation.{NodeContext, RuntimePresence}
  alias Platform.Repo

  @session_limit 8
  @memory_limit 12
  @workspace_defaults [
    "SOUL.md",
    "IDENTITY.md",
    "USER.md",
    "AGENTS.md",
    "MEMORY.md",
    "TOOLS.md",
    "HEARTBEAT.md"
  ]

  # ── Agent directory ───────────────────────────────────────────────

  def list_agents do
    persisted_agents = list_persisted_agents()
    persisted_by_slug = Map.new(persisted_agents, &{&1.slug, &1})

    configured_agents =
      case WorkspaceBootstrap.list_configured_agents() do
        {:ok, agents} -> agents
        {:error, _reason} -> []
      end

    configured_items =
      Enum.map(configured_agents, fn configured_agent ->
        case Map.get(persisted_by_slug, configured_agent.id) do
          %Agent{} = agent ->
            build_agent_directory_entry(agent, :workspace)

          nil ->
            build_configured_agent_directory_entry(configured_agent)
        end
      end)

    configured_slugs = MapSet.new(configured_items, & &1.slug)

    persisted_items =
      persisted_agents
      |> Enum.reject(&MapSet.member?(configured_slugs, &1.slug))
      |> Enum.map(&build_agent_directory_entry(&1, :database))

    (configured_items ++ persisted_items)
    |> Enum.map(&attach_runtime_status/1)
    |> Enum.sort_by(&{&1.name, &1.slug})
  end

  defp list_persisted_agents do
    from(a in Agent, order_by: [asc: a.slug])
    |> Repo.all()
  end

  def build_agent_directory_entry(%Agent{} = agent, source) do
    %{
      slug: agent.slug,
      name: agent.name,
      status: agent.status,
      max_concurrent: agent.max_concurrent || 1,
      primary_model: primary_model_label(agent),
      source: source,
      source_label: source_label(source),
      workspace_managed?: source == :workspace,
      persisted?: true,
      agent: agent,
      runtime_type: agent.runtime_type || "built_in",
      runtime_status: runtime_status(agent),
      running?: runtime_running?(agent),
      system_events: agent.system_events || []
    }
  end

  def build_configured_agent_directory_entry(configured_agent) do
    attrs = normalize_map(configured_agent.attrs || %{})
    model_config = normalize_map(Map.get(attrs, "model_config", %{}))

    %{
      slug: configured_agent.id,
      name: configured_agent.name,
      status: Map.get(attrs, "status", "active"),
      max_concurrent: Map.get(attrs, "max_concurrent", 1),
      primary_model: Map.get(model_config, "primary", "no primary model"),
      source: :workspace,
      source_label: source_label(:workspace),
      workspace_managed?: true,
      persisted?: false,
      agent: nil,
      runtime_type: "built_in",
      runtime_status: :unknown,
      running?: false,
      system_events: []
    }
  end

  defp attach_runtime_status(%{agent: %Agent{runtime_type: "external"} = agent} = entry) do
    runtime = Federation.get_runtime_for_agent(agent)
    online? = runtime != nil && RuntimePresence.online?(runtime.runtime_id)

    entry
    |> Map.put(:runtime_status, if(online?, do: :running, else: :idle))
    |> Map.put(:running?, online?)
  end

  defp attach_runtime_status(%{agent: %Agent{} = agent} = entry) do
    entry
    |> Map.put(:runtime_status, runtime_status(agent))
    |> Map.put(:running?, runtime_running?(agent))
  end

  defp attach_runtime_status(entry), do: entry

  defp source_label(:workspace), do: "mounted workspace"
  defp source_label(:database), do: "control center"

  defp runtime_running?(%Agent{} = agent), do: is_pid(AgentServer.whereis(agent.id))

  defp runtime_status(%Agent{} = agent) do
    case runtime_snapshot(agent) do
      %{status: status} -> status
      _ -> :unknown
    end
  end

  # ── Agent selection ───────────────────────────────────────────────

  def resolve_selected_agent_slug(nil, _agents), do: nil

  def resolve_selected_agent_slug(slug, agents) do
    if Enum.any?(agents, &(&1.slug == slug)),
      do: slug,
      else: nil
  end

  def ensure_selected_agent(slug, agents) when is_binary(slug) do
    case find_agent_directory_entry(agents, slug) do
      %{agent: %Agent{} = agent} ->
        agent

      %{workspace_managed?: true} ->
        case WorkspaceBootstrap.ensure_agent(slug: slug) do
          {:ok, agent} -> agent
          {:error, _reason} -> Repo.get_by(Agent, slug: slug)
        end

      _ ->
        Repo.get_by(Agent, slug: slug)
    end
  end

  def ensure_selected_agent(_slug, _agents), do: nil

  def find_agent_directory_entry(agents, slug) when is_binary(slug) do
    Enum.find(agents, &(&1.slug == slug))
  end

  def find_agent_directory_entry(_agents, _slug), do: nil

  # ── Runtime / counts / queries ────────────────────────────────────

  def runtime_snapshot(%Agent{} = agent) do
    pid = AgentServer.whereis(agent.id)

    case AgentServer.state(agent.id) do
      {:ok, state} ->
        %{
          running?: is_pid(pid),
          pid: pid,
          status: state.status,
          active_session_ids: Map.keys(state.active_sessions),
          workspace_keys: Map.keys(state.workspace || %{})
        }

      {:error, _reason} ->
        %{
          running?: false,
          pid: nil,
          status: if(agent.status in ["paused", "archived"], do: :paused, else: :idle),
          active_session_ids: [],
          workspace_keys: []
        }
    end
  end

  def count_memories(agent_id) do
    from(m in Memory, where: m.agent_id == ^agent_id)
    |> Repo.aggregate(:count, :id)
  end

  def count_sessions(agent_id) do
    from(s in Session, where: s.agent_id == ^agent_id)
    |> Repo.aggregate(:count, :id)
  end

  def list_recent_sessions(agent_id) do
    from(s in Session,
      where: s.agent_id == ^agent_id,
      order_by: [desc: s.started_at, desc: s.id],
      limit: ^@session_limit
    )
    |> Repo.all()
  end

  def list_filtered_memories(agent_id, filters) do
    opts = [limit: @memory_limit]

    opts =
      case filters["type"] do
        "all" -> opts
        type -> Keyword.put(opts, :memory_type, type)
      end

    opts =
      case String.trim(filters["query"] || "") do
        "" -> opts
        query -> Keyword.put(opts, :query, query)
      end

    MemoryContext.list_memories(agent_id, opts)
  end

  def relevant_platform_credentials(%Agent{} = agent) do
    providers = providers_for_agent(agent)

    Platform.Vault.list(scope: {:platform, nil})
    |> Enum.filter(fn credential ->
      providers == [] || is_nil(credential.provider) || credential.provider in providers
    end)
  end

  defp providers_for_agent(%Agent{} = agent) do
    case Router.model_chain(agent) do
      {:ok, chain} -> chain
      _ -> []
    end
    |> Enum.map(&provider_for_model/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp provider_for_model(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      ["openai-codex", _rest] -> "openai"
      [provider, _rest] -> provider
      _ -> nil
    end
  end

  # ── Form builders ─────────────────────────────────────────────────

  def build_config_form(%Agent{} = agent, overrides) do
    model_config = normalize_map(agent.model_config || %{})

    base = %{
      "name" => agent.name,
      "status" => agent.status,
      "primary_model" => Map.get(model_config, "primary", ""),
      "fallback_models" => Enum.join(List.wrap(Map.get(model_config, "fallbacks", [])), ", "),
      "thinking_default" => agent.thinking_default || "",
      "max_concurrent" => agent.max_concurrent || 1,
      "sandbox_mode" => agent.sandbox_mode || "off",
      "color" => agent.color || "",
      "system_events" => agent.system_events || [],
      "historian" => "daily_summary" in (agent.system_events || [])
    }

    to_form(Map.merge(base, normalize_map(overrides)), as: :config)
  end

  @doc """
  Returns true if any *other* agent already holds the Historian role.

  Used to disable the Historian checkbox on the current agent's form when a
  different agent is the Historian. The check is based on presence of the
  `daily_summary` system event (which implies dreaming too per the bundled
  toggle).
  """
  @spec another_historian_exists?(binary() | nil) :: boolean()
  def another_historian_exists?(current_agent_id) do
    query =
      from(a in Agent,
        where: fragment("? @> ?", a.system_events, ^["daily_summary"]),
        select: a.id
      )

    query =
      if current_agent_id do
        from(a in query, where: a.id != ^current_agent_id)
      else
        query
      end

    Repo.exists?(query)
  end

  def build_create_agent_form(overrides) do
    to_form(Map.merge(default_create_agent_params(), normalize_map(overrides)), as: :create_agent)
  end

  def build_workspace_form(
        _workspace_files,
        %WorkspaceFile{} = selected_workspace_file,
        overrides
      ) do
    base = %{
      "file_key" => selected_workspace_file.file_key,
      "content" => selected_workspace_file.content
    }

    to_form(Map.merge(base, normalize_map(overrides)), as: :workspace_file)
  end

  def build_workspace_form(workspace_files, nil, overrides) do
    base = %{
      "file_key" => next_workspace_file_key(workspace_files),
      "content" => ""
    }

    to_form(Map.merge(base, normalize_map(overrides)), as: :workspace_file)
  end

  def build_memory_form(overrides \\ nil) do
    to_form(Map.merge(default_memory_entry(), normalize_map(overrides || %{})), as: :memory_entry)
  end

  # ── Defaults ──────────────────────────────────────────────────────

  def default_memory_filters do
    %{"type" => "all", "query" => ""}
  end

  def default_create_agent_params do
    %{
      "name" => "",
      "slug" => "",
      "primary_model" => "",
      "status" => "active",
      "max_concurrent" => 1,
      "sandbox_mode" => "off",
      "color" => ""
    }
  end

  def default_memory_entry do
    %{
      "memory_type" => "long_term",
      "date" => Date.utc_today() |> Date.to_iso8601(),
      "content" => ""
    }
  end

  # ── Parse / normalize ─────────────────────────────────────────────

  def normalize_memory_filters(params) do
    params = normalize_map(params)

    %{
      "type" => Map.get(params, "type", "all"),
      "query" => Map.get(params, "query", "")
    }
  end

  def select_workspace_file([], _selected_file_key), do: nil

  def select_workspace_file(workspace_files, selected_file_key)
      when is_binary(selected_file_key) do
    Enum.find(workspace_files, &(&1.file_key == selected_file_key)) || List.first(workspace_files)
  end

  def select_workspace_file(workspace_files, _selected_file_key), do: List.first(workspace_files)

  def next_workspace_file_key(workspace_files) do
    used = MapSet.new(workspace_files, & &1.file_key)

    Enum.find(@workspace_defaults, &(not MapSet.member?(used, &1))) || "NOTES.md"
  end

  def config_attrs_from_params(%Agent{} = agent, params) do
    params = normalize_map(params)
    model_config = normalize_map(agent.model_config || %{})

    updated_model_config =
      model_config
      |> Map.put("primary", String.trim(Map.get(params, "primary_model", "")))
      |> Map.put("fallbacks", parse_fallbacks(Map.get(params, "fallback_models", "")))

    %{
      name: String.trim(Map.get(params, "name", agent.name || "")),
      status: Map.get(params, "status", agent.status),
      thinking_default: blank_to_nil(Map.get(params, "thinking_default")),
      max_concurrent:
        parse_positive_integer(Map.get(params, "max_concurrent")) || agent.max_concurrent || 1,
      sandbox_mode: blank_fallback(Map.get(params, "sandbox_mode"), agent.sandbox_mode || "off"),
      color: blank_to_nil(Map.get(params, "color")),
      model_config: updated_model_config,
      system_events: derive_system_events(params, agent)
    }
  end

  # The Historian role bundles both daily_summary + dreaming system events
  # behind a single UI toggle. If the param is missing entirely (e.g. a form
  # that doesn't expose Historian), preserve the agent's current value rather
  # than silently clearing it.
  defp derive_system_events(params, %Agent{} = agent) do
    cond do
      Map.has_key?(params, "historian") ->
        case Map.get(params, "historian") do
          "on" -> ["daily_summary", "dreaming"]
          _ -> []
        end

      Map.has_key?(params, "system_events") ->
        params
        |> Map.get("system_events", [])
        |> List.wrap()
        |> Enum.reject(&(&1 == ""))

      true ->
        agent.system_events || []
    end
  end

  def create_agent_attrs_from_params(params) do
    params = normalize_map(params)
    name = String.trim(Map.get(params, "name", ""))
    slug = params |> Map.get("slug", "") |> to_string() |> slugify()
    primary_model = String.trim(Map.get(params, "primary_model", ""))

    %{
      slug: slug,
      name: name,
      status: blank_fallback(Map.get(params, "status"), "active"),
      max_concurrent: parse_positive_integer(Map.get(params, "max_concurrent")) || 1,
      sandbox_mode: blank_fallback(Map.get(params, "sandbox_mode"), "off"),
      color: blank_to_nil(Map.get(params, "color")),
      model_config:
        if(primary_model == "", do: %{}, else: %{"primary" => primary_model, "fallbacks" => []})
    }
  end

  def parse_fallbacks(raw) when is_binary(raw) do
    raw
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_fallbacks(_raw), do: []

  def parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  def parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  def parse_positive_integer(_value), do: nil

  def parse_memory_date("daily", value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  def parse_memory_date("daily", _value), do: Date.utc_today()
  def parse_memory_date(_memory_type, _value), do: nil

  def normalize_memory_type(nil), do: "long_term"

  def normalize_memory_type(value),
    do: value |> to_string() |> String.trim() |> blank_fallback("long_term")

  # ── Agent deletion ────────────────────────────────────────────────

  def delete_agent(%Agent{} = agent) do
    :ok = AgentServer.stop_agent(agent)

    now = DateTime.utc_now()

    # Collect runtime_ids and participant space_ids before the transaction
    # (needed for in-memory cleanup after commit)
    runtime_ids =
      Repo.all(
        from(r in AgentRuntime,
          where: r.agent_id == ^agent.id,
          select: r.runtime_id
        )
      )

    participant_space_ids =
      Repo.all(
        from(p in Participant,
          where: p.participant_type == "agent" and p.participant_id == ^agent.id,
          select: p.space_id
        )
      )

    # Pre-compute DM space IDs before the transaction — the subquery approach
    # won't work because step 1 hard-deletes participants before step 3 runs.
    dm_space_ids =
      Repo.all(
        from(p in Participant,
          join: s in Space,
          on: s.id == p.space_id,
          where:
            p.participant_type == "agent" and
              p.participant_id == ^agent.id and
              s.kind == "dm" and
              is_nil(s.archived_at),
          select: s.id
        )
      )

    session_ids_query =
      from(s in Session,
        where: s.agent_id == ^agent.id,
        select: s.id
      )

    result =
      Multi.new()
      # 1. Hard-delete all chat_participants for this agent (ADR 0038).
      #    Message/pin/canvas attribution survives via author_* snapshots.
      |> Multi.delete_all(
        :remove_participants,
        from(p in Participant,
          where: p.participant_type == "agent" and p.participant_id == ^agent.id
        )
      )
      # Step 1 already hard-deleted every chat_participants row for this
      # agent. Post-ADR-0038 that row *is* the roster entry, so there's
      # nothing extra to remove. Keep the no-op step for ordering.
      |> Multi.run(:remove_roster_entries, fn _repo, _changes -> {:ok, 0} end)
      # 3. Archive DM spaces where this agent was an active participant
      |> Multi.update_all(
        :archive_dm_spaces,
        from(s in Space, where: s.id in ^dm_space_ids),
        set: [archived_at: now]
      )
      # 4. Clean up context shares (existing)
      |> Multi.delete_all(
        :context_shares,
        from(cs in ContextShare,
          where:
            cs.from_session_id in subquery(session_ids_query) or
              cs.to_session_id in subquery(session_ids_query)
        )
      )
      # 5. Clean up sessions (existing)
      |> Multi.delete_all(:sessions, from(s in Session, where: s.agent_id == ^agent.id))
      # 6. Delete the agent record
      |> Multi.delete(:agent, agent)
      |> Repo.transaction()

    case result do
      {:ok, _changes} ->
        # Post-commit: clean up in-memory runtime/presence state (best-effort)
        cleanup_in_memory_state(agent.id, runtime_ids, participant_space_ids)
        :ok

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Clean up ETS/Agent-backed in-memory state after successful deletion.
  # All operations are idempotent — safe even if the process has already
  # cleaned itself up or the entry doesn't exist.
  defp cleanup_in_memory_state(agent_id, runtime_ids, participant_space_ids) do
    # 1. Clear NodeContext ETS entry for this agent
    NodeContext.clear_space(agent_id)

    # 2. Untrack all associated runtimes from RuntimePresence
    Enum.each(runtime_ids, &RuntimePresence.untrack/1)

    # 3. Clear ActiveAgentStore entries where this agent holds the mutex
    Enum.each(participant_space_ids, fn space_id ->
      ActiveAgentStore.clear_if_match(space_id, agent_id)
    end)
  end
end
