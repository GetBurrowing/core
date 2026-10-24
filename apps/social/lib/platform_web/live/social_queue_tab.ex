defmodule PlatformWeb.SocialQueueTab do
  @moduledoc """
  The Queue tab, "Needs you" (Social authoring 5/11, task 01a16c50): the
  home screen of Social.

    * One card per idea (`PlatformWeb.SocialIdeaCard`) for the scope's
      `needs_approval` posts, grouped by idea (a post with no idea is its
      own card) and sorted by the earliest suggested time
      (`Platform.Social.QueueFeed.needs_you/2`). Each card shows every
      account's real preview and offers approve (at the suggested time or
      into the next slot), edit, ask to revise, reject, and approve all.
    * Below the cards: a "N clips waiting in Clips" row (Clip approval
      stays in the Clips tab's Review bay), Scheduled in the next 7 days
      (grouped by idea), Failed and refused (each the existing approval card,
      `PlatformWeb.SocialCardComponent`, with its retry and reconnect
      actions), and Published in the last 24 hours with the link out.
    * Phone (< sm): one idea per screen with Previous / Next, swipe between
      versions, and the card's sticky bottom bar. `?tab=queue&idea=<id>`
      (what an approval inbox row and its push notification open, see
      `Platform.Social.Approvals.queue_url/2`) opens straight onto the idea.

  All brands: the same sections across every visible profile, each card
  naming its brand. Cover controls (task 01a165ec stage 4) are offered only
  for one brand, because the picker re-checks the approver on the CURRENT
  profile.

  Nothing auto-publishes: a human approves on a card and the platform
  publishes. Every click is re-checked server-side in the card.
  """

  use PlatformWeb.SocialTab

  alias Phoenix.LiveView.JS
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Social
  alias Platform.Social.{Account, Approvals, QueueFeed}
  alias PlatformWeb.{SocialIdeaCard, SocialPreview, SocialScope}

  # An uploaded cover's size cap (task 01a165ec stage 4).
  @cover_max_bytes 15_000_000

  @events ~w(queue_focus cover_open cover_close cover_tab cover_frame cover_reset
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
    |> assign(:queue_canvases, %{})
    |> assign(:queue_keys, [])
    |> assign(:queue_focus, nil)
    |> assign(:queue_deep_link, nil)
    |> assign(:queue_profiles, %{})
    |> assign(:queue_empty?, true)
    |> assign(:queue_post_count, 0)
    |> assign(:queue_scheduled_empty?, true)
    |> assign(:queue_failed_empty?, true)
    |> assign(:queue_published_empty?, true)
    |> assign(:queue_clips_waiting, 0)
    |> assign(:cover_picker, nil)
    |> Phoenix.LiveView.stream_configure(:queue, dom_id: &"queue-idea-#{&1.key}")
    |> Phoenix.LiveView.stream_configure(:queue_scheduled, dom_id: &"queue-scheduled-#{&1.key}")
    |> Phoenix.LiveView.stream_configure(:queue_failed, dom_id: &"queue-#{&1.id}")
    |> Phoenix.LiveView.stream_configure(:queue_published, dom_id: &"queue-published-#{&1.id}")
    |> allow_upload(:cover,
      accept: ~w(.jpg .jpeg .png),
      max_entries: 1,
      max_file_size: @cover_max_bytes,
      auto_upload: true,
      progress: &__MODULE__.handle_cover_progress/3
    )
  end

  # Every section for the current scope, re-read and re-streamed with
  # `reset: true`. The cards re-read their own posts on every update.
  @impl true
  def load(socket) do
    %{user: user, scope: scope} = socket.assigns
    scope = queue_scope(scope, socket.assigns[:profile])
    now = DateTime.utc_now()

    groups = QueueFeed.needs_you(user, scope)
    scheduled = QueueFeed.scheduled(user, scope, now)
    failed = QueueFeed.failed(user, scope, now)
    published = QueueFeed.published(user, scope, now)

    all_posts =
      Enum.flat_map(groups, & &1.posts) ++
        Enum.flat_map(scheduled, & &1.posts) ++ failed ++ published

    accounts = QueueFeed.accounts(all_posts)
    profiles = QueueFeed.profiles(accounts)

    keys = Enum.map(groups, & &1.key)

    focus =
      if socket.assigns.queue_focus in keys,
        do: socket.assigns.queue_focus,
        else: List.first(keys)

    idea_rows =
      Enum.map(groups, fn g -> %{key: g.key, group: g, focused?: g.key == focus} end)

    failed_rows =
      Enum.map(failed, fn post ->
        card = Approvals.latest_card(post.id)
        %{id: post.id, post: post, card: card, rev: card && card_rev(card)}
      end)

    canvases =
      Map.merge(
        Map.new(
          for g <- groups,
              post <- g.posts,
              %{canvas_id: canvas_id} <- [Approvals.live_card(post.id)],
              do: {canvas_id, {:idea, "queue-card-idea-" <> g.key}}
        ),
        Map.new(
          for %{card: %{canvas_id: canvas_id, id: card_id}} <- failed_rows,
              do: {canvas_id, {:card, "queue-card-" <> card_id}}
        )
      )

    canvas_ids = Map.keys(canvases)

    if connected?(socket) do
      Enum.each(socket.assigns.queue_canvas_ids -- canvas_ids, &ChatPubSub.unsubscribe_canvas/1)
      Enum.each(canvas_ids -- socket.assigns.queue_canvas_ids, &ChatPubSub.subscribe_canvas/1)
    end

    socket
    |> assign(:queue_canvas_ids, canvas_ids)
    |> assign(:queue_canvases, canvases)
    |> assign(:queue_keys, keys)
    |> assign(:queue_focus, focus)
    |> assign(:queue_profiles, profiles)
    |> assign(:queue_accounts, accounts)
    |> assign(:queue_empty?, groups == [])
    |> assign(:queue_post_count, groups |> Enum.map(&length(&1.posts)) |> Enum.sum())
    |> assign(:queue_scheduled_empty?, scheduled == [])
    |> assign(:queue_failed_empty?, failed == [])
    |> assign(:queue_published_empty?, published == [])
    |> assign(:queue_clips_waiting, QueueFeed.clips_waiting(user, scope))
    |> stream(:queue, idea_rows, reset: true)
    |> stream(:queue_scheduled, scheduled, reset: true)
    |> stream(:queue_failed, failed_rows, reset: true)
    |> stream(:queue_published, published, reset: true)
  end

  defp queue_scope(:all, _profile), do: :all
  defp queue_scope(_scope, profile), do: {:profile, profile}

  # Coming back to the Queue re-reads it, so a draft that arrived while
  # another tab was open is there.
  @impl true
  def on_select(%{assigns: %{tab: "queue"}} = socket), do: load(socket)
  def on_select(socket), do: socket

  # `?tab=queue&idea=<idea id, or a lone post's id>`: that idea is the one
  # on screen (the phone shows one idea at a time). An id that is not in
  # the queue changes nothing.
  @impl true
  def from_query(socket, %{"idea" => key}) when is_binary(key) do
    if key in socket.assigns.queue_keys do
      socket |> assign(:queue_focus, key) |> assign(:queue_deep_link, key) |> load()
    else
      socket
    end
  end

  def from_query(socket, _query), do: socket

  # Phone: Previous / Next idea, or a key.
  @impl true
  def handle_event("queue_focus", params, socket) do
    keys = socket.assigns.queue_keys
    index = Enum.find_index(keys, &(&1 == socket.assigns.queue_focus)) || 0

    key =
      case params do
        %{"dir" => "next"} -> Enum.at(keys, min(index + 1, length(keys) - 1))
        %{"dir" => "prev"} -> Enum.at(keys, max(index - 1, 0))
        %{"key" => key} -> if key in keys, do: key
        _ -> nil
      end

    if key && key != socket.assigns.queue_focus,
      do: {:noreply, socket |> assign(:queue_focus, key) |> load()},
      else: {:noreply, socket}
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
  # the owning idea card (or Failed row) re-reads, and the counts are
  # re-read. A decided version stays on its card, showing its decided
  # status, until the next load.
  @impl true
  def handle_info({:canvas_updated, %{id: canvas_id} = canvas}, socket) do
    case Map.get(socket.assigns.queue_canvases, canvas_id) do
      nil ->
        if canvas_id in socket.assigns.queue_canvas_ids,
          do: {:noreply, socket},
          else: :unhandled

      {:idea, component_id} ->
        send_update(SocialIdeaCard, id: component_id, rev: rev_of(canvas.document))
        {:noreply, SocialScope.assign_profiles(socket, SocialScope.visible_profiles(socket))}

      {:card, component_id} ->
        send_update(PlatformWeb.SocialCardComponent,
          id: component_id,
          rev: rev_of(canvas.document)
        )

        {:noreply, SocialScope.assign_profiles(socket, SocialScope.visible_profiles(socket))}
    end
  end

  def handle_info(_message, _socket), do: :unhandled

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
      with %{canvas_id: canvas_id} <- Approvals.live_card(post.id),
           {:idea, component_id} <- Map.get(socket.assigns.queue_canvases, canvas_id) do
        send_update(SocialIdeaCard, id: component_id)
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

  # ── Pane ─────────────────────────────────────────────────────────────

  @impl true
  def pane(assigns) do
    assigns =
      assign(assigns,
        focus_index: Enum.find_index(assigns.queue_keys, &(&1 == assigns.queue_focus)) || 0,
        connect?: assigns.scope != :all and assigns[:accounts_empty?] == true
      )

    ~H"""
    <div data-role="social-queue-pane" class="mx-auto w-full max-w-6xl space-y-8 pb-56 sm:pb-8">
      <section aria-labelledby="queue-needs-you" class="space-y-3">
        <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <h2 id="queue-needs-you" class="text-xl font-semibold" data-role="queue-heading">
            Needs you
          </h2>
          <span
            :if={not @queue_empty?}
            class="text-sm text-base-content/70"
            data-role="queue-summary"
          >
            {plural(length(@queue_keys), "idea")} · {plural(@queue_post_count, "post")}
          </span>
        </div>

        <nav
          :if={length(@queue_keys) > 1}
          aria-label="Ideas"
          data-role="queue-idea-nav"
          class="flex items-center justify-between gap-2 sm:hidden"
        >
          <button
            type="button"
            phx-click="queue_focus"
            phx-value-dir="prev"
            disabled={@focus_index == 0}
            data-role="queue-prev-idea"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-chevron-left-mini" class="size-4" /> Previous
          </button>
          <span class="text-sm font-medium tabular-nums" data-role="queue-idea-position">
            Idea {@focus_index + 1} of {length(@queue_keys)}
          </span>
          <button
            type="button"
            phx-click="queue_focus"
            phx-value-dir="next"
            disabled={@focus_index >= length(@queue_keys) - 1}
            data-role="queue-next-idea"
            class="btn btn-ghost btn-sm"
          >
            Next <.icon name="hero-chevron-right-mini" class="size-4" />
          </button>
        </nav>

        <div
          :if={@queue_empty?}
          data-role="social-empty"
          class="rounded-2xl border border-dashed border-edge px-4 py-8 text-center"
        >
          <%= if @connect? do %>
            <p class="font-medium">Connect an account to start.</p>
            <p class="mt-1 text-sm text-base-content/70">
              Agents draft posts for {@profile.name} once it has somewhere to post.
            </p>
            <button
              type="button"
              class="btn btn-primary btn-sm mt-4"
              phx-click="select_tab"
              phx-value-tab="connections"
              data-role="social-go-connections"
            >
              Go to Connections
            </button>
          <% else %>
            <.icon name="hero-check-circle" class="mx-auto size-8 text-success" />
            <p class="mt-2 text-lg font-medium">Nothing needs you.</p>
            <p class="mt-1 text-sm text-base-content/70">
              {if @scope == :all,
                do: "Every brand is caught up.",
                else: "#{@profile && @profile.name} is caught up."}
            </p>
          <% end %>
        </div>

        <ul id="social-queue" phx-update="stream" class="space-y-4" data-role="social-queue">
          <li
            :for={{dom_id, row} <- @streams.queue}
            id={dom_id}
            data-role="social-queue-row"
            class={[not row.focused? && "max-sm:hidden"]}
          >
            <.live_component
              module={SocialIdeaCard}
              id={"queue-card-idea-" <> row.key}
              group={row.group}
              viewer={{:user, @user.id}}
              profiles={@queue_profiles}
              show_brand?={@scope == :all}
              focused?={row.focused?}
              deep_link?={@queue_deep_link == row.key}
              cover_controls={@scope != :all}
            />
          </li>
        </ul>
      </section>

      <button
        :if={@queue_clips_waiting > 0}
        type="button"
        phx-click="select_tab"
        phx-value-tab="clips"
        data-role="queue-clips-waiting"
        data-href="?tab=clips"
        class="flex w-full items-center gap-3 rounded-xl border border-edge bg-base-100 px-4 py-3 text-left hover:bg-base-200"
      >
        <.icon name="hero-film" class="size-5 shrink-0 text-base-content/70" />
        <span class="flex-1 text-sm font-medium">
          {plural(@queue_clips_waiting, "clip")} waiting in Clips
        </span>
        <.icon name="hero-chevron-right-mini" class="size-4 text-base-content/70" />
      </button>

      <section aria-labelledby="queue-scheduled" class="space-y-2" data-role="queue-scheduled">
        <h2 id="queue-scheduled" class="text-base font-semibold">Scheduled · next 7 days</h2>
        <p :if={@queue_scheduled_empty?} class="text-sm text-base-content/70">
          Nothing scheduled in the next 7 days.
        </p>
        <ul
          id="social-queue-scheduled"
          phx-update="stream"
          class="divide-y divide-edge overflow-hidden rounded-xl border border-edge bg-base-100"
        >
          <li
            :for={{dom_id, g} <- @streams.queue_scheduled}
            id={dom_id}
            data-role="queue-scheduled-row"
            class="space-y-1.5 px-4 py-3"
          >
            <p class="text-sm font-medium">{group_title(g, @queue_accounts)}</p>
            <ul class="flex flex-wrap gap-x-4 gap-y-1">
              <li
                :for={p <- g.posts}
                data-role="queue-scheduled-post"
                class="flex items-center gap-1.5 text-[13px] text-base-content/70"
              >
                <SocialPreview.glyph
                  platform={account_platform(@queue_accounts, p)}
                  class="size-3.5 shrink-0"
                />
                <span>{account_handle(@queue_accounts, p)}</span>
                <span class="font-mono tabular-nums text-base-content">
                  {SocialIdeaCard.when_text(
                    p.scheduled_at,
                    post_tz(p, @queue_accounts, @queue_profiles)
                  )}
                </span>
              </li>
            </ul>
          </li>
        </ul>
      </section>

      <section
        :if={not @queue_failed_empty?}
        aria-labelledby="queue-failed"
        class="space-y-2"
        data-role="queue-failed"
      >
        <h2 id="queue-failed" class="text-base font-semibold">Failed and refused</h2>
        <ul id="social-queue-failed" phx-update="stream" class="space-y-3">
          <li :for={{dom_id, row} <- @streams.queue_failed} id={dom_id} data-role="queue-failed-row">
            <%= if row.card do %>
              <.live_component
                module={PlatformWeb.SocialCardComponent}
                id={"queue-card-" <> row.card.id}
                card_id={row.card.id}
                rev={row.rev}
                canvas_id={row.card.canvas_id}
                viewer={{:user, @user.id}}
                cover_controls={false}
              />
            <% else %>
              <p class="rounded-xl border border-edge bg-base-100 p-3 text-sm text-base-content/70">
                {account_label(@queue_accounts, row.post)}: {row.post.error || "did not publish."}
              </p>
            <% end %>
          </li>
        </ul>
      </section>

      <section
        :if={not @queue_published_empty?}
        aria-labelledby="queue-published"
        class="space-y-2"
        data-role="queue-published"
      >
        <h2 id="queue-published" class="text-base font-semibold">Published · last 24 hours</h2>
        <ul
          id="social-queue-published"
          phx-update="stream"
          class="divide-y divide-edge overflow-hidden rounded-xl border border-edge bg-base-100"
        >
          <li
            :for={{dom_id, p} <- @streams.queue_published}
            id={dom_id}
            data-role="queue-published-row"
            class="flex items-center gap-2 px-4 py-3 text-sm"
          >
            <SocialPreview.glyph
              platform={account_platform(@queue_accounts, p)}
              class="size-4 shrink-0"
            />
            <span class="min-w-0 flex-1 truncate">
              <span class="font-medium">{account_label(@queue_accounts, p)}</span>
              <span class="text-base-content/70">
                · {SocialIdeaCard.clock(
                  QueueFeed.published_at(p),
                  post_tz(p, @queue_accounts, @queue_profiles)
                )}
              </span>
            </span>
            <a
              :if={p.external_url}
              href={p.external_url}
              target="_blank"
              rel="noopener noreferrer"
              data-role="queue-published-link"
              class="link shrink-0 text-sm"
            >
              View post <.icon name="hero-arrow-top-right-on-square-mini" class="size-3.5" />
            </a>
          </li>
        </ul>
      </section>
    </div>
    <.cover_picker :if={@cover_picker} picker={@cover_picker} upload={@uploads.cover} />
    """
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  defp group_title(%{idea: %{title: title}}, _accounts) when is_binary(title), do: title

  defp group_title(%{posts: [p | _]}, accounts),
    do: "#{Approvals.platform_label(account_platform(accounts, p))} post"

  defp account_platform(accounts, %{account_id: id}),
    do: (Map.get(accounts, id) || %{platform: nil}).platform

  defp account_handle(accounts, %{account_id: id}) do
    case Map.get(accounts, id) do
      %Account{handle: h} when is_binary(h) -> h
      %Account{platform: p} -> Approvals.platform_label(p)
      _ -> ""
    end
  end

  defp account_label(accounts, post) do
    label = Approvals.platform_label(account_platform(accounts, post))

    case account_handle(accounts, post) do
      ^label -> label
      handle -> "#{label} #{handle}"
    end
  end

  defp post_tz(post, accounts, profiles) do
    with %Account{profile_id: pid} <- Map.get(accounts, post.account_id) do
      SocialIdeaCard.profile_tz(Map.get(profiles, pid))
    else
      _ -> "Etc/UTC"
    end
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
