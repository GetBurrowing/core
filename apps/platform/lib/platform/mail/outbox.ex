defmodule Platform.Mail.Outbox do
  @moduledoc """
  Hands `queued` deliveries to SMTP after the transaction that queued them
  has committed (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 6).

  `Platform.Mail.Dispatch.enqueue/3` records a send as `queued` inside a
  caller's transaction — the email deploy strategy runs inside
  `PlanEngine.advance/2`'s — so nothing there may talk to SMTP. This process
  does, on a short tick (`:tick_ms`, default 5 s) and on a PubSub nudge
  (`nudge/0`).

  ## The claim is the only claim

  `run_once/1` claims in ONE committed statement pair: `SELECT ... FOR
  UPDATE SKIP LOCKED` over `queued` rows, then `queued → sending` on exactly
  those ids (still conditioned on `status = 'queued'`). Only the claimer
  holds the ids it flipped, and `Platform.Mail.Deliverer.deliver/1` refuses
  any row that is not `sending`, so two ticks — on one node or two — cannot
  both deliver a row: the second either skips the locked rows or finds them
  already `sending`. `Deliverer` stays the one Swoosh call site.

  ## Deploy stages

  A delivery that carries a `stage_id` and responsibility `"task_deploy"`
  resolves that stage's `test_pass` validation — `passed` on `accepted`,
  `failed` with the error on `failed` — but only while the validation is
  still `pending`, so a late or repeated result never flips a verdict
  someone else already recorded.

  ## Startup

  Started by `Platform.Application.maybe_add_mail_outbox/1` only when
  `Platform.Mail.Config.enabled?/0`. `run_once/1` is public so a test can
  drive a tick in its own process (the recording test adapter reports to
  the calling process).
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Platform.Mail.Deliverer
  alias Platform.Mail.Delivery
  alias Platform.Mail.Dispatch
  alias Platform.Repo
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Validation

  @topic "mail:outbox"
  @default_tick_ms 5_000
  @default_batch 20
  # A nudge sent from inside a transaction arrives before the commit; one
  # short re-check picks the row up without waiting for the next tick.
  @nudge_recheck_ms 1_000
  @deploy_responsibility "task_deploy"

  @type result :: %{
          delivery_id: binary(),
          status: String.t()
        }

  # ── Public API ──────────────────────────────────────────────────────────

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Ask the running Outbox (if any) to claim queued rows now."
  @spec nudge() :: :ok
  def nudge do
    Phoenix.PubSub.broadcast(Platform.PubSub, @topic, :mail_outbox_nudge)
  end

  @doc """
  One tick in the CALLING process: claim up to `:batch` queued rows, deliver
  each, and resolve deploy validations. Returns one entry per claimed row.
  """
  @spec run_once(keyword()) :: [result()]
  def run_once(opts \\ []) do
    batch = Keyword.get(opts, :batch, @default_batch)

    batch
    |> claim()
    |> Enum.map(&deliver_claimed/1)
  end

  @doc """
  Claim up to `batch` `queued` rows: one committed transaction that locks
  them `FOR UPDATE SKIP LOCKED` and flips them to `sending`. Returns the
  claimed ids.
  """
  @spec claim(pos_integer()) :: [binary()]
  def claim(batch \\ @default_batch) do
    {:ok, ids} =
      Repo.transaction(fn ->
        ids =
          from(d in Delivery,
            where: d.status == "queued",
            order_by: [asc: d.inserted_at],
            limit: ^batch,
            lock: "FOR UPDATE SKIP LOCKED",
            select: d.id
          )
          |> Repo.all()

        {_count, claimed} =
          from(d in Delivery,
            where: d.id in ^ids and d.status == "queued",
            select: d.id
          )
          |> Repo.update_all(set: [status: "sending", updated_at: DateTime.utc_now()])

        claimed
      end)

    ids
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
    Phoenix.PubSub.subscribe(Platform.PubSub, @topic)
    Process.send_after(self(), :tick, tick_ms)
    {:ok, %{tick_ms: tick_ms}}
  end

  @impl true
  def handle_info(:tick, state) do
    safe_run()
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(:mail_outbox_nudge, state) do
    safe_run()
    Process.send_after(self(), :recheck, @nudge_recheck_ms)
    {:noreply, state}
  end

  def handle_info(:recheck, state) do
    safe_run()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp safe_run do
    run_once()
  rescue
    e -> Logger.error("[Mail.Outbox] tick crashed: " <> Exception.message(e))
  catch
    :exit, reason -> Logger.error("[Mail.Outbox] tick exited: #{inspect(reason)}")
  end

  # ── Delivery + deploy reporting ─────────────────────────────────────────

  defp deliver_claimed(id) do
    case Deliverer.deliver(id) do
      {:ok, %Delivery{status: "accepted"} = delivery} ->
        Dispatch.mark_dispatched(delivery.draft_id)
        report(delivery, "passed", nil)
        %{delivery_id: id, status: "accepted"}

      {:error, {:failed, error, %Delivery{} = delivery}} ->
        report(delivery, "failed", error)
        %{delivery_id: id, status: "failed"}

      {:error, reason} ->
        Logger.warning("[Mail.Outbox] delivery #{id} not attempted: #{inspect(reason)}")
        %{delivery_id: id, status: "not_attempted"}
    end
  end

  defp report(
         %Delivery{stage_id: stage_id, responsibility: @deploy_responsibility} = delivery,
         status,
         error
       )
       when is_binary(stage_id) do
    case pending_test_pass(stage_id) do
      %Validation{id: vid} ->
        evidence =
          %{
            "delivery_id" => delivery.id,
            "account_id" => delivery.account_id,
            "sender_key" => delivery.sender_key,
            "from_address" => delivery.from_address,
            "recipient_count" => length(delivery.recipients),
            "source_task_id" => delivery.task_id
          }
          |> then(fn e ->
            if status == "passed",
              do: Map.put(e, "smtp_response", delivery.smtp_response),
              else: Map.merge(e, %{"reason" => "smtp_failed", "error" => error})
          end)

        _ =
          PlanEngine.evaluate_validation(vid, %{
            status: status,
            evidence: evidence,
            evaluated_by: "platform.deploy.email"
          })

        :ok

      nil ->
        :ok
    end
  end

  defp report(%Delivery{}, _status, _error), do: :ok

  defp pending_test_pass(stage_id) do
    from(v in Validation,
      where: v.stage_id == ^stage_id and v.kind == "test_pass" and v.status == "pending",
      limit: 1
    )
    |> Repo.one()
  end
end
