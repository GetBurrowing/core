defmodule PlatformWeb.Components.MailPrioritySectionTest do
  @moduledoc """
  The called-out email section of the briefing (task 01a1f426 stage 2),
  driven through the real briefing page (`/inbox/briefing/:date`) and the
  Email message pane.

  The world: org admin A, members B and C. Shared mailbox S is read by A
  and C and granted to the triage agent. B owns personal mailbox B-box
  (granted to the agent, not readable by A). A owns personal mailbox A2,
  NOT granted to the agent. One email in S has an item for A AND one for C
  (each reader's own why line); A also holds an item on A2, as if from a
  grant since revoked, which must never render or accept a write.

  Mutation probe: removing the `Triage.eligible?/3` re-check from
  `MailPrioritySection.handle_event/3` turns "a forged item id ... writes
  nothing" red (the A2 item is A's own and A may read A2, so
  `Triage.record_feedback/3` alone would write).

  async: false — `:mail_enabled` and the responsibility override are
  application-wide.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures
  import Platform.Test.MailTriageFixtures

  alias Platform.Mail.Triage.{BriefingSection, Feedback, Item}
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insights.BriefingSections
  alias Platform.Repo

  setup %{conn: conn} do
    enable_mail!()
    org_id = acme_org_id()
    n = unique()

    a = user!("a") |> member!(org_id, "admin")
    b = user!("b") |> member!(org_id)
    c = user!("c") |> member!(org_id)
    agent = agent!("triage")

    shared = account!(a, org_id, %{"name" => "Shared #{n}"}) |> then(&shared!(a, &1, [a, c]))
    flag_agent!(a, shared, agent)

    b_box = account!(a, org_id, %{"name" => "B box #{n}"}) |> then(&personal!(a, &1, b))
    flag_agent!(b, b_box, agent)

    a2 = account!(a, org_id, %{"name" => "A2 box #{n}"}) |> then(&personal!(a, &1, a))

    in_s =
      inbound!(shared, %{
        from_address: "Counsel Person <counsel-#{n}@otherco.test>",
        subject: "Contract clauses #{n}"
      })

    in_promo = inbound!(shared, %{subject: "Promo #{n}"})
    in_b = inbound!(b_box, %{subject: "B private #{n}"})
    in_a2 = inbound!(a2, %{subject: "A2 old #{n}"})

    a_item = item!(a, in_s, %{tier: "top", why: "A-WHY-#{n}"})
    c_item = item!(c, in_s, %{tier: "action", why: "C-WHY-#{n}"})
    a_promo = item!(a, in_promo, %{tier: "promo", why: "Bulk mail."})
    c_promo = item!(c, in_promo, %{tier: "promo", why: "Bulk mail."})
    b_item = item!(b, in_b, %{tier: "top", why: "B-WHY-#{n}"})
    a2_item = item!(a, in_a2, %{tier: "top", why: "A2-WHY-#{n}"})

    %{
      conn: conn,
      org_id: org_id,
      n: n,
      a: a,
      b: b,
      c: c,
      agent: agent,
      shared: shared,
      a2: a2,
      in_s: in_s,
      in_a2: in_a2,
      a_item: a_item,
      c_item: c_item,
      a_promo: a_promo,
      c_promo: c_promo,
      b_item: b_item,
      a2_item: a2_item,
      date: Platform.Mail.Triage.briefing_today()
    }
  end

  defp item!(user, inbound, attrs) do
    Repo.insert!(
      struct(
        Item,
        Map.merge(
          %{
            org_id: inbound.org_id,
            account_id: inbound.account_id,
            inbound_message_id: inbound.id,
            user_id: user.id,
            tier: "action",
            needs: "reply",
            classifier: "rule:test",
            status: "open",
            signals: []
          },
          attrs
        )
      )
    )
  end

  defp open_briefing(conn, user, date) do
    Repo.insert!(%Briefing{user_id: user.id, digest_date: date, items: %{}},
      on_conflict: :nothing
    )

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, lv, html} = live(conn, "/inbox/briefing/#{date}")
    {lv, html}
  end

  defp section(lv), do: element(lv, "[data-section=mail_priority]")

  defp forge(lv, event, item_id) do
    lv
    |> with_target("[data-section=mail_priority]")
    |> render_click(event, %{"item_id" => item_id})
  end

  defp feedback_for(user),
    do: Repo.all(from(f in Feedback, where: f.user_id == ^user.id, order_by: f.inserted_at))

  defp reload(item), do: Repo.get!(Item, item.id)

  test "renders only the reader's own items, for readable AND granted mailboxes, at the top",
       ctx do
    {lv, html} = open_briefing(ctx.conn, ctx.a, ctx.date)
    section_html = lv |> section() |> render()

    assert section_html =~ "A-WHY-#{ctx.n}"
    assert section_html =~ "Contract clauses #{ctx.n}"
    assert section_html =~ "Counsel Person"
    assert section_html =~ "counsel-#{ctx.n}@otherco.test"
    assert section_html =~ "Needs you"
    assert section_html =~ "Shared #{ctx.n}"
    assert section_html =~ ~s(href="/email/messages/#{ctx.in_s.id}")

    # Another reader's why line on the same email, another member's private
    # mailbox, and a mailbox not granted to the agent never render.
    refute html =~ "C-WHY-#{ctx.n}"
    refute html =~ "B-WHY-#{ctx.n}"
    refute html =~ "B private #{ctx.n}"
    refute html =~ "A2-WHY-#{ctx.n}"
    refute html =~ "A2 old #{ctx.n}"

    # The mailbox A reads but the agent is not granted is named, metadata only.
    assert has_element?(
             lv,
             "[data-role=mail-priority-ungranted-mailbox][data-account-id='#{ctx.a2.id}']"
           )

    assert section_html =~ "A2 box #{ctx.n}"
    assert section_html =~ "has no agent flagging important email"

    # Routine and promo mail sits under the collapsed disclosure.
    assert has_element?(lv, "details[data-role=mail-priority-others]:not([open])")
    assert section_html =~ "1 other email"

    # Drafts only: no send control on this surface.
    refute section_html =~ ~s(phx-click="send")
    refute section_html =~ ">Send<"

    # The section is the first section of the briefing, above Needs your call.
    detail = lv |> element("[data-role=briefing-detail]") |> render()

    assert [_, "mail_priority"] =
             Regex.run(~r/data-role="briefing-section" data-section="([^"]+)"/, detail)

    [before_section, _] = String.split(detail, ~s(data-section="mail_priority"), parts: 2)
    refute before_section =~ "needs-call"
  end

  test "a second reader of the same shared mailbox sees their own items and feedback", ctx do
    {lv_a, _} = open_briefing(ctx.conn, ctx.a, ctx.date)

    lv_a
    |> element("[data-item-id='#{ctx.a_item.id}'] [data-role=mail-priority-not-important]")
    |> render_click()

    assert [%Feedback{verdict: "not_important"} = fb] = feedback_for(ctx.a)
    assert fb.inbound_message_id == ctx.in_s.id
    assert reload(ctx.a_item).status == "dismissed"
    assert has_element?(lv_a, "[data-item-id='#{ctx.a_item.id}'][data-status=dismissed]")

    # C's item on the same email is untouched and C has no feedback.
    assert reload(ctx.c_item).status == "open"
    assert feedback_for(ctx.c) == []

    {lv_c, html_c} = open_briefing(Phoenix.ConnTest.build_conn(), ctx.c, ctx.date)
    assert html_c =~ "C-WHY-#{ctx.n}"
    refute html_c =~ "A-WHY-#{ctx.n}"
    assert has_element?(lv_c, "[data-item-id='#{ctx.c_item.id}'][data-status=open]")

    lv_c
    |> element("[data-item-id='#{ctx.c_promo.id}'] [data-role=mail-priority-missed]")
    |> render_click()

    assert [%Feedback{verdict: "missed"}] = feedback_for(ctx.c)
    assert reload(ctx.c_promo).tier == "action"
    # A's feedback and A's promo item are unchanged by C's.
    assert [%Feedback{verdict: "not_important"}] = feedback_for(ctx.a)
    assert reload(ctx.a_promo).tier == "promo"

    lv_c
    |> element("[data-item-id='#{ctx.c_item.id}'] [data-role=mail-priority-done]")
    |> render_click()

    c_item = reload(ctx.c_item)
    assert c_item.status == "acted"
    assert c_item.acted_how == "manual"
    assert reload(ctx.a_item).status == "dismissed"
  end

  test "a forged item id from another reader or a non-granted mailbox is refused and writes nothing",
       ctx do
    {lv, _} = open_briefing(ctx.conn, ctx.a, ctx.date)

    for event <- ~w(triage_not_important triage_done triage_missed),
        id <- [ctx.c_item.id, ctx.b_item.id, ctx.a2_item.id, ctx.c_promo.id, "not-a-uuid"] do
      forge(lv, event, id)
    end

    assert Repo.aggregate(Feedback, :count) == 0

    for item <- [ctx.c_item, ctx.b_item, ctx.a2_item, ctx.c_promo] do
      fresh = reload(item)
      assert {fresh.status, fresh.tier} == {item.status, item.tier}
      assert is_nil(fresh.acted_at)
    end

    # The reader's own eligible item still accepts the write (positive control).
    forge(lv, "triage_not_important", ctx.a_item.id)
    assert [%Feedback{}] = feedback_for(ctx.a)
  end

  test "summary counts the reader's called-out items of the day", ctx do
    extra = inbound!(ctx.shared, %{})
    item!(ctx.a, extra, %{tier: "action", status: "dismissed"})
    extra2 = inbound!(ctx.shared, %{})
    item!(ctx.a, extra2, %{tier: "action"})

    # A: top open (a_item), action dismissed, action open; promo not counted;
    # the A2 item is not eligible and is not counted.
    assert BriefingSection.summary(ctx.a.id, ctx.date) == %{total: 3, open: 2, calls: 1}
    # C: one action open.
    assert BriefingSection.summary(ctx.c.id, ctx.date) == %{total: 1, open: 1, calls: 0}
    # Another day: nothing called out, the section is one informational item.
    assert BriefingSection.summary(ctx.a.id, Date.add(ctx.date, -3)) ==
             %{total: 1, open: 0, calls: 0}

    # A reader with no readable mailbox has no section.
    d = user!("d") |> member!(ctx.org_id)
    assert BriefingSection.summary(d.id, ctx.date) == nil
    assert BriefingSection.summary("not-a-uuid", ctx.date) == nil
  end

  test "mail_priority comes before mail in the provider order", ctx do
    assert BriefingSections.providers() == [
             Platform.Mail.Triage.BriefingSection,
             Platform.Mail.Digest
           ]

    assert ["mail_priority", "mail" | _] = Enum.map(BriefingSections.all(), & &1.key)
    keys = ctx.a.id |> BriefingSections.summaries(ctx.date) |> Enum.map(& &1.key)
    assert List.first(keys) == "mail_priority"
  end

  test "states: no triage agent, nothing today", ctx do
    {lv, _} = open_briefing(ctx.conn, ctx.a, Date.add(ctx.date, -3))
    assert has_element?(lv, "[data-role=mail-priority-empty]", "Nothing needs you today")

    {:ok, _} = Platform.Mail.Ownership.set_flag_important_agent(ctx.a, ctx.shared, nil)
    {lv, html} = open_briefing(Phoenix.ConnTest.build_conn(), ctx.a, ctx.date)
    assert has_element?(lv, "[data-role=mail-priority-no-agent]")
    refute html =~ "A-WHY-#{ctx.n}"
    refute has_element?(lv, "[data-role=mail-priority-item]")
  end

  # Task 01a1f5cc stage 4: each mailbox has its own flag agent, so the
  # section names none, and no visible string says sort or triage.
  defp visible_text(lv) do
    lv
    |> section()
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text(sep: " ")
    |> String.split()
    |> Enum.join(" ")
  end

  test "the briefing names no single agent and contains neither sort nor triage", ctx do
    # Flagged: S (the agent). Off: A2. Then the no-agent state.
    {lv, _} = open_briefing(ctx.conn, ctx.a, ctx.date)
    flagged = visible_text(lv)
    assert flagged =~ "A-WHY-#{ctx.n}"
    refute flagged =~ ctx.agent.name
    refute flagged =~ ~r/sort|triage/i

    {:ok, _} = Platform.Mail.Ownership.set_flag_important_agent(ctx.a, ctx.shared, nil)
    {lv, _} = open_briefing(Phoenix.ConnTest.build_conn(), ctx.a, ctx.date)
    none = visible_text(lv)

    assert lv
           |> element("[data-role=mail-priority-no-agent]")
           |> render()
           |> Floki.parse_fragment!()
           |> Floki.text()
           |> String.split()
           |> Enum.join(" ") ==
             "No agent flags important email for you yet. Choose one for each mailbox in Email > Accounts."

    assert has_element?(lv, ~s([data-role=mail-priority-no-agent] a[href="/email/accounts"]))
    refute none =~ ctx.agent.name
    refute none =~ ~r/sort|triage/i
  end

  test "a mailbox set to Off is listed as having no agent flagging important email", ctx do
    {lv, _} = open_briefing(ctx.conn, ctx.a, ctx.date)
    row = "[data-role=mail-priority-ungranted-mailbox][data-account-id='#{ctx.a2.id}']"

    text =
      lv
      |> element(row)
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.text()
      |> String.split()
      |> Enum.join(" ")

    assert text ==
             "A2 box #{ctx.n} has no agent flagging important email. Choose one in Email > Accounts."

    assert has_element?(lv, row <> ~s( a[href="/email/accounts"]))

    # The flagged mailbox is not listed; turning it Off lists nothing new
    # here (no mailbox has an agent, so the no-agent line replaces the list).
    refute has_element?(
             lv,
             "[data-role=mail-priority-ungranted-mailbox][data-account-id='#{ctx.shared.id}']"
           )
  end

  test "prepare triages the reader's new mail once and counts new called-out items", ctx do
    :ok = Platform.Test.MailTriageStub.install!(Platform.Test.MailTriageStub.json(verdict()))
    fresh = inbound!(ctx.shared, %{subject: "Fresh #{ctx.n}"})

    # Before the date's briefing is delivered, every called-out item of the
    # date counts: the fresh one AND the setup's item, which was classified
    # before this run (as on arrival).
    assert BriefingSection.prepare(ctx.a.id, ctx.date) == 2
    assert Repo.get_by(Item, user_id: ctx.a.id, inbound_message_id: fresh.id)

    briefing =
      Repo.insert!(%Briefing{user_id: ctx.a.id, digest_date: ctx.date, items: %{}})

    {:ok, _, :created} = Platform.Inbox.upsert_briefing_item(briefing, %{total: 2})

    # Once delivered, only NEW called-out items count.
    later = inbound!(ctx.shared, %{subject: "Later #{ctx.n}"})
    assert BriefingSection.prepare(ctx.a.id, ctx.date) == 1
    assert Repo.get_by(Item, user_id: ctx.a.id, inbound_message_id: later.id)
    # Idempotent per reader and date once delivered.
    assert BriefingSection.prepare(ctx.a.id, ctx.date) == 0
    assert BriefingSection.prepare("not-a-uuid", ctx.date) == 0
  end

  # ── the briefing day (an evening email across the UTC midnight) ───────

  defmodule NoPush do
    @moduledoc "A `:notifications_module` that sends nothing."
    def fan_out_to_user(_user_id, _payload, _opts \\ []), do: :ok
  end

  describe "the briefing day" do
    # 02:00Z on 19 November is 20:00 CST on the 18th in the briefing zone.
    @evening ~U[2026-11-19 02:00:00.000000Z]
    @evening_date ~D[2026-11-18]

    setup ctx do
      inbound =
        inbound!(ctx.shared, %{
          from_address: "late-#{ctx.n}@otherco.test",
          subject: "Evening #{ctx.n}"
        })

      item =
        item!(ctx.a, inbound, %{tier: "top", why: "EVENING-WHY-#{ctx.n}", inserted_at: @evening})

      %{evening_item: item}
    end

    test "an item classified at 02:00Z is in the briefing of the local evening it arrived in",
         ctx do
      assert Platform.Mail.Triage.briefing_date(@evening) == @evening_date

      ids = fn date -> Enum.map(Platform.Mail.Triage.called_out(ctx.a, date), & &1.id) end
      assert ctx.evening_item.id in ids.(@evening_date)
      refute ctx.evening_item.id in ids.(Date.add(@evening_date, 1))

      {_lv, html} = open_briefing(ctx.conn, ctx.a, @evening_date)
      assert html =~ "EVENING-WHY-#{ctx.n}"
      {_lv, next_html} = open_briefing(ctx.conn, ctx.a, Date.add(@evening_date, 1))
      refute next_html =~ "EVENING-WHY-#{ctx.n}"
    end

    test "its Inbox link opens a briefing date that renders the item", ctx do
      Application.put_env(:platform, :notifications_module, NoPush)
      on_exit(fn -> Application.delete_env(:platform, :notifications_module) end)

      assert {:ok, _} =
               Platform.Mail.Triage.notify_top(ctx.evening_item,
                 now: DateTime.add(@evening, 5, :second)
               )

      row =
        Repo.one!(
          from(i in Platform.Inbox.Item,
            where: i.user_id == ^ctx.a.id and i.source_id == ^ctx.evening_item.id
          )
        )

      assert row.url == "/inbox/briefing/#{@evening_date}"

      # No briefing was delivered that evening: the link alone must render.
      conn = init_test_session(ctx.conn, current_user_id: ctx.a.id)
      {:ok, _lv, html} = live(conn, row.url)
      refute html =~ "There&#39;s no briefing for this day"
      refute html =~ "no briefing for this day"
      assert html =~ "EVENING-WHY-#{ctx.n}"
    end
  end

  describe "Email message pane" do
    test "the triage feedback control writes the reader's feedback", ctx do
      conn = init_test_session(ctx.conn, current_user_id: ctx.a.id)
      {:ok, lv, _} = live(conn, "/email/messages/#{ctx.in_s.id}")

      assert has_element?(lv, "[data-role=mail-triage-feedback]")
      lv |> element("[data-role=mail-triage-missed]") |> render_click()

      assert [%Feedback{verdict: "missed"} = fb] = feedback_for(ctx.a)
      assert fb.inbound_message_id == ctx.in_s.id
      assert has_element?(lv, "[data-role=mail-triage-recorded]")
      assert feedback_for(ctx.c) == []
    end

    test "a mailbox not granted to the triage agent has no control and refuses the event",
         ctx do
      conn = init_test_session(ctx.conn, current_user_id: ctx.a.id)
      {:ok, lv, _} = live(conn, "/email/messages/#{ctx.in_a2.id}")

      refute has_element?(lv, "[data-role=mail-triage-feedback]")
      render_click(lv, "triage_feedback", %{"verdict" => "missed"})
      assert feedback_for(ctx.a) == []
    end
  end
end
