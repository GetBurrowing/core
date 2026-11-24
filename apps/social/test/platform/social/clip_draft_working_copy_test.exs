defmodule Platform.Social.ClipDraftWorkingCopyTest do
  @moduledoc """
  Create drafts (`ClipDecisions.draft_clip/5`) takes the title and caption from
  the LOCKED clip's current working copy (what `social_clip_update_copy` or
  the details rail edited) and the media from the explicitly chosen version.
  Posts already written and every version snapshot are never rewritten.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, ClipDecisions, ClipRender, ClipVersions, Post}

  setup do
    w = render_world!()
    file = stored_file!(w.project, "clip bytes #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => "H1",
          "caption" => "C1",
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

    {:ok, yt} = Social.create_account(w.org_id, w.profile, %{platform: "youtube"})
    %{w: w, clip: clip, yt: yt, ctx: %{agent_id: w.agent.id}}
  end

  defp edit(ctx, clip, args) do
    args =
      Map.merge(
        %{
          "clip_id" => clip.id,
          "expected_copy_rev" => Platform.Social.ClipReviewFeed.copy_rev(Repo.get!(Clip, clip.id))
        },
        args
      )

    ToolArguments.dispatch("social_clip_update_copy", args, ctx)
  end

  defp draft(w, clip, render_id, accounts, extra \\ %{}) do
    ClipDecisions.draft_clip(
      w.org_id,
      clip.id,
      w.approver.id,
      Map.merge(
        %{
          "render_id" => render_id,
          "account_ids" => accounts,
          "copy_rev" => clip_copy_rev!(clip)
        },
        extra
      )
    )
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

  defp row(%Post{id: id}), do: Repo.get!(Post, id) |> Map.from_struct() |> Map.delete(:__meta__)

  defp versions(clip_id),
    do: Repo.all(from(r in ClipRender, where: r.clip_id == ^clip_id, order_by: r.rev))

  # A new render is the supported way a decided clip goes back to pending
  # (`ClipVersions.append!/4` resets the review, as the render job and intake
  # do). `undo_clip_decision` does not apply: it refuses a drafted clip
  # (drafts have no undo window), see the first test.
  defp reopen_with_new_render!(w, clip) do
    file2 = stored_file!(w.project, "clip bytes v2 #{unique()}", "clip2.mp4", "video/mp4")

    {:ok, _} =
      Repo.transaction(fn ->
        ClipVersions.append!(clip.id, file2, %{}, %{
          headline: "H1-v2-burned",
          caption: "C1-v2-burned",
          source: %{"origin" => "external"},
          provenance: %{"kind" => "test"},
          completion_key: "test:" <> Ecto.UUID.generate()
        })
      end)

    Repo.get!(Clip, clip.id)
  end

  test "undo does not reopen a drafted clip (so a new render is the lifecycle path used)", c do
    v1 = render_id!(c.clip)
    assert {:ok, _} = draft(c.w, c.clip, v1, [c.w.tiktok.id])

    assert {:error, :window_closed} =
             ClipDecisions.undo_clip_decision(c.w.org_id, c.clip.id, c.w.approver.id)
  end

  test "a later draft takes the edited copy with the chosen version's media; old posts and versions stay",
       c do
    v1 = render_id!(c.clip)
    v1_row = Repo.get!(ClipRender, v1)
    v1_file = v1_row.file_id

    assert {:ok, %{posts: [p1]}} = draft(c.w, c.clip, v1, [c.yt.id])
    assert p1.body == "C1"
    assert p1.platform_options == %{"title" => "H1"}

    reopened = reopen_with_new_render!(c.w, c.clip)
    assert reopened.review_status == "pending"
    assert reopened.render_file_id != v1_file

    assert {:ok, %{clip: %{title: "H2", caption: "C2"}}} =
             edit(c.ctx, c.clip, %{"title" => "H2", "caption" => "C2"})

    {:ok, yt2} = Social.create_account(c.w.org_id, c.w.profile, %{platform: "youtube"})
    p1_before = row(p1)
    versions_before = versions(c.clip.id)

    assert {:ok, %{posts: [p2]}} = draft(c.w, c.clip, v1, [yt2.id])
    p2 = Repo.get!(Post, p2.id)

    assert p2.body == "C2"
    assert p2.platform_options == %{"title" => "H2"}
    assert p2.media_file_ids == [v1_file]
    assert p2.clip_render_id == v1

    assert row(p1) == p1_before
    assert versions(c.clip.id) == versions_before
    v1_after = Repo.get!(ClipRender, v1)
    assert {v1_after.headline, v1_after.caption} == {"H1", "C1"}
    assert v1_after == v1_row
  end

  for {label, value} <- [{"nil", nil}, {"empty string", ""}] do
    test "a cleared caption (#{label}) is never replaced by the version's snapshot caption", c do
      v1 = render_id!(c.clip)
      assert {:ok, _} = edit(c.ctx, c.clip, %{"caption" => unquote(value)})
      assert Repo.get!(Clip, c.clip.id).caption == unquote(value)

      assert {:ok, %{posts: [post]}} = draft(c.w, c.clip, v1, [c.w.tiktok.id])
      body = Repo.get!(Post, post.id).body
      refute body == "C1"
      # The Post changeset casts "" to nil, so both clears store a nil body.
      assert body == nil
      assert Repo.get!(ClipRender, v1).caption == "C1"
    end
  end

  test "an explicit attrs caption wins over the working copy", c do
    v1 = render_id!(c.clip)
    {:ok, _} = edit(c.ctx, c.clip, %{"caption" => "working"})

    assert {:ok, %{posts: [post]}} =
             draft(c.w, c.clip, v1, [c.w.tiktok.id], %{"caption" => "explicit"})

    assert Repo.get!(Post, post.id).body == "explicit"
    assert Repo.get!(Clip, c.clip.id).caption == "explicit"
  end

  test "an explicit nil attrs caption gives nil, not the working copy or the snapshot", c do
    v1 = render_id!(c.clip)
    {:ok, _} = edit(c.ctx, c.clip, %{"caption" => "working"})

    assert {:ok, %{posts: [post]}} =
             draft(c.w, c.clip, v1, [c.w.tiktok.id], %{"caption" => nil})

    assert Repo.get!(Post, post.id).body == nil
  end

  test "an explicit attrs title wins over the working title", c do
    v1 = render_id!(c.clip)
    {:ok, _} = edit(c.ctx, c.clip, %{"title" => "working"})

    assert {:ok, %{posts: [post]}} =
             draft(c.w, c.clip, v1, [c.yt.id], %{"title" => "explicit"})

    assert Repo.get!(Post, post.id).platform_options == %{"title" => "explicit"}
  end

  describe "a clip with no working title" do
    alias Platform.Social.{ClipReviewFeed, PlatformLimits, PublishingCompleteness}

    test "a YouTube draft from it is missing its title, cannot be sent for review", c do
      Repo.update_all(from(cl in Clip, where: cl.id == ^c.clip.id), set: [title: nil])
      v1 = render_id!(c.clip)

      assert {:ok, %{posts: [p]}} =
               draft(c.w, c.clip, v1, [c.yt.id], %{
                 "copy_rev" => ClipReviewFeed.copy_rev(Repo.get!(Clip, c.clip.id))
               })

      p = Repo.get!(Post, p.id)
      refute Map.has_key?(p.platform_options || %{}, "title")
      account = Repo.get!(Platform.Social.Account, c.yt.id)

      # It is not treated as a complete post.
      assert {:error, {:incomplete_post, lines}} =
               PublishingCompleteness.check(%{p | scheduled_at: future()}, account)

      assert Enum.any?(lines, &(&1 =~ "video title"))

      assert Enum.any?(
               PlatformLimits.flags("youtube", %{
                 body: p.body,
                 title: (p.platform_options || %{})["title"]
               }),
               &(&1.key == "missing_title")
             )

      # And the existing refusal on sending for review stands, writing nothing.
      assert {:error, {:incomplete_post, lines}} =
               Social.edit_draft(c.w.org_id, p.id, c.w.approver.id, %{scheduled_at: future()},
                 submit: true
               )

      assert Enum.any?(lines, &(&1 =~ "video title"))
      assert Repo.get!(Post, p.id).status == "draft"
    end
  end
end
