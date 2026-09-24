defmodule Platform.Mail.Inbound do
  @moduledoc """
  Read-only IMAP ingestion for mail accounts (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 3). IMAP only; there is no POP.

  ## Polling, not IDLE (v1)

  One `Platform.Mail.Inbound.Poller` per account with `read_enabled` and an
  `imap_host` polls every `config :platform, Platform.Mail.Inbound, poll_ms:`
  (default 60_000). IMAP IDLE is deferred. Pollers exist only under
  `Platform.Mail.Inbound.Supervisor`, which the application starts only when
  `Platform.Mail.Config.enabled?/0`; with the flag off no IMAP connection is
  ever opened.

  ## One poll (`poll/2`)

    1. Folders: `account.read_folders` when non-empty — exactly those; a
       configured folder the server's LIST does not return is logged and
       skipped, never widened to "all". An empty list means every LISTed
       folder without `\\Noselect`, EXCEPT folders carrying an RFC 6154
       special-use attribute in `@excluded_special_use` (`\\Sent`, `\\All`,
       `\\Drafts`, `\\Trash`, `\\Junk`, `\\Flagged`, `\\Archive`), matched
       case-insensitively. INBOX is never excluded. Gmail's `[Gmail]/All Mail`
       holds every message including sent mail, so reading it posted the
       user's own outgoing mail as received (fabrikam install, 2026-09-24). A
       configured list is not filtered: naming `[Gmail]/Sent Mail` reads it.

       The attributes come from a plain `LIST "" "*"` (no
       `RETURN (SPECIAL-USE)`). Gmail includes them there; RFC 6154 lets a
       server return them only on request, and such a server's special
       folders are still read under an empty scope. No name-based fallback.
    2. Each folder is EXAMINEd (read-only). Nothing ever sets `\\Seen`, moves
       or deletes: `Platform.Mail.Imap.Client` has no such function.
    3. First contact with a folder records a cursor at its current maximum
       UID and ingests nothing older (no backfill). A UIDVALIDITY change
       resets the cursor to the new maximum and re-ingests nothing.
    4. New UIDs are fetched, parsed with `mail`, and inserted into
       `mail_inbound_messages` with `ON CONFLICT DO NOTHING` on
       `(account_id, message_id_key)`. The cursor advances after each UID.

  ## Dedupe

  `message_id_key/2`: the Message-ID header with whitespace and angle
  brackets trimmed, case preserved; when absent, `"sha256:" <> hex` of the
  raw bytes. A chat post happens ONLY when the insert actually wrote a row,
  so a message seen in two folders or after a cursor reset posts once.

  ## Posting: outside text, labelled as such

  Every ingested row is posted to `account.inbound_space_id` (skipped with a
  warning when that is nil or archived; the row is still stored for the
  Inbox) by a dedicated `"Email (external)"` system participant. The stored
  content is:

    * a provenance header (To, From, Date, Message-ID, account) OUTSIDE the
      wrapper, each value sanitised to one line;
    * `Platform.Security.ExternalContent.wrap/2` around the body (a fixed
      SECURITY NOTICE, random-id markers, spoofed markers and LLM special
      tokens neutralised), capped at 32 KB (32_768 bytes) with a truncation note
      outside the wrapper;
    * every `@[` in the whole content escaped, so no mention token survives.

  Message metadata stamps `"source" => "email_inbound"` and
  `"skip_mention_scan" => true`. `Platform.Chat.AttentionRouter` gives an
  `email_inbound` message no agent decision at all, and
  `Platform.Responsibilities.Router` fires no chat_pattern on it: inbound
  mail is untrusted outside input and must never summon, arm or route an
  agent. Suspicious injection patterns are logged (ids only, never the body).
  """

  import Ecto.Query

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  # NOT `alias Platform.Mail`: `Mail` in this module is the `mail` library
  # (Mail.parse/1, Mail.Message), which that alias would shadow.
  alias Platform.Mail.Account
  alias Platform.Mail.FolderCursor
  alias Platform.Mail.InboundMessage
  alias Platform.Repo
  alias Platform.Security.ExternalContent

  @body_cap_bytes 32_768
  @line_cap 320
  @participant_display_name "Email (external)"

  @doc "The display name of the system participant that authors email posts."
  @spec participant_display_name() :: String.t()
  def participant_display_name, do: @participant_display_name

  @doc "Byte cap on the email body carried in a chat post."
  @spec body_cap_bytes() :: pos_integer()
  def body_cap_bytes, do: @body_cap_bytes

  # ── Poller lifecycle ────────────────────────────────────────────────────

  @doc "Should this account have a running poller?"
  @spec eligible?(Account.t()) :: boolean()
  def eligible?(%Account{read_enabled: true, archived_at: nil, imap_host: host})
      when is_binary(host),
      do: String.trim(host) != ""

  def eligible?(_), do: false

  @doc """
  Start or stop `account`'s poller to match `eligible?/1`. A no-op (returning
  `:disabled`) when the module flag is off or the inbound supervisor is not
  running.
  """
  @spec sync_poller(Account.t()) :: :started | :running | :stopped | :disabled
  def sync_poller(%Account{} = account) do
    cond do
      not Platform.Mail.Config.enabled?() -> :disabled
      is_nil(Process.whereis(Platform.Mail.Inbound.Supervisor)) -> :disabled
      eligible?(account) -> start_poller(account.id)
      true -> stop_poller(account.id)
    end
  end

  @doc """
  The pid of `account_id`'s LIVE poller, or nil.

  Resolved with `Registry.whereis_name/1`, which checks `Process.alive?/1`,
  not `Registry.lookup/2`, which does not. A registry drops a dead process's
  entry only when its partition process handles the `:EXIT` — asynchronously,
  after `DynamicSupervisor.terminate_child/2` has already returned — so
  `lookup/2` can hand back the poller `stop_poller/1` just killed.
  """
  @spec poller_pid(binary()) :: pid() | nil
  def poller_pid(account_id) do
    if Process.whereis(Platform.Mail.Inbound.Registry) do
      case Registry.whereis_name({Platform.Mail.Inbound.Registry, account_id}) do
        pid when is_pid(pid) -> pid
        :undefined -> nil
      end
    end
  end

  defp start_poller(account_id) do
    case DynamicSupervisor.start_child(
           Platform.Mail.Inbound.PollerSupervisor,
           {Platform.Mail.Inbound.Poller, account_id}
         ) do
      {:ok, _pid} -> :started
      {:error, {:already_started, _pid}} -> :running
      {:error, reason} -> raise "mail poller failed to start: #{inspect(reason)}"
    end
  end

  defp stop_poller(account_id) do
    case poller_pid(account_id) do
      nil ->
        :stopped

      pid ->
        _ = DynamicSupervisor.terminate_child(Platform.Mail.Inbound.PollerSupervisor, pid)
        :stopped
    end
  end

  @poll_now_timeout 45_000

  @doc """
  Poll `account` once, now, and return the outcome (a manual refresh).

  Starts the account's poller if it is eligible and none is running, then
  asks that poller to poll, so the fetch is serialised with its timer rather
  than racing it. When no poller can run (the module flag off or the inbound
  supervisor not running) it polls in the calling process instead.

  Options: `:timeout` for the poller call (default #{@poll_now_timeout} ms).
  """
  @spec poll_now(Account.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def poll_now(%Account{} = account, opts \\ []) do
    if eligible?(account) do
      _ = sync_poller(account)

      case poller_pid(account.id) do
        pid when is_pid(pid) -> call_poller(pid, Keyword.get(opts, :timeout, @poll_now_timeout))
        nil -> poll_safely(account)
      end
    else
      {:error, :not_eligible}
    end
  end

  defp call_poller(pid, timeout) do
    GenServer.call(pid, :poll_now, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :poller_unavailable}
  end

  @doc """
  `poll/2`, with a raise or an exit inside it caught and logged. Every
  outcome is `{:ok, summary}` or `{:error, reason}`; failures are logged as
  `[Mail.Inbound]` warnings.
  """
  @spec poll_safely(Account.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def poll_safely(%Account{} = account, opts \\ []) do
    case poll(account, opts) do
      {:ok, _summary} = ok ->
        ok

      {:error, reason} = error ->
        Logger.warning(
          "[Mail.Inbound] poll failed account_id=#{account.id} reason=#{inspect(reason)}"
        )

        error
    end
  rescue
    error ->
      Logger.warning(
        "[Mail.Inbound] poll raised account_id=#{account.id} error=#{Exception.message(error)}"
      )

      {:error, :poll_raised}
  catch
    :exit, reason ->
      Logger.warning("[Mail.Inbound] poll exited account_id=#{account.id} #{inspect(reason)}")
      {:error, :poll_exited}
  end

  @doc "Start a poller for every eligible account. Run once at boot."
  @spec start_all_pollers() :: :ok
  def start_all_pollers do
    from(a in Account,
      where: a.read_enabled == true and is_nil(a.archived_at) and not is_nil(a.imap_host)
    )
    |> Repo.all()
    |> Enum.filter(&eligible?/1)
    |> Enum.each(&start_poller(&1.id))
  end

  # ── One poll ────────────────────────────────────────────────────────────

  @doc """
  Poll `account` once. Options: `:client` (default from config).

  Returns `{:ok, %{folders: [folder], ingested: n}}`, or `{:error, reason}`
  when the secret or the connection is unavailable.
  """
  @spec poll(Account.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def poll(%Account{} = account, opts \\ []) do
    client = Keyword.get_lazy(opts, :client, &configured_client/0)

    with {:ok, password} <- Platform.Mail.fetch_secret(account, :imap),
         {:ok, conn} <- client.connect(connect_params(account, password)) do
      try do
        with {:ok, listed} <- client.list_folders(conn) do
          folders = select_folders(account, listed)

          ingested =
            Enum.reduce(folders, 0, fn folder, acc ->
              acc + poll_folder(client, conn, account, folder)
            end)

          {:ok, %{folders: folders, ingested: ingested}}
        end
      after
        client.logout(conn)
      end
    end
  end

  defp configured_client do
    :platform
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:client, Platform.Mail.Imap.WireClient)
  end

  defp connect_params(%Account{} = account, password) do
    %{
      host: account.imap_host,
      port: account.imap_port,
      tls: account.imap_tls,
      username: account.username,
      password: password
    }
  end

  @doc false
  # Public for tests. Configured list → exactly those that LIST returned;
  # empty → every selectable listed folder except the special-use ones in
  # @excluded_special_use (INBOX always kept).
  @spec select_folders(Account.t(), [{String.t(), [String.t()]}]) :: [String.t()]
  def select_folders(%Account{read_folders: configured} = account, listed)
      when is_list(configured) and configured != [] do
    listed_names = Enum.map(listed, fn {name, _flags} -> name end)

    Enum.flat_map(configured, fn wanted ->
      case Enum.find(listed_names, &same_folder?(&1, wanted)) do
        nil ->
          Logger.warning(
            "[Mail.Inbound] configured folder not on server; skipped " <>
              "account_id=#{account.id} folder=#{inspect(wanted)}"
          )

          []

        name ->
          [name]
      end
    end)
    |> Enum.uniq()
  end

  def select_folders(%Account{}, listed) do
    for {name, flags} <- listed,
        selectable?(flags),
        String.upcase(name) == "INBOX" or not excluded_special_use?(flags),
        do: name
  end

  # RFC 6154 special-use attributes an EMPTY scope skips, downcased. `\All`
  # (Gmail's All Mail) and `\Flagged` (Starred) duplicate messages that live
  # elsewhere; `\Sent` and `\Drafts` are the user's own mail; `\Trash` and
  # `\Junk` are discarded or spam; `\Archive` is filed-away mail.
  @excluded_special_use ~w(\\sent \\all \\drafts \\trash \\junk \\flagged \\archive)

  defp excluded_special_use?(flags) do
    Enum.any?(flags, &(String.downcase(to_string(&1)) in @excluded_special_use))
  end

  # INBOX is case-insensitive in IMAP (RFC 3501 §5.1); every other name is not.
  defp same_folder?(a, b) do
    a == b or (String.upcase(a) == "INBOX" and String.upcase(b) == "INBOX")
  end

  defp selectable?(flags) do
    downcased = Enum.map(flags, &String.downcase(to_string(&1)))
    "\\noselect" not in downcased and "\\nonexistent" not in downcased
  end

  defp poll_folder(client, conn, account, folder) do
    case client.examine(conn, folder) do
      {:ok, uidvalidity, max_uid} ->
        case Repo.get_by(FolderCursor, account_id: account.id, folder: folder) do
          nil ->
            put_cursor(
              %FolderCursor{account_id: account.id, folder: folder},
              uidvalidity,
              max_uid
            )

            0

          %FolderCursor{uidvalidity: ^uidvalidity} = cursor ->
            ingest_new(client, conn, account, folder, cursor)

          %FolderCursor{} = cursor ->
            Logger.info(
              "[Mail.Inbound] UIDVALIDITY changed; cursor reset without re-ingest " <>
                "account_id=#{account.id} folder=#{inspect(folder)}"
            )

            put_cursor(cursor, uidvalidity, max_uid)
            0
        end

      {:error, reason} ->
        Logger.warning(
          "[Mail.Inbound] examine failed account_id=#{account.id} " <>
            "folder=#{inspect(folder)} reason=#{inspect(reason)}"
        )

        0
    end
  end

  defp ingest_new(client, conn, account, folder, %FolderCursor{} = cursor) do
    case client.uids_after(conn, cursor.last_uid) do
      {:ok, uids} ->
        uids
        |> Enum.filter(&(&1 > cursor.last_uid))
        |> Enum.sort()
        |> Enum.reduce_while({cursor, 0}, fn uid, {cursor, count} ->
          case client.fetch_raw(conn, uid) do
            {:ok, raw} ->
              inserted = ingest(account, folder, cursor.uidvalidity, uid, raw)
              cursor = put_cursor(cursor, cursor.uidvalidity, uid)
              {:cont, {cursor, count + inserted}}

            {:error, reason} ->
              # Stop the folder here; the cursor has not passed this UID, so
              # the next poll retries it.
              Logger.warning(
                "[Mail.Inbound] fetch failed account_id=#{account.id} " <>
                  "folder=#{inspect(folder)} uid=#{uid} reason=#{inspect(reason)}"
              )

              {:halt, {cursor, count}}
          end
        end)
        |> elem(1)

      {:error, reason} ->
        Logger.warning(
          "[Mail.Inbound] uid search failed account_id=#{account.id} " <>
            "folder=#{inspect(folder)} reason=#{inspect(reason)}"
        )

        0
    end
  end

  defp put_cursor(%FolderCursor{} = cursor, uidvalidity, last_uid) do
    cursor
    |> Ecto.Changeset.change(uidvalidity: uidvalidity, last_uid: last_uid)
    |> Repo.insert_or_update!()
  end

  # ── Ingest one message ──────────────────────────────────────────────────

  @doc """
  Store `raw` and, when that wrote a new row, post it. Returns 1 when a row
  was inserted, 0 when `(account_id, message_id_key)` already existed.
  Public for tests.
  """
  @spec ingest(Account.t(), String.t(), non_neg_integer(), non_neg_integer(), binary()) ::
          0 | 1
  def ingest(%Account{} = account, folder, uidvalidity, uid, raw) when is_binary(raw) do
    parsed = parse(raw)
    now = DateTime.utc_now()

    row = %{
      id: Platform.Types.UUIDv7.generate(),
      account_id: account.id,
      org_id: account.org_id,
      folder: folder,
      uidvalidity: uidvalidity,
      uid: uid,
      message_id_key: message_id_key(parsed.message_id, raw),
      message_id_header: parsed.message_id,
      raw: raw,
      from_address: parsed.from,
      to_addresses: parsed.to,
      subject: parsed.subject,
      text_body: parsed.text,
      received_at: parsed.date || now,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(InboundMessage, [row],
           on_conflict: :nothing,
           conflict_target: [:account_id, :message_id_key]
         ) do
      {1, _} ->
        inbound = Repo.get!(InboundMessage, row.id)
        log_suspicious(inbound, parsed)
        post(account, inbound, parsed)
        1

      {0, _} ->
        0
    end
  end

  @doc """
  The dedupe key: the Message-ID header without surrounding whitespace or
  angle brackets (case kept), else `"sha256:" <> lowercase hex` of `raw`.
  """
  @spec message_id_key(String.t() | nil, binary()) :: String.t()
  def message_id_key(header, raw) do
    case normalize_message_id(header) do
      nil -> "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
      key -> key
    end
  end

  defp normalize_message_id(header) when is_binary(header) do
    trimmed =
      header
      |> String.trim()
      |> String.trim_leading("<")
      |> String.trim_trailing(">")
      |> String.trim()

    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_message_id(_), do: nil

  # ── Parsing ─────────────────────────────────────────────────────────────

  @doc false
  # Public for tests. Never raises: an unparseable message yields nil fields
  # and is still stored, keyed by its raw digest.
  @spec parse(binary()) :: %{
          message_id: String.t() | nil,
          from: String.t() | nil,
          to: [String.t()],
          subject: String.t() | nil,
          date: DateTime.t() | nil,
          text: String.t() | nil
        }
  def parse(raw) do
    message = Mail.parse(raw)
    headers = message.headers || %{}

    %{
      message_id: header_string(headers["message-id"]),
      from: format_address(headers["from"]),
      to:
        (List.wrap(headers["to"]) ++ List.wrap(headers["cc"]))
        |> Enum.map(&address_only/1)
        |> Enum.reject(&is_nil/1),
      subject: header_string(headers["subject"]) |> scrub(),
      date: header_date(headers["date"]),
      text: body_text(message)
    }
  rescue
    _ -> %{message_id: nil, from: nil, to: [], subject: nil, date: nil, text: nil}
  end

  defp header_string(value) when is_binary(value), do: value
  defp header_string(_), do: nil

  # `:utc_datetime_usec` wants 6-digit precision; a parsed header has 0.
  defp header_date(%DateTime{microsecond: {usec, _}} = date),
    do: %DateTime{date | microsecond: {usec, 6}}

  defp header_date(_), do: nil

  defp format_address({name, address}) when is_binary(name) and name != "",
    do: scrub("#{name} <#{address}>")

  defp format_address({_name, address}) when is_binary(address), do: scrub(address)
  defp format_address(address) when is_binary(address), do: scrub(address)
  defp format_address([first | _]), do: format_address(first)
  defp format_address(_), do: nil

  defp address_only({_name, address}) when is_binary(address), do: scrub(address)
  defp address_only(address) when is_binary(address), do: scrub(address)
  defp address_only(_), do: nil

  defp scrub(nil), do: nil
  defp scrub(value) when is_binary(value), do: String.replace_invalid(value)

  defp body_text(%Mail.Message{} = message) do
    cond do
      text = part_body(Mail.get_text(message)) ->
        text

      html = part_body(Mail.get_html(message)) ->
        html_to_text(html)

      not message.multipart and is_binary(message.body) ->
        scrub(message.body)

      true ->
        nil
    end
  end

  defp part_body(%Mail.Message{body: body}) when is_binary(body), do: scrub(body)
  defp part_body(_), do: nil

  @doc false
  # Deliberately crude: the result is text for a chat bubble, not a render.
  def html_to_text(html) do
    html
    |> String.replace(~r/<(script|style)\b[^>]*>.*?<\/\1\s*>/isu, "")
    |> String.replace(~r/<br\s*\/?>/iu, "\n")
    |> String.replace(~r/<\/(p|div|li|tr|h[1-6])\s*>/iu, "\n")
    |> String.replace(~r/<[^>]*>/u, "")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end

  # ── Suspicious-pattern logging ──────────────────────────────────────────

  defp log_suspicious(%InboundMessage{} = inbound, parsed) do
    haystack = Enum.join([parsed.from || "", parsed.subject || "", parsed.text || ""], "\n")

    case ExternalContent.detect_suspicious_patterns(haystack) do
      [] ->
        :ok

      patterns ->
        Logger.warning(
          "[Mail.Inbound] suspicious patterns in inbound email " <>
            "mail_inbound_message_id=#{inbound.id} account_id=#{inbound.account_id} " <>
            "message_id_key=#{inspect(inbound.message_id_key)} patterns=#{inspect(patterns)}"
        )
    end
  end

  # ── Posting ─────────────────────────────────────────────────────────────

  defp post(%Account{} = account, %InboundMessage{} = inbound, parsed) do
    case usable_space(account.inbound_space_id) do
      {:ok, space} ->
        with {:ok, participant} <- ensure_email_participant(space.id),
             {:ok, message} <-
               Chat.post_message(%{
                 space_id: space.id,
                 participant_id: participant.id,
                 content_type: "text",
                 content: render_content(account, inbound, parsed),
                 metadata: %{
                   "source" => "email_inbound",
                   "skip_mention_scan" => true,
                   "mail_inbound_message_id" => inbound.id,
                   "message_id" => one_line(inbound.message_id_header),
                   "account_address" => account_address(account, inbound),
                   "from" => one_line(inbound.from_address)
                 }
               }) do
          inbound
          |> Ecto.Changeset.change(chat_message_id: message.id)
          |> Repo.update!()

          :ok
        else
          {:error, reason} ->
            Logger.warning(
              "[Mail.Inbound] chat post failed; row kept for the Inbox " <>
                "mail_inbound_message_id=#{inbound.id} reason=#{inspect(reason)}"
            )

            :ok
        end

      {:skip, why} ->
        Logger.warning(
          "[Mail.Inbound] no usable inbound space (#{why}); row kept for the Inbox " <>
            "account_id=#{account.id} mail_inbound_message_id=#{inbound.id}"
        )

        :ok
    end
  end

  defp usable_space(nil), do: {:skip, :unset}

  defp usable_space(space_id) do
    case Repo.get(Space, space_id) do
      nil -> {:skip, :missing}
      %Space{archived_at: nil} = space -> {:ok, space}
      %Space{} -> {:skip, :archived}
    end
  end

  @doc """
  The chat content for an ingested email: provenance header outside the
  wrapper, the wrapped body, a truncation note when capped, and every `@[`
  escaped. Public for tests.
  """
  @spec render_content(Account.t(), InboundMessage.t(), map()) :: String.t()
  def render_content(%Account{} = account, %InboundMessage{} = inbound, parsed) do
    {body, truncated_from} = cap_body(parsed.text || "")
    from = one_line(inbound.from_address) || "(unknown sender)"

    provenance =
      [
        "Email to #{account_address(account, inbound)}, from #{from}",
        "Date: #{DateTime.to_iso8601(inbound.received_at)} | Message-ID: " <>
          (one_line(inbound.message_id_header) || "(none)") <>
          " | Account: #{one_line(account.name)}"
      ]
      |> Enum.join("\n")

    wrapped =
      ExternalContent.wrap(body,
        source: :email,
        sender: inbound.from_address,
        subject: inbound.subject
      )

    note =
      case truncated_from do
        nil ->
          []

        size ->
          [
            "[Truncated: the email body is #{size} bytes; the first #{@body_cap_bytes} are " <>
              "shown. The full message is kept in the Email Inbox.]"
          ]
      end

    [provenance, wrapped | note]
    |> Enum.join("\n\n")
    |> ExternalContent.escape_mentions()
  end

  defp cap_body(body) when byte_size(body) <= @body_cap_bytes, do: {body, nil}

  defp cap_body(body) do
    head = binary_part(body, 0, @body_cap_bytes)
    # Drop a codepoint cut in half by the byte cap.
    head = trim_partial_codepoint(head)
    {head, byte_size(body)}
  end

  defp trim_partial_codepoint(bin) do
    if String.valid?(bin) or bin == "",
      do: bin,
      else: trim_partial_codepoint(binary_part(bin, 0, byte_size(bin) - 1))
  end

  defp one_line(nil), do: nil

  defp one_line(value) when is_binary(value) do
    value
    |> ExternalContent.sanitize_line()
    |> String.trim()
    |> String.slice(0, @line_cap)
  end

  @doc """
  The account address the email is shown as sent to: the first To/Cc address
  matching one of the account's senders, else the account's username.
  """
  @spec account_address(Account.t(), InboundMessage.t()) :: String.t()
  def account_address(%Account{} = account, %InboundMessage{to_addresses: to}) do
    senders =
      account
      |> Repo.preload(:senders)
      |> Map.get(:senders)
      |> Enum.map(&String.downcase(&1.address))

    matched = Enum.find(to || [], &(String.downcase(&1) in senders))
    one_line(matched || account.username || account.name)
  end

  @doc """
  The space's `"Email (external)"` system participant, created on first use.
  Deterministic `participant_id`, distinct from the TaskRouter's system
  participant and from every user or agent.
  """
  @spec ensure_email_participant(binary()) :: {:ok, Participant.t()} | {:error, term()}
  def ensure_email_participant(space_id) do
    participant_id = email_participant_id(space_id)

    case Repo.get_by(Participant,
           space_id: space_id,
           participant_type: "system",
           participant_id: participant_id
         ) do
      %Participant{} = participant ->
        {:ok, participant}

      nil ->
        Chat.add_participant(space_id, %{
          participant_type: "system",
          participant_id: participant_id,
          display_name: @participant_display_name,
          attention_mode: "mention",
          joined_at: DateTime.utc_now()
        })
    end
  end

  @doc false
  def email_participant_id(space_id) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12), _::binary>> =
      :crypto.hash(:sha256, "mail_inbound_email_external:#{space_id}")
      |> Base.encode16(case: :lower)

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
