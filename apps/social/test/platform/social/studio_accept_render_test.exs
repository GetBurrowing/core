defmodule Platform.Social.StudioAcceptRenderTest do
  @moduledoc """
  Social Studio slice B: `Studio.accept_render/4`, creative acceptance of a
  Studio clip render into Studio posts (idempotency and the
  `duplicate_destination` cases). The key is the immutable pair
  (render, accepted_account_id); it is not `state_rev` checked.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social
  alias Platform.Social.{Clip, Post, Studio}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    w = studio_world!()
    clip = w |> pending_clip!() |> make_studio_clip!()

    {:ok, third} =
      Social.create_account(w.org_id, w.profile, %{platform: "linkedin", handle: "@third"})

    %{w: w, clip: clip, render_id: render_id!(clip), third: third}
  end

  defp accept(w, clip, render_id, accounts, user \\ nil),
    do:
      Studio.accept_render(w.org_id, clip.id, (user || w.approver).id, %{
        render_id: render_id,
        account_ids: Enum.map(accounts, & &1.id)
      })

  defp post_count, do: Repo.aggregate(Post, :count)

  describe "creation" do
    test "one needs_approval studio post per account, nothing approved, planned or timed",
         %{w: w, clip: clip, render_id: rid} do
      assert {:ok, %{clip: %Clip{id: cid}, posts: [p1, p2]}} =
               accept(w, clip, rid, [w.x, w.tiktok])

      assert cid == clip.id
      # ascending by account id, whatever order the caller named them in
      assert [p1.account_id, p2.account_id] == Enum.sort([w.x.id, w.tiktok.id])

      for p <- [p1, p2] do
        assert {p.flow, p.status, p.version, p.state_rev} == {"studio", "needs_approval", 1, 0}
        assert {p.clip_id, p.clip_render_id} == {clip.id, rid}
        assert p.accepted_account_id == p.account_id
        assert {p.publish_after, p.scheduled_at, p.approved_by_user_id} == {nil, nil, nil}
        assert p.media_file_ids == [clip.render_file_id]
        assert actions(p) == ~w(created submitted)
        assert receipts(p) == []
      end

      assert send_calls() == []
      assert Fake.calls() == []
    end

    test "the clip's own review state is not touched", %{w: w, clip: clip, render_id: rid} do
      {:ok, _} = accept(w, clip, rid, [w.x])
      row = Repo.get!(Clip, clip.id)

      assert {row.review_status, row.reviewed_render_id, row.flow} ==
               {clip.review_status, clip.reviewed_render_id, "studio"}
    end
  end

  describe "idempotent and the immutable key" do
    test "a repeat returns the same posts and writes no row or event",
         %{w: w, clip: clip, render_id: rid} do
      {:ok, %{posts: first}} = accept(w, clip, rid, [w.x, w.tiktok])
      before = write_counts()

      assert {:ok, %{posts: again}} = accept(w, clip, rid, [w.x, w.tiktok])
      assert Enum.map(again, & &1.id) == Enum.map(first, & &1.id)
      assert write_counts() == before
    end

    test "a partial overlap creates only the missing post and its events",
         %{w: w, clip: clip, render_id: rid} do
      {:ok, %{posts: [first]}} = accept(w, clip, rid, [w.x])
      assert {:ok, %{posts: posts}} = accept(w, clip, rid, [w.x, w.tiktok])
      assert [same] = Enum.filter(posts, &(&1.account_id == w.x.id))
      assert [new] = Enum.filter(posts, &(&1.account_id == w.tiktok.id))
      assert same.id == first.id
      assert actions(first) == ~w(created submitted)
      assert actions(new) == ~w(created submitted)
      assert post_count() == 2
    end

    test "replay for A after A was retargeted to B returns the existing post, creates nothing",
         %{w: w, clip: clip, render_id: rid, third: third} do
      {:ok, %{posts: [post]}} = accept(w, clip, rid, [w.x])

      {:ok, %{post: moved}} =
        Studio.save_version(
          w.org_id,
          post.id,
          {:human, w.approver.id},
          %{account_id: third.id},
          expect(post)
        )

      before = write_counts()
      assert {:ok, %{posts: [replayed]}} = accept(w, clip, rid, [w.x])
      assert replayed.id == post.id
      assert replayed.account_id == third.id
      assert replayed.version == moved.version
      assert write_counts() == before
    end

    test "accepting for B while a retargeted post already targets B is :duplicate_destination",
         %{w: w, clip: clip, render_id: rid, third: third} do
      {:ok, %{posts: [post]}} = accept(w, clip, rid, [w.x])

      {:ok, _} =
        Studio.save_version(
          w.org_id,
          post.id,
          {:human, w.approver.id},
          %{account_id: third.id},
          expect(post)
        )

      before = write_counts()

      # tiktok is fresh, third is taken: nothing at all is created, tiktok included
      assert {:error, {:destinations, [%{account_id: id, reason: :duplicate_destination}]}} =
               accept(w, clip, rid, [w.tiktok, third])

      assert id == third.id
      assert write_counts() == before
    end

    test "retargeting onto an account that already holds a post is :duplicate_destination",
         %{w: w, clip: clip, render_id: rid} do
      {:ok, %{posts: posts}} = accept(w, clip, rid, [w.x, w.tiktok])
      a = Enum.find(posts, &(&1.account_id == w.x.id))
      before = write_counts()

      assert {:error, :duplicate_destination} =
               Studio.save_version(
                 w.org_id,
                 a.id,
                 {:human, w.approver.id},
                 %{account_id: w.tiktok.id},
                 expect(a)
               )

      assert write_counts() == before
      assert fresh(a) == a
    end
  end

  describe "refusals (check order, nothing created)" do
    test "a legacy clip", %{w: w} do
      legacy = pending_clip!(w)
      before = write_counts()
      assert {:error, :legacy_clip} = accept(w, legacy, render_id!(legacy), [w.x])
      assert write_counts() == before
    end

    test "wrong org, disabled, unknown clip", %{w: w, clip: clip, render_id: rid} do
      assert {:error, :not_found} =
               Studio.accept_render(w.other_org_id, clip.id, w.approver.id, %{
                 render_id: rid,
                 account_ids: [w.x.id]
               })

      assert {:error, :not_found} =
               Studio.accept_render(w.org_id, Ecto.UUID.generate(), w.approver.id, %{
                 render_id: rid,
                 account_ids: [w.x.id]
               })

      {:ok, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      assert {:error, :studio_disabled} = accept(w, clip, rid, [w.x])
      assert post_count() == 0
    end

    test "an archived destination refuses the whole call", %{w: w, clip: clip, render_id: rid} do
      {:ok, _} = Social.archive_account(w.org_id, w.tiktok)

      assert {:error, {:destinations, [%{account_id: id, reason: :account_archived}]}} =
               accept(w, clip, rid, [w.x, w.tiktok])

      assert id == w.tiktok.id
      assert post_count() == 0
    end

    test "the actor must pass (a) for EACH account, else nothing is created", %{
      w: w,
      clip: clip,
      render_id: rid
    } do
      owner = user!() |> member!(w.org_id)
      {:ok, _} = Social.set_account_owner(w.org_id, w.tiktok, owner.id)
      stranger = user!() |> member!(w.org_id)

      assert {:error, {:destinations, [%{account_id: tid, reason: :not_the_owner}]}} =
               accept(w, clip, rid, [w.x, w.tiktok])

      assert tid == w.tiktok.id

      assert {:error, {:destinations, [%{account_id: xid, reason: :not_an_approver}]}} =
               accept(w, clip, rid, [w.x], stranger)

      assert xid == w.x.id

      assert {:error, {:destinations, [%{account_id: _, reason: :not_a_human}]}} =
               Studio.accept_render(w.org_id, clip.id, w.agent.id, %{
                 render_id: rid,
                 account_ids: [w.x.id]
               })

      assert {:error, {:destinations, [%{reason: reason}]}} =
               accept(w, clip, rid, [w.x], w.outsider)

      assert reason in ~w(not_an_approver approver_no_access)a
      assert post_count() == 0
    end

    test "social.use denied on the project", %{w: w, clip: clip, render_id: rid} do
      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, w.approver.id},
          permission: "social.use",
          resource: {:project, w.project.id}
        })

      assert {:error, {:destinations, [%{reason: :no_social_access}]}} =
               accept(w, clip, rid, [w.x])

      assert post_count() == 0
    end

    test "bad input: no accounts, foreign-profile or unknown account, bad or foreign render",
         %{w: w, clip: clip, render_id: rid} do
      assert {:error, :no_accounts} = accept(w, clip, rid, [])
      ghost = Ecto.UUID.generate()

      assert {:error, {:destinations, [%{account_id: ^ghost, reason: :not_found}]}} =
               accept(w, clip, rid, [%{id: ghost}])

      assert {:error, :render_not_found} = accept(w, clip, Ecto.UUID.generate(), [w.x])
      assert {:error, :render_not_found} = accept(w, clip, "nonsense", [w.x])

      other = w |> pending_clip!() |> make_studio_clip!()
      assert {:error, :render_not_found} = accept(w, clip, render_id!(other), [w.x])

      {:ok, other_profile} =
        Social.create_profile(w.org_id, %{
          name: "Elsewhere #{unique()}",
          project_id: w.project.id,
          home_url: "https://www.youtube.com/@e",
          approver_user_ids: [w.approver.id]
        })

      {:ok, foreign} =
        Social.create_account(w.org_id, other_profile, %{platform: "x", handle: "@e"})

      fid = foreign.id

      # An id that exists under another profile and an id that exists
      # nowhere get the same reason and the same response, so the caller cannot
      # learn that the id exists elsewhere.
      assert {:error, {:destinations, [%{account_id: ^fid, reason: :not_found}]}} =
               foreign_result = accept(w, clip, rid, [foreign])

      unknown_id = Ecto.UUID.generate()

      assert {:error, {:destinations, [%{account_id: ^unknown_id, reason: :not_found}]}} =
               unknown_result = accept(w, clip, rid, [%{id: unknown_id}])

      assert {:error, {:destinations, [%{} = f]}} = foreign_result
      assert {:error, {:destinations, [%{} = u]}} = unknown_result
      assert Map.delete(f, :account_id) == Map.delete(u, :account_id)

      refute inspect(foreign_result) =~ "mismatch"
      assert post_count() == 0
    end

    test "a failing created event rolls back every post", %{w: w, clip: clip, render_id: rid} do
      fail_event!("submitted")
      assert_raise Ecto.ConstraintError, fn -> accept(w, clip, rid, [w.x, w.tiktok]) end
      assert post_count() == 0
      assert Repo.aggregate(Platform.Social.PostEvent, :count) == 0
    end
  end
end
