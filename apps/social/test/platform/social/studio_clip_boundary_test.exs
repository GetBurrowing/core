defmodule Platform.Social.StudioClipBoundaryTest do
  @moduledoc """
  Social Studio slice A, the design owner's clip provenance rule: a clip
  carries its own durable `flow` marker (`legacy` | `studio`, DB CHECK), set
  only at insert by Studio intake and never inferred from the profile's
  `studio_enabled` toggle. Legacy `approve_clip/5` and its undo refuse Studio
  clips, and so does any path that would turn a Studio clip into a legacy post.

  Async false: the Fake's call log is global.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social
  alias Platform.Social.{Clip, ClipPublish, Post}
  alias Platform.Social.Publisher.Fake

  @publisher :studio_clip_boundary_publish

  setup do
    Fake.reset()
    w = studio_world!()
    start_supervised!({ClipPublish, name: @publisher, interval_ms: :infinity, boot_sweep: false})
    %{w: w, t0: DateTime.utc_now()}
  end

  defp approve(w, clip, now, accounts \\ nil) do
    Social.approve_clip(
      w.org_id,
      clip.id,
      w.approver.id,
      %{"render_id" => render_id!(clip), "account_ids" => accounts || [w.tiktok.id]},
      now: now,
      publish_server: @publisher
    )
  end

  defp clip_posts(clip_id), do: Repo.all(from(p in Post, where: p.clip_id == ^clip_id))

  describe "the clip marker" do
    test "defaults to legacy and is not castable", %{w: w} do
      clip = pending_clip!(w)
      assert clip.flow == "legacy"

      assert {:ok, %Clip{flow: "legacy"}} =
               Social.update_clip(w.org_id, clip, %{title: "retitled", flow: "studio"})
    end

    test "the DB refuses any other value", %{w: w} do
      clip = pending_clip!(w)

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.update_all(from(c in Clip, where: c.id == ^clip.id), set: [flow: "other"])
          end)
        end

      assert error.postgres.constraint == "social_clips_flow_check"
    end

    test "provenance is the clip's marker, not the profile toggle", %{w: w, t0: t0} do
      legacy_clip = pending_clip!(w)
      {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, true)
      # Toggle ON does not turn a legacy clip into a Studio one: it still approves.
      assert {:ok, %{posts: [post]}} = approve(w, legacy_clip, t0)
      assert post.flow == "legacy"

      studio_clip = w |> pending_clip!() |> make_studio_clip!()
      {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      # Toggle OFF does not turn a Studio clip back into a legacy one either.
      assert {:error, :studio_clip} = approve(w, studio_clip, t0)
    end
  end

  describe "ClipDecisions.approve_clip/5" do
    test "refuses a Studio clip: no post, no review change, no timer, no publisher call", %{
      w: w,
      t0: t0
    } do
      clip = w |> pending_clip!() |> make_studio_clip!()
      posts_before = Repo.aggregate(Post, :count)

      assert {:error, :studio_clip} = approve(w, clip, t0, [w.tiktok.id, w.x.id])

      assert Repo.aggregate(Post, :count) == posts_before
      row = Repo.get!(Clip, clip.id)

      assert {row.review_status, row.reviewed_by_user_id, row.reviewed_at} ==
               {"pending", nil, nil}

      assert ClipPublish.sweep_now(@publisher, DateTime.add(t0, 60_000, :millisecond)) == []
      assert Fake.calls() == []
    end

    test "still approves a legacy clip (control)", %{w: w, t0: t0} do
      clip = pending_clip!(w)
      assert {:ok, %{posts: [%Post{flow: "legacy", status: "approved"}]}} = approve(w, clip, t0)
    end
  end

  describe "ClipDecisions.undo_clip_decision/4" do
    test "refuses a Studio clip, with and without render_id, leaving its posts", %{w: w, t0: t0} do
      clip = pending_clip!(w)
      {:ok, _} = approve(w, clip, t0)
      render = render_id!(clip)
      clip = make_studio_clip!(clip)
      before = clip_posts(clip.id)

      assert {:error, :studio_clip} =
               Social.undo_clip_decision(w.org_id, clip.id, w.approver.id, now: t0)

      assert {:error, :studio_clip} =
               Social.undo_clip_decision(w.org_id, clip.id, w.approver.id,
                 now: t0,
                 render_id: render
               )

      assert clip_posts(clip.id) == before
      assert Repo.get!(Clip, clip.id).review_status == "approved"
    end

    test "refuses to delete a Studio post attached to a legacy clip", %{w: w, t0: t0} do
      clip = pending_clip!(w)
      {:ok, %{posts: [legacy_post]}} = approve(w, clip, t0)
      render = render_id!(clip)

      studio_post =
        w
        |> studio_post!(w.x, "needs_approval")
        |> force!(clip_id: clip.id, clip_render_id: legacy_post.clip_render_id)

      assert {:error, :studio_post} =
               Social.undo_clip_decision(w.org_id, clip.id, w.approver.id,
                 now: t0,
                 render_id: render
               )

      assert Repo.get(Post, studio_post.id)
      assert Repo.get(Post, legacy_post.id)
    end

    test "the no-render_id undo path also refuses a Studio post on the clip", %{w: w, t0: t0} do
      clip = pending_clip!(w)
      {:ok, %{posts: [legacy_post]}} = approve(w, clip, t0)

      studio_post =
        w
        |> studio_post!(w.x, "needs_approval")
        |> force!(clip_id: clip.id, clip_render_id: legacy_post.clip_render_id)

      assert {:error, :studio_post} =
               Social.undo_clip_decision(w.org_id, clip.id, w.approver.id, now: t0)

      assert Repo.get(Post, studio_post.id)
      assert Repo.get(Post, legacy_post.id)
      assert Repo.get!(Clip, clip.id).review_status == "approved"
    end

    test "still undoes a legacy approval (control)", %{w: w, t0: t0} do
      clip = pending_clip!(w)
      {:ok, _} = approve(w, clip, t0)

      assert {:ok, %Clip{review_status: "pending"}} =
               Social.undo_clip_decision(w.org_id, clip.id, w.approver.id, now: t0)

      assert clip_posts(clip.id) == []
    end
  end

  describe "ClipDecisions.reject_clip/5" do
    test "refuses a Studio clip and writes nothing (not even the review fields)", %{w: w, t0: t0} do
      clip = w |> pending_clip!() |> make_studio_clip!()
      before = Repo.get!(Clip, clip.id)

      assert {:error, :studio_clip} =
               Social.reject_clip(w.org_id, clip.id, w.approver.id, "not for us", now: t0)

      assert Repo.get!(Clip, clip.id) == before

      assert {before.review_status, before.reviewed_by_user_id, before.reviewed_at,
              before.review_note} == {"pending", nil, nil, nil}

      assert Fake.calls() == []
    end

    test "still rejects a legacy clip (control)", %{w: w, t0: t0} do
      clip = pending_clip!(w)

      assert {:ok, %Clip{review_status: "rejected", review_note: "not for us"}} =
               Social.reject_clip(w.org_id, clip.id, w.approver.id, "not for us", now: t0)
    end
  end
end
