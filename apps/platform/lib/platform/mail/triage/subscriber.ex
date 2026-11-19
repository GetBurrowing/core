defmodule Platform.Mail.Triage.Subscriber do
  @moduledoc """
  Triages each newly ingested email as it lands, so a `top` one reaches its
  reader between briefings (task 01a1f426 stage 3). The same shape as the
  experimentation layer's mail subscriber (task 01a0d415 stage 3), which
  Mail does not name:

    * `init/1` subscribes (`Platform.Mail.Inbound.subscribe/0`) and THEN
      continues into `Platform.Mail.Triage.reconcile/1`, so nothing ingested
      between the reconcile query and the subscription is lost. The unique
      (inbound, reader) index and the `notified_at` claim absorb the second
      path to reach a row.
    * Each event runs `Platform.Mail.Triage.on_inbound/2` under
      `Platform.TaskSupervisor`, so a slow model call or a crash never
      touches this process or `Inbound.ingest/5`.

  The event payload is ids only; the work reads the row itself. Everything
  that decides who is told (eligibility, the backfill skip, the dedupe, the
  daily push cap) lives in `Platform.Mail.Triage`. Nothing here sends mail.

  Started by `Platform.Application.maybe_add_mail_triage_subscriber/1`
  behind `:start_mail_triage_subscriber` (false in `config/test.exs`; tests
  `start_supervised/1` it) and only while `Platform.Mail.Config.enabled?/0`.
  """

  use GenServer

  require Logger

  alias Platform.Mail.{Inbound, Triage}

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
    run(state, fn -> Triage.reconcile() end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:mail_inbound_ingested, %{id: id}}, state) when is_binary(id) do
    run(state, fn -> Triage.on_inbound(id) end)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp run(%{task_supervisor: sup}, fun) do
    work = fn ->
      try do
        fun.()
      rescue
        e in DBConnection.OwnershipError ->
          Logger.warning("[Mail.Triage.Subscriber] no db ownership: #{inspect(e.__struct__)}")
      end
    end

    case Task.Supervisor.start_child(sup, work) do
      {:ok, _pid} ->
        :ok

      other ->
        Logger.warning("[Mail.Triage.Subscriber] could not start task: #{inspect(other)}")
        :error
    end
  end
end
