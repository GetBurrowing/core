defmodule PlatformWeb.SocialClipRevision do
  @moduledoc "Editing instructions and same-clip returns; publishing and working copy stay with their existing controls."
  use PlatformWeb, :live_component
  alias Platform.Social.{ClipClosingVideo, ClipRevisionContract, ClipRevisions}
  alias PlatformWeb.SocialClipRevisionState

  @doc false
  # A display predicate for the parent, not an authority check. A stateful
  # component needs a root tag, so empty cards must not be mounted at all.
  def visible?(clip),
    do: clip.review_status == "pending" or not is_nil(ClipRevisions.latest(clip.id))

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       allowed?: false,
       state: nil,
       form: nil,
       form_stamp: nil,
       upload_context: nil,
       error: nil,
       notice: nil
     )
     |> stream_configure(:revision_history, dom_id: &"clip-edit-request-#{&1.id}")
     |> allow_upload(:recut,
       accept: ~w(.mp4 .mov .webm),
       max_entries: 1,
       max_file_size: ClipClosingVideo.max_bytes()
     )}
  end

  @impl true
  def update(assigns, socket) do
    previous = {socket.assigns[:clip] && socket.assigns.clip.id, socket.assigns[:user_id]}
    socket = assign(socket, assigns)

    socket =
      if previous != {assigns.clip.id, assigns.user_id},
        do:
          reset_upload(socket)
          |> assign(form: nil, form_stamp: nil, upload_context: nil, error: nil, notice: nil),
        else: socket

    {:ok, socket |> refresh() |> sync_form()}
  end

  @impl true
  def handle_event("revision_change", %{"request" => params}, socket) do
    socket = refresh(socket)

    if socket.assigns.allowed? and socket.assigns.state.can_request?,
      do: {:noreply, merge_form(socket, params)},
      else: {:noreply, socket}
  end

  def handle_event("revision_request", %{"request" => params}, socket) do
    socket = refresh(socket)

    cond do
      not socket.assigns.allowed? or not socket.assigns.state.can_request? ->
        {:noreply, assign(socket, :error, "You cannot request an edit for this clip now.")}

      is_nil(socket.assigns.form) or
          params["request_id"] != socket.assigns.form.params["request_id"] ->
        {:noreply,
         assign(
           socket,
           :error,
           "This editing form has changed. Use the current form to send a new request."
         )}

      true ->
        socket = merge_form(socket, params) |> assign(error: nil, notice: nil)
        data = socket.assigns.form.params
        state = socket.assigns.state

        with {:ok, assignee} <- assignee(data["assignee"], state.agents),
             attrs = %{
               request_id: data["request_id"],
               base_render_id: data["base_render_id"],
               assignee: assignee,
               note: data["note"],
               replaces_request_id: data["replaces_request_id"]
             },
             {:ok, %{request: _request}} <-
               ClipRevisions.request_edit(
                 socket.assigns.scope,
                 state.clip.id,
                 socket.assigns.user_id,
                 attrs
               ) do
          send(self(), {__MODULE__, :requested, state.clip.id})

          {:noreply,
           socket
           |> assign(
             notice: "Editing request saved.",
             error: nil,
             form_stamp: nil,
             upload_context: nil
           )
           |> refresh()
           |> sync_form()}
        else
          {:error, reason} -> {:noreply, assign(socket, :error, refusal(reason))}
        end
    end
  end

  def handle_event("revision_upload_change", _params, socket),
    do: {:noreply, refresh(socket)}

  def handle_event("revision_upload", _params, socket) do
    context = socket.assigns.upload_context
    socket = refresh(socket) |> assign(error: nil, notice: nil)

    if socket.assigns.allowed? and socket.assigns.state.can_upload? and
         not is_nil(context) and socket.assigns.state.request.id == context.request_id do
      {completed, in_progress} = uploaded_entries(socket, :recut)

      cond do
        in_progress != [] ->
          {:noreply, assign(socket, :error, "Wait for the video upload to finish.")}

        completed == [] ->
          {:noreply, assign(socket, :error, "Choose the returned video first.")}

        true ->
          results =
            consume_uploaded_entries(socket, :recut, fn %{path: path}, entry ->
              {:ok, register_return(socket, context, path, entry)}
            end)

          case results do
            [{:ok, %{clip: clip}}] ->
              send(self(), {__MODULE__, :returned, clip.id})

              {:noreply,
               socket
               |> assign(
                 notice: nil,
                 error: nil,
                 upload_context: nil,
                 form_stamp: nil
               )
               |> refresh()
               |> sync_form()}

            [{:error, reason}] ->
              {:noreply, assign(socket, :error, refusal(reason))}

            _ ->
              {:noreply, assign(socket, :error, "The returned video could not be saved.")}
          end
      end
    else
      {:noreply,
       assign(socket, :error, "This editing request changed or you are not its assigned editor.")}
    end
  end

  def handle_event("revision_upload_cancel", %{"ref" => ref}, socket),
    do: {:noreply, socket |> cancel_upload(:recut, ref) |> refresh()}

  def handle_event(_event, _params, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    %{scope: scope, profile: profile, clip: clip, user_id: user_id} = socket.assigns

    case SocialClipRevisionState.load(scope, profile.id, clip.id, user_id) do
      {:ok, state} ->
        context =
          if state.can_upload?,
            do: %{
              request_id: state.request.id,
              base_render_id: state.request.base_render_id,
              clip_id: state.clip.id
            }

        # A selected file stays bound to the request displayed when it was selected.
        held_context =
          if socket.assigns.uploads.recut.entries == [],
            do: context,
            else: socket.assigns.upload_context

        socket
        |> assign(allowed?: true, state: state, upload_context: held_context)
        |> stream(:revision_history, state.history, reset: true)

      _ ->
        socket
        |> assign(allowed?: false, state: nil, upload_context: nil)
        |> stream(:revision_history, [], reset: true)
    end
  end

  defp sync_form(%{assigns: %{allowed?: false}} = socket), do: socket

  defp sync_form(socket) do
    state = socket.assigns.state
    stamp = {state.clip.id, state.base && state.base.id, state.request && state.request.id}

    if socket.assigns.form_stamp == stamp and not is_nil(socket.assigns.form) do
      socket
    else
      data = %{
        "note" => "",
        "assignee" => "",
        "request_id" => Ecto.UUID.generate(),
        "base_render_id" => state.base && state.base.id,
        "replaces_request_id" => if(state.replaceable?, do: state.request.id)
      }

      assign(socket, form: to_form(data, as: :request), form_stamp: stamp)
    end
  end

  defp merge_form(socket, params) do
    data = Map.merge(socket.assigns.form.params, Map.take(params, ["note", "assignee"]))
    assign(socket, :form, to_form(data, as: :request))
  end

  defp assignee("self", _agents), do: {:ok, :self}

  defp assignee("agent:" <> id, agents) do
    if Enum.any?(agents, &(&1.id == id)),
      do: {:ok, {:agent, id}},
      else: {:error, :invalid_assignee}
  end

  defp assignee(_, _), do: {:error, :invalid_assignee}

  defp register_return(socket, context, path, entry) do
    with {:ok, bytes} <- File.read(path),
         sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
         {:ok, submission_id} <-
           ClipRevisionContract.submission_id(
             context.request_id,
             context.clip_id,
             context.base_render_id,
             sha
           ) do
      attrs =
        Map.merge(context, %{
          submission_id: submission_id,
          sha256: sha,
          byte_size: byte_size(bytes)
        })
        |> Map.delete(:clip_id)

      ClipRevisions.upload_version(
        socket.assigns.scope,
        context.clip_id,
        socket.assigns.user_id,
        bytes,
        entry.client_name,
        entry.client_type,
        attrs
      )
    else
      {:error, :unreadable_video} -> {:error, :unreadable_video}
      {:error, _} -> {:error, :upload_failed}
    end
  end

  defp reset_upload(socket) do
    Enum.reduce(socket.assigns.uploads.recut.entries, socket, fn entry, acc ->
      cancel_upload(acc, :recut, entry.ref)
    end)
  end

  defp refusal(:note_required), do: "Write an editing note first."
  defp refusal(:note_too_long), do: "Keep the editing note under 2,000 characters."
  defp refusal(:invalid_assignee), do: "Choose self or an available editing agent."

  defp refusal(:maker_unavailable),
    do: "That editing agent is no longer available. Choose an editor again."

  defp refusal(:stale_version),
    do: "The clip version changed. Reopen the clip before requesting an edit."

  defp refusal(:idempotency_conflict),
    do: "This request changed after it was sent. Reopen the clip before sending another request."

  defp refusal(:request_not_replaceable),
    do: "This request can no longer be replaced. Reopen the clip to see its current state."

  defp refusal(:request_not_open),
    do: "This editing request is no longer open. Reopen the clip before returning media."

  defp refusal(:request_already_returned),
    do: "This editing request already has a returned version."

  defp refusal(:same_content),
    do: "The returned file has the same content as the original. Choose the edited video."

  defp refusal(:probe_lifecycle),
    do:
      "Video inspection could not finish safely. Nothing was returned. Ask an operator to resolve the retained inspection before trying again."

  defp refusal(:unreadable_video), do: "The video could not be read. Choose a playable video."
  defp refusal(:not_a_video), do: "Choose an MP4, MOV or WebM video."
  defp refusal(:video_too_large), do: "The video is too large. Choose a smaller file."
  defp refusal(:not_pending), do: "This clip is no longer awaiting a review decision."

  defp refusal(_),
    do:
      "The editing request or returned video could not be saved. Reopen the clip and check your access."

  defp notification(%{notification_status: "sent", assignee_name: name}),
    do: "Request posted for #{name}. Receipt is not confirmed."

  defp notification(%{notification_status: status}), do: notification(status)

  defp notification("failed"), do: "The editing agent notification failed."
  defp notification("uncertain"), do: "Delivery of the editing agent notification is uncertain."

  defp notification("attempted"),
    do: "A notification attempt was recorded; delivery is not confirmed."

  defp notification("not_applicable"), do: "Self edit; no agent notification was needed."
  defp notification(_), do: "The editing agent has not been notified yet."

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      data-role="clip-revision"
      class="space-y-4 rounded-xl border border-base-300 p-4"
    >
      <%= if @allowed? do %>
        <h3 :if={@state.can_request? or @state.can_upload?} class="font-semibold">Request a recut</h3>
        <p :if={@state.awaiting?} data-role="clip-edit-state" class="badge badge-warning">
          Awaiting edit
        </p>
        <p :if={@state.returned?} data-role="clip-edit-state" class="badge badge-info">
          Returned for review
        </p>
        <div :if={@state.request} class="space-y-1 text-sm">
          <p>
            {if @state.awaiting?, do: "Assigned to", else: "Editing request was assigned to"} {@state.request.assignee_name}
          </p>
          <p data-role="clip-edit-note-label" class="font-medium">
            {cond do
              @state.awaiting? -> "Editing note:"
              @state.returned? -> "Editing note for this version:"
              true -> "Previous editing note:"
            end}
          </p>
          <p data-role="clip-edit-latest-note" class="whitespace-pre-wrap">{@state.request.note}</p>
          <p data-role="clip-edit-notification" class="text-subtle">
            {notification(@state.request)}
          </p>
        </div>
        <p
          :if={@state.editor_blocked?}
          data-role="clip-edit-editor-blocked"
          class="text-sm text-warning"
        >
          The assigned editor no longer has access for this request. It remains awaiting edit.
        </p>
        <p :if={@error} data-role="clip-edit-error" role="alert" class="text-sm text-error">
          {@error}
        </p>
        <p :if={@notice} data-role="clip-edit-notice" role="status" class="text-sm font-medium">
          {@notice}
        </p>
        <p
          :if={@state.replaceable?}
          data-role="clip-edit-replacement-warning"
          class="text-sm text-warning"
        >
          The old notification may already have arrived or may still arrive. Replacing this request creates a new editing instruction;
          the earlier request cannot accept a returned version.
        </p>
        <.form
          :if={@state.can_request?}
          for={@form}
          id={"#{@id}-request-form"}
          phx-change="revision_change"
          phx-submit="revision_request"
          phx-target={@myself}
          class="space-y-3"
        >
          <.input field={@form[:request_id]} type="hidden" />
          <.input
            field={@form[:assignee]}
            type="select"
            label="Who will edit this clip?"
            prompt="Choose an editor"
            required
            options={
              [{"I'll edit it myself", "self"}] ++
                Enum.map(@state.agents, &{&1.name, "agent:#{&1.id}"})
            }
          />
          <.input field={@form[:note]} type="textarea" label="Editing instructions" maxlength="2000" />
          <button type="submit" class="btn btn-primary min-h-11" phx-disable-with="Saving request…">
            {if @state.replaceable?, do: "Replace editing request", else: "Request edit"}
          </button>
        </.form>
        <form
          :if={@state.can_upload?}
          id={"#{@id}-upload-form"}
          phx-change="revision_upload_change"
          phx-submit="revision_upload"
          phx-target={@myself}
          class="space-y-3"
        >
          <label for={@uploads.recut.ref} class="block text-sm font-medium">
            Upload the returned video
          </label>
          <.live_file_input upload={@uploads.recut} class="file-input w-full" />
          <div :for={entry <- @uploads.recut.entries} class="space-y-1 text-sm">
            <p>{entry.client_name} · {entry.progress}%</p>
            <button
              type="button"
              phx-click="revision_upload_cancel"
              phx-value-ref={entry.ref}
              phx-target={@myself}
              class="btn btn-ghost btn-sm"
            >
              Remove file
            </button>
            <p :for={_error <- upload_errors(@uploads.recut, entry)} role="alert" class="text-error">
              The video could not be uploaded. Check its type and size.
            </p>
          </div>
          <p :for={_error <- upload_errors(@uploads.recut)} role="alert" class="text-sm text-error">
            Choose one MP4, MOV or WebM within the upload size limit.
          </p>
          <p class="text-sm text-subtle">
            Returned media becomes a new version for review. The clip's title and caption stay as they are.
          </p>
          <button
            type="submit"
            class="btn btn-primary min-h-11"
            phx-disable-with="Saving returned video…"
          >
            Return edited video
          </button>
        </form>
        <details :if={@state.history != []} class="text-sm">
          <summary class="cursor-pointer font-medium">Editing request history</summary>
          <ol id={"#{@id}-history"} phx-update="stream" class="mt-3 space-y-3">
            <li
              :for={{dom_id, request} <- @streams.revision_history}
              id={dom_id}
              class="border-l-2 border-base-300 pl-3"
            >
              <p>
                {request.assignee_name} ·
                <time datetime={DateTime.to_iso8601(request.inserted_at)}>
                  {Calendar.strftime(request.inserted_at, "%d %b %Y, %H:%M UTC")}
                </time>
              </p>
              <p data-role="clip-edit-history-note" class="whitespace-pre-wrap">{request.note}</p>
              <p class="text-subtle">
                {if request.returned_render_id, do: "Returned", else: "Requested"} · {notification(
                  request
                )}
              </p>
            </li>
          </ol>
        </details>
      <% else %>
        <p class="text-sm text-subtle">Editing requests are unavailable with your current access.</p>
      <% end %>
    </section>
    """
  end
end
