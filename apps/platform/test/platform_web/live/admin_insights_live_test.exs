defmodule PlatformWeb.AdminInsightsLiveTest do
  @moduledoc """
  `/admin/insights` (task 01a13867 stage 5): whether dreaming insights are
  sent beyond the Insights tab. Admin-only by the `:admin` live_session, and
  `Platform.Memory.Insights.Settings.update/2` re-checks root admin.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.InsightFixtures
  import Platform.TenancyFixtures

  alias Platform.Memory.Insights.Settings
  alias PlatformWeb.AdminInsightsLive

  @form "#admin-insights-form"

  defp conn_for(conn, user), do: init_test_session(conn, %{"current_user_id" => user.id})

  test "a non-admin is refused", %{conn: conn} do
    assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
             conn |> conn_for(person!("member")) |> live(~p"/admin/insights")

    # The context refuses the write on its own, whatever the route did.
    assert {:error, :unauthorized} =
             Settings.update(person!("member"), %{dissemination_enabled: true})

    refute Settings.get().dissemination_enabled

    # Control: an admin mounts the page.
    {:ok, _view, html} = conn |> conn_for(root_admin!()) |> live(~p"/admin/insights")
    assert html =~ "Admin · Insights"
  end

  test "settings copy states the hard limits", %{conn: conn} do
    {:ok, view, html} = conn |> conn_for(root_admin!()) |> live(~p"/admin/insights")

    for copy <- [
          "Send insights beyond this tab",
          "Briefings to people",
          "Questions to addressees",
          "Apply page edits automatically",
          "File backlog tasks",
          "Briefings and questions are sent at high confidence. Page edits and backlog tasks are applied at medium confidence or above, and each can be reverted or deleted from the briefing. Mail outside the org, delete-shaped edits and permission changes still wait for a person." <>
            " Turning either automatic switch on applies the eligible open insights from the past 7 days on the next run."
        ] do
      assert html =~ copy, "missing copy: #{copy}"
    end

    # The limits sit on the master switch itself, not on a later page.
    assert has_element?(
             view,
             ~s([data-role="insights-limits"]),
             "Mail outside the org, delete-shaped edits and permission changes still wait for a person."
           )

    assert html =~ AdminInsightsLive.limits()

    # Both automatic paths are real switches now, not disabled placeholders.
    assert has_element?(view, ~s(input[type="checkbox"][data-role="insights-apply-page-edits"]))
    assert has_element?(view, ~s(input[type="checkbox"][data-role="insights-file-tasks"]))
    refute has_element?(view, ~s(input[data-role="insights-apply-page-edits"][disabled]))
    refute has_element?(view, ~s(input[data-role="insights-file-tasks"][disabled]))
    refute html =~ "Not available yet"
  end

  test "the copy says a switch turned on applies the past 7 days of eligible insights", %{
    conn: conn
  } do
    {:ok, view, _html} = conn |> conn_for(root_admin!()) |> live(~p"/admin/insights")

    assert has_element?(
             view,
             ~s([data-role="insights-limits"]),
             "Turning either automatic switch on applies the eligible open insights from the past 7 days on the next run."
           )

    # The 7 days is the insight TTL: the backlog a switch reaches.
    assert Platform.Memory.Insight.default_ttl_days() == 7
  end

  test "the master switch and the two live toggles save", %{conn: conn} do
    {:ok, view, _html} = conn |> conn_for(root_admin!()) |> live(~p"/admin/insights")

    view |> form(@form, %{"settings" => %{"dissemination_enabled" => "true"}}) |> render_submit()
    assert Settings.get().dissemination_enabled

    view
    |> form(@form, %{
      "settings" => %{"deliver_briefings" => "false", "deliver_questions" => "false"}
    })
    |> render_submit()

    settings = Settings.get()
    refute settings.deliver_briefings
    refute settings.deliver_questions
  end

  test "an admin saves both automatic switches", %{conn: conn} do
    {:ok, view, _html} = conn |> conn_for(root_admin!()) |> live(~p"/admin/insights")

    view
    |> form(@form, %{"settings" => %{"apply_page_edits" => "true", "file_tasks" => "true"}})
    |> render_submit()

    assert %Settings{apply_page_edits: true, file_tasks: true} = Settings.get()

    # The re-rendered form reflects the saved row.
    assert has_element?(view, ~s(input[data-role="insights-apply-page-edits"][checked]))
    assert has_element?(view, ~s(input[data-role="insights-file-tasks"][checked]))

    view
    |> form(@form, %{"settings" => %{"apply_page_edits" => "false", "file_tasks" => "false"}})
    |> render_submit()

    assert %Settings{apply_page_edits: false, file_tasks: false} = Settings.get()
  end
end
