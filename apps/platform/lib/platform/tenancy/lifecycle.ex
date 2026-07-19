defmodule Platform.Tenancy.Lifecycle do
  @moduledoc """
  Archive / schedule-deletion / restore lifecycle for the container
  resources — orgs and projects (task 019f4eaa stage 3).

  Mirrors the proven channel lifecycle in `Platform.Chat`
  (`archive_space/2`, `schedule_space_deletion/2`, …) but adds the two
  things containers need that a single channel does not:

    * **Root guard.** The root org (Fabrikam, `tier == :root`) can never be
      archived or deleted — every org function returns
      `{:error, :not_deletable}` for it before touching the DB.

    * **Provenance-aware cascade.** Archiving or scheduling an org hides
      its child projects and chat_spaces in the SAME transaction, but
      only children that are not already archived on their own. Each
      cascade-hidden child records `archived_cascade_org_id = org.id` so
      the restore path can un-hide exactly (and only) the children this
      org drove — a child that was archived independently keeps a NULL
      `archived_cascade_org_id` and is therefore left hidden on restore.

  Authorization: every function requires a Fabrikam (root) admin actor. There
  is no creator carve-out (orgs and projects have no owner column) and no
  system path — a `nil`/non-admin actor gets `{:error, :unauthorized}`.

  Audit: each successful action emits a distinct `[:platform, …]`
  telemetry event AFTER the transaction commits (a rolled-back write must
  never leave a phantom audit row). Every event here is registered in
  `Platform.Audit.TelemetryHandler` `@events`, or the bridged audit row
  would silently never persist.

  This module is the implementation; `Platform.Tenancy` and
  `Platform.Tasks` expose thin delegates so callers use the natural
  context API (`Tenancy.archive_org/2`, `Tasks.archive_project/2`).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tasks.Task
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  @type actor :: map() | nil
  @type org_error :: :unauthorized | :not_deletable | :not_scheduled | :not_found
  @type project_error :: :unauthorized | :not_scheduled

  # ── Org lifecycle ─────────────────────────────────────────────────────

  @doc """
  Soft-archive an org: set `archived_at` on the org and cascade-hide its
  not-already-archived projects and chat_spaces. Fabrikam-admin only; the root
  org returns `{:error, :not_deletable}`.
  """
  @spec archive_org(actor(), Org.t()) ::
          {:ok, Org.t()} | {:error, org_error() | Ecto.Changeset.t()}
  def archive_org(actor, %Org{} = org) do
    with_org_authz(actor, org, fn ->
      now = DateTime.utc_now()
      hide_org(actor, org, %{archived_at: now}, now, [:platform, :tenancy, :org_archived], %{})
    end)
  end

  @doc """
  Flag an org for permanent deletion. Stamps `deletion_scheduled_at`
  (and `archived_at`, when not already archived) on the org and runs the
  same cascade-hide as `archive_org/2`. Fabrikam-admin only; root returns
  `{:error, :not_deletable}`.
  """
  @spec schedule_org_deletion(actor(), Org.t()) ::
          {:ok, Org.t()} | {:error, org_error() | Ecto.Changeset.t()}
  def schedule_org_deletion(actor, %Org{} = org) do
    with_org_authz(actor, org, fn ->
      now = DateTime.utc_now()

      org_attrs =
        if org.archived_at,
          do: %{deletion_scheduled_at: now},
          else: %{archived_at: now, deletion_scheduled_at: now}

      deadline = DateTime.add(now, retention_days(), :day)

      hide_org(actor, org, org_attrs, now, [:platform, :tenancy, :org_deletion_scheduled], %{
        retention_deadline: DateTime.to_iso8601(deadline)
      })
    end)
  end

  @doc """
  Reverse an archive: clear the org's own flags and un-hide ONLY the
  children this org cascade-hid (`archived_cascade_org_id == org.id`).
  Independently-archived children are left untouched. Fabrikam-admin only.
  """
  @spec unarchive_org(actor(), Org.t()) ::
          {:ok, Org.t()} | {:error, org_error() | Ecto.Changeset.t()}
  def unarchive_org(actor, %Org{} = org) do
    with_org_authz(actor, org, fn ->
      restore_org(actor, org, [:platform, :tenancy, :org_unarchived])
    end)
  end

  @doc """
  Cancel a scheduled org deletion: identical restore to `unarchive_org/2`
  (clears the org's flags and un-hides only its cascade children).
  Returns `{:error, :not_scheduled}` when no deletion is pending.
  Fabrikam-admin only.
  """
  @spec cancel_org_deletion(actor(), Org.t()) ::
          {:ok, Org.t()} | {:error, org_error() | Ecto.Changeset.t()}
  def cancel_org_deletion(actor, %Org{} = org) do
    with_org_authz(actor, org, fn ->
      if is_nil(org.deletion_scheduled_at) do
        {:error, :not_scheduled}
      else
        restore_org(actor, org, [:platform, :tenancy, :org_deletion_cancelled])
      end
    end)
  end

  # Cascade-hide in one transaction: the org row + every child project and
  # chat_space that is NOT already archived (so an independently-archived
  # child keeps its NULL provenance marker and is skipped). Telemetry fires
  # only after commit.
  #
  # Each cascade child inherits the org's OWN deletion clock: when scheduling
  # (`org_attrs` carries `:deletion_scheduled_at`), the child gets the same
  # timestamp so its countdown starts with the org's; when plain-archiving
  # (no deletion in `org_attrs`), `child_deletion` is `nil` and the child's
  # clock stays clear — archive must never start a countdown.
  defp hide_org(actor, %Org{} = org, org_attrs, now, event_name, extra) do
    child_deletion = Map.get(org_attrs, :deletion_scheduled_at)

    Multi.new()
    |> Multi.update(:org, Org.changeset(org, org_attrs))
    |> Multi.update_all(
      :projects,
      unhidden_children_query(Project, org.id),
      set: [
        archived_at: now,
        deletion_scheduled_at: child_deletion,
        archived_cascade_org_id: org.id,
        updated_at: now
      ]
    )
    |> Multi.update_all(
      :spaces,
      unhidden_children_query(Space, org.id),
      set: [
        archived_at: now,
        deletion_scheduled_at: child_deletion,
        archived_cascade_org_id: org.id,
        updated_at: now
      ]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{org: updated_org}} ->
        emit(event_name, actor, org_meta(updated_org, extra))
        {:ok, updated_org}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Restore in one transaction: re-verify the org still exists (guards
  # against a concurrent hard delete), un-hide only this org's cascade
  # children, then clear the org's own flags. Telemetry fires after commit.
  #
  # Clearing `deletion_scheduled_at` on the children is essential: cancelling
  # an org deletion clears the org's clock, so the cascade children it stamped
  # must have theirs cleared too — otherwise they keep counting down after the
  # org they belong to has been reprieved.
  defp restore_org(actor, %Org{} = org, event_name) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:verify, fn repo, _changes ->
      case repo.get(Org, org.id) do
        nil -> {:error, :not_found}
        %Org{} = fresh -> {:ok, fresh}
      end
    end)
    |> Multi.update_all(
      :projects,
      cascade_children_query(Project, org.id),
      set: [
        archived_at: nil,
        deletion_scheduled_at: nil,
        archived_cascade_org_id: nil,
        updated_at: now
      ]
    )
    |> Multi.update_all(
      :spaces,
      cascade_children_query(Space, org.id),
      set: [
        archived_at: nil,
        deletion_scheduled_at: nil,
        archived_cascade_org_id: nil,
        updated_at: now
      ]
    )
    |> Multi.update(:org, fn %{verify: fresh} ->
      Org.changeset(fresh, %{archived_at: nil, deletion_scheduled_at: nil})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{org: restored_org}} ->
        emit(event_name, actor, org_meta(restored_org, %{}))
        {:ok, restored_org}

      {:error, :verify, :not_found, _changes} ->
        {:error, :not_found}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Children to cascade-HIDE: belong to the org and are not already
  # archived. The `is_nil(archived_at)` predicate is what makes the
  # cascade provenance-aware — already-archived children are skipped and
  # keep their NULL `archived_cascade_org_id`.
  defp unhidden_children_query(schema, org_id) do
    from(r in schema, where: r.org_id == ^org_id and is_nil(r.archived_at))
  end

  # Children to cascade-RESTORE: only those this org drove, identified by
  # the provenance marker. An independently-archived child has a NULL
  # marker and is therefore never un-hidden here.
  defp cascade_children_query(schema, org_id) do
    from(r in schema, where: r.archived_cascade_org_id == ^org_id)
  end

  @doc """
  What archiving/scheduling this org would actually hide, right now:
  `%{projects: [name], channels: [name]}`.

  Powers the confirm dialog's "here's what goes with it" list — Marlowe's call
  (2026-07-16): keep the bulk cascade, because bulk archive/delete is useful,
  but say what it takes instead of "and everything under it".

  Reuses `unhidden_children_query/2` — the cascade's OWN predicate — on
  purpose. A preview built from a lookalike query could drift from what the
  cascade actually does, and a dialog that misstates what it is about to hide
  is worse than the vague one it replaces.

  Consequence worth knowing: children you already archived YOURSELF are absent
  from this list, because the cascade skips them (they keep a NULL provenance
  marker and stay archived through a later restore). So the list is exactly
  what CHANGES — not an inventory of the org.

  Takes a UUID, not a slug — the Tasks sidebar posts org SLUGS off its
  `phx-click`, so callers must resolve first (`PlatformWeb.LifecycleActions`
  owns that). A non-UUID falls through to an empty preview rather than raising
  `Ecto.Query.CastError` against `UUIDv7`.
  """
  @spec cascade_preview(term()) :: %{projects: [String.t()], channels: [String.t()]}
  def cascade_preview(org_id) when is_binary(org_id) do
    case Ecto.UUID.cast(org_id) do
      {:ok, _} -> do_cascade_preview(org_id)
      :error -> %{projects: [], channels: []}
    end
  end

  def cascade_preview(_), do: %{projects: [], channels: []}

  defp do_cascade_preview(org_id) do
    %{
      projects:
        Project
        |> unhidden_children_query(org_id)
        |> order_by([r], asc: r.name)
        |> select([r], r.name)
        |> Repo.all(),
      channels:
        Space
        |> unhidden_children_query(org_id)
        |> where([r], r.kind == "channel")
        |> order_by([r], asc: r.name)
        |> select([r], r.name)
        |> Repo.all()
    }
  end

  @doc """
  What this org's cascade is CURRENTLY hiding: `%{projects: [name], channels: [name]}`.

  The mirror of `cascade_preview/1`, and the distinction matters:

    * `cascade_preview/1` answers "what WOULD go if I archived this?" — reads
      the active children (`is_nil(archived_at)`), used by the confirm dialog
      BEFORE the act.
    * `cascade_hidden/1` answers "what DID this org take with it?" — reads the
      provenance marker (`archived_cascade_org_id == org.id`), used by the
      Recovery view AFTER.

  Using the preview query here would return nothing at all: once the org is
  archived, its children are archived too, so the "active children" set is
  empty. They are two different questions and need two different queries.

  This one reuses `cascade_children_query/2` — the exact query the RESTORE
  runs — so the Recovery row lists precisely what its Restore button will
  bring back. Marlowe's ask (2026-07-16), and the same instinct behind the
  confirm dialog's list: don't make someone restore a group without showing
  what's in it.

  Independently-archived children are correctly absent (NULL marker): Restore
  won't bring them back, so it must not claim it will.
  """
  @spec cascade_hidden(term()) :: %{projects: [String.t()], channels: [String.t()]}
  def cascade_hidden(org_id) when is_binary(org_id) do
    case Ecto.UUID.cast(org_id) do
      {:ok, _} -> do_cascade_hidden(org_id)
      :error -> %{projects: [], channels: []}
    end
  end

  def cascade_hidden(_), do: %{projects: [], channels: []}

  defp do_cascade_hidden(org_id) do
    %{
      projects:
        Project
        |> cascade_children_query(org_id)
        |> order_by([r], asc: r.name)
        |> select([r], r.name)
        |> Repo.all(),
      channels:
        Space
        |> cascade_children_query(org_id)
        |> where([r], r.kind == "channel")
        |> order_by([r], asc: r.name)
        |> select([r], r.name)
        |> Repo.all()
    }
  end

  defp with_org_authz(actor, %Org{} = org, fun) do
    cond do
      not Tenancy.fabrikam_admin?(actor) -> {:error, :unauthorized}
      Tenancy.tier(org) == :root -> {:error, :not_deletable}
      true -> fun.()
    end
  end

  # ── Project lifecycle (single-row; no children to cascade) ─────────────

  @doc """
  Soft-archive a single project (`archived_at`). Fabrikam-admin only.
  Projects have no cascade of their own — chat_spaces are org-scoped, not
  project-scoped.
  """
  @spec archive_project(actor(), Project.t()) ::
          {:ok, Project.t()} | {:error, project_error() | Ecto.Changeset.t()}
  def archive_project(actor, %Project{} = project) do
    with_project_authz(actor, fn ->
      now = DateTime.utc_now()

      update_project(
        actor,
        project,
        %{archived_at: now},
        [:platform, :tasks, :project_archived],
        %{}
      )
    end)
  end

  @doc "Reverse a project archive — clears both lifecycle flags. Fabrikam-admin only."
  @spec unarchive_project(actor(), Project.t()) ::
          {:ok, Project.t()} | {:error, project_error() | Ecto.Changeset.t()}
  def unarchive_project(actor, %Project{} = project) do
    with_project_authz(actor, fn ->
      update_project(
        actor,
        project,
        %{archived_at: nil, deletion_scheduled_at: nil, archived_cascade_org_id: nil},
        [:platform, :tasks, :project_unarchived],
        %{}
      )
    end)
  end

  @doc """
  Flag a project for permanent deletion — sets `deletion_scheduled_at`
  (and `archived_at` when not already archived). Fabrikam-admin only.
  """
  @spec schedule_project_deletion(actor(), Project.t()) ::
          {:ok, Project.t()} | {:error, project_error() | Ecto.Changeset.t()}
  def schedule_project_deletion(actor, %Project{} = project) do
    with_project_authz(actor, fn ->
      now = DateTime.utc_now()

      attrs =
        if project.archived_at,
          do: %{deletion_scheduled_at: now},
          else: %{archived_at: now, deletion_scheduled_at: now}

      deadline = DateTime.add(now, retention_days(), :day)

      update_project(
        actor,
        project,
        attrs,
        [:platform, :tasks, :project_deletion_scheduled],
        %{retention_deadline: DateTime.to_iso8601(deadline)}
      )
    end)
  end

  @doc """
  Cancel a scheduled project deletion — clears both flags. Returns
  `{:error, :not_scheduled}` when no deletion is pending. Fabrikam-admin only.
  """
  @spec cancel_project_deletion(actor(), Project.t()) ::
          {:ok, Project.t()} | {:error, project_error() | Ecto.Changeset.t()}
  def cancel_project_deletion(actor, %Project{} = project) do
    with_project_authz(actor, fn ->
      if is_nil(project.deletion_scheduled_at) do
        {:error, :not_scheduled}
      else
        update_project(
          actor,
          project,
          %{archived_at: nil, deletion_scheduled_at: nil, archived_cascade_org_id: nil},
          [:platform, :tasks, :project_deletion_cancelled],
          %{}
        )
      end
    end)
  end

  defp update_project(actor, %Project{} = project, attrs, event_name, extra) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        emit(event_name, actor, project_meta(updated, extra))
        {:ok, updated}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp with_project_authz(actor, fun) do
    if Tenancy.fabrikam_admin?(actor), do: fun.(), else: {:error, :unauthorized}
  end

  # ── Create-time guard ─────────────────────────────────────────────────

  @doc """
  Changeset guard for `create_project/1` and `create_space/1`: reject
  creation when the target org is archived or scheduled for deletion, so
  no new child can slip into a container on its way out. A no-op when the
  changeset has no `:org_id` (spaces are frequently org-less).
  """
  @spec guard_org_active(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def guard_org_active(%Ecto.Changeset{} = changeset) do
    case Ecto.Changeset.get_field(changeset, :org_id) do
      org_id when is_binary(org_id) ->
        if org_archived_or_scheduled?(org_id) do
          Ecto.Changeset.add_error(
            changeset,
            :org_id,
            "belongs to an archived or deletion-scheduled org"
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  @doc "True when the org has `archived_at` or `deletion_scheduled_at` set."
  @spec org_archived_or_scheduled?(binary() | nil) :: boolean()
  def org_archived_or_scheduled?(org_id) when is_binary(org_id) do
    Repo.exists?(
      from(o in Org,
        where:
          o.id == ^org_id and
            (not is_nil(o.archived_at) or not is_nil(o.deletion_scheduled_at))
      )
    )
  end

  def org_archived_or_scheduled?(_), do: false

  # ── Write freeze ──────────────────────────────────────────────────────

  @doc """
  False when the project is archived — the write-freeze predicate, mirroring
  `Platform.Chat.space_writable?/1`. Hiding an archived project from listings
  is only half the promise; this is the half that makes "archived" mean
  *locked* rather than merely *out of sight*.

  Scheduling a deletion always stamps `archived_at` too (see
  `schedule_project_deletion/2`), so this one column covers both states — as
  does the org cascade, which stamps `archived_at` on child projects.

  Contract copied deliberately from the chat precedent:

    * **Unknown id → writable.** Let the write path surface its own
      not-found / FK error rather than a misleading "archived" one.
    * **Single-column select.** This sits on write paths; don't load a row.
    * **Non-UUID id → writable.** An unselected form dropdown submits
      `project_id: ""` — a binary, so it would reach `where: p.id == ^""`
      and raise `Ecto.Query.CastError` against `UUIDv7`. Chat never hits this
      because space ids don't come from an empty `<option>`. Anything that
      isn't a well-formed UUID is not a project reference: fall through and
      let `validate_required` report the real problem.

  ## What this does NOT freeze

  Unlike a chat message — a terminal artifact — a task is a state machine the
  system drives itself (`TaskRouter`, `StackDeployer`, the PR-merged webhook
  flipping a task to `done`). Freezing those transitions would not lock an
  archived project, it would **wedge** it: `TaskRouter` re-dispatches after a
  failed transition, so a task in an archived project would retry forever with
  nobody watching. So the guard sits on the verbs that *initiate* work
  (create/edit/delete a task, start a new plan) and lets already-started work
  drain to a terminal state. Every decision to begin new work is blocked; only
  the completion of a decision already taken proceeds.
  """
  @spec project_writable?(term()) :: boolean()
  def project_writable?(project_id) when is_binary(project_id) do
    case Ecto.UUID.cast(project_id) do
      {:ok, _} ->
        from(p in Project, where: p.id == ^project_id, select: p.archived_at)
        |> Repo.one()
        |> case do
          nil -> true
          archived_at -> is_nil(archived_at)
        end

      :error ->
        true
    end
  end

  def project_writable?(_), do: true

  @doc """
  Guard for project-scoped write paths: `:ok`, or `{:error, :project_archived}`.

  A non-binary / missing project id falls through to `:ok` so changeset
  validation reports the real problem (`project_id` is `validate_required` on
  every project-owned schema) instead of an archived error.
  """
  @spec ensure_project_writable(binary() | nil) :: :ok | {:error, :project_archived}
  def ensure_project_writable(project_id) when is_binary(project_id) do
    if project_writable?(project_id), do: :ok, else: {:error, :project_archived}
  end

  def ensure_project_writable(_), do: :ok

  @doc """
  Variant for write paths addressed by task rather than project — one hop,
  resolved in a single query. Mirrors `ensure_message_space_writable/1`.

  Used by `create_plan/1`, the keystone guard: without it an agent could start
  brand-new work on a pre-existing backlog task in an archived project without
  ever calling `create_task/1`.

  Same non-UUID tolerance as `project_writable?/1` — a malformed task id is
  not a reference to freeze, it's a validation error for the caller to report.
  """
  @spec ensure_task_project_writable(term()) :: :ok | {:error, :project_archived}
  def ensure_task_project_writable(task_id) when is_binary(task_id) do
    case Ecto.UUID.cast(task_id) do
      {:ok, _} ->
        from(t in Task, where: t.id == ^task_id, select: t.project_id)
        |> Repo.one()
        |> case do
          nil -> :ok
          project_id -> ensure_project_writable(project_id)
        end

      :error ->
        :ok
    end
  end

  def ensure_task_project_writable(_), do: :ok

  # ── Shared helpers ────────────────────────────────────────────────────

  @doc """
  Days a deletion-flagged org/project is retained before a purger (stage 4)
  hard-deletes it. Configurable via `config :platform, :container_retention_days`;
  defaults to 30.
  """
  @spec retention_days() :: pos_integer()
  def retention_days do
    Application.get_env(:platform, :container_retention_days, 30)
  end

  # Bridged into the append-only audit log by
  # `Platform.Audit.TelemetryHandler`. `extra` carries event-specific keys
  # (e.g. `retention_deadline`) and MUST be JSON-safe scalars.
  defp emit([_ | _] = event_name, actor, meta) do
    :telemetry.execute(
      event_name,
      %{system_time: System.system_time()},
      Map.merge(
        %{
          actor_id: actor && Map.get(actor, :id),
          actor_type: if(actor, do: "user", else: "system"),
          action: event_name |> List.last() |> Atom.to_string()
        },
        meta
      )
    )

    :ok
  end

  defp org_meta(%Org{} = org, extra) do
    Map.merge(
      %{
        resource_type: "org",
        resource_id: org.id,
        org_slug: org.slug,
        org_name: org.name
      },
      extra
    )
  end

  defp project_meta(%Project{} = project, extra) do
    Map.merge(
      %{
        resource_type: "project",
        resource_id: project.id,
        project_slug: project.slug,
        project_name: project.name,
        org_id: project.org_id
      },
      extra
    )
  end
end
