defmodule Platform.Federation.DispatchOrigin do
  @moduledoc """
  Where a runtime's recent dispatches came from, as the SERVER saw them
  (task 01a1b678 stage 4, the stage 3 audit fixes).

  A federated tool call carries only what the agent chose to send, so a
  tool that must know which space a request came from, or which person
  asked, cannot trust its arguments. This module remembers, per runtime,
  every chat attention `Platform.Federation.AttentionDispatch.broadcast/3`
  sent in the last `window_ms/0`: the space it named and the person who
  wrote the triggering message (`message.author_user_id`, read from the
  participant row by `Platform.Chat.AgentResponder`). `ToolCall.build_context/2`
  puts the answer on every handler context:

    * `:origin_space_ids` — every space a dispatch to this runtime named in
      the window, newest first;
    * `:requester_user_id` — the one person whose message reached this
      runtime in the window, or nil when there was none OR more than one.
      Nil is the fail-closed answer: a tool that needs a requester refuses
      rather than guess between two people.

  Rows are inserted, never updated (a `:duplicate_bag`), so concurrent
  dispatches cannot overwrite each other. ETS only; lost on restart by
  design, which also only ever narrows what a tool will allow.
  """

  use GenServer

  @table :federation_dispatch_origin
  @default_window_ms :timer.minutes(10)
  @sweep_interval_ms :timer.minutes(1)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "How long a dispatch counts, in ms (`config :platform, __MODULE__, window_ms`)."
  @spec window_ms() :: pos_integer()
  def window_ms do
    case Keyword.get(Application.get_env(:platform, __MODULE__, []), :window_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_window_ms
    end
  end

  @doc """
  Remember one attention to `runtime_id`. `payload` is the broadcast
  payload; only `message.author_user_id` (when `message.author_type` is
  `"user"`) is read from it. `space_id` is the option the dispatcher passed.
  Never raises.
  """
  @spec record(binary(), map(), binary() | nil) :: :ok
  def record(runtime_id, payload, space_id) when is_binary(runtime_id) and is_map(payload) do
    user_id = author_user_id(payload)

    if is_binary(space_id) or is_binary(user_id) do
      _ = :ets.insert(@table, {runtime_id, now(), uuid(space_id), user_id})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def record(_runtime_id, _payload, _space_id), do: :ok

  @doc "`%{origin_space_ids: [id], requester_user_id: id | nil}` for `runtime_id`."
  @spec lookup(binary() | nil) :: %{
          origin_space_ids: [binary()],
          requester_user_id: binary() | nil
        }
  def lookup(runtime_id) when is_binary(runtime_id) do
    cutoff = now() - window_ms()

    entries =
      @table
      |> :ets.lookup(runtime_id)
      |> Enum.filter(fn {_rid, at, _space, _user} -> at >= cutoff end)
      |> Enum.sort_by(fn {_rid, at, _space, _user} -> at end, :desc)

    users = entries |> Enum.map(&elem(&1, 3)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      origin_space_ids:
        entries |> Enum.map(&elem(&1, 2)) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      requester_user_id:
        case users do
          [one] -> one
          _ -> nil
        end
    }
  rescue
    ArgumentError -> empty()
  end

  def lookup(_runtime_id), do: empty()

  @doc false
  # Tests only: forget everything.
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :duplicate_bag, :public, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - window_ms()
    :ets.select_delete(@table, [{{:_, :"$1", :_, :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp empty, do: %{origin_space_ids: [], requester_user_id: nil}

  defp author_user_id(payload) do
    message = Map.get(payload, :message) || Map.get(payload, "message")

    case message do
      %{} ->
        type = Map.get(message, :author_type) || Map.get(message, "author_type")
        id = Map.get(message, :author_user_id) || Map.get(message, "author_user_id")
        if type == "user", do: uuid(id)

      _ ->
        nil
    end
  end

  defp uuid(value) do
    case Platform.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
