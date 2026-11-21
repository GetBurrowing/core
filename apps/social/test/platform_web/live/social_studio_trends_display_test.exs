defmodule PlatformWeb.SocialStudioTrendsDisplayTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialStudioFixtures
  alias Platform.Social.Trends

  defp open(conn, user, profile) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{profile.id}")
    find_live_child(parent, "ext-page-social")
  end

  defp rows(ids, title \\ &"Article #{&1}") do
    ids
    |> Enum.with_index(1)
    |> Enum.map(fn {id, position} ->
      %{
        id: "article-#{id}",
        rank: 2 * position + 1,
        title: title.(id),
        url: "https://en.wikipedia.org/wiki/Article_#{id}",
        pageviews: 10_000 - position
      }
    end)
  end

  defp store(items, date, time) do
    {:ok, _} =
      Trends.record_snapshot(%{
        source: "wikimedia_pageviews",
        limit: 50,
        complete: true,
        reporting_date: date,
        observed_at: time,
        items: items
      })
  end

  defp displayed_ids(view) do
    view
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("[data-role='studio-trends'] [data-role='trend-to-idea']")
    |> Enum.map(fn {_, attrs, _} -> attrs |> Map.new() |> Map.fetch!("data-story-id") end)
  end

  test "shows ten current articles in source order with original ranks and the full comparison",
       %{conn: conn} do
    w = studio_world!()

    store(
      rows(Enum.to_list(11..50) ++ Enum.to_list(1..10)),
      ~D[2026-11-12],
      ~U[2026-11-13 12:00:00Z]
    )

    store(rows(1..50), ~D[2026-11-13], ~U[2026-11-14 12:00:00Z])
    view = open(conn, w.approver, w.profile)

    assert length(displayed_ids(view)) == 10
    assert displayed_ids(view) == Enum.map(1..10, &"article-#{&1}")

    ranks =
      view
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find("[data-role='studio-trends'] [data-role='trend-rank']")
      |> Enum.map(fn node -> node |> Floki.text() |> String.trim() |> String.to_integer() end)

    assert ranks == Enum.map(1..10, &(2 * &1 + 1))
    assert has_element?(view, "[data-role='studio-trends']", "Up 80")
    assert has_element?(view, "[data-role='studio-trends']", "Showing up to 10 articles")
    %{current: current, previous: previous} = Trends.latest("wikimedia_pageviews")
    assert length(current.items) == 50
    assert length(previous.items) == 50
  end

  test "the existing title filter runs before the ten-article display cap", %{conn: conn} do
    w = studio_world!()

    store(
      rows(1..50, fn id ->
        if id in 11..30, do: "AI article #{id}", else: "General article #{id}"
      end),
      ~D[2026-11-13],
      ~U[2026-11-14 12:00:00Z]
    )

    view = open(conn, w.approver, w.profile)
    view |> element("[data-role='trends-ai-filter']") |> render_click()
    assert length(displayed_ids(view)) == 10
    assert displayed_ids(view) == Enum.map(11..20, &"article-#{&1}")
    assert length(Trends.latest("wikimedia_pageviews").current.items) == 50
  end

  test "a smaller observation and an empty filtered list remain honest", %{conn: conn} do
    w = studio_world!()
    store(rows(1..3), ~D[2026-11-13], ~U[2026-11-14 12:00:00Z])
    view = open(conn, w.approver, w.profile)
    assert length(displayed_ids(view)) == 3
    assert has_element?(view, "[data-role='studio-trends']", "Showing up to 10 articles")
    view |> element("[data-role='trends-ai-filter']") |> render_click()
    assert displayed_ids(view) == []
    assert has_element?(view, "[data-role='studio-trends']", "No matching article titles")
    assert length(Trends.latest("wikimedia_pageviews").current.items) == 3
  end
end
