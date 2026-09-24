defmodule Platform.Experiments.Signals.MailSubscriber do
  @moduledoc """
  Listens for `Platform.Mail.Inbound`'s ingest event and hands each new
  inbound id to `Platform.Experiments.Signals.MailSource`. Task 01a0d415
  stage 3, the experimentation-layer ADR-0052.

  This is the half of the Mail → Experiments seam that lives on the
  Experiments side: Mail publishes `{:mail_inbound_ingested, %{id, ...}}` on
  `"mail:inbound"` and knows nothing about this process.

    * `init/1` subscribes (`Platform.Mail.Inbound.subscribe/0`) and THEN
      continues into `MailSource.reconcile/0`, so nothing ingested between the
      reconcile query and the subscription is lost — a row broadcast during
      reconcile is labelled once by whichever path reaches it first, and the
      idempotency index absorbs the other.
    * Each event runs `MailSource.on_inbound/1` under
      `Platform.TaskSupervisor`, so a labeler crash or a slow model call never
      touches this process or `ingest/5`.

  Started by `Platform.Application.maybe_add_experiments_mail_subscriber/1`
  behind `:start_experiments_mail_subscriber` (false in `config/test.exs`;
  tests `start_supervised/1` it inside their own sandbox).
  """

  use GenServer

  require Logger

  alias Platform.Experiments.Signals.MailSource
  alias Platform.Mail.Inbound

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    :ok = Inbound.subscribe()

    state = %{task_supervisor: Keyword.get(opts, :task_supervisor, Platform.TaskSupervisor)}

    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    run(state, fn -> MailSource.reconcile() end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:mail_inbound_ingested, %{id: id}}, state) when is_binary(id) do
    run(state, fn -> MailSource.on_inbound(id) end)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp run(%{task_supervisor: sup}, fun) do
    case Task.Supervisor.start_child(sup, fun) do
      {:ok, _pid} ->
        :ok

      other ->
        Logger.warning("[Experiments.MailSubscriber] could not start task: #{inspect(other)}")
        :error
    end
  end
end
