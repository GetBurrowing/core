defmodule Platform.Social.StudioDiscardTest do
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Post, PostEvents, Studio}

  setup do
    world = studio_world!()
    post = studio_post!(world, world.x, "draft")
    %{world: world, post: post}
  end

  test "a human can discard and restore a draft without losing it", %{world: w, post: post} do
    assert function_exported?(Studio, :discard_draft, 4)
    assert function_exported?(Studio, :restore_draft, 4)

    assert {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
    assert discarded.status == "draft"
    assert discarded.version == post.version
    assert discarded.state_rev == post.state_rev + 1
    assert %DateTime{} = discarded.discarded_at
    assert discarded.media_file_ids == post.media_file_ids
    assert {:ok, []} = Studio.list_posts(w.org_id, w.profile.id)
    assert {:error, :not_found} = Studio.get_post(w.org_id, post.id)
    assert Repo.get!(Post, post.id).id == post.id
    assert Enum.map(PostEvents.list_for_post(post.id), & &1.action) == ~w(created discarded)

    assert {:ok, restored} =
             Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(discarded))

    assert restored.status == "draft"
    assert restored.version == post.version
    assert restored.state_rev == discarded.state_rev + 1
    assert is_nil(restored.discarded_at)
    assert {:ok, [%Post{id: id}]} = Studio.list_posts(w.org_id, w.profile.id)
    assert id == post.id

    assert Enum.map(PostEvents.list_for_post(post.id), & &1.action) ==
             ~w(created discarded restored)
  end

  test "repeats respect stale revisions and do not add events", %{world: w, post: post} do
    {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

    assert {:error, {:stale, _}} =
             Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

    assert {:error, :already_discarded} =
             Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(discarded))

    assert Enum.map(PostEvents.list_for_post(post.id), & &1.action) == ~w(created discarded)
    {:ok, restored} = Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(discarded))

    assert {:error, {:stale, _}} =
             Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(discarded))

    assert {:error, :not_discarded} =
             Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(restored))

    assert Repo.get!(Post, post.id).state_rev == restored.state_rev

    assert Enum.map(PostEvents.list_for_post(post.id), & &1.action) ==
             ~w(created discarded restored)
  end

  test "agent, non-approver and non-owner cannot discard", %{world: w, post: post} do
    stranger = user!() |> member!(w.org_id)

    assert {:error, :not_a_human} =
             Studio.discard_draft(w.org_id, post.id, w.agent.id, expect(post))

    assert {:error, :not_an_approver} =
             Studio.discard_draft(w.org_id, post.id, stranger.id, expect(post))

    owner = user!() |> member!(w.org_id)
    {:ok, _} = Social.set_account_owner(w.org_id, w.x, owner.id)

    assert {:error, :not_the_owner} =
             Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

    assert {:ok, _} = Studio.discard_draft(w.org_id, post.id, owner.id, expect(post))
  end

  test "pending, approved and planned posts cannot be discarded", %{world: w} do
    for status <- ~w(needs_approval approved planned) do
      post = studio_post!(w, w.tiktok, status)

      assert {:error, :not_a_draft} =
               Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

      assert Repo.get!(Post, post.id).state_rev == post.state_rev
    end
  end

  test "discard refuses inconsistent plan or approval fields without a state change", %{
    world: w,
    post: post
  } do
    now = DateTime.utc_now()

    for attrs <- [
          %{scheduled_at: now},
          %{planned_by_user_id: w.approver.id},
          %{planned_set_at: now},
          %{approved_by_user_id: w.approver.id},
          %{approved_at: now}
        ] do
      post |> Ecto.Changeset.change(attrs) |> Repo.update!()
      before = Repo.get!(Post, post.id)
      events = PostEvents.list_for_post(post.id)

      assert {:error, :approval_not_current} =
               Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(before))

      assert Repo.get!(Post, post.id) == before
      assert PostEvents.list_for_post(post.id) == events

      before
      |> Ecto.Changeset.change(Map.new(attrs, fn {key, _} -> {key, nil} end))
      |> Repo.update!()
    end
  end

  test "discard refuses an inconsistent current approval receipt", %{world: w, post: post} do
    receipt =
      %Platform.Social.PostApproval{}
      |> Platform.Social.PostApproval.changeset(%{
        post_id: post.id,
        version: post.version,
        account_id: post.account_id,
        approved_by_user_id: w.approver.id,
        approved_at: DateTime.utc_now(),
        state: "current",
        content_fingerprint: "synthetic"
      })
      |> Repo.insert!()

    events = PostEvents.list_for_post(post.id)

    assert {:error, :approval_not_current} =
             Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

    assert Repo.get!(Post, post.id) == post
    assert Repo.get!(Platform.Social.PostApproval, receipt.id).state == "current"
    assert PostEvents.list_for_post(post.id) == events
  end

  test "restore refuses a marked draft with inconsistent plan or approval state", %{
    world: w,
    post: post
  } do
    {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
    now = DateTime.utc_now()

    for attrs <- [
          %{scheduled_at: now},
          %{planned_by_user_id: w.approver.id},
          %{planned_set_at: now},
          %{approved_by_user_id: w.approver.id},
          %{approved_at: now}
        ] do
      discarded |> Ecto.Changeset.change(attrs) |> Repo.update!()
      before = Repo.get!(Post, post.id)
      events = PostEvents.list_for_post(post.id)

      assert {:error, :approval_not_current} =
               Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(before))

      assert Repo.get!(Post, post.id) == before
      assert PostEvents.list_for_post(post.id) == events

      before
      |> Ecto.Changeset.change(Map.new(attrs, fn {key, _} -> {key, nil} end))
      |> Repo.update!()
    end

    receipt =
      %Platform.Social.PostApproval{}
      |> Platform.Social.PostApproval.changeset(%{
        post_id: post.id,
        version: post.version,
        account_id: post.account_id,
        approved_by_user_id: w.approver.id,
        approved_at: now,
        state: "current",
        content_fingerprint: "synthetic"
      })
      |> Repo.insert!()

    before = Repo.get!(Post, post.id)
    events = PostEvents.list_for_post(post.id)

    assert {:error, :approval_not_current} =
             Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(before))

    assert Repo.get!(Post, post.id) == before
    assert Repo.get!(Platform.Social.PostApproval, receipt.id).state == "current"
    assert PostEvents.list_for_post(post.id) == events
  end

  test "project denial is checked before revealing discard state", %{world: w, post: post} do
    available = studio_post!(w, w.tiktok, "draft")
    {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social.use",
        resource: {:project, w.profile.project_id}
      })

    assert {:error, :no_social_access} =
             Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(discarded))

    assert {:error, :no_social_access} =
             Studio.discard_draft(w.org_id, available.id, w.approver.id, expect(available))

    assert {:error, :no_social_access} =
             Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(discarded))

    assert {:error, :not_found} =
             Studio.list_discarded_drafts(w.org_id, w.profile.id, w.approver.id)

    assert Repo.get!(Post, post.id).state_rev == discarded.state_rev
    assert Repo.get!(Post, available.id) == available
  end

  test "module lock refuses both new actions without changing state", %{world: w, post: post} do
    other = studio_post!(w, w.tiktok, "draft")
    {:ok, discarded} = Studio.discard_draft(w.org_id, other.id, w.approver.id, expect(other))

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social",
        resource: {:module, w.org_id}
      })

    assert {:error, :no_social_access} =
             Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

    assert {:error, :no_social_access} =
             Studio.restore_draft(w.org_id, other.id, w.approver.id, expect(discarded))

    assert Repo.get!(Post, post.id) == post
    assert Repo.get!(Post, other.id) == discarded
  end

  test "wrong org is refused for discard and restore without changing either", %{
    world: w,
    post: post
  } do
    other = studio_post!(w, w.tiktok, "draft")
    {:ok, discarded} = Studio.discard_draft(w.org_id, other.id, w.approver.id, expect(other))
    wrong = org_id!()

    assert {:error, :not_found} =
             Studio.discard_draft(wrong, post.id, w.approver.id, expect(post))

    assert {:error, :not_found} =
             Studio.restore_draft(wrong, other.id, w.approver.id, expect(discarded))

    assert Repo.get!(Post, post.id) == post
    assert Repo.get!(Post, other.id) == discarded
  end

  test "agent replay and identical edits cannot revive or return a discarded draft", %{world: w} do
    attrs = %{"request_id" => "discard-test-#{unique()}", "body" => "Agent draft"}
    assert {:ok, post, :created} = Studio.create_agent_draft(w.org_id, w.x.id, w.agent.id, attrs)
    assert {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

    assert {:error, :post_discarded} =
             Studio.create_agent_draft(w.org_id, w.x.id, w.agent.id, attrs)

    assert {:error, :request_id_conflict} =
             Studio.create_agent_draft(
               w.org_id,
               w.x.id,
               w.agent.id,
               Map.put(attrs, "body", "different")
             )

    assert {:error, :post_discarded} =
             AgentDrafts.update_agent_draft(w.org_id, post.id, %{"body" => post.body},
               agent_id: w.agent.id
             )

    assert Repo.get!(Post, post.id).state_rev == discarded.state_rev
  end

  test "accepting a discarded render destination refuses instead of replaying it", %{world: w} do
    clip = w |> pending_clip!() |> make_studio_clip!()
    attrs = %{render_id: render_id!(clip), account_ids: [w.x.id]}
    assert {:ok, %{posts: [post]}} = Studio.accept_render(w.org_id, clip.id, w.approver.id, attrs)

    assert {:ok, draft} =
             Studio.request_changes(w.org_id, post.id, w.approver.id, expect(post), "revise")

    assert {:ok, discarded} =
             Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(draft))

    assert {:error, {:destinations, [%{reason: :draft_discarded}]}} =
             Studio.accept_render(w.org_id, clip.id, w.approver.id, attrs)

    assert Repo.get!(Post, post.id).state_rev == discarded.state_rev
  end

  test "discard and restore preserve render media and unrelated posts", %{world: w} do
    clip = w |> pending_clip!() |> make_studio_clip!()
    attrs = %{render_id: render_id!(clip), account_ids: [w.x.id]}
    {:ok, %{posts: [post]}} = Studio.accept_render(w.org_id, clip.id, w.approver.id, attrs)

    {:ok, draft} =
      Studio.request_changes(w.org_id, post.id, w.approver.id, expect(post), "revise")

    unrelated = studio_post!(w, w.tiktok, "draft")
    assert [_ | _] = draft.media_file_ids
    files = Enum.map(draft.media_file_ids, &Repo.get!(Platform.Files.File, &1))
    {:ok, discarded} = Studio.discard_draft(w.org_id, draft.id, w.approver.id, expect(draft))
    {:ok, restored} = Studio.restore_draft(w.org_id, draft.id, w.approver.id, expect(discarded))
    assert restored.media_file_ids == draft.media_file_ids
    assert Enum.map(draft.media_file_ids, &Repo.get!(Platform.Files.File, &1)) == files
    assert Repo.get!(Post, unrelated.id) == unrelated
  end

  test "acceptance-key replay also refuses after a discarded post was retargeted", %{world: w} do
    clip = w |> pending_clip!() |> make_studio_clip!()
    attrs = %{render_id: render_id!(clip), account_ids: [w.x.id]}
    {:ok, %{posts: [post]}} = Studio.accept_render(w.org_id, clip.id, w.approver.id, attrs)

    {:ok, %{post: moved}} =
      Studio.save_version(
        w.org_id,
        post.id,
        {:human, w.approver.id},
        %{account_id: w.tiktok.id},
        expect(post)
      )

    {:ok, draft} =
      Studio.request_changes(w.org_id, moved.id, w.approver.id, expect(moved), "revise")

    {:ok, discarded} = Studio.discard_draft(w.org_id, moved.id, w.approver.id, expect(draft))

    assert {:error, {:destinations, [%{reason: :draft_discarded}]}} =
             Studio.accept_render(w.org_id, clip.id, w.approver.id, attrs)

    assert Repo.get!(Post, post.id).state_rev == discarded.state_rev
  end

  test "reservation lookup does not return another owner's account id", %{world: w} do
    clip = w |> pending_clip!() |> make_studio_clip!()
    attrs = %{render_id: render_id!(clip), account_ids: [w.x.id]}
    {:ok, %{posts: [post]}} = Studio.accept_render(w.org_id, clip.id, w.approver.id, attrs)

    {:ok, %{post: moved}} =
      Studio.save_version(
        w.org_id,
        post.id,
        {:human, w.approver.id},
        %{account_id: w.tiktok.id},
        expect(post)
      )

    {:ok, draft} =
      Studio.request_changes(w.org_id, moved.id, w.approver.id, expect(moved), "revise")

    {:ok, _} = Studio.discard_draft(w.org_id, draft.id, w.approver.id, expect(draft))
    owner = user!() |> member!(w.org_id)
    {:ok, _} = Social.set_account_owner(w.org_id, w.tiktok, owner.id)

    assert {:ok, [%{account_id: nil, accepted_account_id: accepted}]} =
             Studio.discarded_render_reservations(
               w.org_id,
               w.profile.id,
               w.approver.id,
               render_id!(clip)
             )

    assert accepted == w.x.id
  end

  test "agent tools return a specific content-free refusal for a discarded draft", %{world: w} do
    attrs = %{
      "account_id" => w.x.id,
      "request_id" => "discard-tool-#{unique()}",
      "body" => "private synthetic caption"
    }

    context = %{agent_id: w.agent.id}

    assert {:ok, %{post: post}} =
             Platform.Federation.ToolArguments.dispatch(
               "social_studio_draft_create",
               attrs,
               context
             )

    assert {:ok, _} =
             Studio.discard_draft(
               w.org_id,
               post.id,
               w.approver.id,
               expect(Repo.get!(Post, post.id))
             )

    for {name, args} <- [
          {"social_studio_draft_create", attrs},
          {"social_draft_update", %{"post_id" => post.id, "body" => "private synthetic caption"}}
        ] do
      assert {:error, %{code: :post_discarded} = error} =
               Platform.Federation.ToolArguments.dispatch(name, args, context)

      refute inspect(error) =~ "private synthetic caption"
    end
  end

  test "only an authorized person can list discarded drafts for recovery", %{world: w, post: post} do
    {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
    assert function_exported?(Studio, :list_discarded_drafts, 3)
    assert {:ok, [item]} = Studio.list_discarded_drafts(w.org_id, w.profile.id, w.approver.id)
    assert item.post.id == discarded.id
    assert item.event.action == "discarded"
    assert item.event.actor_id == w.approver.id
    stranger = user!() |> member!(w.org_id)
    assert {:ok, []} = Studio.list_discarded_drafts(w.org_id, w.profile.id, stranger.id)
    assert {:error, :not_found} = Studio.list_discarded_drafts(w.org_id, w.profile.id, w.agent.id)
  end

  test "discard history retains the actor id if that user is deleted", %{world: w, post: post} do
    actor = user!() |> member!(w.org_id)

    {:ok, _} =
      Social.update_profile(w.org_id, w.profile, %{approver_user_ids: [w.approver.id, actor.id]})

    assert {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, actor.id, expect(post))
    Repo.delete!(actor)
    assert Repo.get!(Post, post.id).discarded_at == discarded.discarded_at

    assert %{actor_kind: "human", actor_id: actor_id} =
             List.last(PostEvents.list_for_post(post.id))

    assert actor_id == actor.id
  end

  test "an archived account's discarded draft remains visible but cannot be restored", %{
    world: w,
    post: post
  } do
    {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
    {:ok, _} = Social.archive_account(w.org_id, w.x)

    assert {:ok, [%{post: %{id: id}, can_restore?: false, restore_reason: :account_archived}]} =
             Studio.list_discarded_drafts(w.org_id, w.profile.id, w.approver.id)

    assert id == post.id

    assert {:error, :account_archived} =
             Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(discarded))

    assert Repo.get!(Post, post.id).discarded_at == discarded.discarded_at
  end

  test "an approver can discard on an archived account but cannot restore until it is live", %{
    world: w,
    post: post
  } do
    {:ok, _} = Social.archive_account(w.org_id, w.x)
    assert {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

    assert {:error, :account_archived} =
             Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(discarded))

    assert {:error, :not_a_human} =
             Studio.discard_draft(w.org_id, post.id, w.agent.id, expect(discarded))
  end

  test "an approver can discard when the account owner is archived but cannot restore", %{
    world: w,
    post: post
  } do
    owner = user!() |> member!(w.org_id)
    {:ok, _} = Social.set_account_owner(w.org_id, w.x, owner.id)
    {:ok, _} = Platform.Accounts.archive_user(owner)
    assert {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))

    assert {:error, :not_the_owner} =
             Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(discarded))

    assert {:ok, [%{post: %{id: id}, can_restore?: false, restore_reason: :approver_required}]} =
             Studio.list_discarded_drafts(w.org_id, w.profile.id, w.approver.id)

    assert id == post.id
  end

  test "deleting an owner clears the account owner and restores the normal approver rule", %{
    world: w,
    post: post
  } do
    owner = user!() |> member!(w.org_id)
    {:ok, _} = Social.set_account_owner(w.org_id, w.x, owner.id)
    Platform.Repo.delete!(owner)
    assert is_nil(Social.get_account(w.org_id, w.x.id).owner_user_id)
    assert {:ok, discarded} = Studio.discard_draft(w.org_id, post.id, w.approver.id, expect(post))
    assert {:ok, _} = Studio.restore_draft(w.org_id, post.id, w.approver.id, expect(discarded))
  end

  test "restore refuses a conflicting render destination without changing either post", %{
    world: w
  } do
    clip = w |> pending_clip!() |> make_studio_clip!()
    attrs = %{render_id: render_id!(clip), account_ids: [w.x.id]}
    {:ok, %{posts: [accepted]}} = Studio.accept_render(w.org_id, clip.id, w.approver.id, attrs)

    {:ok, draft} =
      Studio.request_changes(w.org_id, accepted.id, w.approver.id, expect(accepted), "revise")

    {:ok, discarded} = Studio.discard_draft(w.org_id, draft.id, w.approver.id, expect(draft))

    # A conflict cannot arise with the current unique indexes. Drop them inside
    # this sandbox transaction to exercise the defense independently.
    Ecto.Adapters.SQL.query!(Repo, "DROP INDEX social_posts_studio_acceptance_key")
    Ecto.Adapters.SQL.query!(Repo, "DROP INDEX social_posts_studio_destination_key")
    other = studio_post!(w, w.x, "draft")

    other =
      other
      |> Ecto.Changeset.change(
        clip_render_id: discarded.clip_render_id,
        accepted_account_id: discarded.accepted_account_id
      )
      |> Repo.update!()

    before_events = PostEvents.list_for_post(discarded.id)

    assert {:error, :duplicate_destination} =
             Studio.restore_draft(w.org_id, discarded.id, w.approver.id, expect(discarded))

    assert Repo.get!(Post, discarded.id) == discarded
    assert Repo.get!(Post, other.id) == other
    assert PostEvents.list_for_post(discarded.id) == before_events
  end

  test "render destination indexes keep discarded posts reserved" do
    result =
      Ecto.Adapters.SQL.query!(Repo, """
      SELECT indexname, indexdef FROM pg_indexes
      WHERE schemaname = current_schema()
        AND indexname IN ('social_posts_studio_acceptance_key', 'social_posts_studio_destination_key')
      """)

    assert length(result.rows) == 2

    for [_name, definition] <- result.rows do
      assert definition =~ "UNIQUE INDEX"
      assert definition =~ "clip_render_id"
      refute definition =~ "discarded_at"
    end
  end
end
