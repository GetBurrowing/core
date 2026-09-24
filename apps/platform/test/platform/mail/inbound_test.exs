defmodule Platform.Mail.InboundTest do
  @moduledoc """
  The read-only IMAP poller (task 01a0cf21 stage 3): folder scope, cursors,
  Message-ID dedupe, and the channel post. Every test drives
  `Platform.Mail.Inbound.poll/2` against `Platform.Mail.Imap.FakeClient`; no
  test opens a socket.

  async: false — the lifecycle tests flip `:mail_enabled` and start the
  globally named inbound supervisor.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Mail
  alias Platform.Mail.FolderCursor
  alias Platform.Mail.Imap.FakeClient
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Security.ExternalContent
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp admin!(org_id) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "inbound-#{n}@example.com",
        name: "Inbound #{n}",
        oidc_sub: "oidc-inbound-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "admin"})
    |> Repo.insert!()

    user
  end

  defp space! do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "Mail #{n}", slug: "mail-#{n}", kind: "channel"})
    space
  end

  defp account!(ctx, overrides \\ %{}) do
    n = System.unique_integer([:positive])
    host = "imap-#{n}.acme.test"

    attrs =
      Map.merge(
        %{
          "name" => "support-#{n}",
          "smtp_tls" => "starttls",
          "username" => "support@acme.test",
          "imap_host" => host,
          "imap_port" => 993,
          "imap_tls" => "tls",
          "read_enabled" => true,
          "inbound_space_id" => ctx.space.id
        },
        overrides
      )

    {:ok, account} = Mail.create_account(ctx.admin, ctx.org_id, attrs, %{imap: "imap-pass"})
    account
  end

  defp raw(opts) do
    headers =
      [
        {"From", Keyword.get(opts, :from, "Alice Example <alice@example.test>")},
        {"To", Keyword.get(opts, :to, "support@acme.test")},
        {"Subject", Keyword.get(opts, :subject, "Hello")},
        {"Date", "Tue, 22 Sep 2026 10:00:00 +0000"},
        {"Message-ID", Keyword.get(opts, :message_id)}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join("\r\n", fn {k, v} -> "#{k}: #{v}" end)

    headers <> "\r\n\r\n" <> Keyword.get(opts, :body, "Body text") <> "\r\n"
  end

  defp rows(account) do
    Repo.all(from(m in InboundMessage, where: m.account_id == ^account.id, order_by: m.uid))
  end

  defp chat_messages(space) do
    Repo.all(
      from(m in Message,
        where: m.space_id == ^space.id and fragment("?->>'source'", m.metadata) == "email_inbound"
      )
    )
  end

  defp poll!(account) do
    {:ok, summary} = Inbound.poll(Repo.reload!(account), client: FakeClient)
    summary
  end

  setup do
    org_id = Tenancy.get_org_by_slug!("soylent").id
    %{org_id: org_id, admin: admin!(org_id), space: space!()}
  end

  # Gmail's plain `LIST "" "*"` shape; `case_fun` rewrites the flag case.
  defp gmail_listed(case_fun) do
    [
      {"INBOX", ["\\HasNoChildren"]},
      {"[Gmail]", ["\\Noselect", "\\HasChildren"]},
      {"[Gmail]/All Mail", ["\\All", "\\HasNoChildren"]},
      {"[Gmail]/Drafts", ["\\Drafts", "\\HasNoChildren"]},
      {"[Gmail]/Important", ["\\HasNoChildren", "\\Important"]},
      {"[Gmail]/Sent Mail", ["\\HasNoChildren", "\\Sent"]},
      {"[Gmail]/Spam", ["\\HasNoChildren", "\\Junk"]},
      {"[Gmail]/Starred", ["\\Flagged", "\\HasNoChildren"]},
      {"[Gmail]/Trash", ["\\HasNoChildren", "\\Trash"]},
      {"Jobs", ["\\HasNoChildren"]}
    ]
    |> Enum.map(fn {name, flags} -> {name, Enum.map(flags, case_fun)} end)
  end

  defp put_gmail_folders(host, case_fun) do
    for {name, flags} <- gmail_listed(case_fun),
        do: FakeClient.put_folder(host, name, flags: flags)
  end

  # ── folder scope ──────────────────────────────────────────────────────────

  describe "folder scope" do
    test "a configured scope reads exactly those folders", ctx do
      account = account!(ctx, %{"read_folders" => ["Support"]})
      host = account.imap_host
      FakeClient.start_server!(host)
      FakeClient.put_folder(host, "INBOX")
      FakeClient.put_folder(host, "Support")

      assert %{folders: ["Support"], ingested: 0} = poll!(account)

      FakeClient.deliver(host, "INBOX", raw(message_id: "<inbox-1@x.test>"))
      FakeClient.deliver(host, "Support", raw(message_id: "<support-1@x.test>"))

      assert %{ingested: 1} = poll!(account)

      assert [%InboundMessage{folder: "Support", message_id_key: "support-1@x.test"}] =
               rows(account)

      assert [_one] = chat_messages(ctx.space)
      refute Enum.any?(FakeClient.calls(host), &match?({:examine, "INBOX"}, &1))
    end

    test "an empty scope reads every selectable folder", ctx do
      account = account!(ctx)
      host = account.imap_host
      FakeClient.start_server!(host)
      FakeClient.put_folder(host, "INBOX")
      FakeClient.put_folder(host, "Support")
      FakeClient.put_folder(host, "[Gmail]", flags: ["\\Noselect", "\\HasChildren"])

      assert %{folders: ["INBOX", "Support"]} = poll!(account)

      FakeClient.deliver(host, "INBOX", raw(message_id: "<a@x.test>"))
      FakeClient.deliver(host, "Support", raw(message_id: "<b@x.test>"))

      assert %{ingested: 2} = poll!(account)
      assert ["INBOX", "Support"] = account |> rows() |> Enum.map(& &1.folder) |> Enum.sort()
      assert length(chat_messages(ctx.space)) == 2
      refute Enum.any?(FakeClient.calls(host), &match?({:examine, "[Gmail]"}, &1))
    end

    # Measured on the fabrikam install 2026-09-24: an empty scope on imap.gmail.com
    # read `[Gmail]/All Mail`, which holds sent mail, and posted the user's own
    # outgoing message as received.
    test "an empty scope skips RFC 6154 special-use folders (Gmail-shaped LIST)", ctx do
      account = account!(ctx)
      host = account.imap_host
      FakeClient.start_server!(host)
      put_gmail_folders(host, &Function.identity/1)

      assert %{folders: ["INBOX", "[Gmail]/Important", "Jobs"]} = poll!(account)

      for folder <- [
            "[Gmail]/All Mail",
            "[Gmail]/Sent Mail",
            "[Gmail]/Drafts",
            "[Gmail]/Spam",
            "[Gmail]/Trash",
            "[Gmail]/Starred",
            "[Gmail]"
          ] do
        refute Enum.any?(FakeClient.calls(host), &match?({:examine, ^folder}, &1)), folder
      end

      FakeClient.deliver(host, "[Gmail]/All Mail", raw(message_id: "<sent-1@x.test>"))
      FakeClient.deliver(host, "[Gmail]/Sent Mail", raw(message_id: "<sent-1@x.test>"))

      assert %{ingested: 0} = poll!(account)
      assert rows(account) == []
      assert chat_messages(ctx.space) == []
    end

    test "special-use attributes match case-insensitively" do
      listed = gmail_listed(&String.upcase/1) ++ gmail_listed(&String.downcase/1)
      account = %Mail.Account{read_folders: []}

      assert Inbound.select_folders(account, listed) ==
               ["INBOX", "[Gmail]/Important", "Jobs", "INBOX", "[Gmail]/Important", "Jobs"]
    end

    test "INBOX is kept under an empty scope even if it carries a special-use flag" do
      account = %Mail.Account{read_folders: []}

      assert Inbound.select_folders(account, [{"INBOX", ["\\All"]}, {"Sent", ["\\Sent"]}]) ==
               ["INBOX"]
    end

    test "an explicit scope still reads a special-use folder", ctx do
      account = account!(ctx, %{"read_folders" => ["[Gmail]/Sent Mail"]})
      host = account.imap_host
      FakeClient.start_server!(host)
      put_gmail_folders(host, &Function.identity/1)

      assert %{folders: ["[Gmail]/Sent Mail"]} = poll!(account)

      assert Inbound.select_folders(
               %Mail.Account{read_folders: ["[Gmail]/All Mail"]},
               gmail_listed(& &1)
             ) == ["[Gmail]/All Mail"]
    end

    test "a configured folder the server does not list is skipped, never widened", ctx do
      account = account!(ctx, %{"read_folders" => ["Archive"]})
      host = account.imap_host
      FakeClient.start_server!(host)
      FakeClient.put_folder(host, "INBOX")

      log = capture_log(fn -> assert %{folders: [], ingested: 0} = poll!(account) end)

      assert log =~ "configured folder not on server"
      refute Enum.any?(FakeClient.calls(host), &match?({:examine, _}, &1))
    end

    test "INBOX in the scope matches the server's INBOX case-insensitively", ctx do
      account = account!(ctx, %{"read_folders" => ["inbox"]})
      host = account.imap_host
      FakeClient.start_server!(host)
      FakeClient.put_folder(host, "INBOX")

      assert %{folders: ["INBOX"]} = poll!(account)
    end
  end

  # ── cursors ───────────────────────────────────────────────────────────────

  describe "cursors" do
    test "first contact ingests nothing that already exists", ctx do
      account = account!(ctx)
      host = account.imap_host
      FakeClient.start_server!(host)
      FakeClient.put_folder(host, "INBOX", uidvalidity: 11)
      FakeClient.deliver(host, "INBOX", raw(message_id: "<old-1@x.test>"))
      FakeClient.deliver(host, "INBOX", raw(message_id: "<old-2@x.test>"))

      assert %{ingested: 0} = poll!(account)
      assert rows(account) == []
      assert chat_messages(ctx.space) == []

      assert %FolderCursor{uidvalidity: 11, last_uid: 2} =
               Repo.get_by!(FolderCursor, account_id: account.id, folder: "INBOX")

      refute Enum.any?(FakeClient.calls(host), &match?({:fetch_raw, _, _}, &1))

      FakeClient.deliver(host, "INBOX", raw(message_id: "<new-3@x.test>"))
      assert %{ingested: 1} = poll!(account)
      assert [%InboundMessage{uid: 3}] = rows(account)
    end

    test "a UIDVALIDITY change resets the cursor and re-posts nothing", ctx do
      account = account!(ctx)
      host = account.imap_host
      FakeClient.start_server!(host)
      FakeClient.put_folder(host, "INBOX", uidvalidity: 1)
      poll!(account)

      FakeClient.deliver(host, "INBOX", raw(message_id: "<m1@x.test>"))
      FakeClient.deliver(host, "INBOX", raw(message_id: "<m2@x.test>", body: "second"))
      assert %{ingested: 2} = poll!(account)

      # The server renumbers: same two messages, new UIDVALIDITY. Their new
      # UIDs (1, 2) are at or below nothing the old cursor knew about.
      FakeClient.renumber(host, "INBOX", 99)
      assert %{ingested: 0} = poll!(account)

      assert %FolderCursor{uidvalidity: 99, last_uid: 2} =
               Repo.get_by!(FolderCursor, account_id: account.id, folder: "INBOX")

      FakeClient.deliver(host, "INBOX", raw(message_id: "<m3@x.test>"))
      assert %{ingested: 1} = poll!(account)

      assert length(rows(account)) == 3
      assert length(chat_messages(ctx.space)) == 3
    end
  end

  # ── dedupe ────────────────────────────────────────────────────────────────

  describe "dedupe" do
    test "the same Message-ID in two folders and on a second poll is one row, one post", ctx do
      account = account!(ctx)
      host = account.imap_host
      FakeClient.start_server!(host)
      FakeClient.put_folder(host, "INBOX")
      FakeClient.put_folder(host, "Support")
      poll!(account)

      mail = raw(message_id: "  <Same.ID@Example.test> ")
      FakeClient.deliver(host, "INBOX", mail)
      FakeClient.deliver(host, "Support", mail)
      assert %{ingested: 1} = poll!(account)

      # Seen again after a cursor reset: still one.
      Repo.delete_all(from(c in FolderCursor, where: c.account_id == ^account.id))
      FakeClient.renumber(host, "INBOX", 5)
      poll!(account)

      Repo.update_all(from(c in FolderCursor, where: c.account_id == ^account.id),
        set: [last_uid: 0]
      )

      assert %{ingested: 0} = poll!(account)

      assert [%InboundMessage{message_id_key: "Same.ID@Example.test"} = row] = rows(account)
      assert [%Message{id: message_id}] = chat_messages(ctx.space)
      assert row.chat_message_id == message_id
    end

    test "without a Message-ID the sha256 of the raw bytes is the key", ctx do
      account = account!(ctx)
      host = account.imap_host
      FakeClient.start_server!(host)
      FakeClient.put_folder(host, "INBOX")
      FakeClient.put_folder(host, "Support")
      poll!(account)

      mail = raw(body: "no id here")
      FakeClient.deliver(host, "INBOX", mail)
      FakeClient.deliver(host, "Support", mail)
      FakeClient.deliver(host, "Support", raw(body: "a different message"))
      assert %{ingested: 2} = poll!(account)

      keys = account |> rows() |> Enum.map(& &1.message_id_key)
      expected = "sha256:" <> Base.encode16(:crypto.hash(:sha256, mail), case: :lower)
      assert expected in keys
      assert length(keys) == 2
      assert length(chat_messages(ctx.space)) == 2
    end

    test "message_id_key trims whitespace and angle brackets and keeps case" do
      assert Inbound.message_id_key(" <AbC@x.Test>\r\n", "raw") == "AbC@x.Test"
      assert Inbound.message_id_key("<>", "raw") =~ ~r/\Asha256:[0-9a-f]{64}\z/
      assert Inbound.message_id_key(nil, "raw") =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end
  end

  # ── the channel post ──────────────────────────────────────────────────────

  describe "the channel post" do
    setup ctx do
      account = account!(ctx)
      FakeClient.start_server!(account.imap_host)
      FakeClient.put_folder(account.imap_host, "INBOX")
      poll!(account)
      %{account: account}
    end

    test "is authored by the space's Email (external) system participant", ctx do
      FakeClient.deliver(ctx.account.imap_host, "INBOX", raw(message_id: "<p@x.test>"))
      poll!(ctx.account)

      [message] = chat_messages(ctx.space)
      participant = Repo.get!(Chat.Participant, message.participant_id)

      assert participant.participant_type == "system"
      assert participant.display_name == "Email (external)"
      assert participant.participant_id == Inbound.email_participant_id(ctx.space.id)

      assert %{
               "source" => "email_inbound",
               "skip_mention_scan" => true,
               "message_id" => "<p@x.test>",
               "account_address" => "support@acme.test",
               "from" => "Alice Example <alice@example.test>"
             } = message.metadata

      assert message.metadata["mail_inbound_message_id"] == hd(rows(ctx.account)).id
    end

    test "puts provenance outside the wrapper and the body inside it", ctx do
      FakeClient.deliver(
        ctx.account.imap_host,
        "INBOX",
        raw(message_id: "<q@x.test>", subject: "Invoice", body: "Please pay.")
      )

      poll!(ctx.account)
      [message] = chat_messages(ctx.space)

      [provenance, rest] = String.split(message.content, "\n\n", parts: 2)
      assert provenance =~ "Email to support@acme.test, from Alice Example <alice@example.test>"
      assert provenance =~ "Message-ID: <q@x.test>"
      assert provenance =~ "Date: 2026-09-22T10:00:00"
      assert String.starts_with?(rest, ExternalContent.warning())

      [_, id] = Regex.run(~r/<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>/, rest)

      [_, inside, _] =
        String.split(rest, [ExternalContent.start_marker(id), ExternalContent.end_marker(id)])

      assert inside =~ "Subject: Invoice"
      assert inside =~ "Please pay."
      refute provenance =~ "Please pay."
    end

    test "falls back to HTML stripped to text", ctx do
      html =
        "From: a@x.test\r\nMessage-ID: <h@x.test>\r\nContent-Type: text/html\r\n\r\n" <>
          "<p>Hi <b>there</b></p><script>alert(1)</script>\r\n"

      FakeClient.deliver(ctx.account.imap_host, "INBOX", html)
      poll!(ctx.account)

      [row] = rows(ctx.account)
      assert row.text_body == "Hi there"
    end

    test "caps the body at 32 KB with a truncation note outside the wrapper", ctx do
      big = String.duplicate("a", Inbound.body_cap_bytes() + 500)

      FakeClient.deliver(
        ctx.account.imap_host,
        "INBOX",
        raw(message_id: "<big@x.test>", body: big)
      )

      poll!(ctx.account)

      [message] = chat_messages(ctx.space)

      [_, id] =
        Regex.run(~r/<<<END_EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>/, message.content)

      [_, after_end] = String.split(message.content, ExternalContent.end_marker(id))
      assert after_end =~ "[Truncated:"
      refute message.content =~ String.duplicate("a", Inbound.body_cap_bytes() + 1)

      # The Inbox keeps the whole message.
      [row] = rows(ctx.account)
      assert byte_size(row.raw) > Inbound.body_cap_bytes()
    end

    test "with no inbound space the row is stored and nothing is posted", ctx do
      {:ok, account} = Mail.update_account(ctx.admin, ctx.account, %{"inbound_space_id" => nil})
      FakeClient.deliver(account.imap_host, "INBOX", raw(message_id: "<ns@x.test>"))

      log = capture_log(fn -> assert %{ingested: 1} = poll!(account) end)

      assert log =~ "no usable inbound space"
      assert [%InboundMessage{chat_message_id: nil}] = rows(account)
      assert chat_messages(ctx.space) == []
    end

    test "with an archived inbound space the row is stored and nothing is posted", ctx do
      {:ok, _} = Chat.archive_space(ctx.space)
      FakeClient.deliver(ctx.account.imap_host, "INBOX", raw(message_id: "<ar@x.test>"))

      log = capture_log(fn -> assert %{ingested: 1} = poll!(ctx.account) end)

      assert log =~ "no usable inbound space"
      assert [%InboundMessage{chat_message_id: nil}] = rows(ctx.account)
    end
  end

  # ── read-only seam ────────────────────────────────────────────────────────

  describe "the IMAP seam is read-only" do
    test "the client behaviour has exactly the six read callbacks" do
      assert Enum.sort(Platform.Mail.Imap.Client.behaviour_info(:callbacks)) ==
               Enum.sort(
                 connect: 1,
                 list_folders: 1,
                 examine: 2,
                 uids_after: 2,
                 fetch_raw: 2,
                 logout: 1
               )
    end

    test "the wire client issues no mailbox-changing command and peeks bodies" do
      source = File.read!("lib/platform/mail/imap/wire_client.ex")

      # A command is a string literal (or iodata head) that STARTS with the
      # verb; the moduledoc's prose mentions are not quoted that way.
      for forbidden <- ~w(SELECT STORE COPY MOVE EXPUNGE DELETE APPEND CREATE RENAME CLOSE) do
        refute source =~ ~r/"(UID )?#{forbidden}\b/,
               "WireClient must not send #{forbidden}"
      end

      assert source =~ "(BODY.PEEK[])"
      refute source =~ ~r/FETCH[^"]*\(BODY\[/
    end
  end

  # ── poller lifecycle ──────────────────────────────────────────────────────

  describe "poller lifecycle" do
    setup do
      previous = Application.get_env(:platform, :mail_enabled)
      Application.put_env(:platform, :mail_enabled, true)
      on_exit(fn -> Application.put_env(:platform, :mail_enabled, previous) end)
      start_supervised!({Platform.Mail.Inbound.Supervisor, boot: false})
      :ok
    end

    test "read_enabled false has no poller; toggling starts and stops it", ctx do
      account = account!(ctx, %{"read_enabled" => false})
      assert Inbound.sync_poller(account) == :stopped
      assert Inbound.poller_pid(account.id) == nil

      {:ok, account} = Mail.update_account(ctx.admin, account, %{"read_enabled" => true})
      pid = Inbound.poller_pid(account.id)
      assert is_pid(pid)
      ref = Process.monitor(pid)

      {:ok, _account} = Mail.update_account(ctx.admin, account, %{"read_enabled" => false})
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      assert Inbound.poller_pid(account.id) == nil
    end

    # Regression (follow-up to #1084): the registry partition removes a dead
    # poller's entry only when it handles the :EXIT, after terminate_child has
    # returned. Suspending the partition holds that window open, so this fails
    # every time if poller_pid/1 reads the entry without checking liveness.
    test "a stopped poller is gone from poller_pid before the registry cleans up", ctx do
      account = account!(ctx)
      # create_account/4 already started it.
      assert Inbound.sync_poller(account) == :running
      pid = Inbound.poller_pid(account.id)
      assert is_pid(pid)

      partition = Module.concat(Platform.Mail.Inbound.Registry, "PIDPartition0")
      :ok = :sys.suspend(partition)

      try do
        {:ok, _} = Mail.update_account(ctx.admin, account, %{"read_enabled" => false})
        refute Process.alive?(pid)

        assert [{^pid, _}] = Registry.lookup(Platform.Mail.Inbound.Registry, account.id),
               "precondition: the dead poller's registry entry is still present"

        assert Inbound.poller_pid(account.id) == nil
      after
        :sys.resume(partition)
      end
    end

    test "archiving an account stops its poller", ctx do
      account = account!(ctx)
      # create_account/4 already started it.
      assert Inbound.sync_poller(account) == :running
      pid = Inbound.poller_pid(account.id)
      ref = Process.monitor(pid)

      {:ok, _} = Mail.archive_account(ctx.admin, account)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end

    # Regression: create_account/4 never called sync_poller/1, so an account
    # created with reading on while the app was running got no poller until a
    # restart or an edit (prod, 2026-09-24: 0 cursors, 0 inbound rows).
    test "creating a read-enabled account starts its poller", ctx do
      account = account!(ctx)
      assert is_pid(Inbound.poller_pid(account.id))
    end

    test "creating a send-only account starts no poller", ctx do
      account = account!(ctx, %{"read_enabled" => false})
      assert Inbound.poller_pid(account.id) == nil
    end

    test "an account without an imap_host never gets a poller", ctx do
      account = account!(ctx, %{"imap_host" => nil})
      refute Inbound.eligible?(account)
      assert Inbound.sync_poller(account) == :stopped
      assert Inbound.poller_pid(account.id) == nil
    end
  end

  describe "module flag" do
    test "flag off: the inbound supervisor is not among the application's children" do
      assert Platform.Mail.Config.enabled?() == false
      assert Platform.Application.maybe_add_mail_inbound([:x]) == [:x]
      assert Process.whereis(Platform.Mail.Inbound.Supervisor) == nil
    end

    test "flag on: the inbound supervisor is appended" do
      previous = Application.get_env(:platform, :mail_enabled)
      Application.put_env(:platform, :mail_enabled, true)
      on_exit(fn -> Application.put_env(:platform, :mail_enabled, previous) end)

      assert Platform.Application.maybe_add_mail_inbound([:x]) ==
               [:x, Platform.Mail.Inbound.Supervisor]
    end

    test "flag off: sync_poller starts nothing even for an eligible account", ctx do
      account = account!(ctx)
      assert Inbound.eligible?(account)
      assert Inbound.sync_poller(account) == :disabled
    end
  end
end
