defmodule PlatformWeb.Tasks.LifecycleHooks do
  @moduledoc """
  Lifecycle hook module for container archive / schedule-deletion on the
  Tasks surface (task 019f4eaa stage 6; extracted in task 01a008f6 stage 7).

  Correctly a LifecycleHook rather than a LiveComponent under ADR 0035's
  criterion: the UI is *distributed* and there is almost no contiguous
  markup to own. The triggers are kebab menus rendered inside
  `TasksLive.SidebarComponent`; the two rendered surfaces are the shared
  `<.schedule_delete_modal>` and `<.archive_undo_toast>` function
  components, which stay as two lines in the shell template because pinned
  chrome must never nest inside an `:if` region.

  Owns:

    * Assigns: `:lifecycle_menu_key`, `:delete_modal`, `:undo_archive`
    * Events:  `"toggle_lifecycle_menu"`, `"archive_container"`,
      `"undo_archive"`, `"dismiss_undo_archive"`, `"open_delete_modal"`,
      `"close_delete_modal"`, `"delete_modal_change"`, `"delete_keep_all"`,
      `"delete_include_all"`, `"confirm_schedule_deletion"` (10 events —
      `open_delete_modal` has two clauses, org and non-org)

  Fabrikam-admin-only: the controls only render behind `@fabrikam_admin?`, and
  every call re-authorizes underneath in `Platform.Tenancy.Lifecycle`, so a
  forged event from a non-admin still gets `{:error, :unauthorized}`.

  ## No back-compat aliases

  These event names are UNCHANGED from the shell (no `lifecycle_` prefix).
  They are shared verbatim with `ChatLive`, which implements the identical
  set against the same `PlatformWeb.LifecycleActions` and renders the same
  `PlatformWeb.LifecycleControls` markup. Renaming them on one surface
  would fork a deliberately shared vocabulary; the events stay untargeted
  on both, which is what lets `LifecycleControls`' kebab markup be emitted
  from a component (`SidebarComponent`) and still land on the LiveView.

  ## Usage

      # In TasksLive.mount/3:
      socket = PlatformWeb.Tasks.LifecycleHooks.attach(socket)
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  import PlatformWeb.Components.LifecycleControls,
    only: [
      build_org_delete_modal: 3,
      delete_modal_apply_change: 2,
      delete_modal_include_all: 1,
      delete_modal_keep_all: 1
    ]

  alias Platform.Tasks
  alias Platform.Tenancy
  alias PlatformWeb.LifecycleActions
  alias PlatformWeb.Tasks.TaskDisplay

  @doc "Attach the container-lifecycle handlers. Call from `TasksLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:lifecycle_menu_key, nil)
    |> assign(:delete_modal, nil)
    |> assign(:undo_archive, nil)
    |> attach_hook(:tasks_lifecycle_events, :handle_event, &handle_event/3)
  end

  defp handle_event("toggle_lifecycle_menu", %{"key" => key}, socket) do
    next = if socket.assigns.lifecycle_menu_key == key, do: nil, else: key
    {:halt, assign(socket, :lifecycle_menu_key, next)}
  end

  # `id` for an org arrives as whatever the rail EMITTED, which while masking
  # is on is the per-session placeholder slug rather than the real one (task
  # 01a00cf1). Resolve it here, at the boundary, so everything downstream —
  # `LifecycleActions`, `:undo_archive`, `:delete_modal` — keeps seeing a real
  # slug and none of them needs to know masking exists.
  defp handle_event("archive_container", %{"type" => type, "id" => id} = params, socket) do
    id = resolve_container_id(socket, type, id)

    case LifecycleActions.archive(socket.assigns.current_user_record, type, id) do
      {:ok, resource} ->
        # An undo toast rather than a flash (Marlowe, 2026-07-16). Archive stays
        # instant + dialog-free — recoverable by default, undo not consent —
        # but it now SAYS what it took and keeps the reversal one click away.
        # Labels are read AFTER the archive on purpose: cascade_hidden reads
        # the provenance marker, which only exists once the cascade has run.
        {:halt,
         socket
         |> assign(:lifecycle_menu_key, nil)
         |> refresh_containers()
         |> assign(:undo_archive, %{
           type: type,
           id: id,
           name: params["name"] || Map.get(resource, :name, "it"),
           hidden: LifecycleActions.cascade_hidden_labels(type, id)
         })}

      {:error, reason} ->
        {:halt,
         socket
         |> assign(:lifecycle_menu_key, nil)
         |> put_flash(:error, LifecycleActions.error_message(reason))}
    end
  end

  defp handle_event("undo_archive", _params, socket) do
    case socket.assigns[:undo_archive] do
      nil ->
        {:halt, socket}

      %{type: type, id: id} ->
        case LifecycleActions.unarchive(socket.assigns.current_user_record, type, id) do
          {:ok, _resource} ->
            {:halt,
             socket
             |> assign(:undo_archive, nil)
             |> refresh_containers()
             |> put_flash(:info, "Restored.")}

          {:error, reason} ->
            {:halt,
             socket
             |> assign(:undo_archive, nil)
             |> put_flash(:error, LifecycleActions.error_message(reason))}
        end
    end
  end

  defp handle_event("dismiss_undo_archive", _params, socket) do
    {:halt, assign(socket, :undo_archive, nil)}
  end

  # Orgs open the "surface & choose" checklist (task 019f7600 stage 5):
  # deleting an org takes every child with it, so enumerate them ALL (active,
  # cascade-hidden, hand-archived) and let the admin keep any. NB: `id` is an
  # org SLUG on this surface; LifecycleActions resolves it.
  defp handle_event(
         "open_delete_modal",
         %{"type" => "org" = type, "id" => id, "name" => name},
         socket
       ) do
    id = resolve_container_id(socket, type, id)
    modal = build_org_delete_modal(id, name, LifecycleActions.purge_preview(type, id))

    {:halt, socket |> assign(:lifecycle_menu_key, nil) |> assign(:delete_modal, modal)}
  end

  # Projects have no children — the simple confirm (empty `preview`).
  defp handle_event("open_delete_modal", %{"type" => type, "id" => id, "name" => name}, socket) do
    {:halt,
     socket
     |> assign(:lifecycle_menu_key, nil)
     |> assign(:delete_modal, %{
       type: type,
       id: id,
       name: name,
       preview: LifecycleActions.cascade_preview(type, id)
     })}
  end

  defp handle_event("close_delete_modal", _params, socket) do
    {:halt, assign(socket, :delete_modal, nil)}
  end

  defp handle_event("delete_modal_change", params, socket) do
    {:halt, update_delete_modal(socket, &delete_modal_apply_change(&1, params))}
  end

  defp handle_event("delete_keep_all", _params, socket) do
    {:halt, update_delete_modal(socket, &delete_modal_keep_all/1)}
  end

  defp handle_event("delete_include_all", _params, socket) do
    {:halt, update_delete_modal(socket, &delete_modal_include_all/1)}
  end

  defp handle_event("confirm_schedule_deletion", _params, socket) do
    actor = socket.assigns.current_user_record

    case socket.assigns.delete_modal do
      # Org: honor the include/keep choices, gated on the acknowledgement.
      %{type: "org", acknowledged: true, id: id, kept: kept} ->
        result = LifecycleActions.schedule_deletion(actor, "org", id, MapSet.to_list(kept))
        {:halt, finish_schedule_deletion(socket, result)}

      # Gate not armed — ignore the submit, leave the modal open.
      %{type: "org"} ->
        {:halt, socket}

      %{type: type, id: id} ->
        result = LifecycleActions.schedule_deletion(actor, type, id)
        {:halt, finish_schedule_deletion(socket, result)}

      _ ->
        {:halt, assign(socket, :delete_modal, nil)}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # Orgs route by slug on this surface and the rail masks that slug; projects
  # route by UUID, which is not a name and is never aliased.
  defp resolve_container_id(socket, "org", id) when is_binary(id),
    do: TaskDisplay.real_org_slug(socket.assigns[:mask_labels] || %{}, id)

  defp resolve_container_id(_socket, _type, id), do: id

  # Only orgs carry the include/keep modal state; a project modal is a no-op.
  defp update_delete_modal(socket, fun) do
    case socket.assigns.delete_modal do
      %{type: "org"} = modal -> assign(socket, :delete_modal, fun.(modal))
      _ -> socket
    end
  end

  defp finish_schedule_deletion(socket, {:ok, _resource}) do
    socket
    |> assign(:delete_modal, nil)
    |> refresh_containers()
    |> put_flash(:info, "Scheduled for deletion. You can still restore it before then.")
  end

  defp finish_schedule_deletion(socket, {:error, reason}) do
    socket
    |> assign(:delete_modal, nil)
    |> put_flash(:error, LifecycleActions.error_message(reason))
  end

  @doc """
  Reload projects + recompute every container-derived assign after an
  archive / schedule-deletion so the archived row leaves the sidebar and an
  archived org drops off the scope rail without a page reload.

  Public because the shell's `{:sidebar_projects_changed}` notify needs the
  same recomputation for a create/rename.
  """
  def refresh_containers(socket) do
    projects = Tasks.list_projects_for_user(socket.assigns[:current_user_record], preload: :org)

    socket
    |> assign(:projects, projects)
    |> assign(:projects_by_org, Platform.Projects.group_by_org(projects))
    |> assign(:project_sections, project_sections(projects, socket.assigns[:current_user_record]))
    |> assign(:active_scope_keys, active_scope_keys(socket.assigns[:current_user_record]))
    |> PlatformWeb.Tasks.MaskHooks.assign_mask_labels()
  end

  @doc """
  Navigation-sidebar source (task 019f4eaa follow-up): every ACTIVE org the
  VIEWER BELONGS TO gets a section, even at zero projects, so archiving an
  org's last project can't erase its header — and with it the lifecycle
  kebab that archives the org itself.

  The org list is VIEWER-SCOPED (`list_active_tenants_for_user/1`). Grouping
  a correctly-scoped project list by the unscoped org list still rendered a
  header naming every foreign org at a `0` count — an existence leak in its
  own right. Every caller must therefore pass the viewer.
  """
  def project_sections(projects, viewer) do
    Platform.Projects.group_by_active_org(
      projects,
      Tenancy.list_active_tenants_for_user(viewer)
    )
  end

  @doc """
  Scope-rail source (task 019f4eaa stage 6; hardened by task 019fa209;
  viewer-scoped since): the scope atoms whose org is currently non-archived
  AND VISIBLE TO THIS VIEWER, in canonical tenant-priority order.

  The tenant read is `Tenancy.list_active_tenants_for_user/1` — the
  viewer-scoped sibling of `list_active_tenants_unscoped/0`, which leaked
  the NAMES of orgs the viewer has no membership in onto the rail. There is
  no zero-arity form on purpose: a viewer-less call must fail to COMPILE.
  Never re-add a `/0` shim, and never filter an unscoped tenant list at a
  call site — scope belongs in the viewer-taking context read.

  The allowlist-first construction below is UNCHANGED and must stay:
  `Tasks.scope_keys/0` filtered by active slugs, compared as STRINGS, never
  `String.to_atom/1` (nor `String.to_existing_atom/1`). That shape closes
  the two crash modes covered by the task-019fa209 regression tests;
  reverting to atom conversion re-opens a /tasks outage for every user.

  Org slugs are EXTERNALLY SUPPLIED — `Org.changeset/2` accepts any
  `^[a-z][a-z0-9_-]*$` and the tenant reads filter only on `archived_at`
  (plus membership), so an active tenant's slug may never have been compiled
  as an atom. Iterating the canonical allowlist and keeping the ones that
  are active creates no atom (`String.to_atom/1` would grow the never-GC'd
  atom table from user input) and looks none up (`String.to_existing_atom/1`
  raises `ArgumentError`, which 500'd /tasks for every user in the
  deployment — this runs in `mount/3`).

  Filtering rather than converting also closes a SECOND crash: a slug that
  happens to already exist as an atom but is not a scope (e.g. "name" ->
  `:name`, an Ecto field on `Org`) sails through `to_existing_atom/1` and
  reaches `<.scope_pill>`, whose `scope_label/1` and `slug/1` clauses are
  non-total -> `FunctionClauseError` at render. Both failures are why a
  `rescue ArgumentError` would be the wrong fix; starting from the allowlist
  makes every element a valid `<.scope_pill>` value by construction.

  An org outside the enum gets no chip. That is the only behavior the rest
  of the system supports: the enum is hardcoded in `ScopePill` (`@scopes` +
  `slug/1` + `scope_label/1`), `Tasks.@scope_keys`,
  `Tenancy.@scope_classes`/`@scope_labels`, and the `bg-<slug>` /
  `border-<slug>` / `text-<slug>-label` / `bg-<slug>-dot` utilities in
  assets/css/app.css.
  """
  def active_scope_keys(viewer) do
    active = MapSet.new(Tenancy.list_active_tenants_for_user(viewer), & &1.slug)

    Enum.filter(Tasks.scope_keys(), &MapSet.member?(active, Atom.to_string(&1)))
  end
end
