defmodule Platform.Social.ClipReviewFeedTest do
  @moduledoc """
  Clip Studio 3/9 (task 01a16662-8c00) stage 1: the Review bay's read model
  and its one write, `save_details/5`.
  """
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, ClipJobs, ClipReviewFeed}

  setup do
    w = render_world!()
    %{w: w}
  end

  # An externally rendered clip on `profile`, review pending.
  defp pending_clip!(w, profile \\ nil, attrs \\ %{}) do
    profile = profile || w.profile
    file = stored_file!(w.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        profile.id,
        Map.merge(%{"file_id" => file.id, "title" => "Clip #{unique()}"}, attrs),
        w.agent.id
      )

    clip
  end

  # A decided clip, written as the DB's review CHECKs require.
  defp decide!(clip, w, status) do
    clip
    |> Ecto.Changeset.change(
      review_status: status,
      reviewed_by_user_id: w.approver.id,
      reviewed_at: DateTime.utc_now(),
      review_note: if(status == "rejected", do: "not this one")
    )
    |> Repo.update!()
  end

  defp set_inserted_at(clip, at) do
    clip |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end

  describe "review_queue/2" do
    test "review_queue returns only pending rendered clips of this profile, oldest first",
         %{w: w} do
      t0 = ~U[2026-10-01 10:00:00.000000Z]
      newer = w |> pending_clip!() |> set_inserted_at(DateTime.add(t0, 60))
      older = w |> pending_clip!() |> set_inserted_at(t0)

      # Approved, rejected, never rendered, and a pending clip with no file.
      approved = pending_clip!(w)
      decide!(approved, w, "approved")
      rejected = pending_clip!(w)
      decide!(rejected, w, "rejected")
      _candidate = file_clip!(w, 0.0, 10.0)
      no_file = pending_clip!(w)
      Repo.update!(Ecto.Changeset.change(no_file, render_file_id: nil))

      # Another profile in the same org, and another org entirely.
      {:ok, other_profile} =
        Social.create_profile(w.org_id, %{
          name: "Other #{unique()}",
          project_id: w.project.id,
          space_id: channel!(w.org_id).id
        })

      _other_profile_clip = pending_clip!(w, other_profile)
      other = render_world!()
      _other_org_clip = pending_clip!(other)

      assert Enum.map(ClipReviewFeed.review_queue(w.org_id, w.profile.id), & &1.id) ==
               [older.id, newer.id]

      assert ClipReviewFeed.pending_count(w.org_id, w.profile.id) == 2
      assert ClipReviewFeed.review_queue(other.org_id, w.profile.id) == []
      assert ClipReviewFeed.pending_count(other.org_id, w.profile.id) == 0
    end
  end

  describe "fetch_clip/3" do
    test "fetch_clip refuses another org, another profile and a random UUID identically",
         %{w: w} do
      own = pending_clip!(w)
      assert {:ok, %Clip{id: id}} = ClipReviewFeed.fetch_clip(w.org_id, w.profile.id, own.id)
      assert id == own.id

      {:ok, sibling} =
        Social.create_profile(w.org_id, %{
          name: "Sibling #{unique()}",
          project_id: w.project.id,
          space_id: channel!(w.org_id).id
        })

      sibling_clip = pending_clip!(w, sibling)
      other = render_world!()
      foreign = pending_clip!(other)

      refusals =
        for id <- [foreign.id, sibling_clip.id, Ecto.UUID.generate(), "not-a-uuid"],
            do: ClipReviewFeed.fetch_clip(w.org_id, w.profile.id, id)

      assert refusals == List.duplicate({:error, :not_found}, 4)
    end
  end

  describe "rendering/2" do
    test "lists open new_clip and rerender jobs oldest first with clip or payload titles",
         %{w: w} do
      {:ok, %{job: job}} =
        ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
          "source_file_id" => w.video.id,
          "transcript_file_id" => w.transcript.id,
          "in_s" => 1.0,
          "out_s" => 9.0,
          "title" => "Working title"
        })

      assert [row] = ClipReviewFeed.rendering(w.org_id, w.profile.id)
      assert row.id == job.id
      assert row.title == "Working title"
      assert row.kind == "new_clip"
      assert ClipReviewFeed.rendering(render_world!().org_id, w.profile.id) == []
    end
  end

  describe "byline/2" do
    test "names the submitting agent of this org and the source label", %{w: w} do
      clip = pending_clip!(w, nil, %{"source_label" => "htc-clip-tool"})

      assert ClipReviewFeed.byline(w.org_id, clip) == %{
               source_label: "htc-clip-tool",
               agent_name: w.agent.name
             }

      assert ClipReviewFeed.byline(render_world!().org_id, clip).agent_name == nil
    end
  end

  describe "save_details/5" do
    test "saves title, caption and platforms for an approver and broadcasts", %{w: w} do
      clip = pending_clip!(w)
      Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(w.profile.id))

      assert {:ok, saved} =
               ClipReviewFeed.save_details(w.org_id, w.profile.id, clip.id, w.approver.id, %{
                 "title" => "  New title  ",
                 "caption" => "New caption",
                 "platforms" => ["tiktok"]
               })

      assert {saved.title, saved.caption, saved.platforms} ==
               {"New title", "New caption", ["tiktok"]}

      assert_receive {:social_clip, %Clip{id: id}}
      assert id == clip.id
    end

    test "save_details refuses a non-approver and writes nothing", %{w: w} do
      clip = pending_clip!(w)
      stranger = member!(user!(), w.org_id)

      for user_id <- [stranger.id, w.outsider.id, w.agent.id] do
        assert {:error, reason} =
                 ClipReviewFeed.save_details(w.org_id, w.profile.id, clip.id, user_id, %{
                   "title" => "Hijacked"
                 })

        assert reason in [:not_an_approver, :not_a_human, :approver_no_access]
      end

      assert Repo.get!(Clip, clip.id).title == clip.title
    end

    test "save_details ignores review_status in attrs", %{w: w} do
      clip = pending_clip!(w)

      assert {:ok, saved} =
               ClipReviewFeed.save_details(w.org_id, w.profile.id, clip.id, w.approver.id, %{
                 "title" => "Still pending",
                 "review_status" => "approved",
                 "reviewed_by_user_id" => w.approver.id,
                 "review_note" => "sneaky"
               })

      reloaded = Repo.get!(Clip, saved.id)
      assert reloaded.title == "Still pending"

      assert {reloaded.review_status, reloaded.reviewed_by_user_id, reloaded.review_note} ==
               {"pending", nil, nil}
    end

    test "save_details refuses a platform the profile has no account for", %{w: w} do
      clip = pending_clip!(w)

      assert {:error, {:invalid_platforms, ["instagram"]}} =
               ClipReviewFeed.save_details(w.org_id, w.profile.id, clip.id, w.approver.id, %{
                 "title" => "Changed",
                 "platforms" => ["tiktok", "instagram"]
               })

      reloaded = Repo.get!(Clip, clip.id)
      assert {reloaded.title, reloaded.platforms} == {clip.title, clip.platforms}
    end

    test "refuses a blank or over-long title, a long caption and a decided clip", %{w: w} do
      clip = pending_clip!(w)
      save = &ClipReviewFeed.save_details(w.org_id, w.profile.id, clip.id, w.approver.id, &1)

      assert {:error, %Ecto.Changeset{}} = save.(%{"title" => "   "})
      assert {:error, %Ecto.Changeset{}} = save.(%{"title" => String.duplicate("t", 201)})
      assert {:error, %Ecto.Changeset{}} = save.(%{"caption" => String.duplicate("c", 2201)})

      decide!(clip, w, "rejected")
      assert {:error, :not_pending} = save.(%{"title" => "Too late"})
      assert Repo.get!(Clip, clip.id).title == clip.title
    end
  end
end
