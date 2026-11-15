defmodule PlatformWeb.InboxLiveBriefingSectionsTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.InsightFixtures
  alias Platform.Repo
  alias Platform.FixtureExtension
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insights.BriefingCard

  setup do
    FixtureExtension.register([])
    on_exit(fn -> Application.delete_env(:platform, :fixture_briefing_section) end)
    :ok
  end

  test "silent section preserves HTML and interactive section owns events and refreshes counts",
       %{conn: conn} do
    user = person!()
    question = insight!(addressee: user, action_type: "question", body: "Which host?")
    date = PlatformWeb.Components.BriefingRow.today(nil)

    briefing =
      Repo.insert!(%Briefing{
        user_id: user.id,
        digest_date: date,
        items: %{BriefingCard.node_key(question) => question.id}
      })

    Platform.Inbox.upsert_briefing_item(briefing, %{total: 1, calls: 1})
    conn = init_test_session(conn, current_user_id: user.id)
    path = "/inbox/briefing/#{date}"
    {:ok, lv0, _} = live(conn, path)
    h0 = lv0 |> element("[data-role=briefing-detail]") |> render()
    FixtureExtension.register()
    {:ok, lv1, _} = live(conn, path)
    h1 = lv1 |> element("[data-role=briefing-detail]") |> render()
    assert h0 == h1

    Application.put_env(:platform, :fixture_briefing_section, %{
      user.id => %{summary: %{total: 3, open: 2, calls: 1}}
    })

    {:ok, lv, html} = live(conn, path)
    assert has_element?(lv, "[data-role=fixture-briefing]")
    assert html =~ "1 of 4 handled"
    [before_fixture, after_fixture] = String.split(html, "Fixture section", parts: 2)
    refute before_fixture =~ "data-role=\"briefing-section\""
    assert after_fixture =~ "data-role=\"briefing-section\""
    lv |> element("[data-role=fixture-briefing] button") |> render_click()
    assert render(lv) =~ "3 of 4 handled"
  end
end
