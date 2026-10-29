defmodule PlatformWeb.SocialClipAppearance do
  @moduledoc "Caption appearance drafts and exact-version rerenders; never mutates a playing render."
  use PlatformWeb, :live_component
  alias Platform.Social
  alias Platform.Social.{ClipJobs, ClipLook, ClipVersions}

  @impl true
  def mount(socket), do: {:ok, assign(socket, base: nil, style: nil, error: nil, attempt: nil)}

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns) |> load()
    {:ok, socket}
  end

  defp load(socket) do
    %{profile: p, clip: clip, user_id: user} = socket.assigns
    profile = Social.get_profile(p.org_id, p.id)
    can? = profile && Social.approver_check(p.org_id, profile, user) == :ok

    base =
      case ClipVersions.recent(p.org_id, p.id, clip.id) do
        {:ok, versions} -> Enum.find(versions, &(&1.rev == clip.rev))
        _ -> nil
      end

    jobs =
      case ClipJobs.list_jobs(p.org_id, p.id) do
        {:ok, jobs} -> Enum.filter(jobs, &(&1.clip_id == clip.id))
        _ -> []
      end

    attempt = jobs |> Enum.filter(& &1.payload["appearance"]) |> List.last()
    pending? = Enum.any?(jobs, &(&1.status in ~w(queued claimed running)))
    changed? = (socket.assigns.base && socket.assigns.base.id) != (base && base.id)
    socket = assign(socket, base: base, can_edit?: !!can?, pending?: pending?, attempt: attempt)

    socket =
      if changed?,
        do: assign(socket, style: applied_style(base), error: nil),
        else: socket

    notify(socket)
  end

  defp applied_style(nil), do: nil
  defp applied_style(base), do: get_in(base.look || %{}, ["cap", "style"])

  defp dirty?(socket),
    do:
      socket.assigns.style !=
        applied_style(socket.assigns.base)

  defp notify(socket) do
    send_update(PlatformWeb.SocialClipsReview,
      id: socket.assigns.review_id,
      appearance_clip_id: socket.assigns.clip.id,
      appearance_dirty: dirty?(socket) or socket.assigns.pending?
    )

    socket
  end

  @impl true
  def handle_event("choose", %{"style" => style}, socket) do
    socket = load(socket)

    if socket.assigns.can_edit? and not socket.assigns.pending? and style in ClipLook.styles(),
      do: {:noreply, socket |> assign(style: style, error: nil) |> notify()},
      else: {:noreply, socket}
  end

  def handle_event("render", params, socket) do
    socket = load(socket)
    %{profile: p, clip: clip, user_id: user, style: style} = socket.assigns

    if socket.assigns.can_edit? do
      case ClipJobs.enqueue_appearance(p.org_id, clip.id, user, %{
             "base_render_id" => params["base_render_id"],
             "look" => %{"cap" => %{"style" => style}}
           }) do
        {:ok, _} ->
          send_update(PlatformWeb.SocialClipsReview,
            id: socket.assigns.review_id,
            job_event: true
          )

          {:noreply, socket |> assign(:error, nil) |> load()}

        {:error, reason} ->
          {:noreply, assign(socket, :error, message(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  defp message(:stale_version),
    do: "A newer version is ready. Reload it before changing captions."

  defp message(:job_in_flight), do: "A render is already running. Wait for it to finish."
  defp message(_), do: "This version cannot be changed. Reload and try again."

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :dirty?,
        assigns.style != applied_style(assigns.base)
      )

    ~H"""
    <section
      id={@id}
      class="space-y-3 rounded-box border border-base-300 bg-base-200 p-3"
      aria-label="Caption appearance"
      data-role="clip-appearance"
    >
      <h3 class="text-sm font-semibold">Captions</h3>
      <div class="grid grid-cols-3 gap-2" role="group" aria-label="Caption style">
        <button
          :for={
            {style, label, sample} <- [
              {"plain", "Plain", "A clean lower caption"},
              {"phrase-pop", "Phrase pop", "SHORT PHRASES"},
              {"karaoke", "Word highlight", "Follow each word"}
            ]
          }
          type="button"
          phx-click="choose"
          phx-value-style={style}
          phx-target={@myself}
          aria-pressed={to_string(@style == style)}
          disabled={!@can_edit? or @pending? or is_nil(@base)}
          class={[
            "rounded-box border p-2 text-left hover:border-info focus-visible:outline focus-visible:outline-2 focus-visible:outline-info",
            if(@style == style, do: "border-info bg-base-100", else: "border-base-300")
          ]}
          data-role="caption-style"
          data-style={style}
        >
          <span
            class="flex h-16 items-end justify-center rounded bg-neutral p-1 text-center text-[10px] text-neutral-content"
            aria-hidden="true"
          >
            <span class={if style == "karaoke", do: "text-warning", else: ""}>{sample}</span>
          </span>
          <span class="mt-1 block text-xs font-semibold">{label}</span>
        </button>
      </div>
      <p class="text-xs text-subtle">
        Sample captions. Render preview to see this clip in the selected style.
      </p>
      <p class="font-mono text-xs" data-role="caption-applied">
        Applied: {applied_style(@base) || "Existing render (style not recorded)"}
      </p>
      <p :if={@dirty?} class="text-xs text-info" data-role="caption-dirty">
        Captions or music changed. Rerender to review the new version
      </p>
      <form phx-submit="render" phx-target={@myself} data-role="caption-render-form">
        <input type="hidden" name="base_render_id" value={@base && @base.id} />
        <button
          class="btn btn-outline btn-sm min-h-11"
          type="submit"
          disabled={!@can_edit? or @pending? or !@dirty? or is_nil(@base)}
          data-role="caption-render"
        >
          Render preview
        </button>
      </form>
      <p :if={@pending?} role="status" class="text-xs text-info" data-role="caption-pending">
        Rendering a new version. You can keep playing this one.
      </p>
      <p :if={@error} role="alert" class="text-xs text-error" data-role="caption-error">{@error}</p>
      <p
        :if={@attempt && @attempt.status == "failed"}
        role="alert"
        class="text-xs text-error"
        data-role="caption-failure"
      >
        Render failed. Your previous video is unchanged. Check that the runner has the original project or source, then try Render preview again.
      </p>
    </section>
    """
  end
end
