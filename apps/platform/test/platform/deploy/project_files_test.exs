defmodule Platform.Deploy.ProjectFilesTest do
  @moduledoc """
  Coverage for `Platform.Deploy.ProjectFiles.execute/2` (task 019f5e66).

  Stage 4 pinned the happy path, version-collision behavior, and the
  deploy_target_config/no-canvas failure paths. Stage 5 adds the
  cross-tenant guard + audit telemetry: happy path fires `:deployed`,
  workspace mismatch fires `:cross_tenant_rejected` and short-circuits
  before any bytes are uploaded.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Deploy.ProjectFiles
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stage, Validation}

  # Override `chat_attachments_root` to a per-module tmp dir so this file's
  # blobs are isolated from the shared per-run root `test.exs` configures.
  setup do
    root =
      Platform.TestTemp.path("platform-deploy-project-files-test")

    File.mkdir_p!(root)

    previous_root = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous_root,
        do: Application.put_env(:platform, :chat_attachments_root, previous_root),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    :ok
  end

  # ── Fixtures ────────────────────────────────────────────────────────

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp project(overrides) do
    attrs = Map.merge(%{name: unique("proj-src")}, overrides)
    {:ok, project} = Tasks.create_project(attrs)
    project
  end

  defp task_with_config(source_project, config) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: source_project.id,
        title: "Deploy files task",
        deploy_strategy: %{"type" => "project_files"},
        deploy_target_config: config
      })

    Tasks.ensure_project_loaded(task)
  end

  defp execution_space_for(task) do
    {:ok, space} = ExecutionSpace.find_or_create(task.id)
    space
  end

  defp add_agent(space_id) do
    agent_id = Ecto.UUID.generate()

    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: agent_id,
        display_name: "TestAgent",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp create_canvas(space, title, root) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => add_agent(space.id).id,
        "title" => title,
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => root
        }
      })

    canvas
  end

  defp sample_root(text \\ "Hello world.") do
    %{
      "id" => "root",
      "type" => "stack",
      "props" => %{"gap" => 12},
      "children" => [
        %{
          "id" => "h",
          "type" => "heading",
          "props" => %{"level" => 1, "value" => "Doc"}
        },
        %{
          "id" => "m",
          "type" => "markdown",
          "props" => %{"content" => text}
        }
      ]
    }
  end

  defp deploy_stage_for(task) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Deploy: Project files",
        description: "auto-injected for tests"
      })

    {:ok, running} = PlanEngine.start_stage(stage.id)

    {:ok, _validation} =
      Tasks.create_validation(%{stage_id: running.id, kind: "test_pass"})

    running
  end

  defp read_attachment_bytes(%Attachment{storage_key: key}) do
    path = LocalDisk.path_for(key)
    File.read!(path)
  end

  defp attachments_in_space(space_id) do
    from(a in Attachment, where: a.space_id == ^space_id, order_by: [asc: a.inserted_at])
    |> Repo.all()
  end

  defp fetch_validation(stage_id, kind) do
    from(v in Validation, where: v.stage_id == ^stage_id and v.kind == ^kind, limit: 1)
    |> Repo.one()
  end

  defp refetch_stage(stage_id), do: Repo.get!(Stage, stage_id)

  # Attach a telemetry listener that forwards the given event names to
  # the test process as `{:telemetry, event, measurements, metadata}`
  # tuples. Detached automatically on exit.
  defp attach_telemetry(events) do
    handler_id = "project-files-telemetry-#{System.unique_integer([:positive, :monotonic])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  # ── Happy path ──────────────────────────────────────────────────────

  describe "execute/2 — happy path with explicit deliverable_canvas_id" do
    setup do
      source = project(%{name: unique("src")})
      target = project(%{name: unique("tgt")})

      exec_space = execution_space_for(%{id: Ecto.UUID.generate()})
      canvas = create_canvas(exec_space, "Deploy Deliverable", sample_root("Hello."))

      task =
        task_with_config(source, %{
          "strategy" => "project_files",
          "project_id" => target.id,
          "folder" => "Deliverables",
          "deliverable_canvas_id" => canvas.id
        })

      deploy_stage = deploy_stage_for(task)

      %{
        source: source,
        target: target,
        canvas: canvas,
        task: task,
        deploy_stage: deploy_stage
      }
    end

    test "lands a chat_attachments row with the exported Markdown", ctx do
      assert {:ok, result} = ProjectFiles.execute(ctx.task, ctx.deploy_stage)

      assert result.filename == "Deliverables/deploy-deliverable.md"
      assert is_binary(result.attachment_id)
      assert is_nil(result.previous_attachment_id)

      attachment = Chat.get_attachment(result.attachment_id)
      assert attachment.content_type == "text/markdown"
      assert attachment.state == "ready"
      assert attachment.filename == "Deliverables/deploy-deliverable.md"

      bytes = read_attachment_bytes(attachment)
      assert bytes =~ "# Doc"
      assert bytes =~ "Hello."

      assert attachment.metadata["folder"] == "Deliverables"
      assert attachment.metadata["source_task_id"] == ctx.task.id
      assert attachment.metadata["canvas_id"] == ctx.canvas.id
      assert attachment.metadata["deploy_strategy"] == "project_files"
    end

    test "creates the target files space with the expected slug", ctx do
      assert {:ok, _} = ProjectFiles.execute(ctx.task, ctx.deploy_stage)

      space = Chat.get_space_by_slug("project-files-#{ctx.target.slug}")
      assert space
      assert space.kind == "channel"
      assert space.workspace_id == ctx.target.workspace_id
      assert space.metadata["project_id"] == ctx.target.id
    end

    test "records the deploy stage's test_pass validation as passed", ctx do
      assert {:ok, result} = ProjectFiles.execute(ctx.task, ctx.deploy_stage)

      v = fetch_validation(ctx.deploy_stage.id, "test_pass")
      assert v.status == "passed"
      assert v.evaluated_by == "platform.deploy.project_files"
      assert v.evidence["deployed_attachment_id"] == result.attachment_id
      assert v.evidence["deployed_filename"] == "Deliverables/deploy-deliverable.md"
      assert v.evidence["source_task_id"] == ctx.task.id
      assert v.evidence["target_project_id"] == ctx.target.id
      assert v.evidence["canvas_id"] == ctx.canvas.id
      refute Map.has_key?(v.evidence, "previous_attachment_id")

      # Stage auto-advances to passed because test_pass is its sole validation.
      assert refetch_stage(ctx.deploy_stage.id).status == "passed"
    end
  end

  # ── Fallback path ──────────────────────────────────────────────────

  describe "execute/2 — fallback to execution-space newest canvas" do
    test "picks the newest canvas from the source task's execution space when no deliverable_canvas_id" do
      source = project(%{name: unique("src-fb")})
      target = project(%{name: unique("tgt-fb")})

      task =
        task_with_config(source, %{
          "strategy" => "project_files",
          "project_id" => target.id,
          "folder" => "Deliverables"
        })

      # Seed the exec space with two canvases; expect the newer one to win.
      exec_space = execution_space_for(task)
      _older = create_canvas(exec_space, "Older", sample_root("Old content."))
      # Force a monotonic separation so the older is unambiguously older.
      Process.sleep(5)
      newer = create_canvas(exec_space, "Newer", sample_root("Fresh content."))

      deploy_stage = deploy_stage_for(task)

      assert {:ok, result} = ProjectFiles.execute(task, deploy_stage)
      assert result.filename == "Deliverables/newer.md"

      attachment = Chat.get_attachment(result.attachment_id)
      bytes = read_attachment_bytes(attachment)
      assert bytes =~ "Fresh content."
      assert attachment.metadata["canvas_id"] == newer.id
    end
  end

  # ── Failure paths ──────────────────────────────────────────────────

  describe "execute/2 — no deliverable canvas" do
    test "returns {:error, :no_deliverable_canvas} and fails the validation when exec space has no canvases" do
      source = project(%{name: unique("src-empty")})
      target = project(%{name: unique("tgt-empty")})

      task =
        task_with_config(source, %{
          "strategy" => "project_files",
          "project_id" => target.id,
          "folder" => "Deliverables"
        })

      # Create the exec space but do NOT put any canvases in it.
      _ = execution_space_for(task)
      deploy_stage = deploy_stage_for(task)

      assert {:error, :no_deliverable_canvas} = ProjectFiles.execute(task, deploy_stage)

      v = fetch_validation(deploy_stage.id, "test_pass")
      assert v.status == "failed"
      assert v.evidence["reason"] == "no_deliverable_canvas"
      assert v.evidence["source_task_id"] == task.id

      # Zero attachments landed anywhere for the target project.
      target_space = Chat.get_space_by_slug("project-files-#{target.slug}")
      # Space may not have been created because we short-circuit before space
      # resolution; either nil or an empty attachments list is acceptable.
      case target_space do
        nil -> :ok
        %{id: id} -> assert attachments_in_space(id) == []
      end
    end
  end

  describe "execute/2 — invalid deploy_target_config" do
    test "non-project_files strategy returns {:error, :invalid_deploy_target_config}" do
      source = project(%{name: unique("src-bad")})
      target = project(%{name: unique("tgt-bad")})

      # A task whose deploy_target_config was set for a different strategy
      # should not be processed by the project_files handler if it's mistakenly
      # routed here (defense in depth against future dispatch bugs).
      task =
        task_with_config(source, %{
          "strategy" => "docker_deploy",
          "project_id" => target.id
        })

      deploy_stage = deploy_stage_for(task)

      assert {:error, :invalid_deploy_target_config} =
               ProjectFiles.execute(task, deploy_stage)

      v = fetch_validation(deploy_stage.id, "test_pass")
      assert v.status == "failed"
      assert v.evidence["reason"] == "invalid_deploy_target_config"

      # No target space, no attachment.
      target_space = Chat.get_space_by_slug("project-files-#{target.slug}")
      assert is_nil(target_space)
    end

    test "missing project_id returns {:error, :invalid_deploy_target_config}" do
      source = project(%{name: unique("src-bad2")})

      task =
        task_with_config(source, %{
          "strategy" => "project_files",
          "folder" => "Deliverables"
        })

      deploy_stage = deploy_stage_for(task)

      assert {:error, :invalid_deploy_target_config} =
               ProjectFiles.execute(task, deploy_stage)

      v = fetch_validation(deploy_stage.id, "test_pass")
      assert v.status == "failed"
    end

    test "nil deploy_target_config returns {:error, :invalid_deploy_target_config}" do
      source = project(%{name: unique("src-bad3")})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: source.id,
          title: "Task with no deploy config"
        })

      task = Tasks.ensure_project_loaded(task)
      deploy_stage = deploy_stage_for(task)

      assert {:error, :invalid_deploy_target_config} =
               ProjectFiles.execute(task, deploy_stage)

      v = fetch_validation(deploy_stage.id, "test_pass")
      assert v.status == "failed"
      assert v.evidence["reason"] == "invalid_deploy_target_config"
    end
  end

  describe "execute/2 — target project missing" do
    test "returns {:error, :target_project_not_found} when project_id doesn't resolve" do
      source = project(%{name: unique("src-tp")})

      exec_space = execution_space_for(%{id: Ecto.UUID.generate()})
      canvas = create_canvas(exec_space, "Whatever", sample_root())

      task =
        task_with_config(source, %{
          "strategy" => "project_files",
          "project_id" => Ecto.UUID.generate(),
          "deliverable_canvas_id" => canvas.id
        })

      deploy_stage = deploy_stage_for(task)

      assert {:error, :target_project_not_found} = ProjectFiles.execute(task, deploy_stage)

      v = fetch_validation(deploy_stage.id, "test_pass")
      assert v.status == "failed"
      assert v.evidence["reason"] == "target_project_not_found"
    end
  end

  # ── Plan-engine wiring ─────────────────────────────────────────────

  describe "plan-engine wiring" do
    test "PlanEngine auto-injects the deploy stage and dispatches project_files" do
      source = project(%{name: unique("src-wire")})
      target = project(%{name: unique("tgt-wire")})

      exec_space = execution_space_for(%{id: Ecto.UUID.generate()})
      canvas = create_canvas(exec_space, "Wired Doc", sample_root("Wired body."))

      {:ok, task} =
        Tasks.create_task(%{
          project_id: source.id,
          title: "Auto-injected project_files task",
          status: "in_review",
          # `require_deploy_target_for/2` still gates on the legacy
          # string until the follow-up migration lands. Give it a value
          # so the transition to `deploying` can proceed.
          deploy_target: "project_files",
          deploy_strategy: %{"type" => "project_files"},
          deploy_target_config: %{
            "strategy" => "project_files",
            "project_id" => target.id,
            "folder" => "Deliverables",
            "deliverable_canvas_id" => canvas.id
          }
        })

      # A single implementation stage so the plan engine has something
      # to advance from → into the deploy-injection branch.
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, plan_after} = PlanEngine.advance(plan.id)

      deploy_stage =
        Enum.find(plan_after.stages, &String.starts_with?(&1.name, "Deploy:"))

      assert deploy_stage != nil, "expected a deploy stage to be injected"
      assert deploy_stage.name == "Deploy: Project files"

      # The dispatch handler evaluated the test_pass validation, which
      # auto-advanced the deploy stage to passed and completed the plan.
      assert refetch_stage(deploy_stage.id).status == "passed"

      target_space = Chat.get_space_by_slug("project-files-#{target.slug}")
      assert target_space
      [attachment] = attachments_in_space(target_space.id)
      assert attachment.filename == "Deliverables/wired-doc.md"
      assert attachment.metadata["source_task_id"] == task.id
      assert read_attachment_bytes(attachment) =~ "Wired body."

      # And the task moved through deploying to done because the plan
      # completed cleanly.
      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status in ["deploying", "done"]
    end
  end

  # ── Cross-tenant guard + audit telemetry (stage 5) ─────────────────

  describe "execute/2 — cross-tenant guard" do
    test "same workspace lands the deploy and emits :deployed telemetry" do
      workspace_id = Ecto.UUID.generate()
      source = project(%{name: unique("src-same"), workspace_id: workspace_id})
      target = project(%{name: unique("tgt-same"), workspace_id: workspace_id})

      exec_space = execution_space_for(%{id: Ecto.UUID.generate()})
      canvas = create_canvas(exec_space, "Same Workspace Doc", sample_root("Body."))

      task =
        task_with_config(source, %{
          "strategy" => "project_files",
          "project_id" => target.id,
          "folder" => "Deliverables",
          "deliverable_canvas_id" => canvas.id
        })

      deploy_stage = deploy_stage_for(task)

      attach_telemetry([
        [:platform, :deploy, :project_files, :deployed],
        [:platform, :deploy, :project_files, :cross_tenant_rejected]
      ])

      assert {:ok, result} = ProjectFiles.execute(task, deploy_stage)

      assert_receive {:telemetry, [:platform, :deploy, :project_files, :deployed], _measurements,
                      metadata}

      assert metadata.actor_type == "system"
      assert metadata.action == "deployed"
      assert metadata.resource_type == "chat_attachment"
      assert metadata.resource_id == result.attachment_id
      assert metadata.source_task_id == task.id
      assert metadata.target_project_id == target.id
      assert metadata.folder == "Deliverables"
      assert metadata.filename == "Deliverables/same-workspace-doc.md"
      assert metadata.version_id == result.attachment_id

      # No cross-tenant event fired on the happy path.
      refute_received {:telemetry, [:platform, :deploy, :project_files, :cross_tenant_rejected],
                       _, _}
    end

    test "workspace mismatch rejects the deploy, emits :cross_tenant_rejected, and uploads nothing" do
      source_workspace = Ecto.UUID.generate()
      target_workspace = Ecto.UUID.generate()

      source = project(%{name: unique("src-xten"), workspace_id: source_workspace})
      target = project(%{name: unique("tgt-xten"), workspace_id: target_workspace})

      exec_space = execution_space_for(%{id: Ecto.UUID.generate()})
      canvas = create_canvas(exec_space, "Blocked Doc", sample_root("Should not land."))

      task =
        task_with_config(source, %{
          "strategy" => "project_files",
          "project_id" => target.id,
          "folder" => "Deliverables",
          "deliverable_canvas_id" => canvas.id
        })

      deploy_stage = deploy_stage_for(task)

      attach_telemetry([
        [:platform, :deploy, :project_files, :deployed],
        [:platform, :deploy, :project_files, :cross_tenant_rejected]
      ])

      assert {:error, :cross_tenant_rejected} = ProjectFiles.execute(task, deploy_stage)

      assert_receive {:telemetry, [:platform, :deploy, :project_files, :cross_tenant_rejected],
                      _measurements, metadata}

      assert metadata.actor_type == "system"
      assert metadata.action == "cross_tenant_rejected"
      assert metadata.resource_type == "project"
      assert metadata.resource_id == target.id
      assert metadata.source_task_id == task.id
      assert metadata.target_project_id == target.id
      assert metadata.source_workspace_id == source_workspace
      assert metadata.target_workspace_id == target_workspace

      # And no :deployed event fired.
      refute_received {:telemetry, [:platform, :deploy, :project_files, :deployed], _, _}

      # The target files space was NEVER created — the guard runs before
      # resolve_or_create_target_space/1, so no chat_attachments row and
      # no auto-created channel leaked into the target workspace.
      assert is_nil(Chat.get_space_by_slug("project-files-#{target.slug}"))

      # And the validation was recorded as failed with the reason.
      v = fetch_validation(deploy_stage.id, "test_pass")
      assert v.status == "failed"
      assert v.evidence["reason"] == "cross_tenant_rejected"
      assert v.evidence["source_task_id"] == task.id
    end

    test "both workspace_ids nil is treated as same workspace (legacy pre-MT projects)" do
      # Legacy projects created before the workspace_id column was
      # populated carry nil workspace_id. Two such projects should still
      # be permitted to interoperate — the guard is pair-equality, not
      # "must be non-nil".
      source = project(%{name: unique("src-nil")})
      target = project(%{name: unique("tgt-nil")})

      assert is_nil(source.workspace_id)
      assert is_nil(target.workspace_id)

      exec_space = execution_space_for(%{id: Ecto.UUID.generate()})
      canvas = create_canvas(exec_space, "Legacy Doc", sample_root("Body."))

      task =
        task_with_config(source, %{
          "strategy" => "project_files",
          "project_id" => target.id,
          "deliverable_canvas_id" => canvas.id
        })

      deploy_stage = deploy_stage_for(task)

      attach_telemetry([
        [:platform, :deploy, :project_files, :deployed],
        [:platform, :deploy, :project_files, :cross_tenant_rejected]
      ])

      assert {:ok, _} = ProjectFiles.execute(task, deploy_stage)

      assert_receive {:telemetry, [:platform, :deploy, :project_files, :deployed], _, _}

      refute_received {:telemetry, [:platform, :deploy, :project_files, :cross_tenant_rejected],
                       _, _}
    end
  end

  # ── Versioning ─────────────────────────────────────────────────────

  describe "execute/2 — version collision" do
    test "second run renames the previous canonical row into versions/ and inserts a fresh one" do
      source = project(%{name: unique("src-ver")})
      target = project(%{name: unique("tgt-ver")})

      exec_space = execution_space_for(%{id: Ecto.UUID.generate()})
      canvas_v1 = create_canvas(exec_space, "Redeploy Doc", sample_root("First take."))

      task =
        task_with_config(source, %{
          "strategy" => "project_files",
          "project_id" => target.id,
          "folder" => "Deliverables",
          "deliverable_canvas_id" => canvas_v1.id
        })

      stage_a = deploy_stage_for(task)
      assert {:ok, first} = ProjectFiles.execute(task, stage_a)

      # Simulate an updated deliverable — same canvas title, fresher content.
      # We re-use the same canvas row with an updated document via patch since
      # the canonical filename is title-derived; the second run should rotate
      # the first row into versions/ and land a new canonical row.
      canvas_v1_reloaded = Chat.get_canvas(canvas_v1.id)

      updated_doc = %{
        canvas_v1_reloaded.document
        | "revision" => canvas_v1_reloaded.document["revision"] + 1,
          "root" => sample_root("Second take.")
      }

      {:ok, _} = Chat.update_canvas(:system, canvas_v1_reloaded, %{document: updated_doc})

      stage_b = deploy_stage_for(task)
      assert {:ok, second} = ProjectFiles.execute(task, stage_b)

      assert second.previous_attachment_id == first.attachment_id
      assert second.filename == "Deliverables/redeploy-doc.md"

      # Fetch all attachments in the target space and inspect them.
      target_space = Chat.get_space_by_slug("project-files-#{target.slug}")
      rows = attachments_in_space(target_space.id)
      assert length(rows) == 2

      canonical = Enum.find(rows, &(&1.filename == "Deliverables/redeploy-doc.md"))
      assert canonical
      assert read_attachment_bytes(canonical) =~ "Second take."

      versioned =
        Enum.find(rows, fn a ->
          String.starts_with?(a.filename, "Deliverables/versions/redeploy-doc-")
        end)

      assert versioned
      assert String.ends_with?(versioned.filename, ".md")
      # The renamed row still points at the original bytes.
      assert read_attachment_bytes(versioned) =~ "First take."

      # Success evidence carries the previous_attachment_id on redeploys.
      v = fetch_validation(stage_b.id, "test_pass")
      assert v.evidence["previous_attachment_id"] == first.attachment_id
    end
  end
end
