defmodule Platform.Social.ApprovalTest do
  @moduledoc """
  `approved_by_user_id` must reference a user, never an agent. Two layers,
  each pinned on its own:

    * layer 1, `Platform.Social.approve_post/3`: a changeset error "must be a
      human user", DISTINCT from the FK's "does not exist", so this test goes
      red if the context check is removed and only the FK is left;
    * layer 2, the FK to `users`: raw `update_all` / `insert_all`, no
      changeset in the path, so this test goes red if the FK is dropped.

  The agent cases use a real `agents` row, so they prove agent-not-user,
  not merely id-not-found.
  """
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.Post

  setup do
    org_id = org_id!()
    {:ok, profile} = Social.create_profile(org_id, %{name: "Approvals"})
    {:ok, account} = Social.create_account(org_id, profile, %{platform: "linkedin"})
    {:ok, post} = Social.create_post(org_id, account, %{body: "draft"})
    %{org_id: org_id, profile: profile, account: account, post: post, agent: agent!()}
  end

  describe "layer 1: approve_post/3" do
    test "refuses an agent id with the human-user error, not the FK message", ctx do
      assert {:error, %Ecto.Changeset{} = cs} =
               Social.approve_post(ctx.org_id, ctx.post, ctx.agent.id)

      assert errors_on(cs)[:approved_by_user_id] == ["must be a human user"]
      assert Repo.get!(Post, ctx.post.id).approved_by_user_id == nil
      assert Repo.get!(Post, ctx.post.id).status == "draft"
    end

    test "Social 3/7: a real user NOT on the approver list is refused, row unchanged", ctx do
      assert {:error, :not_an_approver} = Social.approve_post(ctx.org_id, ctx.post, user!().id)
      assert Repo.get!(Post, ctx.post.id).status == "draft"
    end

    test "refuses a random UUID", ctx do
      assert {:error, cs} = Social.approve_post(ctx.org_id, ctx.post, Ecto.UUID.generate())
      assert errors_on(cs)[:approved_by_user_id] == ["must be a human user"]
    end

    test "accepts a real user on the approver list and stamps approved_at", ctx do
      user = make_approver!(ctx.org_id, ctx.profile, user!())
      assert {:ok, post} = Social.approve_post(ctx.org_id, ctx.post, user.id)
      assert post.approved_by_user_id == user.id
      assert post.status == "approved"
      assert %DateTime{} = post.approved_at
    end

    test "does not rewind a post already approved", ctx do
      user = make_approver!(ctx.org_id, ctx.profile, user!())
      {:ok, post} = Social.approve_post(ctx.org_id, ctx.post, user.id)
      assert {:error, :not_approvable} = Social.approve_post(ctx.org_id, post, user.id)
    end

    test "a general update cannot set the approver", ctx do
      user = user!()

      {:ok, post} =
        Social.update_post(ctx.org_id, ctx.post, %{
          approved_by_user_id: user.id,
          approved_at: DateTime.utc_now()
        })

      assert post.approved_by_user_id == nil
      assert post.approved_at == nil

      assert {:error, cs} = Social.update_post(ctx.org_id, ctx.post, %{status: "published"})
      assert errors_on(cs)[:status]
    end

    test "profile approver_user_ids refuse an agent id", ctx do
      user = user!()

      assert {:error, cs} =
               Social.create_profile(ctx.org_id, %{
                 name: "With agent",
                 approver_user_ids: [user.id, ctx.agent.id]
               })

      assert errors_on(cs)[:approver_user_ids] == ["must be a human user"]

      assert {:error, _} =
               Social.update_profile(ctx.org_id, ctx.profile, %{approver_user_ids: [ctx.agent.id]})

      assert {:ok, profile} =
               Social.update_profile(ctx.org_id, ctx.profile, %{approver_user_ids: [user.id]})

      assert profile.approver_user_ids == [user.id]
    end
  end

  describe "layer 2: the FK to users, no changeset in the path" do
    test "update_all setting an agent id as approver raises a FK violation", ctx do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.update_all(from(p in Post, where: p.id == ^ctx.post.id),
              set: [
                approved_by_user_id: ctx.agent.id,
                approved_at: DateTime.utc_now(),
                status: "approved"
              ]
            )
          end)
        end

      assert error.postgres.code == :foreign_key_violation
      assert error.postgres.constraint == "social_posts_approved_by_user_id_fkey"
    end

    test "insert_all with an agent id as approver raises a FK violation", ctx do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.insert_all(Post, [
              %{
                id: Ecto.UUID.generate(),
                account_id: ctx.account.id,
                status: "approved",
                approved_by_user_id: ctx.agent.id,
                approved_at: DateTime.utc_now(),
                inserted_at: DateTime.utc_now(),
                updated_at: DateTime.utc_now()
              }
            ])
          end)
        end

      assert error.postgres.code == :foreign_key_violation
    end

    test "insert_all with status approved and a NULL approver raises the CHECK", ctx do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.insert_all(Post, [
              %{
                id: Ecto.UUID.generate(),
                account_id: ctx.account.id,
                status: "approved",
                inserted_at: DateTime.utc_now(),
                updated_at: DateTime.utc_now()
              }
            ])
          end)
        end

      assert error.postgres.constraint == "social_posts_approved_needs_approver_check"
    end
  end
end
