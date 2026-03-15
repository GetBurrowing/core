defmodule Platform.Agents.ContextBroker do
  @moduledoc """
  Coordinates explicit, auditable context transfer between agent sessions.

  Responsibilities introduced in T5:

    * apply `%Platform.Agents.ContextScope{}` rules to a parent session context
    * write immutable inherited payloads into child runtime sessions
    * persist provenance in `agent_context_shares`
    * promote `%Platform.Agents.ContextDelta{}` payloads back into a parent
      session when the caller opts in
  """

  use GenServer

  alias Platform.Agents.{
    AgentServer,
    Context,
    ContextDelta,
    ContextScope,
    ContextShare,
    Memory,
    MemoryContext
  }

  alias Platform.Repo

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Share a filtered snapshot of a parent session's context into a child session.
  """
  @spec share_context(
          term(),
          Ecto.UUID.t(),
          term(),
          Ecto.UUID.t(),
          ContextScope.t() | map() | keyword() | atom() | String.t()
        ) ::
          {:ok, Context.t(), ContextShare.t()} | {:error, term()}
  def share_context(from_agent, from_session_id, to_agent, to_session_id, scope \\ :full) do
    GenServer.call(
      __MODULE__,
      {:share_context, from_agent, from_session_id, to_agent, to_session_id, scope},
      15_000
    )
  end

  @doc """
  Promote a child delta back into a parent's active session context.

  Returns `{:ok, :skipped}` when the delta does not request promotion.
  """
  @spec promote_delta(term(), Ecto.UUID.t(), ContextDelta.t() | map() | keyword()) ::
          {:ok, Context.t(), [Memory.t()], ContextShare.t()} | {:ok, :skipped} | {:error, term()}
  def promote_delta(parent_agent, parent_session_id, delta) do
    GenServer.call(__MODULE__, {:promote_delta, parent_agent, parent_session_id, delta}, 15_000)
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(
        {:share_context, from_agent, from_session_id, to_agent, to_session_id, scope_input},
        _from,
        state
      ) do
    with {:ok, scope} <- ContextScope.new(scope_input),
         {:ok, parent_context} <- AgentServer.session_context(from_agent, from_session_id),
         :ok <- validate_max_depth(parent_context, scope),
         shared_payload = build_shared_payload(parent_context, scope),
         {:ok, child_context} <-
           AgentServer.merge_inherited_context(
             to_agent,
             to_session_id,
             from_session_id,
             shared_payload,
             metadata: %{
               "inheritance_depth" => shared_payload["metadata"]["depth"],
               "last_inherited_from" => from_session_id,
               "last_inherited_scope" => Atom.to_string(scope.share)
             }
           ),
         {:ok, share_record} <-
           persist_share(from_session_id, to_session_id, scope, shared_payload) do
      emit_telemetry(
        [:platform, :agent, :context_shared],
        %{system_time: System.system_time()},
        %{
          from_session_id: from_session_id,
          to_session_id: to_session_id,
          from_agent_id: parent_context.agent_id,
          to_agent: inspect(to_agent),
          scope: Atom.to_string(scope.share),
          inherited_keys: Map.keys(shared_payload)
        }
      )

      {:reply, {:ok, child_context, share_record}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:promote_delta, parent_agent, parent_session_id, delta_input}, _from, state) do
    with {:ok, delta} <- ContextDelta.new(delta_input) do
      if delta.promote do
        with {:ok, promoted_context} <-
               AgentServer.apply_delta(parent_agent, parent_session_id, delta),
             {:ok, memories} <- append_promoted_memories(promoted_context.agent_id, delta),
             {:ok, share_record} <- persist_promotion(parent_session_id, delta) do
          emit_telemetry(
            [:platform, :agent, :context_promoted],
            %{
              system_time: System.system_time(),
              memory_updates: length(memories),
              removal_count: length(delta.removals)
            },
            %{
              parent_session_id: parent_session_id,
              from_session_id: delta.from_session,
              parent_agent_id: promoted_context.agent_id,
              from_agent_id: delta.from_agent,
              promoted_keys: Map.keys(delta.additions)
            }
          )

          {:reply, {:ok, promoted_context, memories, share_record}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
      else
        {:reply, {:ok, :skipped}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # -- Sharing ----------------------------------------------------------------

  defp validate_max_depth(%Context{} = _context, %ContextScope{max_depth: :unlimited}), do: :ok

  defp validate_max_depth(%Context{} = context, %ContextScope{max_depth: max_depth}) do
    current_depth = inheritance_depth(context)

    if current_depth + 1 > max_depth do
      {:error, :max_depth_exceeded}
    else
      :ok
    end
  end

  defp build_shared_payload(%Context{} = context, %ContextScope{} = scope) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    next_depth = inheritance_depth(context) + 1

    %{
      "agent_id" => context.agent_id,
      "session_id" => context.session_id,
      "workspace" => shared_workspace(context, scope),
      "memory" => shared_memory(context, scope),
      "inherited" => shared_nested_map(context.inherited, scope),
      "local" => shared_nested_map(context.local, scope),
      "metadata" => %{
        "scope" => Atom.to_string(scope.share),
        "depth" => next_depth,
        "shared_at" => now
      }
    }
    |> Enum.reject(fn {_key, value} -> value in [%{}, []] end)
    |> Map.new()
  end

  defp shared_workspace(_context, %ContextScope{include_workspace: false}), do: %{}
  defp shared_workspace(_context, %ContextScope{share: :memory_only}), do: %{}

  defp shared_workspace(%Context{} = context, %ContextScope{} = scope) do
    context.workspace
    |> filter_by_keys(scope.include_keys, scope.exclude_keys)
  end

  defp shared_memory(_context, %ContextScope{include_memory: false}), do: %{}
  defp shared_memory(_context, %ContextScope{share: :config_only}), do: %{}

  defp shared_memory(%Context{} = context, %ContextScope{}) do
    Map.new(context.memory, fn {bucket, entries} ->
      {to_string(bucket), Enum.map(entries, &serialize_memory_entry/1)}
    end)
  end

  defp shared_nested_map(_map, %ContextScope{share: share})
       when share in [:memory_only, :config_only], do: %{}

  defp shared_nested_map(map, %ContextScope{} = scope) when is_map(map) do
    map
    |> filter_by_keys(scope.include_keys, scope.exclude_keys)
    |> stringify_map()
  end

  defp shared_nested_map(_other, _scope), do: %{}

  defp persist_share(from_session_id, to_session_id, %ContextScope{} = scope, shared_payload) do
    %ContextShare{}
    |> ContextShare.changeset(%{
      from_session_id: from_session_id,
      to_session_id: to_session_id,
      scope: Atom.to_string(scope.share),
      scope_filter: ContextScope.to_filter(scope),
      delta: stringify_map(shared_payload)
    })
    |> Repo.insert()
  end

  # -- Promotion --------------------------------------------------------------

  defp append_promoted_memories(_agent_id, %ContextDelta{memory_updates: []}), do: {:ok, []}

  defp append_promoted_memories(agent_id, %ContextDelta{} = delta) do
    delta.memory_updates
    |> Enum.reduce_while({:ok, []}, fn memory_update, {:ok, acc} ->
      metadata =
        memory_update
        |> Map.get(:metadata, %{})
        |> Map.merge(%{
          "promoted_from_agent" => delta.from_agent,
          "promoted_from_session" => delta.from_session
        })

      case MemoryContext.append_memory(
             agent_id,
             Map.fetch!(memory_update, :memory_type),
             Map.fetch!(memory_update, :content),
             Keyword.new(memory_update)
             |> Keyword.put(:metadata, metadata)
           ) do
        {:ok, memory} -> {:cont, {:ok, acc ++ [memory]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_promotion(parent_session_id, %ContextDelta{} = delta) do
    %ContextShare{}
    |> ContextShare.changeset(%{
      from_session_id: delta.from_session,
      to_session_id: parent_session_id,
      scope: "custom",
      scope_filter: %{
        "direction" => "child_to_parent",
        "promotion" => true
      },
      delta: ContextDelta.to_map(delta)
    })
    |> Repo.insert()
  end

  # -- Helpers ----------------------------------------------------------------

  defp inheritance_depth(%Context{} = context) do
    case context.metadata["inheritance_depth"] || context.metadata[:inheritance_depth] do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp filter_by_keys(map, nil, nil), do: stringify_map(map)

  defp filter_by_keys(map, include_keys, exclude_keys) do
    map
    |> stringify_map()
    |> maybe_include_keys(include_keys)
    |> maybe_exclude_keys(exclude_keys)
  end

  defp maybe_include_keys(map, nil), do: map
  defp maybe_include_keys(_map, []), do: %{}
  defp maybe_include_keys(map, keys), do: Map.take(map, Enum.map(keys, &to_string/1))

  defp maybe_exclude_keys(map, nil), do: map
  defp maybe_exclude_keys(map, []), do: map
  defp maybe_exclude_keys(map, keys), do: Map.drop(map, Enum.map(keys, &to_string/1))

  defp serialize_memory_entry(%Memory{} = memory) do
    %{
      "id" => memory.id,
      "agent_id" => memory.agent_id,
      "memory_type" => memory.memory_type,
      "date" => if(memory.date, do: Date.to_iso8601(memory.date), else: nil),
      "content" => memory.content,
      "metadata" => stringify_map(memory.metadata),
      "inserted_at" => DateTime.to_iso8601(memory.inserted_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp serialize_memory_entry(memory) when is_map(memory), do: stringify_map(memory)

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_map(_other), do: %{}

  defp stringify_value(%Date{} = date), do: Date.to_iso8601(date)
  defp stringify_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp stringify_value(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp stringify_value(map) when is_map(map), do: stringify_map(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp stringify_value(value), do: value

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
