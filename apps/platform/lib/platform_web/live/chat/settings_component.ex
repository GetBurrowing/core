defmodule PlatformWeb.ChatLive.SettingsComponent do
  @moduledoc """
  Space settings modal for `PlatformWeb.ChatLive`.

  See ADR 0035. Self-contained modal with contiguous render → LiveComponent.

  ## Activation

  The parent LiveView owns a boolean `:show_settings` assign (activation
  state — which modal is open at the shell level) and passes it as the
  `:open` attr. The form + all events live inside this component.

  ## Events (all namespaced `settings_*`)

    * `"settings_close"` — dismiss
    * `"settings_save"` — persist space attrs, request navigation
    * `"settings_archive"` — archive channel, request navigation
    * `"settings_promote"` — group → channel, request navigation
    * `"settings_delete_confirm"` — typed-name check, toggles the Delete button
    * `"settings_delete"` — schedule permanent deletion, request navigation

  ## Messages sent to parent

    * `{:settings_closed}` — parent clears `:show_settings`
    * `{:settings_navigate, path}` — parent `push_navigate`s + clears
      `:show_settings`
    * `{:settings_flash, kind, msg}` — parent attaches a flash
  """

  use PlatformWeb, :live_component

  alias Platform.Chat
  alias Platform.Tenancy

  @impl true
  def update(%{open: open, space: space} = assigns, socket) do
    # Danger-zone permissions are (re)computed only on the closed → open
    # transition, so the root_admin? DB check runs once per open rather
    # than on every parent re-render while the modal is up.
    freshly_opened? = open && socket.assigns[:open] != true

    socket =
      socket
      |> assign(assigns)
      |> maybe_hydrate_form(open, space)
      |> maybe_authorize_danger_zone(freshly_opened?, space)

    {:ok, socket}
  end

  defp maybe_hydrate_form(socket, true, %{} = space) do
    form =
      to_form(%{
        "name" => space.name || "",
        "description" => space.description || "",
        "topic" => space.topic || "",
        "promote_name" => ""
      })

    assign(socket, :form, form)
  end

  defp maybe_hydrate_form(socket, _open, _space),
    do: assign_new(socket, :form, fn -> to_form(%{}) end)

  # Task 019e95ea stage 4: UI affordance only — `Chat.archive_space/2` and
  # `Chat.schedule_space_deletion/2` re-authorize in the context layer.
  # `can_archive?` mirrors the archive rule (root-org admin OR creator);
  # `can_delete?` mirrors the deletion rule (root-org admin ONLY). The typed
  # confirmation state resets on every fresh open.
  defp maybe_authorize_danger_zone(socket, true, %{} = space) do
    root_admin? = Tenancy.root_admin?(%{id: socket.assigns.current_user_id})

    socket
    |> assign(:can_archive?, root_admin? or space.created_by == socket.assigns.current_user_id)
    |> assign(:can_delete?, root_admin?)
    |> assign(:delete_confirmed?, false)
  end

  defp maybe_authorize_danger_zone(socket, _freshly_opened?, _space) do
    socket
    |> assign_new(:can_archive?, fn -> false end)
    |> assign_new(:can_delete?, fn -> false end)
    |> assign_new(:delete_confirmed?, fn -> false end)
  end

  @impl true
  def handle_event("settings_close", _params, socket) do
    send(self(), {:settings_closed})
    {:noreply, socket}
  end

  def handle_event("settings_save", params, socket) do
    space = socket.assigns.space

    attrs =
      case space.kind do
        "channel" ->
          slug =
            (params["name"] || space.name)
            |> String.downcase()
            |> String.replace(~r/[^a-z0-9\s-]/, "")
            |> String.replace(~r/\s+/, "-")
            |> String.trim("-")

          %{
            name: params["name"],
            slug: slug,
            description: params["description"],
            topic: params["topic"]
          }

        "group" ->
          %{name: params["name"]}

        "dm" ->
          %{}
      end

    case Chat.update_space(space, attrs) do
      {:ok, updated} ->
        nav_target = PlatformWeb.ChatLive.space_nav_target(updated)
        send(self(), {:settings_navigate, "/chat/#{nav_target}"})
        {:noreply, socket}

      {:error, _changeset} ->
        send(self(), {:settings_flash, :error, "Could not save settings."})
        {:noreply, socket}
    end
  end

  def handle_event("settings_archive", _params, socket) do
    space = socket.assigns.space
    actor = %{id: socket.assigns.current_user_id}

    case Chat.archive_space(actor, space) do
      {:ok, _} ->
        send(
          self(),
          {:settings_navigate, "/chat",
           {:info,
            "#{space.name} archived — it's now a read-only snapshot under Archived in the sidebar."}}
        )

        {:noreply, socket}

      {:error, :unauthorized} ->
        send(
          self(),
          {:settings_flash, :error,
           "You don't have permission to archive this channel. Only admins and the channel's creator can."}
        )

        {:noreply, socket}

      {:error, _} ->
        send(self(), {:settings_flash, :error, "Could not archive space."})
        {:noreply, socket}
    end
  end

  # Client-side half of the typed confirmation: the Delete button stays
  # disabled until the typed value matches the channel name exactly. The
  # submit handler below re-validates server-side — this assign is UX only.
  def handle_event("settings_delete_confirm", params, socket) do
    typed = params["delete_confirm_name"] || ""
    {:noreply, assign(socket, :delete_confirmed?, typed == socket.assigns.space.name)}
  end

  def handle_event("settings_delete", params, socket) do
    typed = params["delete_confirm_name"] || ""
    actor = %{id: socket.assigns.current_user_id}

    # Re-fetch before comparing: the modal's copy of the space may be stale
    # (renamed in another tab). The DB record's name is the truth the typed
    # confirmation must match.
    space = Chat.get_space(socket.assigns.space.id)

    cond do
      is_nil(space) ->
        send(self(), {:settings_flash, :error, "This channel no longer exists."})
        {:noreply, socket}

      typed != space.name ->
        send(self(), {:settings_flash, :error, "Channel name doesn't match."})
        {:noreply, socket}

      true ->
        case Chat.schedule_space_deletion(actor, space) do
          {:ok, _scheduled} ->
            purge_date = permanent_deletion_date()

            send(
              self(),
              {:settings_navigate, "/chat",
               {:info,
                "#{space.name} is scheduled for permanent deletion on #{purge_date}. " <>
                  "An admin can cancel the deletion until then."}}
            )

            {:noreply, socket}

          {:error, :unauthorized} ->
            send(
              self(),
              {:settings_flash, :error,
               "You don't have permission to delete this channel. Only admins can."}
            )

            {:noreply, socket}

          {:error, :not_deletable} ->
            send(self(), {:settings_flash, :error, "This space cannot be deleted."})
            {:noreply, socket}

          {:error, _changeset} ->
            send(self(), {:settings_flash, :error, "Could not delete channel."})
            {:noreply, socket}
        end
    end
  end

  def handle_event("settings_promote", %{"promote_name" => name}, socket) do
    space = socket.assigns.space

    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    case Chat.promote_to_channel(space, %{name: name, slug: slug}) do
      {:ok, updated} ->
        nav_target = PlatformWeb.ChatLive.space_nav_target(updated)
        send(self(), {:settings_navigate, "/chat/#{nav_target}"})
        {:noreply, socket}

      {:error, :not_promotable} ->
        send(self(), {:settings_flash, :error, "This conversation cannot be promoted."})
        {:noreply, socket}

      {:error, _changeset} ->
        send(self(), {:settings_flash, :error, "Could not promote to channel."})
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@open && @space}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
      >
        <%!-- phx-click-away (not overlay phx-click + inline stopPropagation):
             the inline onclick stopped click bubbling to window, where
             LiveView's delegated listener lives — killing EVERY phx-click
             inside the modal in real browsers while LiveViewTest's direct
             socket events kept passing (task 019e95ea). --%>
        <div
          class="bg-base-100 rounded-xl shadow-xl w-full max-w-md p-6 max-h-[80vh] overflow-y-auto"
          phx-click-away="settings_close"
          phx-target={@myself}
        >
          <h3 class="text-lg font-bold mb-4">{title_for(@space.kind)}</h3>

          <form phx-submit="settings_save" phx-target={@myself}>
            <%= if @space.kind == "channel" do %>
              <div class="form-control mb-3">
                <label class="label"><span class="label-text">Name</span></label>
                <input
                  name="name"
                  type="text"
                  class="input input-bordered w-full"
                  value={@space.name}
                  required
                />
              </div>
              <div class="form-control mb-3">
                <label class="label"><span class="label-text">Description</span></label>
                <textarea
                  name="description"
                  class="textarea textarea-bordered w-full"
                  placeholder="What's this channel about?"
                >{@space.description}</textarea>
              </div>
              <div class="form-control mb-3">
                <label class="label"><span class="label-text">Topic</span></label>
                <input
                  name="topic"
                  type="text"
                  class="input input-bordered w-full"
                  value={@space.topic}
                  placeholder="Current topic of discussion"
                />
              </div>
            <% end %>

            <%= if @space.kind == "group" do %>
              <div class="form-control mb-3">
                <label class="label"><span class="label-text">Custom Name (optional)</span></label>
                <input
                  name="name"
                  type="text"
                  class="input input-bordered w-full"
                  value={@space.name}
                  placeholder="Override auto-generated name"
                />
              </div>
            <% end %>

            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="settings_close"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
            </div>
          </form>

          <%!-- Danger Zone (task 019e95ea stage 4): rendered only when the
               actor may take at least one destructive action. Visibility is
               affordance only — the Chat context re-authorizes every call. --%>
          <%= if @space.kind == "channel" && (@can_archive? || @can_delete?) do %>
            <div class="divider text-xs text-base-content/40 mt-6">Danger Zone</div>

            <%= if @can_archive? do %>
              <button
                phx-click="settings_archive"
                phx-target={@myself}
                class="btn btn-error btn-outline btn-sm w-full"
                data-confirm="Archive this channel? It becomes a read-only snapshot — history stays searchable, and an admin or the creator can unarchive it anytime."
              >
                Archive Channel
              </button>
            <% end %>

            <%= if @can_delete? do %>
              <div class="mt-4">
                <p class="text-sm font-medium text-error mb-1">Delete this channel</p>
                <p class="text-xs text-base-content/60 mb-2">
                  The channel is hidden immediately for everyone and permanently
                  deleted on {permanent_deletion_date()}. An admin can cancel the
                  deletion until then. Type the channel name to confirm.
                </p>
                <form
                  id="delete-channel-form"
                  phx-change="settings_delete_confirm"
                  phx-submit="settings_delete"
                  phx-target={@myself}
                  class="flex flex-col gap-2"
                >
                  <input
                    name="delete_confirm_name"
                    type="text"
                    class="input input-bordered input-sm w-full"
                    placeholder={@space.name}
                    autocomplete="off"
                  />
                  <button
                    type="submit"
                    class="btn btn-error btn-sm w-full"
                    disabled={!@delete_confirmed?}
                  >
                    Delete Channel
                  </button>
                </form>
              </div>
            <% end %>
          <% end %>

          <%= if @space.kind == "group" && !@space.is_direct do %>
            <form phx-submit="settings_promote" phx-target={@myself} class="mb-2">
              <label class="label"><span class="label-text text-sm">Promote to Channel</span></label>
              <div class="flex gap-2">
                <input
                  name="promote_name"
                  type="text"
                  class="input input-bordered input-sm flex-1"
                  placeholder="Channel name"
                  required
                />
                <button type="submit" class="btn btn-sm btn-outline">Promote</button>
              </div>
            </form>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # The concrete calendar date `Platform.Chat.SpacePurger` would hard-delete
  # a channel flagged today — shown in the Delete section and the success
  # flash so the consequence is a date, not an abstract "in N days".
  defp permanent_deletion_date do
    Date.utc_today()
    |> Date.add(Chat.space_retention_days())
    |> Calendar.strftime("%B %-d, %Y")
  end

  defp title_for("channel"), do: "Channel Settings"
  defp title_for("dm"), do: "Conversation Settings"
  defp title_for("group"), do: "Group Settings"
  defp title_for(_), do: "Settings"
end
