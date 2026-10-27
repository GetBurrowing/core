defmodule Platform.Terminal do
  @moduledoc """
  The remote terminal relay's shared pieces (task 01a17b17, protocol v1).

  The relay is a dumb pipe. The agent's machine and the owner's browser hold
  the keys and core only moves sealed frames between them. Nothing in
  `Platform.Terminal` or the terminal channels stores a frame or looks inside
  one, and a guard test keeps it that way.

  The "terminal CLI present" registry doubles as the opt-in signal: the CLI
  joins only when its owner started it with the terminal switched on.
  """

  @registry Platform.Terminal.Registry

  @doc false
  def registry, do: @registry

  @doc "The per-session PubSub topic. The id is random and known to two channels."
  def session_topic(session_id) when is_binary(session_id), do: "terminal_session:" <> session_id

  @doc "A fresh, unguessable session id."
  def new_session_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  @doc """
  Mark the calling process as the terminal CLI channel for `runtime_id`.
  Several can be registered at once (a reconnect races its predecessor); the
  newest wins.
  """
  def register_cli(runtime_id) when is_binary(runtime_id) do
    {:ok, _} = Registry.register(@registry, runtime_id, System.monotonic_time())
    :ok
  end

  @doc "True when a terminal CLI is joined for the runtime."
  def cli_present?(runtime_id) when is_binary(runtime_id), do: cli_pid(runtime_id) != nil

  @doc "The newest registered terminal CLI channel process, or nil."
  def cli_pid(runtime_id) when is_binary(runtime_id) do
    @registry
    |> Registry.lookup(runtime_id)
    |> Enum.filter(fn {pid, _} -> Process.alive?(pid) end)
    |> Enum.max_by(fn {_pid, at} -> at end, fn -> nil end)
    |> case do
      {pid, _} -> pid
      nil -> nil
    end
  end

  @doc "Join-time plumbing for the view channel."
  def subscribe(session_id),
    do: Phoenix.PubSub.subscribe(Platform.PubSub, session_topic(session_id))

  @doc "Send a message to the other end(s) of the session, never to the caller."
  def relay(session_id, message),
    do: Phoenix.PubSub.broadcast_from(Platform.PubSub, self(), session_topic(session_id), message)
end
