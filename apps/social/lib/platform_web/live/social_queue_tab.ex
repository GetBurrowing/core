defmodule PlatformWeb.SocialQueueTab do
  @moduledoc """
  The Queue tab (extracted from `PlatformWeb.SocialLive` by Social authoring
  1/11, no behaviour change): the profile's needs_approval posts, each with
  its live approval card (`PlatformWeb.SocialCardComponent`, read only),
  then approved posts whose publish was refused before the vendor (task
  01a165f1), with the two status filter chips, and the cover picker (task
  01a165ec stage 4).

  All brands: the same rows across every visible profile, read through
  `Platform.Social.list_posts_for_profiles/3`. Cover controls are offered
  only for one brand, because the picker re-checks the approver on the
  CURRENT profile.

  Its events land on the parent LiveView (function components, not a
  LiveComponent), so every `phx-click` and `data-role` is what it was.
  """

  use PlatformWeb.SocialTab

  alias Phoenix.LiveView.JS
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Social
  alias Platform.Social.{Account, Approvals}
  alias PlatformWeb.SocialScope

  # The queue's status filter chips (task 01a165f1), in display order.
  @queue_filters ~w(needs_approval not_published)

  # An uploaded cover's size cap (task 01a165ec stage 4).
  @cover_max_bytes 15_000_000

  @events ~w(queue_filter cover_open cover_close cover_tab cover_frame cover_reset
             cover_upload_validate cover_upload_save)

  @impl true
  def enabled?, do: true

  @impl true
  def all_brands?, do: true

  @impl true
  def events, do: @events

  @impl true
  def tab_label(%{scope: :all, counts: counts}),
    do: "Queue (#{SocialScope.waiting_total(counts)})"

  def tab_label(%{counts: counts, profile: profile}),
    do: "Queue (#{SocialScope.count(counts, profile)})"

  @impl true
  def init(socket) do
    socket
    |> assign(:queue_canvas_ids, [])
    |> assign(:queue_filter, nil)
    |> assign(:cover_picker, nil)
    |> allow_upload(:cover,
      accept: ~w(.jpg .jpeg .png),
      max_entries: 1,
      max_file_size: @cover_max_bytes,
      auto_upload: true,
      progress: &__MODULE__.handle_cover_progress/3
    )
  end

  # The queue stream for the current scope and filter, with `reset: true`.
  # `queue_refused?` (any refused post, whatever the filter) shows the chips.
  @impl true
  def load(socket) do
    all = queue_rows(socket.assigns)
    rows = filter_queue(all, socket.assigns.queue_filter)
    canvas_ids = for %{card: %{canvas_id: id}} <- rows, do: id

    if connected?(socket) do
      Enum.each(socket.assigns.queue_canvas_ids -- canvas_ids, &ChatPubSub.unsubscribe_canvas/1)
      Enum.each(canvas_ids -- socket.assigns.queue_canvas_ids, &ChatPubSub.subscribe_canvas/1)
    end

    socket
    |> assign(:queue_canvas_ids, canvas_ids)
    |> assign(:queue_cards, Map.new(for %{card: %{} = c} <- rows, do: {c.canvas_id, c.id}))
    |> assign(:queue_empty?, rows == [])
    |> assign(:queue_refused?, Enum.any?(all, & &1.refused?))
    |> stream(:queue, rows, reset: true)
  end

  # Task 01a165f1: the queue's status filter. Pressing the active chip
  # clears it; the stream is re-read and re-streamed with `reset: true`.
  @impl true
  def handle_event("queue_filter", %{"filter" => filter}, socket)
      when filter in @queue_filters do
    filter = if socket.assigns.queue_filter == filter, do: nil, else: filter
    {:noreply, socket |> assign(:queue_filter, filter) |> load()}
  end

  # ── Cover picker (task 01a165ec stage 4) ─────────────────────────────
  #
  # A video post's cover, from the queue card's Cover control. Every write
  # goes through `Social.set_cover/4` (the approver and the one cover rule
  # are checked there, on a fresh read); the picker only stages. The frame
  # tab's `cover_frame` comes from the CoverPicker hook (integer ms); the
  # upload tab stores the image as a file of the profile's project as soon
  # as it arrives, and "Use this cover" applies it.

  def handle_event("cover_open", %{"post-id" => post_id}, socket) when is_binary(post_id),
    do: {:noreply, open_cover_picker(socket, post_id)}

  def handle_event("cover_close", _params, socket), do: {:noreply, close_cover_picker(socket)}

  def handle_event("cover_tab", %{"tab" => tab}, socket) when tab in ~w(frame upload),
    do: {:noreply, update_cover_picker(socket, &%{&1 | tab: tab, error: nil})}

  def handle_event("cover_frame", %{"post_id" => post_id, "offset_ms" => ms} = params, socket)
      when is_binary(post_id) and is_integer(ms) do
    attrs =
      case params["duration_ms"] do
        d when is_integer(d) and d > 0 -> %{cover_offset_ms: ms, duration_ms: d}
        _ -> %{cover_offset_ms: ms}
      end

    {:noreply, apply_cover(socket, post_id, attrs)}
  end

  def handle_event("cover_reset", _params, socket) do
    case socket.assigns.cover_picker do
      %{post_id: post_id} -> {:noreply, apply_cover(socket, post_id, :clear)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cover_upload_validate", _params, socket),
    do: {:noreply, update_cover_picker(socket, &%{&1 | error: nil})}

  def handle_event("cover_upload_save", _params, socket) do
    case socket.assigns.cover_picker do
      %{post_id: post_id, staged: %{file_id: file_id}} ->
        {:noreply, apply_cover(socket, post_id, %{cover_file_id: file_id})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A queued card's canvas changed (a decision here, in chat, or anywhere):
  # the card re-renders from `card_view/2` and the counts are re-read. The
  # row stays in the stream showing the card's decided status until the
  # next profile load.
  @impl true
  def handle_info({:canvas_updated, %{id: canvas_id} = canvas}, socket) do
    if canvas_id in socket.assigns.queue_canvas_ids do
      case Map.get(socket.assigns.queue_cards, canvas_id) do
        nil ->
          :ok

        card_id ->
          send_update(PlatformWeb.SocialCardComponent,
            id: "queue-card-" <> card_id,
            rev: rev_of(canvas.document)
          )
      end

      {:noreply, SocialScope.assign_profiles(socket, SocialScope.visible_profiles(socket))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, _socket), do: :unhandled

  defp filter_queue(rows, "needs_approval"), do: Enum.reject(rows, & &1.refused?)
  defp filter_queue(rows, "not_published"), do: Enum.filter(rows, & &1.refused?)
  defp filter_queue(rows, _none), do: rows

  # The profile's needs_approval posts, each with its live approval card
  # (read only) and that card's canvas revision. The rows carry no decision
  # state of their own: the embedded component asks `card_view/2`.
  #
  # Task 01a165f1: then its approved posts whose publish was refused before
  # the vendor (`refused: true`), each with its newest (decided) card.
  defp queue_rows(%{scope: :all, user: user}) do
    pending =
      user
      |> Social.list_posts_for_profiles(:all, status: "needs_approval")
      |> Enum.map(&queue_row(&1, Approvals.live_card(&1.id), false))

    refused =
      user
      |> Social.list_posts_for_profiles(:all, refused: true)
      |> Enum.map(&queue_row(&1, Approvals.latest_card(&1.id), true))

    pending ++ refused
  end

  defp queue_rows(%{profile: nil}), do: []

  defp queue_rows(%{profile: profile}) do
    pending =
      profile.org_id
      |> Social.list_posts(profile_id: profile.id, status: "needs_approval")
      |> Enum.map(&queue_row(&1, Approvals.live_card(&1.id), false))

    refused =
      profile.org_id
      |> Social.list_posts(profile_id: profile.id, refused: true)
      |> Enum.map(&queue_row(&1, Approvals.latest_card(&1.id), true))

    pending ++ refused
  end

  defp queue_row(post, card, refused?),
    do: %{id: post.id, post: post, card: card, rev: card && card_rev(card), refused?: refused?}

  defp card_rev(card) do
    case Platform.Chat.get_canvas(card.canvas_id) do
      %{document: document} -> rev_of(document)
      _ -> nil
    end
  end

  defp rev_of(%{"root" => %{"props" => %{"rev" => rev}}}) when is_integer(rev), do: rev
  defp rev_of(_), do: nil

  # ── Cover picker helpers (task 01a165ec stage 4) ─────────────────────

  # The picker opens only on a video post of the CURRENT profile that this
  # viewer may change; anything else is a no-op (the card shows no button).
  defp open_cover_picker(socket, post_id) do
    with {:ok, profile, user_id} <- authorize(socket),
         %Social.Post{} = post <- Social.get_post(profile.org_id, post_id),
         %Account{} = account <- profile_account(profile, post.account_id),
         %{} = card <- Approvals.live_card(post.id),
         %{cover: %{editable?: true} = cover, role: :approver} <-
           Approvals.card_view(card.id, {:user, user_id}) do
      socket
      |> cancel_cover_uploads()
      |> assign(:cover_picker, %{
        post_id: post.id,
        card_id: card.id,
        platform: account.platform,
        platform_label: Approvals.platform_label(account.platform),
        cover: cover,
        tab: if(cover.kind == :uploaded, do: "upload", else: "frame"),
        staged: nil,
        error: nil
      })
    else
      _ -> socket
    end
  end

  defp close_cover_picker(socket),
    do: socket |> cancel_cover_uploads() |> assign(:cover_picker, nil)

  defp update_cover_picker(%{assigns: %{cover_picker: %{} = picker}} = socket, fun),
    do: assign(socket, :cover_picker, fun.(picker))

  defp update_cover_picker(socket, _fun), do: socket

  defp cancel_cover_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.cover.entries, socket, fn entry, acc ->
      cancel_upload(acc, :cover, entry.ref)
    end)
  end

  # A refusal keeps the picker open with the reason under the control.
  defp apply_cover(socket, post_id, attrs) do
    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, post} <- Social.set_cover(profile.org_id, user_id, post_id, attrs) do
      case Approvals.live_card(post.id) do
        %{id: card_id} ->
          send_update(PlatformWeb.SocialCardComponent, id: "queue-card-" <> card_id)

        nil ->
          :ok
      end

      close_cover_picker(socket)
    else
      {:error, reason} -> update_cover_picker(socket, &%{&1 | error: cover_error_copy(reason)})
    end
  end

  defp cover_error_copy(%Ecto.Changeset{} = changeset) do
    Enum.find_value([:cover_file_id, :cover_offset_ms], "That cover can't be used.", fn field ->
      case Keyword.get_values(changeset.errors, field) do
        [{message, opts} | _] -> PlatformWeb.CoreComponents.translate_error({message, opts})
        [] -> nil
      end
    end)
  end

  defp cover_error_copy(:post_locked), do: "This post is past approval, so its cover is fixed."
  defp cover_error_copy(reason), do: PlatformWeb.SocialCardComponent.refusal_copy(reason)

  @doc false
  # An uploaded image is stored as soon as it arrives (a file of the
  # profile's project, through core's Files), then staged in the picker for
  # "Use this cover". Its pixel size says whether Instagram will crop it.
  def handle_cover_progress(:cover, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, store_cover_image(socket, path, entry)}
        end)

      case result do
        {:ok, staged} ->
          {:noreply, update_cover_picker(socket, &%{&1 | staged: staged, error: nil})}

        {:error, message} ->
          {:noreply, update_cover_picker(socket, &%{&1 | staged: nil, error: message})}
      end
    else
      {:noreply, socket}
    end
  end

  defp store_cover_image(socket, path, entry) do
    bytes = File.read!(path)
    content_type = cover_content_type(entry)

    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, project} <- Social.render_project(profile),
         {:ok, file} <- store_or_reuse(project, bytes, entry.client_name, content_type, user_id) do
      {:ok,
       %{
         file_id: file.id,
         name: entry.client_name,
         size: byte_size(bytes),
         nine_sixteen?: Platform.Social.CoverImage.nine_sixteen?(bytes)
       }}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "That image could not be stored. Try again."}
    end
  end

  # The same image uploaded again is the project's existing file: core's
  # Files keeps one row per content hash in a project, and only dedupes an
  # INGESTED sibling itself (a cover is stored without ingestion).
  defp store_or_reuse(project, bytes, name, content_type, user_id) do
    case Platform.Files.add_bytes(project, bytes, name, content_type,
           uploaded_by_user_id: user_id,
           ingest: false
         ) do
      {:ok, file, _deduplicated?} ->
        {:ok, file}

      {:error, %Ecto.Changeset{}} = error ->
        hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

        project.id
        |> Platform.Files.list_files_for_project(content_type: content_type, limit: nil)
        |> Enum.find(&(&1.content_hash == hash))
        |> case do
          nil -> error
          file -> {:ok, file}
        end

      error ->
        error
    end
  end

  defp cover_content_type(%{client_name: name}) do
    if name |> Path.extname() |> String.downcase() == ".png", do: "image/png", else: "image/jpeg"
  end

  # The upload's refusal, in the cover rule's own words where it has one.
  defp cover_upload_error(:not_accepted), do: Platform.Social.Cover.not_image_message()
  defp cover_upload_error(:too_large), do: "cover image must be under 15 MB"
  defp cover_upload_error(:too_many_files), do: "choose one image"
  defp cover_upload_error(_), do: "That image could not be uploaded."

  # A profile with no accounts can do nothing, so its empty queue points at
  # Connections.
  defp empty_queue_copy(:all, _profile, _accounts_empty?, "not_published"),
    do: "Every approved post in every brand went out."

  defp empty_queue_copy(:all, _profile, _accounts_empty?, _filter),
    do: "Nothing waiting for approval in any brand."

  defp empty_queue_copy(_scope, profile, _accounts_empty?, "not_published"),
    do: "Every approved post on #{profile.name} went out."

  defp empty_queue_copy(_scope, profile, true, _filter),
    do: "Nothing waiting for approval on #{profile.name}. Connect an account to start."

  defp empty_queue_copy(_scope, profile, _accounts_empty?, _filter),
    do: "Nothing waiting for approval on #{profile.name}."

  defp queue_filter_labels,
    do: [{"needs_approval", "Needs approval"}, {"not_published", "Not published"}]

  @impl true
  def pane(assigns) do
    ~H"""
    <div
      :if={@queue_refused? or @queue_filter}
      role="group"
      aria-label="Filter the queue"
      class="mb-3 flex flex-wrap gap-2"
      data-role="social-queue-filter"
    >
      <button
        :for={{key, label} <- queue_filter_labels()}
        type="button"
        phx-click="queue_filter"
        phx-value-filter={key}
        aria-pressed={to_string(@queue_filter == key)}
        data-role="social-queue-chip"
        data-filter={key}
        class={[
          "btn btn-sm rounded-full text-base-content",
          if(@queue_filter == key,
            do: "btn-active border-base-content",
            else: "btn-outline border-edge"
          )
        ]}
      >
        {label}
      </button>
    </div>
    <div :if={@queue_empty?} class="space-y-3">
      <p class="text-base-content/70" data-role="social-empty">
        {empty_queue_copy(@scope, @profile, @accounts_empty?, @queue_filter)}
      </p>
      <button
        :if={@scope != :all and @accounts_empty? and @queue_filter != "not_published"}
        type="button"
        class="btn btn-outline btn-sm"
        phx-click="select_tab"
        phx-value-tab="connections"
        data-role="social-go-connections"
      >
        Go to Connections
      </button>
    </div>
    <ul id="social-queue" phx-update="stream" class="space-y-3" data-role="social-queue">
      <li :for={{dom_id, row} <- @streams.queue} id={dom_id} data-role="social-queue-row">
        <%= if row.card do %>
          <.live_component
            module={PlatformWeb.SocialCardComponent}
            id={"queue-card-" <> row.card.id}
            card_id={row.card.id}
            rev={row.rev}
            canvas_id={row.card.canvas_id}
            viewer={{:user, @user.id}}
            cover_controls={@scope != :all}
          />
        <% else %>
          <p
            class="rounded-xl border border-base-300 bg-base-100 p-3 text-sm text-base-content/70"
            data-role="social-queue-waiting"
          >
            Waiting for its approval card.
          </p>
        <% end %>
      </li>
    </ul>
    <.cover_picker :if={@cover_picker} picker={@cover_picker} upload={@uploads.cover} />
    """
  end

  attr :picker, :map, required: true
  attr :upload, :any, required: true

  # The cover picker (task 01a165ec stage 4, design canvas 01a165ec-76e8):
  # a dialog from sm up, a bottom sheet below. Two neutral segmented tabs;
  # each tab has its own "Use this cover", the only primary on the surface.
  # The frame tab's scrubber is the CoverPicker hook's (phx-update=ignore):
  # it draws the filmstrip in the browser and pushes `cover_frame`.
  defp cover_picker(assigns) do
    ~H"""
    <div
      class="modal modal-open modal-bottom sm:modal-middle"
      role="dialog"
      aria-modal="true"
      aria-labelledby="social-cover-title"
      phx-window-keydown="cover_close"
      phx-key="escape"
      data-role="social-cover-picker"
      data-tab={@picker.tab}
    >
      <div class="modal-box max-h-[95vh] border border-base-300 bg-base-100 p-4 sm:max-w-md sm:p-5">
        <div class="mb-3 flex items-center justify-between gap-2">
          <h2 id="social-cover-title" class="text-lg font-semibold">Cover</h2>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="cover_close"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div
          role="tablist"
          aria-label="Cover source"
          class="mb-3 grid grid-cols-2 gap-1 rounded-lg border border-base-300 bg-base-200 p-1"
          data-role="social-cover-tabs"
        >
          <button
            :for={{key, label} <- [{"frame", "Pick a frame"}, {"upload", "Upload image"}]}
            type="button"
            role="tab"
            aria-selected={to_string(@picker.tab == key)}
            phx-click="cover_tab"
            phx-value-tab={key}
            data-role="social-cover-tab"
            data-tab={key}
            class={[
              "min-h-10 rounded-md px-3 text-[15px]",
              if(@picker.tab == key,
                do: "bg-base-100 font-medium text-base-content shadow-sm",
                else: "text-subtle"
              )
            ]}
          >
            {label}
          </button>
        </div>

        <%= if @picker.tab == "frame" do %>
          <div
            id={"social-cover-scrubber-#{@picker.post_id}"}
            phx-hook="CoverPicker"
            phx-update="ignore"
            data-role="social-cover-scrubber"
            data-post-id={@picker.post_id}
            data-src={@picker.cover.video_src}
            data-offset-ms={@picker.cover.offset_ms || 0}
            data-duration-ms={@picker.cover.duration_ms}
          >
            <.cover_well>
              <video
                data-cover-preview
                src={@picker.cover.video_src <> "#t=" <> seconds(@picker.cover.offset_ms || 0)}
                muted
                playsinline
                preload="metadata"
                class="absolute inset-0 h-full w-full object-contain"
              >
              </video>
            </.cover_well>
            <div
              data-cover-strip
              role="slider"
              tabindex="0"
              aria-label="Cover frame"
              aria-valuemin="0"
              aria-valuemax={(@picker.cover.duration_ms || 0) / 1000}
              aria-valuenow={(@picker.cover.offset_ms || 0) / 1000}
              aria-valuetext={timecode(@picker.cover.offset_ms || 0, @picker.cover.duration_ms)}
              class="relative mt-3 h-14 cursor-pointer touch-none select-none overflow-hidden rounded-md border border-base-300 bg-base-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
            >
              <div data-cover-frames class="flex h-full w-full"></div>
              <div
                data-cover-playhead
                aria-hidden="true"
                class="pointer-events-none absolute inset-y-0 left-0 w-10 -translate-x-1/2 rounded border-2 border-base-content"
              >
                <div class="absolute inset-y-0 left-1/2 w-0.5 -translate-x-1/2 bg-base-content"></div>
              </div>
            </div>
            <p
              data-cover-timecode
              data-role="social-cover-timecode"
              class="mt-2 text-center font-mono text-sm tabular-nums"
            >
              {timecode(@picker.cover.offset_ms || 0, @picker.cover.duration_ms)}
            </p>
          </div>
          <.cover_notes picker={@picker} />
          <div class="modal-action mt-3 items-center">
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="cover_reset"
              data-role="social-cover-reset"
            >
              Reset to first frame
            </button>
            <button
              type="button"
              class="btn btn-primary ml-auto"
              phx-click={
                JS.dispatch("cover:confirm", to: "#social-cover-scrubber-#{@picker.post_id}")
              }
              data-role="social-cover-use"
            >
              Use this cover
            </button>
          </div>
        <% else %>
          <form
            id="social-cover-upload"
            phx-change="cover_upload_validate"
            phx-submit="cover_upload_save"
            data-role="social-cover-upload"
          >
            <.cover_well>
              <img
                :if={@picker.staged}
                src={"/files/blob/#{@picker.staged.file_id}"}
                alt="Uploaded cover"
                class="absolute inset-0 h-full w-full object-contain"
                data-role="social-cover-staged"
              />
              <img
                :if={!@picker.staged and @picker.cover.kind == :uploaded}
                src={"/files/blob/#{@picker.cover.file_id}"}
                alt="Current cover"
                class="absolute inset-0 h-full w-full object-contain"
              />
              <label
                :if={!@picker.staged and @picker.cover.kind != :uploaded}
                for={@upload.ref}
                class="absolute inset-0 flex cursor-pointer flex-col items-center justify-center gap-2 text-[15px] text-subtle"
              >
                <.icon name="hero-photo" class="size-8" /> Choose a JPG or PNG
              </label>
            </.cover_well>
            <div class="mt-3 flex flex-wrap items-center gap-2">
              <.live_file_input
                upload={@upload}
                class="file-input file-input-sm w-full max-w-full"
              />
            </div>
            <p
              :if={@picker.staged}
              data-role="social-cover-file"
              class="mt-2 truncate text-[13px] text-subtle"
            >
              {@picker.staged.name} · {file_size(@picker.staged.size)}
            </p>
            <p
              :if={@picker.staged && !@picker.staged.nine_sixteen?}
              data-role="social-cover-crop-note"
              class="mt-1 text-[13px] text-subtle"
            >
              Instagram will crop this to 9:16
            </p>
            <p
              :for={
                err <-
                  upload_errors(@upload) ++
                    Enum.flat_map(@upload.entries, &upload_errors(@upload, &1))
              }
              data-role="social-cover-error"
              class="mt-2 text-sm text-error"
            >
              {cover_upload_error(err)}
            </p>
            <.cover_notes picker={@picker} />
            <div class="modal-action mt-3 items-center">
              <button
                type="button"
                class="btn btn-ghost"
                phx-click="cover_reset"
                data-role="social-cover-reset"
              >
                Reset to first frame
              </button>
              <button
                type="submit"
                class="btn btn-primary ml-auto"
                disabled={is_nil(@picker.staged)}
                data-role="social-cover-use"
              >
                Use this cover
              </button>
            </div>
          </form>
        <% end %>
      </div>
      <button type="button" class="modal-backdrop" phx-click="cover_close" aria-label="Close">
      </button>
    </div>
    """
  end

  slot :inner_block, required: true

  # The 9:16 preview well: the full frame, with the profile-grid crop (3:4,
  # so 12.5% top and bottom) drawn as a dimmed band. At most 60vh tall, and
  # shorter on a short screen so "Use this cover" stays in view.
  defp cover_well(assigns) do
    ~H"""
    <div
      data-role="social-cover-well"
      class="relative mx-auto aspect-[9/16] max-h-[min(60vh,100dvh_-_25rem)] w-full max-w-[min(100%,calc(min(60vh,100dvh_-_25rem)*9/16))] overflow-hidden rounded-lg bg-base-200"
    >
      {render_slot(@inner_block)}
      <div
        aria-hidden="true"
        data-role="social-cover-crop-guide"
        class="pointer-events-none absolute inset-x-0 top-0 h-[12.5%] bg-base-content/40"
      >
      </div>
      <div
        aria-hidden="true"
        class="pointer-events-none absolute inset-x-0 bottom-0 h-[12.5%] bg-base-content/40"
      >
      </div>
    </div>
    """
  end

  attr :picker, :map, required: true

  # The platform line, then a refusal under the control.
  defp cover_notes(assigns) do
    ~H"""
    <p data-role="social-cover-platform" class="mt-2 text-[13px] text-subtle">
      {cover_platform_line(@picker.platform, @picker.platform_label, @picker.tab)}
    </p>
    <p
      :if={@picker.error}
      role="alert"
      data-role="social-cover-error"
      class="mt-2 text-sm text-error"
    >
      {@picker.error}
    </p>
    """
  end

  defp cover_platform_line("instagram", _label, _tab), do: "Instagram uses this cover"
  defp cover_platform_line("youtube", _label, "frame"), do: "YouTube uses only an uploaded cover"
  defp cover_platform_line("youtube", _label, _tab), do: "YouTube uses this cover"
  defp cover_platform_line(_platform, label, _tab), do: "#{label} picks its own cover"

  # 7400 -> "7.4", 7000 -> "7": a media fragment's seconds.
  defp seconds(ms) when rem(ms, 1000) == 0, do: Integer.to_string(div(ms, 1000))
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, [:short])

  # "0:07.40 / 0:42" (the hook keeps it current while scrubbing).
  defp timecode(ms, duration_ms) do
    cs = div(ms, 10)
    s = div(cs, 100)

    head =
      "#{div(s, 60)}:#{pad2(rem(s, 60))}.#{pad2(rem(cs, 100))}"

    case duration_ms do
      d when is_integer(d) and d > 0 ->
        head <> " / " <> PlatformWeb.SocialCardComponent.clock_ms(d)

      _ ->
        head
    end
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp file_size(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp file_size(bytes) when bytes >= 1_000, do: "#{round(bytes / 1_000)} KB"
  defp file_size(bytes), do: "#{bytes} B"
end
