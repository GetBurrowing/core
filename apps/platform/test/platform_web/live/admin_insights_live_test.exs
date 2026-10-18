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
          "Only high-confidence insights are sent. Mail outside the org, deletes and permission changes always wait for a person."
        ] do
      assert html =~ copy, "missing copy: #{copy}"
    end

    # The limits sit on the master switch itself, not on a later page.
    assert has_element?(
             view,
             ~s([data-role="insights-limits"]),
             "Mail outside the org, deletes and permission changes always wait for a person."
           )

    # The deferred paths are disabled and say why.
    assert has_element?(view, ~s(input[data-role="insights-apply-page-edits"][disabled]))
    assert has_element?(view, ~s(input[data-role="insights-file-tasks"][disabled]))
    assert length(Regex.scan(~r/Not available yet/, html)) == 2
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

    # A forged deferred value never reaches the settings.
    render_submit(view, "save", %{
      "settings" => %{"apply_page_edits" => "true", "file_tasks" => "true"}
    })

    settings = Settings.get()
    refute settings.apply_page_edits
    refute settings.file_tasks
  end
end
