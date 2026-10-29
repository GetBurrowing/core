defmodule PlatformWeb.SocialResultsTabTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Ecto.Query
  alias Platform.{Repo, Social}
  alias Platform.Social.{Idea, IdeaNotes, Ideas, Post}

  setup do
    w = render_world!()

    {:ok, li} =
      Social.create_account(w.org_id, w.profile, %{
        platform: "linkedin",
        handle: "@results",
        weekly_goal: 5
      })

    li = li |> Ecto.Changeset.change(weekly_goal: 5) |> Repo.update!()
    %{w: Map.put(w, :li, li)}
  end

  defp idea(w, title) do
    {:ok, i} =
      Ideas.create(
        w.scope,
        w.profile.id,
        %{title: title, source_kind: "human"},
        {:user, w.approver.id}
      )

    i
  end

  defp post(w, a, idea, metrics, days \\ 0, fields \\ []) do
    {:ok, p} = Social.create_post(w.org_id, a, %{body: "Published reference"})

    p
    |> Ecto.Changeset.change(
      Keyword.merge(
        [
          idea_id: if(idea, do: idea.id),
          status: "published",
          approved_at: DateTime.utc_now(),
          approved_by_user_id: w.approver.id,
          published_at: DateTime.add(DateTime.utc_now(), -days * 86400 - 60),
          metrics_synced_at: DateTime.utc_now(),
          metrics: metrics,
          external_url: "https://example.com/live"
        ],
        fields
      )
    )
    |> Repo.update!()
  end

  defp open(conn, w, user \\ nil) do
    conn = Plug.Test.init_test_session(conn, current_user_id: (user || w.approver).id)
    {:ok, parent, _} = live(conn, "/m/social?tab=results&profile=#{w.profile.id}")
    find_live_child(parent, "ext-page-social")
  end

  defp period(v, p), do: render_click(v, "results_period", %{"period" => to_string(p)})

  test "expands versions, measured zero, unknown data, no-rate and labeled weekly ring", %{
    conn: c,
    w: w
  } do
    i = idea(w, "One idea across platforms")
    post(w, w.li, i, %{"views" => 12400, "likes" => 10, "reach" => 100})
    post(w, w.x, i, %{"views" => 0, "likes" => 0, "reach" => 0})
    post(w, w.tiktok, i, %{}, 0, metrics_synced_at: nil)
    post(w, w.li, nil, %{"likes" => 1})
    post(w, w.li, nil, %{"likes" => 1})
    v = open(c, w)
    assert has_element?(v, "[data-role=goal-label]", "3 of 5 this week")

    assert length(v |> render() |> Floki.parse_document!() |> Floki.find("[data-role=goal-ring]")) ==
             1

    refute has_element?(v, "[data-role=result-version]")
    render_click(v, "results_expand", %{"key" => "idea:#{i.id}"})

    assert length(
             v
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("[data-role=result-version]")
           ) == 3

    assert has_element?(v, "[data-metric=views]", "12.4k")
    assert has_element?(v, "[data-metric=views]", "0")
    assert has_element?(v, "[data-role=no-data]", "No data yet")
    assert has_element?(v, "[data-metric=rate]", "—")
    assert has_element?(v, "a[href='https://example.com/live']")
    assert render(v) =~ "(no idea)"
    period(v, 90)
    assert has_element?(v, "[data-role=goal-label]", "3 of 5 this week")
  end

  test "periods and fresh profile switching isolate brands; forged expansion cannot leak", %{
    conn: c,
    w: w
  } do
    post(w, w.li, idea(w, "Recent idea"), %{"likes" => 1})
    post(w, w.li, idea(w, "Forty day idea"), %{"likes" => 2}, 40)
    {:ok, p} = Social.create_profile(w.org_id, %{name: "Second brand"})
    {:ok, a} = Social.create_account(w.org_id, p, %{platform: "x"})
    other = idea(%{w | profile: p}, "Other brand idea")
    post(w, a, other, %{"likes" => 3})
    foreign = render_world!()
    secret = idea(foreign, "Foreign private title")
    post(foreign, foreign.x, secret, %{"likes" => 999})
    v = open(c, w)
    refute has_element?(v, "[data-role=results-ideas]", "Forty day idea")
    period(v, 90)
    assert has_element?(v, "[data-role=results-ideas]", "Forty day idea")
    period(v, 7)
    refute has_element?(v, "[data-role=results-ideas]", "Forty day idea")
    period(v, 365)
    assert has_element?(v, "button[phx-value-period='7'][aria-pressed=true]")
    render_click(v, "switch_profile", %{"profile_id" => "all"})
    assert has_element?(v, "[data-role=results-ideas]", "Other brand idea")
    assert has_element?(v, "[data-role=results-ideas] .badge", p.name)
    render_click(v, "results_expand", %{"key" => "idea:#{secret.id}"})
    refute has_element?(v, "[data-role=results-ideas]", "Foreign private title")
    render_click(v, "switch_profile", %{"profile_id" => p.id})
    refute has_element?(v, "[data-role=results-ideas]", "Recent idea")
    # The same active view must lose its data after membership is revoked.
    w.approver |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
    period(v, 30)
    refute has_element?(v, "[data-role=result-version]")
    refute has_element?(v, "[data-role=results-ideas]", "Other brand idea")
  end

  test "nine samples show notice and tenth produces account-only heatmap", %{conn: c, w: w} do
    for _ <- 1..9, do: post(w, w.li, nil, %{"likes" => 2}, 10)
    v = open(c, w)

    assert has_element?(
             v,
             "#best-times-#{w.li.id} [data-role=insufficient-posts]",
             "Not enough posts yet (9/10)"
           )

    refute has_element?(v, "#best-times-#{w.li.id} [data-role=best-times-heatmap]")
    refute has_element?(v, "#best-times-#{w.li.id}[open]")
    post(w, w.li, nil, %{"likes" => 412}, 11)
    period(v, 30)
    assert has_element?(v, "#best-times-#{w.li.id} [data-role=best-times-heatmap]")
    assert has_element?(v, "#best-times-#{w.x.id} [data-role=insufficient-posts]", "(0/10)")
    assert render(v) =~ "eng /"
  end

  test "recycle refreshes candidates, creates reference-only Inbox child, replay and forged ids write nothing",
       %{conn: c, w: w} do
    source = idea(w, "Recycle this idea")
    p = post(w, w.li, source, %{"likes" => 1000}, 40)
    v = open(c, w)
    assert has_element?(v, "#recycle-#{source.id} button", "Recycle as new idea")
    before = Repo.aggregate(Post, :count)
    render_click(v, "results_recycle", %{"id" => source.id})
    refute has_element?(v, "#recycle-#{source.id}")
    assert render(v) =~ "New idea created in Inbox"
    child = Repo.one!(from(i in Idea, where: i.recycled_from_idea_id == ^source.id))
    assert Ideas.stage([]) == "inbox"
    assert child.source_kind == "human"
    assert Repo.aggregate(Post, :count) == before
    assert [%{body: note}] = IdeaNotes.list(child.id)
    assert note =~ p.id
    render_click(v, "results_recycle", %{"id" => source.id})
    render_click(v, "results_recycle", %{"id" => "malformed"})

    assert Repo.aggregate(from(i in Idea, where: i.recycled_from_idea_id == ^source.id), :count) ==
             1
  end

  test "fresh approver check rejects stale button and forged event", %{conn: c, w: w} do
    source = idea(w, "Approver protected")
    post(w, w.li, source, %{"likes" => 10}, 40)
    v = open(c, w)
    w.profile |> Ecto.Changeset.change(approver_user_ids: []) |> Repo.update!()
    render_click(v, "results_recycle", %{"id" => source.id})
    refute Repo.exists?(from(i in Idea, where: i.recycled_from_idea_id == ^source.id))
    refute has_element?(v, "#recycle-#{source.id} button")
    assert render(v) =~ "could not be recycled"
  end

  test "multi-org member recycles All brands without root scope and rejects inaccessible cohort",
       %{conn: c, w: w} do
    source = idea(w, "Multi-org source")
    post(w, w.li, source, %{"likes" => 1000}, 40)
    second = render_world!()
    member!(w.approver, second.org_id)
    post(second, second.x, idea(second, "Other visible org"), %{"likes" => 10}, 40)
    hidden = render_world!()
    secret = idea(hidden, "Inaccessible org source")
    post(hidden, hidden.x, secret, %{"likes" => 99999}, 40)
    assert Platform.Tenancy.visibility(Platform.Accounts.get_user(w.approver.id)) != :root_all

    assert {:error, :not_found} =
             Social.Results.recycle(w.scope, source.id, w.approver.id,
               profiles: [w.profile, hidden.profile]
             )

    refute Repo.exists?(from(i in Idea, where: i.recycled_from_idea_id == ^source.id))
    v = open(c, w)
    render_click(v, "switch_profile", %{"profile_id" => "all"})
    assert has_element?(v, "#recycle-#{source.id} button")
    render_click(v, "results_recycle", %{"id" => secret.id})
    refute Repo.exists?(from(i in Idea, where: i.recycled_from_idea_id == ^secret.id))
    render_click(v, "results_recycle", %{"id" => source.id})

    assert Repo.exists?(
             from(i in Idea,
               where: i.recycled_from_idea_id == ^source.id and i.org_id == ^w.org_id
             )
           )

    assert render(v) =~ "New idea created in Inbox"
  end
end
