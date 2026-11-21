defmodule PlatformWeb.SocialIdeaVotingTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social.{Ideas, IdeaVotes}

  defp open(conn, user, query) do
    {:ok, parent, _} =
      conn |> Plug.Test.init_test_session(current_user_id: user.id) |> live("/m/social" <> query)

    find_live_child(parent, "ext-page-social")
  end

  test "ordinary readers vote, the third vote moves to Shortlisted, and withdrawal moves back", %{
    conn: conn
  } do
    w = approval_fixture()

    {:ok, idea} =
      Ideas.create(w.org_id, w.profile.id, %{title: "A shared idea"}, {:agent, w.g.id})

    for user <- [w.h1, w.h2],
        do: assert({:ok, _} = IdeaVotes.vote(w.org_id, idea.id, {:user, user.id}))

    view = open(conn, w.n, "?tab=ideas&profile=#{w.profile.id}")

    assert has_element?(
             view,
             "#ideas-lane-inbox [data-idea-id='#{idea.id}'] [data-role='idea-vote-count']",
             "2 votes"
           )

    view |> element("[data-role='idea-vote'][phx-value-id='#{idea.id}']") |> render_click()
    assert has_element?(view, "#ideas-lane-shortlisted [data-idea-id='#{idea.id}']", "3 votes")
    assert has_element?(view, "[data-role='idea-vote'][aria-pressed='true'][disabled]", "Voted")
    view |> element("[data-role='idea-card-open'][phx-value-id='#{idea.id}']") |> render_click()
    assert has_element?(view, "[data-role='idea-detail-votes']", "3 votes")
    assert has_element?(view, "[data-role='idea-detail-voted']", "You voted")
    refute has_element?(view, "[data-role='idea-detail-voters']")
    refute has_element?(view, "[data-role='idea-voters']")
    view |> element("[data-role='idea-detail-close']") |> render_click()
    view |> element("[data-role='idea-unvote'][phx-value-id='#{idea.id}']") |> render_click()
    assert has_element?(view, "#ideas-lane-inbox [data-idea-id='#{idea.id}']", "2 votes")
  end

  test "a repeated rendered vote action does not accidentally withdraw", %{conn: conn} do
    w = approval_fixture()
    {:ok, idea} = Ideas.create(w.org_id, w.profile.id, %{title: "Repeat vote"}, {:agent, w.g.id})
    view = open(conn, w.n, "?tab=ideas&profile=#{w.profile.id}")
    render_click(view, "ideas_vote", %{"id" => idea.id, "action" => "vote"})
    render_click(view, "ideas_vote", %{"id" => idea.id, "action" => "vote"})
    assert has_element?(view, "[data-role='idea-vote-count']", "1 vote")
  end

  test "replayed vote after profile visibility is lost writes nothing", %{conn: conn} do
    import Ecto.Query
    w = approval_fixture()
    {:ok, idea} = Ideas.create(w.org_id, w.profile.id, %{title: "Private idea"}, {:agent, w.g.id})
    view = open(conn, w.n, "?tab=ideas&profile=#{w.profile.id}")

    Platform.Repo.delete_all(
      from(m in Platform.Tenancy.OrgMembership, where: m.user_id == ^w.n.id)
    )

    render_click(view, "ideas_vote", %{"id" => idea.id, "action" => "vote"})
    assert Platform.Repo.aggregate(Platform.Social.IdeaVote, :count) == 0
  end

  test "Today puts shortlisted agent ideas ahead of newer unvoted ideas", %{conn: conn} do
    w = studio_world!()
    agent = pinned_agent!(w.org_id)

    {:ok, shortlist} =
      Ideas.create(w.org_id, w.profile.id, %{title: "Old shortlisted"}, {:agent, agent.id})

    for _ <- 1..3 do
      voter = pinned_agent!(w.org_id)
      assert {:ok, _} = IdeaVotes.vote(w.org_id, shortlist.id, {:agent, voter.id})
    end

    for n <- 1..6,
        do:
          assert(
            {:ok, _} =
              Ideas.create(w.org_id, w.profile.id, %{title: "New #{n}"}, {:agent, agent.id})
          )

    view = open(conn, w.approver, "?tab=today&profile=#{w.profile.id}")

    rows =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='studio-agent-idea']")
      |> Enum.map(&LazyHTML.text/1)

    assert length(rows) == 5
    assert String.contains?(hd(rows), "Old shortlisted")
  end

  test "Today reorders after the viewer shortlists an idea", %{conn: conn} do
    w = studio_world!()
    creator = pinned_agent!(w.org_id)

    {:ok, older} =
      Ideas.create(w.org_id, w.profile.id, %{title: "Older idea"}, {:agent, creator.id})

    {:ok, newer} =
      Ideas.create(w.org_id, w.profile.id, %{title: "Newly shortlisted"}, {:agent, creator.id})

    Platform.Repo.update!(
      Ecto.Changeset.change(older, inserted_at: ~U[2026-01-01 00:00:00.000000Z])
    )

    Platform.Repo.update!(
      Ecto.Changeset.change(newer, inserted_at: ~U[2026-01-02 00:00:00.000000Z])
    )

    for idea <- [older, newer], _ <- 1..2 do
      voter = pinned_agent!(w.org_id)
      assert {:ok, _} = IdeaVotes.vote(w.org_id, idea.id, {:agent, voter.id})
    end

    {:ok, parent, _} =
      conn
      |> Plug.Test.init_test_session(current_user_id: w.approver.id)
      |> live("/m/social?tab=ideas&profile=#{w.profile.id}")

    view = find_live_child(parent, "ext-page-social")
    view |> element("[data-role='idea-vote'][phx-value-id='#{newer.id}']") |> render_click()
    assert has_element?(view, "#ideas-lane-shortlisted [data-idea-id='#{newer.id}']", "3 votes")
    view |> element("[data-role='social-tab-button'][data-tab='today']") |> render_click()

    titles =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='studio-agent-idea']")
      |> Enum.map(&LazyHTML.text/1)

    assert [first | _] = titles
    assert first =~ "Newly shortlisted"
    view |> element("[data-role='social-tab-button'][data-tab='ideas']") |> render_click()
    view |> element("[data-role='idea-unvote'][phx-value-id='#{newer.id}']") |> render_click()
    view |> element("[data-role='social-tab-button'][data-tab='today']") |> render_click()

    titles =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='studio-agent-idea']")
      |> Enum.map(&LazyHTML.text/1)

    assert [first | _] = titles
    assert first =~ "Older idea"
  end

  test "returning to Today preserves an authorized open editor and unsaved text", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Original"})
    view = open(conn, w.approver, "?tab=today&profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()

    Platform.Repo.update!(
      Ecto.Changeset.change(post, body: "Other edit", version: post.version + 1)
    )

    view |> form("#studio-edit-form", %{body: "Unsaved text"}) |> render_submit()
    assert has_element?(view, "#studio-edit-body", "Unsaved text")
    view |> element("[data-role='social-tab-button'][data-tab='ideas']") |> render_click()
    view |> element("[data-role='social-tab-button'][data-tab='today']") |> render_click()
    assert has_element?(view, "[data-role='studio-post-detail'][data-post-id='#{post.id}']")
    assert has_element?(view, "#studio-edit-body", "Unsaved text")
    assert Platform.Social.get_post(w.org_id, post.id).body == "Other edit"
  end
end
