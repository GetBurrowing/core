defmodule Platform.Deploy.ProjectFiles do
  @moduledoc """
  Deploy handler for the `project_files` strategy (task 019f5e66 stage 4).

  Exports a task's deliverable canvas to Markdown and lands it as a
  `chat_attachments` row inside the target project's files space.

  ## v1 storage shim

  This handler uses `chat_attachments` as the storage backing rather
  than a dedicated `project_files` table. Files are anchored to a
  well-known channel per project, slug `"project-files-<project.slug>"`,
  auto-created on first deploy. The file's folder path is encoded in
  the attachment's `filename` (`"<folder>/<name>.md"`), so folder-scoped
  listing is a plain `filename LIKE 'Deliverables/%'` query and the
  existing attachment ACL applies.

  A proper `project_files` table (with folder as a first-class column
  and its own ACL) is a follow-up. Do NOT expand the shim beyond this
  handler — new callers should wait for the real schema.

  ## Contract

  `execute/2` NEVER raises and NEVER returns a value that
  `Platform.Deploy.dispatch/3` has to inspect. Every terminal outcome
  either evaluates the stage's `test_pass` validation via
  `PlanEngine.evaluate_validation/2` (success or handled failure) or
  is logged + swallowed by the caller.

  ## Versioning

  When a canonical row (`<folder>/<name>.md`) already exists in the
  target space, the old row's `filename` is renamed to
  `<folder>/versions/<name>-<old_inserted_at ISO8601>.md` before the
  fresh row is inserted. The renamed row keeps its `storage_key` — the
  underlying bytes are unchanged; only the metadata pointer moves.

  ## Cross-tenant guard (stage 5)

  Before any bytes land, the handler asserts that
  `source_task.project.workspace_id == target_project.workspace_id`. A
  mismatch short-circuits with `{:error, :cross_tenant_rejected}` and
  emits `[:platform, :deploy, :project_files, :cross_tenant_rejected]`
  so `Platform.Audit.TelemetryHandler` records the attempt in
  `audit_events`. The success path emits the mirror event
  `[:platform, :deploy, :project_files, :deployed]`.

  `workspace_id` is the current tenant key. A follow-up (TODO(mt-rbac))
  will replace this pair-equality check with the RBAC-scoped grants
  from the multi-tenant roadmap once the schema exists — for now
  workspace-parity is the strongest guarantee the schema affords.
  """

  import Ecto.Query

  require Logger

  alias Platform.Chat
  alias Platform.Chat.{Attachment, Canvas, Space}
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stage, Task, Validation}

  @default_folder "Deliverables"

  @type execute_error ::
          :invalid_deploy_target_config
          | :no_deliverable_canvas
          | :target_project_not_found
          | :cross_tenant_rejected
          | :export_failed
          | :persist_failed
          | :attachment_insert_failed
          | :test_pass_validation_missing

  @type execute_ok :: %{
          attachment_id: binary(),
          filename: String.t(),
          previous_attachment_id: binary() | nil
        }

  @doc """
  Execute a project-files deploy for `task` and record the outcome on
  `deploy_stage`'s `test_pass` validation.

  Returns `{:ok, execute_ok}` for the caller-testable happy path, or
  `{:error, reason}` for a handled failure. Both branches evaluate the
  validation before returning — no callers should evaluate on our
  behalf.
  """
  @spec execute(Task.t(), Stage.t()) :: {:ok, execute_ok()} | {:error, execute_error()}
  def execute(%Task{} = task, %Stage{} = deploy_stage) do
    task = Tasks.ensure_project_loaded(task)

    with {:ok, config} <- read_config(task),
         {:ok, canvas} <- resolve_canvas(task, config),
         {:ok, md} <- export_markdown(canvas),
         {:ok, target_project} <- resolve_target_project(config),
         :ok <- ensure_same_workspace(task, target_project),
         {:ok, target_space} <- resolve_or_create_target_space(target_project),
         folder <- Map.get(config, "folder", @default_folder),
         canonical_filename <- canonical_filename(canvas, folder),
         {:ok, previous_id} <-
           rotate_previous_version(target_space.id, canonical_filename, folder),
         {:ok, attachment} <-
           persist_attachment(md, target_space, canvas, task, folder, canonical_filename) do
      report_success(deploy_stage, attachment, canvas, task, target_project, previous_id)
      emit_deployed(task, target_project, folder, attachment)

      {:ok,
       %{
         attachment_id: attachment.id,
         filename: attachment.filename,
         previous_attachment_id: previous_id
       }}
    else
      {:error, reason} = err ->
        report_failure(deploy_stage, reason, task)
        err
    end
  end

  # ── Cross-tenant guard ──────────────────────────────────────────────

  # TODO(mt-rbac): once RBAC-scoped grants land, replace the
  # workspace-parity check with a permission lookup against the actor
  # (currently system) + the target project's grant set. Workspace_id
  # is the strongest tenant boundary the schema exposes today.
  defp ensure_same_workspace(
         %Task{project: %Platform.Tasks.Project{} = src} = task,
         %Platform.Tasks.Project{} = tgt
       ) do
    if src.workspace_id == tgt.workspace_id do
      :ok
    else
      emit_cross_tenant_rejected(task, src, tgt)
      {:error, :cross_tenant_rejected}
    end
  end

  defp ensure_same_workspace(%Task{project: nil} = task, %Platform.Tasks.Project{} = _tgt) do
    Logger.warning(
      "[Deploy.ProjectFiles] task #{task.id} has no loaded source project — cannot verify tenant parity"
    )

    {:error, :cross_tenant_rejected}
  end

  # ── Config resolution ────────────────────────────────────────────────

  defp read_config(%Task{deploy_target_config: %{"strategy" => "project_files"} = cfg}) do
    case Map.get(cfg, "project_id") do
      pid when is_binary(pid) and pid != "" ->
        {:ok, cfg}

      _ ->
        Logger.warning(
          "[Deploy.ProjectFiles] deploy_target_config missing project_id: #{inspect(cfg)}"
        )

        {:error, :invalid_deploy_target_config}
    end
  end

  defp read_config(%Task{deploy_target_config: cfg}) do
    Logger.warning(
      "[Deploy.ProjectFiles] deploy_target_config is not a project_files config: #{inspect(cfg)}"
    )

    {:error, :invalid_deploy_target_config}
  end

  # ── Canvas resolution ────────────────────────────────────────────────

  defp resolve_canvas(%Task{} = task, config) do
    case Map.get(config, "deliverable_canvas_id") do
      id when is_binary(id) and id != "" ->
        case Chat.get_canvas(id) do
          %Canvas{} = canvas -> {:ok, canvas}
          nil -> fallback_canvas(task)
        end

      _ ->
        fallback_canvas(task)
    end
  end

  defp fallback_canvas(%Task{} = task) do
    with %Space{id: space_id} <- ExecutionSpace.find_by_task_id(task.id),
         canvases when is_list(canvases) <- Chat.list_canvases(space_id),
         %Canvas{} = newest <- pick_newest(canvases) do
      {:ok, newest}
    else
      _ -> {:error, :no_deliverable_canvas}
    end
  end

  defp pick_newest([]), do: nil
  defp pick_newest(canvases), do: Enum.max_by(canvases, & &1.inserted_at, DateTime)

  # ── Markdown export ─────────────────────────────────────────────────

  defp export_markdown(%Canvas{} = canvas) do
    case Canvas.export_markdown(canvas) do
      {:ok, md} when is_binary(md) ->
        {:ok, md}

      other ->
        Logger.warning(
          "[Deploy.ProjectFiles] canvas #{canvas.id} export_markdown returned #{inspect(other)}"
        )

        {:error, :export_failed}
    end
  end

  # ── Target project + space ──────────────────────────────────────────

  defp resolve_target_project(config) do
    project_id = Map.fetch!(config, "project_id")

    case Tasks.get_project(project_id) do
      %Platform.Tasks.Project{} = project -> {:ok, project}
      nil -> {:error, :target_project_not_found}
    end
  end

  defp resolve_or_create_target_space(%Platform.Tasks.Project{} = project) do
    slug = target_space_slug(project)

    case find_existing_target_space(slug, project) do
      %Space{} = space ->
        {:ok, space}

      nil ->
        create_target_space(slug, project)
    end
  end

  defp find_existing_target_space(slug, %Platform.Tasks.Project{} = project) do
    # Prefer an org-scoped match when the project has an org_id, so we
    # don't cross tenants via the legacy (workspace_id, slug) index.
    query =
      case project.org_id do
        nil ->
          from(s in Space,
            where: s.slug == ^slug and is_nil(s.archived_at),
            limit: 1
          )

        org_id ->
          from(s in Space,
            where:
              s.slug == ^slug and s.org_id == ^org_id and
                is_nil(s.archived_at),
            limit: 1
          )
      end

    Repo.one(query)
  end

  defp create_target_space(slug, %Platform.Tasks.Project{} = project) do
    attrs = %{
      name: "Project files: #{project.name || project.slug}",
      slug: slug,
      kind: "channel",
      workspace_id: project.workspace_id,
      org_id: project.org_id,
      description:
        "Auto-created files space for project #{inspect(project.slug)} " <>
          "(project_files deploy strategy — v1 shim).",
      metadata: %{
        "purpose" => "project_files_deploy",
        "project_id" => project.id
      }
    }

    case Chat.create_space(attrs) do
      {:ok, space} ->
        {:ok, space}

      {:error, %Ecto.Changeset{}} ->
        # Race — a concurrent deploy created the same slug. Re-fetch.
        case find_existing_target_space(slug, project) do
          %Space{} = space -> {:ok, space}
          nil -> {:error, :target_space_unavailable}
        end
    end
  end

  defp target_space_slug(%Platform.Tasks.Project{slug: slug}) when is_binary(slug),
    do: "project-files-#{slug}"

  # ── Filename + versioning ───────────────────────────────────────────

  defp canonical_filename(%Canvas{} = canvas, folder) do
    base = canvas_slug(canvas)
    "#{folder}/#{base}.md"
  end

  defp canvas_slug(%Canvas{title: title}) when is_binary(title) and title != "" do
    slugify(title)
  end

  defp canvas_slug(%Canvas{id: id}), do: "canvas-#{String.slice(id, 0, 8)}"

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "untitled"
      slug -> slug
    end
  end

  # Returns `{:ok, previous_attachment_id_or_nil}`. Renames any ready
  # canonical row to `<folder>/versions/<name>-<iso>.md` before we
  # insert the fresh copy.
  defp rotate_previous_version(space_id, canonical_filename, folder) do
    case fetch_canonical_row(space_id, canonical_filename) do
      nil ->
        {:ok, nil}

      %Attachment{} = existing ->
        rotated = version_filename(existing, folder)

        case existing
             |> Attachment.changeset(%{filename: rotated})
             |> Repo.update() do
          {:ok, _updated} ->
            {:ok, existing.id}

          {:error, changeset} ->
            Logger.warning(
              "[Deploy.ProjectFiles] failed to rotate previous attachment #{existing.id}: " <>
                inspect(changeset.errors)
            )

            {:error, :attachment_insert_failed}
        end
    end
  end

  defp fetch_canonical_row(space_id, canonical_filename) do
    from(a in Attachment,
      where:
        a.space_id == ^space_id and a.filename == ^canonical_filename and
          a.state == "ready",
      limit: 1
    )
    |> Repo.one()
  end

  defp version_filename(%Attachment{filename: filename, inserted_at: inserted_at}, folder) do
    base_and_ext = Path.basename(filename)
    ext = Path.extname(base_and_ext)
    base = Path.rootname(base_and_ext)
    iso = DateTime.to_iso8601(inserted_at)
    "#{folder}/versions/#{base}-#{iso}#{ext}"
  end

  # ── Persist the fresh attachment ────────────────────────────────────

  defp persist_attachment(
         md,
         %Space{} = target_space,
         %Canvas{} = canvas,
         %Task{} = task,
         folder,
         canonical_filename
       ) do
    storage_key = fresh_storage_key(canonical_filename)

    case storage_adapter().persist(storage_key, {:binary, md}) do
      {:ok, %{byte_size: size, content_hash: hash}} ->
        attrs = %{
          space_id: target_space.id,
          filename: canonical_filename,
          content_type: "text/markdown",
          byte_size: size,
          storage_key: storage_key,
          content_hash: hash,
          state: "ready",
          metadata: %{
            "folder" => folder,
            "project_id" => target_space_project_id(target_space),
            "source_task_id" => task.id,
            "canvas_id" => canvas.id,
            "deployed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "deploy_strategy" => "project_files"
          }
        }

        case Chat.create_attachment(attrs) do
          {:ok, attachment} ->
            {:ok, attachment}

          {:error, reason} ->
            Logger.warning("[Deploy.ProjectFiles] create_attachment failed: #{inspect(reason)}")

            # Best-effort cleanup of the orphaned bytes.
            _ = storage_adapter().delete(storage_key)
            {:error, :attachment_insert_failed}
        end

      {:error, reason} ->
        Logger.warning("[Deploy.ProjectFiles] storage persist failed: #{inspect(reason)}")
        {:error, :persist_failed}
    end
  end

  defp target_space_project_id(%Space{metadata: %{"project_id" => id}}) when is_binary(id), do: id
  defp target_space_project_id(_), do: nil

  defp fresh_storage_key(canonical_filename) do
    sanitized =
      canonical_filename
      |> String.replace("/", "-")
      |> String.replace(~r/[^A-Za-z0-9._-]/u, "-")

    bucket = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "/")
    Path.join(["chat", bucket, "#{Ecto.UUID.generate()}-#{sanitized}"])
  end

  # ── Validation reporting ────────────────────────────────────────────

  defp report_success(
         %Stage{} = deploy_stage,
         %Attachment{} = attachment,
         %Canvas{} = canvas,
         %Task{} = task,
         %Platform.Tasks.Project{} = target_project,
         previous_id
       ) do
    case fetch_test_pass_validation(deploy_stage.id) do
      %Validation{id: vid} ->
        evidence =
          %{
            "deployed_attachment_id" => attachment.id,
            "deployed_filename" => attachment.filename,
            "byte_size" => attachment.byte_size,
            "canvas_id" => canvas.id,
            "source_task_id" => task.id,
            "target_project_id" => target_project.id
          }
          |> maybe_put("previous_attachment_id", previous_id)

        _ =
          PlanEngine.evaluate_validation(vid, %{
            status: "passed",
            evidence: evidence,
            evaluated_by: "platform.deploy.project_files"
          })

        :ok

      nil ->
        Logger.error(
          "[Deploy.ProjectFiles] deploy stage #{deploy_stage.id} has no test_pass validation " <>
            "to record success against"
        )

        :ok
    end
  end

  defp report_failure(%Stage{} = deploy_stage, reason, %Task{} = task) do
    case fetch_test_pass_validation(deploy_stage.id) do
      %Validation{id: vid} ->
        _ =
          PlanEngine.evaluate_validation(vid, %{
            status: "failed",
            evidence: %{
              "reason" => Atom.to_string(reason),
              "source_task_id" => task.id
            },
            evaluated_by: "platform.deploy.project_files"
          })

        :ok

      nil ->
        Logger.error(
          "[Deploy.ProjectFiles] deploy stage #{deploy_stage.id} has no test_pass validation " <>
            "to record failure (#{inspect(reason)}) against"
        )

        :ok
    end
  end

  defp fetch_test_pass_validation(stage_id) do
    from(v in Validation,
      where: v.stage_id == ^stage_id and v.kind == "test_pass",
      limit: 1
    )
    |> Repo.one()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Mirror the private `adapter/0` helper used elsewhere in the chat
  # subtree so this handler doesn't have to reach into
  # `Platform.Chat.AttachmentStorage`'s private surface.
  defp storage_adapter,
    do: Application.get_env(:platform, :attachment_storage_adapter, LocalDisk)

  # ── Audit telemetry ─────────────────────────────────────────────────

  # Both emitters run through :telemetry so `Platform.Audit.TelemetryHandler`
  # is the sole persistence path. `actor_type: "system"` because the
  # deploy dispatch is engine-driven — a human actor never touches this
  # handler directly. `resource_type` / `resource_id` follow the audit
  # handler convention (see @top_level_keys in telemetry_handler.ex) so
  # they surface on the audit_events row rather than getting shoved
  # into the metadata blob.
  defp emit_deployed(
         %Task{} = task,
         %Platform.Tasks.Project{} = target_project,
         folder,
         %Attachment{} = attachment
       ) do
    :telemetry.execute(
      [:platform, :deploy, :project_files, :deployed],
      %{system_time: System.system_time()},
      %{
        actor_type: "system",
        action: "deployed",
        resource_type: "chat_attachment",
        resource_id: attachment.id,
        source_task_id: task.id,
        target_project_id: target_project.id,
        folder: folder,
        filename: attachment.filename,
        version_id: attachment.id
      }
    )
  end

  defp emit_cross_tenant_rejected(
         %Task{} = task,
         %Platform.Tasks.Project{} = src_project,
         %Platform.Tasks.Project{} = target_project
       ) do
    :telemetry.execute(
      [:platform, :deploy, :project_files, :cross_tenant_rejected],
      %{system_time: System.system_time()},
      %{
        actor_type: "system",
        action: "cross_tenant_rejected",
        resource_type: "project",
        resource_id: target_project.id,
        source_task_id: task.id,
        target_project_id: target_project.id,
        source_workspace_id: src_project.workspace_id,
        target_workspace_id: target_project.workspace_id
      }
    )
  end
end
