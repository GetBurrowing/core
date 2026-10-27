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

  @refusals :terminal_refusals
  @max_refusal_keys 10_000

  @doc """
  Create the refusal-window table. Called once from `Platform.Application`, whose
  start process owns it for the life of the app. No DB, nothing persisted.
  """
  def init_refusals do
    if :ets.whereis(@refusals) == :undefined do
      :ets.new(@refusals, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc "Forget every refusal window (tests)."
  def reset_refusals do
    if :ets.whereis(@refusals) != :undefined, do: :ets.delete_all_objects(@refusals)
    :ok
  end

  @doc """
  True when a refusal for `{actor_id, runtime_id, reason}` should be audited now:
  the first one inside a window. Later identical refusals inside it are dropped,
  so a client stuck in a rejoin loop, or a hostile one, cannot flood the audit
  log. The window is `:terminal_refusal_window_ms` (default 60 seconds). The
  decision is one atomic ETS step, so concurrent joins cannot both win.
  """
  def audit_refusal?(actor_id, runtime_id, reason) do
    # No table means the app did not start it; audit rather than lose a refusal.
    if :ets.whereis(@refusals) == :undefined do
      true
    else
      decide_refusal(actor_id, runtime_id, reason)
    end
  end

  defp decide_refusal(actor_id, runtime_id, reason) do
    now = System.monotonic_time(:millisecond)
    window = Application.get_env(:platform, :terminal_refusal_window_ms, 60_000)
    key = {actor_id, runtime_id, reason}

    if :ets.info(@refusals, :size) > @max_refusal_keys, do: sweep(now)

    cond do
      :ets.insert_new(@refusals, {key, now + window}) ->
        true

      # Replace an EXPIRED window; one caller can win this, never two.
      :ets.select_replace(@refusals, [
        {{key, :"$1"}, [{:"=<", :"$1", now}], [{{{:const, key}, now + window}}]}
      ]) == 1 ->
        true

      true ->
        false
    end
  end

  defp sweep(now) do
    :ets.select_delete(@refusals, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  @doc "Join-time plumbing for the view channel."
  def subscribe(session_id),
    do: Phoenix.PubSub.subscribe(Platform.PubSub, session_topic(session_id))

  @doc "Send a message to the other end(s) of the session, never to the caller."
  def relay(session_id, message),
    do: Phoenix.PubSub.broadcast_from(Platform.PubSub, self(), session_topic(session_id), message)
end
