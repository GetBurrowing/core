defmodule Platform.Mail.Imap.WireClientTest do
  @moduledoc """
  The production IMAP client over a REAL socket (task 01a0cf21 stage 7).

  Every test here talks TCP to `Platform.Mail.ScriptedImapServer`, which
  answers with GreenMail 2.1.14's recorded reply bytes. That is the class of
  test the in-memory `FakeClient` could not be: stage 6 found the previous
  (Mailroom-based) client failing on GreenMail's first LIST reply while every
  FakeClient test passed. The end-to-end tests drive the real
  `Platform.Mail.Inbound.poll/2` with `client: @client`.

  These run in the default suite and in CI (no tag): they need no container,
  only a loopback socket. A live-GreenMail variant is
  `test/platform/mail/imap/greenmail_live_test.exs`, excluded by default.

  async: false — the five-poll test asserts on captured logs.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Mail
  alias Platform.Mail.Imap.WireClient
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Mail.ScriptedImapServer
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @client WireClient

  # Every command verb the client may send. Anything else is a defect.
  @allowed ~w(LOGIN LIST EXAMINE STATUS UID LOGOUT)

  defp admin!(org_id) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "wire-#{n}@example.com",
        name: "Wire #{n}",
        oidc_sub: "oidc-wire-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "admin"})
    |> Repo.insert!()

    user
  end

  defp account!(ctx, server, overrides \\ %{}, password \\ "imap-pass") do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          "name" => "wire-#{n}",
          "smtp_tls" => "starttls",
          "username" => "support@acme.test",
          "imap_host" => "127.0.0.1",
          "imap_port" => ScriptedImapServer.port(server),
          "imap_tls" => "none",
          "read_enabled" => true,
          "inbound_space_id" => ctx.space.id
        },
        overrides
      )

    {:ok, account} = Mail.create_account(ctx.admin, ctx.org_id, attrs, %{imap: password})
    account
  end

  defp raw(message_id, subject \\ "Hello") do
    "From: Alice Example <alice@example.test>\r\nTo: support@acme.test\r\n" <>
      "Subject: #{subject}\r\nDate: Tue, 22 Sep 2026 10:00:00 +0000\r\n" <>
      "Message-ID: <#{message_id}>\r\n\r\nline one\r\n.dot line\r\n"
  end

  defp poll!(account) do
    {:ok, summary} = Inbound.poll(Repo.reload!(account), client: @client)
    summary
  end

  defp rows(account) do
    Repo.all(
      from(m in InboundMessage, where: m.account_id == ^account.id, order_by: [m.folder, m.uid])
    )
  end

  defp connect!(server, password \\ "imap-pass") do
    {:ok, conn} =
      @client.connect(%{
        host: "127.0.0.1",
        port: ScriptedImapServer.port(server),
        tls: "none",
        username: "support@acme.test",
        password: password
      })

    conn
  end

  setup do
    org_id = Tenancy.get_org_by_slug!("soylent").id
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "Wire #{n}", slug: "wire-#{n}", kind: "channel"})
    %{org_id: org_id, admin: admin!(org_id), space: space}
  end

  describe "against GreenMail's reply bytes" do
    test "LIST after GreenMail's `LOGIN completed.` is exactly {name, flags} pairs" do
      server = ScriptedImapServer.start!()
      ScriptedImapServer.put_folder(server, "Support")
      ScriptedImapServer.put_folder(server, ~s(Weird "Name"))

      conn = connect!(server)

      assert {:ok, [{"INBOX", []}, {"Support", []}, {~s(Weird "Name"), []}]} =
               @client.list_folders(conn)

      assert :ok = @client.logout(conn)
    end

    test "EXAMINE, UID SEARCH and a BODY.PEEK[] literal round-trip byte-exact" do
      server = ScriptedImapServer.start!()
      ScriptedImapServer.put_folder(server, "Support")
      raw = raw("peek-1@x.test")
      uid = ScriptedImapServer.deliver(server, "Support", raw)

      conn = connect!(server)
      assert {:ok, uidvalidity, 1} = @client.examine(conn, "Support")
      assert is_integer(uidvalidity) and uidvalidity > 0
      assert {:ok, [^uid]} = @client.uids_after(conn, 0)
      assert {:ok, []} = @client.uids_after(conn, uid)
      assert {:ok, ^raw} = @client.fetch_raw(conn, uid)
      assert :ok = @client.logout(conn)

      assert ScriptedImapServer.flags(server, "Support", uid) == ["\\Recent"]
    end

    test "UID SEARCH SINCE sends an RFC 3501 date and returns the matching UIDs (task 01a13ba5)" do
      server = ScriptedImapServer.start!()
      ScriptedImapServer.put_folder(server, "Support")

      old =
        ScriptedImapServer.deliver(server, "Support", raw("old@x.test"),
          internaldate: ~D[2026-09-04]
        )

      edge =
        ScriptedImapServer.deliver(server, "Support", raw("edge@x.test"),
          internaldate: ~D[2026-09-05]
        )

      new =
        ScriptedImapServer.deliver(server, "Support", raw("new@x.test"),
          internaldate: ~D[2026-10-01]
        )

      conn = connect!(server)
      assert {:ok, _uidvalidity, 3} = @client.examine(conn, "Support")
      # SINCE is inclusive of the day itself.
      assert {:ok, [^edge, ^new]} = @client.uids_since(conn, ~D[2026-09-05])
      assert {:ok, []} = @client.uids_since(conn, ~D[2026-10-02])
      assert {:ok, [^old, ^edge, ^new]} = @client.uids_since(conn, ~D[2026-01-01])
      assert :ok = @client.logout(conn)

      search_lines = Enum.filter(ScriptedImapServer.commands(server), &(&1 =~ "SEARCH"))

      # The exact bytes after the tag: day unpadded, English month, 4-digit year.
      assert search_lines == [
               "UID SEARCH SINCE 5-Sep-2026",
               "UID SEARCH SINCE 2-Oct-2026",
               "UID SEARCH SINCE 1-Jan-2026"
             ]
    end

    test "imap_date/1 is day-Mon-yyyy with English months for every month" do
      months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

      for {name, month} <- Enum.with_index(months, 1) do
        assert WireClient.imap_date(Date.new!(2026, month, 1)) == "1-#{name}-2026"
      end

      assert WireClient.imap_date(~D[2026-12-31]) == "31-Dec-2026"
      assert WireClient.imap_date(~D[0999-03-09]) == "9-Mar-0999"
    end

    test "EXAMINE without UIDNEXT falls back to STATUS" do
      server = ScriptedImapServer.start!(omit_uidnext: true)
      ScriptedImapServer.put_folder(server, "Support")
      ScriptedImapServer.deliver(server, "Support", raw("s-1@x.test"))
      ScriptedImapServer.deliver(server, "Support", raw("s-2@x.test"))

      conn = connect!(server)
      assert {:ok, _uidvalidity, 2} = @client.examine(conn, "Support")
      assert Enum.any?(ScriptedImapServer.commands(server), &String.starts_with?(&1, "STATUS "))
      @client.logout(conn)
    end

    test "a tagged NO or BAD is an error, never a raise" do
      server = ScriptedImapServer.start!()
      conn = connect!(server)

      assert {:error, {:no, _}} = @client.examine(conn, "Missing")
      # No folder selected: the server answers UID commands with BAD.
      assert {:error, {:bad, "Invalid command."}} = @client.uids_after(conn, 0)
      assert :ok = @client.logout(conn)
    end

    test "a non-ASCII password goes as a synchronising literal" do
      server = ScriptedImapServer.start!()
      conn = connect!(server, "pässwörd")
      assert {:ok, [{"INBOX", []}]} = @client.list_folders(conn)
      @client.logout(conn)

      assert ["LOGIN \"support@acme.test\" {literal:pässwörd}" | _] =
               ScriptedImapServer.commands(server)
    end

    test "connecting to a closed port is an error" do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      assert {:error, {:connect, _}} =
               @client.connect(%{
                 host: "127.0.0.1",
                 port: port,
                 tls: "none",
                 username: "u",
                 password: "p"
               })
    end
  end

  describe "Inbound.poll/2 end to end over the socket" do
    test "a scope of [\"Support\"] ingests only Support mail", ctx do
      server = ScriptedImapServer.start!()
      ScriptedImapServer.put_folder(server, "Support")
      ScriptedImapServer.put_folder(server, "Sales")
      account = account!(ctx, server, %{"read_folders" => ["Support"]})

      # First poll: cursor at the current top, nothing backfilled.
      ScriptedImapServer.deliver(server, "Support", raw("old@x.test"))
      assert %{folders: ["Support"], ingested: 0} = poll!(account)

      ScriptedImapServer.deliver(server, "INBOX", raw("inbox-1@x.test"))
      ScriptedImapServer.deliver(server, "Sales", raw("sales-1@x.test"))
      support_uid = ScriptedImapServer.deliver(server, "Support", raw("support-1@x.test"))

      assert %{folders: ["Support"], ingested: 1} = poll!(account)

      assert [%InboundMessage{folder: "Support", uid: ^support_uid}] = rows(account)
      assert ScriptedImapServer.flags(server, "Support", support_uid) == ["\\Recent"]

      examined =
        for "EXAMINE " <> name <- ScriptedImapServer.commands(server), uniq: true, do: name

      assert examined == [~s("Support")]
    end

    test "an empty scope ingests every folder", ctx do
      server = ScriptedImapServer.start!()
      ScriptedImapServer.put_folder(server, "Support")
      account = account!(ctx, server)

      assert %{folders: ["INBOX", "Support"], ingested: 0} = poll!(account)

      ScriptedImapServer.deliver(server, "INBOX", raw("inbox-1@x.test"))
      ScriptedImapServer.deliver(server, "Support", raw("support-1@x.test"))

      assert %{ingested: 2} = poll!(account)
      assert [%{folder: "INBOX"}, %{folder: "Support"}] = rows(account)

      posted =
        Repo.aggregate(
          from(m in Message,
            where:
              m.space_id == ^ctx.space.id and
                fragment("?->>'source'", m.metadata) == "email_inbound"
          ),
          :count
        )

      assert posted == 2
    end

    test "five polls, each ending in LOGOUT + server close, log no crash", ctx do
      server = ScriptedImapServer.start!()
      ScriptedImapServer.put_folder(server, "Support")
      account = account!(ctx, server)

      log =
        capture_log(fn ->
          for i <- 1..5 do
            ScriptedImapServer.deliver(server, "Support", raw("five-#{i}@x.test"))
            assert {:ok, _} = Inbound.poll(Repo.reload!(account), client: @client)
          end

          # Let any late socket message reach whatever might crash on it.
          Process.sleep(100)
        end)

      refute log =~ "terminating"
      refute log =~ "[error]"
      assert length(rows(account)) == 4

      verbs =
        server
        |> ScriptedImapServer.commands()
        |> Enum.map(&(&1 |> String.split(" ") |> hd() |> String.upcase()))
        |> Enum.uniq()

      assert verbs -- @allowed == []

      fetches = for "UID FETCH " <> rest <- ScriptedImapServer.commands(server), do: rest
      assert fetches != []
      assert Enum.all?(fetches, &(&1 =~ ~r/\A\d+ \(BODY\.PEEK\[\]\)\z/))
    end
  end
end
