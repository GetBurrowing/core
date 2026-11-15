defmodule Platform.Social.StudioIndependentReviewTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures
  alias Platform.Social
  alias Platform.Social.{ClipPublish, Studio}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    %{w: studio_world!()}
  end

  test "archived account refusal precedes actor refusal", %{w: w} do
    {:ok, account} = Social.archive_account(w.org_id, w.x)

    assert {:error, :account_archived} =
             Studio.create_post(w.org_id, account.id, w.outsider.id, %{body: "review"})
  end

  test "a denied Social module blocks otherwise eligible Studio writes", %{w: w} do
    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social",
        resource: {:module, w.org_id}
      })

    scope = Platform.Access.Scope.for_user(w.approver)
    refute Platform.Access.module_access?(scope, :social, "social.use")
    assert :ok = Social.post_approver_check(w.org_id, w.profile, w.x, w.approver.id)
    assert {:error, _} = Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "review"})
    assert {:error, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
  end

  # Closed in slice A (design owner's decision): `Social.delete_profile/2` and
  # `Studio.create_post/4` serialise on the profile row lock. The sandbox runs
  # every process on one connection, so the interleaving is driven from a
  # telemetry hook (a create fired mid-delete, queued behind the delete's
  # transaction); the two-connection proof is in
  # `studio_profile_lock_concurrency_test.exs`.
  test "profile deletion cannot cascade a Studio post created after its empty check", %{w: w} do
    handler = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _, _, meta, _ ->
          query = meta[:query] || ""

          if self() == parent and !Process.get(handler) and
               String.contains?(query, "social_posts") and String.contains?(query, "'studio'") do
            Process.put(handler, true)

            spawn(fn ->
              send(
                parent,
                {:created_during_delete,
                 Studio.create_post(w.org_id, w.x.id, w.approver.id, %{
                   body: "raced draft",
                   status: "draft"
                 })}
              )
            end)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    result = Social.delete_profile(w.org_id, w.profile)

    # Deletion won (its check ran first): the create waited on the profile row
    # lock, then found no profile. No post was created, so none was cascaded.
    assert {:ok, _} = result
    assert_receive {:created_during_delete, {:error, :not_found}}, 5_000
    assert Social.get_profile(w.org_id, w.profile.id) == nil

    assert Platform.Repo.aggregate(
             from(po in Platform.Social.Post, where: po.flow == "studio"),
             :count
           ) == 0
  end

  test "creation wins: a Studio post committed first makes the deletion refuse", %{w: w} do
    assert {:ok, post} =
             Studio.create_post(w.org_id, w.x.id, w.approver.id, %{
               body: "first",
               status: "draft"
             })

    assert {:error, :has_studio_posts} = Social.delete_profile(w.org_id, w.profile)
    assert Social.get_profile(w.org_id, w.profile.id)
    assert Social.get_post(w.org_id, post.id)
  end

  test "deletion wins: creation on the deleted profile is not_found and writes nothing", %{w: w} do
    assert {:ok, _} = Social.delete_profile(w.org_id, w.profile)

    assert {:error, :not_found} =
             Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "late", status: "draft"})

    assert Platform.Repo.aggregate(
             from(po in Platform.Social.Post, where: po.flow == "studio"),
             :count
           ) == 0
  end

  test "delete_profile of an unknown profile is not_found", %{w: w} do
    assert {:error, :not_found} = Social.delete_profile(w.org_id, Ecto.UUID.generate())
  end

  for mode <- [:due, :next_due, :claim] do
    @mode mode
    test "#{mode} excludes a Studio clip even if its linked post is legacy", %{w: w} do
      now = DateTime.utc_now()
      clip = pending_clip!(w)
      decision_at = DateTime.add(now, -60, :second)

      {:ok, %{posts: [post]}} =
        Social.approve_clip(
          w.org_id,
          clip.id,
          w.approver.id,
          %{"render_id" => render_id!(clip), "account_ids" => [w.tiktok.id]},
          now: decision_at,
          publish_server: :independent_review_no_timer
        )

      assert post.flow == "legacy"
      # This is the explicit second flow filter, independently of
      # the context-level pair invariant; no DB constraint is removed.
      make_studio_clip!(clip)

      case @mode do
        :due ->
          assert {w.org_id, post.id} not in ClipPublish.due(now)

        :next_due ->
          force!(post, publish_after: DateTime.add(now, 60, :second))
          assert is_nil(ClipPublish.next_due(now))

        :claim ->
          assert {:ok, :skipped} = ClipPublish.publish_due(w.org_id, post.id, now)
          assert send_calls() == []
      end
    end
  end
end
