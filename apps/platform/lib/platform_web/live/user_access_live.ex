defmodule PlatformWeb.UserAccessLive do
  @moduledoc """
  User Access — admin surface for managing Burrow user membership.

  Today's scope (task 019f671f Stage 6): soft-archive / unarchive of
  Burrow users. Archived users are hidden from active pickers everywhere
  (task assignee, DM new-conversation — see
  `Accounts.list_users/1` default of `include_archived: false`) but
  historical attribution (past-authored messages, memory-entry authors,
  task `reported_by`) still resolves because those callers opt in with
  `include_archived: true`.

  Server-side guards:

    * **Never self-archive.** The DOM disables the button on the current
      user's own row AND the `handle_event("archive", ...)` handler
      short-circuits with a flash error if the id matches
      `current_user.id`. An admin who could archive themselves would
      immediately lose access to this surface (and every other Burrow
      surface via the auth plug in Stage 5).

  root-admin-only gate is inherited from the `:admin` `live_session` in
  `PlatformWeb.Router` (via `PlatformWeb.LiveAuth.on_mount(:ensure_admin, ...)`).
  """
  use PlatformWeb, :live_view

  alias Platform.Accounts

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "User Access")
      |> assign(:show_archived, false)
      |> load_users()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_show_archived", _params, socket) do
    socket =
      socket
      |> assign(:show_archived, !socket.assigns.show_archived)
      |> load_users()

    {:noreply, socket}
  end

  # Self-archive guard: even if the DOM `disabled` attribute is stripped
  # (DevTools, crafted LV command), the server refuses. Mirror is the
  # semantic reason "an admin should not be able to lock themselves out
  # of the admin surface" from the plan.
  def handle_event("archive", %{"id" => user_id}, socket) do
    current_user = socket.assigns.current_user_record

    cond do
      is_nil(current_user) ->
        # Belt-and-suspenders: the :admin live_session's :ensure_admin
        # hook already halts unauth mounts, so this branch is defensive
        # rather than reachable. Keeps the pattern-match total.
        {:noreply, put_flash(socket, :error, "You must be signed in to archive users.")}

      user_id == current_user.id ->
        {:noreply, put_flash(socket, :error, "You can't archive yourself.")}

      true ->
        case Accounts.get_user(user_id) do
          nil ->
            {:noreply, put_flash(socket, :error, "User not found.")}

          %_{} = user ->
            case Accounts.archive_user(user, actor: current_user) do
              {:ok, _archived} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "Archived #{user.name}.")
                 |> load_users()}

              {:error, _changeset} ->
                {:noreply, put_flash(socket, :error, "Could not archive user.")}
            end
        end
    end
  end

  def handle_event("unarchive", %{"id" => user_id}, socket) do
    # `get_user/1` is deliberately unchanged (Stage 1) and returns
    # archived users unfiltered — that's exactly what we need here.
    case Accounts.get_user(user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      %_{} = user ->
        case Accounts.unarchive_user(user) do
          {:ok, _restored} ->
            {:noreply,
             socket
             |> put_flash(:info, "Unarchived #{user.name}.")
             |> load_users()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not unarchive user.")}
        end
    end
  end

  # ── Assign helpers ─────────────────────────────────────────────────────

  defp load_users(socket) do
    show_archived = socket.assigns.show_archived
    users = Accounts.list_users(include_archived: show_archived)

    # Independent second query — the visible list respects the toggle,
    # but the badge count on the toggle itself always reflects the true
    # archived population regardless of the current view.
    all_users = Accounts.list_users(include_archived: true)
    archived_count = Enum.count(all_users, & &1.archived_at)

    # Build a lookup map so the "archived by" column resolves in O(1)
    # per row without an N+1 fan-out. Includes archived users because
    # an archiver may themselves be archived later (rare, but the FK
    # `on_delete: :nilify_all` on `archived_by_user_id` means the row
    # stays resolvable).
    users_by_id = Map.new(all_users, &{&1.id, &1})

    socket
    |> assign(:users, users)
    |> assign(:archived_count, archived_count)
    |> assign(:users_by_id, users_by_id)
  end

  # ── Template helpers (imported into the .heex via `use PlatformWeb, :live_view`) ─

  @doc false
  def relative_time(nil), do: ""

  def relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  @doc false
  def archived_by_name(_users_by_id, nil), do: "—"

  def archived_by_name(users_by_id, actor_id) when is_binary(actor_id) do
    case Map.get(users_by_id, actor_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "—"
    end
  end
end
