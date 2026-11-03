defmodule PlatformWeb.AccessRolesLive do
  @moduledoc """
  The Custom roles admin page (task `01a1a2e4-9265` stage 4): a plain table
  of an org's custom roles with create, edit, assign and a confirmed
  unassign. Built-in roles are listed read-only.

  `PlatformWeb.ModuleGate` admits the page on `access.manage` held ANYWHERE,
  so it is not the authorization for a write. Every event rebuilds the
  viewer's Scope and calls `Platform.Access.RoleAdmin`, which re-checks
  `Effective.manages_org?/2` for the specific role's org.
  """
  use PlatformWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Access.{Effective, PermissionLabels, Registry, Role, RoleAdmin, Roles, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Repo
  alias Platform.Tenancy.{Org, OrgMembership}

  @forbidden "Only an org admin can change roles."
  @builtin "Built-in roles can't be edited."

  @impl true
  def mount(_params, _session, socket) do
    scope = fresh(socket)
    orgs = managed_orgs(scope)

    {:ok,
     socket
     |> assign(
       page_title: "Custom roles",
       orgs: orgs,
       org_id: orgs |> List.first() |> then(&(&1 && &1.id)),
       editor: nil,
       builtin_edit?: false,
       confirm: nil
     )
     |> load(scope)}
  end

  @impl true
  def handle_params(%{"key" => segment}, _uri, socket) do
    scope = fresh(socket)

    case segment |> key_from_segment() |> Roles.get_role() do
      %Role{builtin: true} ->
        {:noreply, assign(socket, editor: nil, builtin_edit?: true, confirm: nil)}

      %Role{} = role ->
        case RoleAdmin.list_assignments_for_role(scope, role.key) do
          {:ok, assignments} ->
            {:noreply,
             socket
             |> assign(org_id: role.org_id, builtin_edit?: false, confirm: nil)
             |> load(scope)
             |> assign(:editor, editor_for(role, assignments))}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(editor: nil, builtin_edit?: false)
             |> put_flash(:error, @forbidden)}
        end

      nil ->
        {:noreply,
         socket
         |> assign(editor: nil, builtin_edit?: false)
         |> put_flash(:error, "Role not found.")}
    end
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, assign(socket, editor: nil, builtin_edit?: false, confirm: nil)}

  # ── events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_org", %{"org_id" => org_id}, socket) do
    scope = fresh(socket)

    if Enum.any?(socket.assigns.orgs, &(&1.id == org_id)),
      do: {:noreply, socket |> assign(org_id: org_id, editor: nil) |> load(scope)},
      else: {:noreply, put_flash(socket, :error, @forbidden)}
  end

  def handle_event("new_role", _params, socket) do
    if socket.assigns.org_id,
      do:
        {:noreply,
         assign(socket, :editor, %{
           key: nil,
           name: "",
           permissions: [],
           assignments: [],
           error: nil
         })},
      else: {:noreply, put_flash(socket, :error, @forbidden)}
  end

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, socket |> assign(editor: nil) |> push_patch(to: ~p"/access/roles")}

  def handle_event("save_role", params, socket) do
    scope = fresh(socket)
    key = blank_to_nil(Map.get(params, "key"))
    name = params |> Map.get("name", "") |> String.trim()

    permissions =
      params |> Map.get("permissions", []) |> List.wrap() |> Enum.reject(&(&1 == ""))

    attrs = %{name: name, permissions: permissions}

    result =
      if key,
        do: RoleAdmin.update_role(scope, key, attrs),
        else: RoleAdmin.create_role(scope, socket.assigns.org_id || "", attrs)

    case result do
      {:ok, role} ->
        {:noreply,
         socket
         |> load(scope)
         |> put_flash(:info, "Role saved.")
         |> push_patch(to: role_path(role.key))}

      {:error, reason} when reason in [:forbidden, :builtin] ->
        {:noreply, put_flash(socket, :error, flash_for(reason))}

      {:error, reason} ->
        editor =
          (socket.assigns.editor || %{key: key, assignments: []})
          |> Map.merge(%{name: name, permissions: permissions, error: save_error(reason)})

        {:noreply, assign(socket, :editor, editor)}
    end
  end

  def handle_event("delete_role", %{"key" => key}, socket) do
    scope = fresh(socket)

    case RoleAdmin.delete_role(scope, key) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(editor: nil)
         |> load(scope)
         |> put_flash(:info, "Role deleted.")
         |> push_patch(to: ~p"/access/roles")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, flash_for(reason))}
    end
  end

  def handle_event("assign_role", %{"key" => key, "principal" => principal}, socket) do
    scope = fresh(socket)

    with {:ok, principal} <- parse_principal(principal),
         {:ok, _} <- RoleAdmin.assign(scope, key, principal) do
      {:noreply, socket |> refresh_editor(scope, key) |> put_flash(:info, "Assigned.")}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, flash_for(reason))}
    end
  end

  def handle_event("assign_role", _params, socket), do: {:noreply, socket}

  def handle_event("request_unassign", %{"id" => id}, socket) do
    case socket.assigns.editor do
      %{assignments: assignments, permissions: permissions} ->
        case Enum.find(assignments, &(&1.assignment.id == id)) do
          nil ->
            {:noreply, socket}

          row ->
            {:noreply,
             assign(socket, :confirm, %{id: id, message: unassign_message(row, permissions)})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_unassign", _params, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("confirm_unassign", %{"id" => id}, socket) do
    scope = fresh(socket)

    case RoleAdmin.unassign(scope, id) do
      {:ok, assignment} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> refresh_editor(scope, assignment.role_key)
         |> put_flash(:info, "Removed.")}

      {:error, reason} ->
        {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, flash_for(reason))}
    end
  end

  # ── render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} embedded={true}>
      <main
        id="custom-roles-page"
        class="mx-auto h-full max-w-5xl space-y-6 overflow-y-auto p-4 clears-tab-bar"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-semibold">Custom roles</h1>
          <form
            :if={length(@orgs) > 1}
            phx-change="select_org"
            data-role="custom-roles-org"
          >
            <select name="org_id" class="select select-sm" aria-label="Org">
              <option :for={org <- @orgs} value={org.id} selected={org.id == @org_id}>
                {org.name}
              </option>
            </select>
          </form>
        </div>

        <p :if={@builtin_edit?} data-role="builtin-not-editable" class="text-sm text-subtle">
          Built-in roles can't be edited.
        </p>

        <.editor
          :if={@editor}
          editor={@editor}
          groups={@permission_groups}
          candidates={@candidates}
          confirm={@confirm}
        />

        <section :if={!@editor} class="space-y-3">
          <div :if={@roles != []} class="flex justify-end">
            <button
              type="button"
              phx-click="new_role"
              data-role="custom-role-new"
              class="btn btn-primary btn-sm"
            >
              New role
            </button>
          </div>

          <div
            :if={@roles == []}
            data-role="custom-roles-empty"
            class="flex flex-col items-start gap-3 rounded-xl border border-edge bg-base-200 p-6"
          >
            <p class="text-sm text-base-content">No custom roles yet</p>
            <button
              type="button"
              phx-click="new_role"
              data-role="custom-role-new"
              class="btn btn-primary btn-sm"
            >
              New role
            </button>
          </div>

          <table
            :if={@roles != []}
            data-role="custom-roles-table"
            class="hidden w-full overflow-hidden rounded-xl border border-edge bg-base-100 text-sm md:table"
          >
            <thead class="bg-base-200 text-left text-xs text-subtle">
              <tr>
                <th class="px-4 py-2 font-semibold">Role name</th>
                <th class="px-4 py-2 font-semibold">Permissions</th>
                <th class="px-4 py-2 font-semibold">Assigned to</th>
                <th class="w-10 px-2 py-2"><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @roles}
                data-role="custom-role-row"
                data-key={row.role.key}
                class="border-t border-edge align-top"
              >
                <td class="px-4 py-3 font-medium">
                  <.link patch={role_path(row.role.key)} class="hover:underline">
                    {row.role.name}
                  </.link>
                </td>
                <td class="px-4 py-3" data-role="custom-role-permissions">
                  {permissions_summary(row.role)}
                </td>
                <td class="px-4 py-3" data-role="custom-role-assigned">
                  {assigned_summary(row.assignments)}
                </td>
                <td class="px-2 py-2">
                  <.row_menu role={row.role} />
                </td>
              </tr>
            </tbody>
          </table>

          <ul :if={@roles != []} class="space-y-2 md:hidden" data-role="custom-roles-cards">
            <li
              :for={row <- @roles}
              data-role="custom-role-card"
              class="rounded-xl border border-edge bg-base-100 p-4 text-sm"
            >
              <div class="flex items-start justify-between gap-2">
                <.link
                  patch={role_path(row.role.key)}
                  class="min-w-0 font-medium hover:underline"
                >
                  {row.role.name}
                </.link>
                <.row_menu role={row.role} />
              </div>
              <p class="mt-1 text-subtle">{permissions_summary(row.role)}</p>
              <p class="mt-1">{assigned_summary(row.assignments)}</p>
            </li>
          </ul>
        </section>

        <section
          data-role="builtin-roles"
          class="space-y-2 rounded-xl border border-edge bg-base-200 p-4 text-sm"
        >
          <h2 class="text-xs font-semibold text-subtle">Built-in roles</h2>
          <ul class="divide-y divide-edge">
            <li
              :for={role <- @builtins}
              data-role="builtin-role"
              data-key={role.key}
              class="flex items-center justify-between gap-3 py-2"
            >
              <span>{role.name}</span>
              <span class="text-xs text-subtle">
                {map_size(role.permissions || %{})} permissions
              </span>
            </li>
          </ul>
        </section>
      </main>
    </Layouts.app>
    """
  end

  attr(:role, :map, required: true)

  defp row_menu(assigns) do
    ~H"""
    <details class="dropdown dropdown-end" data-role="custom-role-menu">
      <summary class="btn btn-ghost btn-xs" aria-label={"Actions for #{@role.name}"}>
        <span class="hero-ellipsis-horizontal size-4" aria-hidden="true" />
      </summary>
      <ul class="menu dropdown-content z-10 w-32 rounded-box border border-edge bg-base-100 p-1 shadow">
        <li>
          <.link patch={role_path(@role.key)} data-role="custom-role-edit">Edit</.link>
        </li>
        <li>
          <button
            type="button"
            phx-click="delete_role"
            phx-value-key={@role.key}
            data-confirm={"Delete #{@role.name}? Everyone assigned loses it."}
            data-role="custom-role-delete"
            class="text-error"
          >
            Delete
          </button>
        </li>
      </ul>
    </details>
    """
  end

  attr(:editor, :map, required: true)
  attr(:groups, :list, required: true)
  attr(:candidates, :list, required: true)
  attr(:confirm, :map, default: nil)

  defp editor(assigns) do
    ~H"""
    <section
      data-role="custom-role-editor"
      class="space-y-5 rounded-xl border border-edge bg-base-100 p-4"
    >
      <form id="custom-role-form" phx-submit="save_role" class="space-y-4 text-sm">
        <input type="hidden" name="key" value={@editor.key || ""} />
        <label class="block space-y-1">
          <span class="text-xs font-semibold text-subtle">Name</span>
          <input
            type="text"
            name="name"
            value={@editor.name}
            data-role="custom-role-name"
            class="input input-sm w-full max-w-md"
            placeholder="Role name"
          />
        </label>
        <input type="hidden" name="permissions[]" value="" />
        <fieldset :for={group <- @groups} class="space-y-1" data-role="custom-role-group">
          <legend class="text-xs font-semibold text-subtle">{group.module}</legend>
          <label :for={opt <- group.permissions} class="flex items-start gap-2 py-0.5">
            <input
              type="checkbox"
              name="permissions[]"
              value={opt.permission}
              checked={opt.permission in @editor.permissions}
              data-role="custom-role-permission"
              class="checkbox checkbox-sm mt-0.5"
            />
            <span class="min-w-0">
              <span class="block">{opt.label}</span>
              <span class="block truncate font-mono text-xs text-subtle">{opt.permission}</span>
            </span>
          </label>
        </fieldset>
        <p :if={@editor.error} data-role="custom-role-error" class="text-[13px] text-error">
          {@editor.error}
        </p>
        <div class="flex items-center gap-2">
          <button type="submit" data-role="custom-role-save" class="btn btn-primary btn-sm">
            Save
          </button>
          <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">Cancel</button>
        </div>
      </form>

      <div :if={@editor.key} class="space-y-3 border-t border-edge pt-4 text-sm">
        <h2 class="text-xs font-semibold text-subtle">Assigned to</h2>
        <ul class="divide-y divide-edge" data-role="custom-role-assignments">
          <li
            :for={row <- @editor.assignments}
            data-role="custom-role-assignment"
            data-id={row.assignment.id}
            class="flex items-center justify-between gap-3 py-2"
          >
            <span class="min-w-0 truncate">
              {row.name}
              <span class="text-xs text-subtle">({row.principal_type})</span>
            </span>
            <button
              type="button"
              phx-click="request_unassign"
              phx-value-id={row.assignment.id}
              data-role="custom-role-remove"
              class="btn btn-ghost btn-xs"
            >
              Remove
            </button>
          </li>
        </ul>
        <p :if={@editor.assignments == []} class="text-xs text-subtle">Nobody yet.</p>

        <div
          :if={@confirm}
          data-role="custom-role-unassign-confirm"
          class="space-y-2 rounded-xl border border-warning bg-base-200 p-3"
        >
          <p class="flex items-start gap-1.5 text-[13px]">
            <span
              class="hero-exclamation-triangle mt-0.5 size-4 shrink-0 text-warning"
              aria-hidden="true"
            />
            <span>{@confirm.message}</span>
          </p>
          <div class="flex items-center gap-2">
            <button
              type="button"
              phx-click="confirm_unassign"
              phx-value-id={@confirm.id}
              data-role="custom-role-unassign-yes"
              class="btn btn-sm btn-error btn-outline"
            >
              Remove
            </button>
            <button type="button" phx-click="cancel_unassign" class="btn btn-ghost btn-sm">
              Keep
            </button>
          </div>
        </div>

        <form
          id="custom-role-assign-form"
          phx-submit="assign_role"
          class="flex flex-wrap items-center gap-2"
        >
          <input type="hidden" name="key" value={@editor.key} />
          <select name="principal" data-role="custom-role-assign-picker" class="select select-sm">
            <option value="">Assign to…</option>
            <option :for={c <- @candidates} value={c.value}>{c.label}</option>
          </select>
          <button
            type="submit"
            data-role="custom-role-assign"
            class="btn btn-ghost btn-sm border border-edge"
          >
            Assign
          </button>
        </form>
      </div>
    </section>
    """
  end

  # ── data ──────────────────────────────────────────────────────────────

  defp fresh(socket),
    do: socket.assigns.current_user_id |> Accounts.get_user() |> Scope.for_user()

  defp managed_orgs(%Scope{actor: %{org_memberships: memberships}} = scope)
       when is_list(memberships) do
    memberships
    |> Enum.reject(& &1.external)
    |> Enum.map(& &1.org)
    |> Enum.filter(&match?(%Org{}, &1))
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&Effective.manages_org?(scope, &1.id))
  end

  defp managed_orgs(_scope), do: []

  defp load(socket, scope) do
    org_id = socket.assigns.org_id

    roles =
      case org_id && RoleAdmin.list_custom_roles(scope, org_id) do
        {:ok, roles} ->
          Enum.map(roles, fn role ->
            {:ok, assignments} = RoleAdmin.list_assignments_for_role(scope, role.key)
            %{role: role, assignments: assignments}
          end)

        _ ->
          []
      end

    builtins =
      Repo.all(from(r in Role, where: r.builtin, order_by: r.key))
      |> Enum.sort_by(&Enum.find_index(~w(admin member guest), fn k -> k == &1.key end))

    socket
    |> assign(roles: roles, builtins: builtins)
    |> assign(permission_groups: permission_groups(scope))
    |> assign(candidates: candidates(org_id))
  end

  defp refresh_editor(socket, scope, key) do
    socket = load(socket, scope)

    case {Roles.get_role(key), RoleAdmin.list_assignments_for_role(scope, key)} do
      {%Role{} = role, {:ok, assignments}} ->
        assign(socket, :editor, editor_for(role, assignments))

      _ ->
        socket
    end
  end

  defp editor_for(%Role{} = role, assignments) do
    %{
      key: role.key,
      name: role.name,
      permissions: role.permissions |> Kernel.||(%{}) |> Map.keys() |> Enum.sort(),
      assignments: assignments,
      error: nil
    }
  end

  # The permissions the editor offers: registered, not module-admin,
  # install-level, derived or transitional mcp.*, and held by the viewer
  # (RoleAdmin refuses anything else).
  defp permission_groups(scope) do
    Registry.permissions()
    |> Enum.reject(&(&1.module_admin or &1.install_level or &1.derived or &1.module == "mcp"))
    |> Enum.filter(&Access.holds_anywhere?(scope, &1.name))
    |> Enum.group_by(& &1.module)
    |> Enum.sort_by(fn {module, _} -> module end)
    |> Enum.map(fn {module, perms} ->
      %{
        module: String.capitalize(module),
        permissions:
          Enum.map(perms, &%{permission: &1.name, label: PermissionLabels.label(&1.name)})
      }
    end)
  end

  # The org's internal members, and the agents whose runtime owner is one.
  defp candidates(nil), do: []

  defp candidates(org_id) do
    users =
      Repo.all(
        from(u in User,
          join: m in OrgMembership,
          on: m.user_id == u.id and m.org_id == ^org_id and m.external == false,
          order_by: [asc: u.name],
          select: {u.id, u.name, u.email}
        )
      )

    owner_ids = Enum.map(users, &elem(&1, 0))

    agents =
      Repo.all(
        from(a in Agent,
          join: r in AgentRuntime,
          on: r.id == a.runtime_id or r.agent_id == a.id,
          where: r.owner_user_id in ^owner_ids,
          distinct: a.id,
          order_by: [asc: a.id],
          select: {a.id, a.name}
        )
      )

    Enum.map(users, fn {id, name, email} ->
      %{value: "user:" <> id, label: name || email || id}
    end) ++
      Enum.map(agents, fn {id, name} -> %{value: "agent:" <> id, label: "#{name} (agent)"} end)
  end

  defp parse_principal("user:" <> id), do: valid(:user, id)
  defp parse_principal("agent:" <> id), do: valid(:agent, id)
  defp parse_principal(_), do: {:error, :invalid_principal}

  defp valid(type, id),
    do: if(Platform.UUID.valid?(id), do: {:ok, {type, id}}, else: {:error, :invalid_principal})

  # ── copy ──────────────────────────────────────────────────────────────

  defp flash_for(:forbidden), do: @forbidden
  defp flash_for(:builtin), do: @builtin
  defp flash_for(:builtin_not_assignable), do: @builtin
  defp flash_for(:no_membership), do: "Only internal members of this org can be assigned."
  defp flash_for(:invalid_principal), do: "Choose someone to assign."

  defp flash_for({:role_restricts_spaces, _}),
    do: "Remove this role's channel restrictions first."

  defp flash_for(%Ecto.Changeset{}), do: "Already assigned."
  defp flash_for(_), do: "Couldn't save that change."

  defp save_error({:exceeds_actor, perms}),
    do: "You can only give permissions you hold yourself: #{Enum.join(perms, ", ")}."

  defp save_error({:module_admin, perms}),
    do: "Module admin permissions can't be given to a role: #{Enum.join(perms, ", ")}."

  defp save_error(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :name) do
      {"has already been taken", _} -> "A role with this name already exists."
      {msg, _} -> "Name #{msg}."
      nil -> "Couldn't save the role."
    end
  end

  defp save_error(_), do: "Couldn't save the role."

  defp permissions_summary(%Role{permissions: permissions}) do
    keys = permissions |> Kernel.||(%{}) |> Map.keys() |> Enum.sort()
    short = Enum.map_join(keys, ", ", &(&1 |> String.split(".") |> List.last()))
    "#{length(keys)} · #{short}"
  end

  defp assigned_summary([]), do: "Nobody"
  defp assigned_summary(rows), do: Enum.map_join(rows, ", ", & &1.name)

  @doc false
  # Public for tests: the sentence the unassign confirmation shows.
  def unassign_message(%{principal_type: type, principal_id: id, name: name}, permissions) do
    loses =
      permissions
      |> Enum.map(&(&1 |> PermissionLabels.label() |> lower_first()))
      |> sentence()

    base = "#{name} will stop being able to #{loses}."

    case type do
      "user" ->
        case agents_owned_by(id) do
          [] -> base
          agents -> base <> " Their agents lose it too: #{Enum.join(agents, ", ")}."
        end

      _ ->
        base
    end
  end

  defp agents_owned_by(user_id) do
    Repo.all(
      from(a in Agent,
        join: r in AgentRuntime,
        on: r.id == a.runtime_id or r.agent_id == a.id,
        where: r.owner_user_id == ^user_id,
        distinct: a.id,
        order_by: [asc: a.id],
        select: a.name
      )
    )
  end

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower_first(other), do: other

  defp sentence([]), do: "use this role"
  defp sentence([one]), do: one
  defp sentence(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)

  @doc """
  The page path for a role. A custom key is `custom:<uuidv7>`, and
  `Plug.Static` refuses any path segment containing a colon
  (`Plug.Static.InvalidPathError`), so the URL carries the uuid only.
  """
  @spec role_path(String.t()) :: String.t()
  def role_path("custom:" <> uuid), do: ~p"/access/roles/#{uuid}"
  def role_path(key), do: ~p"/access/roles/#{key}"

  defp key_from_segment(segment) do
    if Platform.UUID.valid?(segment), do: "custom:" <> segment, else: segment
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
