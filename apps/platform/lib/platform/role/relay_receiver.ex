defmodule Platform.Role.RelayReceiver do
  @moduledoc """
  The full node's end of `Platform.Role.Relay` (task 01a155a6 stage 3).
  BACKGROUND, so it starts under the full role only.

  Subscribes to `Platform.Role.Relay.topic/0` and re-executes every
  `{:role_relay, event, measurements, metadata}` a web peer broadcasts as
  `Platform.Role.Relay.twin(event)`. Only the consumers in
  `Platform.Role.Relay.consumers/0` attach to twins, so the audit, vault,
  chat, meetings and memory handlers never see a relayed event and a web
  node's write is recorded once, where it happened.

  An event outside `Platform.Role.Relay.events/0` is dropped and logged: a web
  peer on another branch may relay an event this node's consumers do not
  read.
  """

  use GenServer

  require Logger

  alias Platform.Role.Relay

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ok = Phoenix.PubSub.subscribe(Platform.PubSub, Relay.topic())
    {:ok, %{events: MapSet.new(Relay.events())}}
  end

  @impl true
  def handle_info({:role_relay, event, measurements, metadata}, state)
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    if MapSet.member?(state.events, event) do
      :telemetry.execute(Relay.twin(event), measurements, metadata)
    else
      Logger.warning("[Role.RelayReceiver] dropping unrelayed event #{inspect(event)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:__drain__, _from, state), do: {:reply, :ok, state}
end
