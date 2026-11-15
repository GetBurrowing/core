defmodule Platform.Social.StudioSchemaTest do
  @moduledoc """
  Social Studio slice A: schema, enablement and context basics.

    * the CHECKs and the partial unique index, refused at the database
      (every refused write runs in its own savepoint);
    * `social_post_events` carrying `post_version` and `account_id`;
    * `Studio.create_post/4` and the check order (scoped load, then
      `studio_enabled`, then flow, then actor);
    * a Studio post with an approval row cannot be removed (in code and by FK);
    * a failing event write rolls the whole state change back.

  KNOWN LIMITATION (documented, not redesigned, no triggers):
  `social_posts.account_id` and the profile FK cascade, and so do events. A
  Studio post WITHOUT an approval row can still be removed by a direct SQL
  delete or an org-level cascade. The code refuses it on every path
  (`delete_post/2`, `delete_profile/2`, clip undo), and the `restrict` FK on
  `social_post_approvals` protects any post that has a receipt.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social

  alias Platform.Social.{
    ApprovalCard,
    Post,
    PostApproval,
    PostEvent,
    PostEvents,
    Profile
  }

  alias Platform.Social.{Studio}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    %{w: studio_world!()}
  end

  defp attempt(fun) do
    {:error, error} =
      Repo.transaction(fn ->
        try do
          fun.()
        rescue
          e -> Repo.rollback(e)
        end
      end)

    error
  end

  defp constraint_of(fun) do
    error = attempt(fun)
    assert %Postgrex.Error{} = error
    error.postgres.constraint
  end

  defp set!(post, fields),
    do: Repo.update_all(from(p in Post, where: p.id == ^post.id), set: fields)

  defp approval!(post, attrs \\ %{}) do
    PostApproval
    |> struct!()
    |> PostApproval.changeset(
      Map.merge(
        %{
          post_id: post.id,
          version: post.version,
          account_id: post.account_id,
          approved_by_user_id: post.approved_by_user_id,
          approved_at: DateTime.utc_now(),
          state: "current",
          content_fingerprint: "fp-#{unique()}"
        },
        attrs
      )
    )
    |> Repo.insert()
  end

  describe "posts: flow, version, plan columns" do
    test "the DATABASE defaults a row written without the new columns: legacy, off, legacy",
         %{w: w} do
      # insert_all with no flow/version/studio_enabled column: the struct
      # defaults are out of the picture, only the column defaults answer.
      now = DateTime.utc_now()
      id = fn -> Ecto.UUID.dump!(Ecto.UUID.generate()) end
      post_id = id.()
      profile_id = id.()
      clip_id = id.()

      Repo.insert_all("social_profiles", [
        %{
          id: profile_id,
          org_id: Ecto.UUID.dump!(w.org_id),
          name: "raw #{unique()}",
          inserted_at: now,
          updated_at: now
        }
      ])

      Repo.insert_all("social_posts", [
        %{
          id: post_id,
          account_id: Ecto.UUID.dump!(w.x.id),
          body: "raw",
          inserted_at: now,
          updated_at: now
        }
      ])

      Repo.insert_all("social_clips", [
        %{
          id: clip_id,
          profile_id: profile_id,
          source_url: "https://example.test/v",
          inserted_at: now,
          updated_at: now
        }
      ])

      one = fn sql, id -> Repo.query!(sql, [id]).rows |> hd() end

      assert one.(
               "SELECT flow, version, state_rev, accepted_account_id FROM social_posts WHERE id = $1",
               post_id
             ) ==
               ["legacy", 1, 0, nil]

      assert one.("SELECT studio_enabled FROM social_profiles WHERE id = $1", profile_id) == [
               false
             ]

      assert one.("SELECT flow FROM social_clips WHERE id = $1", clip_id) == ["legacy"]
    end

    test "defaults: legacy, version 1, state_rev 0, no accepted account", %{w: w} do
      {:ok, post} = Social.create_post(w.org_id, w.x, %{body: "legacy"})

      assert {post.flow, post.version, post.state_rev, post.accepted_account_id} ==
               {"legacy", 1, 0, nil}

      assert post.planned_by_user_id == nil and post.planned_set_at == nil
    end

    test "flow CHECK refuses any other value", %{w: w} do
      {:ok, post} = Social.create_post(w.org_id, w.x, %{body: "legacy"})
      assert constraint_of(fn -> set!(post, flow: "other") end) == "social_posts_flow_check"
    end

    test "version CHECK refuses 0 and negatives, accepts 1 and up", %{w: w} do
      {:ok, post} = Social.create_post(w.org_id, w.x, %{body: "legacy"})

      for v <- [0, -1],
          do:
            assert(
              constraint_of(fn -> set!(post, version: v) end) == "social_posts_version_check"
            )

      assert {:ok, {1, _}} = Repo.transaction(fn -> set!(post, version: 7) end)
    end

    test "a planned status needs the approver columns (extended approver CHECK)", %{w: w} do
      post = studio_post!(w, w.tiktok, "needs_approval")

      assert constraint_of(fn -> set!(post, status: "planned") end) ==
               "social_posts_approved_needs_approver_check"
    end

    test "a Studio post holds draft, needs_approval, approved and planned", %{w: w} do
      for status <- ~w(draft needs_approval approved planned) do
        assert %Post{flow: "studio", status: ^status} = studio_post!(w, w.tiktok, status)
      end
    end

    test "flow cannot be cast: legacy create ignores it", %{w: w} do
      {:ok, post} = Social.create_post(w.org_id, w.x, %{body: "x", flow: "studio"})
      assert post.flow == "legacy"
    end

    test "planned is not an accepted legacy status at the changeset", %{w: w} do
      {:ok, post} = Social.create_post(w.org_id, w.x, %{body: "x"})

      assert {:error, %Ecto.Changeset{}} =
               Social.update_post(w.org_id, post, %{status: "planned"})

      assert Post.statuses() == ~w(draft needs_approval approved scheduled published failed)
    end
  end

  describe "posts: acceptance key and destination key" do
    defp index_def(name) do
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE tablename = 'social_posts' AND indexname = $1",
        [name]
      ).rows
      |> case do
        [[definition]] -> definition
        [] -> nil
      end
    end

    # A Studio post bound to `render_id`, accepted destination `accepted`
    # (written straight to the row: no changeset may write it).
    defp bound!(w, account, render_id, accepted) do
      post = studio_post!(w, account, "needs_approval")
      force!(post, clip_render_id: render_id, accepted_account_id: accepted.id)
    end

    test "both partial unique indexes exist with exactly the specified predicates" do
      acceptance = index_def("social_posts_studio_acceptance_key")
      destination = index_def("social_posts_studio_destination_key")

      assert acceptance =~ "CREATE UNIQUE INDEX"
      assert acceptance =~ "(clip_render_id, accepted_account_id)"
      assert acceptance =~ "WHERE ((flow = 'studio'::text) AND (clip_render_id IS NOT NULL))"

      assert destination =~ "CREATE UNIQUE INDEX"
      assert destination =~ "(clip_render_id, account_id)"
      assert destination =~ "WHERE ((flow = 'studio'::text) AND (clip_render_id IS NOT NULL))"
    end

    test "a second Studio post with the same render and accepted account is refused", %{w: w} do
      render_id = render_id!(pending_clip!(w))
      bound!(w, w.tiktok, render_id, w.tiktok)

      other = studio_post!(w, w.x, "needs_approval")

      assert constraint_of(fn ->
               set!(other, clip_render_id: render_id, accepted_account_id: w.tiktok.id)
             end) == "social_posts_studio_acceptance_key"
    end

    test "a second Studio post with the same render and current account is refused", %{w: w} do
      render_id = render_id!(pending_clip!(w))
      bound!(w, w.tiktok, render_id, w.tiktok)

      other = studio_post!(w, w.tiktok, "needs_approval")

      assert constraint_of(fn ->
               set!(other, clip_render_id: render_id, accepted_account_id: w.x.id)
             end) == "social_posts_studio_destination_key"
    end

    test "distinct destinations on one render coexist; a null render is never constrained", %{
      w: w
    } do
      render_id = render_id!(pending_clip!(w))
      bound!(w, w.tiktok, render_id, w.tiktok)
      assert %Post{} = bound!(w, w.x, render_id, w.x)

      a = studio_post!(w, w.tiktok, "needs_approval")
      b = studio_post!(w, w.tiktok, "needs_approval")
      assert %Post{} = force!(a, accepted_account_id: w.tiktok.id)
      assert %Post{} = force!(b, accepted_account_id: w.tiktok.id)
    end

    test "legacy rows are unaffected: the same render and account may repeat", %{w: w} do
      render_id = render_id!(pending_clip!(w))
      {:ok, a} = Social.create_post(w.org_id, w.x, %{body: "legacy a"})
      {:ok, b} = Social.create_post(w.org_id, w.x, %{body: "legacy b"})

      for post <- [a, b],
          do: force!(post, clip_render_id: render_id, accepted_account_id: w.x.id)

      assert Repo.aggregate(
               from(p in Post, where: p.clip_render_id == ^render_id and p.flow == "legacy"),
               :count
             ) == 2

      # A legacy row does not collide with a Studio one on the same key either.
      assert %Post{} = bound!(w, w.x, render_id, w.x)
    end

    test "the destination index violation maps to a duplicate_destination changeset error", %{
      w: w
    } do
      render_id = render_id!(pending_clip!(w))
      bound!(w, w.tiktok, render_id, w.tiktok)

      changeset =
        %Post{account_id: w.tiktok.id, flow: "studio", clip_render_id: render_id}
        |> Post.studio_create_changeset(%{body: "again", status: "needs_approval"})

      assert {:error, %Ecto.Changeset{} = failed} = Repo.insert(changeset)
      assert {"duplicate_destination", _} = failed.errors[:account_id]
      assert Post.duplicate_destination?(failed)
    end

    test "accepted_account_id is castable by no changeset and survives every update path", %{
      w: w
    } do
      stranger = Ecto.UUID.generate()
      attrs = %{"accepted_account_id" => stranger, "body" => "x"}

      assert Post.changeset(%Post{}, attrs).changes[:accepted_account_id] == nil
      assert Post.studio_create_changeset(%Post{}, attrs).changes[:accepted_account_id] == nil
      assert Post.human_edit_changeset(%Post{}, attrs).changes[:accepted_account_id] == nil

      assert {:ok, legacy} =
               Social.create_post(w.org_id, w.x, %{body: "x", accepted_account_id: stranger})

      assert legacy.accepted_account_id == nil

      assert {:ok, %Post{accepted_account_id: nil}} =
               Social.update_post(w.org_id, legacy, %{body: "y", accepted_account_id: stranger})

      assert {:ok, studio} =
               Studio.create_post(w.org_id, w.tiktok.id, w.approver.id, %{
                 body: "s",
                 accepted_account_id: stranger
               })

      assert studio.accepted_account_id == nil

      # Written once (as accept_render will); moving the current account never rewrites it.
      studio = force!(studio, accepted_account_id: w.tiktok.id)
      moved = force!(studio, account_id: w.x.id)
      assert moved.accepted_account_id == w.tiktok.id
    end

    test "no cast list in lib names accepted_account_id" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(fn file ->
          source = File.read!(file)

          Regex.match?(~r/cast\([^)]*accepted_account_id/s, source) or
            Regex.match?(~r/~w\([^)]*accepted_account_id[^)]*\)a/s, source)
        end)

      assert offenders == []
    end
  end

  describe "posts: state_rev" do
    test "CHECK refuses negatives and accepts 0 and up", %{w: w} do
      {:ok, post} = Social.create_post(w.org_id, w.x, %{body: "legacy"})

      assert constraint_of(fn -> set!(post, state_rev: -1) end) == "social_posts_state_rev_check"
      assert {:ok, {1, _}} = Repo.transaction(fn -> set!(post, state_rev: 0) end)
      assert {:ok, {1, _}} = Repo.transaction(fn -> set!(post, state_rev: 12) end)
    end

    test "is castable by no changeset", %{w: w} do
      attrs = %{"state_rev" => 9, "body" => "x"}
      assert Post.changeset(%Post{}, attrs).changes[:state_rev] == nil
      assert Post.studio_create_changeset(%Post{}, attrs).changes[:state_rev] == nil

      assert {:ok, studio} =
               Studio.create_post(w.org_id, w.tiktok.id, w.approver.id, %{body: "s", state_rev: 9})

      assert studio.state_rev == 0

      assert {:ok, legacy} = Social.create_post(w.org_id, w.x, %{body: "x", state_rev: 9})
      assert legacy.state_rev == 0

      assert {:ok, %Post{state_rev: 0}} =
               Social.update_post(w.org_id, legacy, %{body: "y", state_rev: 9})
    end

    test "create is not a transition (0); refused calls leave it alone", %{w: w} do
      post = studio_post!(w, w.tiktok, "needs_approval")
      assert post.state_rev == 0

      {:ok, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      assert {:error, :studio_disabled} = Studio.get_post(w.org_id, post.id)
      assert Repo.get!(Post, post.id).state_rev == 0
    end
  end

  describe "social_post_approvals" do
    test "one current approval per post (partial unique index)", %{w: w} do
      post = studio_post!(w, w.tiktok, "approved")
      # studio_post!/3 already wrote the one current row.
      {:error, changeset} =
        Repo.transaction(fn ->
          case approval!(post) do
            {:error, changeset} -> Repo.rollback(changeset)
            ok -> ok
          end
        end)

      assert {"has already been taken", opts} = changeset.errors[:post_id]
      assert opts[:constraint] == :unique
      assert opts[:constraint_name] == "social_post_approvals_one_current"
    end

    test "any number of superseded and revoked rows sit beside one current row", %{w: w} do
      post = studio_post!(w, w.tiktok, "approved")

      for {state, v} <- [{"superseded", 2}, {"superseded", 3}, {"revoked", 4}] do
        assert {:ok, %PostApproval{state: ^state}} =
                 approval!(post, %{state: state, version: v, ended_at: DateTime.utc_now()})
      end

      states = Repo.all(from(a in PostApproval, where: a.post_id == ^post.id, select: a.state))
      assert Enum.sort(states) == ~w(current revoked superseded superseded)
    end

    test "state and version CHECKs", %{w: w} do
      post = studio_post!(w, w.tiktok, "approved")

      assert %Postgrex.Error{postgres: %{constraint: "social_post_approvals_state_check"}} =
               attempt(fn ->
                 Repo.insert_all("social_post_approvals", [raw_approval(post, state: "pending")])
               end)

      assert %Postgrex.Error{postgres: %{constraint: "social_post_approvals_version_check"}} =
               attempt(fn ->
                 Repo.insert_all("social_post_approvals", [
                   raw_approval(post, state: "superseded", version: 0)
                 ])
               end)
    end

    defp raw_approval(post, overrides) do
      Map.merge(
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          post_id: Ecto.UUID.dump!(post.id),
          version: 1,
          account_id: Ecto.UUID.dump!(post.account_id),
          approved_by_user_id: Ecto.UUID.dump!(post.approved_by_user_id),
          approved_at: DateTime.utc_now(),
          state: "current",
          content_fingerprint: "fp"
        },
        Map.new(overrides)
      )
    end

    test "approval requires an approver: a human user FK", %{w: w} do
      post = studio_post!(w, w.tiktok, "approved")
      agent = agent!()

      assert %Postgrex.Error{postgres: %{code: :foreign_key_violation}} =
               attempt(fn ->
                 Repo.insert_all("social_post_approvals", [
                   raw_approval(post,
                     state: "superseded",
                     approved_by_user_id: Ecto.UUID.dump!(agent.id)
                   )
                 ])
               end)
    end

    test "a post with an approval row cannot be deleted: in code and by the FK", %{w: w} do
      post = studio_post!(w, w.tiktok, "approved")

      assert {:error, :studio_post} = Social.delete_post(w.org_id, post)
      assert Repo.get(Post, post.id)

      assert %Postgrex.Error{postgres: %{code: :foreign_key_violation}} =
               attempt(fn -> Repo.delete_all(from(p in Post, where: p.id == ^post.id)) end)

      assert Repo.get(Post, post.id)
      assert Repo.aggregate(from(a in PostApproval, where: a.post_id == ^post.id), :count) == 1
    end

    test "KNOWN LIMITATION: a Studio post without a receipt cascades with its profile", %{w: w} do
      post = studio_post!(w, w.tiktok, "draft")
      {1, _} = Repo.delete_all(from(p in Profile, where: p.id == ^w.profile.id))
      refute Repo.get(Post, post.id)
    end
  end

  describe "social_post_events" do
    test "version and account round-trip, and default from the post", %{w: w} do
      post = studio_post!(w, w.tiktok, "needs_approval")
      other = Ecto.UUID.generate()

      PostEvents.record!(post, "version_saved", {:human, w.approver.id},
        version: 4,
        account_id: other
      )

      PostEvents.record!(post, "approval_revoked", {:human, w.approver.id})

      [created, submitted, saved, revoked] = PostEvents.list_for_post(post.id)
      assert {created.post_version, created.account_id} == {1, w.tiktok.id}
      assert {submitted.post_version, submitted.account_id} == {1, w.tiktok.id}
      assert {saved.action, saved.post_version, saved.account_id} == {"version_saved", 4, other}

      assert {revoked.action, revoked.post_version, revoked.account_id} ==
               {"approval_revoked", 1, w.tiktok.id}
    end

    test "every action is accepted and an unknown one is refused", %{w: w} do
      post = studio_post!(w, w.tiktok, "needs_approval")

      for action <- ~w(version_saved approval_revoked planned plan_cancelled retargeted) do
        assert %PostEvent{action: ^action} = PostEvents.record!(post, action, :system)
      end

      assert Enum.all?(
               ~w(version_saved approval_revoked planned plan_cancelled retargeted),
               &(&1 in PostEvent.actions())
             )

      assert_raise Ecto.InvalidChangesetError, fn ->
        PostEvents.record!(post, "teleported", :system)
      end

      assert constraint_of(fn ->
               Repo.insert_all("social_post_events", [
                 %{
                   id: Ecto.UUID.dump!(Ecto.UUID.generate()),
                   post_id: Ecto.UUID.dump!(post.id),
                   actor_kind: "system",
                   action: "teleported",
                   inserted_at: DateTime.utc_now()
                 }
               ])
             end) == "social_post_events_action_check"
    end

    test "body columns stay edited-only", %{w: w} do
      post = studio_post!(w, w.tiktok, "needs_approval")

      assert constraint_of(fn ->
               Repo.insert_all("social_post_events", [
                 %{
                   id: Ecto.UUID.dump!(Ecto.UUID.generate()),
                   post_id: Ecto.UUID.dump!(post.id),
                   actor_kind: "system",
                   action: "planned",
                   body_before: "x",
                   inserted_at: DateTime.utc_now()
                 }
               ])
             end) == "social_post_events_body_only_for_edited_check"
    end
  end

  describe "enablement" do
    test "off by default; not castable from profile attrs", %{w: w} do
      {:ok, profile} =
        Social.create_profile(w.org_id, %{name: "Fresh #{unique()}", studio_enabled: true})

      assert profile.studio_enabled == false
      {:ok, profile} = Social.update_profile(w.org_id, profile, %{studio_enabled: true})
      assert profile.studio_enabled == false
    end

    test "set_enabled needs an approver of the profile and the right org", %{w: w} do
      {:ok, profile} = Social.create_profile(w.org_id, %{name: "Fresh #{unique()}"})
      stranger = user!()

      assert {:error, :not_a_human} = Studio.set_enabled(w.org_id, profile.id, w.agent.id, true)

      assert {:error, :not_an_approver} =
               Studio.set_enabled(w.org_id, profile.id, stranger.id, true)

      assert {:error, :not_found} = Studio.set_enabled(org_id!(), profile.id, w.approver.id, true)
      assert Repo.get!(Profile, profile.id).studio_enabled == false
    end

    test "every Studio function answers :studio_disabled and writes nothing", %{w: w} do
      post = studio_post!(w, w.tiktok, "needs_approval")
      {:ok, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      before_posts = Repo.all(from(p in Post, order_by: p.id))
      events = Repo.aggregate(PostEvent, :count)

      assert {:error, :studio_disabled} =
               Studio.create_post(w.org_id, w.tiktok.id, w.approver.id, %{body: "x"})

      assert {:error, :studio_disabled} = Studio.get_post(w.org_id, post.id)
      assert {:error, :studio_disabled} = Studio.list_posts(w.org_id, w.profile.id)

      assert Repo.all(from(p in Post, order_by: p.id)) == before_posts
      assert Repo.aggregate(PostEvent, :count) == events
      assert Fake.calls() == []
    end

    test "turning it off leaves Studio rows untouched, and legacy keeps working", %{w: w} do
      post = studio_post!(w, w.tiktok, "approved")
      before = Repo.get!(Post, post.id)
      {:ok, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      assert Repo.get!(Post, post.id) == before

      assert {:ok, %Post{flow: "legacy"}} = Social.create_post(w.org_id, w.x, %{body: "legacy"})
    end

    test "check order: scoped load, then enabled, then flow, then actor", %{w: w} do
      studio = studio_post!(w, w.tiktok, "draft")
      {:ok, legacy} = Social.create_post(w.org_id, w.x, %{body: "legacy"})
      stranger = user!()

      # wrong org reads :not_found, whatever else is true
      assert {:error, :not_found} = Studio.get_post(org_id!(), studio.id)
      assert {:error, :not_found} = Studio.create_post(org_id!(), w.tiktok.id, stranger.id, %{})

      # flow before actor: a legacy post is :not_studio_post, never an actor error
      assert {:error, :not_studio_post} = Studio.get_post(w.org_id, legacy.id)

      # actor refusals on create, in the post_approver_check vocabulary
      assert {:error, :not_a_human} =
               Studio.create_post(w.org_id, w.tiktok.id, w.agent.id, %{body: "x"})

      assert {:error, :not_an_approver} =
               Studio.create_post(w.org_id, w.tiktok.id, stranger.id, %{body: "x"})

      # enabled before actor: disabled profile + stranger is :studio_disabled
      {:ok, profile} = Social.create_profile(w.org_id, %{name: "Off #{unique()}"})
      {:ok, off_account} = Social.create_account(w.org_id, profile, %{platform: "x"})

      assert {:error, :studio_disabled} =
               Studio.create_post(w.org_id, off_account.id, stranger.id, %{body: "x"})

      # enabled before flow: a disabled profile reports disabled even for a legacy id
      {:ok, off_legacy} = Social.create_post(w.org_id, off_account, %{body: "legacy"})
      assert {:error, :studio_disabled} = Studio.get_post(w.org_id, off_legacy.id)
    end

    test "an owned account accepts only its owner", %{w: w} do
      owner = member!(user!(), w.org_id)
      {:ok, account} = Social.create_account(w.org_id, w.profile, %{platform: "youtube"})
      {:ok, owned} = Social.set_account_owner(w.org_id, account, owner.id)

      assert {:error, :not_the_owner} =
               Studio.create_post(w.org_id, owned.id, w.approver.id, %{body: "x"})

      assert {:ok, %Post{}} = Studio.create_post(w.org_id, owned.id, owner.id, %{body: "x"})
    end

    test "an archived account refuses", %{w: w} do
      {:ok, archived} = Social.archive_account(w.org_id, w.x)

      assert {:error, :account_archived} =
               Studio.create_post(w.org_id, archived.id, w.approver.id, %{body: "x"})
    end

    test "archived account is refused before the actor (check order)", %{w: w} do
      {:ok, archived} = Social.archive_account(w.org_id, w.x)
      stranger = user!()
      posts = Repo.aggregate(Post, :count)

      for actor <- [stranger.id, w.agent.id] do
        assert {:error, :account_archived} =
                 Studio.create_post(w.org_id, archived.id, actor, %{body: "x"})
      end

      # still after the scoped load and the enabled gate
      assert {:error, :not_found} =
               Studio.create_post(org_id!(), archived.id, stranger.id, %{body: "x"})

      {:ok, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)

      assert {:error, :studio_disabled} =
               Studio.create_post(w.org_id, archived.id, stranger.id, %{body: "x"})

      assert Repo.aggregate(Post, :count) == posts
    end
  end

  describe "social.use at the context level" do
    # A user lacks `social.use` through a MODULE LOCK (a deny on the module
    # named "social", scoped to the org): `Grants.deny/1` takes the module
    # name, not the permission.
    defp lock_social!(w, user) do
      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, user.id},
          permission: "social",
          resource: {:module, w.org_id}
        })

      :ok
    end

    test "an approver who lacks social.use cannot create a Studio post", %{w: w} do
      assert {:ok, %Post{}} = Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "ok"})
      lock_social!(w, w.approver)

      refute Platform.Access.module_access?(
               Platform.Access.Scope.for_user(w.approver),
               :social,
               "social.use"
             )

      assert :ok = Social.post_approver_check(w.org_id, w.profile, w.x, w.approver.id)

      posts = Repo.aggregate(Post, :count)
      events = Repo.aggregate(PostEvent, :count)

      assert {:error, :no_social_access} =
               Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "locked"})

      assert Repo.aggregate(Post, :count) == posts
      assert Repo.aggregate(PostEvent, :count) == events
    end

    test "an approver who lacks social.use cannot switch Studio", %{w: w} do
      lock_social!(w, w.approver)
      assert :ok = Social.approver_check(w.org_id, w.profile, w.approver.id)

      assert {:error, :no_social_access} =
               Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)

      assert Repo.get!(Profile, w.profile.id).studio_enabled == true
    end

    test "the lock is checked after the archived account (check order)", %{w: w} do
      lock_social!(w, w.approver)
      {:ok, archived} = Social.archive_account(w.org_id, w.x)

      assert {:error, :account_archived} =
               Studio.create_post(w.org_id, archived.id, w.approver.id, %{body: "x"})
    end
  end

  describe "Studio.create_post/4" do
    test "writes a version-1 Studio row, its events and no card, atomically", %{w: w} do
      assert {:ok, post} =
               Studio.create_post(w.org_id, w.tiktok.id, w.approver.id, %{body: "hello studio"})

      assert {post.flow, post.status, post.version, post.state_rev} ==
               {"studio", "needs_approval", 1, 0}

      assert post.accepted_account_id == nil

      assert {post.approved_by_user_id, post.scheduled_at, post.publish_after} == {nil, nil, nil}

      assert [%{action: "created"}, %{action: "submitted"}] = PostEvents.list_for_post(post.id)
      assert Repo.aggregate(from(c in ApprovalCard, where: c.post_id == ^post.id), :count) == 0
      assert Fake.calls() == []
    end

    test "a draft writes only `created`", %{w: w} do
      {:ok, post} =
        Studio.create_post(w.org_id, w.tiktok.id, w.approver.id, %{body: "d", status: "draft"})

      assert post.status == "draft"
      assert [%{action: "created"}] = PostEvents.list_for_post(post.id)
    end

    test "only draft and needs_approval can be asked for; flow and version are not castable", %{
      w: w
    } do
      for status <- ~w(approved planned scheduled published failed) do
        assert {:error, %Ecto.Changeset{}} =
                 Studio.create_post(w.org_id, w.tiktok.id, w.approver.id, %{
                   body: "x",
                   status: status
                 })
      end

      {:ok, post} =
        Studio.create_post(w.org_id, w.tiktok.id, w.approver.id, %{
          body: "x",
          flow: "legacy",
          version: 5
        })

      assert {post.flow, post.version} == {"studio", 1}
    end

    test "get_post and list_posts read Studio rows only", %{w: w} do
      studio = studio_post!(w, w.tiktok, "needs_approval")
      {:ok, _legacy} = Social.create_post(w.org_id, w.x, %{body: "legacy"})

      assert {:ok, %Post{id: id}} = Studio.get_post(w.org_id, studio.id)
      assert id == studio.id
      assert {:ok, [%Post{id: ^id, flow: "studio"}]} = Studio.list_posts(w.org_id, w.profile.id)
    end

    test "a failing event write rolls the state change back", %{w: w} do
      # Make the `created` event insert fail, for this test's transaction only.
      Repo.query!(
        "ALTER TABLE social_post_events ADD CONSTRAINT boom CHECK (action <> 'created')"
      )

      posts = Repo.aggregate(Post, :count)

      assert_raise Ecto.ConstraintError, fn ->
        Studio.create_post(w.org_id, w.tiktok.id, w.approver.id, %{body: "never lands"})
      end

      assert Repo.aggregate(Post, :count) == posts
      assert Repo.aggregate(PostEvent, :count) == 0
    end

    test "a refused call writes no event", %{w: w} do
      events = Repo.aggregate(PostEvent, :count)
      stranger = user!()

      assert {:error, :not_an_approver} =
               Studio.create_post(w.org_id, w.tiktok.id, stranger.id, %{body: "x"})

      assert Repo.aggregate(PostEvent, :count) == events
    end
  end
end
