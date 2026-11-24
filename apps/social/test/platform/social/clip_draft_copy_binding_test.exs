defmodule Platform.Social.ClipDraftCopyBindingTest do
  @moduledoc """
  Create drafts is bound to the copy the reviewer saw: `ClipDecisions.draft_clip/5`
  takes `attrs["copy_rev"]` (`ClipReviewFeed.copy_rev/1` of the clip as rendered)
  and, under the clip lock, refuses `{:error, :stale_copy}` when the copy has
  changed since, creating no posts and changing nothing.

  The token is mandatory at the context boundary: a call that omits the key,
  or sends nil, blank or a stale value, is refused and writes nothing.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social.{AgentDrafts, Clip, ClipDecisions, ClipReviewFeed, Post}

  setup do
    w = render_world!()
    file = stored_file!(w.project, "clip bytes #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => "Seen title",
          "caption" => "Seen caption",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    w = %{
      w
      | profile:
          w.profile |> Ecto.Changeset.change(drafting_agent_id: w.agent.id) |> Repo.update!()
    }

    %{w: w, clip: clip}
  end

  defp seen(clip), do: ClipReviewFeed.copy_rev(Repo.get!(Clip, clip.id))

  defp draft(w, clip, extra) do
    ClipDecisions.draft_clip(
      w.org_id,
      clip.id,
      w.approver.id,
      Map.merge(
        %{"render_id" => render_id!(clip), "account_ids" => [w.tiktok.id]},
        extra
      )
    )
  end

  defp posts(clip), do: Repo.all(from(p in Post, where: p.clip_id == ^clip.id))

  defp tool_edit(w, clip, args) do
    ToolArguments.dispatch(
      "social_clip_update_copy",
      Map.merge(
        %{
          "clip_id" => clip.id,
          "expected_copy_rev" => ClipReviewFeed.copy_rev(Repo.get!(Clip, clip.id))
        },
        args
      ),
      %{agent_id: w.agent.id}
    )
  end

  defp assert_refused_and_untouched(w, clip, extra) do
    before = Repo.get!(Clip, clip.id)
    Phoenix.PubSub.subscribe(Platform.PubSub, Platform.Social.clips_topic(w.profile.id))

    assert {:error, :stale_copy} = draft(w, clip, extra)

    assert posts(clip) == []
    assert Repo.get!(Clip, clip.id) == before
    assert before.review_status == "pending"
    refute_receive {:social_clip, _}, 50
  end

  test "a fresh token creates the drafts", %{w: w, clip: clip} do
    assert {:ok, %{posts: [post]}} = draft(w, clip, %{"copy_rev" => seen(clip)})
    assert post.body == "Seen caption"
  end

  test "a token from before a tool edit is refused: 0 posts, copy and review unchanged", %{
    w: w,
    clip: clip
  } do
    old = seen(clip)
    assert {:ok, _} = tool_edit(w, clip, %{"caption" => "Agent rewrote it"})
    assert_refused_and_untouched(w, clip, %{"copy_rev" => old})
    assert Repo.get!(Clip, clip.id).caption == "Agent rewrote it"
  end

  test "a token from before a details-rail save is refused", %{w: w, clip: clip} do
    old = seen(clip)

    {:ok, _} =
      ClipReviewFeed.save_details(w.org_id, w.profile.id, clip.id, w.approver.id, %{
        "title" => "Rail title"
      })

    assert_refused_and_untouched(w, clip, %{"copy_rev" => old})
  end

  test "the same click with the fresh token then succeeds with the new copy", %{w: w, clip: clip} do
    old = seen(clip)
    assert {:ok, _} = tool_edit(w, clip, %{"caption" => "Agent rewrote it"})
    assert {:error, :stale_copy} = draft(w, clip, %{"copy_rev" => old})

    assert {:ok, %{posts: [post]}} = draft(w, clip, %{"copy_rev" => seen(clip)})
    assert post.body == "Agent rewrote it"
  end

  test "a present nil, blank or wrong token is refused, not treated as absent", %{
    w: w,
    clip: clip
  } do
    for bad <- [nil, "", "not-a-rev", 5] do
      assert {:error, :stale_copy} = draft(w, clip, %{"copy_rev" => bad})
    end

    assert posts(clip) == []
    assert Repo.get!(Clip, clip.id).review_status == "pending"
  end

  test "the human's own edit in the same click is judged against what they saw", %{
    w: w,
    clip: clip
  } do
    assert {:ok, %{posts: [post]}} =
             draft(w, clip, %{"copy_rev" => seen(clip), "caption" => "Typed at click"})

    assert post.body == "Typed at click"
  end

  test "a call that omits the key, or sends nil, blank or a stale value, writes nothing", %{
    w: w,
    clip: clip
  } do
    absent = %{
      "render_id" => render_id!(clip),
      "account_ids" => [w.tiktok.id]
    }

    assert {:error, :stale_copy} =
             ClipDecisions.draft_clip(w.org_id, clip.id, w.approver.id, absent)

    old = seen(clip)

    {:ok, _} =
      Platform.Federation.ToolArguments.dispatch(
        "social_clip_update_copy",
        %{"clip_id" => clip.id, "expected_copy_rev" => old, "caption" => "Moved on"},
        %{agent_id: w.agent.id}
      )

    assert {:error, :stale_copy} = draft(w, clip, %{"copy_rev" => old})
    assert posts(clip) == []
    assert Repo.get!(Clip, clip.id).review_status == "pending"
  end

  test "the token fingerprints the copy value: A to B and back to A is the same token", %{
    clip: clip
  } do
    a = seen(clip)
    b = ClipReviewFeed.copy_rev(%{clip | caption: "B"})
    refute a == b
    assert a == ClipReviewFeed.copy_rev(%{clip | caption: clip.caption})
  end
end
