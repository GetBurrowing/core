defmodule Platform.Social.ClipRevisionRequestTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.{Repo, Social}
  alias Platform.Social.{AgentDrafts, Clip, ClipRender}

  setup do
    w = render_world!()
    file = stored_file!(w.project, "first cut #{unique()}", "first.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => "Working title",
          "caption" => "Working copy",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    render = Repo.get_by!(ClipRender, clip_id: clip.id, rev: clip.rev)
    %{w: w, clip: clip, base: render}
  end

  defp request(w, clip, attrs) do
    apply(Platform.Social.ClipRevisions, :request_edit, [w.scope, clip.id, w.approver.id, attrs])
  end

  test "a self-edit request retains its note and has no agent notification", ctx do
    %{w: w, clip: clip, base: base} = ctx

    attrs = %{
      base_render_id: base.id,
      assignee: :self,
      note: "  Shorten the intro  ",
      request_id: Ecto.UUID.generate()
    }

    assert {:ok, %{request: req, notification: :not_applicable}} = request(w, clip, attrs)
    assert req.assigned_user_id == w.approver.id
    assert req.assigned_agent_id == nil
    assert req.note == "Shorten the intro"
    assert Repo.get!(Clip, clip.id).review_status == "rejected"
    assert Repo.get!(Clip, clip.id).caption == "Working copy"
    assert Social.ClipLibrary.clip_state(Repo.get!(Clip, clip.id), []) == "Awaiting edit"

    assert {:ok, "Awaiting edit"} =
             apply(Platform.Social.ClipRevisions, :state, [
               w.scope,
               clip.id,
               {:user, w.approver.id}
             ])

    assert Social.list_posts(w.org_id, %{}) == []
  end

  test "same request replay returns one receipt and changed payload refuses", ctx do
    %{w: w, clip: clip, base: base} = ctx

    attrs = %{
      base_render_id: base.id,
      assignee: :self,
      note: "Tighten",
      request_id: Ecto.UUID.generate()
    }

    assert {:ok, %{request: first}} = request(w, clip, attrs)
    assert {:ok, %{request: same}} = request(w, clip, attrs)
    assert same.id == first.id
    assert {:error, :idempotency_conflict} = request(w, clip, %{attrs | note: "Different"})
  end

  test "an explicitly assigned maker is mentioned once and can read the instruction", ctx do
    %{w: w, clip: clip, base: base} = ctx
    join!(w.profile.space_id, :agent, w.agent.id)

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "revision-#{unique()}",
        agent_id: w.agent.id,
        owner_user_id: w.approver.id,
        status: "active"
      })

    {:ok, _} =
      Platform.Access.RuntimeProfiles.create_for_runtime(runtime, ["social", "files"], nil)

    attrs = %{
      base_render_id: base.id,
      assignee: {:agent, w.agent.id},
      note: "Private edit instruction",
      request_id: Ecto.UUID.generate()
    }

    assert {:ok, %{request: req, notification: :sent}} = request(w, clip, attrs)
    assert req.notification_message_id != nil
    message = Platform.Chat.get_message(req.notification_message_id)
    refute message.content =~ attrs.note
    assert message.content =~ "/m/social?"
    assert message.content =~ "clip=#{clip.id}"
    assert message.content =~ "#clip-edit-request-#{req.id}"
    assert message.metadata["social_clip_edit_request_id"] == req.id
    assert {:ok, %{request: same, notification: :sent}} = request(w, clip, attrs)
    assert same.notification_message_id == req.notification_message_id
    actor = {:agent, w.agent.id, runtime.runtime_id}

    assert {:ok, %{request: readable}} =
             apply(Platform.Social.ClipRevisions, :get_request, [w.scope, req.id, actor])

    assert readable.note == attrs.note

    assert {:ok, [%{request: listed, awaiting?: true}]} =
             apply(Platform.Social.ClipRevisions, :list_assigned, [w.scope, actor])

    assert listed.id == req.id
    Repo.update!(Ecto.Changeset.change(runtime, status: "revoked"))

    assert {:error, :unauthorized} =
             apply(Platform.Social.ClipRevisions, :get_request, [w.scope, req.id, actor])
  end

  test "a definite pre-insert notification failure is visible and only an explicit replacement wakes again",
       ctx do
    %{w: w, clip: clip, base: base} = ctx
    join!(w.profile.space_id, :agent, w.agent.id)

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "failed-wake-#{unique()}",
        agent_id: w.agent.id,
        owner_user_id: w.approver.id,
        status: "active"
      })

    {:ok, _} =
      Platform.Access.RuntimeProfiles.create_for_runtime(runtime, ["social", "files"], nil)

    space = Platform.Chat.get_space(w.profile.space_id)
    Repo.update!(Ecto.Changeset.change(space, archived_at: DateTime.utc_now()))

    attrs = %{
      base_render_id: base.id,
      assignee: {:agent, w.agent.id},
      note: "Edit",
      request_id: Ecto.UUID.generate()
    }

    assert {:ok, %{request: failed, notification: :failed}} = request(w, clip, attrs)
    assert failed.notification_message_id == nil
    assert failed.notification_attempted_at != nil
    Repo.update!(Ecto.Changeset.change(Platform.Chat.get_space(space.id), archived_at: nil))
    assert {:ok, %{request: same, notification: :failed}} = request(w, clip, attrs)
    assert same.notification_attempted_at == failed.notification_attempted_at
    assert same.notification_message_id == nil

    replacement =
      attrs
      |> Map.put(:request_id, Ecto.UUID.generate())
      |> Map.put(:replaces_request_id, failed.id)

    assert {:ok, %{request: sent, notification: :sent}} = request(w, clip, replacement)
    assert sent.notification_message_id != nil
    assert failed.id != sent.id
    assert Repo.get!(Platform.Social.ClipEditRequest, failed.id).notification_status == "failed"
  end

  test "replacing an uncertain request invalidates the earlier request without resetting its attempt",
       ctx do
    %{w: w, clip: clip, base: base} = ctx
    # A persisted ambiguous attempt is deliberately set here; no fake success or wake is injected.
    attrs = %{
      base_render_id: base.id,
      assignee: :self,
      note: "Old instruction",
      request_id: Ecto.UUID.generate()
    }

    {:ok, %{request: old}} = request(w, clip, attrs)
    old = old |> Ecto.Changeset.change(notification_status: "uncertain") |> Repo.update!()

    replacement =
      %{attrs | request_id: Ecto.UUID.generate(), note: "Replacement"}
      |> Map.put(:replaces_request_id, old.id)

    assert {:ok, %{request: newer}} = request(w, clip, replacement)
    assert newer.id != old.id
    assert apply(Platform.Social.ClipRevisions, :latest, [clip.id]).id == newer.id
    assert Repo.get!(Platform.Social.ClipEditRequest, old.id).notification_status == "uncertain"

    assert {:error, :request_not_replaceable} =
             request(w, clip, Map.put(replacement, :request_id, Ecto.UUID.generate()))
  end

  test "another current quality reviewer can read retained instructions but cannot return a self assignment",
       ctx do
    attrs = %{
      base_render_id: ctx.base.id,
      assignee: :self,
      note: "Editing history",
      request_id: Ecto.UUID.generate()
    }

    {:ok, %{request: request}} = request(ctx.w, ctx.clip, attrs)
    reviewer = member!(user!(), ctx.w.org_id)
    Repo.update!(Ecto.Changeset.change(ctx.w.profile, quality_reviewer_user_ids: [reviewer.id]))

    assert {:ok, %{request: readable}} =
             Platform.Social.ClipRevisions.get_request(
               ctx.w.scope,
               request.id,
               {:user, reviewer.id}
             )

    assert readable.note == attrs.note

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Social.Profile, ctx.w.profile.id),
        quality_reviewer_user_ids: []
      )
    )

    assert {:error, :unauthorized} =
             Platform.Social.ClipRevisions.get_request(
               ctx.w.scope,
               request.id,
               {:user, reviewer.id}
             )
  end

  test "request order is the committed insertion order, not a caller clock's timestamp", ctx do
    attrs = %{
      base_render_id: ctx.base.id,
      assignee: :self,
      note: "First",
      request_id: Ecto.UUID.generate()
    }

    {:ok, %{request: first}} = request(ctx.w, ctx.clip, attrs)

    {:ok, _} =
      Social.ClipDecisions.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id)

    # Represents a previous node's ahead clock; history time is not request precedence.
    Repo.update!(
      Ecto.Changeset.change(first, inserted_at: DateTime.add(first.inserted_at, 3600, :second))
    )

    {:ok, %{request: newer}} =
      request(ctx.w, ctx.clip, %{attrs | request_id: Ecto.UUID.generate(), note: "Second"})

    assert Social.ClipRevisions.latest(ctx.clip.id).id == newer.id

    assert {:ok, "Awaiting edit"} =
             Social.ClipRevisions.state(ctx.w.scope, ctx.clip.id, {:user, ctx.w.approver.id})
  end

  test "caller transactions cannot hold Social locks across a notification", ctx do
    attrs = %{
      base_render_id: ctx.base.id,
      assignee: :self,
      note: "Edit",
      request_id: Ecto.UUID.generate()
    }

    assert {:ok, {:error, :caller_transaction}} =
             Repo.transaction(fn -> request(ctx.w, ctx.clip, attrs) end)

    assert Repo.aggregate(Platform.Social.ClipEditRequest, :count) == 0
    assert Repo.get!(Clip, ctx.clip.id).review_status == "pending"
  end

  for status <- [nil, "attempted"] do
    test "explicit replacement recovers an agent request stored as #{inspect(status)} without resending the old request",
         ctx do
      join!(ctx.w.profile.space_id, :agent, ctx.w.agent.id)

      runtime =
        Repo.insert!(%Platform.Agents.AgentRuntime{
          runtime_id: "replacement-#{unique()}",
          agent_id: ctx.w.agent.id,
          owner_user_id: ctx.w.approver.id,
          status: "active"
        })

      {:ok, _} =
        Platform.Access.RuntimeProfiles.create_for_runtime(runtime, ["social", "files"], nil)

      attrs = %{
        request_id: Ecto.UUID.generate(),
        base_render_id: ctx.base.id,
        assignee: {:agent, ctx.w.agent.id},
        note: "Earlier instruction"
      }

      {:ok, %{request: old}} = request(ctx.w, ctx.clip, attrs)
      # Stored crash boundaries, not a claim that the original wake was absent.
      Repo.update!(Ecto.Changeset.change(old, notification_status: unquote(status)))
      before_count = Repo.aggregate(Platform.Chat.Message, :count)

      replacement =
        attrs
        |> Map.put(:request_id, Ecto.UUID.generate())
        |> Map.put(:replaces_request_id, old.id)
        |> Map.put(:note, "Replacement instruction")

      assert {:ok, %{request: newer, notification: :sent}} = request(ctx.w, ctx.clip, replacement)
      assert newer.id != old.id
      assert Repo.aggregate(Platform.Chat.Message, :count) == before_count + 1
      retained = Repo.get!(Platform.Social.ClipEditRequest, old.id)
      assert retained.notification_status == unquote(status)
      assert retained.notification_attempted_at == old.notification_attempted_at
      assert retained.notification_message_id == old.notification_message_id
      assert {:ok, %{request: replay}} = request(ctx.w, ctx.clip, attrs)
      assert replay.id == old.id
      assert Repo.aggregate(Platform.Chat.Message, :count) == before_count + 1
      assert Repo.get!(Platform.Social.ClipEditRequest, old.id) == retained

      output = stored_file!(ctx.w.project, "not read", "return.mp4", "video/mp4")

      {:ok, id} =
        Social.ClipRevisionContract.submission_id(
          old.id,
          ctx.clip.id,
          ctx.base.id,
          output.content_hash
        )

      assert {:error, :request_not_open} =
               Social.ClipRevisions.append_version(
                 ctx.w.scope,
                 ctx.clip.id,
                 {:agent, ctx.w.agent.id, runtime.runtime_id},
                 %{
                   file_id: output.id,
                   request_id: old.id,
                   base_render_id: ctx.base.id,
                   submission_id: id,
                   sha256: output.content_hash,
                   byte_size: output.byte_size,
                   duration_s: 1.0,
                   width: 10,
                   height: 10
                 }
               )

      assert Repo.get!(Clip, ctx.clip.id).rev == ctx.clip.rev
      assert Social.ClipRevisions.latest(ctx.clip.id).id == newer.id
    end
  end

  test "revoked preparer authority cannot replay a request receipt", ctx do
    %{w: w, clip: clip, base: base} = ctx

    attrs = %{
      base_render_id: base.id,
      assignee: :self,
      note: "Edit",
      request_id: Ecto.UUID.generate()
    }

    assert {:ok, _} = request(w, clip, attrs)
    Repo.update!(Ecto.Changeset.change(w.profile, approver_user_ids: []))
    assert {:error, :not_an_approver} = request(w, clip, attrs)
  end
end
