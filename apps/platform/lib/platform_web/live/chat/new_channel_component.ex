defmodule PlatformWeb.ChatLive.NewChannelComponent do
  @moduledoc """
  "Create Channel" modal for `PlatformWeb.ChatLive`.

  See ADR 0035. Self-contained modal → LiveComponent.

  Parent owns a `:show_new_channel_modal` activation flag and passes it
  as the `:open` attr. All events live in this component.

  ## Events

    * `"new_channel_close"` — dismiss
    * `"new_channel_submit"` — create the channel, request navigation

  ## Messages sent to parent

    * `{:new_channel_closed}` — parent clears `:show_new_channel_modal`
    * `{:new_channel_navigate, path}` — parent `push_navigate`s + clears
      `:show_new_channel_modal`
    * `{:new_channel_flash, kind, msg}` — parent attaches a flash
  """

  use PlatformWeb, :live_component

  alias Platform.Chat

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("new_channel_close", _params, socket) do
    send(self(), {:new_channel_closed})
    {:noreply, socket}
  end

  def handle_event("new_channel_submit", %{"name" => name, "description" => desc}, socket) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    case Chat.create_channel(%{name: name, slug: slug, description: desc}) do
      {:ok, space} ->
        send(self(), {:new_channel_navigate, "/chat/#{space.slug}"})
        {:noreply, socket}

      {:error, _changeset} ->
        send(self(), {:new_channel_flash, :error, "Could not create channel. Name may be taken."})
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@open}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
        phx-click="new_channel_close"
        phx-target={@myself}
      >
        <div
          class="bg-base-100 rounded-xl shadow-xl w-full max-w-md p-6"
          phx-click-away="new_channel_close"
          phx-target={@myself}
        >
          <h3 class="text-lg font-bold mb-4">Create Channel</h3>
          <form phx-submit="new_channel_submit" phx-target={@myself}>
            <div class="form-control mb-3">
              <label class="label"><span class="label-text">Name</span></label>
              <input
                name="name"
                type="text"
                class="input input-bordered w-full"
                placeholder="e.g. engineering"
                required
              />
            </div>
            <div class="form-control mb-4">
              <label class="label"><span class="label-text">Description (optional)</span></label>
              <input
                name="description"
                type="text"
                class="input input-bordered w-full"
                placeholder="What's this channel about?"
              />
            </div>
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="new_channel_close"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-primary btn-sm">Create</button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
