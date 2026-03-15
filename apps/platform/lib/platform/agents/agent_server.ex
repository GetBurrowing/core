defmodule Platform.Agents.AgentServer do
  @moduledoc """
  Supervised runtime process for a single agent.

  T4 introduces the OTP runtime shell that later tasks plug into:

    * dynamic startup/shutdown under `Platform.Agents.RuntimeSupervisor`
    * registry-based lookup by agent slug
    * session lifecycle management backed by `agent_sessions`
    * runtime context assembly via `Platform.Agents.MemoryContext`
    * Vault-backed credential resolution via `Platform.Vault.get/2`

  Provider calls, routing, context promotion, and orchestration arrive in later
  tasks; this module focuses on the durable, supervised runtime foundation.
  """

  use GenServer

  import Ecto.Changeset, only: [put_change: 3]

  alias Platform.Agents.{Agent, Context, ContextDelta, Memory, MemoryContext, Session}
  alias Platform.Repo

  @valid_session_statuses ~w(completed failed cancelled)

  defmodule State do
    @moduledoc false

    @enforce_keys [:agent_id, :slug, :agent, :config, :workspace, :memory_ref, :status]
    defstruct agent_id: nil,
              slug: nil,
              agent: nil,
              config: %{},
              workspace: %{},
              memory_ref: nil,
              active_context: nil,
              active_sessions: %{},
              child_agents: [],
              parent_agent: nil,
              status: :idle
  end

  @type session_runtime :: %{
          started_at: DateTime.t(),
          context: Context.t(),
          parent_session_id: Ecto.UUID.t() | nil
        }

  @type runtime_status :: :idle | :working | :paused

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    %Agent{} = agent = Keyword.fetch!(opts, :agent)
    GenServer.start_link(__MODULE__, opts, name: via(agent.slug))
  end

  @doc """
  Ensure an agent runtime is running under the dynamic supervisor.
  """
  @spec start_agent(Agent.t() | Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_agent(agent_or_ref, opts \\ []) do
    with {:ok, agent} <- fetch_agent(agent_or_ref) do
      case whereis(agent.id) do
        pid when is_pid(pid) ->
          {:ok, pid}

        nil ->
          workspace = load_workspace_map(agent.id)

          DynamicSupervisor.start_child(
            Platform.Agents.RuntimeSupervisor,
            {__MODULE__, Keyword.merge(opts, agent: agent, workspace: workspace)}
          )
      end
    end
  end

  @doc """
  Stop a running agent runtime if it exists.
  """
  @spec stop_agent(Agent.t() | Ecto.UUID.t() | String.t() | pid()) :: :ok | {:error, term()}
  def stop_agent(agent_or_ref) do
    case locate_server(agent_or_ref) do
      {:ok, pid} ->
        case DynamicSupervisor.terminate_child(Platform.Agents.RuntimeSupervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolve the runtime process for a running agent, if any.
  """
  @spec whereis(Agent.t() | Ecto.UUID.t() | String.t()) :: pid() | nil
  def whereis(agent_or_ref) do
    with {:ok, slug} <- resolve_slug(agent_or_ref) do
      case Registry.lookup(Platform.Agents.Registry, slug) do
        [{pid, _value}] -> pid
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  Return the current in-memory runtime state.
  """
  @spec state(Agent.t() | Ecto.UUID.t() | String.t() | pid()) ::
          {:ok, State.t()} | {:error, term()}
  def state(agent_or_ref) do
    with {:ok, pid} <- locate_server(agent_or_ref) do
      {:ok, GenServer.call(pid, :state)}
    end
  end

  @doc """
  Reload the agent row and workspace files from the database.
  """
  @spec refresh(Agent.t() | Ecto.UUID.t() | String.t() | pid()) ::
          {:ok, Agent.t()} | {:error, term()}
  def refresh(agent_or_ref) do
    with {:ok, pid} <- locate_server(agent_or_ref) do
      GenServer.call(pid, :refresh)
    end
  end

  @doc """
  Create and track a new runtime session for the agent.

  ## Options

    * `:parent_session_id` - optional parent session UUID
    * `:context` - prebuilt `%Platform.Agents.Context{}` to use instead of
      rebuilding from `MemoryContext`
    * `:workspace_keys`, `:memory_types`, `:query`, `:date_from`, `:date_to`,
      `:limit`, `:long_term_limit`, `:daily_limit`, `:snapshot_limit` - passed
      through to `MemoryContext.build_context/2`
    * `:inherited`, `:local`, `:metadata` - merged onto the built context
    * `:model_used` - optional model hint stored on the session row
    * `:token_usage` - optional token map stored on the session row
  """
  @spec start_session(Agent.t() | Ecto.UUID.t() | String.t() | pid(), keyword()) ::
          {:ok, Session.t(), Context.t()} | {:error, term()}
  def start_session(agent_or_ref, opts \\ []) do
    with {:ok, pid} <- locate_server(agent_or_ref) do
      GenServer.call(pid, {:start_session, opts}, 15_000)
    end
  end

  @doc """
  Finish an in-flight session and optionally persist a snapshot memory.

  ## Options

    * `:status` - `:completed | :failed | :cancelled` (default `:completed`)
    * `:model_used` - persisted onto the session row
    * `:token_usage` - persisted onto the session row
    * `:snapshot` - if present, appended as a `snapshot` memory entry
    * `:local`, `:metadata` - merged into the final in-memory context for the
      session before it is removed from the active set
  """
  @spec finish_session(Agent.t() | Ecto.UUID.t() | String.t() | pid(), Ecto.UUID.t(), keyword()) ::
          {:ok, Session.t(), Memory.t() | nil} | {:error, term()}
  def finish_session(agent_or_ref, session_id, opts \\ []) do
    with {:ok, pid} <- locate_server(agent_or_ref) do
      GenServer.call(pid, {:finish_session, session_id, opts}, 15_000)
    end
  end

  @doc """
  Return the session IDs currently tracked in memory for the running agent.
  """
  @spec active_session_ids(Agent.t() | Ecto.UUID.t() | String.t() | pid()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, term()}
  def active_session_ids(agent_or_ref) do
    with {:ok, pid} <- locate_server(agent_or_ref) do
      {:ok, GenServer.call(pid, :active_session_ids)}
    end
  end

  @doc """
  Return the current runtime context for an active session.
  """
  @spec session_context(Agent.t() | Ecto.UUID.t() | String.t() | pid(), Ecto.UUID.t()) ::
          {:ok, Context.t()} | {:error, term()}
  def session_context(agent_or_ref, session_id) do
    with {:ok, pid} <- locate_server(agent_or_ref) do
      GenServer.call(pid, {:session_context, session_id})
    end
  end

  @doc """
  Merge an immutable inherited payload into an active session.

  The payload is stored under `context.inherited[source_key]` so provenance is
  preserved even when multiple parent sessions share context into the same child.
  """
  @spec merge_inherited_context(
          Agent.t() | Ecto.UUID.t() | String.t() | pid(),
          Ecto.UUID.t(),
          term(),
          map(),
          keyword()
        ) :: {:ok, Context.t()} | {:error, term()}
  def merge_inherited_context(agent_or_ref, session_id, source_key, inherited_payload, opts \\ []) do
    with {:ok, pid} <- locate_server(agent_or_ref) do
      GenServer.call(
        pid,
        {:merge_inherited_context, session_id, source_key, inherited_payload, opts}
      )
    end
  end

  @doc """
  Apply a promoted child delta to an active parent session.
  """
  @spec apply_delta(
          Agent.t() | Ecto.UUID.t() | String.t() | pid(),
          Ecto.UUID.t(),
          ContextDelta.t() | map() | keyword()
        ) :: {:ok, Context.t()} | {:error, term()}
  def apply_delta(agent_or_ref, session_id, delta) do
    with {:ok, pid} <- locate_server(agent_or_ref) do
      GenServer.call(pid, {:apply_delta, session_id, delta})
    end
  end

  @doc """
  Resolve a Vault credential on behalf of the agent.

  This is the runtime-side credential lookup later provider/router tasks will
  consume. Access is always checked as the agent itself.
  """
  @spec fetch_credential(Agent.t() | Ecto.UUID.t() | String.t() | pid(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def fetch_credential(agent_or_ref, slug, opts \\ []) do
    with {:ok, pid} <- locate_server(agent_or_ref) do
      GenServer.call(pid, {:fetch_credential, slug, opts}, 15_000)
    end
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(opts) do
    %Agent{} = agent = Keyword.fetch!(opts, :agent)
    workspace = Keyword.get(opts, :workspace, %{})
    status = normalize_runtime_status(agent.status)

    state = %State{
      agent_id: agent.id,
      slug: agent.slug,
      agent: agent,
      config: config_from_agent(agent),
      workspace: workspace,
      memory_ref: {:memory_context, agent.id},
      active_context: base_context(agent.id, workspace),
      active_sessions: %{},
      child_agents: [],
      parent_agent: agent.parent_agent_id,
      status: status
    }

    emit_telemetry([:platform, :agent, :started], %{system_time: System.system_time()}, %{
      agent_id: agent.id,
      slug: agent.slug,
      parent_agent_id: agent.parent_agent_id,
      workspace_id: agent.workspace_id,
      status: status
    })

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, %State{} = state), do: {:reply, state, state}

  def handle_call(:active_session_ids, _from, %State{} = state) do
    {:reply, Map.keys(state.active_sessions), state}
  end

  def handle_call({:session_context, session_id}, _from, %State{} = state) do
    case Map.get(state.active_sessions, session_id) do
      %{context: %Context{} = context} -> {:reply, {:ok, context}, state}
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(
        {:merge_inherited_context, session_id, source_key, inherited_payload, opts},
        _from,
        %State{} = state
      ) do
    case update_session_runtime(state, session_id, fn context ->
           key = normalize_inherited_key(source_key)
           metadata = normalize_context_map(Keyword.get(opts, :metadata))

           %{
             context
             | inherited: Map.put(context.inherited, key, json_safe(inherited_payload)),
               metadata: deep_merge(context.metadata, metadata)
           }
         end) do
      {:ok, context, new_state} -> {:reply, {:ok, context}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_delta, session_id, delta_input}, _from, %State{} = state) do
    with {:ok, delta} <- ContextDelta.new(delta_input),
         {:ok, context, new_state} <-
           update_session_runtime(state, session_id, fn %Context{} = context ->
             updated_local =
               context.local
               |> deep_merge(delta.additions)
               |> remove_context_paths(delta.removals)

             %Context{
               context
               | local: updated_local,
                 metadata:
                   deep_merge(context.metadata, %{
                     "last_promoted_from_agent" => delta.from_agent,
                     "last_promoted_from_session" => delta.from_session
                   })
             }
           end) do
      {:reply, {:ok, context}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:refresh, _from, %State{} = state) do
    case Repo.get(Agent, state.agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Agent{} = agent ->
        workspace = load_workspace_map(agent.id)
        refreshed_status = refresh_runtime_status(agent.status, state.active_sessions)

        new_state = %State{
          state
          | agent: agent,
            slug: agent.slug,
            config: config_from_agent(agent),
            workspace: workspace,
            active_context: refresh_active_context(state.active_context, agent.id, workspace),
            parent_agent: agent.parent_agent_id,
            status: refreshed_status
        }

        {:reply, {:ok, agent}, new_state}
    end
  end

  def handle_call({:start_session, opts}, _from, %State{} = state) do
    cond do
      state.status == :paused ->
        {:reply, {:error, :paused}, state}

      map_size(state.active_sessions) >= max_concurrent(state.agent) ->
        {:reply, {:error, :max_concurrency}, state}

      true ->
        session_id = Ecto.UUID.generate()
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        context = build_session_context(state, session_id, opts)

        attrs = %{
          agent_id: state.agent_id,
          parent_session_id: Keyword.get(opts, :parent_session_id),
          status: "running",
          context_snapshot: serialize_context(context),
          model_used: Keyword.get(opts, :model_used),
          token_usage: json_safe(Keyword.get(opts, :token_usage, %{})),
          started_at: now
        }

        changeset =
          %Session{}
          |> Session.changeset(attrs)
          |> put_change(:id, session_id)

        case Repo.insert(changeset) do
          {:ok, session} ->
            runtime = %{
              started_at: now,
              context: context,
              parent_session_id: session.parent_session_id
            }

            new_state = %State{
              state
              | active_sessions: Map.put(state.active_sessions, session.id, runtime),
                active_context: context,
                status: :working
            }

            emit_telemetry(
              [:platform, :agent, :session_started],
              %{system_time: System.system_time()},
              %{
                agent_id: state.agent_id,
                session_id: session.id,
                parent_session_id: session.parent_session_id,
                model_used: session.model_used,
                active_sessions: map_size(new_state.active_sessions)
              }
            )

            {:reply, {:ok, session, context}, new_state}

          {:error, changeset} ->
            {:reply, {:error, changeset}, state}
        end
    end
  end

  def handle_call({:finish_session, session_id, opts}, _from, %State{} = state) do
    with {:ok, status} <- normalize_session_status(Keyword.get(opts, :status, :completed)),
         %Session{} = session <- Repo.get(Session, session_id),
         true <- session.agent_id == state.agent_id do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      update_attrs =
        %{
          status: status,
          ended_at: now
        }
        |> maybe_put(:model_used, Keyword.get(opts, :model_used))
        |> maybe_put(:token_usage, json_safe(Keyword.get(opts, :token_usage)))

      result =
        Repo.transaction(fn ->
          updated_session =
            session
            |> Session.changeset(update_attrs)
            |> Repo.update!()

          snapshot_memory =
            case normalize_snapshot(Keyword.get(opts, :snapshot)) do
              nil ->
                nil

              snapshot ->
                metadata = %{
                  "session_id" => session_id,
                  "status" => status,
                  "model_used" => updated_session.model_used
                }

                case MemoryContext.append_memory(state.agent_id, :snapshot, snapshot,
                       metadata: metadata
                     ) do
                  {:ok, memory} -> memory
                  {:error, changeset} -> Repo.rollback(changeset)
                end
            end

          {updated_session, snapshot_memory}
        end)

      case result do
        {:ok, {updated_session, snapshot_memory}} ->
          {finished_context, new_state} = finalize_session_state(state, session_id, opts)

          emit_telemetry(
            [:platform, :agent, :session_ended],
            %{
              system_time: System.system_time(),
              duration_ms: session_duration_ms(state, session_id, session.started_at, now)
            },
            %{
              agent_id: state.agent_id,
              session_id: session_id,
              status: status,
              model_used: updated_session.model_used,
              active_sessions: map_size(new_state.active_sessions),
              snapshot_written: not is_nil(snapshot_memory),
              final_context: summarize_context(finished_context)
            }
          )

          {:reply, {:ok, updated_session, snapshot_memory}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      nil -> {:reply, {:error, :not_found}, state}
      false -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:fetch_credential, slug, opts}, _from, %State{} = state) do
    result =
      opts
      |> Keyword.put(:accessor, {:agent, state.agent_id})
      |> then(&Platform.Vault.get(slug, &1))

    {:reply, result, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    emit_telemetry([:platform, :agent, :stopped], %{system_time: System.system_time()}, %{
      agent_id: state.agent_id,
      slug: state.slug,
      reason: inspect(reason),
      active_sessions: map_size(state.active_sessions)
    })

    :ok
  end

  # -- Registry / lookup helpers ---------------------------------------------

  defp via(slug), do: {:via, Registry, {Platform.Agents.Registry, slug}}

  defp locate_server(pid) when is_pid(pid), do: {:ok, pid}

  defp locate_server(agent_or_ref) do
    case whereis(agent_or_ref) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :not_found}
    end
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

  defp resolve_slug(%Agent{slug: slug}), do: {:ok, slug}

  defp resolve_slug(value) when is_binary(value) do
    cond do
      match?({:ok, _}, Ecto.UUID.cast(value)) ->
        case Repo.get(Agent, value) do
          %Agent{slug: slug} -> {:ok, slug}
          nil -> {:error, :not_found}
        end

      true ->
        {:ok, value}
    end
  end

  defp resolve_slug(_other), do: {:error, :not_found}

  # -- Context / state helpers ------------------------------------------------

  defp build_session_context(state, session_id, opts) do
    context =
      case Keyword.get(opts, :context) do
        %Context{} = context ->
          %Context{context | agent_id: state.agent_id, session_id: session_id}

        _ ->
          filters =
            opts
            |> Keyword.take([
              :workspace_keys,
              :memory_types,
              :query,
              :date_from,
              :date_to,
              :limit,
              :long_term_limit,
              :daily_limit,
              :snapshot_limit
            ])
            |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
            |> Keyword.put(:session_id, session_id)

          MemoryContext.build_context(state.agent_id, filters)
      end

    workspace =
      case context.workspace do
        workspace when workspace == %{} -> state.workspace
        workspace -> workspace
      end

    %Context{
      context
      | workspace: workspace,
        inherited:
          deep_merge(context.inherited, normalize_context_map(Keyword.get(opts, :inherited))),
        local: deep_merge(context.local, normalize_context_map(Keyword.get(opts, :local))),
        metadata:
          deep_merge(context.metadata, normalize_context_map(Keyword.get(opts, :metadata)))
    }
  end

  defp finalize_session_state(%State{} = state, session_id, opts) do
    runtime = Map.get(state.active_sessions, session_id)
    finished_context = build_finished_context(runtime, opts)
    remaining_sessions = Map.delete(state.active_sessions, session_id)

    next_context =
      case remaining_sessions |> Map.values() |> Enum.map(& &1.context) do
        [%Context{} | _] = contexts -> List.last(contexts)
        [] -> finished_context || base_context(state.agent_id, state.workspace)
      end

    status = refresh_runtime_status(state.agent.status, remaining_sessions)

    new_state = %State{
      state
      | active_sessions: remaining_sessions,
        active_context: next_context,
        status: status
    }

    {finished_context, new_state}
  end

  defp build_finished_context(nil, _opts), do: nil

  defp build_finished_context(%{context: %Context{} = context}, opts) do
    %Context{
      context
      | local: deep_merge(context.local, normalize_context_map(Keyword.get(opts, :local))),
        metadata:
          deep_merge(context.metadata, normalize_context_map(Keyword.get(opts, :metadata)))
    }
  end

  defp update_session_runtime(%State{} = state, session_id, updater)
       when is_function(updater, 1) do
    case Map.get(state.active_sessions, session_id) do
      %{context: %Context{} = context} = runtime ->
        updated_context = updater.(context)
        updated_runtime = %{runtime | context: updated_context}

        new_state = %State{
          state
          | active_sessions: Map.put(state.active_sessions, session_id, updated_runtime),
            active_context:
              maybe_replace_active_context(state.active_context, session_id, updated_context)
        }

        {:ok, updated_context, new_state}

      _ ->
        {:error, :not_found}
    end
  end

  defp maybe_replace_active_context(
         %Context{session_id: session_id},
         session_id,
         updated_context
       ),
       do: updated_context

  defp maybe_replace_active_context(active_context, _session_id, _updated_context),
    do: active_context

  defp normalize_inherited_key(value) when is_binary(value), do: value
  defp normalize_inherited_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_inherited_key(value), do: inspect(value)

  defp remove_context_paths(map, []), do: map

  defp remove_context_paths(map, paths) when is_map(map) do
    Enum.reduce(paths, map, &delete_context_path(&2, &1))
  end

  defp remove_context_paths(map, _paths), do: map

  defp delete_context_path(map, path) when is_binary(path) do
    keys =
      path
      |> String.split(".", trim: true)
      |> Enum.reject(&(&1 == ""))

    do_delete_context_path(map, keys)
  end

  defp delete_context_path(map, path), do: delete_context_path(map, to_string(path))

  defp do_delete_context_path(map, []), do: map
  defp do_delete_context_path(map, [key]) when is_map(map), do: Map.delete(map, key)

  defp do_delete_context_path(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nested when is_map(nested) -> Map.put(map, key, do_delete_context_path(nested, rest))
      _ -> map
    end
  end

  defp do_delete_context_path(map, _keys), do: map

  defp refresh_active_context(%Context{} = context, agent_id, workspace) do
    %Context{context | agent_id: agent_id, workspace: workspace}
  end

  defp refresh_active_context(_context, agent_id, workspace),
    do: base_context(agent_id, workspace)

  defp base_context(agent_id, workspace) do
    %Context{
      agent_id: agent_id,
      workspace: workspace,
      memory: %{},
      metadata: %{"source" => "agent_server"}
    }
  end

  defp config_from_agent(agent) do
    %{
      "model" => agent.model_config || %{},
      "tools" => agent.tools_config || %{},
      "thinking_default" => agent.thinking_default,
      "heartbeat" => agent.heartbeat_config || %{},
      "max_concurrent" => agent.max_concurrent || 1,
      "sandbox_mode" => agent.sandbox_mode,
      "metadata" => agent.metadata || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp load_workspace_map(agent_id) do
    agent_id
    |> MemoryContext.list_workspace_files()
    |> Map.new(fn workspace_file -> {workspace_file.file_key, workspace_file.content} end)
  end

  defp max_concurrent(%Agent{max_concurrent: value}) when is_integer(value) and value > 0,
    do: value

  defp max_concurrent(_agent), do: 1

  defp normalize_runtime_status(status) when status in ["paused", "archived", :paused],
    do: :paused

  defp normalize_runtime_status(_status), do: :idle

  defp refresh_runtime_status(agent_status, active_sessions) do
    cond do
      normalize_runtime_status(agent_status) == :paused -> :paused
      map_size(active_sessions) > 0 -> :working
      true -> :idle
    end
  end

  defp normalize_session_status(status) when status in [:completed, :failed, :cancelled],
    do: {:ok, Atom.to_string(status)}

  defp normalize_session_status(status) when status in @valid_session_statuses, do: {:ok, status}
  defp normalize_session_status(_status), do: {:error, :invalid_status}

  defp normalize_snapshot(snapshot) when is_binary(snapshot) do
    snapshot = String.trim(snapshot)
    if snapshot == "", do: nil, else: snapshot
  end

  defp normalize_snapshot(_snapshot), do: nil

  defp session_duration_ms(state, session_id, fallback_started_at, ended_at) do
    started_at =
      case Map.get(state.active_sessions, session_id) do
        %{started_at: %DateTime{} = started_at} -> started_at
        _ -> fallback_started_at
      end

    DateTime.diff(ended_at, started_at, :millisecond)
  end

  defp summarize_context(nil), do: nil

  defp summarize_context(%Context{} = context) do
    %{
      "workspace_keys" => Map.keys(context.workspace),
      "memory_counts" =>
        Map.new(context.memory, fn {bucket, entries} ->
          {to_string(bucket), length(entries)}
        end),
      "inherited_keys" => Map.keys(context.inherited),
      "local_keys" => Map.keys(context.local)
    }
  end

  # -- Serialization / JSON helpers ------------------------------------------

  defp serialize_context(%Context{} = context) do
    %{
      "agent_id" => context.agent_id,
      "session_id" => context.session_id,
      "workspace" => json_safe(context.workspace),
      "memory" => serialize_memory(context.memory),
      "inherited" => json_safe(context.inherited),
      "local" => json_safe(context.local),
      "metadata" => json_safe(context.metadata)
    }
  end

  defp serialize_memory(memory_buckets) when is_map(memory_buckets) do
    Map.new(memory_buckets, fn {bucket, entries} ->
      {to_string(bucket), Enum.map(entries, &serialize_memory_entry/1)}
    end)
  end

  defp serialize_memory(_memory_buckets), do: %{}

  defp serialize_memory_entry(%Memory{} = memory) do
    %{
      "id" => memory.id,
      "agent_id" => memory.agent_id,
      "memory_type" => memory.memory_type,
      "date" => json_safe(memory.date),
      "content" => memory.content,
      "metadata" => json_safe(memory.metadata),
      "inserted_at" => json_safe(memory.inserted_at)
    }
  end

  defp normalize_context_map(nil), do: %{}
  defp normalize_context_map(map) when is_map(map), do: json_safe(map)
  defp normalize_context_map(_value), do: %{}

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

  defp json_safe(nil), do: nil
  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp json_safe(%Date{} = date), do: Date.to_iso8601(date)
  defp json_safe(%Time{} = time), do: Time.to_iso8601(time)
  defp json_safe(%Decimal{} = decimal), do: Decimal.to_string(decimal)

  defp json_safe(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> json_safe()
  end

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: value

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
