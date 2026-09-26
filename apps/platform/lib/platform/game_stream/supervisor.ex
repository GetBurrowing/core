defmodule Platform.GameStream.Supervisor do
  @moduledoc """
  The process tree for live play sessions (task 01a0db5f stage 2): a
  `Registry` naming each `Platform.GameStream.Session` by `{:session, id}`
  and claiming its host by `{:host, runtime_id}`, and a `DynamicSupervisor`
  holding the sessions.

  Started unconditionally: with `GAME_STREAM_ENABLED` unset it holds no
  children and nothing ever asks it to start one, because every entry point
  in `Platform.GameStream` checks the flag first. Live state is ephemeral by
  design — a core restart ends every session, and the host idles its own
  process out.
  """

  use Supervisor

  @registry Platform.GameStream.Registry
  @sessions Platform.GameStream.SessionSupervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def registry, do: @registry

  @doc false
  def sessions, do: @sessions

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @sessions}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
