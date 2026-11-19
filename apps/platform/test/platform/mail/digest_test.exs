defmodule Platform.Mail.DigestTest do
  @moduledoc """
  `Platform.Mail.Digest` (task 01a1ea5b stage 5, Email privacy): the
  metadata-only mail section of the daily briefing and the `mail_digest`
  agent tool.

    * NOTHING from a subject, a body or a sender's local part reaches the
      digest, the rendered briefing section or the tool, for a viewer who
      cannot read the mailbox ("no subject, body or local part ...");
    * a personal mailbox whose owner has not opted in contributes nothing,
      and opting in makes it appear ("an opted-out personal mailbox ...");
    * an org admin sees the cross-mailbox view, a non-admin only mailboxes
      they can read ("the audience rule ...");
    * unassigned mailboxes never contribute; the agent tool applies the
      same rule to every human of the space it answers in.

  Mutation controls (stage 5 report): selecting the subject into a row,
  dropping the opt-in filter and dropping the non-admin readable
  constraint each turn a named test here red.

  async: false — flips `:mail_enabled` in application env.
  """
  use Platform.DataCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures

  alias Platform.Federation.ToolSurface
  alias Platform.Mail.{Delivery, Digest, Ownership}
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insights.{Briefings, BriefingSections, Disseminator}
  alias PlatformWeb.Components.MailDigestSection

  @now ~U[2026-11-15 13:00:00Z]
  @date ~D[2026-11-15]

  defmodule PushRecorder do
    def fan_out_to_user(id, payload), do: send(self(), {:push, id, payload})
  end

  setup do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    org_id = acme_org_id()
    n = unique()

    %{
      org_id: org_id,
      n: n,
      admin: user!("admin") |> member!(org_id, "admin"),
      owner: user!("owner") |> member!(org_id),
      member: user!("member") |> member!(org_id),
      teammate: user!("teammate") |> member!(org_id),
      subj_s: "SUBJ-S-#{n}",
      body_s: "BODY-S-#{n}",
      subj_p: "SUBJ-P-#{n}",
      body_p: "BODY-P-#{n}"
    }
  end

  # Shared mailbox S (member: teammate) and personal mailbox P (owner,
  # opted out), each with one inbound message from acme.test carrying unique
  # subject and body tokens and a unique sender local part.
  defp seed(ctx) do
    shared =
      account!(ctx.admin, ctx.org_id, %{"name" => "Support #{ctx.n}"})
      |> then(&shared!(ctx.admin, &1, [ctx.teammate]))

    personal =
      account!(ctx.admin, ctx.org_id, %{"name" => "Owner box #{ctx.n}"})
      |> then(&personal!(ctx.admin, &1, ctx.owner))

    inbound!(shared, %{
      from_address: "Alice Local <alicelocal#{ctx.n}@acme.test>",
      subject: ctx.subj_s,
      text_body: ctx.body_s,
      received_at: ~U[2026-11-15 09:00:00.000000Z]
    })

    inbound!(personal, %{
      from_address: "boblocal#{ctx.n}@Acme.Test",
      subject: ctx.subj_p,
      text_body: ctx.body_p,
      received_at: ~U[2026-11-15 10:00:00.000000Z]
    })

    Map.merge(ctx, %{shared: shared, personal: personal})
  end

  defp opt_in!(ctx) do
    {:ok, personal} = Ownership.set_digest_opt_in(ctx.owner, ctx.personal, true)
    %{ctx | personal: personal}
  end

  defp account_ids(digest), do: digest.rows |> Enum.map(& &1.account_id) |> Enum.uniq()

  defp tokens(ctx),
    do: [ctx.subj_s, ctx.body_s, ctx.subj_p, ctx.body_p, "alicelocal", "boblocal", "Alice Local"]

  defp refute_tokens(text, ctx) do
    for token <- tokens(ctx) do
      refute text =~ token, "digest output carried #{token}"
    end
  end

  defp delivery!(account, attrs) do
    id = Platform.Types.UUIDv7.generate()

    %{
      id: id,
      org_id: account.org_id,
      account_id: account.id,
      sender_key: "ops",
      from_address: "ops@example.com",
      recipients: ["someone@example.com"],
      subject: "Delivery #{id}",
      body: "b",
      actor_type: "system",
      message_id_header: "<#{id}@example.com>",
      status: "sending"
    }
    |> Map.merge(Map.drop(attrs, [:status, :accepted_at]))
    |> Delivery.insert_changeset()
    |> Repo.insert!()
    |> Delivery.status_changeset(%{
      status: Map.get(attrs, :status, "accepted"),
      accepted_at: Map.get(attrs, :accepted_at, DateTime.utc_now())
    })
    |> Repo.update!()
  end

  defp space_with!(ctx, humans, agent) do
    space = channel!(ctx.org_id)
    for h <- humans, do: join_user!(space, h)
    join_agent!(space, agent)
    space
  end

  defp tool!(ctx, agent, space) do
    {:ok, result} =
      ToolSurface.execute(
        "mail_digest",
        %{"org_id" => ctx.org_id, "space_id" => space.id},
        %{agent_id: agent.id}
      )

    result
  end

  defp render_section(user),
    do: render_component(MailDigestSection, id: "mail-digest-test", user_id: user.id)

  # ── The token guard ─────────────────────────────────────────────────────

  describe "no subject, body or local part" do
    test "the tokens are in the database (positive control)", ctx do
      ctx = seed(ctx)
      rows = Repo.all(Platform.Mail.InboundMessage)
      assert Enum.any?(rows, &(&1.subject == ctx.subj_s and &1.text_body == ctx.body_s))
      assert Enum.any?(rows, &(&1.subject == ctx.subj_p and &1.text_body == ctx.body_p))
      assert inspect(rows) =~ "alicelocal"
    end

    test "no subject, body or local part reaches for_org/2, the briefing section or mail_digest for a viewer who cannot read the mailbox",
         ctx do
      ctx = ctx |> seed() |> opt_in!()
      agent = agent!()

      # The admin cannot read S (not a member) or P (personal), yet sees both
      # rows: the strongest case. The member sees nothing at all.
      admin_digest = Digest.for_org(ctx.admin, ctx.org_id)
      assert Enum.sort(account_ids(admin_digest)) == Enum.sort([ctx.shared.id, ctx.personal.id])
      assert Enum.all?(admin_digest.rows, &(&1.readable == false))

      for viewer <- [ctx.admin, ctx.member] do
        viewer |> then(&Digest.for_org(&1, ctx.org_id)) |> inspect() |> refute_tokens(ctx)
        viewer |> render_section() |> refute_tokens(ctx)

        ctx
        |> space_with!([viewer], agent)
        |> then(&tool!(ctx, agent, &1))
        |> inspect()
        |> refute_tokens(ctx)
      end

      # And the admin's section did render the rows it carries.
      html = render_section(ctx.admin)
      assert html =~ "acme.test"
      assert html =~ "Support #{ctx.n} (private)"
    end
  end

  # ── Columns ─────────────────────────────────────────────────────────────

  describe "the four columns" do
    test "Customer is the domain, Who's on it the members, repliers and agents, Open threads and Last activity from times",
         ctx do
      ctx = seed(ctx)
      agent = agent!("granted")
      {:ok, _} = Ownership.grant(ctx.admin, ctx.shared, {:agent, agent.id})

      assert [row] = Digest.for_org(ctx.teammate, ctx.org_id).rows
      assert row.customer == "acme.test"
      assert row.account_id == ctx.shared.id
      assert row.readable
      assert row.link == "/email?account=#{ctx.shared.id}"
      assert row.mailbox == "Support #{ctx.n}"
      assert row.people == [ctx.teammate.name]
      assert row.agents == [agent.name]
      assert row.open_threads == 1
      assert row.last_activity_at == ~U[2026-11-15 09:00:00.000000Z]

      # An accepted reply to that address, sent by the owner, closes the
      # thread and puts the sender on it. A refused one would not.
      delivery!(ctx.shared, %{
        recipients: ["alicelocal#{ctx.n}@acme.test"],
        actor_type: "user",
        actor_id: ctx.owner.id,
        drafted_by_type: "agent",
        drafted_by_id: agent.id,
        accepted_at: ~U[2026-11-15 11:00:00.000000Z]
      })

      delivery!(ctx.shared, %{
        recipients: ["carol#{ctx.n}@other.test"],
        status: "refused",
        accepted_at: nil
      })

      assert [row] = Digest.for_org(ctx.teammate, ctx.org_id).rows
      assert row.open_threads == 0
      assert row.last_activity_at == ~U[2026-11-15 11:00:00.000000Z]
      assert row.people == [ctx.teammate.name, ctx.owner.name]
      assert row.agents == [agent.name]
    end

    test "the mailbox's own domain is not a customer", ctx do
      ctx = seed(ctx)

      own =
        account!(ctx.admin, ctx.org_id, %{"username" => "team#{ctx.n}@inhouse.test"})
        |> then(&shared!(ctx.admin, &1, [ctx.teammate]))

      inbound!(own, %{from_address: "colleague#{ctx.n}@inhouse.test"})
      inbound!(own, %{from_address: "buyer#{ctx.n}@client.test"})

      customers =
        for row <- Digest.for_org(ctx.teammate, ctx.org_id).rows,
            row.account_id == own.id,
            do: row.customer

      assert customers == ["client.test"]
    end
  end

  # ── Contribution ────────────────────────────────────────────────────────

  describe "contribution" do
    test "an opted-out personal mailbox contributes nothing; opting in adds it", ctx do
      ctx = seed(ctx)

      for viewer <- [ctx.admin, ctx.owner] do
        refute ctx.personal.id in account_ids(Digest.for_org(viewer, ctx.org_id))
      end

      assert Digest.for_org(ctx.owner, ctx.org_id) == %{
               org_id: ctx.org_id,
               mailboxes: 0,
               rows: []
             }

      ctx = opt_in!(ctx)

      assert [%{readable: true, mailbox: mailbox}] = Digest.for_org(ctx.owner, ctx.org_id).rows
      assert mailbox == "Mp's mailbox"
      admin_rows = Digest.for_org(ctx.admin, ctx.org_id).rows

      assert %{readable: false, link: nil} =
               Enum.find(admin_rows, &(&1.account_id == ctx.personal.id))

      {:ok, _} = Ownership.set_digest_opt_in(ctx.owner, ctx.personal, false)
      refute ctx.personal.id in account_ids(Digest.for_org(ctx.admin, ctx.org_id))
    end

    test "an unassigned mailbox never contributes, even to an admin", ctx do
      unassigned = account!(ctx.admin, ctx.org_id)
      inbound!(unassigned, %{from_address: "x#{ctx.n}@acme.test"})
      assert Digest.for_org(ctx.admin, ctx.org_id).mailboxes == 0
      assert Digest.for_org(ctx.admin, ctx.org_id).rows == []
    end

    test "a malformed org or an empty audience reads nothing", ctx do
      seed(ctx)
      assert Digest.for_org(ctx.admin, "not-a-uuid") == %{org_id: nil, mailboxes: 0, rows: []}
      assert Digest.for_audience([], ctx.org_id).rows == []
      assert Digest.for_org(%{id: "nope"}, ctx.org_id).rows == []
      assert Digest.for_org(nil, ctx.org_id).rows == []
    end
  end

  # ── Audience ────────────────────────────────────────────────────────────

  describe "the audience rule" do
    test "an admin sees the cross-mailbox rows; a non-admin sees only mailboxes they can read",
         ctx do
      ctx = seed(ctx)

      # Admin: S, though not a member, as a private row with no link.
      assert [row] = Digest.for_org(ctx.admin, ctx.org_id).rows
      assert row.account_id == ctx.shared.id
      assert row.mailbox == "Support #{ctx.n} (private)"
      assert row.link == nil

      # A non-admin who cannot read S: nothing, no section.
      assert Digest.for_org(ctx.member, ctx.org_id) == %{
               org_id: ctx.org_id,
               mailboxes: 0,
               rows: []
             }

      # A non-admin member of S: S, linked.
      assert [%{account_id: id, readable: true}] = Digest.for_org(ctx.teammate, ctx.org_id).rows
      assert id == ctx.shared.id
    end

    test "a non-member sees nothing", ctx do
      ctx = seed(ctx)
      outsider = user!("outsider")
      assert Digest.for_org(outsider, ctx.org_id).rows == []
    end

    test "for_audience/2 shows only what every person sees, linked only where all can read",
         ctx do
      ctx = seed(ctx)

      assert Digest.for_audience([ctx.admin, ctx.member], ctx.org_id).rows == []

      assert [%{readable: false, link: nil}] =
               Digest.for_audience([ctx.admin, ctx.teammate], ctx.org_id).rows

      assert [%{readable: true}] = Digest.for_audience([ctx.teammate], ctx.org_id).rows
    end
  end

  # ── The agent tool ──────────────────────────────────────────────────────

  describe "mail_digest" do
    test "follows the audience of the space it answers in; needs no grant", ctx do
      ctx = seed(ctx)
      agent = agent!("ungranted")

      admin_result = tool!(ctx, agent, space_with!(ctx, [ctx.admin], agent))
      assert [%{customer: "acme.test", readable: false} = row] = admin_result.rows
      refute Map.has_key?(row, :account_id)
      assert admin_result.audience == [ctx.admin.name]

      assert tool!(ctx, agent, space_with!(ctx, [ctx.member], agent)).rows == []
      assert tool!(ctx, agent, space_with!(ctx, [ctx.admin, ctx.member], agent)).rows == []

      assert [%{readable: true, account_id: id}] =
               tool!(ctx, agent, space_with!(ctx, [ctx.teammate], agent)).rows

      assert id == ctx.shared.id
      assert tool!(ctx, agent, space_with!(ctx, [], agent)).rows == []
    end

    test "a space the agent is not in is not found; the module switch refuses", ctx do
      seed(ctx)
      agent = agent!()
      space = channel!(ctx.org_id)
      join_user!(space, ctx.admin)
      args = %{"org_id" => ctx.org_id, "space_id" => space.id}

      assert {:error, %{code: :not_found}} =
               ToolSurface.execute("mail_digest", args, %{agent_id: agent.id})

      assert {:error, %{code: :not_found}} =
               ToolSurface.execute("mail_digest", Map.delete(args, "space_id"), %{
                 agent_id: agent.id
               })

      Application.put_env(:platform, :mail_enabled, false)

      assert {:error, %{code: :mail_disabled}} =
               ToolSurface.execute("mail_digest", args, %{agent_id: agent.id})
    end

    test "is in the mail bundle with the mail.use permission" do
      assert Platform.Access.ToolPermissions.for_tool("mail_digest") == "mail.use"
      names = ToolSurface.list_tools(["mail"]) |> Enum.map(& &1.name)
      assert "mail_digest" in names
    end
  end

  # ── The briefing section ────────────────────────────────────────────────

  describe "the briefing section" do
    test "a core provider contributes the mail section only while Email is on", ctx do
      # Task 01a1f426 stage 2 lists the called-out email section first.
      assert ["mail_priority", "mail"] = Enum.map(BriefingSections.all(), & &1.key)
      assert BriefingSections.providers() == [Platform.Mail.Triage.BriefingSection, Digest]
      Application.put_env(:platform, :mail_enabled, false)
      assert BriefingSections.all() == []
      _ = ctx
    end

    test "the admin's briefing renders the cross-mailbox rows; the non-admin's has no section",
         ctx do
      ctx = seed(ctx)

      admin_briefing =
        Repo.insert!(%Briefing{user_id: ctx.admin.id, digest_date: @date, items: %{}})

      member_briefing =
        Repo.insert!(%Briefing{user_id: ctx.member.id, digest_date: @date, items: %{}})

      admin_view = Briefings.view(admin_briefing, Platform.Access.Scope.for_user(ctx.admin))
      assert [%{key: "mail", total: 1, open: 0, calls: 0}] = admin_view.sections

      member_view = Briefings.view(member_briefing, Platform.Access.Scope.for_user(ctx.member))
      assert member_view.sections == []

      html = render_section(ctx.admin)
      assert html =~ "data-role=\"mail-digest\""

      for heading <- ["Customer", "Open threads", "Last activity"], do: assert(html =~ heading)
      assert html =~ "Who's on it" or html =~ "Who&#39;s on it"

      assert html =~ "data-role=\"mail-digest-private\""
      refute html =~ "data-role=\"mail-digest-mailbox-link\""
      assert html =~ "data-role=\"mail-digest-cards\""

      teammate_html = render_section(ctx.teammate)
      assert teammate_html =~ "/email?account=#{ctx.shared.id}"
      refute render_section(ctx.member) =~ "mail-digest-row"
    end

    test "a mailbox in view with no traffic reads Nothing to show yet", ctx do
      account!(ctx.admin, ctx.org_id) |> then(&shared!(ctx.admin, &1, []))
      html = render_section(ctx.admin)
      assert html =~ "Nothing to show yet"
      assert Digest.briefing_summary(ctx.admin.id, @date) == %{total: 1, open: 0, calls: 0}
      assert Digest.briefing_prepare(ctx.admin.id, @date) == 0
      assert Digest.briefing_summary(ctx.member.id, @date) == nil
    end

    test "delivery creates a briefing for a reader with mail rows, and none for a reader without",
         ctx do
      ctx = seed(ctx)

      assert {:ok, %{sections: _}} =
               Disseminator.run(now: @now, notifications_module: PushRecorder)

      assert Briefings.for_user_on(ctx.admin.id, @date)
      assert Briefings.for_user_on(ctx.teammate.id, @date)
      assert Briefings.for_user_on(ctx.member.id, @date) == nil
    end
  end
end
