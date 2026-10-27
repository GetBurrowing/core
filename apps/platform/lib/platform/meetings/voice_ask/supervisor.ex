defmodule Platform.Meetings.VoiceAsk.Supervisor do
  @moduledoc """
  Holds the per-ask accumulators of `voice_ask_agent` (task 01a17b10 stage 4):
  a unique `Registry` keyed by ask id, and a `DynamicSupervisor` the
  accumulators start under on demand, `restart: :temporary`.

  Inert at boot (a Registry and an empty DynamicSupervisor), so it is a WEB
  child in `Platform.Role`: an accumulator only exists because a tool call on
  this node asked for one, and it acts only on its own state.
  """

  use Supervisor

  @registry Platform.Meetings.VoiceAsk.Registry
  @dynamic Platform.Meetings.VoiceAsk.AccumulatorSupervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: @registry},
        {DynamicSupervisor, strategy: :one_for_one, name: @dynamic}
      ],
      strategy: :one_for_all
    )
  end

  @doc "The Registry accumulators register under."
  def registry, do: @registry

  @doc "The DynamicSupervisor accumulators start under."
  def dynamic_supervisor, do: @dynamic
end
