defmodule PlatformWeb.SocialClosingVideo do
  @moduledoc "Shared show ending and an actual pending-version join preview."
  use PlatformWeb, :live_component
  alias Platform.{Files, Repo, Social}
  alias Platform.Social.{ClipClosingVideo, ClosingAsset, ClipJob, ClipJobs}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       profile: nil,
       draft: nil,
       files: [],
       picker?: false,
       error: nil,
       preview_job: nil,
       preview: nil,
       candidates: [],
       affected: [],
       warnings: [],
       allowed?: false
     )
     |> allow_upload(:closing_video,
       accept: ~w(.mp4 .mov .webm),
       max_entries: 1,
       max_file_size: ClipClosingVideo.max_bytes(),
       auto_upload: true,
       progress: &upload_progress/3
     )}
  end

  @impl true
  def update(assigns, socket) do
    changed? =
      assigns[:profile] &&
        (!socket.assigns.profile || assigns.profile.id != socket.assigns.profile.id)

    socket = assign(socket, Map.drop(assigns, [:tick]))

    socket =
      if changed?,
        do:
          assign(socket, draft: nil, preview_job: nil, preview: nil, picker?: false, error: nil),
        else: socket

    {:ok, refresh(socket)}
  end

  defp fresh(socket) do
    p = socket.assigns.profile

    with true <- not is_nil(p),
         {:ok, files} <- ClipClosingVideo.list(p.org_id, p.id, socket.assigns.user_id),
         %{} = profile <- Social.get_profile(p.org_id, p.id),
         do: {:ok, profile, files},
         else: (_ -> {:error, :unauthorized})
  end

  defp refresh(socket) do
    case fresh(socket) do
      {:ok, p, files} ->
        saved = settings(p)
        renders = current_renders(p)

        candidates =
          Enum.filter(renders, fn {c, r} ->
            c.origin == "burrow" and is_map(r.source) and map_size(r.source) > 0 and
              is_binary(r.file_id) and not is_nil(Files.get_file(r.file_id))
          end)

        preview =
          Enum.find_value(candidates, fn {_c, r} ->
            if saved["enabled"] and same?(r.closing_video, saved), do: r
          end)

        socket
        |> assign(
          profile: p,
          files: files,
          allowed?: true,
          draft: socket.assigns.draft || saved,
          candidates: candidates,
          preview_job: socket.assigns.preview_job || active_preview(p, candidates, saved),
          affected: Enum.reject(renders, fn {_, r} -> same?(r.closing_video, saved) end),
          warnings: warnings(p, renders, saved),
          preview: preview
        )
        |> poll_preview()

      _ ->
        assign(socket,
          allowed?: false,
          files: [],
          candidates: [],
          preview: nil,
          affected: [],
          warnings: []
        )
    end
  end

  defp active_preview(p, candidates, saved) do
    ids = Enum.map(candidates, fn {c, _} -> c.id end)

    case ClipJobs.list_jobs(p.org_id, p.id) do
      {:ok, jobs} ->
        Enum.find_value(Enum.reverse(jobs), fn j ->
          closing = j.payload["closing_video"] || %{}

          if j.status in ~w(queued claimed running) and j.clip_id in ids and
               j.payload["appearance"] == true and closing["enabled"] == saved["enabled"] and
               closing["file_id"] == saved["file_id"] and closing["audio"] == saved["audio"],
             do: j.id
        end)

      _ ->
        nil
    end
  end

  defp settings(p) do
    s = p.closing_video

    %{
      "file_id" => s && s.file_id,
      "enabled" => !!(s && s.enabled),
      "audio" => to_string((s && s.audio) || :mute)
    }
  end

  defp same?(r, s), do: ClipClosingVideo.same_ending?(r, s)
  defp current_renders(p), do: ClipClosingVideo.review_renders(p)

  defp poll_preview(%{assigns: %{preview_job: nil}} = socket), do: socket

  defp poll_preview(socket) do
    p = socket.assigns.profile

    with {:ok, jobs} <- ClipJobs.list_jobs(p.org_id, p.id),
         %ClipJob{} = job <- Enum.find(jobs, &(&1.id == socket.assigns.preview_job)) do
      cond do
        job.status in ~w(queued claimed running) ->
          send_update_after(__MODULE__, %{id: socket.assigns.id, tick: true}, 1000)
          socket

        job.status in ~w(failed cancelled) ->
          assign(socket,
            preview_job: nil,
            error: "The preview could not render. Your playing version is unchanged."
          )

        true ->
          assign(socket, preview_job: nil)
      end
    else
      _ -> assign(socket, preview_job: nil)
    end
  end

  defp warnings(p, renders, s) do
    closing = asset(p, s["file_id"])

    accounts =
      Social.list_accounts(p.org_id, profile_id: p.id) |> Enum.filter(&(&1.status == "connected"))

    errors =
      for {_, r} <- renders,
          account <- accounts,
          content = content_duration(r),
          is_number(content),
          suffix = if(s["enabled"], do: if(closing, do: closing.duration_s), else: 0),
          is_number(suffix),
          {:error, errors} <- [
            Platform.Social.MediaRules.check(account.platform, account, [
              %{
                content_type: "video/mp4",
                duration_s:
                  if(same?(r.closing_video, s) and is_number(r.duration_s),
                    do: r.duration_s,
                    else: content + suffix
                  ),
                width: r.width,
                height: r.height,
                byte_size: nil
              }
            ])
          ],
          error <- errors,
          String.contains?(error, ["seconds", "duration"]),
          do: error

    errors |> Enum.frequencies() |> Enum.map(fn {text, n} -> "#{text} (#{n} clips)" end)
  end

  defp asset(_, nil), do: nil
  defp asset(p, id), do: Repo.get_by(ClosingAsset, profile_id: p.id, file_id: id)

  defp content_duration(r) do
    a = r.actual_start_s || r.trim_in_s || r.requested_start_s
    b = r.actual_end_s || r.trim_out_s || r.requested_end_s
    if is_number(a) and is_number(b), do: b - a
  end

  @impl true
  def handle_event("pick", _, socket) do
    case fresh(socket) do
      {:ok, _, _} -> {:noreply, socket |> refresh() |> assign(picker?: true, error: nil)}
      _ -> {:noreply, denied(socket)}
    end
  end

  def handle_event("close_picker", _, socket), do: {:noreply, assign(socket, picker?: false)}

  def handle_event("choose", %{"id" => id}, socket) do
    case fresh(socket) do
      {:ok, _, files} ->
        if Enum.any?(files, &(&1.id == id)),
          do:
            {:noreply,
             assign(socket,
               draft: %{socket.assigns.draft | "file_id" => id, "enabled" => true},
               picker?: false,
               error: nil
             )},
          else: {:noreply, assign(socket, error: "That video is unavailable in this project.")}

      _ ->
        {:noreply, denied(socket)}
    end
  end

  def handle_event("change", %{"closing" => params}, socket) do
    with {:ok, _, _} <- fresh(socket), true <- params["audio"] in ~w(keep mute) do
      {:noreply,
       assign(socket,
         draft: %{
           socket.assigns.draft
           | "enabled" => params["enabled"] == "true",
             "audio" => params["audio"]
         },
         error: nil
       )}
    else
      _ -> {:noreply, denied(socket)}
    end
  end

  def handle_event("save", _, socket) do
    with {:ok, p, _} <- fresh(socket),
         true <- Enum.all?(socket.assigns.uploads.closing_video.entries, & &1.done?),
         {:ok, p} <-
           ClipClosingVideo.save(p.org_id, p.id, socket.assigns.user_id, socket.assigns.draft) do
      {:noreply, socket |> assign(profile: p, draft: settings(p), error: nil) |> refresh()}
    else
      false -> {:noreply, assign(socket, error: "Still uploading, try again in a moment")}
      {:error, reason} -> {:noreply, socket |> recover_saved() |> assign(error: message(reason))}
    end
  end

  def handle_event("remove", _, socket) do
    with {:ok, p, _} <- fresh(socket),
         {:ok, p} <- ClipClosingVideo.remove(p.org_id, p.id, socket.assigns.user_id) do
      {:noreply,
       socket |> assign(profile: p, draft: settings(p), preview_job: nil, error: nil) |> refresh()}
    else
      _ -> {:noreply, denied(socket)}
    end
  end

  def handle_event("preview", _, socket) do
    socket = refresh(socket)

    with {:ok, p, _} <- fresh(socket),
         true <- socket.assigns.draft == settings(p),
         true <- is_nil(socket.assigns.preview_job),
         [{clip, base} | _] <- socket.assigns.candidates,
         {:ok, job} <-
           ClipJobs.enqueue_closing_video(p.org_id, clip.id, socket.assigns.user_id, %{
             base_render_id: base.id
           }) do
      send_update_after(__MODULE__, %{id: socket.assigns.id, tick: true}, 1000)
      {:noreply, assign(socket, preview_job: job.id, error: nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: message(reason))}

      _ ->
        {:noreply,
         assign(socket, error: "Save first, then choose an eligible unapproved clip for preview.")}
    end
  end

  def handle_event("upload", _, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :closing_video, ref)}
  end

  def handle_event(_, _, socket),
    do: {:noreply, assign(socket, error: "That action is unavailable. Reload and try again.")}

  def upload_progress(:closing_video, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          result =
            with {:ok, p, _} <- fresh(socket),
                 {:ok, bytes} <- File.read(path),
                 do:
                   ClipClosingVideo.upload(
                     p.org_id,
                     p.id,
                     socket.assigns.user_id,
                     bytes,
                     entry.client_name,
                     entry.client_type
                   )

          {:ok, result}
        end)

      case result do
        {:ok, %{file: f}} ->
          {:noreply,
           socket
           |> assign(
             draft: %{socket.assigns.draft | "file_id" => f.id, "enabled" => true},
             picker?: false,
             error: nil
           )
           |> refresh()}

        {:error, reason} ->
          {:noreply, assign(socket, error: message(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  defp recover_saved(socket) do
    case fresh(socket) do
      {:ok, p, _} -> socket |> assign(profile: p, draft: settings(p)) |> refresh()
      _ -> socket
    end
  end

  defp denied(socket),
    do: assign(socket, allowed?: false, error: "You no longer have access to this project")

  defp message(:video_too_large),
    do: "Over the #{div(ClipClosingVideo.max_bytes(), 1024 * 1024)} MiB limit"

  defp message(reason) when reason in [:not_a_video, :invalid_video],
    do: "That file isn't a video"

  defp message(:already_an_episode),
    do: "That file is already an episode. Choose a different video."

  defp message(:job_in_flight), do: "A render is already running. Wait for it to finish."
  defp message(:stale_version), do: "A newer clip version is ready. Reload and try again."

  defp message(reason) when reason in [:unauthorized, :not_an_approver, :not_found],
    do: "You no longer have access to this project"

  defp message(_), do: "That video is unavailable. The saved closing video is unchanged."

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        selected: Enum.find(assigns.files, &(&1.id == assigns.draft["file_id"])),
        saved_file: Enum.find(assigns.files, &(&1.id == settings(assigns.profile)["file_id"])),
        asset: asset(assigns.profile, assigns.draft["file_id"]),
        dirty?: assigns.draft != settings(assigns.profile),
        uploading?: Enum.any?(assigns.uploads.closing_video.entries, &(not &1.done?))
      )

    ~H"""
    <section
      id={@id}
      class="card mb-6 max-w-xl rounded-box border border-base-300 bg-base-100"
      aria-labelledby={@id <> "-title"}
    >
      <div class="card-body gap-4 p-4 sm:p-5">
        <h2 id={@id <> "-title"} class="text-base font-semibold">Closing video</h2>
        <p class="text-sm text-subtle">
          Added to the end of every new clip for {@profile.name}. Your logo should be in the video itself.
        </p>
        <p :if={@error} role="alert" class="text-sm text-error">{@error}</p>
        <p :if={!@allowed?} class="text-sm text-subtle">
          Only a show approver with project access can manage the closing video.
        </p>
        <div :if={@allowed? && !@draft["file_id"]} class="rounded-box bg-base-200 p-4">
          <p class="text-sm">No closing video. Clips end where the highlight ends.</p>
          <button
            type="button"
            phx-click="pick"
            phx-target={@myself}
            class="btn btn-primary mt-3 rounded-field"
          >
            Choose video
          </button>
        </div>
        <div :if={@allowed? && @draft["file_id"]} class="space-y-3">
          <div
            :if={@preview_job}
            role="status"
            class="rounded-box bg-base-200 p-4 text-sm"
            data-role="closing-preview-pending"
          >
            Rendering preview… A new pending version will be ready for review. Your playing version stays available.
          </div>
          <div
            :if={@preview && !@preview_job && !@dirty?}
            id={@id <> "-preview"}
            phx-hook="ClosingVideoPreview"
            data-seam={content_duration(@preview)}
            data-total={@preview.duration_s}
            class="relative rounded-box bg-base-200 p-3"
          >
            <video
              id={@id <> "-join-video"}
              controls
              preload="metadata"
              class="mx-auto max-h-72 w-full rounded-box"
              src={"/files/blob/#{@preview.file_id}"}
              aria-label="Rendered join preview"
            >
            </video>
            <p hidden data-role="closing-media-error" role="status" class="p-4 text-sm text-subtle">
              Preview video unavailable. Reload or choose another video.
            </p>
            <progress data-role="closing-playhead" class="progress mt-2 w-full" value="0" max="1">
            </progress>
            <span
              data-role="closing-seam"
              class="absolute bottom-7 h-3 border-l border-base-content"
              title="Closing video begins"
            >
            </span>
            <p class="mt-1 font-mono text-xs">
              {clock(content_duration(@preview))} + {clock(
                @preview.closing_video && @preview.closing_video.duration_s
              )} = {clock(@preview.duration_s)}
            </p>
          </div>
          <div
            :if={!@preview || @dirty?}
            id={@id <> "-closing-player"}
            phx-hook="ClosingVideoPreview"
            data-audio={@draft["audio"]}
            class="rounded-box bg-base-200 p-3"
          >
            <video
              :if={@selected}
              id={@id <> "-closing-only"}
              controls
              preload="metadata"
              muted={@draft["audio"] == "mute"}
              class="mx-auto max-h-64 w-full rounded-box"
              src={"/files/blob/#{@selected.id}"}
              aria-label="Closing video only"
            >
            </video>
            <p hidden data-role="closing-media-error" role="status" class="p-4 text-sm text-subtle">
              Preview video unavailable. Reload or choose another video.
            </p>
            <p class="mt-2 text-xs text-subtle">
              <%= cond do %>
                <% !@selected -> %>
                  The saved closing video is unavailable. Replace or remove it.
                <% @candidates == [] -> %>
                  No eligible unapproved clip is available. Playing the closing video only.
                <% true -> %>
                  Closing video only. Save, then preview a rendered join.
              <% end %>
            </p>
          </div>
          <div class="flex min-w-0 flex-wrap items-center gap-2 text-sm">
            <span class={[
              "min-w-0 basis-full truncate sm:basis-auto sm:flex-1",
              !@draft["enabled"] && "text-subtle"
            ]}>
              {if @selected, do: @selected.name, else: "Saved video unavailable"}
            </span>
            <span :if={!@asset && @selected} class="text-xs text-subtle">
              Duration and dimensions unknown until Save
            </span>
            <span :if={@asset} class="font-mono text-xs text-subtle">
              {clock(@asset.duration_s)} · {@asset.width}×{@asset.height}
            </span>
            <button
              type="button"
              phx-click="pick"
              phx-target={@myself}
              class="btn btn-ghost btn-sm rounded-field"
            >
              Replace
            </button>
            <button
              type="button"
              phx-click="remove"
              phx-target={@myself}
              class="btn btn-ghost btn-sm rounded-field"
            >
              Remove
            </button>
          </div>
          <p :if={@dirty? && @saved_file} class="text-xs text-subtle">
            Saved: {@saved_file.name}. Changes apply after Save.
          </p>
          <form
            id={@id <> "-form"}
            phx-change="change"
            phx-submit="save"
            phx-target={@myself}
            class="space-y-3"
          >
            <div class="flex flex-wrap items-center justify-between gap-3">
              <label class="flex items-center gap-2 text-sm">
                <input type="hidden" name="closing[enabled]" value="false" /><input
                  type="checkbox"
                  name="closing[enabled]"
                  value="true"
                  checked={@draft["enabled"]}
                  class="toggle rounded-selector"
                />Enabled
              </label>
              <fieldset class="flex flex-wrap items-center gap-2 text-sm">
                <legend class="sr-only">Closing audio</legend>
                <span aria-hidden="true">Closing audio:</span>
                <div class="join">
                  <label
                    :for={mode <- ~w(keep mute)}
                    class={[
                      "btn btn-sm join-item rounded-selector",
                      @draft["audio"] == mode && "btn-active"
                    ]}
                  >
                    <input
                      type="radio"
                      name="closing[audio]"
                      value={mode}
                      checked={@draft["audio"] == mode}
                      class="sr-only"
                    />
                    {String.capitalize(mode)}
                  </label>
                </div>
              </fieldset>
            </div>
            <p :if={!@draft["enabled"]} class="text-sm text-subtle">
              Saved but off: new clips won't use it
            </p>
            <div class="flex flex-wrap gap-2">
              <button
                :if={@dirty?}
                type="submit"
                disabled={@uploading?}
                class="btn btn-primary rounded-field"
              >
                Save
              </button>
              <button
                :if={@candidates != [] && @draft["enabled"]}
                type="button"
                phx-click="preview"
                phx-target={@myself}
                disabled={@dirty? || !!@preview_job || !!@preview}
                class="btn btn-outline rounded-field"
              >
                Preview join
              </button>
            </div>
          </form>
        </div>
        <p
          :if={@affected != [] && @draft["file_id"]}
          class="rounded-box bg-info/10 p-3 text-sm text-info"
        >
          Applies to new clips. {length(@affected)} clips in review still end with the previous video.
          <a
            href={"/m/social?tab=clips&view=review&profile=#{@profile.id}&closing=previous"}
            class="link"
          >
            Review them
          </a>
        </p>
        <p :for={warning <- @warnings} class="text-sm text-warning">{warning}</p>
        <div
          :if={@picker?}
          class="modal modal-open items-end sm:items-center"
          role="dialog"
          aria-modal="true"
          aria-label="Choose closing video"
          phx-window-keydown="close_picker"
          phx-key="Escape"
          phx-target={@myself}
        >
          <div class="modal-box max-h-[85vh] rounded-t-box rounded-b-none bg-base-100 sm:rounded-box">
            <div class="flex items-center justify-between">
              <h3 class="text-base font-semibold">Choose video</h3>
              <button
                type="button"
                phx-click="close_picker"
                phx-target={@myself}
                class="btn btn-ghost btn-sm rounded-field"
                aria-label="Close picker"
              >
                Close
              </button>
            </div>
            <p class="mt-2 text-sm text-subtle">
              From project Files, or upload. MP4, MOV or WebM · {div(
                ClipClosingVideo.max_bytes(),
                1024 * 1024
              )} MiB maximum.
            </p>
            <form
              id={@id <> "-upload"}
              phx-change="upload"
              phx-submit="upload"
              phx-target={@myself}
              class="my-4"
            >
              <label class="block text-sm">
                Upload video<.live_file_input
                  upload={@uploads.closing_video}
                  class="file-input mt-2 w-full rounded-field"
                />
              </label>
              <div :for={entry <- @uploads.closing_video.entries} class="mt-2 text-sm">
                <span>{entry.client_name}</span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs rounded-field"
                >
                  Cancel upload
                </button>
                <progress
                  class="progress w-full"
                  value={entry.progress}
                  max="100"
                >
                  {entry.progress}%
                </progress>
                <p
                  :for={error <- upload_errors(@uploads.closing_video, entry)}
                  role="alert"
                  class="text-error"
                >
                  {upload_message(error)}
                </p>
              </div>
              <button
                :if={@uploading?}
                type="button"
                disabled
                class="btn btn-primary mt-2 rounded-field"
              >
                Save
              </button>
              <p
                :for={error <- upload_errors(@uploads.closing_video)}
                role="alert"
                class="text-sm text-error"
              >
                {upload_message(error)}
              </p>
            </form>
            <p :if={@error} role="alert" class="mb-3 text-sm text-error">{@error}</p>
            <p :if={@files == []} class="rounded-box bg-base-200 p-4 text-sm">
              No project videos yet.
            </p>
            <button
              :for={file <- @files}
              type="button"
              phx-click="choose"
              phx-value-id={file.id}
              phx-target={@myself}
              class="btn btn-ghost mb-1 w-full justify-start rounded-field"
            >
              <span class="truncate">{file.name}</span>
            </button>
          </div>
          <button
            type="button"
            class="modal-backdrop"
            phx-click="close_picker"
            phx-target={@myself}
            aria-label="Close picker"
          >
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp clock(n) when is_number(n) and n >= 0 do
    tenths = round(n * 10)
    s = div(tenths, 10)
    decimal = if rem(tenths, 10) == 0, do: "", else: ".#{rem(tenths, 10)}"
    "#{div(s, 60)}:#{s |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}#{decimal}"
  end

  defp clock(_), do: "unknown"
  defp upload_message(:too_large), do: message(:video_too_large)
  defp upload_message(:not_accepted), do: "That file isn't a video"
  defp upload_message(_), do: "The upload could not finish. Try again."
end
