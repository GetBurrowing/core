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

  ## Messages sent to parent

    * `{:settings_closed}` — parent clears `:show_settings`
    * `{:settings_navigate, path}` — parent `push_navigate`s + clears
      `:show_settings`
    * `{:settings_flash, kind, msg}` — parent attaches a flash
  """

  use PlatformWeb, :live_component

  alias Platform.Chat

  @impl true
  def update(%{open: open, space: space} = assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> maybe_hydrate_form(open, space)

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
        nav_target = updated.slug || updated.id
        send(self(), {:settings_navigate, "/chat/#{nav_target}"})
        {:noreply, socket}

      {:error, _changeset} ->
        send(self(), {:settings_flash, :error, "Could not save settings."})
        {:noreply, socket}
    end
  end

  def handle_event("settings_archive", _params, socket) do
    space = socket.assigns.space

    case Chat.archive_space(space) do
      {:ok, _} ->
        send(self(), {:settings_navigate, "/chat"})
        {:noreply, socket}

      {:error, _} ->
        send(self(), {:settings_flash, :error, "Could not archive space."})
        {:noreply, socket}
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
        send(self(), {:settings_navigate, "/chat/#{updated.slug}"})
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
        phx-click="settings_close"
        phx-target={@myself}
      >
        <div
          class="bg-base-100 rounded-xl shadow-xl w-full max-w-md p-6 max-h-[80vh] overflow-y-auto"
          onclick="event.stopPropagation()"
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

          <div class="divider text-xs text-base-content/40 mt-6">Danger Zone</div>

          <%= if @space.kind == "channel" do %>
            <button
              phx-click="settings_archive"
              phx-target={@myself}
              class="btn btn-error btn-outline btn-sm w-full"
              data-confirm="Are you sure you want to archive this channel? This cannot be undone."
            >
              Archive Channel
            </button>
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

  defp title_for("channel"), do: "Channel Settings"
  defp title_for("dm"), do: "Conversation Settings"
  defp title_for("group"), do: "Group Settings"
  defp title_for(_), do: "Settings"
end
