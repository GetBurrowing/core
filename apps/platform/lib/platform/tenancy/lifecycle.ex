defmodule Platform.Tenancy.Lifecycle do
  @moduledoc """
  Create / archive / schedule-deletion / restore lifecycle for the container
  resources — orgs and projects (task 019f4eaa stage 3; `create_org/2` added
  by task 019ffe9d stage 1).

  Mirrors the proven channel lifecycle in `Platform.Chat`
  (`archive_space/2`, `schedule_space_deletion/2`, …) but adds the two
  things containers need that a single channel does not:

    * **Root guard.** The root org (`tier == :root`) can never be
      archived or deleted — every org function returns
      `{:error, :not_deletable}` for it before touching the DB.

    * **Provenance-aware cascade.** Archiving or scheduling an org hides
      its child projects and chat_spaces in the SAME transaction, but
      only children that are not already archived on their own. Each
      cascade-hidden child records `archived_cascade_org_id = org.id` so
      the restore path can un-hide exactly (and only) the children this
      org drove — a child that was archived independently keeps a NULL
      `archived_cascade_org_id` and is therefore left hidden on restore.

  Authorization: every function requires a root-org admin actor. There
  is no creator carve-out (orgs and projects have no owner column) and no
  system path — a `nil`/non-admin actor gets `{:error, :unauthorized}`.
  The check is `Platform.Access.authorize_install/1` (task 01a1386d-fb6e
  stage 2), which replaced `Tenancy.root_admin?/1`. It answers the same for
  every internal actor and is STRICTER for exactly one class, the external
  root admin (guest dominates,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Root-admin carve-outs`),
  who is now refused here too. The `ExternalUserScope` plug already refuses
  that user over HTTP, so HTTP outcomes are unchanged.

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
  alias Platform.Access
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tasks.Task
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  @type actor :: map() | nil
  @type org_error :: :unauthorized | :not_deletable | :not_scheduled | :not_found
  @type project_error :: :unauthorized | :not_scheduled
  @type restore_error :: :unauthorized | :not_found

  # ── Org creation ──────────────────────────────────────────────────────

  @doc """
  Create a TENANT org — the write the tenancy context never had (task
  019ffe9d stage 1). Until this existed, every org in the system came from
  the seed migration `20260519143620_seed_root_orgs.exs`, so onboarding a
  client meant shipping a migration.

  Root-admin only, and deliberately actor-first arity-2 like every sibling
  in this module: creating an org is a *higher*-privilege act than archiving
  one, so it gets the same `{:error, :unauthorized}` gate rather than
  resting solely on the caller's route hook. There is no unauthenticated
  arity — an attrs-only `create_org/1` would be an unauthorized writer, and
  nothing in the system needs one.

  ## Parentage

  New orgs are tenants of the root org, and `:parent_org_id` is *derived*,
  not asked for: when the caller omits it, it defaults to the id of the row
  the DB itself calls root (the single `parent_org_id IS NULL` row behind
  the `orgs_single_root` partial unique index). An explicit `nil` is
  refused as a changeset error on `:parent_org_id` — see
  `require_tenant_parent/1` — because the alternative is a raised
  `Ecto.ConstraintError` that a form cannot render.

  ## Validation

  All of it already lives in `Platform.Tenancy.Org.changeset/2` — required
  name+slug, the `~r/^[a-z][a-z0-9_-]*$/` slug format, `unique_constraint(:slug)`
  paired with the real `unique_index(:orgs, [:slug])`, and the parent FK
  constraint. This function adds exactly one create-time rule (the tenant
  parent) and otherwise just wraps that changeset, so a duplicate slug comes
  back as `{:error, %Ecto.Changeset{}}` with an error on `:slug` rather than
  a 500.

  Accepts atom- or string-keyed attrs (LiveView form params are the latter).

  Emits `[:platform, :tenancy, :org_created]` AFTER the insert commits;
  the event is registered in `Platform.Audit.TelemetryHandler` `@events`
  so it bridges to an audit row.

  ## No registration step

  There is no compiled scope enum to register the new org in (task 01a14dd9
  stage 2 deleted the last one). Its scope chip, chat section dot and recolor
  swatch are driven by its row: it is coloured once an admin sets its
  `color_hue`.
  """
  @spec create_org(actor(), map()) ::
          {:ok, Org.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_org(actor, attrs) when is_map(attrs) do
    with_root_admin_authz(actor, fn ->
      changeset =
        %Org{}
        |> Org.changeset(put_default_parent(attrs))
        |> require_tenant_parent()

      # Ecto.Multi, not log-and-continue: an org row with no `channel_sections`
      # row is EXACTLY the half-made state task 01a00910 exists to clean up, so
      # the create either produces both or neither. The backfill migration stays
      # as the safety net for the orgs already in that state, not as a licence
      # to keep producing more.
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:org, changeset)
      |> Ecto.Multi.run(:section, fn _repo, %{org: org} ->
        Platform.Chat.Sidebar.ensure_default_section(org)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{org: %Org{} = org}} ->
          emit([:platform, :tenancy, :org_created], actor, org_meta(org, %{}))
          {:ok, org}

        {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    end)
  end

  # Default `:parent_org_id` to the root org when the caller omitted the key
  # entirely. A key that IS present — including one holding an explicit nil —
  # is left alone so `require_tenant_parent/1` can report it.
  #
  # The key has to be inserted in whichever style the caller used: LiveView
  # form params arrive string-keyed, internal callers use atoms, and Ecto's
  # `cast/3` raises on a map with MIXED key types.
  defp put_default_parent(attrs) do
    if Map.has_key?(attrs, :parent_org_id) or Map.has_key?(attrs, "parent_org_id") do
      attrs
    else
      case root_org_id() do
        nil -> attrs
        root_id -> Map.put(attrs, parent_key(attrs), root_id)
      end
    end
  end

  defp parent_key(attrs) do
    if Enum.any?(Map.keys(attrs), &is_binary/1), do: "parent_org_id", else: :parent_org_id
  end

  # The root org is resolved by STRUCTURE — the single row the
  # `orgs_single_root` partial unique index permits to have a NULL parent —
  # not by any slug, so a rename can never silently reparent new orgs.
  # Returns nil rather than raising when no root exists (a bare test DB);
  # `require_tenant_parent/1` then turns that into a changeset error instead
  # of a `Repo.get_by!` blow-up.
  defp root_org_id do
    Repo.one(from(o in Org, where: is_nil(o.parent_org_id), select: o.id))
  end

  # Refuse to even ATTEMPT a second root. `Org.changeset/2` does not require
  # `:parent_org_id` (the seeded root legitimately has none), and the
  # `orgs_single_root` index lives only in the DB with no matching
  # `unique_constraint`, so a nil parent reaching `Repo.insert/1` comes back
  # as a RAISED Ecto.ConstraintError — a 500, not something a form can render
  # on the field. Every org this function creates is a tenant.
  defp require_tenant_parent(%Ecto.Changeset{} = changeset) do
    if is_nil(Ecto.Changeset.get_field(changeset, :parent_org_id)) do
      Ecto.Changeset.add_error(
        changeset,
        :parent_org_id,
        "is required — a new org is a tenant of the root org"
      )
    else
      changeset
    end
  end

  # ── Org lifecycle ─────────────────────────────────────────────────────

  @doc """
  Soft-archive an org: set `archived_at` on the org and cascade-hide its
  not-already-archived projects and chat_spaces. Root-admin only; the root
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
  same cascade-hide as `archive_org/2`. Root-admin only; root returns
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
  Schedule an org for deletion, but let the admin choose per child which ones
  go with it. The "surface & choose" variant behind the Recovery-hub delete
  confirm (task 019f7600 stage 5).

  `keep_ids` is the set of child ids to SPARE. Every other child — active,
  cascade-hidden, OR independently/hand-archived — is swept: it inherits the
  org's own deletion clock + provenance marker so `ContainerPurger` hard-deletes
  it inside the org's retention window. A *kept* child is left as an
  independently-archived row (its own clock and provenance cleared) so it
  survives the org's deletion and stays recoverable on its own.

  This is deliberately broader than the plain `schedule_org_deletion/2`, whose
  cascade skips already-archived children (`unhidden_children_query`). That skip
  is why the old confirm's "Also hidden" list — built from the same query —
  silently omitted hand-archived items that would nonetheless be lost when the
  container was purged. Here every child is enumerated (see `purge_preview/1`)
  and the admin's include/keep decision is honored exactly.

  Root-admin only; root org returns `{:error, :not_deletable}`. Emits the same
  `[:platform, :tenancy, :org_deletion_scheduled]` event as `/2`.
  """
  @spec schedule_org_deletion(actor(), Org.t(), [binary()]) ::
          {:ok, Org.t()} | {:error, org_error() | Ecto.Changeset.t()}
  def schedule_org_deletion(actor, %Org{} = org, keep_ids) when is_list(keep_ids) do
    with_org_authz(actor, org, fn ->
      now = DateTime.utc_now()

      org_attrs =
        if org.archived_at,
          do: %{deletion_scheduled_at: now},
          else: %{archived_at: now, deletion_scheduled_at: now}

      deadline = DateTime.add(now, retention_days(), :day)

      hide_org_choosing(actor, org, org_attrs, now, keep_ids, %{
        retention_deadline: DateTime.to_iso8601(deadline)
      })
    end)
  end

  @doc """
  Reverse an archive: clear the org's own flags and un-hide ONLY the
  children this org cascade-hid (`archived_cascade_org_id == org.id`).
  Independently-archived children are left untouched. Root-admin only.
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
  Root-admin only.
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

  # Keep-aware hide (task 019f7600 stage 5). Like `hide_org`, but partitions the
  # org's children by the admin's include/keep choice instead of blindly cascading
  # the active ones:
  #
  #   * INCLUDED (any child NOT in `keep_ids`, whatever its current state) inherits
  #     the org's clock + provenance so the purger sweeps it with the org. Split in
  #     two so an already-archived included child keeps its original `archived_at`
  #     (only the clock + marker are added) while an active one is hidden now.
  #   * KEPT + active is hidden independently (own clock + provenance cleared) so it
  #     survives the org's deletion as a standalone recoverable row.
  #   * KEPT + already-archived is left entirely untouched.
  #
  # Telemetry fires only after commit.
  defp hide_org_choosing(actor, %Org{} = org, org_attrs, now, keep_ids, extra) do
    child_deletion = Map.get(org_attrs, :deletion_scheduled_at)

    Multi.new()
    |> Multi.update(:org, Org.changeset(org, org_attrs))
    |> put_child_choices(Project, org.id, keep_ids, child_deletion, now)
    |> put_child_choices(Space, org.id, keep_ids, child_deletion, now)
    |> Repo.transaction()
    |> case do
      {:ok, %{org: updated_org}} ->
        emit([:platform, :tenancy, :org_deletion_scheduled], actor, org_meta(updated_org, extra))
        {:ok, updated_org}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Three writes per child schema, keyed uniquely so both project and space
  # passes coexist in one Multi. See `hide_org_choosing/6` for the partitioning.
  defp put_child_choices(multi, schema, org_id, keep_ids, child_deletion, now) do
    tag = schema_key(schema)

    multi
    |> Multi.update_all(
      {:incl_sweep, tag},
      from(r in schema, where: r.org_id == ^org_id and r.id not in ^keep_ids),
      set: [
        deletion_scheduled_at: child_deletion,
        archived_cascade_org_id: org_id,
        updated_at: now
      ]
    )
    |> Multi.update_all(
      {:incl_hide, tag},
      from(r in schema,
        where: r.org_id == ^org_id and r.id not in ^keep_ids and is_nil(r.archived_at)
      ),
      set: [archived_at: now, updated_at: now]
    )
    |> Multi.update_all(
      {:keep_hide, tag},
      from(r in schema,
        where: r.org_id == ^org_id and r.id in ^keep_ids and is_nil(r.archived_at)
      ),
      set: [
        archived_at: now,
        deletion_scheduled_at: nil,
        archived_cascade_org_id: nil,
        updated_at: now
      ]
    )
  end

  defp schema_key(Project), do: :projects
  defp schema_key(Space), do: :spaces

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

  @doc """
  Restore an org's subtree, but let the admin keep specific cascade children on
  their deletion countdown (task 019f7600 stage 5). Backs the Recovery-hub
  "Restore all" warning modal.

  `keep_scheduled_ids` is the set of cascade children to LEAVE scheduled. Every
  other cascade child (`archived_cascade_org_id == org.id`) is fully un-hidden,
  exactly as `unarchive_org/2` / `cancel_org_deletion/2` would. A kept child
  keeps its own `archived_at` + `deletion_scheduled_at` (its original countdown,
  not a fresh one) and is detached from the cascade (`archived_cascade_org_id`
  cleared) so it becomes an independently-scheduled row — the purger still sweeps
  it on its own clock, and a later org action never touches it again.

  Passing `[]` is equivalent to the plain org restore: the whole subtree revives.
  The event mirrors the org's state — `:org_deletion_cancelled` for a scheduled
  org, `:org_unarchived` otherwise. Root-admin only; root is `:not_deletable`.

  Fixes the gap where restoring an org left a child it hid still counting down
  to a permanent purge with no way to say "revive everything except this one".
  """
  @spec restore_org_selective(actor(), Org.t(), [binary()]) ::
          {:ok, Org.t()} | {:error, org_error() | Ecto.Changeset.t()}
  def restore_org_selective(actor, %Org{} = org, keep_scheduled_ids)
      when is_list(keep_scheduled_ids) do
    with_org_authz(actor, org, fn ->
      event_name =
        if org.deletion_scheduled_at,
          do: [:platform, :tenancy, :org_deletion_cancelled],
          else: [:platform, :tenancy, :org_unarchived]

      do_restore_org_selective(actor, org, keep_scheduled_ids, event_name)
    end)
  end

  defp do_restore_org_selective(actor, %Org{} = org, keep_ids, event_name) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:verify, fn repo, _changes ->
      case repo.get(Org, org.id) do
        nil -> {:error, :not_found}
        %Org{} = fresh -> {:ok, fresh}
      end
    end)
    |> restore_cascade_children(Project, org.id, keep_ids, now)
    |> restore_cascade_children(Space, org.id, keep_ids, now)
    |> detach_kept_children(Project, org.id, keep_ids, now)
    |> detach_kept_children(Space, org.id, keep_ids, now)
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

  # Fully un-hide the cascade children the admin did NOT keep scheduled.
  defp restore_cascade_children(multi, schema, org_id, keep_ids, now) do
    Multi.update_all(
      multi,
      {:restore, schema_key(schema)},
      from(r in schema, where: r.archived_cascade_org_id == ^org_id and r.id not in ^keep_ids),
      set: [
        archived_at: nil,
        deletion_scheduled_at: nil,
        archived_cascade_org_id: nil,
        updated_at: now
      ]
    )
  end

  # Kept children keep their own clock (original countdown) but detach from the
  # cascade so they read as independently-scheduled rows and the org restore
  # never claims them.
  defp detach_kept_children(multi, schema, org_id, keep_ids, now) do
    Multi.update_all(
      multi,
      {:detach, schema_key(schema)},
      from(r in schema, where: r.archived_cascade_org_id == ^org_id and r.id in ^keep_ids),
      set: [archived_cascade_org_id: nil, updated_at: now]
    )
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

  Powers the confirm dialog's "here's what goes with it" list — the design call
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
    # Platform.UUID.cast/1, NOT Ecto.UUID.cast/1. Every guard in this module
    # discards the cast output and pins the ORIGINAL value downstream
    # (`where: p.id == ^org_id`), so it is RAISE-exposed: a bare cast accepts
    # any 16-byte binary, which then hits the strict UUIDv7 key inside Repo.
    case Platform.UUID.cast(org_id) do
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
  bring back. The design ask (2026-07-16), and the same instinct behind the
  confirm dialog's list: don't make someone restore a group without showing
  what's in it.

  Independently-archived children are correctly absent (NULL marker): Restore
  won't bring them back, so it must not claim it will.
  """
  @spec cascade_hidden(term()) :: %{projects: [String.t()], channels: [String.t()]}
  def cascade_hidden(org_id) when is_binary(org_id) do
    case Platform.UUID.cast(org_id) do
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

  @typedoc """
  One row of the org-delete "surface & choose" checklist: a child project or
  channel that would be lost with the org, with its current lifecycle state.

    * `:status` — `:active` (still live), `:archived` (hidden, no countdown), or
      `:scheduled` (already on a deletion clock).
  """
  @type purge_item :: %{
          id: binary(),
          name: String.t(),
          type: :project | :channel,
          status: :active | :archived | :scheduled
        }

  @doc """
  Every child that deleting this org would take with it — projects and channels,
  in EVERY state: active, cascade-hidden, and independently/hand-archived
  (task 019f7600 stage 5).

  The deliberate counterpart to `cascade_preview/1`. That one reuses the
  cascade's own `unhidden_children_query` and so lists only the ACTIVE children
  the cascade would newly hide — which means a child the admin archived by hand
  is absent from the "here's what goes" list even though it, too, is purged when
  the container is swept. `purge_preview/1` enumerates ALL of them so the delete
  confirm can show the complete blast radius and let the admin keep any of them.

  Takes a UUID (a non-UUID falls through to an empty list rather than raising
  against `UUIDv7`, matching `cascade_preview/1`). Sorted projects-then-channels,
  each group alphabetical, so the checklist reads like the Recovery table.
  """
  @spec purge_preview(term()) :: [purge_item()]
  def purge_preview(org_id) when is_binary(org_id) do
    case Platform.UUID.cast(org_id) do
      {:ok, _} -> do_purge_preview(org_id)
      :error -> []
    end
  end

  def purge_preview(_), do: []

  defp do_purge_preview(org_id) do
    projects =
      Project
      |> where([r], r.org_id == ^org_id)
      |> order_by([r], asc: r.name)
      |> select([r], %{
        id: r.id,
        name: r.name,
        archived_at: r.archived_at,
        deletion_scheduled_at: r.deletion_scheduled_at
      })
      |> Repo.all()
      |> Enum.map(&purge_item(&1, :project))

    channels =
      Space
      |> where([r], r.org_id == ^org_id and r.kind == "channel")
      |> order_by([r], asc: r.name)
      |> select([r], %{
        id: r.id,
        name: r.name,
        archived_at: r.archived_at,
        deletion_scheduled_at: r.deletion_scheduled_at
      })
      |> Repo.all()
      |> Enum.map(&purge_item(&1, :channel))

    projects ++ channels
  end

  defp purge_item(row, type) do
    %{id: row.id, name: row.name, type: type, status: purge_status(row)}
  end

  defp purge_status(%{deletion_scheduled_at: %DateTime{}}), do: :scheduled
  defp purge_status(%{archived_at: %DateTime{}}), do: :archived
  defp purge_status(_), do: :active

  # ── Recoverable inventory (Recovery hub read) ──────────────────────────

  @typedoc """
  One normalized recovery row — an archived or deletion-scheduled org,
  project, or channel. Flat by design: cascade children are their own rows,
  linked to the org that hid them via `:cascade_org_id`, so the Recovery hub
  UI (stage 4) can group/nest without the read imposing a shape.

    * `:id` — the recoverable item's OWN id (the org/project/channel id). The
      restore target the stage-3 mutation acts on; `:org` is the scope, not
      the thing being restored.
    * `:org` — the owning/scope `Org` the row concerns (the org itself for an
      `:org` row; the parent tenant for a project/channel), or `nil` for an
      org-less channel. Carries id/slug/name for grouping + display.
    * `:type` — `:org | :project | :channel`.
    * `:status` — TWO-STATE. `:scheduled` when the row is on a permanent-delete
      clock — its OWN `deletion_scheduled_at`, or (for a cascade child) the
      clock on the org that hid it; `:archived` otherwise.
    * `:cascade_org_id` — the org that cascade-hid this row, or `nil` for an
      independently-archived row or an org row. A non-nil value means the row
      returns only when that org is restored.

  Attribution (`deleted_by`) is deliberately absent: orgs/projects/channels
  carry no `archived_by` column. It lives in the append-only audit log
  (`Platform.Audit.list(resource_id: id)`) for a later stage to join in.
  """
  @type recoverable_row :: %{
          id: binary(),
          org: Org.t() | nil,
          name: String.t(),
          type: :org | :project | :channel,
          status: :archived | :scheduled,
          archived_at: DateTime.t(),
          deletion_scheduled_at: DateTime.t() | nil,
          cascade_org_id: binary() | nil
        }

  @doc """
  Every recoverable container — archived / deletion-scheduled orgs, projects,
  and channels — as one flat list of normalized `t:recoverable_row/0`s.

  The single read the Recovery hub LiveView (stage 4) and the selective-restore
  mutation (stage 3) consume. It folds together the three canonical recovery
  queries:

    * `Platform.Tenancy.list_archived_tenants/0` — archived orgs. Never the
      root: the root org can't be archived, so it never appears here.
    * `Platform.Tasks.list_recoverable_projects/0` — every archived project,
      independent AND cascade-hidden.
    * `Platform.Chat.list_archived_spaces/0` — every archived channel,
      independent AND cascade-hidden.

  Unlike the per-entity sidebars, cascade-hidden children ARE included — as
  their own rows tagged with `:cascade_org_id` — so the hub groups them under
  their org rather than hiding them. That is what makes selective restore
  possible.

  No actor argument: the recovery route is root-admin-gated at the LiveView
  (`PlatformWeb.LiveAuth.ensure_admin`), and every restore re-authorizes in
  the stage-3 mutation. This read is the admin's full recoverable inventory.
  """
  @spec list_recoverable() :: [recoverable_row()]
  def list_recoverable do
    orgs_by_id = Map.new(Tenancy.list_orgs(), &{&1.id, &1})

    org_rows = Enum.map(Tenancy.list_archived_tenants(), &org_row/1)

    project_rows =
      Enum.map(Platform.Tasks.list_recoverable_projects(), &project_row(&1, orgs_by_id))

    channel_rows =
      Enum.map(Platform.Chat.list_archived_spaces(), &channel_row(&1, orgs_by_id))

    org_rows ++ project_rows ++ channel_rows
  end

  defp org_row(%Org{} = org) do
    %{
      id: org.id,
      org: org,
      name: org.name,
      type: :org,
      status: if(is_nil(org.deletion_scheduled_at), do: :archived, else: :scheduled),
      archived_at: org.archived_at,
      deletion_scheduled_at: org.deletion_scheduled_at,
      cascade_org_id: nil
    }
  end

  defp project_row(%Project{} = project, orgs_by_id) do
    build_item_row(:project, project, project.org, orgs_by_id)
  end

  defp channel_row(%Space{} = space, orgs_by_id) do
    build_item_row(:channel, space, Map.get(orgs_by_id, space.org_id), orgs_by_id)
  end

  # Shared builder for the leaf entity types (project, channel). `owning_org`
  # is the scope org for display; the deletion clock is inherited from the org
  # named by `archived_cascade_org_id` when this row is a cascade child.
  defp build_item_row(type, item, owning_org, orgs_by_id) do
    cascade_org_id = item.archived_cascade_org_id
    cascade_org = cascade_org_id && Map.get(orgs_by_id, cascade_org_id)

    %{
      id: item.id,
      org: owning_org,
      name: item.name,
      type: type,
      status: item_status(item.deletion_scheduled_at, cascade_org),
      archived_at: item.archived_at,
      deletion_scheduled_at: item.deletion_scheduled_at,
      cascade_org_id: cascade_org_id
    }
  end

  # Two-state status. Scheduled when the row has its own deletion clock OR is a
  # cascade child of an org that does — so a child hidden by a *scheduled* org
  # reads `:scheduled` even though its own `deletion_scheduled_at` is NULL (the
  # pre-019f760f model keeps the retention clock only on the org).
  defp item_status(own_deletion_scheduled_at, cascade_org) do
    if is_nil(own_deletion_scheduled_at) and not scheduled_org?(cascade_org),
      do: :archived,
      else: :scheduled
  end

  defp scheduled_org?(%Org{deletion_scheduled_at: %DateTime{}}), do: true
  defp scheduled_org?(_), do: false

  defp with_org_authz(actor, %Org{} = org, fun) do
    cond do
      Access.authorize_install(actor) != :ok -> {:error, :unauthorized}
      Tenancy.tier(org) == :root -> {:error, :not_deletable}
      true -> fun.()
    end
  end

  # ── Project lifecycle (single-row; no children to cascade) ─────────────

  @doc """
  Soft-archive a single project (`archived_at`). Root-admin only.
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

  @doc "Reverse a project archive — clears both lifecycle flags. Root-admin only."
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
  (and `archived_at` when not already archived). Root-admin only.
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
  `{:error, :not_scheduled}` when no deletion is pending. Root-admin only.
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
    with :ok <- Access.authorize_install(actor), do: fun.()
  end

  # ── Selective restore (Recovery hub — task 019f7600 stage 3) ───────────

  @doc """
  Restore ONE archived project and reactivate its owning org, leaving every
  sibling the org cascade-hid exactly as it was. The Recovery-hub mutation for
  "bring back just this one" — the deliberate opposite of `unarchive_org/2`,
  which un-hides the whole cascade subtree.

  Clears only THIS project's own `archived_at`, its deletion clock, and its
  `archived_cascade_org_id` provenance marker, then clears the org's own flags
  so the restored project has a live parent. Sibling rows are never touched.

  Root-admin only: a selective restore resurrects the child's entire org, so
  creator-level access must not suffice (projects carry no creator column in
  any case). Emits `[:platform, :tasks, :project_unarchived]` for the project
  and, only when the org was actually hidden, `[:platform, :tenancy,
  :org_unarchived]` for the org — both AFTER commit.

  Returns `{:error, :not_found}` when the project was hard-deleted by the
  purger between the hub render and the click, `{:error, :unauthorized}` for a
  non-admin actor.
  """
  @spec restore_project_with_ancestors(actor(), Project.t()) ::
          {:ok, Project.t()} | {:error, restore_error() | Ecto.Changeset.t()}
  def restore_project_with_ancestors(actor, %Project{} = project) do
    with_root_admin_authz(actor, fn ->
      restore_child_with_ancestors(
        actor,
        Project,
        project,
        [:platform, :tasks, :project_unarchived],
        &project_meta/2
      )
    end)
  end

  @doc """
  Restore ONE archived channel and reactivate its owning org, leaving the org's
  other cascade children untouched. The channel counterpart of
  `restore_project_with_ancestors/2`.

  On success broadcasts `:sidebar_changed` on the acting admin's per-user
  sidebar topic (`Platform.Chat.PubSub`) so their chat sidebar re-reads and the
  restored channel reappears live — the freshness hook a project restore
  doesn't need (projects have no sidebar row).

  Root-admin only — deliberately STRICTER than `Chat.unarchive_space/2`, which
  also admits the space creator: resurrecting the whole org is a privileged act,
  so this mirrors the destructive `schedule_space_deletion/2` precedent that
  drops the creator. Emits `[:platform, :chat, :space_unarchived]` and, only
  when the org was hidden, `[:platform, :tenancy, :org_unarchived]`.

  Returns `{:error, :not_found}` if the channel was hard-deleted before the
  click, `{:error, :unauthorized}` for a non-admin actor.
  """
  @spec restore_space_with_ancestors(actor(), Space.t()) ::
          {:ok, Space.t()} | {:error, restore_error() | Ecto.Changeset.t()}
  def restore_space_with_ancestors(actor, %Space{} = space) do
    with_root_admin_authz(actor, fn ->
      with {:ok, restored} <-
             restore_child_with_ancestors(
               actor,
               Space,
               space,
               [:platform, :chat, :space_unarchived],
               &space_meta/2
             ) do
        broadcast_space_restored(actor)
        {:ok, restored}
      end
    end)
  end

  # One selective-restore transaction, shared by project and space. Mirrors
  # `restore_org/3`'s verify→update shape but inverts the scope: it brings back
  # exactly ONE child + reactivates its org, touching NO sibling row.
  #
  #   :verify — re-fetch the child; a hard delete by the purger between the
  #     hub render and the click yields {:error, :not_found}.
  #   :child  — clear the child's OWN archived_at, deletion clock, and cascade
  #     provenance marker.
  #   :org_before / :org — reactivate the owning org (clear its archived_at +
  #     deletion clock). `:org_before` preserves the pre-restore org so the
  #     post-commit emit fires org_unarchived ONLY when the org was genuinely
  #     hidden — never a phantom audit row for an already-active org (e.g. when
  #     restoring an independently-archived child).
  defp restore_child_with_ancestors(actor, schema, child, child_event, child_meta_fun) do
    Multi.new()
    |> Multi.run(:verify, fn repo, _changes ->
      case repo.get(schema, child.id) do
        nil -> {:error, :not_found}
        fresh -> {:ok, fresh}
      end
    end)
    |> Multi.update(:child, fn %{verify: fresh} ->
      schema.changeset(fresh, %{
        archived_at: nil,
        deletion_scheduled_at: nil,
        archived_cascade_org_id: nil
      })
    end)
    |> Multi.run(:org_before, fn repo, %{verify: fresh} ->
      {:ok, fetch_org(repo, fresh.org_id)}
    end)
    |> Multi.run(:org, fn repo, %{org_before: org_before} ->
      reactivate_org(repo, org_before)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{child: restored_child, org: org, org_before: org_before}} ->
        emit(child_event, actor, child_meta_fun.(restored_child, %{}))
        maybe_emit_org_unarchived(actor, org, org_before)
        {:ok, restored_child}

      {:error, :verify, :not_found, _changes} ->
        {:error, :not_found}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp fetch_org(_repo, nil), do: nil
  defp fetch_org(repo, org_id) when is_binary(org_id), do: repo.get(Org, org_id)

  # Clear the org's own lifecycle flags when it was hidden; a no-op returning
  # the row unchanged (or nil, for an org-less space) otherwise. Never touches
  # the org's cascade children — that is exactly what a selective restore must
  # NOT do.
  defp reactivate_org(_repo, nil), do: {:ok, nil}

  defp reactivate_org(repo, %Org{} = org) do
    if org_hidden?(org) do
      org
      |> Org.changeset(%{archived_at: nil, deletion_scheduled_at: nil})
      |> repo.update()
    else
      {:ok, org}
    end
  end

  defp org_hidden?(%Org{archived_at: %DateTime{}}), do: true
  defp org_hidden?(%Org{deletion_scheduled_at: %DateTime{}}), do: true
  defp org_hidden?(%Org{}), do: false

  # Emit org_unarchived only when the org was actually hidden before the
  # restore — keyed on the pre-restore snapshot, so reactivating an org that
  # was already active (independent-archive path) never writes a phantom row.
  defp maybe_emit_org_unarchived(actor, %Org{} = org, %Org{} = org_before) do
    if org_hidden?(org_before) do
      emit([:platform, :tenancy, :org_unarchived], actor, org_meta(org, %{}))
    else
      :ok
    end
  end

  defp maybe_emit_org_unarchived(_actor, _org, _org_before), do: :ok

  defp broadcast_space_restored(%{id: user_id}) when is_binary(user_id) do
    Platform.Chat.PubSub.broadcast_sidebar_changed(user_id)
  end

  defp broadcast_space_restored(_actor), do: :ok

  # Root-admin-only gate for selective restore, shared by both entity types.
  # Deliberately has NO creator carve-out (unlike `Chat.unarchive_space/2`):
  # restoring one cascade child reactivates its entire org, so creator-level
  # access must not suffice — the same precedent as the destructive
  # `schedule_space_deletion/2`. A nil / non-admin actor gets :unauthorized.
  defp with_root_admin_authz(actor, fun) do
    with :ok <- Access.authorize_install(actor), do: fun.()
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
    case Platform.UUID.cast(project_id) do
      {:ok, _} ->
        from(p in Project, where: p.id == ^project_id, select: p.archived_at)
        |> Repo.one()
        |> case do
          # nil is both "no such project" and "project not archived": the
          # query selects `archived_at`, so either way the project is writable.
          nil -> true
          _archived_at -> false
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
    case Platform.UUID.cast(task_id) do
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

  # Matches the space telemetry meta `Platform.Chat` emits
  # (`tap_space_lifecycle_telemetry/4`) so a channel restored here bridges to
  # the audit log with the same resource_type/shape as a channel archived there.
  defp space_meta(%Space{} = space, extra) do
    Map.merge(
      %{
        resource_type: "chat_space",
        resource_id: space.id,
        space_kind: space.kind,
        space_name: space.name
      },
      extra
    )
  end
end
