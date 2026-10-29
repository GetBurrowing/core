defmodule PlatformWeb.SocialClipsLibrary do
  @moduledoc "The profile's retained clip entries, with shared authorized removal controls."
  use PlatformWeb, :live_component
  alias Platform.Social.ClipLibrary

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:refresh]))

    items =
      case socket.assigns[:profile] do
        %{org_id: org, id: id} -> ClipLibrary.list(org, %{"show" => id}).items
        _ -> []
      end

    {:ok, assign(socket, :items, items)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="social-clips-library" data-role="clips-library" class="space-y-3">
      <p :if={@items == []} class="p-4 text-sm text-base-content/70">No clips in Library.</p>
      <article
        :for={item <- @items}
        id={"library-clip-#{item.clip.id}"}
        data-role="library-clip"
        class="rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="mb-2 flex items-center gap-2">
          <h3 class="min-w-0 flex-1 truncate font-semibold">{item.clip.title || "Untitled clip"}</h3>
          <span class="badge badge-outline">{item.state}</span>
        </div>
        <.live_component
          module={PlatformWeb.SocialClipRemoval}
          id={"library-remove-#{item.clip.id}"}
          clip={item.clip}
          profile={@profile}
          user_id={@user_id}
        />
      </article>
    </div>
    """
  end
end
