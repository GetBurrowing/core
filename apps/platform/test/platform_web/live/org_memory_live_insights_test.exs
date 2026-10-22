defmodule PlatformWeb.OrgMemoryLiveInsightsTest do
  @moduledoc """
  The Insights tab (task 01a13867 stage 5), renamed from Proposals and
  built to direction canvas 01a14a73.

  Every refusal here reads the row (and the verdicts, briefings and page)
  back afterwards, and has its positive control on the same fixture: the
  same event by someone allowed, or with the missing input supplied, DOES
  take effect. Forged events are sent with `render_click/3` /
  `render_submit/3` straight at the LiveView, so the server path is what
  is tested, not whether a button rendered.

  Mutation probe: in `Platform.Memory.Insights.Actions.tier_permits/2`,
  make the `:needs_call` branch `:ok`; "a forged insight_act on a
  needs_call insight by a non-admin is refused" must go red.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.InsightFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.Scope
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Memory.InsightVerdict
  alias Platform.Org.Wiki
  alias Platform.Repo

  @off_notice "Insights stay on this tab. An admin can send them to people in Settings."

  defmodule PushRecorder do
    @moduledoc false
    def fan_out_to_humans(_participant_ids, _payload, _opts), do: :ok
    def fan_out_to_user(_user_id, _payload), do: :ok
  end

  setup do
    Repo.delete_all(Insight)
    Repo.delete_all(InsightVerdict)
    :ok
  end

  defp n, do: System.unique_integer([:positive])

  defp conn_for(conn, user), do: init_test_session(conn, %{"current_user_id" => user.id})

  defp tab!(conn, user) do
    {:ok, view, _html} = conn |> conn_for(user) |> live(~p"/memory/insights")
    view
  end

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # The desktop pane only: the mobile branch renders the same rows into the
  # same document, so a whole-document count would see every row twice.
  defp desktop_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      ~s([data-role="insights-pane"][data-surface="desktop"] [data-role="insight-row"])
    )
  end

  defp row(view, insight, surface \\ "desktop") do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      ~s([data-role="insights-pane"][data-surface="#{surface}"] [data-role="insight-row"][data-insight-id="#{insight.id}"])
    )
  end

  defp page_edit!(attrs \\ %{}) do
    key = "org/page/insight-tab-#{n()}.md"
    {:ok, _page} = Wiki.upsert_page(key, %{content: "Deploys go to host-a every night."})

    insight!(
      Map.merge(
        %{
          action_type: "page_edit",
          body: "The runbook still says host-a. <old>go to host-a</old><new>go to host-b</new>",
          source_ref: "page:#{key}",
          action: %{
            "target" => key,
            "hunks" => [%{"old" => "go to host-a", "new" => "go to host-b"}]
          }
        },
        Map.new(attrs)
      )
    )
    |> then(&{&1, key})
  end

  # A briefing addressed to a guest (an `external` membership) is `needs_call`
  # (Tier rule 3). Pass a guest: an internal member named by email is
  # reversible since 2026-10-21.
  defp needs_call_briefing!(addressee) do
    insight!(
      addressee: addressee,
      body: "Tell #{addressee.name} the vendor contract renews Friday.",
      action: %{"addressee" => addressee.email},
      tier: "needs_call"
    )
  end

  describe "tab" do
    test "the tab is labelled Insights", %{conn: conn} do
      {:ok, view, _html} = conn |> conn_for(person!()) |> live(~p"/org_memory")

      assert has_element?(
               view,
               ~s([data-role="tab-strip"] button[data-tab="insights"]),
               "Insights"
             )

      assert has_element?(
               view,
               ~s([data-role="mobile-tabs"] button[data-mobile-tab="insights"]),
               "Insights"
             )

      refute has_element?(view, ~s([data-tab="proposals"]))
      refute render(view) =~ "Proposals"

      view |> element(~s([data-role="tab-strip"] button[data-tab="insights"])) |> render_click()

      assert has_element?(
               view,
               ~s([data-role="insights-pane"][data-surface="desktop"] h1),
               "Insights"
             )
    end

    test "/memory/proposals redirects to /memory/insights", %{conn: conn} do
      assert {:error, {kind, %{to: "/memory/insights"}}} =
               conn |> conn_for(person!()) |> live("/memory/proposals")

      assert kind in [:live_redirect, :redirect]

      # Control: the target itself mounts on the Insights tab.
      {:ok, view, _html} = conn |> conn_for(person!()) |> live("/memory/insights")

      assert has_element?(
               view,
               ~s([data-role="tab-strip"] button[data-tab="insights"][aria-selected="true"])
             )
    end
  end

  describe "reject" do
    test "Reject without a reason is refused server-side", %{conn: conn} do
      member = person!()
      insight = insight!(addressee: member)
      view = tab!(conn, member)

      view
      |> element(~s(#insight-row-#{insight.id} [data-role="insight-reject"]))
      |> render_click()

      assert has_element?(
               view,
               ~s(#insight-reject-form-#{insight.id} textarea[name="reason"][required])
             )

      assert has_element?(
               view,
               ~s(#insight-reject-form-#{insight.id}),
               "Your reason is kept and used to teach dreaming."
             )

      # Forged past the browser's `required`: blank and whitespace reasons.
      for reason <- ["", "   "] do
        html = render_submit(view, "insight_reject", %{"_id" => insight.id, "reason" => reason})
        assert html =~ "Say why this is wrong. The reason is required."
      end

      html = render_submit(view, "insight_reject", %{"_id" => insight.id})
      assert html =~ "Say why this is wrong. The reason is required."

      assert %Insight{state: "open"} = Repo.get!(Insight, insight.id)
      assert Repo.aggregate(InsightVerdict, :count) == 0

      # Control: with a reason the same submit rejects and keeps the reason.
      view
      |> form("#insight-reject-form-#{insight.id}", %{"reason" => "Deploys never moved."})
      |> render_submit()

      assert %Insight{state: "dismissed"} = Repo.get!(Insight, insight.id)

      assert [%InsightVerdict{kind: "rejected", reason: "Deploys never moved."}] =
               Repo.all(InsightVerdict)

      assert desktop_rows(view) |> Enum.count() == 0
    end
  end

  describe "needs_call" do
    test "a forged insight_act on a needs_call insight by a non-admin is refused", %{conn: conn} do
      dreaming_agent!()
      member = person!()
      addressee = person!("member", external: true)
      insight = needs_call_briefing!(addressee)

      view = tab!(conn, member)

      # The server, checked FIRST so the mutation probe detonates here and
      # not on the presentation below (which reuses the same gate): a forged
      # event is refused and nothing is delivered.
      html = render_click(view, "insight_act", %{"id" => insight.id})
      assert %Insight{state: "open", delivered_at: nil} = Repo.get!(Insight, insight.id)
      assert Repo.aggregate(Briefing, :count) == 0
      assert html =~ "You cannot act on this insight. An install admin decides it."

      # Presentation: a member sees the warning row and no buttons.
      assert has_element?(view, ~s(#insight-row-#{insight.id} [data-role="insight-needs-call"]))
      refute has_element?(view, ~s(#insight-row-#{insight.id} [data-role="insight-primary"]))
      assert has_element?(view, ~s(#insight-row-#{insight.id} [data-role="insight-no-actions"]))

      # The other buttons are refused the same way: reroute would re-tier it.
      render_click(view, "insight_dismiss", %{"id" => insight.id})

      render_submit(view, "insight_reroute", %{"_id" => insight.id, "addressee" => member.id})

      render_submit(view, "insight_reject", %{"_id" => insight.id, "reason" => "no"})
      assert %Insight{state: "open", tier: "needs_call"} = Repo.get!(Insight, insight.id)
      assert Repo.aggregate(InsightVerdict, :count) == 0

      # Control: a root admin's same event executes it.
      admin_view = tab!(conn, root_admin!())

      assert has_element?(
               admin_view,
               ~s(#insight-row-#{insight.id} [data-role="insight-primary"])
             )

      admin_html = render_click(admin_view, "insight_act", %{"id" => insight.id})

      # The admin passes the gate (no refusal), and delivery then refuses the
      # guest: a guest's Inbox shows no briefing, so nothing is delivered.
      refute admin_html =~ "You cannot act on this insight. An install admin decides it."

      assert admin_html =~
               "This is addressed to a guest. Guests can&#39;t receive briefings, so it wasn&#39;t delivered."

      assert %Insight{state: "open", delivered_at: nil} = Repo.get!(Insight, insight.id)
      refute Repo.exists?(from(b in Briefing, where: b.user_id == ^addressee.id))
      assert Repo.aggregate(Briefing, :count) == 0
    end
  end

  describe "dissemination" do
    test "no Already done section while dissemination is off", %{conn: conn} do
      admin = root_admin!()
      {done, _key} = page_edit!()
      {:ok, done} = Platform.Memory.Insights.act(done, Platform.Access.Scope.for_user(admin))
      assert done.state == "done"
      open = insight!(addressee: admin)

      view = tab!(conn, admin)
      refute has_element?(view, ~s([data-role="insights-already-done"]))
      refute render(view) =~ "Already done</h2>"

      notice =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(
          ~s([data-role="insights-pane"][data-surface="desktop"] [data-role="insights-off-notice"])
        )

      assert squish(LazyHTML.text(notice)) == @off_notice
      # For an admin, "Settings" links to the install settings.
      assert has_element?(
               view,
               ~s([data-role="insights-off-notice"] a[href="/admin/insights"]),
               "Settings"
             )

      assert has_element?(view, ~s(#insight-row-#{open.id}))

      # A member reads the same sentence with no link.
      member_view = tab!(conn, person!())
      refute has_element?(member_view, ~s([data-role="insights-off-notice"] a))

      member_notice =
        member_view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(
          ~s([data-role="insights-pane"][data-surface="desktop"] [data-role="insights-off-notice"])
        )

      assert squish(LazyHTML.text(member_notice)) == @off_notice

      # Control: turned on, the section renders with the acted edit and its Revert.
      enable_dissemination!()
      on_view = tab!(conn, admin)
      refute has_element?(on_view, ~s([data-role="insights-off-notice"]))

      assert has_element?(
               on_view,
               ~s([data-role="insights-already-done"] [data-insight-id="#{done.id}"]),
               "· revertible"
             )

      assert has_element?(
               on_view,
               ~s([data-insight-id="#{done.id}"] [data-role="insight-revert"])
             )
    end

    test "the opt-out toggle writes only the viewer's own preference", %{conn: conn} do
      member = person!()
      other = person!()
      view = tab!(conn, member)

      view
      |> element("#insight-delivery-form")
      |> render_change(%{"receive" => "false"})

      assert Platform.Accounts.insight_delivery_opted_out?(member.id)
      refute Platform.Accounts.insight_delivery_opted_out?(other.id)

      view |> element("#insight-delivery-form") |> render_change(%{"receive" => "true"})
      refute Platform.Accounts.insight_delivery_opted_out?(member.id)
    end
  end

  describe "rows" do
    test "an expired insight is not rendered before the purge", %{conn: conn} do
      member = person!()
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      expired = insight!(addressee: member, body: "Expired line #{n()}.", expires_at: past)
      live_one = insight!(addressee: member, body: "Live line #{n()}.")

      # The row still exists: the purge has not run.
      assert Repo.get(Insight, expired.id)

      view = tab!(conn, member)
      refute has_element?(view, ~s([data-insight-id="#{expired.id}"]))
      refute render(view) =~ expired.body
      assert has_element?(view, ~s(#insight-row-#{live_one.id}), live_one.body)

      # Expiry is on every row: a fresh 7-day insight reads 7d left in neutral.
      assert has_element?(
               view,
               ~s(#insight-row-#{live_one.id} [data-role="insight-expiry"][data-last-day="false"]),
               "7d left"
             )

      # The last day turns warning.
      soon =
        insight!(addressee: member, expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))

      view = tab!(conn, member)

      assert has_element?(
               view,
               ~s(#insight-row-#{soon.id} [data-role="insight-expiry"][data-last-day="true"].text-warning),
               "1d left"
             )

      # An acted row past its TTL is not in Already done either.
      enable_dissemination!()

      Repo.update_all(from(i in Insight, where: i.id == ^expired.id),
        set: [state: "done", acted_at: past]
      )

      view = tab!(conn, member)
      refute has_element?(view, ~s([data-insight-id="#{expired.id}"]))
    end

    test "exactly one btn-primary per row, named for the action", %{conn: conn} do
      admin = root_admin!()
      addressee = person!()
      {edit, _key} = page_edit!()

      question =
        insight!(action_type: "question", addressee: addressee, body: "Who owns staging?")

      briefing = insight!(addressee: addressee, body: "Deploys moved to host-b.")
      task = insight!(action_type: "task", addressee: addressee, body: "Rotate the deploy key.")
      call = needs_call_briefing!(person!("member", external: true))

      view = tab!(conn, admin)

      expected = %{
        edit.id => "Apply edit",
        question.id => "Ask",
        briefing.id => "Add to briefing",
        task.id => "File task",
        call.id => "Add to briefing"
      }

      for surface <- ["desktop", "mobile"], {id, label} <- expected do
        primaries =
          view
          |> row(%{id: id}, surface)
          |> LazyHTML.query(".btn-primary")

        assert Enum.count(primaries) == 1,
               "#{surface} row #{id}: #{Enum.count(primaries)} btn-primary"

        assert squish(LazyHTML.text(primaries)) == label
      end

      assert desktop_rows(view) |> Enum.count() == 5

      # Type labels: mono text, no per-type colour class.
      labels =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-surface="desktop"] [data-role="insight-type-label"]))

      assert labels |> Enum.map(&squish(LazyHTML.text(&1))) |> Enum.sort() ==
               Enum.sort(["PAGE EDIT", "QUESTION", "BRIEFING", "TASK", "BRIEFING"])

      for label <- labels do
        assert LazyHTML.attribute(label, "class") == ["font-mono text-xs text-base-content/70"]
      end

      # The previews are the artefacts.
      assert has_element?(
               view,
               ~s(#insight-row-#{edit.id} [data-role="insight-diff-removed"]),
               "- go to host-a"
             )

      assert has_element?(
               view,
               ~s(#insight-row-#{edit.id} [data-role="insight-diff-added"]),
               "+ go to host-b"
             )

      assert has_element?(
               view,
               ~s(#insight-row-#{question.id} [data-role="insight-preview-to"]),
               addressee.name
             )

      # Bounded: a needs_call row a member may not handle has NO btn-primary.
      member_view = tab!(conn, person!())
      assert member_view |> row(call) |> LazyHTML.query(".btn-primary") |> Enum.count() == 0
      assert member_view |> row(briefing) |> LazyHTML.query(".btn-primary") |> Enum.count() == 1
    end

    test "a second session live-refreshes when an insight is acted on", %{conn: conn} do
      actor = person!()
      watcher = person!()
      {insight, key} = page_edit!()
      other = insight!(addressee: watcher)

      actor_view = tab!(conn, actor)
      watcher_view = tab!(conn, watcher)
      assert has_element?(watcher_view, ~s(#insight-row-#{insight.id}))

      actor_view
      |> element(~s(#insight-row-#{insight.id} [data-role="insight-primary"]))
      |> render_click()

      assert Wiki.get_page(key).content == "Deploys go to host-b every night."
      assert %Insight{state: "done"} = Repo.get!(Insight, insight.id)

      # The watcher did nothing; the PubSub broadcast refreshed its tab.
      refute has_element?(watcher_view, ~s([data-insight-id="#{insight.id}"]))
      assert has_element?(watcher_view, ~s(#insight-row-#{other.id}))
    end

    test "Reroute opens a picker defaulting to the suggested addressee, with the reason", %{
      conn: conn
    } do
      member = person!()
      addressee = person!()
      target = person!()
      insight = insight!(action_type: "question", addressee: addressee, body: "Who owns it?")

      view = tab!(conn, member)

      view
      |> element(~s(#insight-row-#{insight.id} [data-role="insight-reroute-button"]))
      |> render_click()

      assert has_element?(
               view,
               ~s(#insight-reroute-form-#{insight.id} option[value="#{addressee.id}"][selected])
             )

      assert has_element?(
               view,
               ~s(#insight-reroute-form-#{insight.id} [data-role="insight-reroute-reason"]),
               "named addressee"
             )

      view
      |> form("#insight-reroute-form-#{insight.id}", %{"addressee" => target.id})
      |> render_submit()

      assert %Insight{addressee_user_id: target_id} = Repo.get!(Insight, insight.id)
      assert target_id == target.id
    end
  end

  # Task 01a13867 stage 6: the two behavioural-gate findings on the tab.
  describe "after delivery (stage 6)" do
    # Every insight broadcast's `{event, in_transaction?}`, for `insight_id`.
    defp capture_broadcasts!(insight_id) do
      test_pid = self()
      handler_id = "stage6-broadcasts-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :memory_insights, :broadcast],
          fn _event, _measurements, meta, _config ->
            if meta.insight_id == insight_id,
              do: send(test_pid, {:insight_broadcast, meta.event, meta.in_transaction?})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "a needs_call insight stays on the admin's tab after the disseminator delivers it",
         %{conn: conn} do
      enable_dissemination!()
      dreaming_agent!()
      admin = root_admin!()
      member = person!()
      call = needs_call_briefing!(person!("member", external: true))

      assert {:ok, %{items: items}} = Disseminator.run(notifications_module: PushRecorder)
      assert items >= 1

      # It went to the admins' briefings as a pointer to this tab.
      assert %Insight{state: "open", delivered_at: %DateTime{}} = Repo.get!(Insight, call.id)
      assert Enum.any?(Repo.all(Briefing), &(&1.user_id == admin.id))

      view = tab!(conn, admin)
      assert has_element?(view, ~s(#insight-row-#{call.id} [data-role="insight-needs-call"]))
      assert has_element?(view, ~s(#insight-row-#{call.id} [data-role="insight-primary"]))
      assert view |> row(call, "mobile") |> Enum.count() == 1

      # A member sees the same row, with no buttons.
      member_view = tab!(conn, member)

      assert has_element?(
               member_view,
               ~s(#insight-row-#{call.id} [data-role="insight-needs-call"])
             )

      refute has_element?(member_view, ~s(#insight-row-#{call.id} [data-role="insight-primary"]))

      # Control: a delivered reversible briefing still leaves the tab.
      line = insight!(addressee: member, body: "Deploys moved to host-b this week.")
      assert {:ok, %{items: 1}} = Disseminator.run(notifications_module: PushRecorder)
      assert %Insight{delivered_at: %DateTime{}} = Repo.get!(Insight, line.id)
      refute has_element?(tab!(conn, admin), ~s(#insight-row-#{line.id}))
    end

    test "a second session sees an answered question in Already done without a reload",
         %{conn: conn} do
      enable_dissemination!()
      dreaming_agent!()
      ben = person!()

      question =
        insight!(
          addressee: ben,
          action_type: "question",
          body: "Is Scout still an active agent?",
          evidence: "agent_runtimes.last_connected_at: scout never connected",
          action: %{"target" => "org/agents.md"}
        )

      assert {:ok, %{items: 1}} = Disseminator.run(notifications_module: PushRecorder)

      ada_view = tab!(conn, root_admin!())

      refute has_element?(
               ada_view,
               ~s([data-role="insights-already-done"] [data-insight-id="#{question.id}"])
             )

      capture_broadcasts!(question.id)

      assert {:ok, %Insight{state: "done"}} =
               Insights.answer(question.id, Scope.for_user(ben), "Scout was retired in August")

      # The :acted broadcast left after the commit. Under the test sandbox a
      # second process's read waits for the transaction to end, so the
      # render below cannot by itself see a pre-commit broadcast; this is the
      # assertion that can.
      assert_received {:insight_broadcast, :acted, false}
      refute_received {:insight_broadcast, _event, true}

      # Ada's window, never reloaded, lists the answer under Already done.
      assert has_element?(
               ada_view,
               ~s([data-role="insights-already-done"] [data-insight-id="#{question.id}"])
             )
    end
  end
end
