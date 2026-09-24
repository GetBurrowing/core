defmodule PlatformWeb.EmailLiveDraftsTest do
  @moduledoc """
  Drafting in the Email module (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6
  stage 5): an agent-written draft in Drafts with its drafter, the editor,
  the internal-only recipient rule, the confirm pane, and Send through
  `Platform.Mail.Dispatch.dispatch/3` with the server as the enforcement.

  async: false — flips `:mail_enabled` and the mailer adapter in
  application env.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Mail
  alias Platform.Mail.Delivery
  alias Platform.Mail.Draft
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "#{label}-#{n}@example.com",
      name: "#{label} #{n}",
      oidc_sub: "oidc-email-drafts-#{label}-#{n}"
    })
    |> Repo.insert!()
  end

  defp member!(user, org_id, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role, external: false})
    |> Repo.insert!()

    user
  end

  defp login(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp set_adapter(adapter) do
    previous = Application.get_env(:platform, Platform.Mail.Mailer)
    Application.put_env(:platform, Platform.Mail.Mailer, adapter: adapter)
    on_exit(fn -> Application.put_env(:platform, Platform.Mail.Mailer, previous) end)
  end

  defp agent_draft!(ctx, overrides \\ %{}) do
    args =
      Map.merge(
        %{
          "org_id" => ctx.org_id,
          "account_id" => ctx.account.id,
          "sender_key" => "ops",
          "to_addresses" => [ctx.member.email],
          "subject" => "Weekly digest",
          "body" => "Hi team,\n\nThis week: 4 tasks shipped.",
          "task_id" => ctx.task.id
        },
        overrides
      )

    {:ok, result} = ToolSurface.execute("mail_draft_create", args, %{agent_id: ctx.agent.id})
    Repo.get!(Draft, result.draft_id)
  end

  defp accepted!(account, n) do
    for _ <- 1..n do
      id = Platform.Types.UUIDv7.generate()

      %{
        id: id,
        org_id: account.org_id,
        account_id: account.id,
        sender_key: "ops",
        from_address: "ops@soylent.test",
        recipients: ["someone@example.com"],
        subject: "earlier",
        body: "b",
        actor_type: "system",
        message_id_header: "<#{id}@soylent.test>",
        status: "sending"
      }
      |> Delivery.insert_changeset()
      |> Repo.insert!()
      |> Delivery.status_changeset(%{status: "accepted", smtp_response: "250 Ok"})
      |> Repo.update!()
    end
  end

  defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1

  defp internal_only!(ctx) do
    {:ok, _} = Mail.update_account(ctx.admin, ctx.account, %{"internal_only" => true})
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

    org_id = Tenancy.get_org_by_slug!("soylent").id

    admin = user!("admin") |> member!(org_id, "admin")
    member = user!("member") |> member!(org_id, "member")

    {:ok, account} =
      Mail.create_account(
        admin,
        org_id,
        %{
          "name" => "ops",
          "smtp_host" => "smtp.ops.test",
          "smtp_port" => 2525,
          "smtp_tls" => "none",
          "username" => "ops-relay"
        },
        %{smtp: "ops-password"}
      )

    {:ok, _} =
      Mail.put_sender(admin, account, %{"key" => "ops", "address" => "ops@soylent.test"})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Drafts #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Weekly digest task"})

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "chabrielle-#{System.unique_integer([:positive])}",
        name: "Chabrielle",
        status: "active",
        metadata: %{"org_id" => org_id}
      })
      |> Repo.insert!()

    %{
      org_id: org_id,
      admin: admin,
      member: member,
      account: Mail.get_account(org_id, account.id),
      task: task,
      agent: agent
    }
  end

  # ── Drafts tab ──────────────────────────────────────────────────────────

  describe "drafts tab" do
    test "an agent-created draft appears with its drafter and task", %{conn: conn} = ctx do
      draft = agent_draft!(ctx)

      {:ok, view, _html} = live(login(conn, ctx.member), "/email?tab=drafts")

      assert has_element?(view, ~s([data-role="mail-draft-row"][data-draft-id="#{draft.id}"]))

      assert has_element?(
               view,
               ~s([data-role="mail-draft-row-meta"]),
               "Drafted by Chabrielle · task Weekly digest task"
             )

      view
      |> element(~s([data-role="mail-draft-row"][data-draft-id="#{draft.id}"]))
      |> render_click()

      assert_patch(view, "/email/drafts/#{draft.id}")
      assert has_element?(view, ~s([data-role="mail-draft-editor"]))

      assert has_element?(
               view,
               ~s([data-role="mail-draft-drafted-by"]),
               "Drafted by Chabrielle · task Weekly digest task"
             )
    end

    test "New email opens an empty editor; saving creates a person's draft",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(login(conn, ctx.member), "/email")

      view |> element(~s([data-role="mail-new-email"])) |> render_click()
      assert_patch(view, "/email/drafts/new")
      assert has_element?(view, ~s([data-role="mail-draft-drafted-by"]), "Drafted by you")

      # One sendable sender: it is preselected, shown by its dispatch address.
      assert has_element?(
               view,
               ~s([data-role="mail-draft-from"] option[selected]),
               "ops@soylent.test"
             )

      view
      |> form("#mail-draft-editor", %{
        draft: %{
          subject: "Hello",
          body: "Plain body",
          new_address: ctx.admin.email
        }
      })
      |> render_submit()

      draft = Repo.one!(from(d in Draft, where: d.subject == "Hello"))
      assert draft.created_by_type == "user"
      assert draft.created_by_id == ctx.member.id
      assert draft.to_addresses == [ctx.admin.email]
      assert draft.account_id == ctx.account.id
      assert draft.sender_key == "ops"
      assert_patch(view, "/email/drafts/#{draft.id}")
    end

    test "a draft body renders as escaped plain text in the editor and the confirm pane",
         %{conn: conn} = ctx do
      body = "<script>alert(1)</script> <b>bold</b> **md**"
      draft = agent_draft!(ctx, %{"body" => body})

      {:ok, view, html} = live(login(conn, ctx.member), "/email/drafts/#{draft.id}")

      refute html =~ "<script>alert(1)</script>"
      refute html =~ "<b>bold</b>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"

      html = view |> element(~s([data-role="mail-review-and-send"])) |> render_click()

      assert has_element?(view, ~s([data-role="mail-confirm-body"]))
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt; &lt;b&gt;bold&lt;/b&gt; **md**"
    end
  end

  # ── Edit, confirm, send ─────────────────────────────────────────────────

  describe "edit and send" do
    test "the edited body is what is sent; actor is the person, drafter the agent",
         %{conn: conn} = ctx do
      draft = agent_draft!(ctx)

      {:ok, view, _html} = live(login(conn, ctx.member), "/email/drafts/#{draft.id}")

      view
      |> form("#mail-draft-editor", %{draft: %{body: "Edited body, by a person."}})
      |> render_change()

      view |> element(~s([data-role="mail-review-and-send"])) |> render_click()

      assert has_element?(view, ~s([data-role="mail-confirm"]))
      assert has_element?(view, ~s([data-role="mail-confirm-from"]), "ops@soylent.test")
      assert has_element?(view, ~s([data-role="mail-confirm-body"]), "Edited body, by a person.")
      assert has_element?(view, ~s([data-role="mail-confirm-recipient"]), ctx.member.email)
      assert has_element?(view, ~s([data-role="mail-confirm-count"]), "1 recipient")

      assert has_element?(
               view,
               ~s([data-role="mail-confirm-recorded"]),
               "drafted by Chabrielle · task Weekly digest task · edited and sent by you"
             )

      assert has_element?(
               view,
               ~s([data-role="mail-confirm-rate"]),
               "This account: 0 of #{ctx.account.rate_limit_per_hour} sends used this hour."
             )

      # The From line never names the agent or the signed-in person.
      from_html = view |> element(~s([data-role="mail-confirm-from"])) |> render()
      refute from_html =~ "Chabrielle"
      refute from_html =~ ctx.member.name

      view |> element(~s([data-role="mail-confirm-send"])) |> render_click()

      assert has_element?(
               view,
               ~s([data-role="mail-delivery-status"]),
               "Accepted by smtp.ops.test"
             )

      refute has_element?(view, ~s([data-role="mail-delivery-status"].text-success))
      refute render(view) =~ "Delivered"

      assert_received {:mail_test_adapter, %Swoosh.Email{text_body: "Edited body, by a person."},
                       _config}

      delivery = Repo.one!(from(d in Delivery, where: d.draft_id == ^draft.id))
      assert delivery.status == "accepted"
      assert delivery.body == "Edited body, by a person."
      assert delivery.actor_type == "user"
      assert delivery.actor_id == ctx.member.id
      assert delivery.drafted_by_type == "agent"
      assert delivery.drafted_by_id == ctx.agent.id
      assert delivery.on_behalf_of_user_id == ctx.member.id
      assert delivery.task_id == ctx.task.id

      assert Repo.get!(Draft, draft.id).status == "dispatched"
    end

    test "a draft changed after review is not sent", %{conn: conn} = ctx do
      draft = agent_draft!(ctx)

      {:ok, view, _html} = live(login(conn, ctx.member), "/email/drafts/#{draft.id}")
      view |> element(~s([data-role="mail-review-and-send"])) |> render_click()

      # The agent revises it while the person is looking at the confirm pane.
      {:ok, _} =
        ToolSurface.execute(
          "mail_draft_update",
          %{"draft_id" => draft.id, "body" => "Swapped behind your back"},
          %{agent_id: ctx.agent.id}
        )

      view |> element(~s([data-role="mail-confirm-send"])) |> render_click()

      assert has_element?(
               view,
               ~s([data-role="mail-delivery-status"]),
               "changed since you reviewed"
             )

      refute_received {:mail_test_adapter, _, _}
      assert Repo.aggregate(from(d in Delivery, where: d.draft_id == ^draft.id), :count) == 0
    end

    test "a failing relay reads Failed, never Sent", %{conn: conn} = ctx do
      set_adapter(Platform.Mail.RaisingTestAdapter)
      draft = agent_draft!(ctx)

      {:ok, view, _html} = live(login(conn, ctx.member), "/email/drafts/#{draft.id}")
      view |> element(~s([data-role="mail-review-and-send"])) |> render_click()
      view |> element(~s([data-role="mail-confirm-send"])) |> render_click()

      assert has_element?(view, ~s([data-role="mail-delivery-status"].text-error), "Failed: ")
      refute has_element?(view, ~s([data-role="mail-delivery-status"]), "Sent")

      delivery = Repo.one!(from(d in Delivery, where: d.draft_id == ^draft.id))
      assert delivery.status == "failed"
      assert Repo.get!(Draft, draft.id).status == "draft"
    end
  end

  # ── Internal-only ───────────────────────────────────────────────────────

  describe "internal-only accounts" do
    test "an outside recipient is flagged in place, blocks review, and is removed by the person",
         %{conn: conn} = ctx do
      internal_only!(ctx)
      draft = agent_draft!(ctx, %{"to_addresses" => [ctx.member.email, "ceo@clientco.test"]})

      {:ok, view, _html} = live(login(conn, ctx.member), "/email/drafts/#{draft.id}")

      # Both recipients are shown; nothing was dropped.
      html = render(view)
      assert occurrences(html, ~s(data-role="mail-draft-recipient")) == 2
      assert has_element?(view, ~s([data-role="mail-draft-recipient-outside"]), "Outside the org")
      assert occurrences(html, ~s(data-role="mail-draft-recipient-outside")) == 1

      assert has_element?(
               view,
               ~s([data-role="mail-draft-outside-note"]),
               "ceo@clientco.test"
             )

      assert has_element?(
               view,
               ~s([data-role="mail-draft-outside-note"]),
               "This account only sends to internal recipients."
             )

      refute has_element?(view, ~s([data-role="mail-review-and-send"]))

      # In a browser a clicked button's own (empty) `value` attribute
      # overwrites a `phx-value-value` key, so the event would name no
      # recipient. LiveViewTest does not reproduce that, so pin the name.
      refute html =~ "phx-value-value="

      view
      |> element(
        ~s([data-role="mail-draft-recipient-remove"][phx-value-recipient="ceo@clientco.test"])
      )
      |> render_click()

      refute has_element?(view, ~s([data-role="mail-draft-recipient-outside"]))
      assert has_element?(view, ~s([data-role="mail-review-and-send"]))

      view |> element(~s([data-role="mail-review-and-send"])) |> render_click()

      assert has_element?(
               view,
               ~s([data-role="mail-confirm-removed"]),
               "1 external recipient removed"
             )

      assert occurrences(render(view), ~s(data-role="mail-confirm-recipient")) == 1
      assert has_element?(view, ~s([data-role="mail-confirm-recipient"]), ctx.member.email)
      assert Repo.get!(Draft, draft.id).to_addresses == [ctx.member.email]
    end

    test "a forced send with the outside recipient still present is refused by the server",
         %{conn: conn} = ctx do
      internal_only!(ctx)
      draft = agent_draft!(ctx, %{"to_addresses" => [ctx.member.email, "ceo@clientco.test"]})

      {:ok, view, _html} = live(login(conn, ctx.member), "/email/drafts/#{draft.id}")
      refute has_element?(view, ~s([data-role="mail-review-and-send"]))

      render_hook(view, "send", %{})

      assert has_element?(
               view,
               ~s([data-role="mail-delivery-status"]),
               "Refused: outside this org: ceo@clientco.test"
             )

      refute_received {:mail_test_adapter, _, _}

      delivery = Repo.one!(from(d in Delivery, where: d.draft_id == ^draft.id))
      assert delivery.status == "refused"
      assert delivery.refusal_reason["code"] == "external_recipients"
      assert delivery.refusal_reason["addresses"] == ["ceo@clientco.test"]
    end
  end

  # ── Confirm pane ────────────────────────────────────────────────────────

  describe "confirm pane" do
    test "every recipient is listed whole: 12 recipients, 12 rows, outside ones flagged",
         %{conn: conn} = ctx do
      # Not internal-only (accounts default to internal-only): outside
      # recipients reach the confirm pane, flagged in the warning colour.
      {:ok, _} = Mail.update_account(ctx.admin, ctx.account, %{"internal_only" => false})
      outside = for n <- 1..11, do: "person#{n}@outside-#{n}.test"
      draft = agent_draft!(ctx, %{"to_addresses" => [ctx.member.email | outside]})

      {:ok, view, _html} = live(login(conn, ctx.member), "/email/drafts/#{draft.id}")
      html = view |> element(~s([data-role="mail-review-and-send"])) |> render_click()

      assert occurrences(html, ~s(data-role="mail-confirm-recipient")) == 12
      assert occurrences(html, ~s(data-role="mail-confirm-recipient-outside")) == 11
      assert has_element?(view, ~s([data-role="mail-confirm-count"]), "12 recipients")
      # No summarising of the audience: no "and N others", no ellipsis.
      to_html = view |> element(~s([data-role="mail-confirm-to"])) |> render()
      refute to_html =~ "others"
      refute to_html =~ "…"
      refute to_html =~ "truncate"
      refute has_element?(view, ~s([data-role="mail-confirm-recipient-outside"].text-error))
      assert has_element?(view, ~s([data-role="mail-confirm-recipient-outside"].text-warning))

      for address <- outside do
        assert has_element?(view, ~s([data-role="mail-confirm-recipient"]), address)
      end
    end

    test "the rate line reads N of M, and at the limit there is no Send", %{conn: conn} = ctx do
      {:ok, _} = Mail.update_account(ctx.admin, ctx.account, %{"rate_limit_per_hour" => 3})
      accepted!(ctx.account, 2)
      draft = agent_draft!(ctx)

      {:ok, view, _html} = live(login(conn, ctx.member), "/email/drafts/#{draft.id}")
      view |> element(~s([data-role="mail-review-and-send"])) |> render_click()

      assert has_element?(
               view,
               ~s([data-role="mail-confirm-rate"]),
               "This account: 2 of 3 sends used this hour."
             )

      assert has_element?(view, ~s([data-role="mail-confirm-send"]))

      accepted!(ctx.account, 1)
      view |> element(~s([data-role="mail-confirm-back"])) |> render_click()
      view |> element(~s([data-role="mail-review-and-send"])) |> render_click()

      assert has_element?(
               view,
               ~s([data-role="mail-confirm-rate"]),
               "This account: 3 of 3 sends used this hour."
             )

      refute has_element?(view, ~s([data-role="mail-confirm-send"]))
      assert has_element?(view, ~s([data-role="mail-confirm-refusal"]), "used all 3 sends")
    end

    test "a draft of another org does not open by URL", %{conn: conn} = ctx do
      other_org_id = Tenancy.get_org_by_slug!("sxi").id
      other_admin = user!("other") |> member!(other_org_id, "admin")

      {:ok, other} =
        Mail.Drafts.create(other_admin, other_org_id, %{subject: "theirs", body: "x"})

      {:ok, view, _html} = live(login(conn, ctx.member), "/email/drafts/#{other.id}")

      refute has_element?(view, ~s([data-role="mail-draft-editor"]))
      refute render(view) =~ "theirs"
    end
  end
end
