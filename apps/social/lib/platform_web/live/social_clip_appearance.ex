defmodule PlatformWeb.SocialClipAppearance do
  @moduledoc "Caption appearance drafts and exact-version rerenders; never mutates a playing render."
  use PlatformWeb, :live_component
  alias Platform.Social

  alias Platform.Social.{
    ClipJobs,
    ClipLook,
    ClipVersions,
    ClipMusic,
    ClipCaptionRenderer,
    ClipCaptionPreviews
  }

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       base: nil,
       style: nil,
       error: nil,
       attempt: nil,
       track: ClipMusic.settings(nil),
       tracks: []
     )
     |> allow_upload(:music,
       accept: ["audio/*"],
       max_entries: 1,
       max_file_size: ClipMusic.max_bytes(),
       auto_upload: true,
       progress: &handle_music_progress/3
     )}
  end

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

    tracks =
      case ClipMusic.list(profile || p, user) do
        {:ok, files} -> files
        _ -> []
      end

    socket =
      assign(socket,
        base: base,
        can_edit?: !!can?,
        pending?: pending?,
        attempt: attempt,
        tracks: tracks,
        supported_styles: ClipCaptionRenderer.styles(),
        renderer_receipt: ClipCaptionRenderer.receipt()
      )

    socket =
      if changed?,
        do:
          assign(socket,
            style: applied_style(base),
            track: ClipMusic.settings(base && base.look),
            error: nil
          ),
        else: socket

    notify(socket)
  end

  defp applied_style(nil), do: nil
  defp applied_style(base), do: get_in(base.look || %{}, ["cap", "style"])

  defp dirty?(socket),
    do:
      socket.assigns.style !=
        applied_style(socket.assigns.base) or
        socket.assigns.track !=
          ClipMusic.settings(socket.assigns.base && socket.assigns.base.look)

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

    if socket.assigns.can_edit? and not socket.assigns.pending? and
         style in ClipCaptionRenderer.styles(),
       do: {:noreply, socket |> assign(style: style, error: nil) |> notify()},
       else: {:noreply, socket}
  end

  def handle_event("render", params, socket) do
    socket = load(socket)
    %{profile: p, clip: clip, user_id: user, style: style} = socket.assigns

    if socket.assigns.can_edit? and not is_nil(socket.assigns.base) do
      case ClipJobs.enqueue_appearance(p.org_id, clip.id, user, %{
             "base_render_id" => params["base_render_id"],
             "look" => %{
               "cap" => %{"style" => style || ClipLook.caption_style(socket.assigns.base.look)},
               "music_track" => socket.assigns.track
             }
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

  def handle_event("music", params, socket) do
    socket = load(socket)

    if socket.assigns.can_edit? and not socket.assigns.pending? do
      current = socket.assigns.track
      id = Map.get(params, "file_id", current["file_id"])
      id = if id == "", do: nil, else: id

      gain =
        case Float.parse(to_string(Map.get(params, "gain_db", current["gain_db"]))) do
          {n, ""} when n >= -60 and n <= 0 -> n
          _ -> current["gain_db"]
        end

      muted = Map.get(params, "muted", to_string(current["muted"])) == "true"
      track = %{"file_id" => id, "gain_db" => gain, "muted" => muted or is_nil(id)}
      valid = is_nil(id) or match?({:ok, _}, ClipMusic.resolve(socket.assigns.profile, id))

      if valid,
        do: {:noreply, socket |> assign(track: track, error: nil) |> notify()},
        else: {:noreply, assign(socket, :error, "That song is unavailable in this project.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("music_upload", _, socket), do: {:noreply, socket}

  def handle_music_progress(:music, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          result =
            if socket.assigns.can_edit? and not socket.assigns.pending?,
              do:
                ClipMusic.upload(
                  socket.assigns.profile,
                  socket.assigns.user_id,
                  File.read!(path),
                  entry.client_name,
                  entry.client_type
                ),
              else: {:error, :unauthorized}

          {:ok, result}
        end)

      case result do
        {:ok, file} ->
          track = Map.merge(socket.assigns.track, %{"file_id" => file.id, "muted" => false})
          {:noreply, socket |> assign(track: track, error: nil) |> load() |> notify()}

        _ ->
          {:noreply,
           assign(socket, :error, "Upload an MP3, WAV, M4A, Ogg or FLAC audio file under 25 MB.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp message(:stale_version),
    do: "A newer version is ready. Reload it before changing captions."

  defp message(:caption_renderer_unavailable),
    do:
      "This caption treatment is unavailable. Choose an available style or try again after the renderer is ready."

  defp message(:job_in_flight), do: "A render is already running. Wait for it to finish."
  defp message(_), do: "This version cannot be changed. Reload and try again."

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :dirty?,
        dirty?(%{assigns: assigns})
      )

    assigns = assign(assigns, cards: ClipCaptionPreviews.cards())

    ~H"""
    <section
      id={@id}
      class="space-y-3 rounded-box border border-base-300 bg-base-200 p-3"
      aria-label="Clip appearance"
      data-role="clip-appearance"
    >
      <h3 id={"#{@id}-style-label"} class="text-sm font-semibold">Caption style</h3>
      <div
        id={"#{@id}-previews"}
        class="caption-preview-row"
        role="group"
        aria-labelledby={"#{@id}-style-label"}
        data-role="caption-preview-group"
      >
        <div
          id={"#{@id}-preview-sync"}
          phx-hook="SyncedVideoPreviews"
          phx-update="ignore"
          data-preview-controls={"#{@id}-previews"}
          class="hidden"
        />
        <button
          :for={card <- @cards}
          id={"#{@id}-style-#{card.style}"}
          type="button"
          phx-click="choose"
          phx-value-style={card.style}
          phx-target={@myself}
          aria-pressed={to_string(@style == card.style)}
          aria-label={"#{card.name}: #{card.description}"}
          aria-describedby={if applied_style(@base) == card.style, do: "#{@id}-current-#{card.style}"}
          disabled={!@can_edit? or @pending? or is_nil(@base) or card.style not in @supported_styles}
          class={[
            "caption-preview-card rounded-box border border-base-300 bg-base-100 text-left focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary",
            if(@style == card.style, do: "caption-preview-selected")
          ]}
          data-role="caption-style"
          data-style={card.style}
        >
          <span id={"#{@id}-media-#{card.style}"} phx-update="ignore" class="block">
            <span
              data-preview-media
              data-preview-state="loading"
              class="caption-preview-media"
              aria-hidden="true"
            >
              <video
                data-preview-video
                src={card.video}
                poster={elem(hd(card.frames), 1)}
                muted
                loop
                playsinline
                preload="auto"
                tabindex="-1"
              />
              <span data-preview-stills class="caption-preview-stills">
                <img
                  :for={{phase, src} <- card.frames}
                  src={src}
                  alt={"#{card.name}, #{phase}"}
                  loading="lazy"
                />
              </span>
              <span data-preview-loading class="caption-preview-status">Loading preview…</span>
              <span data-preview-error class="caption-preview-status">Preview unavailable</span>
            </span>
          </span>
          <span class="mt-2 flex min-h-5 items-center justify-between gap-1 text-xs font-semibold text-base-content">
            <span>{card.name}</span>
            <span
              :if={applied_style(@base) == card.style}
              id={"#{@id}-current-#{card.style}"}
              class="badge badge-info badge-xs"
              data-role="caption-current"
            >
              Current
            </span>
          </span>
          <span
            class="caption-preview-description mt-1 block text-xs text-subtle"
            title={card.description}
          >
            {card.description}
          </span>
          <span
            :if={card.style not in @supported_styles}
            class="mt-1 block text-xs text-subtle"
            data-role="caption-unavailable"
          >
            Renderer unavailable
          </span>
        </button>
      </div>
      <p class="text-xs text-subtle">
        Same excerpt in every preview. Choose a style to render your clip.
      </p>
      <details class="text-xs text-subtle" data-role="caption-metadata">
        <summary>Render details</summary>
        <p class="font-mono text-xs">Preview v1 · CLI 0.9.0 · caption-treatments/1</p>
        <p :if={@renderer_receipt} class="font-mono text-xs">Qualified renderer · helper 0.9.0</p>
        <p :if={!@renderer_receipt}>
          New treatments are unavailable until the renderer is qualified.
        </p>
      </details>
      <p class="text-xs text-subtle" data-role="caption-applied">
        Applied: {ClipCaptionPreviews.version_label(@base || %{look: %{}})}
      </p>
      <p :if={@dirty?} class="text-xs text-info" data-role="caption-dirty">
        Captions or music changed. Rerender to review the new version
      </p>
      <PlatformWeb.SocialClipMusic.controls
        track={@track}
        tracks={@tracks}
        base={@base}
        disabled={!@can_edit? or @pending? or is_nil(@base)}
        target={@myself}
        upload={@uploads.music}
      />
      <form phx-submit="render" phx-target={@myself} data-role="caption-render-form">
        <input type="hidden" name="base_render_id" value={@base && @base.id} />
        <button
          class="btn btn-primary btn-sm min-h-11 h-auto text-wrap py-2"
          type="submit"
          disabled={!@can_edit? or @pending? or !@dirty? or is_nil(@base)}
          data-role="caption-render"
        >
          Apply {ClipCaptionPreviews.label(@style || applied_style(@base) || "phrase-pop")} — queues a new render; approval resets
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
        Render failed. Your previous video is unchanged. Check that the runner has the original project or source and selected audio, then apply the style again.
      </p>
    </section>
    """
  end
end
