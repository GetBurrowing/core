defmodule Platform.Agents.Orchestration do
  @moduledoc """
  Coordinates parent/child agent orchestration for the Agent Runtime.

  The orchestration layer sits on top of the lower-level runtime primitives:

    * `Platform.Agents.AgentServer` owns supervised agent/session lifecycle
    * `Platform.Agents.ContextBroker` handles auditable context transfer
    * `Platform.Agents.MemoryContext` persists child workspace/memory seeds

  T10 focuses on the backend coordination API needed for multi-agent flows:

    * create or reuse child agent definitions inside the parent's workspace
    * start the child runtime + linked child session
    * share filtered parent context into the child session
    * optionally promote a child delta back into the parent on completion
    * emit telemetry for child spawn/completion events
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.{
    Agent,
    AgentServer,
    Config,
    Context,
    ContextBroker,
    ContextDelta,
    ContextScope,
    ContextShare,
    Memory,
    MemoryContext,
    Session
  }

  alias Platform.Repo

  @type spawn_result :: %{
          agent: Agent.t(),
          pid: pid(),
          session: Session.t(),
          context: Context.t(),
          share_record: ContextShare.t(),
          created?: boolean()
        }

  @type completion_result :: %{
          session: Session.t(),
          snapshot_memory: Memory.t() | nil,
          promoted_context: Context.t() | nil,
          promoted_memories: [Memory.t()],
          promotion_share: ContextShare.t() | nil,
          stopped?: boolean()
        }

  @doc """
  Spawn a child agent beneath an active parent session.

  `child_input` may be:

    * an existing `%Platform.Agents.Agent{}` or agent id/slug to reuse
    * a map/keyword with direct `Agent` attrs (`slug`, `name`, `model_config`, ...)
    * a map containing `:config` / `"config"` with an OpenClaw agent definition,
      which is converted via `Platform.Agents.Config.to_agent_attrs/2`

  Additional optional keys on `child_input`:

    * `:context_scope` - `ContextScope` input for inherited context filtering
    * `:task` - stored on the child session local context and telemetry metadata
    * `:workspace` / `:workspace_files` - seed workspace markdown files on create
    * `:memories` - seed memory rows on create
    * `:local` - child session local context additions
    * `:session_metadata` - child session metadata additions
    * memory/context builder options accepted by `AgentServer.start_session/2`
  """
  @spec spawn_child(Agent.t() | Ecto.UUID.t() | String.t(), Ecto.UUID.t(), term(), keyword()) ::
          {:ok, spawn_result()} | {:error, term()}
  def spawn_child(parent_agent_or_ref, parent_session_id, child_input, opts \\ []) do
    with {:ok, parent_agent} <- fetch_agent(parent_agent_or_ref),
         {:ok, _parent_context} <- AgentServer.session_context(parent_agent.id, parent_session_id),
         {:ok, scope} <- ContextScope.new(child_scope_input(child_input, opts)),
         {:ok, child_agent, created?} <-
           ensure_child_agent(parent_agent, parent_session_id, child_input, opts),
         {:ok, pid} <- AgentServer.start_agent(child_agent) do
      maybe_allow_sandbox(pid)

      case AgentServer.start_session(
             child_agent.id,
             build_child_session_opts(parent_agent, parent_session_id, child_input, opts)
           ) do
        {:ok, child_session, _base_context} ->
          case ContextBroker.share_context(
                 parent_agent.id,
                 parent_session_id,
                 child_agent.id,
                 child_session.id,
                 scope
               ) do
            {:ok, child_context, share_record} ->
              emit_telemetry(
                [:platform, :agent, :child_spawned],
                %{system_time: System.system_time()},
                %{
                  parent_agent_id: parent_agent.id,
                  parent_session_id: parent_session_id,
                  child_agent_id: child_agent.id,
                  child_session_id: child_session.id,
                  child_slug: child_agent.slug,
                  created: created?,
                  scope: Atom.to_string(scope.share),
                  task: child_task(child_input, opts)
                }
              )

              {:ok,
               %{
                 agent: child_agent,
                 pid: pid,
                 session: child_session,
                 context: child_context,
                 share_record: share_record,
                 created?: created?
               }}

            {:error, reason} ->
              _ =
                AgentServer.finish_session(child_agent.id, child_session.id,
                  status: :cancelled,
                  metadata: %{"orchestration_error" => inspect(reason)}
                )

              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Complete a child session and optionally promote a child delta into the parent.

  Options:

    * `:delta` - `ContextDelta` input; when present, missing `from_agent` /
      `from_session` values are filled from the child references automatically
    * all `AgentServer.finish_session/3` options (`:status`, `:snapshot`, ...)
    * `:stop_agent` - stop the child runtime after completion (default: `false`)
  """
  @spec complete_child(
          Agent.t() | Ecto.UUID.t() | String.t(),
          Ecto.UUID.t(),
          Agent.t() | Ecto.UUID.t() | String.t(),
          Ecto.UUID.t(),
          keyword()
        ) :: {:ok, completion_result()} | {:error, term()}
  def complete_child(
        parent_agent_or_ref,
        parent_session_id,
        child_agent_or_ref,
        child_session_id,
        opts \\ []
      ) do
    with {:ok, parent_agent} <- fetch_agent(parent_agent_or_ref),
         {:ok, child_agent} <- fetch_agent(child_agent_or_ref),
         {:ok, promotion} <-
           maybe_promote_delta(
             parent_agent.id,
             parent_session_id,
             child_agent.id,
             child_session_id,
             opts
           ),
         {:ok, finished_session, snapshot_memory} <-
           AgentServer.finish_session(child_agent.id, child_session_id, finish_child_opts(opts)) do
      stopped? = maybe_stop_child(child_agent.id, Keyword.get(opts, :stop_agent, false))

      emit_telemetry(
        [:platform, :agent, :child_completed],
        %{
          system_time: System.system_time(),
          duration_ms: session_duration_ms(finished_session),
          promoted_memories: length(promotion.promoted_memories)
        },
        %{
          parent_agent_id: parent_agent.id,
          parent_session_id: parent_session_id,
          child_agent_id: child_agent.id,
          child_session_id: child_session_id,
          child_slug: child_agent.slug,
          status: finished_session.status,
          promoted: promotion.promoted?,
          snapshot_written: not is_nil(snapshot_memory),
          stopped: stopped?
        }
      )

      {:ok,
       %{
         session: finished_session,
         snapshot_memory: snapshot_memory,
         promoted_context: promotion.promoted_context,
         promoted_memories: promotion.promoted_memories,
         promotion_share: promotion.promotion_share,
         stopped?: stopped?
       }}
    end
  end

  @doc """
  List child sessions linked to a parent session, newest first.
  """
  @spec list_children(Ecto.UUID.t()) :: [%{agent: Agent.t(), session: Session.t()}]
  def list_children(parent_session_id) do
    from(s in Session,
      join: a in Agent,
      on: a.id == s.agent_id,
      where: s.parent_session_id == ^parent_session_id,
      order_by: [desc: s.started_at, desc: s.id],
      select: %{agent: a, session: s}
    )
    |> Repo.all()
  end

  defp ensure_child_agent(parent_agent, parent_session_id, child_input, opts) do
    spec = normalize_child_input(child_input)

    case resolve_existing_child(parent_agent, spec) do
      {:ok, %Agent{} = child_agent} ->
        {:ok, child_agent, false}

      {:ok, nil} ->
        create_child_agent(parent_agent, parent_session_id, spec, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_existing_child(_parent_agent, %{"agent" => %Agent{} = agent}), do: {:ok, agent}
  defp resolve_existing_child(_parent_agent, %{"agent_id" => agent_id}), do: fetch_agent(agent_id)
  defp resolve_existing_child(_parent_agent, %{"id" => agent_id}), do: fetch_agent(agent_id)

  defp resolve_existing_child(%Agent{} = parent_agent, %{"slug" => slug}) when is_binary(slug) do
    {:ok, find_agent_by_workspace_slug(parent_agent.workspace_id, slug)}
  end

  defp resolve_existing_child(_parent_agent, _spec), do: {:ok, nil}

  defp create_child_agent(parent_agent, _parent_session_id, spec, opts) do
    attrs = build_child_agent_attrs(parent_agent, spec, opts)

    Repo.transaction(fn ->
      agent =
        %Agent{}
        |> Agent.changeset(attrs)
        |> Repo.insert!()

      seed_child_workspace!(agent.id, spec)
      seed_child_memories!(agent.id, spec)

      agent
    end)
    |> case do
      {:ok, agent} -> {:ok, agent, true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_child_agent_attrs(parent_agent, spec, opts) do
    base_attrs =
      case Map.get(spec, "config") do
        %{} = config ->
          Config.to_agent_attrs(config,
            workspace_id: Map.get(spec, "workspace_id") || parent_agent.workspace_id,
            parent_agent_id: Map.get(spec, "parent_agent_id") || parent_agent.id,
            status: Map.get(spec, "status") || Keyword.get(opts, :status, "active")
          )

        _ ->
          slug = Map.get(spec, "slug") || generated_child_slug(parent_agent.slug)

          %{
            slug: slug,
            name: Map.get(spec, "name") || slug,
            status: Map.get(spec, "status") || Keyword.get(opts, :status, "active"),
            model_config:
              normalize_map(Map.get(spec, "model_config") || Map.get(spec, "modelConfig")),
            tools_config:
              normalize_map(Map.get(spec, "tools_config") || Map.get(spec, "toolsConfig")),
            heartbeat_config:
              normalize_map(Map.get(spec, "heartbeat_config") || Map.get(spec, "heartbeatConfig")),
            metadata: %{}
          }
          |> maybe_put(
            :thinking_default,
            Map.get(spec, "thinking_default") || Map.get(spec, "thinkingDefault")
          )
          |> maybe_put(
            :max_concurrent,
            normalize_integer(Map.get(spec, "max_concurrent") || Map.get(spec, "maxConcurrent"))
          )
          |> maybe_put(
            :sandbox_mode,
            Map.get(spec, "sandbox_mode") || Map.get(spec, "sandboxMode")
          )
          |> maybe_put(:workspace_id, Map.get(spec, "workspace_id") || parent_agent.workspace_id)
          |> maybe_put(:parent_agent_id, Map.get(spec, "parent_agent_id") || parent_agent.id)
      end

    metadata =
      base_attrs
      |> Map.get(:metadata, %{})
      |> normalize_map()
      |> deep_merge(normalize_map(Map.get(spec, "metadata")))
      |> deep_merge(%{
        "orchestration" => %{
          "spawned_by_agent_id" => parent_agent.id,
          "kind" => "child"
        }
      })

    Map.put(base_attrs, :metadata, metadata)
  end

  defp build_child_session_opts(parent_agent, parent_session_id, child_input, opts) do
    spec = normalize_child_input(child_input)

    local =
      spec
      |> Map.get("local", %{})
      |> normalize_map()
      |> maybe_put_in_map("task", child_task(child_input, opts))

    session_metadata =
      spec
      |> Map.get("session_metadata")
      |> normalize_map()
      |> deep_merge(%{
        "orchestration" => %{
          "parent_agent_id" => parent_agent.id,
          "parent_session_id" => parent_session_id
        }
      })
      |> maybe_put_in_map("task", child_task(child_input, opts))

    []
    |> Keyword.put(:parent_session_id, parent_session_id)
    |> maybe_put_kw(:context, Map.get(spec, "context"))
    |> maybe_put_kw(
      :workspace_keys,
      Map.get(spec, "workspace_keys") || Map.get(spec, "workspaceKeys")
    )
    |> maybe_put_kw(:memory_types, Map.get(spec, "memory_types") || Map.get(spec, "memoryTypes"))
    |> maybe_put_kw(:query, Map.get(spec, "query"))
    |> maybe_put_kw(:date_from, Map.get(spec, "date_from") || Map.get(spec, "dateFrom"))
    |> maybe_put_kw(:date_to, Map.get(spec, "date_to") || Map.get(spec, "dateTo"))
    |> maybe_put_kw(:limit, Map.get(spec, "limit"))
    |> maybe_put_kw(
      :long_term_limit,
      Map.get(spec, "long_term_limit") || Map.get(spec, "longTermLimit")
    )
    |> maybe_put_kw(:daily_limit, Map.get(spec, "daily_limit") || Map.get(spec, "dailyLimit"))
    |> maybe_put_kw(
      :snapshot_limit,
      Map.get(spec, "snapshot_limit") || Map.get(spec, "snapshotLimit")
    )
    |> maybe_put_kw(:model_used, Map.get(spec, "model_used") || Map.get(spec, "modelUsed"))
    |> maybe_put_kw(:token_usage, Map.get(spec, "token_usage") || Map.get(spec, "tokenUsage"))
    |> maybe_put_kw(:local, local)
    |> maybe_put_kw(:metadata, session_metadata)
  end

  defp child_scope_input(child_input, opts) do
    spec = normalize_child_input(child_input)

    Map.get(spec, "context_scope") || Map.get(spec, "contextScope") ||
      Keyword.get(opts, :context_scope, :full)
  end

  defp child_task(child_input, opts) do
    spec = normalize_child_input(child_input)
    Map.get(spec, "task") || Keyword.get(opts, :task)
  end

  defp seed_child_workspace!(agent_id, spec) do
    workspace =
      normalize_map(Map.get(spec, "workspace"))
      |> deep_merge(
        normalize_map(Map.get(spec, "workspace_files") || Map.get(spec, "workspaceFiles"))
      )

    Enum.each(workspace, fn {file_key, content} ->
      {:ok, _workspace_file} =
        MemoryContext.upsert_workspace_file(agent_id, file_key, to_string(content || ""))
    end)
  end

  defp seed_child_memories!(agent_id, spec) do
    spec
    |> Map.get("memories", [])
    |> List.wrap()
    |> Enum.each(fn
      %{} = memory ->
        {:ok, _memory} =
          MemoryContext.append_memory(
            agent_id,
            Map.get(memory, "memory_type") || Map.get(memory, :memory_type) || :long_term,
            to_string(Map.get(memory, "content") || Map.get(memory, :content) || ""),
            date: Map.get(memory, "date") || Map.get(memory, :date),
            metadata:
              normalize_map(Map.get(memory, "metadata") || Map.get(memory, :metadata) || %{})
          )

      _other ->
        :ok
    end)
  end

  defp maybe_promote_delta(
         parent_agent_id,
         parent_session_id,
         child_agent_id,
         child_session_id,
         opts
       ) do
    case Keyword.get(opts, :delta) do
      nil ->
        {:ok,
         %{promoted?: false, promoted_context: nil, promoted_memories: [], promotion_share: nil}}

      delta_input ->
        delta_input = ensure_delta_defaults(delta_input, child_agent_id, child_session_id)

        case ContextBroker.promote_delta(parent_agent_id, parent_session_id, delta_input) do
          {:ok, :skipped} ->
            {:ok,
             %{
               promoted?: false,
               promoted_context: nil,
               promoted_memories: [],
               promotion_share: nil
             }}

          {:ok, promoted_context, promoted_memories, promotion_share} ->
            {:ok,
             %{
               promoted?: true,
               promoted_context: promoted_context,
               promoted_memories: promoted_memories,
               promotion_share: promotion_share
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp finish_child_opts(opts) do
    opts
    |> Keyword.drop([:delta, :stop_agent])
  end

  defp ensure_delta_defaults(%ContextDelta{} = delta, _child_agent_id, _child_session_id),
    do: delta

  defp ensure_delta_defaults(delta_input, child_agent_id, child_session_id)
       when is_list(delta_input) do
    delta_input
    |> Enum.into(%{})
    |> ensure_delta_defaults(child_agent_id, child_session_id)
  end

  defp ensure_delta_defaults(delta_input, child_agent_id, child_session_id)
       when is_map(delta_input) do
    delta_input
    |> Map.put_new(:from_agent, child_agent_id)
    |> Map.put_new(:from_session, child_session_id)
  end

  defp ensure_delta_defaults(other, _child_agent_id, _child_session_id), do: other

  defp maybe_stop_child(_child_agent_id, false), do: false

  defp maybe_stop_child(child_agent_id, true) do
    case AgentServer.stop_agent(child_agent_id) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  defp session_duration_ms(%Session{
         started_at: %DateTime{} = started_at,
         ended_at: %DateTime{} = ended_at
       }) do
    DateTime.diff(ended_at, started_at, :millisecond)
  end

  defp session_duration_ms(_session), do: nil

  defp find_agent_by_workspace_slug(nil, slug) do
    Repo.get_by(Agent, slug: slug)
  end

  defp find_agent_by_workspace_slug(workspace_id, slug) do
    Repo.get_by(Agent, workspace_id: workspace_id, slug: slug)
  end

  defp fetch_agent(%Agent{} = agent), do: {:ok, agent}

  defp fetch_agent(value) when is_binary(value) do
    cond do
      match?({:ok, _}, Ecto.UUID.cast(value)) ->
        case Repo.get(Agent, value) do
          %Agent{} = agent -> {:ok, agent}
          nil -> {:error, :not_found}
        end

      true ->
        case Repo.get_by(Agent, slug: value) do
          %Agent{} = agent -> {:ok, agent}
          nil -> {:error, :not_found}
        end
    end
  end

  defp fetch_agent(_other), do: {:error, :not_found}

  defp generated_child_slug(parent_slug) do
    "#{parent_slug}-child-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp normalize_child_input(%Agent{} = agent), do: %{"agent" => agent}
  defp normalize_child_input(value) when is_binary(value), do: %{"slug" => value}

  defp normalize_child_input(value) when is_list(value) do
    value
    |> Enum.into(%{})
    |> normalize_child_input()
  end

  defp normalize_child_input(%{} = value), do: stringify_map(value)
  defp normalize_child_input(_other), do: %{}

  defp maybe_allow_sandbox(pid) when is_pid(pid) do
    if sandbox_pool?() do
      case Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid) do
        :ok -> :ok
        {:already, :owner} -> :ok
        {:already, :allowed} -> :ok
        _other -> :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp sandbox_pool? do
    case Repo.config()[:pool] do
      Ecto.Adapters.SQL.Sandbox -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp normalize_map(nil), do: %{}
  defp normalize_map(%{} = map), do: stringify_map(map)
  defp normalize_map(_value), do: %{}

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(%Date{} = date), do: Date.to_iso8601(date)
  defp stringify_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp stringify_value(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp stringify_value(map) when is_map(map), do: stringify_map(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp stringify_value(value), do: value

  defp deep_merge(left, right) when map_size(left) == 0, do: right
  defp deep_merge(left, right) when map_size(right) == 0, do: left

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_kw(list, _key, nil), do: list
  defp maybe_put_kw(list, _key, %{} = value) when map_size(value) == 0, do: list
  defp maybe_put_kw(list, _key, []), do: list
  defp maybe_put_kw(list, key, value), do: Keyword.put(list, key, value)

  defp maybe_put_in_map(map, _key, nil), do: map
  defp maybe_put_in_map(map, key, value), do: Map.put(map, key, value)

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
