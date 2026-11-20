defmodule PlatformWeb.Components.MailPriorityDraftsTest do
  @moduledoc """
  Drafts and plans in the briefing's called-out email section (task
  01a1f426 stage 5, Level 2 surface), driven through the real briefing page
  (`/inbox/briefing/:date`) and the Email draft editor.

  The world: org admin A and member C read shared mailbox S, which is
  granted to the triage agent. A owns personal mailbox A2, NOT granted to
  the agent. Every draft is an agent draft written the way the drafter
  writes one (`created_by_type` agent, `on_behalf_of_user_id` the reader).

  What must hold:

    * a reader sees "Draft ready", a two-line preview and a link to the
      draft for their OWN item's draft, and a plan's summary and steps;
    * a draft id on an item that names another reader's draft, a draft of
      a non-granted mailbox, or a discarded draft renders nothing and links
      nowhere;
    * the section offers no send control, and none of its events reaches
      `Platform.Mail.Dispatch` or `Platform.Mail.Deliverer`;
    * the draft text reaches the permitted reader's page and nothing else:
      not the log (Ecto :debug on), not repo query telemetry (params AND
      result rows), not PubSub;
    * the Email editor says "Prepared by <agent> from the morning
      briefing" and links back to the item, for that reader only.

  async: false — `:mail_enabled`, the responsibility override, the trace
  session and the Logger level are application-wide.
  """
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures
  import Platform.Test.MailTriageFixtures

  require Logger

  alias Platform.Mail.Draft
  alias Platform.Mail.Triage.Item
  alias Platform.Memory.Briefing
  alias Platform.Repo

  setup %{conn: conn} do
    enable_mail!()
    org_id = acme_org_id()
    n = unique()

    a = user!("a") |> member!(org_id, "admin")
    c = user!("c") |> member!(org_id)
    agent = agent!("triage")

    shared = account!(a, org_id, %{"name" => "Shared #{n}"}) |> then(&shared!(a, &1, [a, c]))
    flag_agent!(a, shared, agent)
    a2 = account!(a, org_id, %{"name" => "A2 box #{n}"}) |> then(&personal!(a, &1, a))

    %{
      conn: conn,
      org_id: org_id,
      n: n,
      a: a,
      c: c,
      agent: agent,
      shared: shared,
      a2: a2,
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
            tier: "top",
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

  defp draft!(ctx, account, on_behalf, body, attrs \\ %{}) do
    %Draft{}
    |> Draft.changeset(
      Map.merge(
        %{
          org_id: ctx.org_id,
          account_id: account.id,
          to_addresses: ["them@outside.test"],
          subject: "Re: contract",
          body: body,
          created_by_type: "agent",
          created_by_id: ctx.agent.id,
          on_behalf_of_user_id: on_behalf.id
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp with_draft!(item, draft) do
    item
    |> Item.drafter_changeset(%{
      draft_id: draft.id,
      draft_original_body: draft.body,
      drafted_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp open_briefing(conn, user, date) do
    Repo.insert!(%Briefing{user_id: user.id, digest_date: date, items: %{}},
      on_conflict: :nothing
    )

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, lv, html} = live(conn, "/inbox/briefing/#{date}")
    {lv, html}
  end

  defp section_html(lv), do: lv |> element("[data-section=mail_priority]") |> render()

  defp item_html(lv, item),
    do: lv |> element("[data-role=mail-priority-item][data-item-id='#{item.id}']") |> render()

  describe "draft ready and plan" do
    test "the reader's own draft shows Draft ready, a two-line preview and a link", ctx do
      inbound = inbound!(ctx.shared, %{subject: "Clauses #{ctx.n}"})

      draft =
        draft!(
          ctx,
          ctx.shared,
          ctx.a,
          "Hi Dana,\n\n  Clause 7.2 works for us.  \nThird line #{ctx.n} stays out."
        )

      item = item!(ctx.a, inbound, %{}) |> with_draft!(draft)

      {lv, _html} = open_briefing(ctx.conn, ctx.a, ctx.date)
      html = item_html(lv, item)

      assert html =~ "Draft ready"
      assert has_element?(lv, "[data-role=mail-priority-draft][data-draft-id='#{draft.id}']")

      assert has_element?(
               lv,
               ~s([data-role=mail-priority-draft-open][href="/email/drafts/#{draft.id}"])
             )

      preview =
        lv |> element("[data-role=mail-priority-draft-preview]") |> render()

      assert preview =~ "Hi Dana,"
      assert preview =~ "Clause 7.2 works for us."
      refute preview =~ "Third line #{ctx.n}"

      # Drafts only: no send control anywhere in the section.
      section = section_html(lv)
      refute section =~ ~r/phx-click="[^"]*send/i
      refute section =~ ">Send<"
      refute section =~ "/send"
    end

    test "a plan shows its summary and an expandable numbered step list, and no draft link",
         ctx do
      inbound = inbound!(ctx.shared, %{subject: "Proposal #{ctx.n}"})

      item =
        item!(ctx.a, inbound, %{tier: "action", needs: "plan"})
        |> Item.drafter_changeset(%{
          plan_summary: "Send the proposal by Friday",
          plan_steps: ["Collect the scope", "Draft the timeline", "Review pricing"],
          drafted_at: DateTime.utc_now()
        })
        |> Repo.update!()

      {lv, _html} = open_briefing(ctx.conn, ctx.a, ctx.date)
      html = item_html(lv, item)

      assert html =~ "Send the proposal by Friday"
      assert html =~ "3 steps"
      assert html =~ ~r/<details[^>]*data-role="mail-priority-plan"/
      refute html =~ ~r/<details[^>]*\sopen/

      steps =
        lv |> element("[data-role=mail-priority-plan-steps]") |> render()

      assert steps =~ "<ol"
      assert steps =~ "Collect the scope"
      assert steps =~ "Review pricing"
      refute html =~ "Draft ready"
      refute html =~ "/email/drafts/"
    end

    test "a sent draft reads Draft sent and no longer links", ctx do
      draft = draft!(ctx, ctx.shared, ctx.a, "Sent already.", %{status: "dispatched"})
      item = item!(ctx.a, inbound!(ctx.shared), %{}) |> with_draft!(draft)

      {lv, _html} = open_briefing(ctx.conn, ctx.a, ctx.date)
      html = item_html(lv, item)

      assert html =~ "Draft sent"
      refute html =~ "Draft ready"
      refute html =~ draft.id
    end
  end

  describe "forged draft ids" do
    test "another reader's draft, a non-granted mailbox's draft or a discarded draft renders nothing and links nowhere",
         ctx do
      # C's own draft on the shared mailbox: A can read S, so the draft
      # visibility rule alone would show it to A.
      c_draft = draft!(ctx, ctx.shared, ctx.c, "C-DRAFT-#{ctx.n}")
      # A's draft on A2, a mailbox not granted to the triage agent.
      a2_draft = draft!(ctx, ctx.a2, ctx.a, "A2-DRAFT-#{ctx.n}")
      # A's own draft on S, discarded.
      gone = draft!(ctx, ctx.shared, ctx.a, "GONE-DRAFT-#{ctx.n}")

      forged_other = item!(ctx.a, inbound!(ctx.shared), %{}) |> with_draft!(c_draft)
      forged_box = item!(ctx.a, inbound!(ctx.shared), %{}) |> with_draft!(a2_draft)
      discarded = item!(ctx.a, inbound!(ctx.shared), %{}) |> with_draft!(gone)
      {:ok, _} = Platform.Mail.Drafts.discard({:agent, ctx.agent.id}, gone.id)

      # The same draft ids on C's own item: C sees C's draft (the positive
      # control), and still not A2's.
      c_item = item!(ctx.c, inbound!(ctx.shared), %{}) |> with_draft!(c_draft)

      {lv, html} = open_briefing(ctx.conn, ctx.a, ctx.date)

      for item <- [forged_other, forged_box, discarded] do
        assert has_element?(lv, "[data-role=mail-priority-item][data-item-id='#{item.id}']")
        refute item_html(lv, item) =~ "Draft ready"
      end

      refute has_element?(lv, "[data-role=mail-priority-draft]")

      for draft <- [c_draft, a2_draft, gone] do
        refute html =~ draft.id
        refute section_html(lv) =~ draft.id
      end

      refute html =~ "C-DRAFT-#{ctx.n}"
      refute html =~ "A2-DRAFT-#{ctx.n}"
      refute html =~ "GONE-DRAFT-#{ctx.n}"

      {lv_c, _} = open_briefing(ctx.conn, ctx.c, ctx.date)
      assert item_html(lv_c, c_item) =~ "Draft ready"
      assert has_element?(lv_c, "[data-role=mail-priority-draft][data-draft-id='#{c_draft.id}']")
    end
  end

  # ── Drafts only ─────────────────────────────────────────────────────────

  @send_path [
    {Platform.Mail.Dispatch, :dispatch, 3},
    {Platform.Mail.Dispatch, :dispatch, 2},
    {Platform.Mail.Dispatch, :enqueue, 3},
    {Platform.Mail.Deliverer, :deliver, 1}
  ]

  defp trace_send_path! do
    test_pid = self()

    collector =
      spawn(fn ->
        Stream.repeatedly(fn ->
          receive do
            msg -> send(test_pid, msg)
          end
        end)
        |> Stream.run()
      end)

    session = :trace.session_create(:mail_priority_drafts_send_path, collector, [])

    for {m, f, a} <- @send_path do
      Code.ensure_loaded!(m)
      if function_exported?(m, f, a), do: 1 = :trace.function(session, {m, f, a}, true, [:local])
    end

    :trace.process(session, :all, true, [:call])

    on_exit(fn ->
      :trace.session_destroy(session)
      Process.exit(collector, :kill)
    end)
  end

  defp send_path_calls do
    receive do
      {:trace, _pid, :call, {m, f, args}} -> [{m, f, length(args)} | send_path_calls()]
    after
      100 -> []
    end
  end

  test "drafts only: none of the section's events calls Dispatch or the Deliverer", ctx do
    draft = draft!(ctx, ctx.shared, ctx.a, "Ready to go.")
    done = item!(ctx.a, inbound!(ctx.shared), %{}) |> with_draft!(draft)
    other_draft = draft!(ctx, ctx.shared, ctx.a, "Another.")
    dismiss = item!(ctx.a, inbound!(ctx.shared), %{}) |> with_draft!(other_draft)
    promo = item!(ctx.a, inbound!(ctx.shared), %{tier: "promo", needs: "none"})

    deliveries = Repo.aggregate(Platform.Mail.Delivery, :count)
    {lv, _html} = open_briefing(ctx.conn, ctx.a, ctx.date)
    trace_send_path!()

    lv
    |> element("[data-item-id='#{done.id}'] [data-role=mail-priority-done]")
    |> render_click()

    lv
    |> element("[data-item-id='#{dismiss.id}'] [data-role=mail-priority-not-important]")
    |> render_click()

    lv
    |> element("[data-role=mail-priority-other][data-item-id='#{promo.id}'] button")
    |> render_click()

    # The events took effect...
    assert Repo.get!(Item, done.id).status == "acted"
    assert Repo.get!(Item, dismiss.id).status == "dismissed"

    # ...and nothing reached the send path.
    assert send_path_calls() == []
    assert Repo.aggregate(Platform.Mail.Delivery, :count) == deliveries
    refute_received {:mail_test_adapter, _email, _config}
    assert Repo.get!(Draft, draft.id).status == "draft"
    assert Repo.get!(Draft, other_draft.id).status == "draft"

    # Positive control: the trace is live.
    _ = Platform.Mail.Deliverer.deliver(Ecto.UUID.generate())
    assert {Platform.Mail.Deliverer, :deliver, 1} in send_path_calls()
  end

  # ── Sentinel ─────────────────────────────────────────────────────────────

  test "the draft preview reaches the reader's page and no log, repo telemetry or PubSub",
       ctx do
    sentinel = "SENTINEL-#{Ecto.UUID.generate()}"
    draft = draft!(ctx, ctx.shared, ctx.a, "Confirmed: #{sentinel}.\nSecond line.")
    item = item!(ctx.a, inbound!(ctx.shared), %{}) |> with_draft!(draft)

    test_pid = self()
    handler = "mail-priority-drafts-sentinel-#{ctx.n}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:platform, :repo, :query], [:platform, :mail, :triage, :item]],
        fn event, measurements, metadata, _ ->
          # The whole metadata, `:result` (the rows) and `:params` included.
          send(test_pid, {:telemetry_seen, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    :ok = Platform.Mail.Inbound.subscribe()
    :ok = Platform.Inbox.subscribe(ctx.a.id)

    previous = Logger.level()
    Logger.configure(level: :debug)

    {html, log} =
      try do
        with_log([level: :debug], fn ->
          {lv, _} = open_briefing(ctx.conn, ctx.a, ctx.date)

          lv
          |> element("[data-item-id='#{item.id}'] [data-role=mail-priority-done]")
          |> render_click()

          section_html(lv)
        end)
      after
        Logger.configure(level: previous)
      end

    # Positive controls: the permitted reader's page shows the preview, the
    # debug query log and the repo telemetry were live, and the Done click
    # broadcast on the Inbox topic.
    assert html =~ sentinel
    assert log =~ "memory_briefings"
    telemetry = collect_telemetry()
    assert Enum.any?(telemetry, &match?({[:platform, :repo, :query], _, _}, &1))
    assert Enum.any?(telemetry, &match?({[:platform, :mail, :triage, :item], _, _}, &1))

    refute log =~ sentinel

    for {event, _m, metadata} <- telemetry do
      refute inspect(metadata, limit: :infinity, printable_limit: :infinity) =~ sentinel,
             "sentinel in #{inspect(event)} telemetry (query, params or result rows)"
    end

    # PubSub traffic only: the test process also holds the HTTP response of
    # the briefing page it requested (`{ref, {200, headers, body}}` and
    # `{:plug_conn, :sent}`), which is the permitted reader's page.
    {:messages, mailbox} = Process.info(self(), :messages)

    broadcasts =
      Enum.reject(mailbox, fn
        {:plug_conn, :sent} -> true
        {ref, {_status, _headers, _body}} when is_reference(ref) -> true
        _ -> false
      end)

    assert broadcasts != []
    refute inspect(broadcasts, limit: :infinity, printable_limit: :infinity) =~ sentinel
  end

  defp collect_telemetry do
    receive do
      {:telemetry_seen, event, m, metadata} -> [{event, m, metadata} | collect_telemetry()]
    after
      0 -> []
    end
  end

  # ── Email editor provenance ─────────────────────────────────────────────

  test "the Email editor says Prepared by the agent from the morning briefing and links back, for that reader only",
       ctx do
    draft = draft!(ctx, ctx.shared, ctx.a, "From the briefing.")
    item = item!(ctx.a, inbound!(ctx.shared), %{}) |> with_draft!(draft)

    conn = init_test_session(ctx.conn, current_user_id: ctx.a.id)
    {:ok, lv, _html} = live(conn, "/email/drafts/#{draft.id}")

    assert lv |> element("[data-role=mail-draft-drafted-by]") |> render() =~
             "Prepared by #{ctx.agent.name} from the morning briefing"

    href =
      Platform.Inbox.briefing_url(DateTime.to_date(item.inserted_at)) <>
        "#mail-priority-item-" <> item.id

    assert has_element?(lv, ~s([data-role=mail-draft-briefing-link][href="#{href}"]))

    # C reads S too and may open the draft, but the briefing item is A's:
    # the provenance line stays, the link back does not.
    conn_c = init_test_session(build_conn(), current_user_id: ctx.c.id)
    {:ok, lv_c, _html} = live(conn_c, "/email/drafts/#{draft.id}")

    assert lv_c |> element("[data-role=mail-draft-drafted-by]") |> render() =~
             "from the morning briefing"

    refute has_element?(lv_c, "[data-role=mail-draft-briefing-link]")

    # A draft that is not a triage draft keeps the old wording.
    plain = draft!(ctx, ctx.shared, ctx.a, "Plain agent draft.")
    {:ok, lv_p, _html} = live(conn, "/email/drafts/#{plain.id}")

    assert lv_p |> element("[data-role=mail-draft-drafted-by]") |> render() =~
             "Drafted by #{ctx.agent.name}"

    refute has_element?(lv_p, "[data-role=mail-draft-briefing-link]")
  end
end
