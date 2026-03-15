defmodule Platform.Context.Cache do
  @moduledoc """
  ETS-backed hot cache for context sessions, items, deltas, and acks.

  ## ETS tables

  Four named ETS tables are created at process start and owned by this GenServer:

  | Table                          | Key shape                       | Value                    |
  |--------------------------------|---------------------------------|--------------------------|
  | `:ctx_sessions`                | `scope_key :: String.t()`       | `%Session{}`             |
  | `:ctx_items`                   | `{scope_key, item_key}`         | `%Item{}`                |
  | `:ctx_deltas`                  | `{scope_key, version}`          | `%Delta{}`               |
  | `:ctx_acks`                    | `{scope_key, run_id}`           | `version :: integer`     |

  All tables are `:public` so callers can read without a GenServer round-trip.
  Writes go through GenServer calls to keep version counters atomic.

  ## PubSub

  After each successful mutation, a delta is published to
  `Platform.PubSub` on topic `"ctx:<scope_key>"` as
  `{:context_delta, delta}`.
  """

  use GenServer

  alias Platform.Context.{Delta, Item, Session}

  @sessions_table :ctx_sessions
  @items_table :ctx_items
  @deltas_table :ctx_deltas
  @acks_table :ctx_acks

  # Maximum number of deltas kept per scope key before old ones are trimmed.
  @delta_history_limit 200

  # ---------------------------------------------------------------------------
  # Public API — reads (direct ETS, no GenServer hop)
  # ---------------------------------------------------------------------------

  @doc "Retrieves the live session for `scope_key`, or `{:error, :not_found}`."
  @spec get_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(scope_key) do
    case :ets.lookup(@sessions_table, scope_key) do
      [{^scope_key, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @doc "Returns all items for `scope_key`, sorted by key."
  @spec all_items(String.t()) :: [Item.t()]
  def all_items(scope_key) do
    :ets.select(@items_table, [
      {{{scope_key, :_}, :"$1"}, [], [:"$1"]}
    ])
    |> Enum.sort_by(& &1.key)
  end

  @doc "Returns a single item by `scope_key + item_key`, or `nil`."
  @spec get_item(String.t(), String.t()) :: Item.t() | nil
  def get_item(scope_key, item_key) do
    case :ets.lookup(@items_table, {scope_key, item_key}) do
      [{{^scope_key, ^item_key}, item}] -> item
      [] -> nil
    end
  end

  @doc "Returns all deltas for `scope_key` with version > `since_version`."
  @spec deltas_since(String.t(), non_neg_integer()) :: [Delta.t()]
  def deltas_since(scope_key, since_version) do
    :ets.select(@deltas_table, [
      {{{scope_key, :"$1"}, :"$2"}, [{:>, :"$1", since_version}], [:"$2"]}
    ])
    |> Enum.sort_by(& &1.version)
  end

  @doc "Returns the highest acknowledged version for `{scope_key, run_id}`, or `nil`."
  @spec get_ack(String.t(), String.t()) :: non_neg_integer() | nil
  def get_ack(scope_key, run_id) do
    case :ets.lookup(@acks_table, {scope_key, run_id}) do
      [{{^scope_key, ^run_id}, version}] -> version
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Public API — writes (via GenServer for atomicity)
  # ---------------------------------------------------------------------------

  @doc "Creates a new session for `scope`. Idempotent if session already exists."
  @spec create_session(Session.Scope.t()) :: {:ok, Session.t()}
  def create_session(%Session.Scope{} = scope) do
    GenServer.call(__MODULE__, {:create_session, scope})
  end

  @doc "Upserts an item in `scope_key`. Returns `{:ok, new_version}`."
  @spec put_item(String.t(), String.t(), term(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def put_item(scope_key, key, value, opts \\ []) do
    GenServer.call(__MODULE__, {:put_item, scope_key, key, value, opts})
  end

  @doc "Removes an item from `scope_key`. Returns `{:ok, new_version}`."
  @spec delete_item(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def delete_item(scope_key, key) do
    GenServer.call(__MODULE__, {:delete_item, scope_key, key})
  end

  @doc """
  Applies a `%Delta{}` to `scope_key`.

  Assigns the next version, applies all puts/deletes, records the delta, and
  publishes to PubSub.  Returns `{:ok, new_version}`.
  """
  @spec apply_delta(String.t(), Delta.t()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def apply_delta(scope_key, %Delta{} = delta) do
    GenServer.call(__MODULE__, {:apply_delta, scope_key, delta})
  end

  @doc "Records that `run_id` has acknowledged `version` in `scope_key`."
  @spec record_ack(String.t(), String.t(), non_neg_integer()) :: :ok | {:error, :not_found}
  def record_ack(scope_key, run_id, version) do
    GenServer.call(__MODULE__, {:record_ack, scope_key, run_id, version})
  end

  @doc "Removes all ETS rows for `scope_key`."
  @spec evict(String.t()) :: :ok
  def evict(scope_key) do
    GenServer.call(__MODULE__, {:evict, scope_key})
  end

  # ---------------------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    tables = [
      :ets.new(@sessions_table, [:named_table, :public, :set, read_concurrency: true]),
      :ets.new(@items_table, [:named_table, :public, :set, read_concurrency: true]),
      :ets.new(@deltas_table, [:named_table, :public, :set, read_concurrency: true]),
      :ets.new(@acks_table, [:named_table, :public, :set, read_concurrency: true])
    ]

    {:ok, %{tables: tables}}
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks — writes
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:create_session, scope}, _from, state) do
    {:ok, scope_key} = Session.scope_key(scope)

    session =
      case :ets.lookup(@sessions_table, scope_key) do
        [{^scope_key, existing}] ->
          existing

        [] ->
          new_session = Session.new(scope)
          :ets.insert(@sessions_table, {scope_key, new_session})
          new_session
      end

    {:reply, {:ok, session}, state}
  end

  def handle_call({:put_item, scope_key, key, value, opts}, _from, state) do
    case :ets.lookup(@sessions_table, scope_key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^scope_key, %Session{} = session}] ->
        {new_version, updated_session} = Session.bump_version(session)
        item = Item.new(key, value, new_version, opts)

        :ets.insert(@sessions_table, {scope_key, updated_session})
        :ets.insert(@items_table, {{scope_key, key}, item})

        # Record a delta for this single-put
        delta = %Delta{
          scope_key: scope_key,
          version: new_version,
          puts: %{key => {value, opts}},
          deletes: [],
          applied_at: item.inserted_at
        }

        persist_delta(scope_key, new_version, delta)
        broadcast(scope_key, delta)

        {:reply, {:ok, new_version}, state}
    end
  end

  def handle_call({:delete_item, scope_key, key}, _from, state) do
    case :ets.lookup(@sessions_table, scope_key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^scope_key, %Session{} = session}] ->
        {new_version, updated_session} = Session.bump_version(session)

        :ets.insert(@sessions_table, {scope_key, updated_session})
        :ets.delete(@items_table, {scope_key, key})

        delta = %Delta{
          scope_key: scope_key,
          version: new_version,
          puts: %{},
          deletes: [key],
          applied_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        }

        persist_delta(scope_key, new_version, delta)
        broadcast(scope_key, delta)

        {:reply, {:ok, new_version}, state}
    end
  end

  def handle_call({:apply_delta, scope_key, %Delta{} = delta}, _from, state) do
    case :ets.lookup(@sessions_table, scope_key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^scope_key, %Session{} = session}] ->
        {new_version, updated_session} = Session.bump_version(session)

        # Apply puts
        Enum.each(delta.puts, fn {key, {value, opts}} ->
          item = Item.new(key, value, new_version, opts)
          :ets.insert(@items_table, {{scope_key, key}, item})
        end)

        # Apply deletes
        Enum.each(delta.deletes, fn key ->
          :ets.delete(@items_table, {scope_key, key})
        end)

        %Delta{} = stamped_delta = %Delta{delta | scope_key: scope_key, version: new_version}

        :ets.insert(@sessions_table, {scope_key, updated_session})
        persist_delta(scope_key, new_version, stamped_delta)
        broadcast(scope_key, stamped_delta)

        {:reply, {:ok, new_version}, state}
    end
  end

  def handle_call({:record_ack, scope_key, run_id, version}, _from, state) do
    case :ets.lookup(@sessions_table, scope_key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^scope_key, _session}] ->
        :ets.insert(@acks_table, {{scope_key, run_id}, version})
        {:reply, :ok, state}
    end
  end

  def handle_call({:evict, scope_key}, _from, state) do
    :ets.delete(@sessions_table, scope_key)
    :ets.select_delete(@items_table, [{{{scope_key, :_}, :_}, [], [true]}])
    :ets.select_delete(@deltas_table, [{{{scope_key, :_}, :_}, [], [true]}])
    :ets.select_delete(@acks_table, [{{{scope_key, :_}, :_}, [], [true]}])
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp persist_delta(scope_key, version, delta) do
    :ets.insert(@deltas_table, {{scope_key, version}, delta})
    trim_old_deltas(scope_key)
  end

  defp trim_old_deltas(scope_key) do
    deltas =
      :ets.select(@deltas_table, [
        {{{scope_key, :"$1"}, :_}, [], [:"$1"]}
      ])
      |> Enum.sort(:desc)

    if length(deltas) > @delta_history_limit do
      to_drop = Enum.drop(deltas, @delta_history_limit)

      Enum.each(to_drop, fn v ->
        :ets.delete(@deltas_table, {scope_key, v})
      end)
    end
  end

  defp broadcast(scope_key, %Delta{} = delta) do
    Phoenix.PubSub.broadcast(Platform.PubSub, "ctx:#{scope_key}", {:context_delta, delta})
  end
end
