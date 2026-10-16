defmodule Platform.Federation.ToolSurfaceMailInboundTest do
  @moduledoc """
  `mail_inbound_list` / `mail_inbound_get` (task
  01a13ba5-42a7-7000-8f2b-4c63003f3f92 stage 2): backfilled mail reaches the
  agents of an account's inbound space by PULL, never by post.

    * an insider (participant of the account's live inbound space) lists and
      reads a backfilled row, rendered exactly as the chat post would be:
      SECURITY NOTICE wrapper, 32_768-byte cap with its note, mentions
      escaped;
    * an outsider, a sibling-org agent, an account with no inbound space, an
      archived space, a history bound, an unknown id and a malformed id all
      get ONE identical not-found envelope;
    * no call writes a chat message or broadcasts on `"mail:inbound"`.

  async: false — flips `:mail_enabled` in application env.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Federation.ToolSurface
  alias Platform.Mail
  alias Platform.Mail.FolderCursor
  alias Platform.Mail.Imap.FakeClient
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @tools ~w(mail_inbound_list mail_inbound_get)
  @to "ops@soylent.test"
  @cap 32_768

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp admin!(org_id) do
    n = u()

    user =
      %User{}
      |> User.changeset(%{
        email: "inbound-tool-#{n}@example.com",
        name: "Inbound tool #{n}",
        oidc_sub: "oidc-inbound-tool-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: "admin",
      external: false
    })
    |> Repo.insert!()

    user
  end

  defp agent!(label, org_id) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "inbound-#{label}-#{u()}",
      name: "Agent #{label}",
      status: "active",
      metadata: %{"org_id" => org_id}
    })
    |> Repo.insert!()
  end

  defp space! do
    n = u()

    {:ok, space} =
      Chat.create_space(%{name: "Inbound #{n}", slug: "inbound-#{n}", kind: "channel"})

    space
  end

  defp join!(space, agent, extra \\ %{}) do
    {:ok, participant} =
      Chat.add_participant(
        space.id,
        Map.merge(
          %{
            participant_type: "agent",
            participant_id: agent.id,
            display_name: agent.name,
            role: "member",
            joined_at: DateTime.utc_now()
          },
          extra
        )
      )

    participant
  end

  defp account!(admin, org_id, space_id, overrides \\ %{}) do
    n = u()

    attrs =
      Map.merge(
        %{
          "name" => "inbound-#{n}",
          "smtp_tls" => "starttls",
          "username" => @to,
          "imap_host" => "imap-tool-#{n}.acme.test",
          "imap_port" => 993,
          "imap_tls" => "tls",
          "read_enabled" => true,
          "inbound_space_id" => space_id
        },
        overrides
      )

    {:ok, account} = Mail.create_account(admin, org_id, attrs, %{imap: "imap-pass"})
    account
  end

  defp raw(message_id, opts \\ []) do
    subject = Keyword.get(opts, :subject, "Re: your application")
    body = Keyword.get(opts, :body, "Thanks, we received it.")
    date = Keyword.get(opts, :date, "Tue, 22 Sep 2026 10:00:00 +0000")

    "From: Recruiter <recruiter@corp.test>\r\nTo: #{@to}\r\n" <>
      "Subject: #{subject}\r\nDate: #{date}\r\n" <>
      "Message-ID: <#{message_id}>\r\n\r\n#{body}\r\n"
  end

  # The backfill's own storage call (`Backfill.run/3` ingests every UID this
  # way): stored, no post, no broadcast.
  defp backfilled!(account, bytes, uid \\ nil) do
    assert 1 == Inbound.ingest(account, "INBOX", 7, uid || u(), bytes, quiet: true)

    Repo.one!(
      from(m in InboundMessage,
        where: m.account_id == ^account.id,
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: 1
      )
    )
  end

  defp list(agent, args),
    do: ToolSurface.execute("mail_inbound_list", args, %{agent_id: agent.id})

  defp get(agent, id),
    do: ToolSurface.execute("mail_inbound_get", %{"id" => id}, %{agent_id: agent.id})

  defp chat_count, do: Repo.aggregate(Message, :count)

  # `ExternalContent.marker_id/0` is 16 lowercase hex characters.
  defp mask_marker_ids(content),
    do: Regex.replace(~r/(?<![0-9a-f])[0-9a-f]{16}(?![0-9a-f])/, content, "<marker-id>")

  # The envelope for a well-formed id that names no row.
  defp unknown_envelope(ctx) do
    assert {:error, envelope} = get(ctx.insider, Ecto.UUID.generate())
    assert envelope.code == :not_found
    assert envelope.recoverable == false
    envelope
  end

  defp set_flag(value), do: Application.put_env(:platform, :mail_enabled, value)

  setup do
    previous = Application.fetch_env(:platform, :mail_enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    set_flag(true)

    org_id = Tenancy.get_org_by_slug!("soylent").id
    other_org_id = Tenancy.get_org_by_slug!("sxi").id
    admin = admin!(org_id)
    space = space!()
    account = account!(admin, org_id, space.id)

    insider = agent!("insider", org_id)
    join!(space, insider)

    %{
      org_id: org_id,
      other_org_id: other_org_id,
      admin: admin,
      space: space,
      account: account,
      insider: insider,
      outsider: agent!("outsider", org_id)
    }
  end

  # ── surface ───────────────────────────────────────────────────────────────

  describe "the surface" do
    test "listed in the mail bundle and only there, while the module is on" do
      mail = ToolSurface.list_tools(["mail"])
      for tool <- @tools, do: assert(%{bundle: "mail"} = Enum.find(mail, &(&1.name == tool)))

      others = ToolSurface.list_tools(ToolSurface.all_bundles() -- ["mail"])
      refute Enum.any?(others, &(&1.name in @tools))
      refute Enum.any?(ToolSurface.list_tools(["messaging"]), &(&1.name in @tools))
    end

    test "off: listed nowhere, and execute refuses recoverably without reading", ctx do
      row = backfilled!(ctx.account, raw("off-#{u()}@corp.test"))
      set_flag(false)

      names = ToolSurface.tool_definitions() |> Enum.map(& &1.name)
      for tool <- @tools, do: refute(tool in names)

      assert {:error, %{code: :mail_disabled, recoverable: true}} =
               list(ctx.insider, %{"org_id" => ctx.org_id})

      assert {:error, %{code: :mail_disabled, recoverable: true}} = get(ctx.insider, row.id)
    end

    test "an anonymous caller is refused", ctx do
      assert {:error, %{code: :unauthorized}} =
               ToolSurface.execute("mail_inbound_list", %{"org_id" => ctx.org_id}, %{})
    end
  end

  # ── the insider ───────────────────────────────────────────────────────────

  describe "an agent in the inbound space" do
    test "lists a backfilled row: metadata only, mentions escaped in the subject", ctx do
      row = backfilled!(ctx.account, raw("list-#{u()}@corp.test", subject: "Ping @[y] now"))
      assert row.ingest_source == "backfill"
      assert row.chat_message_id == nil

      assert {:ok, env} = list(ctx.insider, %{"org_id" => ctx.org_id})
      assert env.total == 1
      assert env.has_more == false
      assert [listed] = env.messages

      assert listed.id == row.id
      assert listed.account_id == ctx.account.id
      assert listed.folder == "INBOX"
      assert listed.ingest_source == "backfill"
      assert listed.from == "Recruiter <recruiter@corp.test>"
      assert listed.subject == "Ping ＠[y] now"
      assert listed.received_at == DateTime.to_iso8601(row.received_at)

      refute Map.has_key?(listed, :content)
      refute Map.has_key?(listed, :text_body)
      refute Map.has_key?(listed, :raw)
    end

    test "reads it rendered as the chat post would be: wrapper, cap with note, mentions escaped",
         ctx do
      # Over the cap, with a marker past it and an injected mention token.
      body = "Hello @[x], please act.\n" <> String.duplicate("a", @cap + 500) <> "TAILMARK"
      row = backfilled!(ctx.account, raw("big-#{u()}@corp.test", body: body))
      assert byte_size(row.text_body) > @cap

      assert {:ok, got} = get(ctx.insider, row.id)

      assert got.id == row.id
      assert got.ingest_source == "backfill"
      assert got.truncated == true
      assert got.body_bytes == byte_size(row.text_body)

      # Exactly the live path's renderer, byte for byte once the wrapper's
      # per-render random marker ids are masked (they differ on every call,
      # which is the wrapper working).
      live = Inbound.render_content(ctx.account, row, %{text: row.text_body})
      assert got.content != live
      assert mask_marker_ids(got.content) == mask_marker_ids(live)

      assert got.content =~ "SECURITY NOTICE"
      assert got.content =~ "EXTERNAL, UNTRUSTED"
      assert got.content =~ "Email to #{@to}, from Recruiter <recruiter@corp.test>"

      assert got.content =~
               "[Truncated: the email body is #{byte_size(row.text_body)} bytes; " <>
                 "the first #{@cap} are shown."

      refute got.content =~ "TAILMARK"
      refute got.content =~ "@["
      assert got.content =~ "＠[x]"
    end

    test "a body under the cap is whole and carries no note", ctx do
      row = backfilled!(ctx.account, raw("small-#{u()}@corp.test", body: "short body ENDMARK"))

      assert {:ok, got} = get(ctx.insider, row.id)
      assert got.truncated == false
      assert got.content =~ "ENDMARK"
      refute got.content =~ "[Truncated:"
      assert got.content =~ "SECURITY NOTICE"
    end

    test "a row from a real backfill run is listed and readable" do
      # Rebuild the rig with a polled cursor so `start_backfill/4` imports.
      org_id = Tenancy.get_org_by_slug!("soylent").id
      admin = admin!(org_id)
      space = space!()
      account = account!(admin, org_id, space.id)
      agent = agent!("rig", org_id)
      join!(space, agent)

      FakeClient.start_server!(account.imap_host)
      FakeClient.put_folder(account.imap_host, "INBOX", uidvalidity: 7)

      FakeClient.deliver(account.imap_host, "INBOX", raw("rig-#{u()}@corp.test"),
        internaldate: Date.add(Date.utc_today(), -5)
      )

      assert {:ok, %{ingested: 0}} = Inbound.poll(Repo.reload!(account), client: FakeClient)
      assert %FolderCursor{} = Repo.get_by!(FolderCursor, account_id: account.id, folder: "INBOX")

      before = chat_count()
      assert {:ok, run} = Mail.start_backfill(admin, Repo.reload!(account), 30, runner: :inline)
      assert run.imported == 1
      assert chat_count() == before

      assert {:ok, %{messages: [listed], total: 1}} = list(agent, %{"org_id" => org_id})
      assert listed.ingest_source == "backfill"
      assert {:ok, %{content: content}} = get(agent, listed.id)
      assert content =~ "Thanks, we received it."
    end

    test "live and backfilled rows are listed alike, newest first, paged", ctx do
      for {id, date} <- [
            {"p1", "Mon, 21 Sep 2026 10:00:00 +0000"},
            {"p2", "Tue, 22 Sep 2026 10:00:00 +0000"},
            {"p3", "Wed, 23 Sep 2026 10:00:00 +0000"}
          ] do
        backfilled!(ctx.account, raw("#{id}-#{u()}@corp.test", date: date, subject: id))
      end

      assert {:ok, page} = list(ctx.insider, %{"org_id" => ctx.org_id, "limit" => 2})
      assert Enum.map(page.messages, & &1.subject) == ["p3", "p2"]
      assert page.total == 3
      assert page.has_more == true

      assert {:ok, rest} =
               list(ctx.insider, %{"org_id" => ctx.org_id, "limit" => 2, "offset" => 2})

      assert Enum.map(rest.messages, & &1.subject) == ["p1"]
      assert rest.has_more == false

      assert {:ok, since} =
               list(ctx.insider, %{"org_id" => ctx.org_id, "since" => "2026-09-22"})

      assert Enum.map(since.messages, & &1.subject) == ["p3", "p2"]
      assert since.total == 2

      assert {:error, %{recoverable: true}} =
               list(ctx.insider, %{"org_id" => ctx.org_id, "since" => "yesterday"})
    end

    test "account_id narrows the list", ctx do
      other_space = space!()
      join!(other_space, ctx.insider)
      other = account!(ctx.admin, ctx.org_id, other_space.id)

      mine = backfilled!(ctx.account, raw("narrow-a-#{u()}@corp.test"))
      _theirs = backfilled!(other, raw("narrow-b-#{u()}@corp.test"))

      assert {:ok, %{total: 2}} = list(ctx.insider, %{"org_id" => ctx.org_id})

      assert {:ok, %{messages: [only], total: 1}} =
               list(ctx.insider, %{"org_id" => ctx.org_id, "account_id" => ctx.account.id})

      assert only.id == mine.id

      assert {:ok, %{messages: [], total: 0}} =
               list(ctx.insider, %{"org_id" => ctx.org_id, "account_id" => "not-a-uuid"})
    end
  end

  # ── everyone else ─────────────────────────────────────────────────────────

  describe "the not-found envelope" do
    setup ctx do
      %{row: backfilled!(ctx.account, raw("secret-#{u()}@corp.test"))}
    end

    test "an agent NOT in the space: nothing listed, get is not-found", ctx do
      assert {:ok, %{messages: [], total: 0}} = list(ctx.outsider, %{"org_id" => ctx.org_id})
      assert {:error, envelope} = get(ctx.outsider, ctx.row.id)
      assert envelope.code == :not_found
      assert envelope == unknown_envelope(ctx)
    end

    test "an agent of another org, even as a participant of the space", ctx do
      sibling = agent!("sibling", ctx.other_org_id)
      join!(ctx.space, sibling)

      assert {:error, envelope} = get(sibling, ctx.row.id)
      assert envelope == unknown_envelope(ctx)

      # Listing the other org is the tenant pin's refusal, as for drafts.
      assert {:error, %{error: "unauthorized: " <> _}} =
               list(sibling, %{"org_id" => ctx.org_id})

      assert {:ok, %{messages: [], total: 0}} = list(sibling, %{"org_id" => ctx.other_org_id})
    end

    test "an account with no inbound space has no agent audience", ctx do
      bare = account!(ctx.admin, ctx.org_id, nil)
      assert bare.inbound_space_id == nil
      row = backfilled!(bare, raw("bare-#{u()}@corp.test"))

      assert {:ok, %{total: total, messages: messages}} =
               list(ctx.insider, %{"org_id" => ctx.org_id})

      refute Enum.any?(messages, &(&1.id == row.id))
      assert total == 1

      assert {:error, envelope} = get(ctx.insider, row.id)
      assert envelope == unknown_envelope(ctx)
    end

    test "an archived inbound space reads as nothing", ctx do
      {:ok, _} = Chat.archive_space(ctx.space)

      assert {:ok, %{messages: [], total: 0}} = list(ctx.insider, %{"org_id" => ctx.org_id})
      assert {:error, envelope} = get(ctx.insider, ctx.row.id)
      assert envelope == unknown_envelope(ctx)
    end

    test "a removed participant reads as nothing", ctx do
      ctx.space.id |> Chat.get_agent_participant(ctx.insider) |> Chat.remove_participant()

      assert {:error, envelope} = get(ctx.insider, ctx.row.id)
      assert envelope == unknown_envelope(ctx)
    end

    test "a history-bounded participant reads nothing from before its bound", ctx do
      # Joined by a mention grant an hour from now: the existing backfilled
      # row (old Date header, inserted now) and a row whose sender forged a
      # far-future Date header (inserted now) are both before the bound.
      bounded = agent!("bounded", ctx.org_id)
      join!(ctx.space, bounded, %{history_visible_from: DateTime.add(DateTime.utc_now(), 3600)})

      forged =
        backfilled!(
          ctx.account,
          raw("forged-#{u()}@corp.test", date: "Fri, 01 Jan 2099 00:00:00 +0000")
        )

      assert DateTime.compare(forged.received_at, DateTime.utc_now()) == :gt

      assert {:ok, %{messages: [], total: 0}} = list(bounded, %{"org_id" => ctx.org_id})
      assert {:error, e1} = get(bounded, ctx.row.id)
      assert {:error, e2} = get(bounded, forged.id)
      assert e1 == unknown_envelope(ctx)
      assert e2 == unknown_envelope(ctx)

      # Positive control: the unbounded insider reads both.
      assert {:ok, _} = get(ctx.insider, ctx.row.id)
      assert {:ok, _} = get(ctx.insider, forged.id)
    end

    test "a malformed id is the same not-found", ctx do
      assert {:error, envelope} = get(ctx.insider, "not-a-uuid")
      assert envelope == unknown_envelope(ctx)
    end

    test "positive control: the insider reads the very row the others cannot", ctx do
      assert {:ok, %{id: id}} = get(ctx.insider, ctx.row.id)
      assert id == ctx.row.id
    end
  end

  # ── quiet ─────────────────────────────────────────────────────────────────

  describe "quiet" do
    test "no tool call writes a chat message or broadcasts on mail:inbound", ctx do
      row = backfilled!(ctx.account, raw("quiet-#{u()}@corp.test"))
      outsider_row_id = row.id
      :ok = Inbound.subscribe()
      before = chat_count()
      rows_before = Repo.aggregate(InboundMessage, :count)

      assert {:ok, _} = list(ctx.insider, %{"org_id" => ctx.org_id})
      assert {:ok, _} = get(ctx.insider, row.id)
      assert {:error, _} = get(ctx.outsider, outsider_row_id)

      assert chat_count() == before
      assert Repo.aggregate(InboundMessage, :count) == rows_before
      assert Repo.reload!(row).chat_message_id == nil
      assert Repo.reload!(row).updated_at == row.updated_at
      refute_receive {:mail_inbound_ingested, _}, 100
    end
  end
end
