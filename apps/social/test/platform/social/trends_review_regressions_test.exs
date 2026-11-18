defmodule PlatformWeb.TrendsReviewRegressionsTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query
  import Platform.SocialStudioFixtures
  alias Platform.{Repo, Social}
  alias Social.Trends.{Wikimedia, Refresher}

  @now ~U[2026-11-14 12:00:00Z]
  @fixture Path.expand(
             "../../fixtures/wikimedia/top-en-2026-11-13.json",
             __DIR__
           )

  test "article filtering also excludes User_talk pages" do
    body = @fixture |> File.read!() |> Jason.decode!()
    [entry] = body["items"]
    [first, second, third | rest] = entry["articles"]

    body = %{
      "items" => [
        %{
          entry
          | "articles" => [
              %{first | "article" => "User_talk:Example"},
              %{second | "article" => "File_talk:Example"},
              %{third | "article" => "Star_Trek:_Example"} | rest
            ]
        }
      ]
    }

    assert {:ok, snapshot} = Wikimedia.parse_response(body, ~D[2026-11-13], @now, 50)
    included? = Enum.any?(snapshot.items, &(&1.id == "User_talk:Example"))
    refute included?
    refute Enum.any?(snapshot.items, &(&1.id == "File_talk:Example"))
    assert Enum.any?(snapshot.items, &(&1.id == "Star_Trek:_Example"))
  end

  test "invalid negative Retry-After recovers after the ordinary invalid-header fallback" do
    studio_world!()
    keys = [:trends, :trends_wikimedia, :trends_req_options]
    old = Map.new(keys, &{&1, Application.get_env(:social, &1)})

    on_exit(fn ->
      Enum.each(old, fn {k, v} ->
        if v == nil,
          do: Application.delete_env(:social, k),
          else: Application.put_env(:social, k, v)
      end)
    end)

    Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")
    Application.put_env(:social, :trends_wikimedia, contact: "https://example.com/contact")
    Application.put_env(:social, :trends_req_options, plug: {Req.Test, Wikimedia})
    parent = self()

    Req.Test.stub(Wikimedia, fn conn ->
      send(parent, :requested)
      conn |> Plug.Conn.put_resp_header("retry-after", "-1") |> Plug.Conn.send_resp(429, "slow")
    end)

    assert {:error, :throttled} = Refresher.refresh(@now)
    assert_receive :requested
    assert {:error, :throttled} = Refresher.refresh(DateTime.add(@now, 86_401, :second))
    assert_receive :requested
  end

  test "oversized Retry-After values use bounded fallback rather than indefinitely blocking" do
    studio_world!()
    keys = [:trends, :trends_wikimedia, :trends_req_options]
    old = Map.new(keys, &{&1, Application.get_env(:social, &1)})

    on_exit(fn ->
      Enum.each(old, fn {k, v} ->
        if v == nil,
          do: Application.delete_env(:social, k),
          else: Application.put_env(:social, k, v)
      end)
    end)

    Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")
    Application.put_env(:social, :trends_wikimedia, contact: "https://example.com/contact")
    Application.put_env(:social, :trends_req_options, plug: {Req.Test, Wikimedia})
    parent = self()

    for header <- ["999999999999999999999", "Fri, 31 Dec 9999 23:59:59 GMT"] do
      Repo.delete_all(Social.Trends.SourceState)

      Req.Test.stub(Wikimedia, fn conn ->
        send(parent, :requested)

        conn
        |> Plug.Conn.put_resp_header("retry-after", header)
        |> Plug.Conn.send_resp(429, "slow")
      end)

      assert {:error, :throttled} = Refresher.refresh(@now)
      assert_receive :requested
      assert {:error, :throttled} = Refresher.refresh(DateTime.add(@now, 86_401, :second))
      assert_receive :requested
    end
  end

  test "an event rendered for brand A does not silently create an idea for brand B", %{conn: conn} do
    w = studio_world!()

    {:ok, other} =
      Social.create_profile(w.org_id, %{
        name: "Other brand",
        project_id: w.profile.project_id,
        approver_user_ids: [w.approver.id]
      })

    {:ok, _} = Social.Studio.set_enabled(w.org_id, other.id, w.approver.id, true)

    {:ok, _snapshot} =
      Social.Trends.record_snapshot(%{
        source: "wikimedia_pageviews",
        limit: 1,
        complete: true,
        reporting_date: ~D[2026-11-13],
        observed_at: @now,
        items: [
          %{
            id: "Example",
            rank: 1,
            title: "Example",
            url: "https://en.wikipedia.org/wiki/Example",
            pageviews: 1
          }
        ]
      })

    conn = Plug.Test.init_test_session(conn, current_user_id: w.approver.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{w.profile.id}")
    view = find_live_child(parent, "ext-page-social")
    assert has_element?(view, "[data-role='trend-to-idea']")

    [{"button", attrs, _}] =
      view |> element("[data-role='trend-to-idea']") |> render() |> Floki.parse_fragment!()

    payload = Map.new(for {"phx-value-" <> key, value} <- attrs, do: {key, value})
    view |> form("#social-profile-switcher", %{profile_id: other.id}) |> render_change()
    render_click(view, "studio_trend_to_idea", payload)
    assert Repo.aggregate(from(i in Social.Idea, where: i.profile_id == ^other.id), :count) == 0
  end

  test "a missing reporting day is labelled and never shows rank movement", %{conn: conn} do
    w = studio_world!()

    for {date, time, rank} <- [
          {~D[2026-11-12], ~U[2026-11-13 12:00:00Z], 3},
          {~D[2026-11-14], ~U[2026-11-15 12:00:00Z], 1}
        ] do
      assert {:ok, _} =
               Social.Trends.record_snapshot(%{
                 source: "wikimedia_pageviews",
                 limit: 10,
                 complete: true,
                 reporting_date: date,
                 observed_at: time,
                 items: [
                   %{
                     id: "Example",
                     rank: rank,
                     title: "Example",
                     url: "https://en.wikipedia.org/wiki/Example",
                     pageviews: 1_204_551
                   }
                 ]
               })
    end

    conn = Plug.Test.init_test_session(conn, current_user_id: w.approver.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{w.profile.id}")
    view = find_live_child(parent, "ext-page-social")
    assert has_element?(view, "[data-role='studio-trends']", "No consecutive-day comparison")
    assert has_element?(view, "[data-role='studio-trends']", "1,204,551 pageviews")
    refute has_element?(view, "[data-role='studio-trends']", "Up 2")
  end

  test "refresh list reads a newly stored observation without reloading the page", %{conn: conn} do
    w = studio_world!()

    snapshot = fn date, time, title ->
      %{
        source: "wikimedia_pageviews",
        limit: 1,
        complete: true,
        reporting_date: date,
        observed_at: time,
        items: [
          %{
            id: title,
            rank: 1,
            title: title,
            url: "https://en.wikipedia.org/wiki/Example",
            pageviews: 123
          }
        ]
      }
    end

    assert {:ok, _} =
             Social.Trends.record_snapshot(
               snapshot.(~D[2026-11-13], ~U[2026-11-14 12:00:00Z], "Earlier")
             )

    conn = Plug.Test.init_test_session(conn, current_user_id: w.approver.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{w.profile.id}")
    view = find_live_child(parent, "ext-page-social")
    assert has_element?(view, "[data-role='studio-trends']", "Earlier")

    assert {:ok, _} =
             Social.Trends.record_snapshot(
               snapshot.(~D[2026-11-14], ~U[2026-11-15 12:00:00Z], "Later")
             )

    refute has_element?(view, "[data-role='studio-trends']", "Later")
    view |> element("[data-role='trends-refresh']") |> render_click()
    assert has_element?(view, "[data-role='studio-trends']", "Later")
  end
end
