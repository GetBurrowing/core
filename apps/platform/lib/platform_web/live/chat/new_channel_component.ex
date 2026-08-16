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
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign_new(:org_options, fn -> [] end)
     |> assign_new(:active_org_id, fn -> nil end)
     |> assign(assigns)}
  end

  @impl true
  def handle_event("new_channel_close", _params, socket) do
    send(self(), {:new_channel_closed})
    {:noreply, socket}
  end

  def handle_event(
        "new_channel_submit",
        %{"name" => name, "description" => desc} = params,
        socket
      ) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    attrs =
      %{name: name, slug: slug, description: desc}
      |> put_org_id(resolve_org_id(params, socket))

    case Chat.create_channel(attrs) do
      {:ok, space} ->
        nav_target = PlatformWeb.ChatLive.space_nav_target(space)
        send(self(), {:new_channel_navigate, "/chat/#{nav_target}"})
        {:noreply, socket}

      {:error, changeset} ->
        send(self(), {:new_channel_flash, :error, format_error(changeset)})
        {:noreply, socket}
    end
  end

  # The org the new channel is filed into (task 01a00910 stage 5). Before this
  # the dialog sent NO `org_id` at all, so "+ New channel" could not create an
  # org-scoped channel and the org-less row it did create was invisible to
  # ChatLive's org-scoped mount lookup — which then minted a DUPLICATE of it.
  #
  # The submitted value is checked against `@org_options` (the server-built,
  # viewer-scoped list) rather than trusted: the select is an affordance, not
  # the authority. Anything not on that list falls back to the active org, so a
  # forged option cannot file a channel into an org the viewer can't see.
  defp resolve_org_id(params, socket) do
    submitted = params["org_id"]
    allowed = Enum.map(socket.assigns[:org_options] || [], & &1.id)

    if is_binary(submitted) and submitted in allowed do
      submitted
    else
      socket.assigns[:active_org_id]
    end
  end

  defp put_org_id(attrs, nil), do: attrs
  defp put_org_id(attrs, org_id), do: Map.put(attrs, :org_id, org_id)

  defp format_error(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      [{field, {msg, _}} | _] -> "#{Phoenix.Naming.humanize(field)} #{msg}."
      _ -> "Could not create channel. Please try again."
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@open}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
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
                autocapitalize="none"
                autocorrect="off"
                spellcheck="false"
                required
              />
            </div>
            <div :if={@org_options != []} class="form-control mb-3">
              <label class="label" for={"#{@id}-org"}>
                <span class="label-text">Organisation</span>
              </label>
              <select id={"#{@id}-org"} name="org_id" class="select select-bordered w-full">
                <option
                  :for={org <- @org_options}
                  value={org.id}
                  selected={org.id == @active_org_id}
                >
                  {org.name}
                </option>
              </select>
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
