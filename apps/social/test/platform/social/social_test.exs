defmodule Platform.SocialTest do
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{Account, Clip, Post, Profile}

  # Org A owns one of everything; org B owns nothing and is the intruder.
  setup do
    org_a = org_id!()
    org_b = org_id!()

    {:ok, profile} = Social.create_profile(org_a, %{name: "Show A"})
    {:ok, account} = Social.create_account(org_a, profile, %{platform: "youtube", handle: "@a"})
    {:ok, post} = Social.create_post(org_a, account, %{body: "hello"})

    {:ok, clip} =
      Social.create_clip(org_a, profile, %{
        source_url: "https://www.youtube.com/watch?v=abc",
        start_s: 1.0,
        end_s: 2.0
      })

    %{org_a: org_a, org_b: org_b, profile: profile, account: account, post: post, clip: clip}
  end

  describe "org scoping: org A's rows are invisible from org B" do
    test "every get_* answers nil, exactly as for a missing id", ctx do
      for {getter, row} <- [
            get_profile: ctx.profile,
            get_account: ctx.account,
            get_post: ctx.post,
            get_clip: ctx.clip
          ] do
        assert apply(Social, getter, [ctx.org_b, row.id]) == nil
        assert apply(Social, getter, [ctx.org_b, Ecto.UUID.generate()]) == nil
        assert %{id: id} = apply(Social, getter, [ctx.org_a, row.id])
        assert id == row.id
      end
    end

    test "every list_* omits them, with and without filters", ctx do
      assert Social.list_profiles(ctx.org_b) == []
      assert Social.list_accounts(ctx.org_b) == []
      assert Social.list_accounts(ctx.org_b, include_archived: true) == []
      assert Social.list_accounts(ctx.org_b, profile_id: ctx.profile.id) == []
      assert Social.list_posts(ctx.org_b) == []
      assert Social.list_posts(ctx.org_b, account_id: ctx.account.id) == []
      assert Social.list_posts(ctx.org_b, status: "draft") == []
      assert Social.list_clips(ctx.org_b) == []
      assert Social.list_clips(ctx.org_b, profile_id: ctx.profile.id) == []

      assert [%Profile{}] = Social.list_profiles(ctx.org_a)
      assert [%Account{}] = Social.list_accounts(ctx.org_a)
      assert [%Post{}] = Social.list_posts(ctx.org_a, account_id: ctx.account.id, status: "draft")
      assert [%Clip{}] = Social.list_clips(ctx.org_a)
    end

    test "a non-UUID org id sees nothing and does not raise", ctx do
      assert Social.list_profiles("not-a-uuid") == []
      assert Social.get_post("not-a-uuid", ctx.post.id) == nil
      assert Social.get_post(ctx.org_a, "not-a-uuid") == nil
    end

    test "every update, delete and archive from org B is refused and changes nothing", ctx do
      b = ctx.org_b

      assert {:error, :not_found} = Social.update_profile(b, ctx.profile, %{name: "pwned"})
      assert {:error, :not_found} = Social.update_profile(b, ctx.profile.id, %{name: "pwned"})
      assert {:error, :not_found} = Social.delete_profile(b, ctx.profile)
      assert {:error, :not_found} = Social.update_account(b, ctx.account, %{handle: "pwned"})
      assert {:error, :not_found} = Social.archive_account(b, ctx.account)
      assert {:error, :not_found} = Social.update_post(b, ctx.post, %{body: "pwned"})
      assert {:error, :not_found} = Social.delete_post(b, ctx.post)
      assert {:error, :not_found} = Social.approve_post(b, ctx.post, user!().id)
      assert {:error, :not_found} = Social.update_clip(b, ctx.clip, %{caption: "pwned"})
      assert {:error, :not_found} = Social.delete_clip(b, ctx.clip)

      assert Repo.get!(Profile, ctx.profile.id).name == "Show A"
      account = Repo.get!(Account, ctx.account.id)
      assert account.handle == "@a"
      assert account.archived_at == nil
      post = Repo.get!(Post, ctx.post.id)
      assert post.body == "hello"
      assert post.status == "draft"
      assert post.approved_by_user_id == nil
      assert Repo.get!(Clip, ctx.clip.id).caption == nil
    end

    test "creating under org A's profile or account with org B's id is refused", ctx do
      b = ctx.org_b

      assert {:error, :not_found} = Social.create_account(b, ctx.profile, %{platform: "x"})
      assert {:error, :not_found} = Social.create_account(b, ctx.profile.id, %{platform: "x"})
      assert {:error, :not_found} = Social.create_post(b, ctx.account, %{body: "x"})
      assert {:error, :not_found} = Social.create_clip(b, ctx.profile, %{})

      assert [_] = Social.list_accounts(ctx.org_a)
      assert [_] = Social.list_posts(ctx.org_a)
      assert [_] = Social.list_clips(ctx.org_a)
    end

    test "the same writes with org A's id succeed", ctx do
      a = ctx.org_a
      assert {:ok, %{name: "Show A2"}} = Social.update_profile(a, ctx.profile, %{name: "Show A2"})
      assert {:ok, %{handle: "@a2"}} = Social.update_account(a, ctx.account, %{handle: "@a2"})
      assert {:ok, %{body: "edited"}} = Social.update_post(a, ctx.post, %{body: "edited"})
      assert {:ok, %{caption: "c"}} = Social.update_clip(a, ctx.clip, %{caption: "c"})
      assert {:ok, _} = Social.delete_clip(a, ctx.clip)
      assert {:ok, _} = Social.delete_post(a, ctx.post)
    end

    test "a profile's project must belong to the same org", ctx do
      assert {:error, cs} =
               Social.create_profile(ctx.org_a, %{name: "P", project_id: project!(ctx.org_b).id})

      assert errors_on(cs)[:project_id] == ["must belong to the profile's org"]

      assert {:ok, %Profile{}} =
               Social.create_profile(ctx.org_a, %{name: "P", project_id: project!(ctx.org_a).id})

      assert {:error, cs} =
               Social.update_profile(ctx.org_a, ctx.profile, %{project_id: project!(ctx.org_b).id})

      assert errors_on(cs)[:project_id]
    end

    test "org_id is never taken from attrs", ctx do
      {:ok, profile} = Social.create_profile(ctx.org_a, %{name: "Q", org_id: ctx.org_b})
      assert profile.org_id == ctx.org_a
      {:ok, profile} = Social.update_profile(ctx.org_a, profile, %{org_id: ctx.org_b})
      assert profile.org_id == ctx.org_a
    end
  end

  describe "accounts" do
    test "approval_mode defaults to approve_first", ctx do
      assert ctx.account.approval_mode == "approve_first"
      assert Repo.get!(Account, ctx.account.id).approval_mode == "approve_first"
    end

    test "secret_slug is set by the context, never from attrs", ctx do
      assert ctx.account.secret_slug == "social:#{ctx.account.id}"
      assert Social.account_secret_slug(ctx.account) == "social:#{ctx.account.id}"

      {:ok, account} =
        Social.create_account(ctx.org_a, ctx.profile, %{platform: "x", secret_slug: "evil"})

      assert account.secret_slug == "social:#{account.id}"
      {:ok, account} = Social.update_account(ctx.org_a, account, %{secret_slug: "evil"})
      assert account.secret_slug == "social:#{account.id}"
    end

    test "invalid platform, approval_mode and status are rejected on the field", ctx do
      assert {:error, cs} =
               Social.create_account(ctx.org_a, ctx.profile, %{
                 platform: "facebook",
                 approval_mode: "auto",
                 status: "pending"
               })

      errors = errors_on(cs)
      assert errors[:platform]
      assert errors[:approval_mode]
      assert errors[:status]
    end
  end

  describe "posts and clips: invalid values" do
    test "invalid post status and clip status / span are rejected", ctx do
      assert {:error, cs} = Social.create_post(ctx.org_a, ctx.account, %{status: "live"})
      assert errors_on(cs)[:status]

      assert {:error, cs} = Social.create_post(ctx.org_a, ctx.account, %{status: "approved"})
      assert errors_on(cs)[:status]

      assert {:error, cs} =
               Social.create_clip(ctx.org_a, ctx.profile, %{status: "done", start_s: 5, end_s: 1})

      assert errors_on(cs)[:status]
      assert errors_on(cs)[:end_s]
    end
  end

  describe "archiving" do
    setup ctx do
      {:ok, archived} = Social.archive_account(ctx.org_a, ctx.account)
      %{archived: archived}
    end

    test "hides the account from the default list only", ctx do
      assert ctx.archived.archived_at
      assert Social.list_accounts(ctx.org_a) == []
      assert [%{id: id}] = Social.list_accounts(ctx.org_a, include_archived: true)
      assert id == ctx.account.id
      assert Social.get_account(ctx.org_a, ctx.account.id)
    end

    test "its posts stay readable", ctx do
      assert Social.get_post(ctx.org_a, ctx.post.id)
      assert [_] = Social.list_posts(ctx.org_a, account_id: ctx.account.id)
    end

    test "new posts and scheduling on it are refused", ctx do
      assert {:error, :account_archived} =
               Social.create_post(ctx.org_a, ctx.account, %{body: "new"})

      assert {:error, :account_archived} =
               Social.update_post(ctx.org_a, ctx.post, %{scheduled_at: DateTime.utc_now()})

      assert Repo.get!(Post, ctx.post.id).scheduled_at == nil
      # Editing the body of an existing post is not scheduling.
      assert {:ok, _} = Social.update_post(ctx.org_a, ctx.post, %{body: "fixed typo"})
    end
  end

  describe "cascades" do
    test "deleting a task, meeting or file nils the ref and keeps the row", ctx do
      task = task!(ctx.org_a)
      meeting = meeting!(ctx.org_a)
      file = file!(ctx.org_a)

      {:ok, post} =
        Social.update_post(ctx.org_a, ctx.post, %{task_id: task.id, meeting_id: meeting.id})

      {:ok, clip} = Social.update_clip(ctx.org_a, ctx.clip, %{render_file_id: file.id})
      assert post.task_id && post.meeting_id && clip.render_file_id

      Repo.delete_all(from(t in "tasks", where: t.id == type(^task.id, :binary_id)))
      Repo.delete_all(from(m in "meetings", where: m.id == type(^meeting.id, :binary_id)))
      Repo.delete_all(from(f in "platform_files", where: f.id == type(^file.id, :binary_id)))

      post = Social.get_post(ctx.org_a, post.id)
      assert post.task_id == nil
      assert post.meeting_id == nil
      assert Social.get_clip(ctx.org_a, clip.id).render_file_id == nil
    end

    test "deleting a profile removes its accounts, posts and clips", ctx do
      {:ok, second} = Social.create_account(ctx.org_a, ctx.profile, %{platform: "x"})
      {:ok, _} = Social.create_post(ctx.org_a, second, %{body: "two"})

      assert {:ok, _} = Social.delete_profile(ctx.org_a, ctx.profile)

      assert Repo.get(Profile, ctx.profile.id) == nil
      assert Repo.get(Account, ctx.account.id) == nil
      assert Repo.get(Account, second.id) == nil
      assert Repo.get(Post, ctx.post.id) == nil
      assert Repo.get(Clip, ctx.clip.id) == nil
    end

    test "deleting an org that still has a profile is refused (restrict)", ctx do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.delete_all(from(o in "orgs", where: o.id == type(^ctx.org_a, :binary_id)))
          end)
        end

      assert error.postgres.code == :foreign_key_violation
      assert Social.get_profile(ctx.org_a, ctx.profile.id)
    end

    test "hard-deleting the approving user is refused (restrict)", ctx do
      user = user!()
      make_approver!(ctx.org_a, ctx.profile, user)
      {:ok, _} = Social.approve_post(ctx.org_a, ctx.post, user.id)

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.delete_all(from(u in "users", where: u.id == type(^user.id, :binary_id)))
          end)
        end

      assert error.postgres.code == :foreign_key_violation
      assert error.postgres.constraint == "social_posts_approved_by_user_id_fkey"
    end
  end
end
