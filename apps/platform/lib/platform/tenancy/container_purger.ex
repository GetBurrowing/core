defmodule Platform.Tenancy.ContainerPurger do
  @moduledoc """
  Permanently deletes container children whose scheduled deletion passed
  its retention window (task 019f4eaa stage 4).

  `Platform.Tenancy.Lifecycle` (stage 3) soft-hides containers two ways:

    * **Directly-scheduled projects** — `schedule_project_deletion/2`
      stamps the project's own `deletion_scheduled_at` (+ `archived_at`).
    * **Cascade-hidden children of a scheduled org** —
      `schedule_org_deletion/2` stamps the ORG's `deletion_scheduled_at`
      and cascade-stamps each active child project / chat_space with
      `archived_cascade_org_id = org.id` (children do NOT carry their own
      `deletion_scheduled_at`; the retention clock lives on the org).

  This GenServer ticks daily and hard-deletes, past the retention window
  (`Platform.Tenancy.Lifecycle.retention_days/0`):

    1. Projects with their own `deletion_scheduled_at < now - retention`.
    2. Projects AND chat_spaces whose `archived_cascade_org_id` references
       an org whose `deletion_scheduled_at < now - retention`.

  Project rows cascade cleanly at the DB level (tasks, epics, task_stacks,
  meetings, platform_files are `ON DELETE :delete_all` on `project_id`);
  deleting a chat_space cascades its messages, participants, threads, pins,
  canvases, space_agents, attention routing, attachments, and meetings —
  exactly as `Platform.Chat.SpacePurger` relies on.

  Named `ContainerPurger` (not `ProjectPurger`) because it hard-deletes
  BOTH projects and chat_spaces across the container lifecycle domain that
  `Platform.Tenancy.Lifecycle` owns — a `ProjectPurger` name would hide the
  chat_space deletions.

  ## Org rows are never deleted

  The emptied org row STAYS soft-hidden after its children are purged.
  Orgs are fenced by `ON DELETE RESTRICT` foreign keys (including
  `audit_events.actor_org_id`) — hard-deleting one would corrupt the
  append-only audit trail. No query in this module targets the `orgs`
  table; org-row deletion is deliberately out of scope.

  ## Safety posture

  The sweep runs in one transaction. Every delete re-asserts the full
  "still scheduled + still past window" predicate INSIDE the delete query
  itself (not just the select) — for cascade children that means the org
  it hangs off is still scheduled and past window. So a
  `cancel_project_deletion` / `cancel_org_deletion` / `unarchive_org`
  landing between candidate selection and deletion is respected: the
  re-check matches zero rows and the row is skipped, never resurrected as a
  half-purged husk. An impossible row count (> 1 for a primary-key delete)
  raises and rolls the whole sweep back.

  Telemetry (`[:platform, :tasks, :project_purged]` and the reused
  `[:platform, :chat, :space_purged]`) fires only AFTER the transaction
  commits — a rolled-back sweep must not leave phantom audit rows. Both are
  registered in `Platform.Audit.TelemetryHandler` `@events`.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2, subquery: 1]

  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.Lifecycle
  alias Platform.Tenancy.Org

  @tick_interval_ms 24 * 60 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run one sweep synchronously. Returns `{:ok, purged_count}`."
  @spec sweep() :: {:ok, non_neg_integer()}
  def sweep, do: do_sweep()

  @impl true
  def init(_opts) do
    schedule_next_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    {:ok, _count} = do_sweep()
    schedule_next_tick()
    {:noreply, state}
  end

  defp schedule_next_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  defp do_sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -Lifecycle.retention_days(), :day)

    {:ok, {purged_projects, purged_spaces}} =
      Repo.transaction(fn ->
        direct_projects = Repo.all(directly_scheduled_projects_query(cutoff))
        direct_ids = MapSet.new(direct_projects, & &1.id)

        # A directly-scheduled project has `archived_at` set, so the org
        # cascade skips it and its `archived_cascade_org_id` stays NULL — the
        # two candidate sets are disjoint. The reject is belt-and-braces so a
        # row never gets a redundant second delete + skip-warn.
        cascade_projects =
          cutoff
          |> cascade_child_projects_query()
          |> Repo.all()
          |> Enum.reject(&MapSet.member?(direct_ids, &1.id))

        cascade_spaces = Repo.all(cascade_child_spaces_query(cutoff))

        purged_projects =
          Enum.filter(direct_projects, &purge_directly_scheduled_project(&1, cutoff)) ++
            Enum.filter(cascade_projects, &purge_cascade_project(&1, cutoff))

        purged_spaces = Enum.filter(cascade_spaces, &purge_cascade_space(&1, cutoff))

        {purged_projects, purged_spaces}
      end)

    # Telemetry fires only after the transaction commits — a rolled-back
    # sweep must not leave phantom purge entries in the audit log.
    Enum.each(purged_projects, &emit_project_purged_telemetry/1)
    Enum.each(purged_spaces, &emit_space_purged_telemetry/1)

    total = length(purged_projects) + length(purged_spaces)

    Logger.info(
      "[container_purger] purged #{length(purged_projects)} project(s) + " <>
        "#{length(purged_spaces)} chat_space(s) past retention"
    )

    {:ok, total}
  end

  # ── Candidate selection ────────────────────────────────────────────────

  # Category 1: projects flagged for deletion on their own clock.
  defp directly_scheduled_projects_query(cutoff) do
    from(p in Project,
      where: not is_nil(p.deletion_scheduled_at) and p.deletion_scheduled_at < ^cutoff
    )
  end

  # Category 2: projects cascade-hidden by an org whose own retention window
  # has elapsed. The clock lives on the org — join children to it via the
  # provenance marker, expressed as a subquery so the same predicate can be
  # reused verbatim in the race-guarded delete below.
  defp cascade_child_projects_query(cutoff) do
    from(p in Project,
      where: p.archived_cascade_org_id in subquery(scheduled_org_ids_query(cutoff))
    )
  end

  defp cascade_child_spaces_query(cutoff) do
    from(s in Space,
      where: s.archived_cascade_org_id in subquery(scheduled_org_ids_query(cutoff))
    )
  end

  # Org ids whose deletion is scheduled AND past the retention window. NEVER
  # selected for deletion themselves — only used to identify their children.
  defp scheduled_org_ids_query(cutoff) do
    from(o in Org,
      where: not is_nil(o.deletion_scheduled_at) and o.deletion_scheduled_at < ^cutoff,
      select: o.id
    )
  end

  # ── Race-guarded per-candidate deletes ─────────────────────────────────

  # Deletes one directly-scheduled project, re-verifying its own lifecycle
  # flag IN the delete query so a `cancel_project_deletion` landing between
  # select and delete is respected. Exposed (`@doc false`) as the test seam
  # that proves the re-check lives in the query, not only the select.
  @doc false
  @spec purge_directly_scheduled_project(Project.t(), DateTime.t()) :: boolean()
  def purge_directly_scheduled_project(%Project{} = candidate, cutoff) do
    from(p in Project,
      where:
        p.id == ^candidate.id and not is_nil(p.deletion_scheduled_at) and
          p.deletion_scheduled_at < ^cutoff
    )
    |> delete_one("project", candidate.id)
  end

  # Deletes one cascade-hidden project, re-verifying IN the delete query that
  # its `archived_cascade_org_id` still points to a scheduled, past-window
  # org. A `cancel_org_deletion` / `unarchive_org` clears BOTH the org flag
  # and the child's provenance marker in one transaction, so either change
  # drops the row out of the subquery → 0 deleted → skipped.
  @doc false
  @spec purge_cascade_project(Project.t(), DateTime.t()) :: boolean()
  def purge_cascade_project(%Project{} = candidate, cutoff) do
    from(p in Project,
      where:
        p.id == ^candidate.id and
          p.archived_cascade_org_id in subquery(scheduled_org_ids_query(cutoff))
    )
    |> delete_one("project", candidate.id)
  end

  # Deletes one cascade-hidden chat_space, with the same org-anchored
  # re-check as `purge_cascade_project/2`.
  @doc false
  @spec purge_cascade_space(Space.t(), DateTime.t()) :: boolean()
  def purge_cascade_space(%Space{} = candidate, cutoff) do
    from(s in Space,
      where:
        s.id == ^candidate.id and
          s.archived_cascade_org_id in subquery(scheduled_org_ids_query(cutoff))
    )
    |> delete_one("chat_space", candidate.id)
  end

  # Runs a primary-key-scoped delete and interprets the affected count.
  # Exactly 0 (skip + warn) or 1 (purged) may be affected — anything else
  # raises, rolling back the whole sweep.
  defp delete_one(query, resource, id) do
    {deleted, _} = Repo.delete_all(query)

    case deleted do
      1 ->
        true

      0 ->
        Logger.warning(
          "[container_purger] #{resource} #{id} no longer matched the delete " <>
            "re-check — skipped"
        )

        false

      other ->
        raise "container purge affected #{other} rows for #{resource} #{id} — " <>
                "expected exactly 1, rolling back sweep"
    end
  end

  # ── Telemetry (bridged into the audit log) ─────────────────────────────

  # `deletion_scheduled_at` is nil for a cascade child (its clock is on the
  # org) — stringify only when present so the audit bridge's JSON pass never
  # chokes on a DateTime struct, and never crashes on the nil.
  defp emit_project_purged_telemetry(%Project{} = project) do
    :telemetry.execute(
      [:platform, :tasks, :project_purged],
      %{system_time: System.system_time()},
      %{
        actor_id: nil,
        actor_type: "system",
        resource_type: "project",
        resource_id: project.id,
        action: "project_purged",
        project_slug: project.slug,
        project_name: project.name,
        org_id: project.org_id,
        archived_cascade_org_id: project.archived_cascade_org_id,
        deletion_scheduled_at: iso8601_or_nil(project.deletion_scheduled_at)
      }
    )
  end

  # Reuses the `[:platform, :chat, :space_purged]` event `SpacePurger`
  # already emits + registers. Guards the nil `deletion_scheduled_at` that a
  # cascade child carries (SpacePurger's own emit stringifies unconditionally
  # because it only ever purges directly-scheduled channels).
  defp emit_space_purged_telemetry(%Space{} = space) do
    :telemetry.execute(
      [:platform, :chat, :space_purged],
      %{system_time: System.system_time()},
      %{
        actor_id: nil,
        actor_type: "system",
        resource_type: "chat_space",
        resource_id: space.id,
        action: "space_purged",
        space_kind: space.kind,
        space_name: space.name,
        org_id: space.org_id,
        archived_cascade_org_id: space.archived_cascade_org_id,
        deletion_scheduled_at: iso8601_or_nil(space.deletion_scheduled_at)
      }
    )
  end

  defp iso8601_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601_or_nil(nil), do: nil
end
