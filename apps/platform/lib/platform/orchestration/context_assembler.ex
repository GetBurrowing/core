defmodule Platform.Orchestration.ContextAssembler do
  @moduledoc """
  Deterministic context snapshot for task dispatch.

  Walks the task hierarchy (project → epic → task → plan → stages → validations)
  and assembles a plain map suitable for sending to an executing agent. No LLM —
  pure Repo queries via `Platform.Tasks`.
  """

  import Ecto.Query

  alias Platform.Execution.CredentialLease
  alias Platform.Org.PreambleBuilder
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Skills
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Task, as: TaskSchema

  @doc """
  Build a full context snapshot for the given task.

  Returns a map with `:project`, `:epic`, `:task`, `:plan`,
  `:execution_space_id`, `:previous_rejection_reason`, and optionally
  `:deploy_credentials` keys.

  Stack-member tasks additionally carry a `:parent_plans` key: the list of
  approved plans belonging to the task's in-stack `blocks`-kind dep parents.
  Solo (non-stack) tasks omit the key entirely so the planner prompt
  template can key on presence (avoids confusing "Upstream plans" sections
  for tasks with no upstreams). See stage 5 of task
  `019f487e-25e6-7e53-8968-802a2b76302f` — ADR 0042's "immediate deps —
  not transitive" rule scopes each entry to a single one-hop parent.

  The optional `deploy_lease` argument, when provided, causes the lease's
  env vars to be included under `:deploy_credentials` so the executing agent
  has SSH keys, API tokens, etc. available in its dispatch context.
  """
  @spec build(String.t(), CredentialLease.t() | nil) :: map() | nil
  def build(task_id, deploy_lease \\ nil) do
    case Tasks.get_task_detail(task_id) do
      nil ->
        nil

      task ->
        # Use the plan from the fully-preloaded task detail (includes stages
        # with validations) rather than current_plan/1 which only preloads stages.
        plan = find_current_plan(task.plans)

        # ADR 0042: PreambleBuilder needs `task.project.org` to resolve
        # the operating org's parent chain. `get_task_detail/1` preloads
        # `:project` but not the nested `:org`; add it here so the
        # builder never falls back to a per-call Repo round-trip.
        task = maybe_preload_project_org(task)

        execution_space_id =
          case ExecutionSpace.find_or_create(task_id) do
            {:ok, space} -> space.id
            _ -> nil
          end

        skills =
          task_id
          |> Skills.resolve_skills()
          |> Enum.map(fn {skill, _source} -> %{name: skill.name, content: skill.content} end)

        resolved_deploy_strategy = Tasks.resolve_deploy_strategy(task)
        previous_rejection_reason = find_latest_rejected_reason(task.plans)
        canvases = serialize_attached_canvases(task_id)

        base = %{
          project: serialize_project(task.project),
          epic: serialize_epic(task.epic),
          task: serialize_task(task),
          plan: serialize_plan(plan),
          execution_space_id: execution_space_id,
          skills: skills,
          canvases: canvases,
          resolved_deploy_strategy: resolved_deploy_strategy,
          previous_rejection_reason: previous_rejection_reason,
          # Budgeted, namespace + super-context org preamble
          # (ADR 0042 §3 — supersedes ADR-0041 T4's single-tenant
          # surface). PreambleBuilder resolves the operating org from
          # `task.project.org`, walks `parent_org_id` upward for
          # super-context, and includes project-scoped pages when the
          # task carries `:project_id`.
          org: PreambleBuilder.build(task, nil)
        }

        base
        |> maybe_put_parent_plans(task)
        |> maybe_add_deploy_credentials(deploy_lease)
    end
  end

  # Ensure `task.project.org` is loaded so PreambleBuilder can walk the
  # parent-org chain without a second round-trip. Idempotent — Repo.preload
  # is a no-op when `:org` is already present.
  defp maybe_preload_project_org(%{project: nil} = task), do: task

  defp maybe_preload_project_org(%{project: %{} = _project} = task) do
    Repo.preload(task, project: :org)
  end

  defp maybe_preload_project_org(task), do: task

  # Find the latest approved plan from the preloaded plans list
  defp find_current_plan(nil), do: nil
  defp find_current_plan([]), do: nil

  defp find_current_plan(plans) do
    plans
    |> Enum.filter(&(&1.status in ["approved", "completed"]))
    |> Enum.sort_by(& &1.version, :desc)
    |> List.first()
  end

  # Find the most-recent rejected plan with a non-nil rejection_reason and
  # return its reason. Operates on the preloaded plans list — no extra Repo
  # round trip. Powers the reopen-with-feedback flow (task 019dfad1) so the
  # planner sees what didn't work last time.
  defp find_latest_rejected_reason(nil), do: nil
  defp find_latest_rejected_reason([]), do: nil

  defp find_latest_rejected_reason(plans) do
    plans
    |> Enum.filter(&(&1.status == "rejected" and not is_nil(&1.rejection_reason)))
    |> Enum.sort_by(& &1.version, :desc)
    |> List.first()
    |> case do
      nil -> nil
      plan -> plan.rejection_reason
    end
  end

  defp serialize_project(nil), do: nil

  defp serialize_project(project) do
    %{
      name: project.name,
      repo_url: project.repo_url,
      tech_stack: project.tech_stack,
      deploy_config: project.deploy_config
    }
  end

  defp serialize_epic(nil), do: nil

  defp serialize_epic(epic) do
    %{
      name: epic.name,
      description: epic.description,
      acceptance_criteria: epic.acceptance_criteria,
      target_branch: epic.target_branch,
      deploy_target: epic.deploy_target
    }
  end

  defp serialize_task(task) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      status: task.status,
      priority: task.priority,
      dependencies: task.dependencies,
      metadata: task.metadata
    }
  end

  defp serialize_plan(nil), do: nil

  defp serialize_plan(plan) do
    %{
      id: plan.id,
      version: plan.version,
      status: plan.status,
      stages: Enum.map(plan.stages || [], &serialize_stage/1)
    }
  end

  defp serialize_stage(stage) do
    validations =
      case stage.validations do
        %Ecto.Association.NotLoaded{} -> []
        nil -> []
        vals -> Enum.map(vals, &serialize_validation/1)
      end

    %{
      id: stage.id,
      position: stage.position,
      name: stage.name,
      description: stage.description,
      status: stage.status,
      validations: validations
    }
  end

  defp serialize_validation(validation) do
    %{
      id: validation.id,
      kind: validation.kind,
      status: validation.status
    }
  end

  # Flatten the `Platform.Tasks.CanvasAttachments.list_task_canvases/1` envelope
  # into a dispatch-payload-friendly shape. Soft-deleted canvases stay in the
  # list with `canvas_present: false` so the executing agent can self-correct
  # by calling `task_detach_canvas` rather than ignoring the stale reference.
  defp serialize_attached_canvases(task_id) do
    task_id
    |> CanvasAttachments.list_task_canvases()
    |> Enum.map(fn %{attachment: attachment, canvas: canvas} ->
      %{
        id: attachment.canvas_id,
        title: canvas && canvas.title,
        kind: canvas && canvas.kind,
        note: attachment.note,
        attached_at: attachment.inserted_at,
        canvas_present: not is_nil(canvas),
        # Task 01a13ae7 stage 1: the canonical page, so the execution
        # dispatch's design-canvases block can name it without a Repo read
        # inside HeartbeatScheduler.
        view_url: Platform.Chat.Canvas.Links.view_url(attachment.canvas_id)
      }
    end)
  end

  defp maybe_add_deploy_credentials(context, nil), do: context

  defp maybe_add_deploy_credentials(context, %CredentialLease{} = lease) do
    if CredentialLease.valid?(lease) do
      Map.put(context, :deploy_credentials, CredentialLease.to_env(lease))
    else
      context
    end
  end

  # ── Parent plans (stack members only) ────────────────────────────────

  # Only inject `:parent_plans` when the task is a stack member. Solo tasks
  # get the key omitted entirely so the planner template can key on presence
  # rather than always rendering an "Upstream plans" section for tasks that
  # have no upstreams.
  defp maybe_put_parent_plans(context, %{stack_id: nil}), do: context

  defp maybe_put_parent_plans(context, %{stack_id: stack_id} = task)
       when is_binary(stack_id) do
    Map.put(context, :parent_plans, resolve_parent_plans(task))
  end

  defp maybe_put_parent_plans(context, _task), do: context

  # Resolve the approved plans belonging to the task's in-stack `blocks`-kind
  # dep parents. ADR 0042 scopes each entry to a single one-hop parent —
  # transitive walks are the planner's job, not this helper's.
  #
  # Behavior:
  #   - Skip dep entries whose kind is not "blocks" (only true dependency
  #     relationships propagate upstream context).
  #   - Skip parents that belong to a different stack (or are not in any
  #     stack) — cross-stack context is out of scope for the wave cascade.
  #   - Skip parents with no approved plan (manual-mode wave gate before
  #     approval — the normal case).
  #   - Emit `[]` for a member with in-stack deps whose parents haven't
  #     approved anything yet; emit `[]` for a member with no deps at all.
  defp resolve_parent_plans(%{dependencies: deps, stack_id: stack_id}) when is_list(deps) do
    parent_task_ids =
      deps
      |> Enum.filter(&blocks_dep?/1)
      |> Enum.map(&Map.get(&1, "task_id"))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case parent_task_ids do
      [] ->
        []

      ids ->
        ids
        |> Enum.map(fn parent_id -> load_parent_plan_entry(parent_id, stack_id) end)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp resolve_parent_plans(_task), do: []

  defp blocks_dep?(%{"kind" => "blocks"}), do: true
  defp blocks_dep?(_), do: false

  # Load a same-stack parent and its most-recent approved plan. Returns
  # `nil` when the parent belongs to a different stack (or none), or when
  # the parent has no approved plan yet.
  defp load_parent_plan_entry(parent_id, stack_id) do
    case Repo.get(TaskSchema, parent_id) do
      %TaskSchema{stack_id: ^stack_id, title: title} ->
        case fetch_latest_approved_plan(parent_id) do
          nil ->
            nil

          plan ->
            %{
              task_id: parent_id,
              task_title: title,
              plan: serialize_parent_plan(plan)
            }
        end

      _ ->
        nil
    end
  end

  defp fetch_latest_approved_plan(task_id) do
    Plan
    |> where([p], p.task_id == ^task_id and p.status == "approved")
    |> order_by([p], desc: p.version)
    |> limit(1)
    |> preload(:stages)
    |> Repo.one()
  end

  # Serialize a parent plan into a small map. Omit per-stage validations —
  # the planner needs to see WHAT the parent decided to do, not the
  # validation gates that policed it.
  defp serialize_parent_plan(%Plan{} = plan) do
    stages =
      (plan.stages || [])
      |> Enum.sort_by(& &1.position)
      |> Enum.map(fn stage ->
        %{
          position: stage.position,
          name: stage.name,
          description: stage.description
        }
      end)

    %{
      id: plan.id,
      version: plan.version,
      status: plan.status,
      stages: stages
    }
  end
end
