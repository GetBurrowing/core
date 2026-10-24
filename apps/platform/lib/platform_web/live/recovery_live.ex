defmodule PlatformWeb.RecoveryLive do
  @moduledoc """
  Recovery hub for archived / deletion-scheduled containers — orgs, projects,
  AND channels (task 019f7600 stage 4). The one place a root-org admin brings a
  retired container back.

  ## What changed from the stage-6 (019f4eaa) surface

  The old surface showed only *independently*-archived orgs and projects and
  offered a single per-row Restore. This rework reads the unified
  `Platform.Tenancy.Lifecycle.list_recoverable/0` (stage 2), which folds in
  channels and surfaces every cascade-hidden child as its OWN row grouped under
  the org that hid it. Three things follow:

    * **Grouping.** Org rows are containers; a container with cascade children
      shows an "N archived inside" toggle that expands to reveal those children
      as nested rows. Independently-archived projects/channels are their own
      top-level rows.

    * **Selective restore.** Every leaf row (project/channel) carries a checkbox.
      With ≥1 checked, a pinned bulk bar offers "Restore selected", which calls
      the stage-3 `restore_project_with_ancestors/2` /
      `restore_space_with_ancestors/2` per picked item — bringing back JUST that
      child and reactivating its org, leaving every sibling as-is. Containers
      keep a "Restore all" that brings back the whole subtree via the org
      unarchive/cancel path.

    * **Act-then-confirm toast.** There is no pre-action confirm. After a restore
      a success toast names the org side-effect ("Discovery restored · Initech
      reactivated too") with a View quick-link to the restored item and an Undo
      that re-archives just that item — reversible inside the retention window.

  root-admin-only gate is inherited from the `:admin` live_session's
  `PlatformWeb.LiveAuth.ensure_admin` hook; every restore re-authorizes
  underneath in `Platform.Tenancy.Lifecycle`.
  """
  use PlatformWeb, :live_view

  alias Platform.{Chat, Tasks, Tenancy}
  alias Platform.Tenancy.Lifecycle
  alias PlatformWeb.LifecycleActions

  # How long the success toast lingers before it auto-dismisses. Long enough to
  # read the org side-effect and reach for Undo; the timer is nonce-guarded so a
  # newer toast is never cleared by an older restore's timer.
  @toast_ttl_ms 8_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Recovery")
     |> assign(:expanded, MapSet.new())
     |> assign(:selected, %{})
     |> assign(:sort, {:deletes_on, :asc})
     |> assign(:org_filter, nil)
     |> assign(:toast, nil)
     |> assign(:restore_modal, nil)
     |> load()}
  end

  # ── Selection ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_select", %{"type" => type, "id" => id}, socket) do
    key = "#{type}:#{id}"
    selected = socket.assigns.selected

    selected =
      if Map.has_key?(selected, key) do
        Map.delete(selected, key)
      else
        case find_row(socket, type, id) do
          nil -> selected
          row -> Map.put(selected, key, row)
        end
      end

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected, %{})}
  end

  # ── Restore ────────────────────────────────────────────────────────────

  def handle_event("restore_selected", _params, socket) do
    items = Map.values(socket.assigns.selected)
    do_restore(socket, items, :items)
  end

  def handle_event("restore_all", %{"id" => id}, socket) do
    case find_row(socket, "org", id) do
      nil ->
        {:noreply, socket}

      row ->
        children = Map.get(socket.assigns.children_by_org, id, [])
        scheduled = Enum.filter(children, &(&1.status == :scheduled))

        if scheduled == [] do
          # Nothing counting down — restore the whole subtree straight away.
          do_restore(socket, [row], {:subtree, length(children)})
        else
          # Some children are on a delete clock: warn first, and let the admin
          # keep any of them scheduled instead of silently cancelling their
          # countdown (task 019f7600 stage 5).
          {:noreply,
           assign(
             socket,
             :restore_modal,
             build_restore_modal(row, scheduled, socket.assigns.retention_days)
           )}
        end
    end
  end

  def handle_event("toggle_keep_scheduled", %{"id" => id}, socket) do
    case socket.assigns.restore_modal do
      %{kept: kept} = modal ->
        {:noreply, assign(socket, :restore_modal, %{modal | kept: toggle_member(kept, id)})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_restore_modal", _params, socket) do
    {:noreply, assign(socket, :restore_modal, nil)}
  end

  def handle_event("confirm_restore_all", _params, socket) do
    case socket.assigns.restore_modal do
      %{org: %{id: id} = org_ref, kept: kept} ->
        total_children = length(Map.get(socket.assigns.children_by_org, id, []))
        socket = assign(socket, :restore_modal, nil)

        result =
          case Tenancy.get_org(id) do
            nil -> {:error, :not_found}
            org -> Lifecycle.restore_org_selective(actor(socket), org, MapSet.to_list(kept))
          end

        case result do
          {:ok, _restored} ->
            restored_count = max(0, total_children - MapSet.size(kept))
            toast = build_toast([{org_ref, result}], {:subtree, restored_count})
            {:noreply, socket |> load() |> maybe_toast(toast)}

          {:error, reason} ->
            {:noreply,
             socket |> load() |> put_flash(:error, LifecycleActions.error_message(reason))}
        end

      _ ->
        {:noreply, assign(socket, :restore_modal, nil)}
    end
  end

  def handle_event("undo_restore", _params, socket) do
    actor = actor(socket)
    refs = (socket.assigns.toast || %{}) |> Map.get(:undo, [])
    Enum.each(refs, fn %{type: type, id: id} -> rearchive(actor, type, id) end)

    {:noreply,
     socket
     |> assign(:toast, nil)
     |> load()
     |> put_flash(:info, undo_flash(refs))}
  end

  def handle_event("dismiss_toast", _params, socket) do
    {:noreply, assign(socket, :toast, nil)}
  end

  # ── View controls (sort / filter / expand) ─────────────────────────────

  def handle_event("sort", %{"key" => key}, socket) do
    key_atom = sort_key(key)
    {current_key, current_dir} = socket.assigns.sort
    dir = if current_key == key_atom and current_dir == :asc, do: :desc, else: :asc

    {:noreply, socket |> assign(:sort, {key_atom, dir}) |> refresh_display()}
  end

  def handle_event("filter_org", %{"org" => org}, socket) do
    filter = if org == "", do: nil, else: org
    {:noreply, socket |> assign(:org_filter, filter) |> refresh_display()}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    {:noreply, assign(socket, :expanded, toggle_member(socket.assigns.expanded, id))}
  end

  @impl true
  def handle_info({:clear_toast, nonce}, socket) do
    case socket.assigns.toast do
      %{nonce: ^nonce} -> {:noreply, assign(socket, :toast, nil)}
      _ -> {:noreply, socket}
    end
  end

  # ── Restore orchestration ──────────────────────────────────────────────

  # Restore a batch of items, then reload. `mode` is `:items` (leaf selective
  # restore) or `{:subtree, child_count}` (a container "Restore all"). Toast
  # facts are captured from the pre-reload item snapshots, so the toast can name
  # the org side-effect even though `list_recoverable/0` no longer shows it.
  defp do_restore(socket, [], _mode), do: {:noreply, socket}

  defp do_restore(socket, items, mode) do
    actor = actor(socket)
    results = Enum.map(items, fn item -> {item, restore_item(actor, item)} end)
    {ok, errors} = Enum.split_with(results, fn {_item, result} -> match?({:ok, _}, result) end)

    toast = if ok == [], do: nil, else: build_toast(ok, mode)

    {:noreply,
     socket
     |> assign(:selected, %{})
     |> load()
     |> maybe_error_flash(errors)
     |> maybe_toast(toast)}
  end

  # Resolve a row to its live struct and call the right stage-3 restore. Leaf
  # rows bring back just themselves + reactivate their org; an org row brings
  # back its whole subtree via the unarchive/cancel path.
  defp restore_item(actor, %{type: :project, id: id}) do
    case Tasks.get_project(id) do
      nil -> {:error, :not_found}
      project -> Lifecycle.restore_project_with_ancestors(actor, project)
    end
  end

  defp restore_item(actor, %{type: :channel, id: id}) do
    case Chat.get_space(id) do
      nil -> {:error, :not_found}
      space -> Lifecycle.restore_space_with_ancestors(actor, space)
    end
  end

  defp restore_item(actor, %{type: :org, id: id, status: :scheduled}),
    do: LifecycleActions.cancel_deletion(actor, "org", id)

  defp restore_item(actor, %{type: :org, id: id}),
    do: LifecycleActions.unarchive(actor, "org", id)

  # Undo = re-archive JUST the restored item (reversible inside the retention
  # window). A leaf that was reactivated alongside its org re-archives on its
  # own, becoming an independently-archived row again; the org stays active.
  defp rearchive(actor, "project", id) do
    case Tasks.get_project(id) do
      nil -> :ok
      project -> Tasks.archive_project(actor, project)
    end
  end

  defp rearchive(actor, "channel", id) do
    case Chat.get_space(id) do
      nil -> :ok
      space -> Chat.archive_space(actor, space)
    end
  end

  defp rearchive(actor, "org", id) do
    case Tenancy.get_org(id) do
      nil -> :ok
      org -> Tenancy.archive_org(actor, org)
    end
  end

  defp maybe_error_flash(socket, []), do: socket

  defp maybe_error_flash(socket, [{_item, {:error, reason}} | _]),
    do: put_flash(socket, :error, LifecycleActions.error_message(reason))

  defp maybe_toast(socket, nil), do: socket

  defp maybe_toast(socket, toast) do
    nonce = System.unique_integer([:positive])
    Process.send_after(self(), {:clear_toast, nonce}, @toast_ttl_ms)
    assign(socket, :toast, Map.put(toast, :nonce, nonce))
  end

  # ── Toast copy ─────────────────────────────────────────────────────────

  # "Restore all" on a container: name the org and how many children came with it.
  defp build_toast([{%{type: :org} = org_row, _restored}] = ok, {:subtree, child_count}) do
    suffix =
      if child_count > 0,
        do: " · #{child_count} #{pluralize(child_count, "item")} brought back",
        else: ""

    %{
      message: "#{org_row.name} restored#{suffix}",
      view_path: nil,
      undo: Enum.map(ok, fn {item, _} -> undo_ref(item) end)
    }
  end

  # Leaf selective restore: name the item(s) and any org reactivated as a
  # side-effect (deduped — two children of one org reactivate it once).
  defp build_toast(ok, :items) do
    names = Enum.map(ok, fn {item, _} -> item.name end)

    reactivated =
      ok
      |> Enum.map(fn {item, _} -> item.org end)
      |> Enum.filter(&org_hidden?/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(& &1.name)

    head =
      case names do
        [one] -> "#{one} restored"
        many -> "#{length(many)} items restored"
      end

    react_suffix =
      case reactivated do
        [] -> ""
        [org] -> " · #{org} reactivated too"
        orgs -> " · #{length(orgs)} orgs reactivated"
      end

    # View link only for a SINGLE successful leaf restore — unwrap the
    # `{:ok, struct}` result to the bare struct `view_path/2` matches on.
    # Anything else (a multi-item batch, or an `{:error, _}` that slipped
    # through) yields no link.
    view_path =
      case ok do
        [{item, {:ok, restored}}] -> view_path(item, restored)
        _ -> nil
      end

    %{
      message: head <> react_suffix,
      view_path: view_path,
      undo: Enum.map(ok, fn {item, _} -> undo_ref(item) end)
    }
  end

  defp undo_ref(%{type: type, id: id}), do: %{type: to_string(type), id: id}

  defp undo_flash([_]), do: "Re-archived. It's back in Recovery."
  defp undo_flash(refs), do: "Re-archived #{length(refs)} items. They're back in Recovery."

  # A restored channel opens in chat; a restored project opens its file store.
  # Orgs have no standalone page, so their toast carries no View link.
  defp view_path(%{type: :channel}, %{slug: slug}) when is_binary(slug), do: ~p"/chat/#{slug}"
  defp view_path(%{type: :project}, %{id: id}), do: ~p"/files/#{id}"
  defp view_path(_item, _restored), do: nil

  # Shape the "Restore all" warning modal (task 019f7600 stage 5): the scheduled
  # children with their absolute delete date, formatted with the SAME helper the
  # Recovery table's "Deletes on" column uses so the two never drift. `kept`
  # starts empty — the default is to restore (cancel the countdown of) them all.
  defp build_restore_modal(org_row, scheduled_children, retention_days) do
    %{
      # Carries `type: :org` so the shared `build_toast/2` subtree clause + its
      # `undo_ref/1` match the same shape a recovery row has.
      org: %{id: org_row.id, name: org_row.name, type: :org},
      children:
        Enum.map(scheduled_children, fn child ->
          %{
            id: child.id,
            name: child.name,
            type: child.type,
            delete_on: format_date(permanent_delete_at(scheduled_at(child), retention_days))
          }
        end),
      kept: MapSet.new()
    }
  end

  # ── Data loading + display shaping ─────────────────────────────────────

  # Read the unified recoverable inventory and recompute the display. Called on
  # mount and after every restore/undo so the hub stays live without a reload.
  defp load(socket) do
    socket
    |> assign(:rows, Lifecycle.list_recoverable())
    |> assign(:retention_days, Lifecycle.retention_days())
    |> refresh_display()
    |> prune_selection()
  end

  # Split the flat inventory into containers, their cascade children (grouped
  # under the org that hid them), and independent leaves; then filter + sort the
  # top-level rows. Recomputed on any sort/filter change without re-reading.
  defp refresh_display(socket) do
    rows = socket.assigns.rows
    {containers, leaves} = Enum.split_with(rows, &(&1.type == :org))
    {children, independents} = Enum.split_with(leaves, & &1.cascade_org_id)

    children_by_org =
      children
      |> Enum.group_by(& &1.cascade_org_id)
      |> Map.new(fn {org_id, kids} -> {org_id, Enum.sort_by(kids, &String.downcase(&1.name))} end)

    top_level =
      (containers ++ independents)
      |> filter_by_org(socket.assigns.org_filter)
      |> sort_rows(socket.assigns.sort)

    socket
    |> assign(:children_by_org, children_by_org)
    |> assign(:top_level, top_level)
    |> assign(:org_options, org_options(rows))
  end

  # Drop selected keys for rows that no longer exist (restored away) so the bulk
  # bar count never counts a ghost.
  defp prune_selection(socket) do
    valid = MapSet.new(socket.assigns.rows, &row_key/1)

    selected =
      socket.assigns.selected
      |> Enum.filter(fn {key, _row} -> MapSet.member?(valid, key) end)
      |> Map.new()

    assign(socket, :selected, selected)
  end

  defp filter_by_org(rows, nil), do: rows

  defp filter_by_org(rows, org_id) do
    Enum.filter(rows, fn
      %{type: :org, id: id} -> id == org_id
      %{org: %{id: id}} -> id == org_id
      _ -> false
    end)
  end

  defp sort_rows(rows, {key, :desc}), do: Enum.sort_by(rows, &comparable(&1, key), :desc)
  defp sort_rows(rows, {key, _asc}), do: Enum.sort_by(rows, &comparable(&1, key))

  # Every comparable ends in the downcased name so equal primary keys fall back
  # to a stable alphabetical order.
  defp comparable(row, key), do: {primary(row, key), String.downcase(row.name)}

  defp primary(row, :org), do: row |> org_name() |> String.downcase()
  defp primary(row, :name), do: String.downcase(row.name)
  defp primary(row, :type), do: type_rank(row.type)
  defp primary(row, :status), do: status_rank(row.status)
  defp primary(row, :archived_at), do: date_key(row.archived_at)
  defp primary(row, :deletes_on), do: date_key(deletes_on(row))

  # A missing date sorts AFTER any real one in ascending order (archived rows
  # with no deadline follow scheduled rows), regardless of type.
  defp date_key(nil), do: {1, 0}
  defp date_key(%DateTime{} = dt), do: {0, DateTime.to_unix(dt, :microsecond)}

  defp org_options(rows) do
    rows
    |> Enum.map(& &1.org)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&String.downcase(&1.name))
    |> Enum.map(&{&1.name, &1.id})
  end

  # ── Row function component ─────────────────────────────────────────────

  attr(:row, :map, required: true)
  attr(:retention_days, :integer, required: true)
  attr(:selected, :boolean, default: false)
  attr(:selectable, :boolean, default: true)
  attr(:expandable, :boolean, default: false)
  attr(:expanded, :boolean, default: false)
  attr(:child_count, :integer, default: 0)
  attr(:indent, :boolean, default: false)

  defp recovery_row(assigns) do
    ~H"""
    <tr
      data-role="recovery-row"
      data-type={@row.type}
      data-id={@row.id}
      data-status={@row.status}
      class={[
        "border-b border-edge/50 last:border-0 transition-colors hover:bg-base-200/40",
        @row.type == :org && "bg-base-200/40",
        @indent && "bg-base-200/20"
      ]}
    >
      <td class="w-10 px-4 py-3 align-top">
        <input
          :if={@selectable}
          type="checkbox"
          data-role="select"
          checked={@selected}
          phx-click="toggle_select"
          phx-value-type={@row.type}
          phx-value-id={@row.id}
          class="checkbox checkbox-primary checkbox-sm [--radius-selector:0.25rem] focus-visible-ring"
          aria-label={"Select #{@row.name}"}
        />
      </td>

      <td class="px-4 py-3 text-base-content">
        <div class="flex min-w-0 items-center gap-2">
          <span
            :if={org_scope_slug(@row)}
            class="size-2 shrink-0 rounded-full scope-dot-current"
            data-scope={org_scope_slug(@row)}
            aria-hidden="true"
          />
          <span class="truncate">{org_name(@row)}</span>
        </div>
      </td>

      <td class="px-4 py-3">
        <div class={["flex min-w-0 items-center gap-2.5", @indent && "pl-8"]}>
          <.icon name={kind_icon(@row.type)} class="size-4 shrink-0 text-subtle" />
          <span class="truncate font-medium text-base-content">{@row.name}</span>
        </div>
        <button
          :if={@expandable}
          type="button"
          phx-click="toggle_expand"
          phx-value-id={@row.id}
          data-role="expand-toggle"
          class="focus-visible-ring mt-1.5 inline-flex items-center gap-1 rounded pl-[26px] text-xs text-subtle hover:text-base-content"
          aria-expanded={@expanded}
        >
          <.icon
            name={if(@expanded, do: "hero-chevron-down", else: "hero-chevron-right")}
            class="size-3.5"
          />
          {@child_count} archived inside
        </button>
      </td>

      <td class="px-4 py-3 text-base-content">{type_label(@row.type)}</td>

      <td class="px-4 py-3">
        <.chip :if={@row.status == :scheduled} tone="warning">Scheduled for deletion</.chip>
        <.chip :if={@row.status == :archived} tone="neutral">Archived</.chip>
      </td>

      <td class="whitespace-nowrap px-4 py-3 tabular-nums text-base-content">
        {format_date(@row.archived_at)}
      </td>

      <td class="whitespace-nowrap px-4 py-3">
        <%= if @row.status == :scheduled do %>
          <% {tone, label} = runway(scheduled_at(@row), @retention_days) %>
          <div class="flex flex-col leading-tight">
            <span class={["tabular-nums", deadline_class(tone)]}>
              {format_date(permanent_delete_at(scheduled_at(@row), @retention_days))}
            </span>
            <span class="text-xs text-subtle">{label}</span>
          </div>
        <% else %>
          <span class="text-subtle">—</span>
        <% end %>
      </td>

      <td class="px-4 py-3">
        <div class="flex items-center justify-end">
          <.button
            :if={@row.type == :org}
            variant="primary"
            phx-click="restore_all"
            phx-value-id={@row.id}
            data-role="restore-all"
            class="btn btn-primary btn-xs focus-visible-ring"
          >
            <.icon name="hero-arrow-uturn-left" class="size-3.5" />
            {if @child_count > 0, do: "Restore all", else: "Restore"}
          </.button>
        </div>
      </td>
    </tr>
    """
  end

  attr(:sort, :any, required: true)
  attr(:key, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:align, :string, default: "text-left")

  defp sort_header(assigns) do
    {active_key, dir} = assigns.sort
    assigns = assign(assigns, active?: active_key == assigns.key, dir: dir)

    ~H"""
    <th class={["px-4 py-2.5", @align]}>
      <button
        type="button"
        phx-click="sort"
        phx-value-key={@key}
        class="focus-visible-ring group inline-flex items-center gap-1 rounded hover:text-base-content"
        aria-label={"Sort by #{@label}"}
      >
        {@label}
        <.icon
          name={sort_caret(@active?, @dir)}
          class={[
            "size-3",
            if(@active?,
              do: "text-base-content",
              else: "text-subtle group-hover:text-subtle"
            )
          ]}
        />
      </button>
    </th>
    """
  end

  defp sort_caret(false, _dir), do: "hero-chevron-up-down"
  defp sort_caret(true, :desc), do: "hero-chevron-down"
  defp sort_caret(true, _asc), do: "hero-chevron-up"

  # ── Template-facing helpers ────────────────────────────────────────────

  @doc false
  def row_key(%{type: type, id: id}), do: "#{type}:#{id}"

  defp selected?(selected, row), do: Map.has_key?(selected, row_key(row))
  defp children?(children_by_org, org_id), do: Map.has_key?(children_by_org, org_id)
  defp child_count(children_by_org, org_id), do: length(Map.get(children_by_org, org_id, []))

  defp org_name(%{org: %{name: name}}), do: name
  defp org_name(_row), do: "—"

  # Org slug driving the scope-color dot in the Org column — the same
  # org-identity marker the tasks/chat sidebars carry on their section
  # headers. Nil (no dot) when the row has no resolvable org.
  defp org_scope_slug(%{org: %{slug: slug}}) when is_binary(slug), do: slug
  defp org_scope_slug(_row), do: nil

  defp type_label(:org), do: "Org"
  defp type_label(:project), do: "Project"
  defp type_label(:channel), do: "Channel"

  defp kind_icon(:org), do: "hero-building-office-2"
  defp kind_icon(:project), do: "hero-folder"
  defp kind_icon(:channel), do: "hero-hashtag"

  defp type_rank(:org), do: 0
  defp type_rank(:project), do: 1
  defp type_rank(:channel), do: 2

  # Scheduled (on a delete clock) is the state that needs attention — it sorts
  # first when sorting by status ascending.
  defp status_rank(:scheduled), do: 0
  defp status_rank(:archived), do: 1

  # The effective deletion clock: a row's own, or (for a cascade child whose org
  # holds the clock) the owning org's. Nil for a purely-archived row.
  defp scheduled_at(%{deletion_scheduled_at: %DateTime{} = at}), do: at
  defp scheduled_at(%{org: %{deletion_scheduled_at: %DateTime{} = at}}), do: at
  defp scheduled_at(_row), do: nil

  # Sort key for "Deletes on". The permanent-delete date is `scheduled_at +
  # retention_days`, a monotonic shift that never changes ordering, so the raw
  # scheduled clock is a cheaper, order-equivalent key.
  defp deletes_on(row), do: scheduled_at(row)

  defp org_hidden?(%{archived_at: %DateTime{}}), do: true
  defp org_hidden?(%{deletion_scheduled_at: %DateTime{}}), do: true
  defp org_hidden?(_row), do: false

  @doc "Permanent-delete date for a scheduled row: `scheduled_at + retention_days`."
  def permanent_delete_at(nil, _retention_days), do: nil

  def permanent_delete_at(%DateTime{} = scheduled_at, retention_days),
    do: DateTime.add(scheduled_at, retention_days, :day)

  @doc "Compact date label (e.g. `Jul 15, 2026`); em-dash for nil."
  def format_date(nil), do: "—"
  def format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y")

  # Tint the permanent-delete date as the window closes (mirrors runway tone).
  defp deadline_class("error"), do: "text-error font-medium"
  defp deadline_class("warning"), do: "text-warning"
  defp deadline_class(_neutral), do: "text-base-content"

  @doc """
  Retention runway for a scheduled row: `{tone, label}` where tone
  graduates neutral → warning → error as the window closes. Pure
  presentation — the deadline is `scheduled_at + retention_days`.
  """
  def runway(deletion_scheduled_at, retention_days, now \\ DateTime.utc_now())

  def runway(nil, _retention_days, _now), do: {"neutral", ""}

  def runway(%DateTime{} = deletion_scheduled_at, retention_days, now) do
    deadline = DateTime.add(deletion_scheduled_at, retention_days, :day)
    days_left = max(0, ceil(DateTime.diff(deadline, now, :second) / 86_400))

    tone =
      cond do
        days_left <= 2 -> "error"
        days_left <= 7 -> "warning"
        true -> "neutral"
      end

    {tone, runway_label(days_left)}
  end

  defp runway_label(0), do: "Deletes today"
  defp runway_label(1), do: "Deletes tomorrow"
  defp runway_label(n), do: "Deletes in #{n} days"

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  defp sort_key("org"), do: :org
  defp sort_key("name"), do: :name
  defp sort_key("type"), do: :type
  defp sort_key("status"), do: :status
  defp sort_key("archived_at"), do: :archived_at
  defp sort_key("deletes_on"), do: :deletes_on
  defp sort_key(_other), do: :deletes_on

  defp toggle_member(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp find_row(socket, type, id) do
    Enum.find(socket.assigns.rows, fn row -> to_string(row.type) == type and row.id == id end)
  end

  defp actor(socket), do: socket.assigns[:current_user_record]
end
