defmodule PlatformWeb.AdminFederationLiveDeadLettersTest do
  @moduledoc """
  The dead-letter surface in `/admin/federation` (task 019fa56b-ca2d stage 5).

  The assertion this file exists for is
  `cumulative panel outlives the rows it is rendered above/1`: after a prune,
  the panel's `recorded` total must read GREATER than the number of ledger rows
  on screen. Before this stage the header badge was literally
  `{length(@dead_letters)}` (`admin_federation_live.html.heex:112`), so any
  "total" that re-derived itself from the row list would shrink the moment the
  ledger was pruned — which is the exact shape of the 2026-07-27 misreading
  this stage exists to make unavailable. A test that only checked "some number
  renders" would pass against that bug.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetters
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @runtime_id "runtime-dead-letters-test"

  defp admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "dl-admin-#{n}@example.com",
        name: "Dead Letter Admin #{n}",
        oidc_sub: "oidc-dl-admin-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("fabrikam").id,
      role: "admin"
    })
    |> Repo.insert!()

    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  # One arrival. Distinct `subject_id` per call so the ledger's partial unique
  # index never collapses two of these into one row — a collapse would move
  # `superseded_duplicate` and quietly change the arithmetic this file asserts.
  defp record!(opts) do
    {:ok, row} =
      DeadLetters.record(%{
        runtime_id: @runtime_id,
        source: :system_event,
        agent_slug: Keyword.get(opts, :agent_slug, "dalton"),
        responsibility_key: Keyword.get(opts, :responsibility_key, "task.stage_ready"),
        trigger_kind: Keyword.get(opts, :trigger_kind, :event_topic),
        subject_type: "task",
        subject_id: Keyword.get(opts, :subject_id, Ecto.UUID.generate()),
        reason: :system_event,
        occurred_at: DateTime.utc_now()
      })

    case Keyword.get(opts, :disposition) do
      nil ->
        row

      "pending" ->
        row

      disposition ->
        {:ok, marked} = DeadLetters.mark(row, disposition, bump_attempts: true)
        marked
    end
  end

  # 9 arrivals: 6 terminal (prunable) + 3 live (not prunable). Returns the live
  # rows, which are the ones that must still be on screen after a prune.
  defp seed_every_disposition! do
    pending_a = record!(disposition: "pending", responsibility_key: "task.stage_ready")
    pending_b = record!(disposition: "pending", responsibility_key: "meetings.summary")
    replaying = record!(disposition: "replaying", responsibility_key: "task.stage_ready")

    _terminal = [
      record!(disposition: "replayed", responsibility_key: "task.stage_ready"),
      record!(disposition: "replayed", responsibility_key: "meetings.summary"),
      record!(disposition: "dropped_policy", responsibility_key: "task.stage_ready"),
      record!(disposition: "dropped_stale", responsibility_key: "meetings.summary"),
      record!(disposition: "superseded_duplicate", responsibility_key: "task.stage_ready"),
      record!(disposition: "abandoned", responsibility_key: "meetings.summary")
    ]

    %{pending_a: pending_a, pending_b: pending_b, replaying: replaying}
  end

  # Element extraction via LazyHTML, never an attribute-order regex — same rule
  # `icon_rail_test.exs` states.
  defp visible_row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#dead-letter-rows tr")
    |> LazyHTML.attribute("id")
  end

  defp panel_number(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
    |> String.to_integer()
  end

  describe "the ledger table" do
    test "renders a row per dead letter with the ledger's own columns", %{conn: conn} do
      row =
        record!(
          agent_slug: "higgins",
          responsibility_key: "task.stage_ready",
          trigger_kind: :event_topic,
          disposition: "pending"
        )

      {:ok, view, html} = conn |> admin_conn() |> live(~p"/admin/federation")

      assert has_element?(view, "#dead-letter-#{row.id}")
      assert html =~ "task.stage_ready"
      assert html =~ "event_topic"
      assert html =~ "higgins"
      # Subject renders as a short id, not the full uuid column dump.
      assert html =~ String.slice(row.subject_id, 0, 8)
    end

    test "every disposition in the vocabulary renders its own badge", %{conn: conn} do
      seed_every_disposition!()

      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/federation")

      for disposition <- DeadLetter.dispositions() do
        assert has_element?(view, "[data-disposition='#{disposition}']"),
               "no badge rendered for disposition #{disposition}"
      end
    end

    test "drops the 'since last restart' caption that stage 1 made false", %{conn: conn} do
      {:ok, _view, html} = conn |> admin_conn() |> live(~p"/admin/federation")

      refute html =~ "since last restart"
    end
  end

  describe "the cumulative panel" do
    test "is captioned as a since-inception total, not a snapshot", %{conn: conn} do
      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/federation")

      caption = view |> element("#dead-letter-cumulative-caption") |> render()

      assert caption =~ "since inception"
      assert caption =~ "not a snapshot"
    end

    test "outlives the rows it is rendered above", %{conn: conn} do
      live_rows = seed_every_disposition!()

      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/federation")

      assert length(visible_row_ids(view)) == 9
      assert panel_number(view, "#dead-letter-count-recorded") == 9

      view |> element("#prune-dead-letters") |> render_click()

      visible = visible_row_ids(view)
      recorded = panel_number(view, "#dead-letter-count-recorded")

      # The load-bearing assertion. `length(@dead_letters)` would now read 3.
      assert recorded > length(visible),
             "cumulative recorded (#{recorded}) must exceed the #{length(visible)} rows " <>
               "still on screen after a prune — a panel that re-derives from the row " <>
               "list cannot satisfy this"

      assert recorded == 9
      assert length(visible) == 3

      # Prune removed only terminal rows; the replay queue is intact.
      assert "dead-letter-#{live_rows.pending_a.id}" in visible
      assert "dead-letter-#{live_rows.pending_b.id}" in visible
      assert "dead-letter-#{live_rows.replaying.id}" in visible
    end

    test "reports each terminal outcome and the live backlog separately", %{conn: conn} do
      seed_every_disposition!()

      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/federation")

      assert panel_number(view, "#dead-letter-count-replayed") == 2
      assert panel_number(view, "#dead-letter-count-dropped-policy") == 1
      assert panel_number(view, "#dead-letter-count-dropped-stale") == 1
      assert panel_number(view, "#dead-letter-count-superseded-duplicate") == 1
      assert panel_number(view, "#dead-letter-count-abandoned") == 1
      # Live term, read off the ledger — pending + replaying.
      assert panel_number(view, "#dead-letter-count-pending") == 3
    end

    test "breaks arrivals down per responsibility key", %{conn: conn} do
      seed_every_disposition!()

      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/federation")

      assert has_element?(view, "#dead-letter-key-task-stage_ready")
      assert has_element?(view, "#dead-letter-key-meetings-summary")

      # Arrivals per key: 5 for task.stage_ready, 4 for meetings.summary.
      assert panel_number(view, "#dead-letter-key-task-stage_ready [data-count='recorded']") == 5
      assert panel_number(view, "#dead-letter-key-meetings-summary [data-count='recorded']") == 4
    end
  end

  describe "prune" do
    test "cannot delete the replay queue", %{conn: conn} do
      live_rows = seed_every_disposition!()

      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/federation")

      view |> element("#prune-dead-letters") |> render_click()

      assert has_element?(view, "#dead-letter-#{live_rows.pending_a.id}")
      assert has_element?(view, "#dead-letter-#{live_rows.pending_b.id}")
      assert has_element?(view, "#dead-letter-#{live_rows.replaying.id}")

      # And in the database, not only on screen.
      assert DeadLetters.outstanding_count() == 3
    end

    test "leaves the cumulative counters untouched", %{conn: conn} do
      seed_every_disposition!()

      {:ok, view, _html} = conn |> admin_conn() |> live(~p"/admin/federation")

      before_prune = DeadLetters.loss_summary()

      view |> element("#prune-dead-letters") |> render_click()

      after_prune = DeadLetters.loss_summary()

      assert after_prune.recorded == before_prune.recorded
      assert after_prune.replayed == before_prune.replayed
      assert after_prune.abandoned == before_prune.abandoned
      assert after_prune.balanced
      assert panel_number(view, "#dead-letter-count-recorded") == before_prune.recorded
    end
  end
end
