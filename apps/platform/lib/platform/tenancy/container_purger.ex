defmodule Platform.Tenancy.ContainerPurger do
  @moduledoc """
  Permanently deletes container children whose scheduled deletion passed
  its retention window (task 019f4eaa stage 4).

  `Platform.Tenancy.Lifecycle` (stage 3) soft-hides containers two ways,
  and as of task 019f760f stage 1 BOTH stamp the child's OWN deletion clock:

    * **Directly-scheduled projects** — `schedule_project_deletion/2`
      stamps the project's own `deletion_scheduled_at` (+ `archived_at`).
    * **Cascade-hidden children of a scheduled org** —
      `schedule_org_deletion/2` stamps the ORG's `deletion_scheduled_at`
      and cascade-stamps each active child project / chat_space with
      `archived_cascade_org_id = org.id` AND that same
      `deletion_scheduled_at` — a per-child countdown that starts with the
      org's and is cleared again when the org is restored.

  This GenServer ticks daily and hard-deletes, past the retention window
  (`Platform.Tenancy.Lifecycle.retention_days/0`):

    1. Projects with their own `deletion_scheduled_at < now - retention` —
       one query now covers BOTH directly-scheduled projects and cascade
       project children, since each carries its own clock.
    2. Chat_spaces with their own `deletion_scheduled_at < now - retention`
       AND a non-NULL `archived_cascade_org_id`. That marker scopes this to
       cascade children only: `Platform.Chat.SpacePurger` purges
       directly-scheduled channels off the same own-clock predicate, so
       without the split both purgers would race to delete one row. Cascade
       channels therefore follow CONTAINER retention; directly-scheduled
       channels follow channel retention.

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
  itself (not just the select) — cascade children re-assert their OWN
  `deletion_scheduled_at` (spaces also re-assert the cascade marker). So a
  `cancel_project_deletion` / `cancel_org_deletion` / `unarchive_org`
  landing between candidate selection and deletion — each of which clears
  the child's own clock — is respected: the re-check matches zero rows and
  the row is skipped, never resurrected as a half-purged husk. An
  impossible row count (> 1 for a primary-key delete) raises and rolls the
  whole sweep back.

  Telemetry (`[:platform, :tasks, :project_purged]` and the reused
  `[:platform, :chat, :space_purged]`) fires only AFTER the transaction
  commits — a rolled-back sweep must not leave phantom audit rows. Both are
  registered in `Platform.Audit.TelemetryHandler` `@events`.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.Lifecycle

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
        # One own-clock query now covers BOTH directly-scheduled projects and
        # cascade project children — stage 1 gave cascade children their own
        # deletion clock, so there is no longer a separate org-join set.
        projects = Repo.all(directly_scheduled_projects_query(cutoff))

        # Cascade child channels carry their own clock too, but SpacePurger
        # owns directly-scheduled channels off the same own-clock predicate —
        # scope to the cascade marker so the two purgers never race for a row.
        cascade_spaces = Repo.all(cascade_child_spaces_query(cutoff))

        purged_projects = Enum.filter(projects, &purge_directly_scheduled_project(&1, cutoff))
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

  # Category 1: projects flagged for deletion on their own clock. Post
  # stage 1 this catches BOTH directly-scheduled projects and cascade
  # project children — each carries its own `deletion_scheduled_at`, so
  # there is no separate org-join query anymore.
  defp directly_scheduled_projects_query(cutoff) do
    from(p in Project,
      where: not is_nil(p.deletion_scheduled_at) and p.deletion_scheduled_at < ^cutoff
    )
  end

  # Category 2: chat_spaces cascade-hidden by a scheduled org. As of stage 1
  # each carries its own deletion clock, so key off it directly — scoped to
  # the cascade marker (`archived_cascade_org_id`) so this purger owns only
  # cascade children and never races SpacePurger, which owns directly-
  # scheduled channels off the same own-clock predicate.
  defp cascade_child_spaces_query(cutoff) do
    from(s in Space,
      where:
        not is_nil(s.deletion_scheduled_at) and s.deletion_scheduled_at < ^cutoff and
          not is_nil(s.archived_cascade_org_id)
    )
  end

  # ── Race-guarded per-candidate deletes ─────────────────────────────────

  # Deletes one project by its OWN deletion clock, re-verifying that clock
  # IN the delete query so a `cancel_project_deletion` / `cancel_org_deletion`
  # / `unarchive_org` landing between select and delete — any of which clears
  # the clock — is respected. Handles both directly-scheduled projects and
  # cascade project children (each carries its own clock). Exposed
  # (`@doc false`) as the test seam that proves the re-check lives in the
  # query, not only the select.
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

  # Deletes one cascade-hidden chat_space, re-verifying its OWN clock AND the
  # cascade marker IN the delete query. A `cancel_org_deletion` /
  # `unarchive_org` clears BOTH the child's `deletion_scheduled_at` and its
  # `archived_cascade_org_id` in one transaction, so either change drops the
  # row out of the re-check → 0 deleted → skipped.
  @doc false
  @spec purge_cascade_space(Space.t(), DateTime.t()) :: boolean()
  def purge_cascade_space(%Space{} = candidate, cutoff) do
    from(s in Space,
      where:
        s.id == ^candidate.id and not is_nil(s.deletion_scheduled_at) and
          s.deletion_scheduled_at < ^cutoff and not is_nil(s.archived_cascade_org_id)
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

  # Every purged project — directly-scheduled or cascade child — carries its
  # own `deletion_scheduled_at`, so stringify it unconditionally for the
  # audit bridge's JSON pass (which chokes on a raw DateTime struct).
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
        deletion_scheduled_at: DateTime.to_iso8601(project.deletion_scheduled_at)
      }
    )
  end

  # Reuses the `[:platform, :chat, :space_purged]` event `SpacePurger`
  # already emits + registers. Every cascade child now carries its own
  # `deletion_scheduled_at`, so stringify it unconditionally — matching
  # SpacePurger's own emit.
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
        deletion_scheduled_at: DateTime.to_iso8601(space.deletion_scheduled_at)
      }
    )
  end
end
