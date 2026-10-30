defmodule PlatformWeb.SocialClipsReview do
  @moduledoc """
  The Clips tab's Review bay (Clip Studio 3/9, task 01a16662-8c00), a
  LiveComponent mounted by `PlatformWeb.SocialLive` in its clips pane.

  Assigns from the parent: `profile`, `user_id`, `view` ("review" or
  "library", already parsed from the URL), `clip_id` (a UUID from the URL
  or nil). The parent also forwards each clips-topic broadcast as
  `clip_event: %Clip{}` through `send_update/3`; the queue is then re-read.

  `update/2` loads the queue and the open render jobs through
  `Platform.Social.ClipReviewFeed`, selects the URL's clip when
  `ClipReviewFeed.fetch_clip/3` accepts it AND it is in the queue (else the
  first pending clip), and computes `can_decide?` from
  `Platform.Social.approver_check/3` on the re-read profile. `can_decide?`
  drives rendering only.

  Every `handle_event/3` re-runs that check first (`authorize/1`): it
  re-reads the user (`Platform.Accounts.get_user/1`) and the profile
  (`Platform.Social.get_profile/2`) and calls `approver_check/3`. A write
  event (`save_title`, `save_caption`, `toggle_platform`) refuses with no
  write when it fails; a read event (`pick`, `prev`, `next`, `set_view`,
  `edit_title`, `note`) recomputes `can_decide?` from it, so decision
  controls vanish the moment an approver is removed.

  Stage 3 wires the decisions to `Platform.Social.ClipDecisions`:
  "approve" (the clip's ticked platforms, resolved to THIS profile's live
  accounts, never ids from params), "reject" (a trimmed, non-blank note)
  and "undo". Each re-runs the approver check first and writes nothing when
  it fails; `ClipDecisions` checks again inside. The undo window is
  `ClipPublish`'s server-side job: the toast's deadline comes from its
  return value and the component only schedules `send_update_after/4` to
  drop the toast, never to commit or publish. A clips-topic event inserts a
  newly pending clip ("New clip in Review"), removes one decided elsewhere
  and re-reads the render queue; while jobs are open the component
  re-reads them every 5s.

  Stage 2 renders the desktop bay, a port of prototype
  01a16628-8d70 v2 `socialHTML` (subhead), `queueHTML`, `reviewHTML` and
  `detailsHTML` (canvas 01a1660d-1de2 node c1i): the queue rail with the
  render queue, the 9:16 player (core's `ChatClip` hook), the details rail
  and the empty state. Approve and Reject render with their enabled states;
  stage 3 wires them. Edit look, Trim, the Cover row, the re-render
  box, the on-frame title and "New clip from episode" are not rendered.

  Stage 4 adds the `ClipReview` hook root (`#social-clips-review-keys`:
  J/K push "next"/"prev", Space plays/pauses, scrubber and toast counter,
  `clips:url` → history.replaceState; it never decides) and the phone
  layout from the prototype's `@media (max-width:760px)` block as
  `max-[760px]:` variants: Up next beside the player, platform chips in
  place of the switch rows, and the bottom bar (`.pbar`, approvers only)
  firing the same approve/reject events.
  """
  use PlatformWeb, :live_component

  import PlatformWeb.SocialClipsReviewActions, only: [pbar: 1, decision_bar: 1]

  alias Platform.Social

  alias Platform.Social.{
    Approvals,
    Clip,
    ClipDecisions,
    ClipPublish,
    ClipReviewFeed,
    ClipJobs,
    ClipVersions,
    ClipClosingVideo,
    Profile
  }

  @views ~w(review library)
  @info_toast_ms 3_200
  @landed_ms 3_000
  @jobs_refresh_ms 5_000
  @toast_grace_ms 250

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       queue: [],
       jobs: [],
       episode_jobs: [],
       accounts: [],
       clip: nil,
       byline: %{source_label: nil, agent_name: nil},
       can_decide?: false,
       view: "review",
       clip_id: nil,
       selected_id: nil,
       editing_title?: false,
       note: "",
       toast: nil,
       landed: MapSet.new(),
       selected_render: nil,
       selected_version_id: nil,
       versions: [],
       closing_filter: nil,
       closing_error: nil,
       closing_attempt: nil,
       closing_change?: false,
       headline_attempt: nil,
       headline_error: nil,
       appearance_dirty: false,
       jobs_timer?: false
     )}
  end

  @impl true
  def update(%{clip_event: %Clip{} = clip}, socket),
    do: {:ok, socket |> clip_event(clip) |> schedule_jobs_refresh()}

  def update(%{appearance_clip_id: id, appearance_dirty: dirty}, socket) do
    {:ok,
     if(socket.assigns.clip && socket.assigns.clip.id == id,
       do: assign(socket, :appearance_dirty, dirty),
       else: socket
     )}
  end

  # Timers this component scheduled for itself with send_update_after/4.
  # None of them decides, commits or publishes anything.
  def update(%{toast_expire: token}, socket) do
    case socket.assigns.toast do
      %{token: ^token} -> {:ok, assign(socket, :toast, nil)}
      _ -> {:ok, socket}
    end
  end

  def update(%{landed_expire: clip_id}, socket),
    do: {:ok, assign(socket, :landed, MapSet.delete(socket.assigns.landed, clip_id))}

  def update(%{job_event: true}, socket),
    do: {:ok, socket |> refresh_job_state() |> schedule_jobs_refresh()}

  def update(%{refresh_jobs: true}, socket) do
    {:ok, socket |> assign(:jobs_timer?, false) |> refresh_job_state() |> schedule_jobs_refresh()}
  end

  def update(assigns, socket) do
    # The URL's clip seeds the selection once (and again only if the URL
    # param itself changes); a parent re-render never undoes a pick.
    url_changed? = Map.get(assigns, :clip_id) != socket.assigns.clip_id

    socket =
      socket
      |> assign(Map.take(assigns, [:id, :profile, :user_id, :view, :clip_id, :closing_filter]))
      |> then(fn s ->
        if url_changed? or s.assigns.selected_id == nil,
          do: assign(s, :selected_id, s.assigns.clip_id),
          else: s
      end)
      |> load()
      |> schedule_jobs_refresh()

    {:ok, socket}
  end

  defp refresh_job_state(socket) do
    previous = MapSet.new(socket.assigns.queue, & &1.id)
    socket = load(socket)

    # A job's completion broadcast may arrive before its clip broadcast. Keep
    # the existing "New clip in Review" notification when polling loads it first.
    case Enum.find(socket.assigns.queue, &(not MapSet.member?(previous, &1.id))) do
      %Clip{} = clip -> landed(socket, socket.assigns.profile, clip)
      _ -> socket
    end
  end

  # ── Events ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) when view in @views do
    socket = authorize(socket)
    send(self(), {:clips_view, view})

    {:noreply,
     socket
     |> assign(:view, view)
     |> push_event("clips:url", url_params(view, socket.assigns.clip))}
  end

  def handle_event("set_view", _params, socket), do: {:noreply, authorize(socket)}

  def handle_event("pick", %{"id" => id}, socket) do
    socket = authorize(socket)
    %{profile: profile} = socket.assigns

    case ClipReviewFeed.fetch_clip(profile.org_id, profile.id, id) do
      {:ok, %Clip{} = clip} ->
        if reviewable?(clip) and Enum.any?(socket.assigns.queue, &(&1.id == clip.id)),
          do: {:noreply, select_clip(socket, clip)},
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("pick", _params, socket), do: {:noreply, authorize(socket)}

  def handle_event("prev", _params, socket), do: {:noreply, socket |> authorize() |> step(-1)}
  def handle_event("next", _params, socket), do: {:noreply, socket |> authorize() |> step(1)}

  def handle_event("edit_title", _params, socket) do
    socket = authorize(socket)

    {:noreply,
     assign(socket, :editing_title?, socket.assigns.can_decide? and socket.assigns.clip != nil)}
  end

  def handle_event("cancel_title", _params, socket),
    do: {:noreply, socket |> authorize() |> assign(:editing_title?, false)}

  def handle_event("save_title", params, socket) do
    title = params["title"] || params["value"]

    socket
    |> authorize()
    |> save(%{"title" => title})
    |> then(&{:noreply, assign(&1, :editing_title?, false)})
  end

  def handle_event("pick_version", %{"render_id" => id}, socket) do
    socket = authorize(socket)
    %{profile: p, clip: clip} = socket.assigns

    with %Clip{} <- clip, {:ok, version} <- ClipVersions.get(p.org_id, p.id, clip.id, id) do
      {:noreply,
       socket
       |> assign(
         selected_version_id: if(version.rev == clip.rev, do: nil, else: id),
         closing_error: nil
       )
       |> headline_state()
       |> authorize()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("pick_version", _params, socket), do: {:noreply, authorize(socket)}

  def handle_event("use_closing_video", params, socket) do
    socket = authorize(socket)
    %{profile: p, clip: clip, selected_render: selected} = socket.assigns

    if socket.assigns.can_decide? and not is_nil(clip) and not is_nil(selected) and
         selected.rev == clip.rev and params["base_render_id"] == selected.id do
      case ClipJobs.enqueue_closing_video(p.org_id, clip.id, socket.assigns.user_id, %{
             "base_render_id" => params["base_render_id"]
           }) do
        {:ok, job} ->
          {:noreply,
           socket
           |> assign(closing_error: nil, closing_attempt: job)
           |> load()
           |> schedule_jobs_refresh()}

        {:error, reason} ->
          {:noreply, assign(socket, :closing_error, closing_message(reason))}
      end
    else
      {:noreply, assign(socket, :closing_error, closing_message(:stale_version))}
    end
  end

  def handle_event("rerender_headline", params, socket) do
    socket = authorize(socket)

    if socket.assigns.can_decide? and socket.assigns.clip do
      %{profile: profile, clip: clip, user_id: user_id} = socket.assigns

      # Never replace the browser's base with the newest version: stale forms must fail.
      case ClipJobs.enqueue_fix(profile.org_id, clip.id, user_id, %{
             "base_render_id" => params["base_render_id"],
             "operation" => "edit_headline",
             "headline" => params["headline"]
           }) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> assign(:headline_error, nil)
           |> headline_state()
           |> load()
           |> schedule_jobs_refresh()}

        {:error, reason} ->
          {:noreply, assign(socket, :headline_error, headline_message(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_caption", params, socket) do
    caption = params["caption"] || params["value"]
    {:noreply, socket |> authorize() |> save(%{"caption" => caption})}
  end

  def handle_event("toggle_platform", %{"platform" => platform}, socket) do
    socket = authorize(socket)

    case socket.assigns.clip do
      %Clip{platforms: current} ->
        current = current || []

        next =
          if platform in current,
            do: List.delete(current, platform),
            else: current ++ [platform]

        {:noreply, save(socket, %{"platforms" => next})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("note", params, socket) do
    socket = authorize(socket)
    note = params["note"] || params["value"] || ""
    {:noreply, assign(socket, :note, String.slice(note, 0, 2000))}
  end

  # ── Decisions ────────────────────────────────────────────────────────

  # approver check → fetch_clip → the clip's ticked platforms resolved to
  # this profile's live accounts (params never name an account) →
  # ClipDecisions.approve_clip/5. An empty selection writes nothing.
  def handle_event("approve", %{"id" => id, "render_id" => render_id}, socket) do
    socket = authorize(socket)

    with true <- socket.assigns.can_decide? and not socket.assigns.appearance_dirty,
         %{profile: profile, user_id: user_id} = socket.assigns,
         {:ok, %Clip{} = clip} <- ClipReviewFeed.fetch_clip(profile.org_id, profile.id, id),
         [_ | _] = accounts <- ticked_accounts(profile, clip),
         {:ok, %{clip: decided, posts: posts}} <-
           ClipDecisions.approve_clip(profile.org_id, clip.id, user_id, %{
             "account_ids" => Enum.map(accounts, & &1.id),
             "render_id" => render_id
           }) do
      platforms = accounts |> Enum.map(& &1.platform) |> Enum.uniq()
      until = posts |> Enum.map(& &1.publish_after) |> Enum.reject(&is_nil/1) |> deadline()

      {:noreply,
       socket
       |> drop_clip(decided.id)
       |> put_toast(%{
         kind: :approved,
         clip_id: decided.id,
         render_id: decided.reviewed_render_id,
         lead: "Approved",
         text:
           "publishing to #{platforms |> Enum.map(&Approvals.platform_label/1) |> join_and()}",
         until: until
       })}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("approve", _params, socket), do: {:noreply, authorize(socket)}

  # approver check → a trimmed, non-blank note → ClipDecisions.reject_clip/5.
  def handle_event("reject", %{"id" => id} = params, socket) do
    socket = authorize(socket)
    note = params |> Map.get("note", socket.assigns.note) |> to_string() |> String.trim()

    with true <- socket.assigns.can_decide?,
         false <- note == "",
         %{profile: profile, user_id: user_id} = socket.assigns,
         {:ok, %Clip{} = clip} <- ClipReviewFeed.fetch_clip(profile.org_id, profile.id, id),
         {:ok, %Clip{} = decided} <-
           ClipDecisions.reject_clip(profile.org_id, clip.id, user_id, note) do
      byline = ClipReviewFeed.byline(profile.org_id, decided)
      reader = byline.agent_name || byline.source_label || "The clip tool"

      until =
        deadline([
          DateTime.add(decided.reviewed_at, ClipPublish.window_ms(), :millisecond)
        ])

      {:noreply,
       socket
       |> drop_clip(decided.id)
       |> put_toast(%{
         kind: :rejected,
         clip_id: decided.id,
         lead: "Rejected",
         text: "#{reader} gets your note",
         until: until
       })}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reject", _params, socket), do: {:noreply, authorize(socket)}

  # approver check → ClipDecisions.undo_clip_decision/4. A closed window (or
  # any refusal) just closes the toast; nothing else changes.
  def handle_event("undo", %{"id" => id} = params, socket) do
    socket = authorize(socket)
    %{profile: profile, user_id: user_id} = socket.assigns

    if socket.assigns.can_decide? do
      opts = if params["render_id"], do: [render_id: params["render_id"]], else: []

      case ClipDecisions.undo_clip_decision(profile.org_id, id, user_id, opts) do
        {:ok, %Clip{} = clip} ->
          socket =
            socket
            |> assign(:selected_id, clip.id)
            |> load()
            |> then(fn s ->
              if s.assigns.clip, do: select_clip(s, s.assigns.clip), else: s
            end)

          {:noreply,
           put_toast(socket, %{
             kind: :info,
             clip_id: clip.id,
             lead: nil,
             text: "Restored “#{clip.title || "Untitled clip"}” to review",
             until: now_ms() + @info_toast_ms
           })}

        {:error, _} ->
          {:noreply, assign(socket, :toast, nil)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("undo", _params, socket), do: {:noreply, authorize(socket)}

  def handle_event("dismiss_toast", _params, socket),
    do: {:noreply, socket |> authorize() |> assign(:toast, nil)}

  # The clip's ticked platforms (`ticked/2`) mapped onto the profile's live
  # accounts, re-read now. Never from params.
  defp ticked_accounts(%Profile{} = profile, %Clip{} = clip) do
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)
    platforms = ticked(accounts, clip)
    Enum.filter(accounts, &(&1.platform in platforms))
  end

  # Removes a clip from the list. If it was selected, the clip now at the
  # same index is selected, else the previous one, else the empty state.
  defp drop_clip(socket, clip_id) do
    %{queue: queue, clip: selected} = socket.assigns

    case Enum.find_index(queue, &(&1.id == clip_id)) do
      nil ->
        socket

      i ->
        rest = List.delete_at(queue, i)
        socket = assign(socket, :queue, rest)

        if selected && selected.id == clip_id do
          case Enum.at(rest, min(i, length(rest) - 1)) do
            %Clip{} = next when rest != [] ->
              select_clip(socket, next) |> push_event("clips:focus", %{clip: next.id})

            _ ->
              socket
              |> assign(clip: nil, selected_id: nil, editing_title?: false, note: "")
              |> assign(:byline, %{source_label: nil, agent_name: nil})
              |> push_event("clips:url", url_params(socket.assigns.view, nil))
          end
        else
          socket
        end
    end
  end

  # One toast at a time: a new one replaces the last. The component only
  # drops it after `until` (+250ms); the decision's window is ClipPublish's.
  defp put_toast(socket, toast) do
    token = System.unique_integer([:positive])
    toast = Map.put(toast, :token, token)
    ms = max(toast.until - now_ms(), 0) + @toast_grace_ms

    send_update_after(self(), __MODULE__, %{id: socket.assigns.id, toast_expire: token}, ms)
    assign(socket, :toast, toast)
  end

  defp deadline([]), do: now_ms() + ClipPublish.window_ms()

  defp deadline(times),
    do: times |> Enum.map(&DateTime.to_unix(&1, :millisecond)) |> Enum.min()

  defp now_ms, do: System.system_time(:millisecond)

  # ── Live: clips-topic events forwarded by the parent ─────────────────

  defp clip_event(%{assigns: %{closing_filter: "previous"}} = socket, %Clip{}), do: load(socket)

  defp clip_event(%{assigns: %{profile: %Profile{} = profile}} = socket, %Clip{} = clip) do
    in_list? = Enum.any?(socket.assigns.queue, &(&1.id == clip.id))
    waiting? = clip.profile_id == profile.id and reviewable?(clip)

    socket =
      cond do
        waiting? and not in_list? -> landed(socket, profile, clip)
        in_list? and not waiting? -> drop_clip(socket, clip.id)
        in_list? -> replace_clip(socket, clip)
        true -> socket
      end

    socket
    |> assign(:jobs, ClipReviewFeed.rendering(profile.org_id, profile.id))
    |> assign(:episode_jobs, ClipReviewFeed.episode_jobs(profile.org_id, profile.id))
  end

  defp clip_event(socket, _clip), do: socket

  # A newly pending clip goes into the list in queue order (re-read), with
  # the "New clip in Review" toast and a 3s highlight on its queue item.
  defp landed(socket, profile, %Clip{} = clip) do
    queue = review_queue(profile, socket.assigns.closing_filter)

    if Enum.any?(queue, &(&1.id == clip.id)) do
      clip = Enum.find(queue, &(&1.id == clip.id))

      send_update_after(
        self(),
        __MODULE__,
        %{id: socket.assigns.id, landed_expire: clip.id},
        @landed_ms
      )

      socket =
        socket
        |> assign(:queue, queue)
        |> assign(:landed, MapSet.put(socket.assigns.landed, clip.id))

      socket =
        if socket.assigns.clip, do: socket, else: select_clip(socket, clip)

      put_toast(socket, %{
        kind: :info,
        clip_id: clip.id,
        lead: "New clip in Review",
        text: clip.title || "Untitled clip",
        until: now_ms() + @info_toast_ms
      })
    else
      socket
    end
  end

  defp replace_clip(socket, %Clip{} = clip) do
    queue = Enum.map(socket.assigns.queue, &if(&1.id == clip.id, do: clip, else: &1))
    socket = assign(socket, :queue, queue)

    if socket.assigns.clip && socket.assigns.clip.id == clip.id,
      do: socket |> assign(:clip, clip) |> headline_state(),
      else: socket
  end

  # Broadcasts deliver new jobs even from an initially empty bay. Poll only
  # while work remains open, as a fallback after missed notifications.
  defp schedule_jobs_refresh(%{assigns: %{jobs_timer?: false}} = socket) do
    open? =
      socket.assigns.jobs != [] or
        Enum.any?(socket.assigns.episode_jobs, fn job ->
          job.status in ["queued", "claimed", "running"] or
            Enum.any?(job.children, &(&1.status in ["queued", "claimed", "running"]))
        end)

    if open?, do: schedule_job_timer(socket), else: socket
  end

  defp schedule_jobs_refresh(socket), do: socket

  defp schedule_job_timer(socket) do
    send_update_after(
      self(),
      __MODULE__,
      %{id: socket.assigns.id, refresh_jobs: true},
      @jobs_refresh_ms
    )

    assign(socket, :jobs_timer?, true)
  end

  # A write: refused with no write unless the fresh approver check passed.
  defp save(%{assigns: %{can_decide?: false}} = socket, _attrs), do: socket
  defp save(%{assigns: %{clip: nil}} = socket, _attrs), do: socket

  defp save(socket, attrs) do
    %{profile: profile, clip: clip, user_id: user_id} = socket.assigns

    case ClipReviewFeed.save_details(profile.org_id, profile.id, clip.id, user_id, attrs) do
      {:ok, %Clip{} = saved} ->
        queue = Enum.map(socket.assigns.queue, &if(&1.id == saved.id, do: saved, else: &1))
        assign(socket, queue: queue, clip: saved)

      {:error, _} ->
        socket
    end
  end

  defp step(%{assigns: %{queue: queue, clip: clip}} = socket, delta) do
    case index_of(queue, clip) do
      nil ->
        socket

      i ->
        case Enum.at(queue, i + delta) do
          %Clip{} = next when i + delta >= 0 -> select_clip(socket, next)
          _ -> socket
        end
    end
  end

  defp select_clip(socket, %Clip{} = clip) do
    socket
    |> assign(
      clip: clip,
      selected_id: clip.id,
      editing_title?: false,
      note: "",
      appearance_dirty: false,
      selected_version_id: nil,
      closing_error: nil,
      closing_attempt: nil
    )
    |> assign(:byline, ClipReviewFeed.byline(socket.assigns.profile.org_id, clip))
    |> assign(:headline_error, nil)
    |> headline_state()
    |> authorize()
    |> push_event("clips:url", url_params(socket.assigns.view, clip))
  end

  defp render_id(clip) do
    import Ecto.Query

    Platform.Repo.one(
      from(r in Platform.Social.ClipRender,
        where: r.clip_id == ^clip.id and r.rev == ^clip.rev,
        order_by: [desc: r.rev],
        limit: 1,
        select: r.id
      )
    )
  end

  defp reviewable?(%Clip{review_status: "pending", render_file_id: id, removed_at: nil})
       when not is_nil(id),
       do: true

  defp reviewable?(_), do: false

  # ── Loading ──────────────────────────────────────────────────────────

  # The queue, the jobs, the accounts, the selected clip and `can_decide?`,
  # all re-read now.
  defp review_queue(profile, filter) do
    profile = Social.get_profile(profile.org_id, profile.id) || profile
    queue = ClipReviewFeed.review_queue(profile.org_id, profile.id)

    queue =
      if filter == "previous" do
        ids =
          ClipClosingVideo.review_renders(profile)
          |> Enum.reject(fn {_, r} ->
            ClipClosingVideo.same_ending?(r.closing_video, profile.closing_video)
          end)
          |> Enum.map(fn {c, _} -> c.id end)

        Enum.filter(queue, &(&1.id in ids))
      else
        queue
      end

    queue
  end

  defp load(%{assigns: %{profile: %Profile{} = profile}} = socket) do
    profile = Social.get_profile(profile.org_id, profile.id) || profile
    queue = review_queue(profile, socket.assigns.closing_filter)
    clip = select(profile, queue, socket.assigns.selected_id)
    previous = socket.assigns.clip

    socket
    |> assign(:profile, profile)
    |> assign(:queue, queue)
    |> assign(:jobs, ClipReviewFeed.rendering(profile.org_id, profile.id))
    |> assign(:episode_jobs, ClipReviewFeed.episode_jobs(profile.org_id, profile.id))
    |> assign(:accounts, Social.list_accounts(profile.org_id, profile_id: profile.id))
    |> assign(:clip, clip)
    |> assign(:selected_id, clip && clip.id)
    |> assign(:byline, byline(profile, clip))
    |> then(fn s ->
      if (previous && previous.id) == (clip && clip.id),
        do: s,
        else: assign(s, editing_title?: false, note: "")
    end)
    |> headline_state()
    |> authorize()
  end

  defp load(socket),
    do:
      assign(socket,
        queue: [],
        jobs: [],
        episode_jobs: [],
        accounts: [],
        clip: nil,
        can_decide?: false
      )

  # Shares the selected immutable version with the sibling version picker.
  # Re-read on promotion; queueing/failure never changes the playable clip.
  defp headline_state(%{assigns: %{clip: %Clip{} = clip, profile: profile}} = socket) do
    versions =
      case ClipVersions.recent(profile.org_id, profile.id, clip.id, 50) do
        {:ok, rows} -> rows
        _ -> []
      end

    selected =
      Enum.find(versions, &(&1.id == socket.assigns.selected_version_id)) ||
        Enum.find(versions, &(&1.rev == clip.rev))

    attempt =
      case ClipJobs.list_jobs(profile.org_id, profile.id) do
        {:ok, jobs} ->
          Enum.find(
            Enum.reverse(jobs),
            &(&1.clip_id == clip.id and &1.payload["appearance"] == true)
          )

        _ ->
          nil
      end

    fresh_profile = Social.get_profile(profile.org_id, profile.id) || profile

    change? =
      not is_nil(selected) and selected.rev == clip.rev and clip.review_status != "approved" and
        not ClipClosingVideo.approved_render?(selected.id) and clip.origin == "burrow" and
        is_map(selected.source) and map_size(selected.source) > 0 and is_binary(selected.file_id) and
        not ClipClosingVideo.same_ending?(selected.closing_video, fresh_profile.closing_video)

    assign(socket,
      versions: versions,
      selected_render: selected,
      closing_attempt: attempt,
      closing_change?: !!change?,
      headline_attempt: ClipReviewFeed.headline_attempt(profile.org_id, profile.id, clip.id)
    )
  end

  defp headline_state(socket),
    do:
      assign(socket,
        selected_render: nil,
        versions: [],
        closing_attempt: nil,
        closing_change?: false,
        headline_attempt: nil
      )

  defp closing_message(:job_in_flight),
    do: "A render is already running. Your playing version is unchanged."

  defp closing_message(:stale_version),
    do: "Select the current version before applying the closing video."

  defp closing_message(_),
    do: "This closing video could not be applied. Your playing version is unchanged."

  defp playback_clip(clip, nil), do: clip

  defp playback_clip(clip, render),
    do: %{
      clip
      | render_file_id: render.file_id,
        rev: render.rev,
        duration_s: render.duration_s,
        look: render.look
    }

  defp version_state(render, clip) do
    cond do
      ClipClosingVideo.approved_render?(render.id) -> "Approved"
      render.rev == clip.rev -> String.capitalize(clip.review_status || "pending")
      true -> "Previous"
    end
  end

  defp headline_message(:stale_version),
    do: "A newer version is ready. Reload it before changing the headline."

  defp headline_message(:job_in_flight), do: "A render is already running. Wait for it to finish."

  defp headline_message(:invalid_headline),
    do: "Enter a headline of 1–200 characters on one line."

  defp headline_message(_), do: "This version cannot be changed. Reload and try again."

  defp byline(_profile, nil), do: %{source_label: nil, agent_name: nil}
  defp byline(profile, clip), do: ClipReviewFeed.byline(profile.org_id, clip)

  # The selected clip only when it is this profile's AND waiting in the
  # queue; anything else (another org, another profile, unknown, decided)
  # falls back to the first pending clip, rendering nothing of the refused id.
  defp select(_profile, queue, nil), do: List.first(queue)

  defp select(profile, queue, clip_id) do
    with {:ok, %Clip{id: id}} <- ClipReviewFeed.fetch_clip(profile.org_id, profile.id, clip_id),
         %Clip{} = clip <- Enum.find(queue, &(&1.id == id)) do
      clip
    else
      _ -> List.first(queue)
    end
  end

  # The server-side approver check every handle_event runs first: the user
  # and the profile are re-read, then `Social.approver_check/3`.
  defp authorize(%{assigns: %{profile: %Profile{} = profile, user_id: user_id}} = socket) do
    selected = socket.assigns.selected_render

    current? =
      is_nil(selected) or is_nil(socket.assigns.clip) or selected.rev == socket.assigns.clip.rev

    assign(socket, :can_decide?, current? and approver?(profile, user_id))
  end

  defp authorize(socket), do: assign(socket, :can_decide?, false)

  defp approver?(%Profile{org_id: org_id, id: id}, user_id) do
    with %{} <- user_id && Platform.Accounts.get_user(user_id),
         %Profile{} = profile <- Social.get_profile(org_id, id) do
      Social.approver_check(org_id, profile, user_id) == :ok
    else
      _ -> false
    end
  end

  defp url_params(view, clip) do
    %{tab: "clips", view: view, clip: clip && clip.id}
  end

  # ── Render ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:position, index_of(assigns.queue, assigns.clip))
      |> assign(:ticked, ticked(assigns.accounts, assigns.clip))

    ~H"""
    <div
      id="social-clips-review"
      data-role="clips-review"
      data-view={@view}
      data-can-decide={to_string(@can_decide?)}
    >
      <div id="social-clips-review-keys" phx-hook="ClipReview" data-role="clips-review-keys">
        <.subhead view={@view} count={length(@queue)} jobs={@jobs} myself={@myself} />
        <div
          :if={@closing_filter == "previous" and @view == "review"}
          class="alert alert-info mb-3"
          data-role="closing-impact-filter"
        >
          Clips with a previous closing video.
          <.link href={"/m/social?tab=clips&view=review&profile=#{@profile.id}"}>
            Show all clips
          </.link>
        </div>
        <.episode_outcomes :if={@view == "review"} jobs={@episode_jobs} />

        <div
          :if={@view == "review"}
          data-role="clips-bay"
          data-clip-id={@clip && @clip.id}
          class={[
            "grid grid-cols-1 overflow-hidden rounded-box border border-base-300 bg-base-100",
            "min-[761px]:grid-cols-[150px_minmax(0,1fr)_360px] min-[1181px]:grid-cols-[208px_minmax(0,1fr)_404px]",
            "max-[760px]:block max-[760px]:pb-[calc(84px+env(safe-area-inset-bottom))]"
          ]}
        >
          <.queue_rail queue={@queue} clip={@clip} jobs={@jobs} landed={@landed} myself={@myself} />

          <%= if @clip do %>
            <.stage
              clip={playback_clip(@clip, @selected_render)}
              queue={@queue}
              position={@position}
              total={length(@queue)}
              myself={@myself}
            />
            <.details
              clip={@clip}
              profile={@profile}
              appearance_jobs={@jobs}
              review_id={@id}
              appearance_dirty={@appearance_dirty}
              user_id={@user_id}
              byline={@byline}
              accounts={@accounts}
              ticked={@ticked}
              note={@note}
              can_decide?={@can_decide?}
              editing_title?={@editing_title?}
              selected_render={@selected_render}
              versions={@versions}
              closing_change?={@closing_change?}
              closing_error={@closing_error}
              closing_attempt={@closing_attempt}
              headline_attempt={@headline_attempt}
              headline_error={@headline_error}
              myself={@myself}
            />
          <% else %>
            <.empty jobs={@jobs} myself={@myself} />
            <aside class="border-base-300 max-[760px]:hidden min-[761px]:border-l"></aside>
          <% end %>
        </div>

        <.pbar
          :if={@view == "review" and @can_decide? and @clip != nil}
          render_id={render_id(@clip)}
          appearance_dirty={@appearance_dirty}
          clip={@clip}
          note={@note}
          ticked={@ticked}
          myself={@myself}
        />

        <.toast :if={@toast} toast={@toast} myself={@myself} />
      </div>
    </div>
    """
  end

  # [drawToast] one toast at a time. An undo toast carries the decision's
  # deadline (data-until, from ClipDecisions' return) and a bar that drains
  # by CSS alone (@starting-style); no client timer commits anything.
  attr :toast, :map, required: true
  attr :myself, :any, required: true

  defp toast(assigns) do
    left = max(assigns.toast.until - System.system_time(:millisecond), 0)

    assigns =
      assigns
      |> assign(:undo?, assigns.toast.kind in [:approved, :rejected])
      |> assign(:left_ms, left)
      |> assign(:secs, div(left + 999, 1000))

    ~H"""
    <div
      id="clip-toast"
      role="status"
      data-role="clip-toast"
      data-kind={@toast.kind}
      data-until={@toast.until}
      class={[
        "fixed bottom-[22px] left-1/2 z-[70] max-[760px]:bottom-auto max-[760px]:top-[calc(72px+env(safe-area-inset-top))] flex max-w-[94vw] -translate-x-1/2 items-center gap-3 overflow-hidden",
        "rounded-full border border-base-300 bg-base-200 py-2 pl-3.5 text-sm shadow",
        if(@undo?, do: "pr-2", else: "pr-3.5")
      ]}
    >
      <.icon
        :if={@toast.kind == :approved}
        name="hero-check-circle-solid"
        class="size-5 shrink-0 text-success"
      />
      <.icon
        :if={@toast.kind == :rejected}
        name="hero-x-circle-solid"
        class="size-5 shrink-0 text-error"
      />
      <span class="truncate text-base-content" data-role="clip-toast-text">
        <b :if={@toast.lead} class="font-semibold">{@toast.lead}</b><span :if={@toast.lead}> · </span>{@toast.text}
      </span>
      <button
        :if={@undo?}
        type="button"
        class="btn btn-sm shrink-0 gap-2 rounded-full border-0 bg-base-300 font-semibold text-primary"
        phx-click="undo"
        phx-value-render_id={Map.get(@toast, :render_id)}
        phx-value-id={@toast.clip_id}
        phx-target={@myself}
        data-role="clip-toast-undo"
      >
        Undo
        <small
          class="font-mono text-xs font-normal text-subtle"
          data-role="clip-toast-secs"
        >
          {@secs}s
        </small>
      </button>
      <i
        :if={@undo?}
        class="absolute bottom-0 left-0 h-0.5 w-full origin-left scale-x-0 bg-primary transition-transform ease-linear starting:scale-x-100"
        style={"transition-duration: #{@left_ms}ms"}
        data-role="clip-toast-bar"
      >
      </i>
    </div>
    """
  end

  # [socialHTML .subhead] segmented Review/Library, the count, the pill.
  attr :view, :string, required: true
  attr :count, :integer, required: true
  attr :jobs, :list, required: true
  attr :myself, :any, required: true

  defp subhead(assigns) do
    ~H"""
    <div class="mb-3 flex flex-wrap items-center gap-3" data-role="clips-subhead">
      <div
        class="inline-flex gap-0.5 rounded-full border border-base-300 p-[3px]"
        role="tablist"
        aria-label="Clips view"
        data-role="clips-view-switch"
      >
        <button
          :for={{key, label} <- [{"review", "Review"}, {"library", "Library"}]}
          type="button"
          role="tab"
          class={[
            "h-[30px] rounded-full px-4 text-sm",
            if(@view == key,
              do: "bg-base-300 font-semibold text-base-content",
              else: "text-base-content"
            )
          ]}
          aria-selected={to_string(@view == key)}
          phx-click="set_view"
          phx-value-view={key}
          phx-target={@myself}
          data-role="clips-view-button"
          data-view={key}
        >
          {label}
        </button>
      </div>
      <span class="text-sm text-base-content max-[760px]:hidden" data-role="clips-count">
        <b class="font-semibold text-base-content">{@count} to review</b> · one approval publishes
      </span>
      <a
        :if={@jobs != []}
        href="#rq"
        class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-200 px-3 py-1 text-xs text-base-content"
        data-role="clips-rendering-pill"
      >
        <span class="loading loading-spinner loading-xs text-info"></span>
        <span>
          {length(@jobs)} rendering<span class="max-[760px]:hidden"> on clip tool</span>
        </span>
      </a>
    </div>
    """
  end

  # [queueHTML] the queue rail and the render queue (#rq).
  attr :queue, :list, required: true
  attr :clip, :any, required: true
  attr :jobs, :list, required: true
  attr :landed, :any, required: true
  attr :myself, :any, required: true

  defp queue_rail(assigns) do
    ~H"""
    <nav
      class="flex flex-col gap-1 overflow-y-auto border-base-300 p-2 max-[760px]:hidden min-[761px]:border-r"
      aria-label="Clips to review"
      data-role="clips-queue"
    >
      <div class="flex items-center justify-between px-1.5 pb-1 pt-0.5 text-xs font-semibold uppercase tracking-wider text-subtle">
        <span>Review</span>
        <span data-role="clips-queue-count">{length(@queue)}</span>
      </div>

      <p :if={@queue == []} class="px-1.5 py-2 text-xs text-subtle">
        Nothing left to review.
      </p>

      <button
        :for={item <- @queue}
        type="button"
        class={[
          "flex w-full items-start gap-2 rounded-box p-1.5 text-left",
          @clip && @clip.id == item.id && "bg-base-200",
          MapSet.member?(@landed, item.id) && "bg-base-200 ring ring-info"
        ]}
        aria-current={if(@clip && @clip.id == item.id, do: "true")}
        phx-click="pick"
        phx-value-id={item.id}
        phx-target={@myself}
        data-role="clips-queue-item"
        data-clip-id={item.id}
        data-landed={MapSet.member?(@landed, item.id) && "true"}
      >
        <span class="relative h-20 w-[46px] shrink-0 overflow-hidden rounded-lg bg-base-300">
          <video
            :if={item.render_file_id}
            preload="metadata"
            muted
            playsinline
            src={media_src(item.render_file_id) <> "#t=0.1"}
            class="block size-full object-cover"
          >
          </video>
          <span
            :if={mmss(item.duration_s)}
            class="absolute bottom-[3px] right-[3px] rounded bg-base-100/80 px-1 text-[10px] font-semibold leading-4 text-base-content"
          >
            {mmss(item.duration_s)}
          </span>
        </span>
        <span class="min-w-0 flex-1">
          <span class="mt-0.5 line-clamp-2 text-[13px] font-semibold leading-[1.3] text-base-content">
            {item.title || "Untitled clip"}
          </span>
          <span class="mt-0.5 block truncate font-mono text-xs text-subtle">
            {join_dot([item.episode_code, mmss(item.duration_s)])}
          </span>
        </span>
      </button>

      <div :if={@jobs != []} id="rq" class="mt-3 flex flex-col gap-1" data-role="clips-render-queue">
        <div class="flex items-center justify-between px-1.5 pb-1 text-xs font-semibold uppercase tracking-wider text-subtle">
          <span>Rendering on clip tool</span>
          <span>{length(@jobs)}</span>
        </div>
        <div
          :for={job <- @jobs}
          class="flex flex-col gap-1 rounded-box p-1.5"
          data-role="clips-render-row"
          data-job-id={job.id}
        >
          <div class="flex items-start gap-2">
            <span class="loading loading-spinner loading-xs mt-0.5 shrink-0 text-info"></span>
            <span class="min-w-0 flex-1">
              <span class="line-clamp-2 text-xs font-semibold leading-snug text-base-content">
                {job.title || "New clip"}
              </span>
              <span
                class="block truncate text-xs text-subtle"
                data-role="clips-render-eta"
              >
                {join_dot([job.episode_code, eta_left(job.eta_s)])}
              </span>
            </span>
          </div>
          <progress
            :if={is_number(job.progress)}
            class="progress progress-info h-1 w-full"
            value={round(job.progress * 100)}
            max="100"
          >
          </progress>
          <progress :if={!is_number(job.progress)} class="progress progress-info h-1 w-full">
          </progress>
        </div>
        <p class="px-1.5 pt-1 text-xs text-subtle">Finished renders land in Review.</p>
      </div>
    </nav>
    """
  end

  # [reviewHTML] the stage: position, prev/next, the 9:16 player, the
  # scrubber and the keyboard hint.
  attr :clip, :any, required: true
  attr :queue, :list, required: true
  attr :position, :any, required: true
  attr :total, :integer, required: true
  attr :myself, :any, required: true

  defp stage(assigns) do
    ~H"""
    <section
      class="flex min-w-0 flex-col items-center gap-3 p-4 max-[760px]:items-stretch max-[760px]:px-3 max-[760px]:pt-0"
      data-role="clips-stage"
    >
      <div class="flex w-full max-w-[420px] items-center justify-between max-[760px]:hidden">
        <span class="font-mono text-sm text-base-content" data-role="clips-position">
          {if @position, do: "#{@position + 1} of #{@total}", else: "#{@total} to review"}
        </span>
        <div class="flex items-center gap-1">
          <button
            type="button"
            class="btn btn-ghost btn-square btn-sm"
            aria-label="Previous clip (K)"
            disabled={@position in [nil, 0]}
            phx-click="prev"
            phx-target={@myself}
            data-role="clips-prev"
          >
            <.icon name="hero-chevron-left" class="size-4" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-square btn-sm"
            aria-label="Next clip (J)"
            disabled={@position == nil or @position + 1 >= @total}
            phx-click="next"
            phx-target={@myself}
            data-role="clips-next"
          >
            <.icon name="hero-chevron-right" class="size-4" />
          </button>
        </div>
      </div>

      <div
        class={[
          "flex w-[min(100%,calc(min(448px,calc(100vh-340px))*9/16))] min-w-[169px] flex-col gap-2",
          "max-[760px]:w-full max-[760px]:min-w-0"
        ]}
        data-role="clips-player-stack"
      >
        <div class="flex justify-center gap-2.5" data-role="clips-pv-row">
          <div
            id={"clip-player-#{@clip.id}-r#{@clip.rev}"}
            phx-hook="ChatClip"
            phx-update="ignore"
            data-role="clip-player"
            class="relative w-full max-[760px]:w-[min(calc(100%-78px),calc(46vh*9/16))]"
          >
            <div
              data-role="clip-frame"
              class="relative aspect-[9/16] w-full overflow-hidden rounded-box bg-base-300"
            >
              <video
                preload="metadata"
                playsinline
                loop
                src={media_src(@clip.render_file_id)}
                class="block size-full object-cover"
              >
              </video>
              <button
                type="button"
                class="absolute left-1/2 top-1/2 flex size-[54px] -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full bg-base-100/80 text-base-content shadow"
                aria-label="Play or pause"
                data-role="clip-play"
              >
                <span data-role="clip-icon-play" class="flex">
                  <.icon name="hero-play" class="size-7" />
                </span>
                <span data-role="clip-icon-pause" class="hidden">
                  <.icon name="hero-pause" class="size-7" />
                </span>
              </button>
            </div>
            <div
              data-role="clip-fallback"
              class="hidden items-center gap-2 rounded-box bg-base-200 px-3 py-4 text-sm"
            >
              <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-error" />
              <span class="flex-1">Can't play this video</span>
            </div>
          </div>
          <.upnext queue={@queue} clip={@clip} myself={@myself} />
        </div>

        <div class="flex items-center gap-2" data-role="clip-scrub">
          <button
            type="button"
            class="btn btn-ghost btn-square btn-xs"
            aria-label="Play or pause"
            data-role="clip-scrub-play"
          >
            <span data-role="clip-icon-play" class="flex">
              <.icon name="hero-play" class="size-4" />
            </span>
            <span data-role="clip-icon-pause" class="hidden">
              <.icon name="hero-pause" class="size-4" />
            </span>
          </button>
          <span class="w-8 text-xs tabular-nums text-subtle" data-role="clip-time">
            0:00
          </span>
          <span class="relative h-1 flex-1 overflow-hidden rounded-full bg-base-300">
            <span class="absolute inset-y-0 left-0 w-0 bg-primary" data-role="clip-scrub-fill"></span>
          </span>
          <span
            class="w-8 text-right text-xs tabular-nums text-subtle"
            data-role="clip-scrub-duration"
          >
            {mmss(@clip.duration_s) || "0:00"}
          </span>
        </div>
      </div>

      <p
        class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-subtle max-[760px]:hidden"
        data-role="clips-kbd-hint"
      >
        <span><kbd class="kbd kbd-sm">J</kbd> next</span>
        <span><kbd class="kbd kbd-sm">K</kbd> previous</span>
        <span><kbd class="kbd kbd-sm">Space</kbd> play / pause</span>
      </p>
    </section>
    """
  end

  # [reviewHTML .upnext] phone only: the next two clips (after the selected
  # one, wrapping to the start) as 68px 9:16 thumbs, then "+N more", or
  # "last one" when the selected clip is the only one left.
  attr :queue, :list, required: true
  attr :clip, :any, required: true
  attr :myself, :any, required: true

  defp upnext(assigns) do
    i = index_of(assigns.queue, assigns.clip) || 0
    {before, rest} = Enum.split(assigns.queue, i + 1)
    nexts = Enum.reject(rest ++ before, &(&1.id == assigns.clip.id))

    assigns =
      assign(assigns,
        shown: Enum.take(nexts, 2),
        more: max(length(nexts) - 2, 0),
        none?: nexts == []
      )

    ~H"""
    <div class="hidden w-[68px] flex-none flex-col gap-1.5 max-[760px]:flex" data-role="clips-upnext">
      <span class="text-xs font-bold tracking-wider text-subtle">UP NEXT</span>
      <button
        :for={item <- @shown}
        type="button"
        class="relative aspect-[9/16] w-[68px] overflow-hidden rounded-lg bg-base-300"
        aria-label={item.title || "Untitled clip"}
        phx-click="pick"
        phx-value-id={item.id}
        phx-target={@myself}
        data-role="clips-upnext-item"
        data-clip-id={item.id}
      >
        <video
          :if={item.render_file_id}
          preload="metadata"
          muted
          playsinline
          src={media_src(item.render_file_id) <> "#t=0.1"}
          class="block size-full object-cover"
        >
        </video>
        <span
          :if={mmss(item.duration_s)}
          class="absolute bottom-[3px] right-[3px] rounded bg-base-100/80 px-[3px] font-mono text-[9px] text-base-content"
        >
          {mmss(item.duration_s)}
        </span>
      </button>
      <span :if={@more > 0} class="text-xs text-subtle" data-role="clips-upnext-more">
        +{@more} more
      </span>
      <span :if={@none?} class="text-xs text-subtle" data-role="clips-upnext-more">
        last one
      </span>
    </div>
    """
  end

  attr :clip, :any, required: true
  attr :profile, :any, required: true
  attr :selected, :any, required: true
  attr :versions, :list, required: true
  attr :change?, :boolean, required: true
  attr :pending?, :boolean, required: true
  attr :error, :any, required: true
  attr :attempt, :any, required: true
  attr :can_decide?, :boolean, required: true
  attr :myself, :any, required: true

  defp closing_versions(assigns) do
    assigns =
      assign(
        assigns,
        :ending,
        ClipClosingVideo.ending_name(
          assigns.selected && assigns.selected.closing_video,
          assigns.profile
        )
      )

    ~H"""
    <section class="min-w-0 space-y-2" aria-label="Render versions" data-role="closing-versions">
      <div class="flex min-w-0 items-center gap-2 text-xs text-subtle" data-role="selected-ending">
        <span :if={@selected} class="shrink-0">
          v{@selected.rev} · {version_state(@selected, @clip)}
        </span>
        <span
          :if={@selected}
          class="min-w-0 truncate"
          data-role="selected-render-style"
          title={Platform.Social.ClipCaptionPreviews.version_label(@selected)}
        >
          {Platform.Social.ClipCaptionPreviews.version_label(@selected)}
        </span>
        <span :if={@ending} class="min-w-0 truncate" title={@ending}>Ends with: {@ending}</span>
        <span :if={!@ending} class="min-w-0 truncate">No closing video</span>
      </div>
      <div :if={length(@versions) > 1} class="flex flex-wrap gap-1" aria-label="Select render version">
        <button
          :for={r <- @versions}
          type="button"
          class="btn btn-ghost btn-xs h-auto min-h-6 max-w-full shrink-0 whitespace-normal text-left"
          aria-pressed={to_string(@selected && r.id == @selected.id)}
          phx-click="pick_version"
          phx-value-render_id={r.id}
          phx-target={@myself}
          data-role="pick-render-version"
          data-render-id={r.id}
        >
          v{r.rev} · {version_state(r, @clip)} · {Platform.Social.ClipCaptionPreviews.version_label(r)}
        </button>
      </div>
      <form
        :if={@can_decide? and @change?}
        phx-submit="use_closing_video"
        phx-target={@myself}
        data-role="use-closing-video"
      >
        <input type="hidden" name="base_render_id" value={@selected && @selected.id} />
        <button
          type="submit"
          class="btn btn-outline btn-sm rounded-field"
          disabled={@pending?}
          phx-disable-with="Rendering…"
        >
          Use current closing video
        </button>
      </form>
      <p :if={@pending?} role="status" class="text-xs text-subtle" data-role="closing-render-pending">
        Rendering a new pending version. You can keep playing this one.
      </p>
      <p :if={@error} role="alert" class="text-xs text-error" data-role="closing-render-error">
        {@error}
      </p>
      <p
        :if={@attempt && @attempt.status in ["failed", "cancelled"]}
        role="alert"
        class="text-xs text-error"
        data-role="closing-render-failure"
      >
        Render failed. Your previous video is unchanged.
      </p>
    </section>
    """
  end

  # [detailsHTML] title, meta, byline, caption, Post to, note, footer.
  attr :clip, :any, required: true
  attr :byline, :map, required: true
  attr :accounts, :list, required: true
  attr :ticked, :list, required: true
  attr :note, :string, required: true
  attr :can_decide?, :boolean, required: true
  attr :editing_title?, :boolean, required: true
  attr :myself, :any, required: true

  attr :selected_render, :any, default: nil
  attr :versions, :list, default: []
  attr :closing_change?, :boolean, default: false
  attr :closing_error, :any, default: nil
  attr :closing_attempt, :any, default: nil
  attr :headline_attempt, :any, default: nil
  attr :headline_error, :any, default: nil
  attr :review_id, :string, required: true
  attr :appearance_dirty, :boolean, default: false
  attr :appearance_jobs, :list, default: []

  attr :profile, :any, required: true
  attr :user_id, :any, required: true

  defp details(assigns) do
    assigns =
      assigns
      |> assign(:agent, assigns.byline.agent_name)
      |> assign(
        :caption,
        if(assigns.selected_render && assigns.selected_render.rev != assigns.clip.rev,
          do: assigns.selected_render.caption || "",
          else: assigns.clip.caption || ""
        )
      )
      |> assign(
        :display_title,
        if(assigns.selected_render && assigns.selected_render.rev != assigns.clip.rev,
          do: assigns.selected_render.headline,
          else: assigns.clip.title
        )
      )
      |> assign(
        :current_version?,
        is_nil(assigns.selected_render) or assigns.selected_render.rev == assigns.clip.rev
      )
      |> assign(
        :closing_pending?,
        assigns.closing_attempt != nil and
          assigns.closing_attempt.status in ~w(queued claimed running)
      )
      |> assign(
        :headline_pending?,
        assigns.headline_attempt != nil and
          assigns.headline_attempt.status in ~w(queued claimed running)
      )

    ~H"""
    <aside
      class="flex min-w-0 flex-col border-base-300 max-[760px]:gap-4 max-[760px]:p-3 min-[761px]:border-l"
      data-role="clips-details"
    >
      <div
        class="contents"
        data-role="clips-details-body"
        role="region"
        tabindex="0"
        aria-label="Clip details"
      >
        <.live_component
          module={PlatformWeb.SocialClipRemoval}
          id={"review-remove-#{@clip.id}"}
          clip={@clip}
          profile={@profile}
          user_id={@user_id}
        />
        <div>
          <form
            :if={@editing_title?}
            phx-submit="save_title"
            phx-target={@myself}
            data-role="clip-title-form"
          >
            <input
              type="text"
              name="title"
              value={@clip.title}
              maxlength="200"
              class="input input-bordered w-full bg-base-100 text-base font-semibold"
              aria-label="Title"
              phx-blur="save_title"
              phx-target={@myself}
              phx-mounted={Phoenix.LiveView.JS.focus()}
              data-role="clip-title-input"
            />
          </form>
          <button
            :if={!@editing_title?}
            type="button"
            class="group flex w-full items-start gap-2 rounded-box border border-base-300 px-3 py-2 text-left text-lg font-bold leading-snug text-base-content disabled:cursor-default"
            phx-click="edit_title"
            phx-target={@myself}
            disabled={!@can_decide?}
            data-role="clip-title"
          >
            <span class="flex-1" data-role="clips-selected-title">
              {@display_title || "Untitled clip"}
            </span>
            <.icon
              :if={@can_decide?}
              name="hero-pencil-square"
              class="mt-0.5 size-4 shrink-0 text-subtle"
            />
          </button>
          <p class="mt-2 font-mono text-xs text-subtle" data-role="clip-meta">
            {join_dot([
              @clip.episode_code,
              mmss((@selected_render && @selected_render.duration_s) || @clip.duration_s),
              @clip.source_label,
              "v#{(@selected_render && @selected_render.rev) || @clip.rev}"
            ])}
          </p>
          <p class="mt-2 flex items-center gap-2 text-xs text-base-content" data-role="clip-byline">
            <span
              :if={@agent}
              class="flex size-5 shrink-0 items-center justify-center rounded-full bg-base-300 text-[10px] font-bold text-base-content"
              aria-hidden="true"
            >
              {String.first(@agent) |> String.upcase()}
            </span>
            <span>
              <span :if={@byline.source_label} class="font-mono">{@byline.source_label}</span><span :if={
                @agent
              }> · rendered by <b class="font-semibold text-base-content">{@agent}</b></span>
            </span>
          </p>
          <div class="mt-3 hidden flex-wrap gap-2 max-[760px]:flex" data-role="clip-platform-chips">
            <button
              :for={platform <- @accounts |> Enum.map(& &1.platform) |> Enum.uniq()}
              type="button"
              role="checkbox"
              aria-checked={to_string(platform in @ticked)}
              class={[
                "btn btn-sm rounded-full",
                if(platform in @ticked, do: "btn-primary", else: "btn-outline border-base-300")
              ]}
              disabled={!@can_decide?}
              phx-click="toggle_platform"
              phx-value-platform={platform}
              phx-target={@myself}
              data-role="clip-platform-chip"
              data-platform={platform}
            >
              {Approvals.platform_label(platform)}
            </button>
          </div>
        </div>

        <.closing_versions
          clip={@clip}
          profile={@profile}
          selected={@selected_render}
          versions={@versions}
          change?={@closing_change?}
          pending?={@closing_pending?}
          error={@closing_error}
          attempt={@closing_attempt}
          can_decide?={@can_decide?}
          myself={@myself}
        />

        <.live_component
          :if={@current_version?}
          module={PlatformWeb.SocialClipAppearance}
          id={"appearance-#{@clip.id}"}
          refresh_key={Enum.map(@appearance_jobs, &{&1.id, &1.status})}
          review_id={@review_id}
          clip={@clip}
          profile={@profile}
          user_id={@user_id}
        />

        <section aria-label="Clip headline" data-role="clip-headline-section" class="space-y-2">
          <form phx-submit="rerender_headline" phx-target={@myself} data-role="clip-headline-form">
            <input
              type="hidden"
              name="base_render_id"
              value={@selected_render && @selected_render.id}
            />
            <label for="clip-headline" class="text-xs font-semibold text-base-content">
              Headline
            </label>
            <input
              id="clip-headline"
              name="headline"
              type="text"
              maxlength="200"
              value={(@selected_render && @selected_render.headline) || ""}
              disabled={!@can_decide? or @headline_pending? or is_nil(@selected_render)}
              aria-describedby="clip-headline-help"
              class="input input-bordered mt-1 w-full bg-base-100 text-sm"
              data-role="clip-headline-input"
            />
            <p id="clip-headline-help" class="mt-1 text-xs text-subtle">
              Headlines are generated automatically. Enter new text to render another version.
              Local generated text stays on the clip runner.
            </p>
            <button
              type="submit"
              class="btn btn-primary btn-sm mt-2 min-h-11"
              disabled={!@can_decide? or @headline_pending? or is_nil(@selected_render)}
              phx-disable-with="Rendering…"
              data-role="clip-headline-render"
            >
              {if @headline_pending?, do: "Rendering…", else: "Render headline"}
            </button>
          </form>
          <p
            :if={@headline_pending?}
            role="status"
            class="text-xs text-subtle"
            data-role="clip-headline-pending"
          >
            Rendering a new version. You can keep playing this one.
          </p>
          <p
            :if={@headline_error}
            role="alert"
            class="text-xs text-error"
            data-role="clip-headline-error"
          >
            {@headline_error}
          </p>
          <p
            :if={@headline_attempt && @headline_attempt.status == "failed"}
            role="alert"
            class="text-xs text-error"
            data-role="clip-headline-failure"
          >
            Headline render failed ({@headline_attempt.code}). Your previous video is unchanged.
            Check the clip runner, then enter a headline and try again.
          </p>
        </section>

        <form phx-change="save_caption" phx-target={@myself}>
          <div class="mb-1 flex items-center justify-between text-xs">
            <label for="clip-caption" class="font-semibold text-base-content">Caption</label>
            <span class="tabular-nums text-subtle" data-role="clip-caption-count">
              {String.length(@caption)}/2200
            </span>
          </div>
          <textarea
            id="clip-caption"
            name="caption"
            rows="4"
            maxlength="2200"
            phx-debounce="600"
            disabled={!@can_decide?}
            class="textarea textarea-bordered w-full bg-base-100 text-sm"
            data-role="clip-caption"
          >{@caption}</textarea>
        </form>

        <div class="max-[760px]:hidden" data-role="clip-post-to">
          <div class="mb-1 flex items-center justify-between text-xs">
            <span class="font-semibold text-base-content">Post to</span>
            <span class="text-subtle">publishes on approve</span>
          </div>
          <ul class="flex flex-col divide-y divide-base-300 rounded-box border border-base-300">
            <li
              :for={account <- @accounts}
              class="flex items-center gap-2 px-3 py-2"
              data-role="clip-platform-row"
              data-platform={account.platform}
            >
              <span class="flex size-6 shrink-0 items-center justify-center rounded-md border border-base-300">
                <.icon name="hero-globe-alt" class="size-3.5 text-base-content" />
              </span>
              <span class="text-sm font-semibold text-base-content">
                {Approvals.platform_label(account.platform)}
              </span>
              <span class="min-w-0 flex-1 truncate text-xs text-subtle">{account.handle}</span>
              <input
                type="checkbox"
                class="toggle toggle-primary toggle-sm"
                role="switch"
                aria-label={Approvals.platform_label(account.platform)}
                checked={account.platform in @ticked}
                disabled={!@can_decide?}
                phx-click="toggle_platform"
                phx-value-platform={account.platform}
                phx-target={@myself}
                data-role="clip-platform-toggle"
              />
            </li>
          </ul>
        </div>

        <form phx-change="note" phx-target={@myself}>
          <div class="mb-1 flex items-center justify-between text-xs">
            <label for="clip-note" class="font-semibold text-base-content">Note</label>
            <span class="text-subtle" data-role="clip-note-hint">needed to reject</span>
          </div>
          <textarea
            id="clip-note"
            name="note"
            rows="3"
            maxlength="2000"
            phx-debounce="200"
            disabled={!@can_decide?}
            placeholder={"Why not? #{@agent || @byline.source_label || "the clip tool"} reads this for the next cut…"}
            class="textarea textarea-bordered w-full bg-base-100 text-sm"
            data-role="clip-note"
          >{@note}</textarea>
        </form>
      </div>

      <.decision_bar
        :if={@can_decide?}
        clip={@clip}
        note={@note}
        ticked={@ticked}
        render_id={render_id(@clip)}
        appearance_dirty={@appearance_dirty}
        why_line={why_line(@ticked)}
        myself={@myself}
      />
    </aside>
    """
  end

  attr :jobs, :list, required: true

  defp episode_outcomes(assigns) do
    ~H"""
    <section
      :if={@jobs != []}
      aria-label="Automatic episodes"
      data-role="episode-jobs"
      class="mb-4 rounded-box border border-base-300 bg-base-100 p-4 text-base-content"
    >
      <h3 class="text-sm font-semibold">Automatic episodes</h3>
      <p class="mt-1 text-xs text-subtle">
        New episodes run automatically. Finished clips appear in Review.
      </p>
      <ul class="mt-3 space-y-3">
        <li :for={job <- @jobs} data-role="episode-job" data-job-id={job.id} data-status={job.status}>
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <span class="font-semibold">
              Episode <span class="font-normal text-subtle">· {job.uploaded_at}</span>
            </span>
            <span
              class={if job.status == "failed", do: "text-error", else: "text-subtle"}
              role={if job.status == "failed", do: "alert", else: "status"}
            >
              {job.step}<span :if={job.status == "failed"}> ({job.code})</span>
            </span>
            <span
              :if={job.progress && job.status in ["claimed", "running"]}
              class="text-xs tabular-nums text-subtle"
            >
              {round(job.progress * 100)}%
            </span>
          </div>
          <progress
            :if={job.status in ["claimed", "running"] && job.progress}
            class="progress progress-primary mt-1 h-1 w-full max-w-sm"
            value={job.progress}
            max="1"
            aria-label="Episode progress"
          >
          </progress>
          <p :if={job.status == "failed"} class="mt-1 text-xs text-subtle">
            Episode incomplete. Completed clips remain available for review. Check the clip runner.
          </p>
          <ul :if={job.children != []} class="mt-2 space-y-1 border-l border-base-300 pl-3">
            <li
              :for={{child, index} <- Enum.with_index(job.children, 1)}
              data-role="episode-child-job"
              data-job-id={child.id}
              data-status={child.status}
              class="flex flex-wrap gap-2 text-xs"
            >
              <span>Clip {index}</span>
              <span
                class={if child.status == "failed", do: "text-error", else: "text-subtle"}
                role={if child.status == "failed", do: "alert", else: "status"}
              >
                {child.step}<span :if={child.status == "failed"}> ({child.code})</span>
              </span>
              <span
                :if={child.progress && child.status in ["claimed", "running"]}
                class="tabular-nums text-subtle"
              >
                {round(child.progress * 100)}%
              </span>
            </li>
          </ul>
        </li>
      </ul>
    </section>
    """
  end

  # [reviewHTML empty branch]
  attr :jobs, :list, required: true
  attr :myself, :any, required: true

  defp empty(assigns) do
    ~H"""
    <div
      class="flex flex-col items-center justify-center gap-2 p-10 text-center"
      data-role="clips-empty"
    >
      <.icon name="hero-check-badge" class="size-10 text-subtle" />
      <h3 class="text-base font-semibold text-base-content">All caught up</h3>
      <p class="text-sm text-base-content">
        Approved clips are publishing.<span :if={@jobs != []}> More are rendering on the clip tool.</span>
      </p>
      <button
        type="button"
        class="btn btn-ghost btn-sm"
        phx-click="set_view"
        phx-value-view="library"
        phx-target={@myself}
        data-role="clips-open-library"
      >
        Open Library
      </button>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp index_of(_queue, nil), do: nil
  defp index_of(queue, %Clip{id: id}), do: Enum.find_index(queue, &(&1.id == id))

  # Ticked platforms: the clip's platforms the profile has an account for,
  # in account order.
  defp ticked(_accounts, nil), do: []

  defp ticked(accounts, %Clip{platforms: platforms}) do
    platforms = platforms || []
    accounts |> Enum.map(& &1.platform) |> Enum.uniq() |> Enum.filter(&(&1 in platforms))
  end

  defp why_line([]), do: "Tick at least one platform to approve"

  defp why_line(platforms) do
    "Publishes to #{platforms |> Enum.map(&Approvals.platform_label/1) |> join_and()} now · no second approval"
  end

  defp join_and([one]), do: one
  defp join_and(list), do: Enum.join(Enum.drop(list, -1), ", ") <> " and " <> List.last(list)

  # The same Files route Social's cards and cover picker use for media.
  defp media_src(file_id), do: "/files/blob/#{file_id}"

  defp join_dot(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

  defp eta_left(nil), do: nil
  defp eta_left(s), do: "#{mmss(s)} left"

  defp mmss(s) when is_number(s) and s >= 0 do
    total = round(s)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp mmss(_), do: nil
end
