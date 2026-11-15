defmodule PlatformWeb.MentionGroupsLive do
  @moduledoc "Org-scoped mention groups. Every action checks fresh exact-org admin rights."
  use PlatformWeb, :live_view

  alias Platform.{Accounts, Tenancy}
  alias Platform.Chat.MentionGroups

  @impl true
  def mount(_params, _session, socket) do
    orgs = managed_orgs(actor(socket))

    if orgs == [] do
      {:ok, redirect(socket, to: "/access-denied?module=chat")}
    else
      {:ok,
       socket
       |> assign(
         page_title: "Mention groups",
         orgs: orgs,
         org_id: hd(orgs).id,
         groups: [],
         candidates: [],
         editor: nil
       )
       |> load()}
    end
  end

  @impl true
  def handle_event("select_org", %{"org_id" => org_id}, socket) do
    orgs = managed_orgs(actor(socket))

    if Enum.any?(orgs, &(&1.id == org_id)) do
      {:noreply, socket |> assign(org_id: org_id, orgs: orgs, editor: nil) |> load()}
    else
      {:noreply, put_flash(socket, :error, "Could not open that organization.")}
    end
  end

  def handle_event("new_group", _params, socket) do
    open_editor(socket, %{id: nil, name: "", members: []})
  end

  def handle_event("edit_group", %{"id" => id}, socket) do
    with {:ok, group} <- MentionGroups.get_group(actor(socket), id),
         true <- group.org_id == socket.assigns.org_id do
      open_editor(socket, group)
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not open this group.")}
    end
  end

  def handle_event("cancel_group", _params, socket),
    do: {:noreply, assign(socket, editor: nil, candidates: [])}

  def handle_event("save_group", %{"group" => params}, socket) do
    user = actor(socket)
    editor = socket.assigns.editor

    attrs = %{
      name: Map.get(params, "name", ""),
      members: parse_members(Map.get(params, "members", []))
    }

    result =
      if editor && authorized?(user, socket.assigns.org_id) do
        if editor.id,
          do: MentionGroups.update_group(user, editor.id, attrs),
          else: MentionGroups.create_group(user, socket.assigns.org_id, attrs)
      else
        {:error, :forbidden}
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(editor: nil, candidates: [])
         |> load()
         |> put_flash(:info, "Group saved.")}

      {:error, _} ->
        socket =
          if editor,
            do: assign(socket, :editor, %{editor | name: attrs.name, members: attrs.members}),
            else: socket

        {:noreply,
         put_flash(socket, :error, "Could not save this group. Check its name and members.")}
    end
  end

  def handle_event("archive_group", %{"id" => id}, socket) do
    user = actor(socket)

    with true <- authorized?(user, socket.assigns.org_id),
         {:ok, group} <- MentionGroups.get_group(user, id),
         true <- group.org_id == socket.assigns.org_id,
         {:ok, _} <- MentionGroups.archive_group(user, id) do
      {:noreply,
       socket
       |> assign(editor: nil, candidates: [])
       |> load()
       |> put_flash(:info, "Group archived.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not archive this group.")}
    end
  end

  defp open_editor(socket, group) do
    user = actor(socket)

    with true <- authorized?(user, socket.assigns.org_id),
         {:ok, candidates} <- MentionGroups.list_candidates(user, socket.assigns.org_id) do
      {:noreply, assign(socket, editor: group, candidates: candidates)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not open this group.")}
    end
  end

  defp actor(socket), do: Accounts.get_user(socket.assigns[:current_user_id])

  @doc false
  def managed_orgs(%Accounts.User{org_memberships: memberships} = user)
      when is_list(memberships) do
    memberships
    |> Enum.map(& &1.org)
    |> Enum.filter(&match?(%Tenancy.Org{archived_at: nil, deletion_scheduled_at: nil}, &1))
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&Tenancy.org_admin?(user, &1.id))
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  def managed_orgs(_), do: []

  defp authorized?(user, org_id), do: Enum.any?(managed_orgs(user), &(&1.id == org_id))

  defp load(socket) do
    groups =
      if authorized?(actor(socket), socket.assigns.org_id) do
        case MentionGroups.list_groups(actor(socket), socket.assigns.org_id) do
          {:ok, groups} -> groups
          _ -> []
        end
      else
        []
      end

    assign(socket, groups: groups)
  end

  defp parse_members(values) when is_list(values) do
    values
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn value ->
      case String.split(value, ":", parts: 2) do
        [type, id] -> %{type: type, id: id}
        _ -> %{type: "invalid", id: ""}
      end
    end)
  end

  defp parse_members(_), do: [%{type: "invalid", id: ""}]

  defp selected?(group, candidate),
    do: Enum.any?(group.members, &(&1.type == candidate.type and &1.id == candidate.id))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-3xl space-y-6 p-4 lg:p-8">
      <div class="flex items-center justify-between gap-4">
        <div>
          <.link navigate="/settings" class="link text-sm">Settings</.link>
          <h1 class="text-2xl font-semibold">Mention groups</h1>
        </div>
        <button id="new-mention-group" phx-click="new_group" class="btn btn-primary">
          New group
        </button>
      </div>
      <p class="text-sm text-subtle">
        Address existing participants together. Groups do not add anyone to a space or grant access.
      </p>
      <.form :if={length(@orgs) > 1} for={%{}} phx-change="select_org" id="mention-group-org-form">
        <label class="form-control">
          <span class="label-text">Organization</span>
          <select name="org_id" class="select select-bordered" aria-label="Organization">
            <option :for={org <- @orgs} value={org.id} selected={org.id == @org_id}>
              {org.name}
            </option>
          </select>
        </label>
      </.form>
      <.form
        :if={@editor}
        for={%{}}
        id="mention-group-form"
        phx-submit="save_group"
        class="space-y-4 rounded-box border border-edge bg-base-200 p-4"
      >
        <h2 class="text-lg font-semibold">{if @editor.id, do: "Edit group", else: "New group"}</h2>
        <label class="form-control">
          <span class="label-text">Group name</span>
          <input
            type="text"
            name="group[name]"
            value={@editor.name}
            required
            maxlength="80"
            class="input input-bordered"
          />
        </label>
        <fieldset class="space-y-2">
          <legend class="mb-2 font-medium">Members</legend>
          <input type="hidden" name="group[members][]" value="" />
          <label :for={candidate <- @candidates} class="flex min-h-11 items-center gap-3">
            <input
              type="checkbox"
              name="group[members][]"
              value={"#{candidate.type}:#{candidate.id}"}
              checked={selected?(@editor, candidate)}
              class="checkbox checkbox-sm"
            />
            <span>{candidate.name}</span>
            <span class="badge badge-ghost badge-sm">
              {if candidate.type == "agent", do: "agent", else: "person"}
            </span>
          </label>
          <p :if={@candidates == []} class="text-sm text-subtle">
            No eligible members in this organization.
          </p>
        </fieldset>
        <p class="text-sm text-subtle">
          Group recipients are set when a message is sent. Send a new message to notify a new group.
        </p>
        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary">Save group</button>
          <button type="button" phx-click="cancel_group" class="btn btn-ghost">Cancel</button>
        </div>
      </.form>
      <p :if={@groups == []} class="text-sm text-subtle">No mention groups yet.</p>
      <ul class="divide-y divide-edge">
        <li
          :for={group <- @groups}
          id={"mention-group-#{group.id}"}
          class="flex flex-wrap items-center justify-between gap-3 py-4"
        >
          <div class="flex items-center gap-3">
            <span class="hero-user-group size-5" aria-hidden="true"></span>
            <div>
              <p class="font-medium">{group.name}</p>
              <p class="text-sm text-subtle">{length(group.members)} members</p>
            </div>
          </div>
          <div class="flex gap-2">
            <button
              id={"edit-group-#{group.id}"}
              phx-click="edit_group"
              phx-value-id={group.id}
              class="btn btn-ghost btn-sm min-h-11"
            >
              Edit
            </button>
            <button
              id={"archive-group-#{group.id}"}
              phx-click="archive_group"
              phx-value-id={group.id}
              class="btn btn-ghost btn-sm min-h-11"
            >
              Archive
            </button>
          </div>
        </li>
      </ul>
    </div>
    """
  end
end
