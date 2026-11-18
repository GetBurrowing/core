defmodule Platform.Social.TrendsIdeaTest do
  use Platform.DataCase, async: false

  import Platform.SocialStudioFixtures

  alias Platform.Social.{Idea, Trends}

  setup do
    w = studio_world!()

    assert {:ok, _} =
             Trends.record_snapshot(%{
               source: "hn_top",
               limit: 20,
               complete: true,
               observed_at: ~U[2026-11-15 10:00:00Z],
               items: [
                 %{
                   id: "7",
                   rank: 1,
                   title: "Synthetic story",
                   url: "https://example.com/story",
                   points: 20,
                   comments: 4
                 }
               ]
             })

    %{world: w}
  end

  test "turns a trusted observation into an idea and returns it on replay", %{world: w} do
    snapshot = Trends.latest("hn_top").current.id

    assert {:ok, first} =
             Trends.turn_into_idea(w.org_id, w.profile.id, "hn_top", "7", w.approver.id, snapshot)

    assert %Idea{title: "Synthetic story", source_url: "https://example.com/story"} = first
    assert first.brief =~ "20 points"
    assert first.brief =~ "4 comments"
    assert first.brief =~ "2026-11-15"

    assert {:ok, again} =
             Trends.turn_into_idea(w.org_id, w.profile.id, "hn_top", "7", w.approver.id, snapshot)

    assert again.id == first.id
    assert Repo.aggregate(Idea, :count) == 1
  end

  test "refuses an unknown story and unauthorized actor without writing", %{world: w} do
    snapshot = Trends.latest("hn_top").current.id

    assert {:error, :not_found} =
             Trends.turn_into_idea(
               w.org_id,
               w.profile.id,
               "hn_top",
               "999",
               w.approver.id,
               snapshot
             )

    assert {:error, _} =
             Trends.turn_into_idea(w.org_id, w.profile.id, "hn_top", "7", w.outsider.id, snapshot)

    assert {:error, :not_found} =
             Trends.turn_into_idea(
               w.org_id,
               w.profile.id,
               "hn_top",
               "bad\0key",
               w.approver.id,
               snapshot
             )

    assert Repo.aggregate(Idea, :count) == 0
  end

  test "a foreign organization cannot create or recover another profile's idea", %{world: w} do
    snapshot = Trends.latest("hn_top").current.id

    assert {:ok, idea} =
             Trends.turn_into_idea(w.org_id, w.profile.id, "hn_top", "7", w.approver.id, snapshot)

    other = studio_world!()

    assert {:error, :not_found} =
             Trends.turn_into_idea(
               other.org_id,
               w.profile.id,
               "hn_top",
               "7",
               other.approver.id,
               snapshot
             )

    assert Repo.get!(Idea, idea.id).profile_id == w.profile.id
  end

  test "replay after disabling Studio refuses without revealing the existing idea", %{world: w} do
    snapshot = Trends.latest("hn_top").current.id

    assert {:ok, idea} =
             Trends.turn_into_idea(w.org_id, w.profile.id, "hn_top", "7", w.approver.id, snapshot)

    assert {:ok, _} =
             Platform.Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)

    assert {:error, :studio_disabled} =
             Trends.turn_into_idea(w.org_id, w.profile.id, "hn_top", "7", w.approver.id, snapshot)

    assert Repo.get!(Idea, idea.id).title == "Synthetic story"
    assert Repo.aggregate(Idea, :count) == 1
  end

  test "a new idea refuses a stale selected observation", %{world: w} do
    selected = Trends.latest("hn_top").current.id

    assert {:ok, _} =
             Trends.record_snapshot(%{
               source: "hn_top",
               limit: 20,
               complete: true,
               observed_at: ~U[2026-11-15 11:00:00Z],
               items: [
                 %{
                   id: "7",
                   rank: 1,
                   title: "Changed story",
                   url: "https://example.com/changed",
                   points: 21,
                   comments: 5
                 }
               ]
             })

    assert {:error, :stale_observation} =
             Trends.turn_into_idea(w.org_id, w.profile.id, "hn_top", "7", w.approver.id, selected)

    assert Repo.aggregate(Idea, :count) == 0
  end

  test "a project-level social.use deny blocks creation and replay", %{world: w} do
    snapshot = Trends.latest("hn_top").current.id

    assert {:ok, idea} =
             Trends.turn_into_idea(w.org_id, w.profile.id, "hn_top", "7", w.approver.id, snapshot)

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, w.approver.id},
               permission: "social.use",
               resource: {:project, w.project.id}
             })

    assert {:error, :no_social_access} =
             Trends.turn_into_idea(w.org_id, w.profile.id, "hn_top", "7", w.approver.id, snapshot)

    assert Repo.get!(Idea, idea.id)
    assert Repo.aggregate(Idea, :count) == 1
  end

  test "a long article title still creates an idea and keeps its full title in context", %{
    world: w
  } do
    title = String.duplicate("x", 240)

    assert {:ok, _} =
             Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 1,
               complete: true,
               reporting_date: ~D[2026-11-13],
               observed_at: ~U[2026-11-15 12:00:00Z],
               items: [
                 %{
                   id: title,
                   rank: 1,
                   title: title,
                   url: "https://en.wikipedia.org/wiki/Example",
                   pageviews: 10
                 }
               ]
             })

    snapshot = Trends.latest("wikimedia_pageviews").current.id

    assert {:ok, idea} =
             Trends.turn_into_idea(
               w.org_id,
               w.profile.id,
               "wikimedia_pageviews",
               title,
               w.approver.id,
               snapshot
             )

    assert String.length(idea.title) <= 200
    assert idea.brief =~ title
    assert idea.brief =~ "10 pageviews"
  end
end
