defmodule Platform.Federation.ToolSurfaceMailInboundTest do
  @moduledoc """
  `mail_inbound_list` / `mail_inbound_get`: the pull reads of task
  01a13ba5 stage 2, scoped by task 01a1ea5b stage 3 (Email privacy) to the
  agent's mailbox GRANT intersected with what every human in the named
  `space_id` (the AUDIENCE) may read, with the agent a current PARTICIPANT
  of that space.

    * a granted agent answering the owner (DM D) lists and reads, rendered
      exactly as the chat post would be: SECURITY NOTICE wrapper,
      32_768-byte cap with its note, mentions escaped;
    * the same agent answering a space that also holds a non-owner (X)
      reads nothing and gets the verbatim `withheld_notice`, never a count,
      a subject or a placeholder;
    * an ungranted participant agent (even of the inbound space), a revoked
      agent, a missing / foreign / archived space, an empty audience, a
      sibling org and an unknown id all read nothing, with ONE not-found
      envelope;
    * every list and get writes one audit row with no content; nothing
      else is written or broadcast.

  Mutation controls (stage 3 report): dropping the grant term, the
  audience intersection or the participant check each turns a named test
  here red.

  async: false — flips `:mail_enabled` in application env.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Audit.Event
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Federation.ToolSurface
  alias Platform.Mail
  alias Platform.Mail.FolderCursor
  alias Platform.Mail.Imap.FakeClient
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Mail.Ownership
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @tools ~w(mail_inbound_list mail_inbound_get)
  @to "ops@initech.test"
  @cap 32_768
  @notice "I can't share mail from a mailbox you don't have access to"

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp person!(org_id, role, label \\ "person") do
    n = u()

    user =
      %User{}
      |> User.changeset(%{
        email: "inbound-tool-#{label}-#{n}@example.com",
        name: "#{String.capitalize(label)} #{n}",
        oidc_sub: "oidc-inbound-tool-#{label}-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: false
    })
    |> Repo.insert!()

    user
  end

  defp admin!(org_id), do: person!(org_id, "admin", "admin")

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

  defp join_user!(space, user) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        role: "member",
        joined_at: DateTime.utc_now()
      })

    participant
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

  defp personal!(admin, account, owner) do
    {:ok, account} =
      Ownership.set_owner(admin, account, %{kind: "personal", owner_user_id: owner.id})

    account
  end

  defp grant!(actor, account, agent) do
    {:ok, _} = Ownership.grant(actor, account, {:agent, agent.id})
    :ok
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

  defp sid(nil), do: nil
  defp sid(%{id: id}), do: id
  defp sid(id) when is_binary(id), do: id

  defp list(agent, space, args) do
    args = if space == :omit, do: args, else: Map.put(args, "space_id", sid(space))
    ToolSurface.execute("mail_inbound_list", args, %{agent_id: agent.id})
  end

  defp get(agent, space, id) do
    args = if space == :omit, do: %{"id" => id}, else: %{"id" => id, "space_id" => sid(space)}
    ToolSurface.execute("mail_inbound_get", args, %{agent_id: agent.id})
  end

  defp chat_count, do: Repo.aggregate(Message, :count)

  defp audit_rows(agent) do
    from(e in Event,
      where: e.event_type == "platform.mail.agent_read" and e.actor_id == ^agent.id,
      order_by: [asc: e.inserted_at, asc: e.id]
    )
    |> Repo.all()
  end

  # `ExternalContent.marker_id/0` is 16 lowercase hex characters.
  defp mask_marker_ids(content),
    do: Regex.replace(~r/(?<![0-9a-f])[0-9a-f]{16}(?![0-9a-f])/, content, "<marker-id>")

  # The envelope for a well-formed id that names no row.
  defp unknown_envelope(ctx) do
    assert {:error, envelope} = get(ctx.insider, ctx.dm, Ecto.UUID.generate())
    assert envelope.code == :not_found
    assert envelope.recoverable == false
    envelope
  end

  # The list envelope for a space the agent may not answer in.
  defp list_not_found(ctx) do
    assert {:error, envelope} = list(ctx.insider, Ecto.UUID.generate(), %{"org_id" => ctx.org_id})
    assert envelope.code == :not_found
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

    org_id = Tenancy.get_org_by_slug!("initech").id
    other_org_id = Tenancy.get_org_by_slug!("globex").id
    admin = admin!(org_id)
    owner = person!(org_id, "member", "owner")
    other = person!(org_id, "member", "other")

    # The mailbox P, owned by `owner`, with an inbound channel C.
    inbound = space!()
    account = admin |> account!(org_id, inbound.id) |> then(&personal!(admin, &1, owner))

    # Agent A: granted P by its owner.
    insider = agent!("insider", org_id)
    :ok = grant!(owner, account, insider)

    # DM D: the owner and A. Space X: the owner, a non-owner, and A.
    dm = space!()
    join_user!(dm, owner)
    join!(dm, insider)

    mixed = space!()
    join_user!(mixed, owner)
    join_user!(mixed, other)
    join!(mixed, insider)

    # Agent B: NOT granted, yet a participant of the inbound channel and of D.
    outsider = agent!("outsider", org_id)
    join!(inbound, outsider)
    join!(dm, outsider)

    %{
      org_id: org_id,
      other_org_id: other_org_id,
      admin: admin,
      owner: owner,
      other: other,
      inbound: inbound,
      account: account,
      insider: insider,
      outsider: outsider,
      dm: dm,
      mixed: mixed
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

    test "both tools require space_id and say where the rule cannot be enforced" do
      for tool <- @tools do
        definition =
          Enum.find(Platform.Federation.MailInboundTools.definitions(), &(&1.name == tool))

        assert definition.parameters.space_id.required == true
        assert definition.limitations =~ "Where this cannot be enforced"
        assert definition.limitations =~ "space_id is asserted by you"
        assert definition.limitations =~ "context and memory"
        assert definition.limitations =~ "content provenance"
        assert definition.limitations =~ "operator can see its transcripts"
        refute definition.description =~ "inbound chat space you are a participant of"
      end
    end

    test "off: listed nowhere, and execute refuses recoverably without reading", ctx do
      row = backfilled!(ctx.account, raw("off-#{u()}@corp.test"))
      set_flag(false)

      names = ToolSurface.tool_definitions() |> Enum.map(& &1.name)
      for tool <- @tools, do: refute(tool in names)

      assert {:error, %{code: :mail_disabled, recoverable: true}} =
               list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id})

      assert {:error, %{code: :mail_disabled, recoverable: true}} =
               get(ctx.insider, ctx.dm, row.id)
    end

    test "an anonymous caller is refused", ctx do
      assert {:error, %{code: :unauthorized}} =
               ToolSurface.execute(
                 "mail_inbound_list",
                 %{"org_id" => ctx.org_id, "space_id" => ctx.dm.id},
                 %{}
               )
    end
  end

  # ── the owner's audience ──────────────────────────────────────────────────

  describe "a granted agent answering the owner" do
    test "lists a backfilled row: metadata only, mentions escaped, audience and access line",
         ctx do
      row = backfilled!(ctx.account, raw("list-#{u()}@corp.test", subject: "Ping @[y] now"))
      assert row.ingest_source == "backfill"
      assert row.chat_message_id == nil

      assert {:ok, env} = list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id})
      assert env.total == 1
      assert env.has_more == false
      assert [listed] = env.messages
      refute Map.has_key?(env, :withheld_notice)
      assert env.audience == [ctx.owner.name]
      assert env.access_line == "Visible to you · #{ctx.insider.name}"

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

      assert {:ok, got} = get(ctx.insider, ctx.dm, row.id)

      assert got.id == row.id
      assert got.ingest_source == "backfill"
      assert got.truncated == true
      assert got.body_bytes == byte_size(row.text_body)
      assert got.audience == [ctx.owner.name]
      assert got.access_line == "Visible to you · #{ctx.insider.name}"

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

      assert {:ok, got} = get(ctx.insider, ctx.dm, row.id)
      assert got.truncated == false
      assert got.content =~ "ENDMARK"
      refute got.content =~ "[Truncated:"
      assert got.content =~ "SECURITY NOTICE"
    end

    test "a granted mailbox with no inbound space is readable: the grant is the right", ctx do
      bare = ctx.admin |> account!(ctx.org_id, nil) |> then(&personal!(ctx.admin, &1, ctx.owner))
      assert bare.inbound_space_id == nil
      :ok = grant!(ctx.owner, bare, ctx.insider)
      row = backfilled!(bare, raw("bare-#{u()}@corp.test"))

      assert {:ok, %{id: id}} = get(ctx.insider, ctx.dm, row.id)
      assert id == row.id
    end

    test "a row from a real backfill run is listed and readable", ctx do
      # Rebuild the rig with a polled cursor so `start_backfill/4` imports.
      space = space!()

      account =
        ctx.admin |> account!(ctx.org_id, space.id) |> then(&personal!(ctx.admin, &1, ctx.owner))

      agent = agent!("rig", ctx.org_id)
      :ok = grant!(ctx.owner, account, agent)
      join!(ctx.dm, agent)

      FakeClient.start_server!(account.imap_host)
      FakeClient.put_folder(account.imap_host, "INBOX", uidvalidity: 7)

      FakeClient.deliver(account.imap_host, "INBOX", raw("rig-#{u()}@corp.test"),
        internaldate: Date.add(Date.utc_today(), -5)
      )

      assert {:ok, %{ingested: 0}} = Inbound.poll(Repo.reload!(account), client: FakeClient)
      assert %FolderCursor{} = Repo.get_by!(FolderCursor, account_id: account.id, folder: "INBOX")

      before = chat_count()

      assert {:ok, run} =
               Mail.start_backfill(ctx.admin, Repo.reload!(account), 30, runner: :inline)

      assert run.imported == 1
      assert chat_count() == before

      assert {:ok, %{messages: [listed], total: 1}} =
               list(agent, ctx.dm, %{"org_id" => ctx.org_id})

      assert listed.ingest_source == "backfill"
      assert {:ok, %{content: content}} = get(agent, ctx.dm, listed.id)
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

      args = %{"org_id" => ctx.org_id}

      assert {:ok, page} = list(ctx.insider, ctx.dm, Map.put(args, "limit", 2))
      assert Enum.map(page.messages, & &1.subject) == ["p3", "p2"]
      assert page.total == 3
      assert page.has_more == true

      assert {:ok, rest} =
               list(ctx.insider, ctx.dm, Map.merge(args, %{"limit" => 2, "offset" => 2}))

      assert Enum.map(rest.messages, & &1.subject) == ["p1"]
      assert rest.has_more == false

      assert {:ok, since} = list(ctx.insider, ctx.dm, Map.put(args, "since", "2026-09-22"))
      assert Enum.map(since.messages, & &1.subject) == ["p3", "p2"]
      assert since.total == 2

      assert {:error, %{recoverable: true}} =
               list(ctx.insider, ctx.dm, Map.put(args, "since", "yesterday"))
    end

    test "account_id narrows the list", ctx do
      other =
        ctx.admin |> account!(ctx.org_id, nil) |> then(&personal!(ctx.admin, &1, ctx.owner))

      :ok = grant!(ctx.owner, other, ctx.insider)

      mine = backfilled!(ctx.account, raw("narrow-a-#{u()}@corp.test"))
      _theirs = backfilled!(other, raw("narrow-b-#{u()}@corp.test"))

      assert {:ok, %{total: 2}} = list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id})

      assert {:ok, %{messages: [only], total: 1}} =
               list(ctx.insider, ctx.dm, %{
                 "org_id" => ctx.org_id,
                 "account_id" => ctx.account.id
               })

      assert only.id == mine.id

      assert {:ok, %{messages: [], total: 0}} =
               list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id, "account_id" => "not-a-uuid"})
    end
  end

  # ── the audience term ─────────────────────────────────────────────────────

  describe "the audience" do
    setup ctx do
      %{
        row:
          backfilled!(
            ctx.account,
            raw("aud-#{u()}@corp.test", subject: "SUBJ-P-1", body: "BODY-P-1")
          )
      }
    end

    test "a non-owner in the same space: nothing listed, the verbatim withheld_notice, no count or subject",
         ctx do
      assert {:ok, env} = list(ctx.insider, ctx.mixed, %{"org_id" => ctx.org_id})
      assert env.messages == []
      assert env.total == 0
      assert env.has_more == false
      assert env.withheld_notice == @notice
      assert Enum.sort(env.audience) == Enum.sort([ctx.owner.name, ctx.other.name])
      assert env.access_line == "Visible to 2 people"

      rendered = inspect(env)
      refute rendered =~ "SUBJ-P-1"
      refute rendered =~ "BODY-P-1"
      refute rendered =~ "recruiter@corp.test"
      refute rendered =~ ctx.account.id
      refute rendered =~ ctx.row.id

      # Positive control: the same agent, the owner alone, reads the row.
      assert {:ok, %{messages: [%{id: id}]}} =
               list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id})

      assert id == ctx.row.id
    end

    test "get of a granted row for that audience is withheld: the notice, no content or metadata",
         ctx do
      assert {:error, envelope} = get(ctx.insider, ctx.mixed, ctx.row.id)
      assert envelope.code == :withheld
      assert envelope.withheld_notice == @notice
      refute Map.has_key?(envelope, :content)

      rendered = inspect(envelope)
      refute rendered =~ "SUBJ-P-1"
      refute rendered =~ "BODY-P-1"
      refute rendered =~ "recruiter@corp.test"
      refute rendered =~ ctx.account.id

      assert {:ok, %{content: content}} = get(ctx.insider, ctx.dm, ctx.row.id)
      assert content =~ "BODY-P-1"
    end

    test "a shared mailbox both humans read is listed; the personal one is withheld", ctx do
      support =
        ctx.admin
        |> account!(ctx.org_id, nil)
        |> then(&Platform.Test.MailPrivacyFixtures.shared!(ctx.admin, &1, [ctx.owner, ctx.other]))

      :ok = grant!(ctx.admin, support, ctx.insider)
      shared_row = backfilled!(support, raw("shared-#{u()}@corp.test", subject: "SUBJ-S-1"))

      assert {:ok, env} = list(ctx.insider, ctx.mixed, %{"org_id" => ctx.org_id})
      assert Enum.map(env.messages, & &1.id) == [shared_row.id]
      assert env.total == 1
      assert env.withheld_notice == @notice
      refute inspect(env) =~ "SUBJ-P-1"

      assert {:ok, %{id: id}} = get(ctx.insider, ctx.mixed, shared_row.id)
      assert id == shared_row.id
    end

    test "an empty audience (no human in the space) reads nothing", ctx do
      lonely = space!()
      join!(lonely, ctx.insider)

      assert {:ok, env} = list(ctx.insider, lonely, %{"org_id" => ctx.org_id})
      assert env.messages == []
      assert env.total == 0
      assert env.audience == []
      assert {:error, %{code: :withheld}} = get(ctx.insider, lonely, ctx.row.id)
    end
  end

  # ── the grant term ────────────────────────────────────────────────────────

  describe "the grant" do
    setup ctx do
      %{row: backfilled!(ctx.account, raw("grant-#{u()}@corp.test", subject: "SUBJ-G-1"))}
    end

    test "an ungranted agent, even in the inbound channel and the owner's DM, reads nothing",
         ctx do
      for space <- [ctx.dm, ctx.inbound] do
        assert {:ok, env} = list(ctx.outsider, space, %{"org_id" => ctx.org_id})
        assert env.messages == []
        assert env.total == 0
        # Nothing it is granted was withheld: it is granted nothing.
        refute Map.has_key?(env, :withheld_notice)

        assert {:error, envelope} = get(ctx.outsider, space, ctx.row.id)
        assert envelope == unknown_envelope(ctx)
      end

      # Positive control: the granted agent reads the very row in D.
      assert {:ok, %{id: id}} = get(ctx.insider, ctx.dm, ctx.row.id)
      assert id == ctx.row.id
    end

    test "revoke, then the very next call reads nothing", ctx do
      assert {:ok, %{total: 1}} = list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id})
      assert {:ok, _} = get(ctx.insider, ctx.dm, ctx.row.id)

      {:ok, _} = Ownership.revoke(ctx.owner, ctx.account, {:agent, ctx.insider.id})

      assert {:ok, env} = list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id})
      assert env.messages == []
      refute Map.has_key?(env, :withheld_notice)
      assert {:error, envelope} = get(ctx.insider, ctx.dm, ctx.row.id)
      assert envelope == unknown_envelope(ctx)
    end

    test "a mailbox returned to unassigned is read by no agent", ctx do
      {:ok, _} = Ownership.set_owner(ctx.admin, ctx.account, %{kind: "unassigned"})

      assert {:ok, %{messages: [], total: 0}} =
               list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id})

      assert {:error, envelope} = get(ctx.insider, ctx.dm, ctx.row.id)
      assert envelope == unknown_envelope(ctx)
    end
  end

  # ── the participant check ─────────────────────────────────────────────────

  describe "the space" do
    setup ctx do
      %{row: backfilled!(ctx.account, raw("space-#{u()}@corp.test"))}
    end

    test "a missing space_id is not-found", ctx do
      assert {:error, envelope} = list(ctx.insider, :omit, %{"org_id" => ctx.org_id})
      assert envelope == list_not_found(ctx)
      assert {:error, envelope} = get(ctx.insider, :omit, ctx.row.id)
      assert envelope == unknown_envelope(ctx)
    end

    test "a space the agent is not a participant of is not-found, even with the owner in it",
         ctx do
      foreign = space!()
      join_user!(foreign, ctx.owner)

      assert {:error, envelope} = list(ctx.insider, foreign, %{"org_id" => ctx.org_id})
      assert envelope == list_not_found(ctx)
      assert {:error, envelope} = get(ctx.insider, foreign, ctx.row.id)
      assert envelope == unknown_envelope(ctx)

      # Positive control: once it joins, the same call reads.
      join!(foreign, ctx.insider)
      assert {:ok, %{id: id}} = get(ctx.insider, foreign, ctx.row.id)
      assert id == ctx.row.id
    end

    test "an archived space is not-found", ctx do
      {:ok, _} = Chat.archive_space(ctx.dm)

      assert {:error, envelope} = list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id})
      assert envelope == list_not_found(ctx)
      assert {:error, %{code: :not_found}} = get(ctx.insider, ctx.dm, ctx.row.id)
    end

    test "a removed participant reads nothing", ctx do
      ctx.dm.id |> Chat.get_agent_participant(ctx.insider) |> Chat.remove_participant()

      assert {:error, envelope} = get(ctx.insider, ctx.dm, ctx.row.id)
      assert envelope == unknown_envelope(ctx)
    end

    test "a malformed id or space id is the same not-found", ctx do
      assert {:error, envelope} = get(ctx.insider, ctx.dm, "not-a-uuid")
      assert envelope == unknown_envelope(ctx)
      assert {:error, envelope} = get(ctx.insider, "not-a-uuid", ctx.row.id)
      assert envelope == unknown_envelope(ctx)
    end

    test "an agent of another org, even granted and in the owner's DM", ctx do
      sibling = agent!("sibling", ctx.other_org_id)
      :ok = grant!(ctx.owner, ctx.account, sibling)
      join!(ctx.dm, sibling)

      assert {:error, envelope} = get(sibling, ctx.dm, ctx.row.id)
      assert envelope == unknown_envelope(ctx)

      # Listing the other org is the tenant pin's refusal, as for drafts.
      assert {:error, %{error: "unauthorized: " <> _}} =
               list(sibling, ctx.dm, %{"org_id" => ctx.org_id})
    end
  end

  # ── audit and quiet ───────────────────────────────────────────────────────

  describe "audit" do
    test "each list and get writes one audit row: ids and outcome, never content", ctx do
      row =
        backfilled!(
          ctx.account,
          raw("audit-#{u()}@corp.test", subject: "SUBJ-A-1", body: "BODY-A-1")
        )

      assert audit_rows(ctx.insider) == []

      assert {:ok, _} = list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id})
      assert {:ok, _} = get(ctx.insider, ctx.dm, row.id)
      assert {:error, %{code: :withheld}} = get(ctx.insider, ctx.mixed, row.id)
      assert {:error, %{code: :not_found}} = get(ctx.insider, Ecto.UUID.generate(), row.id)

      assert [listed, read, withheld, missed] = audit_rows(ctx.insider)

      assert listed.action == "list"
      assert listed.actor_type == "agent"
      assert listed.resource_type == "chat_space"
      assert listed.resource_id == ctx.dm.id
      assert listed.actor_org_id == ctx.org_id
      assert listed.metadata["outcome"] == "ok"
      assert listed.metadata["space_id"] == ctx.dm.id
      assert listed.metadata["audience_user_ids"] == [ctx.owner.id]
      assert listed.metadata["account_ids"] == [ctx.account.id]
      assert listed.metadata["row_ids"] == [row.id]

      assert read.action == "get"
      assert read.metadata["outcome"] == "ok"
      assert read.metadata["row_ids"] == [row.id]

      assert withheld.metadata["outcome"] == "withheld"
      assert withheld.resource_id == ctx.mixed.id
      assert withheld.metadata["row_ids"] == []

      assert missed.metadata["outcome"] == "not_found"

      for event <- [listed, read, withheld, missed] do
        rendered = inspect(event.metadata)
        refute rendered =~ "SUBJ-A-1"
        refute rendered =~ "BODY-A-1"
        refute rendered =~ "recruiter@corp.test"
      end
    end
  end

  describe "quiet" do
    test "no tool call writes a chat message, a mail row or broadcasts on mail:inbound", ctx do
      row = backfilled!(ctx.account, raw("quiet-#{u()}@corp.test"))
      :ok = Inbound.subscribe()
      before = chat_count()
      rows_before = Repo.aggregate(InboundMessage, :count)

      assert {:ok, _} = list(ctx.insider, ctx.dm, %{"org_id" => ctx.org_id})
      assert {:ok, _} = get(ctx.insider, ctx.dm, row.id)
      assert {:error, _} = get(ctx.outsider, ctx.dm, row.id)

      assert chat_count() == before
      assert Repo.aggregate(InboundMessage, :count) == rows_before
      assert Repo.reload!(row).chat_message_id == nil
      assert Repo.reload!(row).updated_at == row.updated_at
      refute_receive {:mail_inbound_ingested, _}, 100
    end
  end
end
