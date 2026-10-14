defmodule Platform.Mail do
  @moduledoc """
  The Email module's context: org-scoped mail accounts, their senders, and
  their Vault-held secrets (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6).

  The module as a whole is gated by `Platform.Mail.Config.enabled?/0`; this
  context stores and resolves configuration and does not itself send or read
  mail.

  ## Who may do what

    * `can_manage_accounts?/2` — add, edit, replace a secret, manage senders,
      archive. **Org admins only**: `Platform.Tenancy.org_admin?/2`, with no
      root-admin bypass.
    * `can_use?/2` — draft, send, read the module's Inbox/Sent/Refused. Any
      non-external member of the org.

  `start_backfill/4` and `latest_backfill/2` (the one-off import of older
  mail, task 01a13ba5-42a7-7000-8f2b-4c63003f3f92) use the manage gate, as
  the Inbox Refresh does.

  Every mutating function here takes the actor and re-checks. A LiveView
  that hides a button is presentation; the check in this module is the
  authorization. An unauthorized call returns `{:error, :unauthorized}` and
  writes nothing.

  ## Secrets

  Neither `mail_accounts` nor `mail_senders` has a secret column. The SMTP
  and IMAP passwords are Vault credentials at slug `"mail:<account_id>:smtp"`
  / `"mail:<account_id>:imap"` and scope `{:integration, account.id}`, and are
  read with `Platform.Vault.get_unique/2` — which refuses an ambiguous slug —
  passing that exact scope and the integration-owner accessor
  `{:integration, account.id}`. Platform scope is deliberately not used: any
  accessor may read a platform-scoped credential.

  ## Resolving a sender

  `resolve_sender/3` returns the exact `(account, sender)` pair named by
  `(org_id, account_id, sender_key)` or a named refusal. It never picks a
  default account and never falls back to the account's first sender.
  """

  import Ecto.Query

  alias Platform.Mail.Account
  alias Platform.Mail.BackfillRun
  alias Platform.Mail.Inbound.Backfill
  alias Platform.Mail.Sender
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Vault

  @secret_kinds [:smtp, :imap]

  @type secret_kind :: :smtp | :imap
  @type resolve_error ::
          :account_not_found | :account_wrong_org | :account_archived | :sender_key_not_found

  # ── Authorization ───────────────────────────────────────────────────────

  @doc """
  May `user` add, edit, replace secrets on, or archive mail accounts of
  `org_id`? Exactly `Platform.Tenancy.org_admin?/2` — nothing else.
  """
  @spec can_manage_accounts?(any(), any()) :: boolean()
  def can_manage_accounts?(user, org_id), do: Tenancy.org_admin?(user, org_id)

  @doc """
  May `user` use the Email module for `org_id` (draft, send, read)? Any
  non-external membership in that org.
  """
  @spec can_use?(any(), any()) :: boolean()
  def can_use?(user, org_id), do: Tenancy.internal_member?(user, org_id)

  # ── Reads ───────────────────────────────────────────────────────────────

  @doc "Non-archived accounts of `org_id`, by name, with senders preloaded."
  @spec list_accounts(binary()) :: [Account.t()]
  def list_accounts(org_id) when is_binary(org_id) do
    if Platform.UUID.valid?(org_id) do
      from(a in Account,
        where: a.org_id == ^org_id and is_nil(a.archived_at),
        order_by: [asc: a.name],
        preload: [senders: ^from(s in Sender, order_by: [asc: s.key])]
      )
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  The account `id` IF it belongs to `org_id` (archived or not), else `nil`.
  An account of another org is `nil` here, never returned.
  """
  @spec get_account(binary(), binary()) :: Account.t() | nil
  def get_account(org_id, id) when is_binary(org_id) and is_binary(id) do
    with true <- Platform.UUID.valid?(org_id),
         true <- Platform.UUID.valid?(id),
         %Account{org_id: ^org_id} = account <- Repo.get(Account, id) do
      Repo.preload(account, senders: from(s in Sender, order_by: [asc: s.key]))
    else
      _ -> nil
    end
  end

  def get_account(_, _), do: nil

  @doc """
  Resolve the exact `(account, sender)` pair for a send.

  Refusals, checked in this order:

    * `:account_not_found` — no account has that id (or it is not a UUID);
    * `:account_wrong_org` — the account exists but belongs to another org;
    * `:account_archived` — the account is archived;
    * `:sender_key_not_found` — the account has no sender with that key.

  Never falls back to a default account or to the account's first sender.
  """
  @spec resolve_sender(any(), any(), any()) ::
          {:ok, {Account.t(), Sender.t()}} | {:error, resolve_error()}
  def resolve_sender(org_id, account_id, sender_key) do
    with {:ok, account} <- fetch_account_by_id(account_id),
         :ok <- same_org(account, org_id),
         :ok <- not_archived(account),
         {:ok, sender} <- fetch_sender(account, sender_key) do
      {:ok, {account, sender}}
    end
  end

  defp fetch_account_by_id(account_id) when is_binary(account_id) do
    with true <- Platform.UUID.valid?(account_id),
         %Account{} = account <- Repo.get(Account, account_id) do
      {:ok, account}
    else
      _ -> {:error, :account_not_found}
    end
  end

  defp fetch_account_by_id(_), do: {:error, :account_not_found}

  defp same_org(%Account{org_id: org_id}, org_id) when is_binary(org_id), do: :ok
  defp same_org(_account, _org_id), do: {:error, :account_wrong_org}

  defp not_archived(%Account{archived_at: nil}), do: :ok
  defp not_archived(_), do: {:error, :account_archived}

  defp fetch_sender(%Account{id: account_id}, key) when is_binary(key) do
    case Repo.get_by(Sender, account_id: account_id, key: key) do
      %Sender{} = sender -> {:ok, sender}
      nil -> {:error, :sender_key_not_found}
    end
  end

  defp fetch_sender(_account, _key), do: {:error, :sender_key_not_found}

  @doc """
  Read an account's SMTP or IMAP secret from the Vault.

  Always `Vault.get_unique/2` with the exact scope `{:integration, id}` and the
  integration-owner accessor — an ambiguous slug is refused, never guessed.

  `{:ok, value}` is returned ONLY when `value` is a non-empty string. The
  Vault answers `{:ok, :error}` for a credential that no longer decrypts (a
  dev boot without `VAULT_MASTER_KEY` mints a new key every time), and that
  is `{:error, :secret_unavailable}` here: every caller fails closed on it, so
  no SMTP send and no IMAP login ever happens without the credential
  (task 01a0cf21 stage 7).
  """
  @spec fetch_secret(Account.t(), secret_kind()) ::
          {:ok, binary()}
          | {:error,
             :not_configured
             | :not_found
             | :ambiguous_slug
             | :access_denied
             | :secret_unavailable}
  def fetch_secret(%Account{} = account, kind) when kind in @secret_kinds do
    case secret_slug_field(account, kind) do
      nil -> {:error, :not_configured}
      slug -> account |> vault_read(slug) |> usable_secret()
    end
  end

  defp vault_read(account, slug), do: Vault.get_unique(slug, vault_opts(account))

  defp usable_secret({:ok, value}) when is_binary(value) and value != "", do: {:ok, value}
  defp usable_secret({:ok, _undecryptable_or_empty}), do: {:error, :secret_unavailable}
  defp usable_secret({:error, reason}), do: {:error, reason}

  @doc "The Vault slug an account's `kind` secret is stored under."
  @spec secret_slug(binary(), secret_kind()) :: String.t()
  def secret_slug(account_id, kind) when is_binary(account_id) and kind in @secret_kinds,
    do: "mail:#{account_id}:#{kind}"

  @doc "The Vault scope every secret of this account lives at."
  @spec secret_scope(Account.t() | binary()) :: {:integration, binary()}
  def secret_scope(%Account{id: id}), do: {:integration, id}
  def secret_scope(id) when is_binary(id), do: {:integration, id}

  # ── Mutations (actor re-checked in every one) ──────────────────────────

  @doc """
  Create an account in `org_id`, storing any given secrets in the Vault.

  `secrets` is a map with optional `:smtp` / `:imap` binary values (string
  keys accepted). Blank values are ignored. The account row and its Vault
  credentials are written in one transaction.
  """
  @spec create_account(any(), binary(), map(), map()) ::
          {:ok, Account.t()} | {:error, :unauthorized | Ecto.Changeset.t() | term()}
  def create_account(actor, org_id, attrs, secrets \\ %{}) do
    if can_manage_accounts?(actor, org_id) do
      id = Platform.Types.UUIDv7.generate()
      secrets = normalize_secrets(secrets)

      changeset =
        %Account{id: id, org_id: org_id}
        |> Account.changeset(attrs)
        |> Ecto.Changeset.change(
          smtp_secret_slug: if(Map.has_key?(secrets, :smtp), do: secret_slug(id, :smtp)),
          imap_secret_slug: if(Map.has_key?(secrets, :imap), do: secret_slug(id, :imap))
        )

      Repo.transaction(fn ->
        account = insert_or_rollback(changeset)

        Enum.each(secrets, fn {kind, value} ->
          case put_secret(account, kind, value) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

        Repo.preload(account, :senders)
      end)
      |> case do
        {:ok, account} ->
          # Starts the IMAP poller for a read-enabled account, after the
          # commit so it never sees an uncommitted or rolled-back row. A no-op
          # when the module flag is off.
          _ = Platform.Mail.Inbound.sync_poller(account)
          {:ok, account}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc "Update an account's editable settings. Refused for an archived account."
  @spec update_account(any(), Account.t(), map()) ::
          {:ok, Account.t()} | {:error, :unauthorized | :account_archived | Ecto.Changeset.t()}
  def update_account(actor, %Account{} = account, attrs) do
    with :ok <- authorize_manage(actor, account),
         :ok <- not_archived(account),
         {:ok, updated} <- account |> Account.changeset(attrs) |> Repo.update() do
      # Starts or stops the IMAP poller on a read toggle (stage 3). A no-op
      # when the module flag is off.
      _ = Platform.Mail.Inbound.sync_poller(updated)
      {:ok, updated}
    end
  end

  @doc """
  Replace (or first set) the account's `:smtp` or `:imap` secret.

  An existing credential is rotated in place with `Vault.rotate/3` at the
  account's exact scope; a missing one is created and its slug recorded on
  the row.
  """
  @spec replace_secret(any(), Account.t(), secret_kind(), binary()) ::
          {:ok, Account.t()} | {:error, term()}
  def replace_secret(actor, %Account{} = account, kind, value)
      when kind in @secret_kinds and is_binary(value) and value != "" do
    with :ok <- authorize_manage(actor, account),
         :ok <- not_archived(account) do
      slug = secret_slug(account.id, kind)

      Repo.transaction(fn ->
        case Vault.rotate(slug, value, vault_opts(account)) do
          {:ok, _} ->
            :ok

          {:error, :not_found} ->
            case put_secret(account, kind, value) do
              {:ok, _} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end

        account
        |> Ecto.Changeset.change(%{slug_field(kind) => slug})
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end
  end

  def replace_secret(_actor, %Account{}, _kind, _value), do: {:error, :invalid_secret}

  @doc """
  Poll every reading account of `org_id` now (the inbox Refresh button).

  Refused unless `actor` may manage the org's accounts. Each eligible
  account (`Platform.Mail.Inbound.eligible?/1`) is polled through
  `Platform.Mail.Inbound.poll_now/2`; the result pairs each account with its
  `{:ok, summary}` or `{:error, reason}`, in account-name order.
  """
  @spec refresh_inbound(any(), binary()) ::
          {:ok, [{Account.t(), {:ok, map()} | {:error, term()}}]} | {:error, :unauthorized}
  def refresh_inbound(actor, org_id) do
    if can_manage_accounts?(actor, org_id) do
      results =
        org_id
        |> list_accounts()
        |> Enum.filter(&Platform.Mail.Inbound.eligible?/1)
        |> Task.async_stream(&{&1, Platform.Mail.Inbound.poll_now(&1)},
          max_concurrency: 4,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, pair} -> pair end)

      {:ok, results}
    else
      {:error, :unauthorized}
    end
  end

  # ── Backfill (task 01a13ba5-42a7-7000-8f2b-4c63003f3f92) ───────────────

  @backfill_max_days 30
  @backfill_stale_seconds 600

  @doc """
  Import the last `window_days` days of `account`'s mail, quietly (see
  `Platform.Mail.Inbound.Backfill`): rows land in the Inbox with
  `ingest_source: "backfill"`, nothing is posted to chat, nothing is
  broadcast on `"mail:inbound"`, and no folder cursor moves.

  Refusals, in this order, each writing nothing:

    * `:unauthorized` — `actor` may not manage the account's org
      (`can_manage_accounts?/2`, the Refresh gate);
    * `:not_eligible` — `Platform.Mail.Inbound.eligible?/1` is false;
    * `:invalid_window` — `window_days` is not an integer in
      1..#{@backfill_max_days} (refused, never clamped);
    * `:already_running` — the account has a running backfill (the partial
      unique index, so this holds across nodes).

  A `running` row whose `updated_at` is more than #{div(@backfill_stale_seconds, 60)} minutes
  old (a node restarted mid-run) is first marked `failed` with error
  `"interrupted"`, so a crash never locks an account out.

  Options: `:runner` — `:task` (default; the run proceeds under
  `Platform.TaskSupervisor` and this returns the `running` row) or `:inline`
  (the run completes in the caller and this returns the final row; tests);
  `:client` — the IMAP client module.
  """
  @spec start_backfill(any(), Account.t(), any(), keyword()) ::
          {:ok, BackfillRun.t()}
          | {:error, :unauthorized | :not_eligible | :invalid_window | :already_running}
  def start_backfill(actor, %Account{} = account, window_days \\ @backfill_max_days, opts \\ []) do
    with :ok <- authorize_manage(actor, account),
         %Account{} = account <- Repo.get(Account, account.id),
         :ok <- backfill_eligible(account),
         :ok <- valid_window(window_days) do
      reap_stale_backfills(account.id)

      %{
        account_id: account.id,
        org_id: account.org_id,
        requested_by_user_id: actor_id(actor),
        window_days: window_days,
        since_date: Date.add(Date.utc_today(), -window_days),
        started_at: DateTime.utc_now()
      }
      |> BackfillRun.start_changeset()
      |> Repo.insert()
      |> case do
        {:ok, run} ->
          launch_backfill(account, run, opts)

        {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          if Keyword.has_key?(errors, :account_id),
            do: {:error, :already_running},
            else: raise(Ecto.InvalidChangesetError, action: :insert, changeset: changeset)
      end
    else
      nil -> {:error, :unauthorized}
      {:error, _} = error -> error
    end
  end

  @doc """
  The account's most recent backfill run, or nil. Org admins only (the
  manage gate, not `can_use?/2`): any other actor gets nil, as if no run
  existed. A stale `running` row is reaped first, so a run interrupted by a
  restart reads as failed rather than running forever.
  """
  @spec latest_backfill(any(), Account.t()) :: BackfillRun.t() | nil
  def latest_backfill(actor, %Account{} = account) do
    case authorize_manage(actor, account) do
      :ok ->
        reap_stale_backfills(account.id)

        Repo.one(
          from(r in BackfillRun,
            where: r.account_id == ^account.id,
            order_by: [desc: r.inserted_at, desc: r.id],
            limit: 1
          )
        )

      {:error, _} ->
        nil
    end
  end

  @doc """
  Subscribe the caller to `account_id`'s backfill progress:
  `{:mail_backfill_progress, %{run_id, account_id}}` (IDs only; re-read the
  row with `latest_backfill/2`).
  """
  @spec subscribe_backfill(binary()) :: :ok | {:error, term()}
  def subscribe_backfill(account_id) when is_binary(account_id),
    do: Phoenix.PubSub.subscribe(Platform.PubSub, Backfill.topic(account_id))

  defp backfill_eligible(account),
    do: if(Platform.Mail.Inbound.eligible?(account), do: :ok, else: {:error, :not_eligible})

  defp valid_window(days) when is_integer(days) and days >= 1 and days <= @backfill_max_days,
    do: :ok

  defp valid_window(_), do: {:error, :invalid_window}

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_), do: nil

  defp reap_stale_backfills(account_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@backfill_stale_seconds, :second)
    now = DateTime.utc_now()

    from(r in BackfillRun,
      where: r.account_id == ^account_id and r.status == "running" and r.updated_at < ^cutoff
    )
    |> Repo.update_all(
      set: [status: "failed", error: "interrupted", finished_at: now, updated_at: now]
    )

    :ok
  end

  defp launch_backfill(account, run, opts) do
    case Keyword.get(opts, :runner, :task) do
      :inline ->
        {:ok, Backfill.run(account, run, opts)}

      :task ->
        case Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
               run_backfill_task(account, run, opts)
             end) do
          {:ok, _pid} ->
            {:ok, run}

          {:error, reason} ->
            {:ok,
             run
             |> BackfillRun.progress_changeset(%{
               status: "failed",
               error: "could not start: #{inspect(reason)}",
               finished_at: DateTime.utc_now()
             })
             |> Repo.update!()}
        end
    end
  end

  # The supervised child. `Backfill.run/3` handles every ordinary failure
  # itself; an OwnershipError means a test's sandbox owner is gone and there
  # is nothing left to record.
  defp run_backfill_task(account, run, opts) do
    Backfill.run(account, run, opts)
  rescue
    DBConnection.OwnershipError -> :ok
  end

  @doc "Archive an account. Idempotent for an already-archived account."
  @spec archive_account(any(), Account.t()) :: {:ok, Account.t()} | {:error, term()}
  def archive_account(actor, %Account{} = account) do
    with :ok <- authorize_manage(actor, account) do
      case account.archived_at do
        nil ->
          with {:ok, archived} <-
                 account
                 |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
                 |> Repo.update() do
            _ = Platform.Mail.Inbound.sync_poller(archived)
            {:ok, archived}
          end

        _ ->
          {:ok, account}
      end
    end
  end

  @doc "Create or update the sender with `attrs[\"key\"]` on this account."
  @spec put_sender(any(), Account.t(), map()) ::
          {:ok, Sender.t()} | {:error, :unauthorized | :account_archived | Ecto.Changeset.t()}
  def put_sender(actor, %Account{} = account, attrs) do
    with :ok <- authorize_manage(actor, account),
         :ok <- not_archived(account) do
      key = attrs[:key] || attrs["key"]

      existing = is_binary(key) && Repo.get_by(Sender, account_id: account.id, key: key)

      case existing do
        %Sender{} = sender -> sender |> Sender.changeset(attrs) |> Repo.update()
        _ -> %Sender{account_id: account.id} |> Sender.changeset(attrs) |> Repo.insert()
      end
    end
  end

  @doc "Delete the sender `key` from this account."
  @spec delete_sender(any(), Account.t(), String.t()) ::
          {:ok, Sender.t()} | {:error, :unauthorized | :sender_key_not_found}
  def delete_sender(actor, %Account{} = account, key) do
    with :ok <- authorize_manage(actor, account),
         {:ok, sender} <- fetch_sender(account, key) do
      Repo.delete(sender)
    end
  end

  @doc """
  Send a test email from `account`'s sender `sender_key` to the acting user's
  own address, THROUGH `Platform.Mail.Dispatch.dispatch/3` with
  responsibility `"mail_account_test"` (task 01a0cf21 stage 4).

  There is no bypass: the send toggle, internal-only and the rate limit all
  apply exactly as to any other send, and the attempt is recorded as a
  delivery. Org admins only.

  Returns what `dispatch/3` returned, or `{:error, :unauthorized |
  :no_address}` before anything is recorded. A test draft that did not end
  `accepted` is marked `discarded`, so it never sits in Drafts.
  """
  @spec send_test(any(), Account.t(), String.t()) ::
          {:ok, Platform.Mail.Delivery.t()} | {:error, term()}
  def send_test(actor, %Account{} = account, sender_key) do
    with :ok <- authorize_manage(actor, account),
         {:ok, address} <- actor_address(actor) do
      {:ok, draft} =
        %Platform.Mail.Draft{}
        |> Platform.Mail.Draft.changeset(%{
          org_id: account.org_id,
          account_id: account.id,
          sender_key: sender_key,
          to_addresses: [address],
          subject: "Test email from Suite",
          body:
            "This is a test email sent from the Email module to check the account " <>
              "#{account.name}. No reply is needed.",
          created_by_type: "user",
          created_by_id: actor.id,
          on_behalf_of_user_id: actor.id,
          responsibility: "mail_account_test"
        })
        |> Repo.insert()

      result =
        Platform.Mail.Dispatch.dispatch(draft.id, actor, responsibility: "mail_account_test")

      case result do
        {:ok, _delivery} ->
          result

        _ ->
          from(d in Platform.Mail.Draft, where: d.id == ^draft.id and d.status == "draft")
          |> Repo.update_all(set: [status: "discarded", updated_at: DateTime.utc_now()])

          result
      end
    end
  end

  defp actor_address(%{email: email}) when is_binary(email) and email != "", do: {:ok, email}
  defp actor_address(_), do: {:error, :no_address}

  # ── Private ─────────────────────────────────────────────────────────────

  # Re-reads the org from the account row the caller handed in, so a stale
  # or forged struct cannot move authority to another org: the check is
  # against the persisted org_id.
  defp authorize_manage(actor, %Account{id: id}) do
    case Repo.get(Account, id) do
      %Account{org_id: org_id} ->
        if can_manage_accounts?(actor, org_id), do: :ok, else: {:error, :unauthorized}

      nil ->
        {:error, :unauthorized}
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, account} -> account
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp put_secret(%Account{} = account, kind, value) do
    Vault.put(secret_slug(account.id, kind), :custom, value,
      scope: secret_scope(account),
      name: "Mail #{kind} secret (#{account.name})",
      provider: "mail",
      metadata: %{"mail_account_id" => account.id, "kind" => to_string(kind)}
    )
  end

  defp vault_opts(%Account{} = account) do
    [scope: secret_scope(account), accessor: secret_scope(account)]
  end

  defp secret_slug_field(%Account{smtp_secret_slug: slug}, :smtp), do: slug
  defp secret_slug_field(%Account{imap_secret_slug: slug}, :imap), do: slug

  defp slug_field(:smtp), do: :smtp_secret_slug
  defp slug_field(:imap), do: :imap_secret_slug

  defp normalize_secrets(secrets) when is_map(secrets) do
    Enum.reduce(@secret_kinds, %{}, fn kind, acc ->
      case Map.get(secrets, kind) || Map.get(secrets, to_string(kind)) do
        value when is_binary(value) and value != "" -> Map.put(acc, kind, value)
        _ -> acc
      end
    end)
  end

  defp normalize_secrets(_), do: %{}
end
