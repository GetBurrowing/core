defmodule PlatformWeb.SocialClipRemoval do
  @moduledoc "Human-only clip and version removal, shared by Review and Library."
  use PlatformWeb, :live_component
  alias Platform.Social
  alias Platform.Social.ClipRemoval

  @impl true
  def mount(socket), do: {:ok, assign(socket, target: nil, error: nil, expanded?: false)}

  @impl true
  def update(assigns, socket) do
    changed? =
      socket.assigns[:clip] &&
        (socket.assigns.clip.id != assigns.clip.id or socket.assigns.clip.rev != assigns.clip.rev)

    socket = socket |> assign(assigns) |> load()
    {:ok, if(changed?, do: assign(socket, target: nil, error: nil), else: socket)}
  end

  defp load(socket) do
    %{profile: p, clip: clip, user_id: user} = socket.assigns
    profile = Social.get_profile(p.org_id, p.id)
    can? = profile && Social.approver_check(p.org_id, profile, user) == :ok
    versions = ClipRemoval.history(p.org_id, p.id, clip.id)

    assign(socket,
      can_remove?: !!can?,
      versions: versions,
      guard: ClipRemoval.status(p.org_id, p.id, clip.id),
      guards: Map.new(versions, &{&1.id, ClipRemoval.status(p.org_id, p.id, clip.id, &1.id)})
    )
  end

  @impl true
  def handle_event("toggle", _, socket),
    do: {:noreply, assign(socket, :expanded?, not socket.assigns.expanded?)}

  def handle_event("request", params, socket) do
    socket = load(socket)
    id = params["render"]
    target = if is_nil(id), do: :clip, else: Enum.find(socket.assigns.versions, &(&1.id == id))
    guard = if is_nil(id), do: socket.assigns.guard, else: socket.assigns.guards[id]

    if (socket.assigns.can_remove? and target) && guard == :ok,
      do: {:noreply, assign(socket, target: target, error: nil, expanded?: true)},
      else: {:noreply, assign(socket, target: nil, error: message(guard))}
  end

  def handle_event("cancel", _, socket),
    do: {:noreply, assign(socket, target: nil, error: nil)}

  def handle_event("confirm", _, %{assigns: %{target: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm", _, socket) do
    %{profile: p, clip: clip, user_id: user, target: target} = socket.assigns

    result =
      case target do
        :clip -> Social.remove_clip(p.org_id, p.id, clip.id, user)
        render -> Social.remove_clip_render(p.org_id, p.id, clip.id, render.id, user)
      end

    case result do
      {:ok, _} ->
        {:noreply, socket |> assign(target: nil, error: nil) |> load()}

      {:error, reason} ->
        {:noreply, socket |> assign(target: nil, error: message({:error, reason})) |> load()}
    end
  end

  defp message({:error, :job_in_flight}), do: "Rendering — wait or cancel"
  defp message({:error, :version_in_use}), do: "In use by an approved version"
  defp message({:error, :post_reference}), do: "In use by a post — remove the post first"

  defp message({:error, reason})
       when reason in [:not_a_human, :not_an_approver, :approver_archived, :approver_no_access],
       do: "Only a current human approver can remove this entry."

  defp message(:ok), do: nil
  defp message(_), do: "This entry is no longer available. Reload and try again."

  defp target_label(:clip, clip), do: clip.title || "Untitled clip"
  defp target_label(render, clip), do: "#{clip.title || "Untitled clip"} v#{render.rev}"

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="max-[760px]:hidden" data-role="clip-removal">
      <details
        data-role="clip-manage-menu"
        open={@expanded?}
        class="rounded-box border border-base-300 bg-base-200 p-2"
      >
        <summary
          phx-click="toggle"
          phx-target={@myself}
          class="cursor-pointer text-sm"
          aria-label="Manage clip and render versions"
        >
          ⋯ Manage clip
        </summary>
        <div class="mt-2 space-y-2">
          <p class="text-xs text-base-content/70">Remove unwanted entries from Review and Library.</p>
          <button
            type="button"
            class="btn btn-error btn-outline btn-sm"
            data-role="clip-delete"
            phx-click="request"
            phx-target={@myself}
            disabled={!@can_remove? or @guard != :ok}
          >
            Delete clip…
          </button>
          <p
            :if={@guard != :ok}
            class="badge badge-warning h-auto whitespace-normal text-xs"
            data-role="clip-delete-guard"
          >
            {message(@guard)}
          </p>
          <ul aria-label="Render history" data-role="clip-render-history" class="space-y-2">
            <li
              :for={render <- @versions}
              class="flex flex-wrap items-center gap-2 border-t border-base-300 pt-2"
              data-role="clip-render-row"
              data-render-id={render.id}
            >
              <span class="font-mono text-xs">
                v{render.rev}{if render.rev == @clip.rev, do: " · Current"}
              </span>
              <span class="min-w-0 flex-1 truncate text-xs">
                {render.headline || "Untitled render"}
              </span>
              <button
                type="button"
                class="btn btn-ghost btn-xs text-error"
                data-role="render-delete"
                aria-label={"Delete render v#{render.rev}"}
                phx-click="request"
                phx-value-render={render.id}
                phx-target={@myself}
                disabled={!@can_remove? or @guards[render.id] != :ok}
              >
                Delete…
              </button>
              <span
                :if={@guards[render.id] != :ok}
                class="badge badge-warning h-auto whitespace-normal text-xs"
              >
                {message(@guards[render.id])}
              </span>
            </li>
          </ul>
        </div>
      </details>
      <p :if={@error} role="alert" class="mt-2 text-sm text-error" data-role="clip-delete-error">
        {@error}
      </p>
      <div
        :if={@target}
        id={@id <> "-dialog"}
        class="modal modal-open modal-middle"
        role="dialog"
        aria-modal="true"
        aria-labelledby={@id <> "-title"}
        phx-window-keydown="cancel"
        phx-key="escape"
        phx-target={@myself}
        phx-mounted={JS.focus_first(to: "##{@id}-dialog .modal-box")}
        phx-remove={JS.focus(to: "##{@id} summary")}
        data-role="clip-delete-dialog"
      >
        <.focus_wrap id={@id <> "-focus"} class="modal-box border border-base-300 bg-base-100">
          <h2 id={@id <> "-title"} class="text-lg font-semibold">
            Delete {target_label(@target, @clip)}?
          </h2>
          <p class="mt-3 text-sm">
            This removes the entry from Review and Library. Media files remain under Files retention. This cannot be undone here.
          </p>
          <p :if={@target != :clip and @target.rev == @clip.rev} class="mt-2 text-sm">
            The newest remaining playable version will become current. If none remains, the clip leaves Review and Library.
          </p>
          <div class="modal-action">
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="cancel"
              phx-target={@myself}
              data-role="clip-delete-cancel"
            >
              Cancel
            </button>
            <button
              type="button"
              class="btn btn-error"
              phx-click="confirm"
              phx-target={@myself}
              data-role="clip-delete-confirm"
            >
              {if @target == :clip, do: "Delete clip", else: "Delete render"}
            </button>
          </div>
        </.focus_wrap>
        <button
          type="button"
          class="modal-backdrop"
          phx-click="cancel"
          phx-target={@myself}
          aria-label="Cancel deletion"
        >
        </button>
      </div>
    </section>
    """
  end
end
