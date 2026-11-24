defmodule Platform.Social.QualityReviewSchemaTest do
  use Platform.DataCase, async: true

  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures, only: [approval_fixture: 0]

  alias Platform.Social.{Post, Profile}

  setup do
    approval_fixture()
  end

  test "reviewers default empty and are editable separately from approvers", ctx do
    assert Map.get(Repo.get!(Profile, ctx.profile.id), :quality_reviewer_user_ids) == []

    changeset = Profile.changeset(ctx.profile, %{quality_reviewer_user_ids: [ctx.n.id]})
    assert changeset.valid?
    updated = Repo.update!(changeset)
    assert Map.get(updated, :quality_reviewer_user_ids) == [ctx.n.id]
    assert updated.approver_user_ids == [ctx.h1.id, ctx.h2.id]
  end

  test "database defaults reviewers empty and pass fields null without schema defaults", ctx do
    now = DateTime.utc_now()
    id = Ecto.UUID.generate()

    Repo.insert_all("social_profiles", [
      %{
        id: Ecto.UUID.dump!(id),
        org_id: Ecto.UUID.dump!(ctx.org_id),
        name: "raw quality #{unique()}",
        inserted_at: now,
        updated_at: now
      }
    ])

    assert %{rows: [[[]]]} =
             Repo.query!(
               "SELECT quality_reviewer_user_ids FROM social_profiles WHERE id = $1",
               [Ecto.UUID.dump!(id)]
             )

    post_id = raw_post!(ctx.a.id)

    assert %{rows: [[nil, nil, nil]]} =
             Repo.query!(
               "SELECT quality_passed_by_user_id, quality_passed_at, quality_pass_fingerprint FROM social_posts WHERE id = $1",
               [Ecto.UUID.dump!(post_id)]
             )
  end

  test "legacy quality review is accepted but Studio's status boundary stays closed", ctx do
    changeset = Post.changeset(%Post{}, %{status: "quality_review"})
    assert changeset.valid?
    assert raw_post!(ctx.a.id, %{status: "quality_review"})

    error =
      assert_raise Postgrex.Error, fn ->
        raw_post!(ctx.a.id, %{flow: "studio", status: "quality_review"})
      end

    assert error.postgres.constraint == "social_posts_studio_boundary_check"

    refute Post.studio_create_changeset(%Post{flow: "studio"}, %{
             body: "quality",
             status: "quality_review"
           }).valid?
  end

  test "widened database status check preserves every existing status including planned", ctx do
    for status <- ~w(draft needs_approval approved scheduled published failed planned) do
      attrs = %{status: status, flow: if(status == "planned", do: "studio", else: "legacy")}

      attrs =
        if status in ~w(approved scheduled published planned),
          do:
            Map.merge(attrs, %{
              approved_by_user_id: Ecto.UUID.dump!(ctx.h1.id),
              approved_at: DateTime.utc_now()
            }),
          else: attrs

      assert raw_post!(ctx.a.id, attrs)
    end
  end

  test "general creation and edit changesets cannot forge a quality pass", ctx do
    attrs = %{
      quality_passed_by_user_id: ctx.h1.id,
      quality_passed_at: DateTime.utc_now(),
      quality_pass_fingerprint: "forged",
      body: "quality",
      status: "draft"
    }

    for changeset <- [
          Post.changeset(%Post{}, attrs),
          Post.studio_create_changeset(%Post{flow: "studio"}, attrs),
          Post.human_edit_changeset(%Post{}, attrs)
        ] do
      for field <- [:quality_passed_by_user_id, :quality_passed_at, :quality_pass_fingerprint] do
        refute Map.has_key?(changeset.changes, field)
      end
    end
  end

  test "pass author references users and refuses an actual agent id", ctx do
    error =
      assert_raise Postgrex.Error, fn ->
        raw_post!(ctx.a.id, %{quality_passed_by_user_id: Ecto.UUID.dump!(ctx.g.id)})
      end

    assert error.postgres.code == :foreign_key_violation
    assert error.postgres.constraint == "social_posts_quality_passed_by_user_id_fkey"

    id =
      raw_post!(ctx.a.id, %{
        quality_passed_by_user_id: Ecto.UUID.dump!(ctx.h1.id),
        quality_passed_at: DateTime.utc_now(),
        quality_pass_fingerprint: "reviewed"
      })

    post = Repo.get!(Post, id)
    assert Map.get(post, :quality_passed_by_user_id) == ctx.h1.id
    assert Map.get(post, :quality_passed_at)
    assert Map.get(post, :quality_pass_fingerprint) == "reviewed"
  end

  defp raw_post!(account_id, overrides \\ %{}) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    row =
      Map.merge(
        %{
          id: Ecto.UUID.dump!(id),
          account_id: Ecto.UUID.dump!(account_id),
          body: "quality",
          inserted_at: now,
          updated_at: now
        },
        overrides
      )

    {:ok, {1, _}} = Repo.transaction(fn -> Repo.insert_all("social_posts", [row]) end)
    id
  end
end
