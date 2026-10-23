defmodule Platform.Memory.Insights.ProjectInference do
  @moduledoc """
  The project a `task` insight presumably belongs to. Task
  `01a15ee1-48c8-7000-a8f1-33a5586cb458`, stage 2.

  The sponsor, 2026-10-21: "the tasks should already have been filed to the
  presumed appropriate project". So a task insight is filed unattended into
  the project this module infers, and a person is asked to pick one only
  when nothing here names a project.

  ## The rungs

  `infer/1` takes the FIRST rung that names an existing project in the
  insight's org (`Platform.Memory.Insights.Tier.org_id/1`) that is neither
  archived (`archived_at`) nor scheduled for deletion
  (`deletion_scheduled_at`):

    1. `action["project_id"]`, then `action["target"]`, when it is a uuid:
       `"named by dreaming"`. A `target` that matches a project slug
       case-insensitively: `"named by slug"`.
    2. a `journal_path` of `project/<uuid>/journal/...`: `"journal's project"`.
    3. a `source_ref` of `task:<uuid>`: the cited task's project,
       `"cited task's project"`.
    4. the org has exactly ONE such project: `"only project"`.

  Otherwise `nil`. A rung that names a project outside the org, an archived
  one or a missing one is skipped, not an answer, so the next rung is tried.
  There is no primary-project flag on `Platform.Tasks.Project`, so no rung
  reads one.

  Every project read goes through the `Platform.Tasks` context
  (`project_id_for_task/1`, `live_project_ids/2`, `live_project_in_org?/2`,
  `live_project_id_by_slug/2`), which owns what "live" means (task 01a15ee1
  stage 3); this module holds no query of its own.

  Pure read. It decides nothing about who may file: `Platform.Access`
  re-checks `tasks.write` on the inferred project when the task is filed.
  Run at ingest (`Platform.Memory.Insights.ingest_from_journal/4` stores
  `action["project_id"]` and `action["project_reason"]`) and again in
  `Platform.Memory.Insights.Actions.apply_unattended/2`, so a project
  archived since ingest is caught.
  """

  alias Platform.Memory.Insights.Tier
  alias Platform.Tasks

  @type reason :: String.t()

  @journal_regex ~r/^project\/([^\/]+)\/journal\//

  @doc """
  `{project_id, reason}` for the first rung that resolves (see the
  moduledoc), or `nil`. Takes an `%Insight{}` or a map with the same keys
  (`:action`, `:journal_path`, `:source_ref`, `:org_id`).
  """
  @spec infer(map()) :: {binary(), reason()} | nil
  def infer(insight) when is_map(insight) do
    org_id = Tier.org_id(insight)
    action = Map.get(insight, :action) || %{}

    if is_binary(org_id) do
      named(action, org_id) ||
        journal(Map.get(insight, :journal_path), org_id) ||
        cited_task(Map.get(insight, :source_ref), org_id) ||
        only_project(org_id)
    end
  end

  # ── rungs ────────────────────────────────────────────────────────────

  defp named(action, org_id) do
    by_id =
      [Map.get(action, "project_id"), Map.get(action, "target")]
      |> Enum.find_value(fn id -> if live_in_org?(id, org_id), do: normalise(id) end)

    cond do
      by_id -> {by_id, "named by dreaming"}
      id = by_slug(Map.get(action, "target"), org_id) -> {id, "named by slug"}
      true -> nil
    end
  end

  defp journal(path, org_id) when is_binary(path) do
    case Regex.run(@journal_regex, path) do
      [_, id] -> if live_in_org?(id, org_id), do: {normalise(id), "journal's project"}
      _ -> nil
    end
  end

  defp journal(_path, _org_id), do: nil

  defp cited_task("task:" <> task_id, org_id) do
    task_id = String.trim(task_id)

    with project_id when is_binary(project_id) <- Tasks.project_id_for_task(task_id),
         true <- live_in_org?(project_id, org_id) do
      {project_id, "cited task's project"}
    else
      _ -> nil
    end
  end

  defp cited_task(_source_ref, _org_id), do: nil

  defp only_project(org_id) do
    case Tasks.live_project_ids(org_id, limit: 2) do
      [id] -> {id, "only project"}
      _ -> nil
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp live_in_org?(id, org_id), do: Tasks.live_project_in_org?(id, org_id)

  defp by_slug(target, org_id), do: Tasks.live_project_id_by_slug(target, org_id)

  defp normalise(id), do: String.downcase(id)
end
