defmodule Platform.Mail.Inbound.Backfill do
  @moduledoc """
  One-off import of an account's older mail, quietly (task
  01a13ba5-42a7-7000-8f2b-4c63003f3f92 stage 1).

  The live poller (`Platform.Mail.Inbound`) records a cursor at a folder's
  current maximum UID on first contact and ingests nothing older. This module
  is the separate, admin-triggered path for "the last N days" (N in 1..30),
  started only through `Platform.Mail.start_backfill/4`, which owns the
  authorization, the window bound and the one-running-run lock.

  ## What one run does (`run/3`)

    1. Connects exactly as `Inbound.poll/2` does (the account's Vault-held
       IMAP secret, `Inbound.connect_params/2`).
    2. Folders: `Inbound.select_folders/2` (the live scope, special-use
       exclusions unchanged) MINUS every folder whose LIST flags carry
       `\\All`, EVEN WHEN CONFIGURED. Gmail's `[Gmail]/All Mail` holds every
       message including sent mail; the live path reads a configured `\\All`
       folder, the backfill never does. The live path is not changed.
    3. Per folder: `examine/2` ONLY. Nothing here selects, stores, copies,
       moves or expunges, and bodies come from `fetch_raw/2`, which uses
       `BODY.PEEK[]`, so `\\Seen` is never set.
    4. The folder's `Platform.Mail.FolderCursor` is read ONCE. No cursor
       (the live poller has not seen the folder yet) or a cursor whose
       UIDVALIDITY differs from EXAMINE's: the folder is skipped. Creating
       and resetting cursors is the live poller's job.
    5. UIDs = `uids_since(since_date)` filtered to `uid <= cursor.last_uid`.
       That snapshot bound is load-bearing: a UID above it belongs to the
       live poller. Without it, a message arriving during the run could be
       inserted quietly here first, and the live insert would then hit
       `ON CONFLICT DO NOTHING` and never post it.
    6. Each UID is fetched and stored with
       `Inbound.ingest(account, folder, uidvalidity, uid, raw, quiet: true)`:
       `ingest_source: "backfill"`, no chat post, no `"mail:inbound"`
       broadcast. The 32 KB body cap on rendering is unchanged.

  This module NEVER writes `mail_folder_cursors`: not create, not update, not
  reset. A backfill moves no cursor backwards or forwards.

  SINCE matches INTERNALDATE (when the server received the message) at day
  granularity in the server's time zone, not the Date header, so a message
  with a forged or old Date header is selected by when it actually arrived.

  ## Progress

  `total`, `imported` and `already_present` are written to the
  `Platform.Mail.BackfillRun` row after each folder's search, every 25
  messages, and at the end, each time followed by
  `{:mail_backfill_progress, %{run_id, account_id}}` (IDs only) on
  `topic/1`. A connect, search or fetch error ends the run `failed` with the
  counts so far; re-running is safe because the insert dedupes.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Mail.Account
  alias Platform.Mail.BackfillRun
  alias Platform.Mail.FolderCursor
  alias Platform.Mail.Inbound
  alias Platform.Repo

  @progress_every 25

  @doc "The PubSub topic progress for `account_id`'s backfills is broadcast on."
  @spec topic(binary()) :: String.t()
  def topic(account_id) when is_binary(account_id), do: "mail:backfill:" <> account_id

  @doc """
  Run `run` for `account` to completion in the calling process and return the
  final row. Options: `:client` (default `Inbound.configured_client/0`).
  Never raises: an unexpected error marks the run `failed`.
  """
  @spec run(Account.t(), BackfillRun.t(), keyword()) :: BackfillRun.t()
  def run(%Account{} = account, %BackfillRun{} = run, opts \\ []) do
    client = Keyword.get_lazy(opts, :client, &Inbound.configured_client/0)

    case import_all(client, account, run) do
      {:ok, state} -> finish(state, "done", nil)
      {:error, reason, state} -> finish(state, "failed", describe(reason))
    end
  rescue
    error in DBConnection.OwnershipError ->
      reraise error, __STACKTRACE__

    error ->
      Logger.warning(
        "[Mail.Backfill] run raised run_id=#{run.id} account_id=#{account.id} " <>
          "error=#{Exception.message(error)}"
      )

      finish(initial_state(run), "failed", "crashed")
  end

  # ── The run ─────────────────────────────────────────────────────────────

  defp initial_state(%BackfillRun{} = run) do
    %{
      run: run,
      total: run.total,
      imported: run.imported,
      already_present: run.already_present,
      folders: run.folders,
      skipped: run.skipped_folders,
      since: run.since_date,
      processed: 0
    }
  end

  defp import_all(client, account, run) do
    state = initial_state(run)

    with {:ok, password} <- secret(account),
         {:ok, conn} <- connect(client, account, password) do
      try do
        case client.list_folders(conn) do
          {:ok, listed} ->
            {folders, all_mail} = backfill_folders(account, listed)

            state = %{
              state
              | skipped: state.skipped ++ Enum.map(all_mail, &skip_entry(&1, "all-mail"))
            }

            Enum.reduce_while(folders, {:ok, state}, fn folder, {:ok, state} ->
              case import_folder(client, conn, account, folder, state) do
                {:ok, state} -> {:cont, {:ok, state}}
                {:error, reason, state} -> {:halt, {:error, reason, state}}
              end
            end)

          {:error, reason} ->
            {:error, {:list_failed, reason}, state}
        end
      after
        client.logout(conn)
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp secret(account) do
    case Platform.Mail.fetch_secret(account, :imap) do
      {:ok, password} -> {:ok, password}
      {:error, reason} -> {:error, {:secret_unavailable, reason}}
    end
  end

  defp connect(client, account, password) do
    case client.connect(Inbound.connect_params(account, password)) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  @doc false
  # Public for tests. The live scope minus every `\All` folder, configured
  # or not. Returns `{folders_to_read, all_mail_folders_skipped}`.
  @spec backfill_folders(Account.t(), [{String.t(), [String.t()]}]) ::
          {[String.t()], [String.t()]}
  def backfill_folders(%Account{} = account, listed) do
    flags_by_name = Map.new(listed, fn {name, flags} -> {name, flags} end)

    account
    |> Inbound.select_folders(listed)
    |> Enum.split_with(fn folder -> not all_mail?(Map.get(flags_by_name, folder, [])) end)
  end

  defp all_mail?(flags), do: Enum.any?(flags, &(String.downcase(to_string(&1)) == "\\all"))

  defp import_folder(client, conn, account, folder, state) do
    case client.examine(conn, folder) do
      {:ok, uidvalidity, _max_uid} ->
        # Read ONCE: this row is the snapshot bound for the whole folder.
        case Repo.one(
               from(c in FolderCursor, where: c.account_id == ^account.id and c.folder == ^folder)
             ) do
          nil ->
            {:ok, skip(state, folder, "not-yet-polled")}

          %FolderCursor{uidvalidity: ^uidvalidity, last_uid: snapshot} ->
            import_uids(client, conn, account, folder, uidvalidity, snapshot, state)

          %FolderCursor{} ->
            {:ok, skip(state, folder, "uidvalidity-changed")}
        end

      {:error, reason} ->
        Logger.warning(
          "[Mail.Backfill] examine failed run_id=#{state.run.id} " <>
            "folder=#{inspect(folder)} reason=#{inspect(reason)}"
        )

        {:ok, skip(state, folder, "examine-failed")}
    end
  end

  defp import_uids(client, conn, account, folder, uidvalidity, snapshot, state) do
    case client.uids_since(conn, state.since) do
      {:ok, found} ->
        uids = found |> Enum.filter(&(&1 <= snapshot)) |> Enum.uniq() |> Enum.sort()

        state =
          %{state | total: state.total + length(uids), folders: state.folders ++ [folder]}
          |> checkpoint()

        Enum.reduce_while(uids, {:ok, state}, fn uid, {:ok, state} ->
          case client.fetch_raw(conn, uid) do
            {:ok, raw} ->
              state =
                case Inbound.ingest(account, folder, uidvalidity, uid, raw, quiet: true) do
                  1 -> %{state | imported: state.imported + 1}
                  0 -> %{state | already_present: state.already_present + 1}
                end
                |> Map.update!(:processed, &(&1 + 1))
                |> maybe_checkpoint()

              {:cont, {:ok, state}}

            {:error, reason} ->
              {:halt, {:error, {:fetch_failed, folder, uid, reason}, state}}
          end
        end)

      {:error, reason} ->
        {:error, {:search_failed, folder, reason}, state}
    end
  end

  defp skip(state, folder, reason),
    do: %{state | skipped: state.skipped ++ [skip_entry(folder, reason)]}

  defp skip_entry(folder, reason), do: "#{folder} (#{reason})"

  # ── Progress ────────────────────────────────────────────────────────────

  defp maybe_checkpoint(%{processed: n} = state) when rem(n, @progress_every) == 0,
    do: checkpoint(state)

  defp maybe_checkpoint(state), do: state

  defp checkpoint(state) do
    run = write(state.run, progress_attrs(state))
    %{state | run: run}
  end

  defp finish(state, status, error) do
    attrs =
      state
      |> progress_attrs()
      |> Map.merge(%{status: status, error: error, finished_at: DateTime.utc_now()})

    write(state.run, attrs)
  end

  defp progress_attrs(state) do
    %{
      total: state.total,
      imported: state.imported,
      already_present: state.already_present,
      folders: state.folders,
      skipped_folders: state.skipped
    }
  end

  defp write(%BackfillRun{} = run, attrs) do
    updated =
      run
      |> BackfillRun.progress_changeset(attrs)
      |> Repo.update!()

    broadcast(updated)
    updated
  end

  # IDs only. A PubSub failure never changes the run's outcome.
  defp broadcast(%BackfillRun{} = run) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      topic(run.account_id),
      {:mail_backfill_progress, %{run_id: run.id, account_id: run.account_id}}
    )
  rescue
    _ -> :error
  end

  defp describe({:secret_unavailable, _}), do: "the IMAP password is unavailable"
  defp describe({:connect_failed, _}), do: "could not connect to the mail server"
  defp describe({:list_failed, _}), do: "the mail server did not list folders"
  defp describe({:search_failed, folder, _}), do: "search failed in #{folder}"
  defp describe({:fetch_failed, folder, uid, _}), do: "fetch failed in #{folder} at UID #{uid}"
  defp describe(other), do: inspect(other)
end
