defmodule Platform.Mail.Dispatch do
  @moduledoc """
  The audited send path (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 2).

  `dispatch/3` is the one way a draft becomes mail. In order:

    1. `Platform.Mail.Config.enabled?/0` false → `{:error, :mail_disabled}`.
       No row, nothing sent.
    2. The actor is checked: a user must be a non-external member of the
       draft's org (`Platform.Mail.can_use?/2`); the system may send; an agent
       may not (agents draft, people send).
    3. `(account, sender)` is resolved EXACTLY from the draft's
       `org_id + account_id + sender_key` with `Platform.Mail.resolve_sender/3`
       — never the org's first account, never a default sender.
    4. One committed transaction: `SELECT ... FOR UPDATE` on the account row
       (which serialises the rate-limit count across concurrent sends of that
       account), then the policy in order **send_enabled → internal-only →
       rate limit**, then the `mail_deliveries` row as `sending` (allowed) or
       `refused` with its reason, plus a `"platform.mail.dispatch"` audit
       event that references the delivery id and carries no body. Commit.
    5. Only after commit: `Platform.Mail.Deliverer.deliver/1` re-reads the row
       and talks to SMTP, recording `accepted` or `failed`.
    6. The draft becomes `dispatched` only on `accepted`.

  A refusal returns `{:error, {:refused, reason, delivery}}` where `reason` is
  `:send_disabled | {:external_recipients, [address]} | :rate_limited`. The
  refusal IS recorded; nothing reaches SMTP.

  Errors before the transaction (flag off, unauthorized actor, unresolvable
  account or sender, no recipients, unknown recipient user ids, a draft that
  is not a draft) record no row: nothing was attempted against an account.

  ## Internal

  `Platform.Mail.Internal.partition/2` against the ACCOUNT's org — exact,
  case-insensitive email equality with a non-external, non-archived member.
  No domain heuristic.

  ## Rate limit

  Per account: rows with status `queued | sending | accepted` inserted in the
  last 60 minutes, against `account.rate_limit_per_hour`, counted under the
  step-4 row lock. Refused and failed rows do not count. DB-derived, so it
  survives restarts and needs no process. `rate_usage/1` reports the same
  count.

  ## Transaction boundary

  `dispatch/3` refuses to run inside a caller's transaction
  (`{:error, :in_transaction}`): its audit row must be COMMITTED before SMTP
  is contacted, which an enclosing transaction would make false.

  `enqueue/3` (task 01a0cf21 stage 6) is the other half: the same steps and
  the same policy, for the system's deploy drafts, run INSIDE the caller's
  transaction, recording the row as `queued`. `Platform.Mail.Outbox` claims
  it after commit and calls `Platform.Mail.Deliverer.deliver/1`. Both share
  one row-writing function that never calls `Repo.rollback/1`, so a refusal
  inside the plan engine's transaction cannot abort the plan engine's work.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Audit
  alias Platform.Mail
  alias Platform.Mail.Account
  alias Platform.Mail.Config
  alias Platform.Mail.Deliverer
  alias Platform.Mail.Delivery
  alias Platform.Mail.Draft
  alias Platform.Mail.Internal
  alias Platform.Mail.Sender
  alias Platform.Repo

  @counted_statuses ~w(queued sending accepted)
  @in_flight_statuses ~w(queued sending accepted)
  @window_seconds 3600

  @type actor :: {:user, binary()} | {:agent, binary()} | {:system, nil} | User.t() | :system
  @type refusal :: :send_disabled | {:external_recipients, [String.t()]} | :rate_limited

  @doc """
  Send the draft `draft_id` as `actor`.

  Options:

    * `:on_behalf_of_user_id` — overrides the draft's value on the delivery row;
    * `:responsibility` — overrides the draft's value on the delivery row;
    * `:expected_updated_at` — the draft version the caller showed a person
      (the confirm pane). If the draft has changed since, nothing is
      recorded or sent and the result is `{:error, :draft_changed}`.

  Returns `{:ok, delivery}` (status `accepted`), `{:error, {:failed, error,
  delivery}}`, `{:error, {:refused, reason, delivery}}`, or a bare
  `{:error, reason}` when nothing was recorded.
  """
  @spec dispatch(binary(), actor(), keyword()) ::
          {:ok, Delivery.t()}
          | {:error, {:refused, refusal(), Delivery.t()}}
          | {:error, {:failed, String.t(), Delivery.t()}}
          | {:error, term()}
  def dispatch(draft_id, actor, opts \\ []) do
    with :ok <- enabled(),
         :ok <- outside_transaction(),
         {:ok, actor} <- normalize_actor(actor),
         {:ok, draft} <- fetch_draft(draft_id),
         :ok <- authorize(actor, draft.org_id),
         {:ok, {account, sender}} <-
           Mail.resolve_sender(draft.org_id, draft.account_id, draft.sender_key),
         {:ok, recipients} <- expand_recipients(draft),
         {:ok, delivery} <- record(draft, account, sender, recipients, actor, opts) do
      send_recorded(delivery, draft)
    end
  end

  @doc """
  Record a system draft's send as `queued`, for `Platform.Mail.Outbox` to
  hand to SMTP after the caller commits (task 01a0cf21 stage 6).

  This is the deploy path. `Platform.Deploy.dispatch/3` runs inside
  `PlanEngine.advance/2`'s transaction, so SMTP cannot be contacted here:
  this function runs the SAME steps as `dispatch/3` — flag, actor, exact
  `(account, sender)`, recipients, then the lock and the policy (send toggle
  → internal-only → rate limit), the snapshot row and the audit event — and
  inserts the row as `queued` instead of `sending`. It works inside the
  caller's transaction and never rolls it back: if the caller's transaction
  rolls back, neither the audit event nor the delivery row exists and the
  Outbox never sees it. Called outside a transaction it opens its own.

  Only `{:system, nil}` may enqueue, and only a draft the system created —
  there is no confirm pane on this path, so a person's or an agent's draft
  goes through `dispatch/3` and its confirm-time version check instead.

  Returns `{:ok, delivery}` (status `queued`), `{:error, {:refused, reason,
  delivery}}` (the refused row is written in the caller's transaction and
  commits with it), or `{:error, reason}` with nothing written.
  """
  @spec enqueue(binary(), actor(), keyword()) ::
          {:ok, Delivery.t()}
          | {:error, {:refused, refusal(), Delivery.t()}}
          | {:error, term()}
  def enqueue(draft_id, actor, opts \\ []) do
    with :ok <- enabled(),
         {:ok, {:system, nil} = actor} <- system_actor(actor),
         {:ok, draft} <- fetch_draft(draft_id),
         :ok <- system_drafted(draft),
         {:ok, {account, sender}} <-
           Mail.resolve_sender(draft.org_id, draft.account_id, draft.sender_key),
         {:ok, recipients} <- expand_recipients(draft),
         {:ok, delivery} <- record_queued(draft, account, sender, recipients, actor, opts) do
      case delivery do
        %Delivery{status: "refused"} ->
          {:error, {:refused, decode_refusal(delivery.refusal_reason), delivery}}

        %Delivery{status: "queued"} ->
          {:ok, delivery}
      end
    end
  end

  defp system_actor(actor) do
    case normalize_actor(actor) do
      {:ok, {:system, nil}} = ok -> ok
      {:ok, _other} -> {:error, :unauthorized}
      error -> error
    end
  end

  defp system_drafted(%Draft{created_by_type: "system"}), do: :ok
  defp system_drafted(%Draft{}), do: {:error, :unauthorized}

  defp record_queued(draft, account, sender, recipients, actor, opts) do
    if Repo.in_transaction?() do
      record_rows(draft, account, sender, recipients, actor, opts, "queued")
    else
      Repo.transaction(fn ->
        case record_rows(draft, account, sender, recipients, actor, opts, "queued") do
          {:ok, delivery} -> delivery
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Mark `draft_id` `dispatched` if it is still a draft. Called once a
  delivery of it is `accepted` — by `dispatch/3` and by
  `Platform.Mail.Outbox`.
  """
  @spec mark_dispatched(binary() | nil) :: :ok
  def mark_dispatched(nil), do: :ok

  def mark_dispatched(draft_id) when is_binary(draft_id) do
    from(d in Draft, where: d.id == ^draft_id and d.status == "draft")
    |> Repo.update_all(set: [status: "dispatched", updated_at: DateTime.utc_now()])

    :ok
  end

  @doc """
  `{used, limit}` for this account's rolling hour — the same count the rate
  limit is evaluated against.
  """
  @spec rate_usage(Account.t()) :: {non_neg_integer(), pos_integer()}
  def rate_usage(%Account{id: id} = account) do
    limit =
      case Repo.get(Account, id) do
        %Account{rate_limit_per_hour: limit} -> limit
        nil -> account.rate_limit_per_hour
      end

    {recent_count(id), limit}
  end

  # ── Steps ───────────────────────────────────────────────────────────────

  defp enabled do
    if Config.enabled?(), do: :ok, else: {:error, :mail_disabled}
  end

  defp outside_transaction do
    if Repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok
  end

  defp normalize_actor(%User{id: id}) when is_binary(id), do: {:ok, {:user, id}}
  defp normalize_actor({:user, id}) when is_binary(id), do: {:ok, {:user, id}}
  defp normalize_actor({:agent, id}) when is_binary(id), do: {:ok, {:agent, id}}
  defp normalize_actor(:system), do: {:ok, {:system, nil}}
  defp normalize_actor({:system, _}), do: {:ok, {:system, nil}}
  defp normalize_actor(_), do: {:error, :invalid_actor}

  defp fetch_draft(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %Draft{} = draft <- Repo.get(Draft, id) do
      if draft.status == "draft", do: {:ok, draft}, else: {:error, :draft_not_sendable}
    else
      _ -> {:error, :draft_not_found}
    end
  end

  defp fetch_draft(_), do: {:error, :draft_not_found}

  defp authorize({:user, id}, org_id) do
    if Mail.can_use?(%{id: id}, org_id), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize({:system, nil}, _org_id), do: :ok
  # Agents write drafts; a person (or the system, for deploys) sends them.
  defp authorize({:agent, _}, _org_id), do: {:error, :unauthorized}

  defp expand_recipients(%Draft{} = draft) do
    addresses =
      (draft.to_addresses || [])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    user_ids = Enum.uniq(draft.to_user_ids || [])

    with {:ok, user_emails} <- user_emails(user_ids) do
      recipients = Enum.uniq_by(addresses ++ user_emails, &String.downcase/1)
      if recipients == [], do: {:error, :no_recipients}, else: {:ok, recipients}
    end
  end

  defp user_emails([]), do: {:ok, []}

  defp user_emails(ids) do
    found =
      from(u in User, where: u.id in ^ids, select: {u.id, u.email})
      |> Repo.all()
      |> Map.new()

    case Enum.reject(ids, &Map.has_key?(found, &1)) do
      [] -> {:ok, Enum.map(ids, &Map.fetch!(found, &1))}
      missing -> {:error, {:unknown_recipient_user_ids, missing}}
    end
  end

  # The committed transaction: lock, policy, audit row, audit event.
  defp record(draft, %Account{} = account, %Sender{} = sender, recipients, actor, opts) do
    Repo.transaction(fn ->
      case record_rows(draft, account, sender, recipients, actor, opts, "sending") do
        {:ok, delivery} -> delivery
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Lock, policy, delivery row, audit event — in the CURRENT transaction.
  #
  # Never calls `Repo.rollback/1`: `enqueue/3` runs this inside a caller's
  # transaction (the plan engine's), where a rollback would abort the
  # caller's whole unit of work, not just this send. Every refusal is
  # decided before the first write, and both changesets are validated before
  # either insert, so an `{:error, _}` return has written nothing.
  # `dispatch/3`'s own transaction turns an error into a rollback.
  defp record_rows(
         draft,
         %Account{} = account,
         %Sender{} = sender,
         recipients,
         actor,
         opts,
         allowed
       ) do
    locked = lock_account!(account.id)

    with :ok <- not_archived(locked),
         {:ok, locked_draft} <- lock_draft(draft.id),
         :ok <- unchanged(locked_draft, draft, opts),
         :ok <- not_in_flight(draft.id) do
      refusal = policy(locked, recipients)
      id = Platform.Types.UUIDv7.generate()

      attrs = %{
        id: id,
        org_id: locked.org_id,
        account_id: locked.id,
        sender_key: sender.key,
        from_address: sender.address,
        recipients: recipients,
        subject: draft.subject,
        body: draft.body,
        actor_type: actor_type(actor),
        actor_id: actor_id(actor),
        drafted_by_type: draft.created_by_type,
        drafted_by_id: draft.created_by_id,
        on_behalf_of_user_id:
          Keyword.get(opts, :on_behalf_of_user_id, draft.on_behalf_of_user_id),
        responsibility: Keyword.get(opts, :responsibility, draft.responsibility),
        draft_id: draft.id,
        task_id: draft.task_id,
        stage_id: draft.stage_id,
        message_id_header: message_id(id, sender.address),
        status: if(refusal, do: "refused", else: allowed),
        refusal_reason: encode_refusal(refusal)
      }

      delivery_changeset = Delivery.insert_changeset(attrs)

      audit_changeset =
        Audit.Event.changeset(
          %Audit.Event{},
          audit_attrs(Ecto.Changeset.apply_changes(delivery_changeset), actor, refusal)
        )

      cond do
        not delivery_changeset.valid? ->
          {:error, delivery_changeset}

        not audit_changeset.valid? ->
          {:error, audit_changeset}

        true ->
          with {:ok, delivery} <- Repo.insert(delivery_changeset),
               {:ok, _event} <- Audit.record(audit_attrs(delivery, actor, refusal)) do
            {:ok, delivery}
          end
      end
    end
  end

  defp not_archived(%Account{archived_at: nil}), do: :ok
  defp not_archived(%Account{}), do: {:error, :account_archived}

  # What is recorded and sent is what the draft held when it was read
  # (recipients were expanded from it). An edit that landed in between, or
  # since the version the caller showed a person (`:expected_updated_at`),
  # refuses the send rather than mailing a body nobody reviewed (task
  # 01a0cf21 stage 5). With no `:expected_updated_at` — `enqueue/3`, which
  # has no confirm pane — only the first comparison applies.
  defp unchanged(%Draft{} = locked_draft, %Draft{} = draft, opts) do
    expected = Keyword.get(opts, :expected_updated_at, locked_draft.updated_at)

    if same_version?(locked_draft.updated_at, draft.updated_at) and
         same_version?(locked_draft.updated_at, expected),
       do: :ok,
       else: {:error, :draft_changed}
  end

  defp not_in_flight(draft_id) do
    if in_flight?(draft_id), do: {:error, :draft_in_flight}, else: :ok
  end

  defp send_recorded(%Delivery{status: "refused"} = delivery, _draft) do
    {:error, {:refused, decode_refusal(delivery.refusal_reason), delivery}}
  end

  defp send_recorded(%Delivery{status: "sending", id: id}, draft) do
    case Deliverer.deliver(id) do
      {:ok, %Delivery{status: "accepted"} = delivery} ->
        mark_dispatched(draft.id)
        {:ok, delivery}

      {:error, {:failed, _error, _delivery} = failed} ->
        {:error, failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Policy (order is the contract: send_enabled → internal-only → rate) ──

  defp policy(%Account{send_enabled: false}, _recipients), do: :send_disabled

  defp policy(%Account{} = account, recipients) do
    with nil <- internal_refusal(account, recipients),
         nil <- rate_refusal(account) do
      nil
    end
  end

  defp internal_refusal(%Account{internal_only: true, org_id: org_id}, recipients) do
    case Internal.external(org_id, recipients) do
      [] -> nil
      external -> {:external_recipients, external}
    end
  end

  defp internal_refusal(%Account{}, _recipients), do: nil

  defp rate_refusal(%Account{id: id, rate_limit_per_hour: limit}) do
    if recent_count(id) >= limit, do: :rate_limited, else: nil
  end

  defp recent_count(account_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

    from(d in Delivery,
      where:
        d.account_id == ^account_id and d.status in ^@counted_statuses and
          d.inserted_at > ^cutoff,
      select: count(d.id)
    )
    |> Repo.one()
  end

  # ── Locks ───────────────────────────────────────────────────────────────

  defp lock_account!(id) do
    from(a in Account, where: a.id == ^id, lock: "FOR UPDATE") |> Repo.one!()
  end

  defp lock_draft(id) do
    case from(d in Draft, where: d.id == ^id, lock: "FOR UPDATE") |> Repo.one() do
      %Draft{status: "draft"} = draft -> {:ok, draft}
      _ -> {:error, :draft_not_sendable}
    end
  end

  defp same_version?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_version?(a, b), do: a == b

  defp in_flight?(draft_id) do
    from(d in Delivery,
      where: d.draft_id == ^draft_id and d.status in ^@in_flight_statuses,
      select: 1
    )
    |> Repo.exists?()
  end

  # ── Encoding ────────────────────────────────────────────────────────────

  defp message_id(id, from_address) do
    domain = from_address |> String.split("@") |> List.last()
    "<#{id}@#{domain}>"
  end

  defp encode_refusal(nil), do: nil
  defp encode_refusal(:send_disabled), do: %{"code" => "send_disabled"}
  defp encode_refusal(:rate_limited), do: %{"code" => "rate_limited"}

  defp encode_refusal({:external_recipients, addresses}),
    do: %{"code" => "external_recipients", "addresses" => addresses}

  @doc false
  @spec decode_refusal(map() | nil) :: refusal() | nil
  def decode_refusal(%{"code" => "send_disabled"}), do: :send_disabled
  def decode_refusal(%{"code" => "rate_limited"}), do: :rate_limited

  def decode_refusal(%{"code" => "external_recipients", "addresses" => addresses}),
    do: {:external_recipients, addresses}

  def decode_refusal(_), do: nil

  defp actor_type({type, _}), do: Atom.to_string(type)
  defp actor_id({_type, id}), do: id

  defp audit_attrs(%Delivery{} = delivery, actor, refusal) do
    %{
      event_type: "platform.mail.dispatch",
      actor_type: actor_type(actor),
      actor_id: actor_id(actor),
      actor_org_id: delivery.org_id,
      resource_type: "mail_delivery",
      resource_id: delivery.id,
      action: delivery.status,
      metadata: %{
        "delivery_id" => delivery.id,
        "account_id" => delivery.account_id,
        "sender_key" => delivery.sender_key,
        "draft_id" => delivery.draft_id,
        "recipient_count" => length(delivery.recipients),
        "refusal_reason" => encode_refusal(refusal)
      }
    }
  end
end
