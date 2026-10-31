defmodule Platform.Installs.HandoverMail do
  @moduledoc """
  The requester's ONE hand-over email when their install is ready (task
  01a18f0c stage 4).

  ## What the email carries

  The hand-over PAGE link, `https://<control host>/install-status/<token>`,
  not a raw sign-in link: bundled pocket-id is passkey-only and its one-time
  sign-in link dies 30 minutes after minting, usually before a stranger
  reads the email. The page mints a fresh sign-in link each time it is
  opened (`Platform.Installs.reveal_handover/1`) and stops revealing anything
  once the requester ticks "I've saved these" or 7 days pass
  (`Platform.Installs.expire_handovers/1`).

  ## Order of operations (`deliver_ready/1`)

  1. Claim with a compare-and-swap on `handover_email_claimed_at` (a ready
     install that came from a request, never claimed). Count 0 answers
     `{:ok, :already_claimed}`. This is what makes it one email, from the
     runner and the hourly sweeper alike, across restarts; it mirrors the
     nil-guarded CAS in `Platform.Meetings.InviteDelivery`.
  2. Read `config :platform, Platform.Installs, mail_sender:`
     (`BURROW_INSTALLS_MAIL_*`). Unconfigured, or mail disabled: RELEASE the
     claim and answer `{:error, :not_configured}`. A branch that sends
     nothing releases its claim, so a later sweep sends once configured.
  3. In ONE transaction: mint a new status token (the provision-time one
     was discarded), create the system draft and queue it through
     `Platform.Mail.Dispatch.enqueue/3`, the audited path
     `Platform.Mail.Outbox` delivers after commit; then store
     `handover_email_delivery_id` (also for a `refused` delivery, which is
     recorded and not retried). Any other failure rolls all of it back and
     releases the claim.

  ## The credential never reaches a log

  The token, the URL and the body are never passed to Logger, `inspect`, a
  PubSub payload, `steps` or an audit event. The draft and delivery inserts
  run with `log: false` (Ecto's :debug line prints the body). Logged lines
  carry the install id and an outcome code only.
  """

  import Ecto.Query

  require Logger

  alias Platform.Installs
  alias Platform.Installs.Install
  alias Platform.Mail
  alias Platform.Repo

  @no_query_log [log: false]
  @sender_keys [:org_id, :account_id, :sender_key]

  @doc """
  Send the hand-over email for the install `id` if it is owed. Returns
  `{:ok, :queued | :refused}`, `{:ok, :already_claimed}` (sent before, being
  sent, or not owed: not ready or not from a request), or
  `{:error, :not_configured | term()}` with the claim released.
  """
  @spec deliver_ready(term()) :: {:ok, atom()} | {:error, term()}
  def deliver_ready(id) do
    if Platform.UUID.valid?(id), do: claim_and_send(id), else: {:ok, :already_claimed}
  end

  @doc """
  `deliver_ready/1` for every ready install from a request whose email is
  still unclaimed. Run by `Platform.Installs.Sweeper`. Returns how many it
  queued.
  """
  @spec deliver_pending() :: non_neg_integer()
  def deliver_pending do
    from(i in Install,
      where:
        i.status == "ready" and not is_nil(i.requested_at) and
          is_nil(i.handover_email_claimed_at),
      select: i.id
    )
    |> Repo.all()
    |> Enum.count(&match?({:ok, :queued}, deliver_ready(&1)))
  end

  defp claim_and_send(id) do
    {claimed, _} =
      from(i in Install,
        where:
          i.id == ^id and i.status == "ready" and not is_nil(i.requested_at) and
            is_nil(i.handover_email_claimed_at)
      )
      |> Repo.update_all([set: [handover_email_claimed_at: DateTime.utc_now()]], @no_query_log)

    if claimed == 1, do: send_claimed(id), else: {:ok, :already_claimed}
  end

  defp send_claimed(id) do
    with {:ok, sender} <- sender(),
         {:ok, {status, _delivery_id}} <-
           Repo.transaction(fn -> compose_and_queue(id, sender) end, @no_query_log) do
      Logger.info("[installs] hand-over email for #{id}: #{status}")
      {:ok, status}
    else
      {:error, reason} ->
        release(id)

        Logger.warning(
          "[installs] hand-over email for #{id} not sent: #{Installs.reason_code(reason)}"
        )

        {:error, reason}
    end
  end

  defp compose_and_queue(id, sender) do
    install =
      Repo.one!(from(i in Install, where: i.id == ^id, lock: "FOR UPDATE"), @no_query_log)

    token = Installs.mint_status_token(install)

    attrs = %{
      account_id: sender.account_id,
      sender_key: sender.sender_key,
      to_addresses: [install.owner_email],
      subject: "Your Burrow is ready",
      body: body(install, token),
      responsibility: "installs.ready_handover"
    }

    delivery =
      with {:ok, draft} <- Mail.Drafts.create_system(sender.org_id, attrs, log: false),
           {:ok, delivery} <- Mail.Dispatch.enqueue(draft.id, :system, log: false) do
        delivery
      else
        {:error, {:refused, _reason, delivery}} -> delivery
        {:error, reason} -> Repo.rollback(reason)
      end

    Installs.update!(Installs.get(id), %{handover_email_delivery_id: delivery.id})
    {String.to_existing_atom(delivery.status), delivery.id}
  end

  defp release(id) do
    from(i in Install, where: i.id == ^id)
    |> Repo.update_all([set: [handover_email_claimed_at: nil]], @no_query_log)
  end

  defp sender do
    sender =
      case Keyword.get(Application.get_env(:platform, Installs, []), :mail_sender) do
        map when is_map(map) -> map
        _ -> %{}
      end

    configured? =
      Enum.all?(@sender_keys, fn key ->
        value = Map.get(sender, key)
        is_binary(value) and String.trim(value) != ""
      end)

    if configured? and Mail.Config.enabled?(),
      do: {:ok, Map.take(sender, @sender_keys)},
      else: {:error, :not_configured}
  end

  @doc false
  # The deterministic plain-text body. No model call, no time promise.
  def body(%Install{} = install, token) do
    """
    Hi #{install.requester_name},

    Your Burrow for #{install.business_name} is ready: https://#{install.primary_host}

    Your sign-in details are on this page, shown once: #{handover_url(token)}. It gives you a one-time sign-in link for #{install.owner_email}. Save what it shows, then tick "I've saved these".

    After you sign in, the first screen is "Connect your AI", where you pick the AI your Burrow uses.

    This page stops working once you've saved your details, or after 7 days.

    #{signoff()}
    """
  end

  # "Burrow, from <operator>": the operator is this control install's root
  # org, read from the database rather than written into the tree.
  defp signoff do
    case Platform.Tenancy.get_root_org() do
      %{name: name} when is_binary(name) and name != "" -> "Burrow, from #{name}"
      _ -> "Burrow"
    end
  end

  defp handover_url(token), do: PlatformWeb.Endpoint.url() <> "/install-status/" <> token
end
