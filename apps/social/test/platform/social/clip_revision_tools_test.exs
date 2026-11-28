defmodule Platform.Social.ClipRevisionToolsTest do
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  alias Platform.Repo
  alias Platform.Federation.ToolArguments

  alias Platform.Social.{
    AgentDrafts,
    Clip,
    ClipEditRequest,
    ClipJob,
    ClipRender,
    ClipRevisionContract,
    ClipRevisions,
    Post,
    ToolDefinitions,
    Tools
  }

  setup do
    w = render_world!()
    join!(w.profile.space_id, :agent, w.agent.id)
    runtime = runtime!(w.agent, w.approver)
    base_file = stored_file!(w.project, "original #{unique()}", "original.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => base_file.id,
          "title" => "Working title",
          "caption" => "Working caption",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    base = Repo.get_by!(ClipRender, clip_id: clip.id, rev: clip.rev)

    {:ok, %{request: request}} =
      ClipRevisions.request_edit(w.scope, clip.id, w.approver.id, %{
        request_id: Ecto.UUID.generate(),
        base_render_id: base.id,
        assignee: {:agent, w.agent.id},
        note: "Remove the long pause"
      })

    file =
      stored_file!(
        w.project,
        File.read!(Path.expand("../../support/fixtures/episode_pipeline/one.mp4", __DIR__)),
        "returned.mp4",
        "video/mp4"
      )

    {:ok, submission_id} =
      ClipRevisionContract.submission_id(request.id, clip.id, base.id, file.content_hash)

    args = %{
      "clip_id" => clip.id,
      "file_id" => file.id,
      "request_id" => request.id,
      "base_render_id" => base.id,
      "submission_id" => submission_id,
      "output" => %{
        "sha256" => file.content_hash,
        "bytes" => file.byte_size,
        "duration_s" => 28.0,
        "width" => 1080,
        "height" => 1920
      }
    }

    %{
      w: w,
      runtime: runtime,
      clip: clip,
      base: base,
      request: request,
      output_file: file,
      args: args,
      ctx: %{agent_id: w.agent.id, runtime_id: runtime.runtime_id}
    }
  end

  test "assigned active runtime discovers and reads only the explicit request receipt", c do
    for name <-
          ~w(social_clip_edit_request_list social_clip_edit_request_get social_clip_version_append) do
      assert name in ToolDefinitions.names()
      assert Enum.any?(ToolDefinitions.definitions(), &(&1.name == name))
    end

    assert {:ok, %{requests: [listed], total: 1}} =
             Tools.execute("social_clip_edit_request_list", %{}, c.ctx)

    assert listed.id == c.request.id
    assert listed.note == "Remove the long pause"
    assert listed.assigned_agent_id == c.w.agent.id
    assert listed.base_render_id == c.base.id
    assert listed.current_render_id == c.base.id
    assert listed.returned_render_id == nil
    assert listed.awaiting?
    assert listed.notification_status == "sent"

    assert {:ok, %{request: ^listed}} =
             Tools.execute("social_clip_edit_request_get", %{"request_id" => c.request.id}, c.ctx)

    for key <- [:__meta__, :request_payload_hash, :storage_key, :source, :transcript, :url] do
      refute Map.has_key?(listed, key)
    end
  end

  test "append returns a same-clip receipt without changing copy, posts, jobs or assignment", c do
    before = Repo.get!(Clip, c.clip.id)
    jobs = Repo.aggregate(ClipJob, :count)

    assert {:ok, %{render: render, duplicate?: false}} =
             ToolArguments.dispatch("social_clip_version_append", c.args, c.ctx)

    assert render.clip_id == before.id
    assert render.file_id == c.output_file.id
    assert render.rev == before.rev + 1
    after_clip = Repo.get!(Clip, before.id)
    assert after_clip.title == before.title
    assert after_clip.caption == before.caption
    assert after_clip.review_status == "pending"
    assert Repo.get!(ClipEditRequest, c.request.id).assigned_agent_id == c.w.agent.id
    assert Repo.all(Post) == []
    assert Repo.aggregate(ClipJob, :count) == jobs
    refute Map.has_key?(render, :provenance)
    refute Map.has_key?(render, :source)

    assert {:ok, %{render: replay, duplicate?: true}} =
             Tools.execute("social_clip_version_append", c.args, c.ctx)

    assert replay.id == render.id

    assert {:ok, %{request: request}} =
             Tools.execute("social_clip_edit_request_get", %{"request_id" => c.request.id}, c.ctx)

    assert request.returned_render_id == render.id
    assert request.current_render_id == render.id
    refute request.awaiting?
  end

  test "client-supplied actor and runtime cannot replace the trusted execution runtime", c do
    forged = %{
      "request_id" => c.request.id,
      "runtime_id" => c.runtime.runtime_id,
      "actor" => c.w.agent.id
    }

    assert {:error, %{code: :unauthorized}} =
             Tools.execute("social_clip_edit_request_get", forged, %{agent_id: c.w.agent.id})

    other = pinned_agent!(c.w.org_id)
    other_runtime = runtime!(other, c.w.approver)
    context = %{agent_id: other.id, runtime_id: other_runtime.runtime_id}

    assert {:error, %{code: :unauthorized}} =
             Tools.execute("social_clip_edit_request_get", forged, context)

    assert {:ok, %{requests: [], total: 0}} =
             Tools.execute("social_clip_edit_request_list", %{}, context)

    assert {:error, %{code: :unauthorized}} =
             Tools.execute("social_clip_version_append", c.args, context)

    assert Repo.get!(Clip, c.clip.id).rev == c.clip.rev
  end

  test "the generic clip list cannot bypass the editing-request note read boundary", c do
    other = pinned_agent!(c.w.org_id)
    runtime = runtime!(other, c.w.approver)
    context = %{agent_id: other.id, runtime_id: runtime.runtime_id}

    assert {:error, %{code: :unauthorized}} =
             Tools.execute(
               "social_clip_edit_request_get",
               %{"request_id" => c.request.id},
               context
             )

    assert {:ok, %{clips: [listed]}} =
             Tools.execute("social_clip_list", %{"profile_id" => c.w.profile.id}, context)

    assert listed.review_note == nil

    assert {:ok, %{request: readable}} =
             Tools.execute("social_clip_edit_request_get", %{"request_id" => c.request.id}, c.ctx)

    assert readable.note == c.request.note

    assert {:ok, _} =
             Platform.Social.ClipDecisions.undo_clip_decision(
               c.w.org_id,
               c.clip.id,
               c.w.approver.id
             )

    assert {:ok, _} =
             Platform.Social.ClipDecisions.reject_clip(
               c.w.org_id,
               c.clip.id,
               c.w.approver.id,
               "Ordinary rejection"
             )

    assert {:ok, %{clips: [ordinary]}} =
             Tools.execute("social_clip_list", %{"profile_id" => c.w.profile.id}, context)

    assert ordinary.review_note == "Ordinary rejection"
  end

  test "revocation refuses reads and immutable receipt replay without leaking the old receipt",
       c do
    assert {:ok, _} = Tools.execute("social_clip_version_append", c.args, c.ctx)
    Repo.update!(Ecto.Changeset.change(c.runtime, status: "revoked"))

    for {name, args} <- [
          {"social_clip_edit_request_list", %{}},
          {"social_clip_edit_request_get", %{"request_id" => c.request.id}},
          {"social_clip_version_append", c.args}
        ] do
      assert {:error, %{code: :unauthorized} = error} = Tools.execute(name, args, c.ctx)
      refute Map.has_key?(error, :request)
      refute Map.has_key?(error, :render)
      refute inspect(error) =~ "Remove the long pause"
    end
  end

  test "append forwards unsupported fields to strict validation rather than silently dropping them",
       c do
    assert {:error, %{code: :field_not_allowed}} =
             Tools.execute(
               "social_clip_version_append",
               Map.put(c.args, "title", "Forged title"),
               c.ctx
             )

    assert Repo.get!(Clip, c.clip.id).rev == c.clip.rev
    assert Repo.get!(ClipEditRequest, c.request.id).returned_render_id == nil
  end

  defp runtime!(agent, owner) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "clip-revision-tools-#{unique()}",
        agent_id: agent.id,
        owner_user_id: owner.id,
        status: "active"
      })

    {:ok, _} =
      Platform.Access.RuntimeProfiles.create_for_runtime(runtime, ["social", "files"], nil)

    runtime
  end
end
