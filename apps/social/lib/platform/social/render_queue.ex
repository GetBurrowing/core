defmodule Platform.Social.RenderQueue do
  @moduledoc """
  Social's clip render queue (task 01a140a9-69b7, Social 5/7): a GenServer
  holding a FIFO of clip ids, running at most `config :social,
  :render_concurrency` (default 1, capped at 2) renders at once, each in a
  task under Social's own `Platform.Social.RenderTaskSupervisor` (core's
  `Platform.TaskSupervisor` is agent dispatch's, ADR 0027, and is not
  borrowed). Core has no job runner (no Oban), so this is Social's.

  `enqueue/1` is a cast: the caller (a tool call, a LiveView) returns at
  once and the render happens here, off the request path. The work itself
  is `Platform.Social.RenderJob.run/1`, which records success or failure on
  the clip. The queue MONITORS each task, so a task that crashes or is
  killed is recorded `failed` ("render crashed: ...") and the queue keeps
  serving.

  ## Restart

  On (re)start the queue first terminates any task still running under its
  task supervisor (those belonged to the queue that died), then looks for
  clips left in `rendering`: each with `attempts < 2` is re-enqueued once;
  the rest are failed with "render interrupted by a restart". Nothing is
  left stuck in `rendering`. Set `config :social, :render_recover_on_boot,
  false` to skip the scan (tests that own their own queue instance).
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Social.{Clip, RenderJob}

  @max_concurrency 2

  # ── API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @doc "Queues a clip for rendering. Returns at once."
  @spec enqueue(Ecto.UUID.t(), GenServer.server()) :: :ok
  def enqueue(clip_id, server \\ __MODULE__), do: GenServer.cast(server, {:enqueue, clip_id})

  @doc "`%{queued: [clip_id], running: [clip_id], concurrency: n}`."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "The effective concurrency from config (1..2)."
  @spec concurrency() :: pos_integer()
  def concurrency do
    case Application.get_env(:social, :render_concurrency, 1) do
      n when is_integer(n) and n >= 1 -> min(n, @max_concurrency)
      _ -> 1
    end
  end

  # ── Server ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      queue: :queue.new(),
      running: %{},
      task_supervisor: Keyword.get(opts, :task_supervisor, Platform.Social.RenderTaskSupervisor),
      concurrency: Keyword.get(opts, :concurrency) || concurrency(),
      job: Keyword.get(opts, :job, &RenderJob.run/1),
      recover?:
        Keyword.get(opts, :recover, Application.get_env(:social, :render_recover_on_boot, true))
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    orphans = stop_orphaned_tasks(state.task_supervisor)

    state =
      if state.recover? do
        recover(state)
      else
        state
      end

    if orphans > 0,
      do:
        Logger.info("[Social.RenderQueue] stopped #{orphans} render(s) left by a previous queue")

    {:noreply, drain(state)}
  end

  @impl true
  def handle_cast({:enqueue, clip_id}, state) do
    if queued_or_running?(state, clip_id) do
      {:noreply, state}
    else
      {:noreply, drain(%{state | queue: :queue.in(clip_id, state.queue)})}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       queued: :queue.to_list(state.queue),
       running: Map.values(state.running),
       concurrency: state.concurrency
     }, state}
  end

  # A task finished normally (its result is already on the clip).
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, drain(%{state | running: Map.delete(state.running, ref)})}
  end

  # A task crashed or was killed: record it, keep serving.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {clip_id, running} ->
        RenderJob.fail(clip_id, "render crashed: #{crash_reason(reason)}")
        {:noreply, drain(%{state | running: running})}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ────────────────────────────────────────────────────────

  defp drain(state) do
    if map_size(state.running) < state.concurrency do
      case :queue.out(state.queue) do
        {{:value, clip_id}, queue} ->
          job = state.job
          task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> job.(clip_id) end)
          drain(%{state | queue: queue, running: Map.put(state.running, task.ref, clip_id)})

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  defp queued_or_running?(state, clip_id),
    do: :queue.member(clip_id, state.queue) or clip_id in Map.values(state.running)

  defp stop_orphaned_tasks(sup) do
    case Process.whereis(sup) || (is_pid(sup) && sup) do
      pid when is_pid(pid) ->
        children = Task.Supervisor.children(pid)
        Enum.each(children, &Task.Supervisor.terminate_child(pid, &1))
        length(children)

      _ ->
        0
    end
  end

  defp recover(state) do
    stuck = Repo.all(from(c in Clip, where: c.status == "rendering", select: {c.id, c.attempts}))

    Enum.reduce(stuck, state, fn {id, attempts}, acc ->
      if (attempts || 0) < 2 do
        %{acc | queue: :queue.in(id, acc.queue)}
      else
        RenderJob.fail(id, "render interrupted by a restart")
        acc
      end
    end)
  rescue
    e ->
      Logger.warning("[Social.RenderQueue] boot recovery skipped: #{Exception.message(e)}")
      state
  end

  defp crash_reason({%{__exception__: true} = e, _stack}), do: Exception.message(e)
  defp crash_reason(:killed), do: "the render process was killed"
  defp crash_reason(:shutdown), do: "the render process was shut down"
  defp crash_reason({:shutdown, _}), do: "the render process was shut down"
  defp crash_reason(other), do: inspect(other)
end
