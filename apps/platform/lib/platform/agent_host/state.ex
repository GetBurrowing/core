defmodule Platform.AgentHost.State do
  @moduledoc """
  OBSERVED state of native agents, as the install's agent host last reported
  it (task 01a10322 stage 2). ETS, ephemeral, rebuilt from `host.inventory`
  every time a host joins.

  Desired state lives in Postgres (`agent_runtimes.desired_state`) because a
  person chose it. Observed state lives here because it is only ever a copy of
  what the host says: when the host goes away the copy is wrong, so the table
  is cleared rather than left to look authoritative.

  One row per agent:

      {agent_id, %{state: observed(), detail: String.t() | nil,
                   files_applied: term(), profile: String.t() | nil,
                   observed_at: DateTime.t()}}

  There is deliberately no login page or login code here (task 01a17b10): a
  `needs_login` agent is a state and a step name only. Burrow never relays or
  handles a Claude login; a human logs in at the agent's own pane.

  plus one `{:__host__, %{profile, connected_at}}` row for the connected host.

  The table is created by `Platform.AgentHost.Reconciler`, which owns it for
  its lifecycle. Reads run in the caller's process.
  """

  @table :platform_agent_host_state
  @host_key :__host__

  @observed ~w(starting running stopped crashed needs_login)a

  @type observed :: :starting | :running | :stopped | :crashed | :needs_login
  @type entry :: %{
          state: observed(),
          detail: String.t() | nil,
          files_applied: term(),
          files_drifted: [String.t()] | nil,
          profile: String.t() | nil,
          observed_at: DateTime.t()
        }

  @doc false
  def table, do: @table

  @doc "Create the table. Called once, by the Reconciler, which owns it."
  @spec init_table() :: :ok
  def init_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc "Every state an agent can be observed in."
  @spec observed_states() :: [observed()]
  def observed_states, do: @observed

  @doc """
  Parse a state string sent by the host. Unknown strings are refused rather
  than turned into atoms.
  """
  @spec parse_state(term()) :: {:ok, observed()} | :error
  def parse_state(value) when is_atom(value) and value in @observed, do: {:ok, value}

  def parse_state(value) when is_binary(value) do
    case Enum.find(@observed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      state -> {:ok, state}
    end
  end

  def parse_state(_), do: :error

  @doc "The observed entry for `agent_id`, or nil when nothing has been reported."
  @spec get(binary()) :: entry() | nil
  def get(agent_id) when is_binary(agent_id) do
    case safe_lookup(agent_id) do
      [{^agent_id, entry}] -> entry
      _ -> nil
    end
  end

  @doc "Every observed agent entry, keyed by agent id."
  @spec all() :: %{binary() => entry()}
  def all do
    if :ets.whereis(@table) == :undefined do
      %{}
    else
      @table
      |> :ets.tab2list()
      |> Enum.reject(fn {key, _} -> key == @host_key end)
      |> Map.new()
    end
  end

  @doc "Record one agent's observed state."
  @spec put(binary(), observed(), map()) :: entry()
  def put(agent_id, state, attrs \\ %{}) when is_binary(agent_id) and state in @observed do
    entry = %{
      state: state,
      detail: Map.get(attrs, :detail),
      files_applied: Map.get(attrs, :files_applied),
      files_drifted: Map.get(attrs, :files_drifted),
      profile: Map.get(attrs, :profile) || host_profile(),
      observed_at: Map.get(attrs, :observed_at) || DateTime.utc_now()
    }

    :ets.insert(@table, {agent_id, entry})
    entry
  end

  @doc "Record the connected host."
  @spec put_host(map()) :: :ok
  def put_host(host) when is_map(host) do
    :ets.insert(@table, {@host_key, host})
    :ok
  end

  @doc "The connected host's record, or nil."
  @spec host() :: map() | nil
  def host do
    case safe_lookup(@host_key) do
      [{@host_key, host}] -> host
      _ -> nil
    end
  end

  @doc "Forget everything: the host is gone, so nothing here is true any more."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Forget every agent row but keep the host row (before an inventory)."
  @spec clear_agents() :: :ok
  def clear_agents do
    if :ets.whereis(@table) != :undefined do
      :ets.select_delete(@table, [{{:"$1", :_}, [{:"=/=", :"$1", @host_key}], [true]}])
    end

    :ok
  end

  defp host_profile do
    case host() do
      %{profile: profile} -> profile
      _ -> nil
    end
  end

  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end
end
