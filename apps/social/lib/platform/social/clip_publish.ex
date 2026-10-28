defmodule Platform.Social.ClipPublish do
  @moduledoc """
  The server-side undo window of Clip Studio 2/9 (task 01a16662). A human's
  Posts retain their explicit `clip_render_id`, media and text from approval;
  sweeps, retries and undo never resolve the clip's latest render.

  `Platform.Social.ClipDecisions.approve_clip/5` writes one approved post per
  selected account with `publish_after` = the decision time + `window_ms/0`
  (8s). Nothing publishes before then; inside the window
  `undo_clip_decision/4` deletes the posts. This server publishes them once
  the window has closed. There is no client timer and no second approval.

  Core has no job runner (no Oban), so this is Social's, shaped like
  `Platform.Social.RateLimit`'s and `Platform.Social.PublishRetry`'s sweeps:

    * `schedule/2` arms a `Process.send_after/3` for the window's end;
    * after EVERY sweep the server re-arms one timer for the earliest
      clip post still waiting (`next_due/1`), so a due post never depends on
      the periodic sweep;
    * a periodic sweep every `interval_ms` and a boot sweep (when the server
      starts) pick up any due post a restart left behind. All state is in
      the database.

  ## The timer never fires early (stage 5 fix)

  The timer message carries the `publish_after` it was armed for, the delay
  is rounded UP to the next whole millisecond, and the sweep it triggers
  runs as of `max(now, publish_after)`. A timer that lands a few
  microseconds before `publish_after` (Erlang timers are millisecond
  grained) therefore still finds its posts due. Before this, a floored delay
  and a sweep at the wall clock could find nothing due, re-arm nothing, and
  leave the post to the periodic sweep (up to `interval_ms` late). The sweep
  still claims only posts whose `publish_after` is at or before that
  instant.

  One timer is kept: an earlier window replaces a later armed one, a later
  window waits for the re-arm after the earlier one fires.

  A post is due (`due/1`) when it has a `clip_id`, status `approved`,
  `publish_after <= now` and no `external_id`. Each due post is claimed and
  published in ONE transaction: a conditional `update_all` sets
  `publish_after = NULL` where the id matches and `publish_after <= now`
  (zero rows means another sweep or an undo got there first, so it is
  skipped), then `Platform.Social.Publishing.publish_post/2` runs its full
  guard. A crash rolls the claim back, so the post stays due. A refused or
  failed publish is not retried here: that belongs to the human retry path
  and `PublishRetry`.

  Config (`config :social, :clip_publish`): `window_ms` (8_000),
  `interval_ms` (the periodic sweep; `:infinity` sets none), `timers`
  (default true: arm window timers and re-arm after sweeps) and `boot_sweep`
  (default true). The test config sets `interval_ms: :infinity`,
  `timers: false` and `boot_sweep: false` for the application's instance;
  tests start their own with `start_supervised!/1` and either call
  `sweep_now/2` or pass `timers: true` and a `notify: pid`, which receives
  `{:clip_publish_swept, server_pid, results}` after every timer-driven
  sweep, once its re-arm is done.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Social.{Account, Post, Profile, Publishing}

  @default_window_ms 8_000
  @default_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The undo window in milliseconds (`config :social, :clip_publish, window_ms:`)."
  @spec window_ms() :: pos_integer()
  def window_ms, do: Keyword.get(config(), :window_ms, @default_window_ms)

  @doc """
  Arms a timer on `server` for `publish_after`, the end of the window of
  `post_ids`. Fire-and-forget: a server that is not running, or one with
  `interval_ms: :infinity`, arms nothing, and the next sweep (or the boot
  sweep) still finds the posts in the database.
  """
  @spec schedule([Ecto.UUID.t()], DateTime.t(), GenServer.server()) :: :ok
  def schedule(post_ids, %DateTime{} = publish_after, server \\ __MODULE__) do
    if post_ids != [], do: GenServer.cast(server, {:schedule, publish_after})
    :ok
  end

  @doc """
  Runs one sweep now, in the server, as of `now` (default the real clock),
  and answers `[{post_id, result}]` for every due post it claimed or skipped.
  """
  @spec sweep_now(GenServer.server(), DateTime.t() | nil) :: [{Ecto.UUID.t(), term()}]
  def sweep_now(server \\ __MODULE__, now \\ nil),
    do: GenServer.call(server, {:sweep_now, now}, :infinity)

  @doc "The clip posts due at `now`: `[{org_id, post_id}]`, oldest `publish_after` first."
  @spec due(DateTime.t()) :: [{Ecto.UUID.t(), Ecto.UUID.t()}]
  def due(%DateTime{} = now) do
    Repo.all(
      from(po in Post,
        join: a in Account,
        on: a.id == po.account_id,
        join: p in Profile,
        on: p.id == a.profile_id,
        where:
          not is_nil(po.clip_id) and po.status == "approved" and po.publish_after <= ^now and
            is_nil(po.external_id),
        order_by: [asc: po.publish_after, asc: po.id],
        select: {p.org_id, po.id}
      )
    )
  end

  @doc """
  Claims one post and publishes it, in one transaction. `{:ok, :skipped}`
  when the claim matched no row (already claimed, undone, or not yet due).
  """
  @spec publish_due(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: {:ok, term()}
  def publish_due(org_id, post_id, %DateTime{} = now) do
    Repo.transaction(fn ->
      case Repo.update_all(
             from(po in Post,
               where: po.id == ^post_id and po.publish_after <= ^now and po.status == "approved"
             ),
             set: [publish_after: nil]
           ) do
        {1, _} -> Publishing.publish_post(org_id, post_id)
        {0, _} -> :skipped
      end
    end)
  end

  # ── Server ───────────────────────────────────────────────────────────

  @doc """
  The earliest `publish_after` after `now` among clip posts still waiting
  (approved, not sent), or nil.
  """
  @spec next_due(DateTime.t()) :: DateTime.t() | nil
  def next_due(%DateTime{} = now) do
    Repo.one(
      from(po in Post,
        where:
          not is_nil(po.clip_id) and po.status == "approved" and po.publish_after > ^now and
            is_nil(po.external_id),
        select: min(po.publish_after)
      )
    )
  end

  @doc false
  # Milliseconds from `now` until `at`, rounded UP, never negative: a timer
  # armed with this never fires before `at` on a millisecond clock.
  @spec delay_ms(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def delay_ms(%DateTime{} = at, %DateTime{} = now) do
    case DateTime.diff(at, now, :microsecond) do
      us when us <= 0 -> 0
      us -> div(us + 999, 1000)
    end
  end

  @impl true
  def init(opts) do
    config = config()

    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, config[:interval_ms] || @default_interval_ms),
      boot_sweep: Keyword.get(opts, :boot_sweep, Keyword.get(config, :boot_sweep, true)),
      timers: Keyword.get(opts, :timers, Keyword.get(config, :timers, true)),
      notify: Keyword.get(opts, :notify),
      armed: nil
    }

    schedule_sweep(state)
    if state.boot_sweep, do: {:ok, state, {:continue, :boot_sweep}}, else: {:ok, state}
  end

  @impl true
  def handle_continue(:boot_sweep, state) do
    now = DateTime.utc_now()
    sweep(now)
    {:noreply, rearm(state, now)}
  end

  @impl true
  def handle_call({:sweep_now, now}, _from, state) do
    now = now || DateTime.utc_now()
    results = sweep(now)
    {:reply, results, rearm(state, latest(now, DateTime.utc_now()))}
  end

  @impl true
  def handle_cast({:schedule, publish_after}, state), do: {:noreply, arm(state, publish_after)}

  @impl true
  def handle_info({:window_closed, publish_after}, state) do
    # Never earlier than the window this timer was armed for.
    now = latest(DateTime.utc_now(), publish_after)
    results = sweep(now)
    # Re-arm first, then notify: a notified caller finds the server idle.
    state = rearm(%{state | armed: nil}, now)
    notify(state, results)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    now = DateTime.utc_now()
    results = sweep(now)
    schedule_sweep(state)
    state = rearm(state, now)
    notify(state, results)
    {:noreply, state}
  end

  # Keeps ONE timer, for the earliest window: a later window than the one
  # armed waits for the re-arm after that one fires.
  defp arm(%{timers: false} = state, _at), do: state
  defp arm(state, nil), do: state

  defp arm(%{armed: {armed_at, _ref}} = state, at) do
    if DateTime.compare(armed_at, at) != :gt, do: state, else: arm(cancel(state), at)
  end

  defp arm(state, %DateTime{} = at) do
    ref = Process.send_after(self(), {:window_closed, at}, delay_ms(at, DateTime.utc_now()))
    %{state | armed: {at, ref}}
  end

  defp cancel(%{armed: {_at, ref}} = state) do
    Process.cancel_timer(ref)
    %{state | armed: nil}
  end

  # After a sweep: arm for the earliest clip post still waiting, if any.
  defp rearm(%{timers: false} = state, _now), do: state

  defp rearm(state, now) do
    arm(state, next_due(now))
  rescue
    error ->
      Logger.warning("[Social.ClipPublish] re-arm failed: #{Exception.message(error)}")
      state
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp notify(%{notify: pid}, results) when is_pid(pid),
    do: send(pid, {:clip_publish_swept, self(), results})

  defp notify(_state, _results), do: :ok

  defp sweep(now) do
    for {org_id, post_id} <- due(now) do
      {post_id, publish_one(org_id, post_id, now)}
    end
  rescue
    error ->
      Logger.warning("[Social.ClipPublish] sweep failed: #{Exception.message(error)}")
      []
  end

  defp publish_one(org_id, post_id, now) do
    {:ok, result} = publish_due(org_id, post_id, now)
    result
  rescue
    error ->
      Logger.warning(
        "[Social.ClipPublish] post #{post_id} publish raised: #{Exception.message(error)}"
      )

      {:error, :raised}
  end

  defp schedule_sweep(%{interval_ms: :infinity}), do: :ok

  defp schedule_sweep(%{interval_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :sweep, ms)

  defp config, do: Application.get_env(:social, :clip_publish, [])
end
