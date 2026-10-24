defmodule PlatformWeb.SocialIdeaCard do
  @moduledoc """
  One idea on the Queue ("Needs you", Social authoring 5/11, task 01a16c50):
  a header (where the idea came from, which agent drafted it, its title and
  stage), then one column per account, each the platform's real preview
  (`PlatformWeb.SocialPreview.preview/1`) with its flags, the suggested time
  in the profile's timezone and the agent's reason for it.

  ## Every click is a fresh, server-side decision

  Like `PlatformWeb.SocialCardComponent`, this LiveComponent runs in the
  clicking human's own LiveView process, and every click:

    * re-reads the user from the database (`Platform.Accounts.get_user/1`)
      from `viewer`, never a cached struct;
    * names the post's approval card by its canvas id and carries the
      content `fingerprint` this card rendered, so an edit the human did
      not see is refused (`:post_changed`, in plain words on the column);
    * goes through `Platform.Social.Approvals.decide_*` (approve, approve
      into the next slot, edit, reject) or
      `Platform.Social.Ideas.request_revision/4` (revise), where every rule
      is enforced. This module only reflects refusals.

  The chat approval card is the same card row: a decision here re-renders
  it through `Approvals.rerender/1` (and a decision there re-renders this
  one through the Queue tab's canvas subscription). Nothing is approved
  twice: the second decision finds the card decided.

  "Approve all" approves every version this viewer may approve, each through
  `Approvals.decide_approve/3` with ITS OWN rendered fingerprint, after one
  confirm step that lists what goes out when.

  ## Who sees what

  Every human who can open the profile in Social sees every version's
  preview. Only actions `Approvals.card_view/2` grants are rendered: a
  non-approver gets no buttons at all (not disabled ones), a profile
  approver on an owned account sees "Waiting for <owner>", and a draft-only
  account offers "Copy text" in place of Approve.

  ## Phone (< sm)

  The versions are a full-width, scroll-snapped strip: swipe (or the arrow
  keys, `QueueSwipe` hook) moves between them, and a sticky bottom bar holds
  Approve, Revise and Reject for the version on screen (`current`).

  ## The alt-text flag

  Posts have no alt-text field yet, so `PlatformLimits.flags/2` reports
  `missing_alt` on every image. It is taken out of the warning chips and
  shown as one quiet line instead, so it never outweighs a real problem.
  """
  use PlatformWeb, :live_component

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Social.{Account, Approvals, Ideas, NextSlot, PlatformLimits, Post, PostEvents}
  alias PlatformWeb.SocialPreview

  @refusals %{
    slot_passed: "That slot has passed. Pick the time again.",
    slot_changed: "The next slot moved. Check the new time and approve again.",
    note_required: "Say what should change before asking for a revision.",
    note_too_long: "Keep the note under #{Ideas.max_note()} characters.",
    not_needs_approval: "This post isn't waiting for approval any more."
  }

  @source_labels %{
    "chat" => {"From chat", "hero-chat-bubble-left-right-mini"},
    "clip" => {"From a clip", "hero-film-mini"},
    "task" => {"From a task", "hero-check-circle-mini"},
    "meeting" => {"From a meeting", "hero-video-camera-mini"},
    "agent" => {"Agent idea", "hero-sparkles-mini"},
    "human" => {"Your idea", "hero-user-mini"},
    "url" => {"From a link", "hero-link-mini"}
  }

  @stage_labels %{
    "inbox" => "Inbox",
    "drafting" => "Drafting",
    "in_review" => "In review",
    "scheduled" => "Scheduled",
    "live" => "Live",
    "failed" => "Failed"
  }

  # ── Lifecycle ────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       mode: nil,
       mode_post: nil,
       text: "",
       notices: %{},
       confirm_all?: false,
       current: 0,
       all_result: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(
        Map.take(assigns, [
          :id,
          :group,
          :viewer,
          :profiles,
          :show_brand?,
          :focused?,
          :deep_link?,
          :cover_controls,
          :dom_prefix
        ])
      )
      |> assign_new(:show_brand?, fn -> false end)
      |> assign_new(:focused?, fn -> false end)
      |> assign_new(:deep_link?, fn -> false end)
      |> assign_new(:cover_controls, fn -> false end)
      |> assign_new(:dom_prefix, fn -> "queue" end)
      |> refresh()

    {:ok, socket}
  end

  # Every version re-read now: the post row, its account, its card and this
  # viewer's role on it. Nothing here is trusted at click time.
  defp refresh(socket) do
    %{group: group, viewer: viewer} = socket.assigns
    ids = Enum.map(group.posts, & &1.id)

    posts =
      from(p in Post, where: p.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    accounts =
      posts
      |> Map.values()
      |> Enum.map(& &1.account_id)
      |> then(&from(a in Account, where: a.id in ^&1))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    versions =
      for id <- ids,
          %Post{} = post <- [posts[id]],
          %Account{} = account <- [accounts[post.account_id]] do
        post
        |> version(account, profile_for(socket, account), viewer)
        |> Map.put(:dom, socket.assigns.dom_prefix)
      end

    approvable = Enum.filter(versions, &(:approve in &1.actions))
    current = socket.assigns.current |> max(0) |> min(max(length(versions) - 1, 0))

    mode =
      if socket.assigns.mode &&
           Enum.any?(versions, &(&1.post.id == socket.assigns.mode_post and &1.actions != [])),
         do: socket.assigns.mode

    assign(socket,
      versions: versions,
      approvable: approvable,
      current: current,
      mode: mode,
      mode_post: mode && socket.assigns.mode_post,
      confirm_all?: socket.assigns.confirm_all? and length(approvable) > 1,
      header: header(group, versions)
    )
  end

  defp profile_for(socket, %Account{profile_id: id}), do: Map.get(socket.assigns.profiles, id)

  defp version(post, account, profile, viewer) do
    card = Approvals.live_card(post.id) || Approvals.latest_card(post.id)
    view = if card, do: Approvals.card_view(card.id, viewer), else: %{role: :viewer}
    actions = Map.get(view, :actions, [])
    media = media(post)

    {alt, flags} =
      split_alt(PlatformLimits.flags(account.platform, flag_input(post, media, account, profile)))

    %{
      post: post,
      account: account,
      profile: profile,
      card: card,
      canvas_id: card && card.canvas_id,
      role: Map.get(view, :role, :viewer),
      actions: actions,
      state: Map.get(view, :state),
      status: Map.get(view, :status),
      owner_name: Map.get(view, :owner_name),
      waiting?: Map.get(view, :waiting?, false),
      viewer_owner?: is_binary(Map.get(view, :posts_as)),
      edited_by: Map.get(view, :edited_by),
      cover: Map.get(view, :cover),
      fingerprint: Approvals.fingerprint(post),
      media: media,
      flags: flags,
      alt: alt,
      label: PlatformLimits.label(account.platform),
      tz: profile_tz(profile),
      next_slot: next_slot(actions, profile, post),
      # Only a human sees the post itself; anything else (an agent) gets
      # the status line, as on the chat card.
      content?: match?({:user, id} when is_binary(id), viewer)
    }
  end

  # Only offered when it is a different time from the suggested one.
  defp next_slot(actions, profile, post) do
    with true <- :approve in actions and profile != nil,
         %DateTime{} = at <- NextSlot.next_free(profile, post),
         false <- same_minute?(at, post.scheduled_at) do
      at
    else
      _ -> nil
    end
  end

  defp same_minute?(%DateTime{} = a, %DateTime{} = b),
    do: DateTime.to_unix(a) |> div(60) == DateTime.to_unix(b) |> div(60)

  defp same_minute?(_a, _b), do: false

  defp media(%Post{media_file_ids: ids, media_meta: meta} = post) do
    for id <- ids || [], file = Platform.Files.get_file(id), file != nil do
      facts = Map.get(meta || %{}, id) || %{}
      video? = String.starts_with?(file.content_type || "", "video/")

      %{
        # A frame cover is a media fragment on the video's src, as on the
        # chat card (task 01a165ec stage 4); an uploaded one is its poster.
        src: "/files/blob/#{id}" <> if(video?, do: fragment(post.cover_offset_ms), else: ""),
        content_type: file.content_type,
        width: facts["width"],
        height: facts["height"],
        duration_s: facts["duration_s"],
        byte_size: facts["byte_size"] || file.byte_size,
        poster: video? && post.cover_file_id && "/files/blob/#{post.cover_file_id}"
      }
    end
  end

  defp fragment(ms) when is_integer(ms) and rem(ms, 1000) == 0, do: "#t=#{div(ms, 1000)}"
  defp fragment(ms) when is_integer(ms), do: "#t=#{:erlang.float_to_binary(ms / 1000, [:short])}"
  defp fragment(_none), do: ""

  defp flag_input(post, media, account, profile) do
    %{
      body: post.body || "",
      title: nil,
      link_url: post.link_url,
      media: media,
      account: %{approval_mode: account.approval_mode, status: account.status},
      banned: banned(profile)
    }
  end

  # The profile's banned phrases (4/11), so a human sees the warning chip.
  defp banned(%Platform.Social.Profile{} = profile), do: Platform.Social.Voice.of(profile).banned
  defp banned(_profile), do: []

  defp split_alt(flags) do
    {alt, rest} = Enum.split_with(flags, &(&1.key == "missing_alt"))
    {Enum.map(alt, & &1.text), rest}
  end

  # The header: source chip, drafting agent, title and stage.
  defp header(%{idea: idea}, versions) do
    posts = Enum.map(versions, & &1.post)
    first = List.first(posts)

    kind =
      case idea do
        %{source_kind: kind} -> kind
        nil -> post_source(first)
      end

    {source, icon} = Map.get(@source_labels, kind, {"Idea", "hero-light-bulb-mini"})

    %{
      title: header_title(idea, versions),
      source: source,
      source_icon: icon,
      source_kind: kind,
      agent: agent_name(posts),
      stage: Map.get(@stage_labels, Ideas.stage(posts), "In review")
    }
  end

  defp header_title(%{title: title}, _versions) when is_binary(title), do: title

  defp header_title(nil, [v | _]), do: "#{v.label} post"
  defp header_title(nil, []), do: "Post"

  defp post_source(nil), do: "human"

  defp post_source(%Post{} = p) do
    cond do
      p.clip_id -> "clip"
      p.meeting_id -> "meeting"
      p.task_id -> "task"
      p.generated_by_agent_id -> "agent"
      true -> "human"
    end
  end

  defp agent_name(posts) do
    Enum.find_value(posts, fn post ->
      with id when is_binary(id) <- PostEvents.drafting_agent_id(post),
           %{name: name} when is_binary(name) and name != "" <-
             Repo.get(Platform.Agents.Agent, id) do
        name
      else
        _ -> nil
      end
    end)
  end

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("q_approve", params, socket) do
    decide(socket, params["post-id"], fn user, v ->
      Approvals.decide_approve(v.canvas_id, user, params["fingerprint"])
    end)
  end

  # The slot the human was SHOWN is re-derived now; a different answer is
  # refused rather than approving a time nobody saw.
  def handle_event("q_approve_slot", params, socket) do
    decide(socket, params["post-id"], fn user, v ->
      with {:ok, shown, _} <- DateTime.from_iso8601(params["slot"] || ""),
           %DateTime{} = now_slot <- v.next_slot || {:error, :slot_changed},
           true <- same_minute?(shown, now_slot) || {:error, :slot_changed} do
        Approvals.decide_approve_at(v.canvas_id, user, params["fingerprint"], now_slot)
      else
        {:error, _} = error -> error
        _ -> {:error, :slot_changed}
      end
    end)
  end

  def handle_event("q_edit_open", %{"post-id" => id}, socket),
    do: {:noreply, open_mode(socket, :edit, id, :edit, fn v -> v.post.body || "" end)}

  def handle_event("q_revise_open", %{"post-id" => id}, socket),
    do: {:noreply, open_mode(socket, :revise, id, :edit, fn _ -> "" end)}

  def handle_event("q_reject_open", %{"post-id" => id}, socket),
    do: {:noreply, open_mode(socket, :reject, id, :reject, fn _ -> "" end)}

  def handle_event("q_text", params, socket),
    do: {:noreply, assign(socket, text: params["text"] || "")}

  def handle_event("q_cancel", _params, socket),
    do: {:noreply, assign(socket, mode: nil, mode_post: nil, text: "")}

  def handle_event("q_edit_save", params, socket) do
    decide(socket, params["post-id"], fn user, v ->
      Approvals.decide_edit(
        v.canvas_id,
        user,
        %{body: params["text"] || ""},
        params["fingerprint"]
      )
    end)
  end

  def handle_event("q_reject_submit", params, socket) do
    decide(socket, params["post-id"], fn user, v ->
      Approvals.decide_reject(v.canvas_id, user, params["text"], params["fingerprint"])
    end)
  end

  def handle_event("q_revise_submit", params, socket) do
    decide(socket, params["post-id"], fn user, v ->
      org_id = v.profile && v.profile.org_id
      Ideas.request_revision(org_id, v.post.id, user.id, params["text"])
    end)
  end

  def handle_event("q_all_open", _params, socket),
    do: {:noreply, assign(socket, confirm_all?: length(socket.assigns.approvable) > 1)}

  def handle_event("q_all_cancel", _params, socket),
    do: {:noreply, assign(socket, confirm_all?: false)}

  # Each version through decide_approve/3 with the fingerprint THIS card
  # rendered for it (`fps`, "post_id:fingerprint" pairs). A version missing
  # from `fps` is not approved.
  def handle_event("q_all_confirm", params, socket) do
    shown = parse_fps(params["fps"])

    case fresh_user(socket) do
      nil ->
        {:noreply, socket |> put_notices(all_ids(socket), :not_an_approver) |> refresh()}

      user ->
        results =
          for v <- socket.assigns.approvable, Map.has_key?(shown, v.post.id) do
            {v.post.id, Approvals.decide_approve(v.canvas_id, user, Map.fetch!(shown, v.post.id))}
          end

        notices =
          Enum.reduce(results, socket.assigns.notices, fn
            {id, {:ok, _}}, acc -> Map.delete(acc, id)
            {id, {:error, reason}}, acc -> Map.put(acc, id, copy(reason, socket, id))
          end)

        ok = Enum.count(results, &match?({_, {:ok, _}}, &1))

        {:noreply,
         socket
         |> assign(notices: notices, confirm_all?: false, all_result: {ok, length(results)})
         |> refresh()}
    end
  end

  def handle_event("q_version", %{"index" => index}, socket) do
    index =
      case index do
        i when is_integer(i) -> i
        s when is_binary(s) -> String.to_integer(s)
      end

    {:noreply,
     assign(socket, current: index |> max(0) |> min(length(socket.assigns.versions) - 1))}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp open_mode(socket, mode, post_id, needed, initial) do
    case find(socket, post_id) do
      %{actions: actions} = v ->
        if needed in actions do
          assign(socket,
            mode: mode,
            mode_post: v.post.id,
            text: initial.(v),
            notices: Map.delete(socket.assigns.notices, v.post.id),
            current: Enum.find_index(socket.assigns.versions, &(&1.post.id == v.post.id))
          )
        else
          socket
        end

      nil ->
        socket
    end
  end

  # Re-read the user, find the version by the CLICKED post id among this
  # card's own versions, run the decision, reflect a refusal on the column.
  defp decide(socket, post_id, fun) do
    user = fresh_user(socket)
    v = find(socket, post_id)

    result =
      cond do
        is_nil(v) -> {:error, :not_found}
        is_nil(user) -> {:error, :not_an_approver}
        is_nil(v.canvas_id) -> {:error, :not_a_social_card}
        true -> fun.(user, v)
      end

    socket =
      case result do
        {:ok, _} ->
          assign(socket,
            mode: nil,
            mode_post: nil,
            text: "",
            notices: Map.delete(socket.assigns.notices, post_id)
          )

        {:error, reason} ->
          put_notices(socket, [post_id], reason)
      end

    {:noreply, refresh(socket)}
  end

  defp put_notices(socket, ids, reason) do
    notices = Enum.reduce(ids, socket.assigns.notices, &Map.put(&2, &1, copy(reason, socket, &1)))
    assign(socket, notices: notices)
  end

  defp all_ids(socket), do: Enum.map(socket.assigns.approvable, & &1.post.id)

  defp copy(reason, _socket, _post_id) when is_atom(reason) and is_map_key(@refusals, reason),
    do: Map.fetch!(@refusals, reason)

  defp copy(%Ecto.Changeset{}, _socket, _post_id),
    do: "That did not save. Check the text and try again."

  defp copy(reason, socket, post_id) do
    view =
      case find(socket, post_id) do
        %{owner_name: name} when is_binary(name) -> %{owner_name: name}
        _ -> %{}
      end

    PlatformWeb.SocialCardComponent.refusal_copy(reason, view)
  end

  defp find(socket, post_id), do: Enum.find(socket.assigns.versions, &(&1.post.id == post_id))

  defp fresh_user(socket) do
    case socket.assigns.viewer do
      {:user, id} -> Platform.Accounts.get_user(id)
      _ -> nil
    end
  end

  defp parse_fps(fps) when is_binary(fps) do
    fps
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, ":", parts: 2) do
        [id, fp] when id != "" and fp != "" -> [{id, fp}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp parse_fps(_), do: %{}

  @doc false
  # "post_id:fingerprint,..." for the versions Approve all would approve.
  def fps(versions), do: Enum.map_join(versions, ",", &"#{&1.post.id}:#{&1.fingerprint}")

  # ── Time ─────────────────────────────────────────────────────────────

  @doc """
  The profile's timezone, read the same way the Calendar reads it
  (`PlatformWeb.SocialCalendarClock.profile_zone/1`: 4/11's `timezone` when
  it is a known zone, else UTC), so the Queue and the Calendar agree.
  """
  @spec profile_tz(map() | nil) :: String.t()
  def profile_tz(profile), do: PlatformWeb.SocialCalendarClock.profile_zone(profile)

  @doc "\"Tue 28 Oct, 14:00 UTC\" in `tz`; \"Today, 14:00\" / \"Tomorrow, 09:00\" when near."
  @spec when_text(DateTime.t(), String.t(), DateTime.t()) :: String.t()
  def when_text(%DateTime{} = at, tz, now \\ DateTime.utc_now()) do
    local = DateTime.shift_zone!(at, tz)
    today = now |> DateTime.shift_zone!(tz) |> DateTime.to_date()

    day =
      case Date.diff(DateTime.to_date(local), today) do
        0 -> "Today"
        1 -> "Tomorrow"
        _ -> Calendar.strftime(local, "%a %-d %b")
      end

    "#{day}, #{Calendar.strftime(local, "%H:%M")} #{local.zone_abbr}"
  end

  @doc "\"14:00\" in `tz`."
  @spec clock(DateTime.t(), String.t()) :: String.t()
  def clock(%DateTime{} = at, tz),
    do: at |> DateTime.shift_zone!(tz) |> Calendar.strftime("%H:%M")

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cur, Enum.at(assigns.versions, assigns.current))

    ~H"""
    <article
      id={@id}
      data-role="queue-idea"
      data-idea={@group.key}
      data-focused={to_string(@focused?)}
      data-deep-link={to_string(@deep_link?)}
      class="rounded-2xl border border-edge bg-base-100 text-base-content shadow-sm"
    >
      <header class="space-y-1.5 px-4 pt-4 sm:px-5">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[13px] text-base-content/70">
          <span
            data-role="queue-source"
            data-source={@header.source_kind}
            class="inline-flex items-center gap-1 rounded-full border border-edge bg-base-200 px-2 py-0.5 font-medium text-base-content"
          >
            <.icon name={@header.source_icon} class="size-3.5" />
            {@header.source}
          </span>
          <span :if={@header.agent} data-role="queue-agent" class="inline-flex items-center gap-1">
            <.icon name="hero-sparkles-mini" class="size-3.5" /> Drafted by {@header.agent}
          </span>
          <span :if={(@show_brand? and @cur) && @cur.profile} data-role="queue-brand">
            · {@cur.profile.name}
          </span>
          <span data-role="queue-stage" class="badge badge-ghost badge-sm ml-auto font-medium">
            {@header.stage}
          </span>
        </div>
        <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
          <h3 data-role="queue-title" class="min-w-0 flex-1 text-lg font-semibold leading-snug">
            {@header.title}
          </h3>
          <button
            :if={length(@approvable) > 1 and not @confirm_all?}
            type="button"
            phx-click="q_all_open"
            phx-target={@myself}
            data-role="queue-approve-all"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-check-mini" class="size-4" /> Approve all {length(@approvable)}
          </button>
        </div>
        <p class="text-[13px] text-base-content/60" data-role="queue-count">
          {versions_line(@versions)}
        </p>
      </header>

      <.approve_all_confirm
        :if={@confirm_all?}
        approvable={@approvable}
        myself={@myself}
      />

      <p
        :if={@all_result}
        role="status"
        data-role="queue-all-result"
        class="mx-4 mt-3 rounded-lg bg-base-200 px-3 py-2 text-sm sm:mx-5"
      >
        {all_result_text(@all_result)}
      </p>

      <div
        id={"#{@id}-strip"}
        phx-hook="QueueSwipe"
        phx-target={@myself}
        data-current={@current}
        data-count={length(@versions)}
        data-role="queue-versions"
        tabindex="0"
        aria-label={"#{length(@versions)} versions. Use the arrow keys to move between them."}
        class="mt-3 flex snap-x snap-mandatory gap-4 overflow-x-auto scroll-smooth px-4 pb-4 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content sm:snap-none sm:px-5 sm:pb-5"
      >
        <.version_column
          :for={{v, i} <- Enum.with_index(@versions)}
          v={v}
          index={i}
          current?={i == @current}
          mode={if @mode_post == v.post.id, do: @mode}
          text={@text}
          notice={Map.get(@notices, v.post.id)}
          cover_controls={@cover_controls}
          myself={@myself}
        />
      </div>

      <.dots :if={length(@versions) > 1} versions={@versions} current={@current} />

      <.phone_bar
        :if={@cur}
        v={@cur}
        mode={@mode}
        myself={@myself}
        count={length(@versions)}
        index={@current}
      />
    </article>
    """
  end

  defp versions_line(versions) do
    labels = versions |> Enum.map(& &1.label) |> Enum.join(", ")

    case length(versions) do
      1 -> "1 version: #{labels}"
      n -> "#{n} versions: #{labels}"
    end
  end

  defp all_result_text({n, n}), do: "Approved #{n} of #{n}."
  defp all_result_text({ok, n}), do: "Approved #{ok} of #{n}. The others say why below."

  attr :approvable, :list, required: true
  attr :myself, :any, required: true

  # One confirm step: what goes out, where and when, then one button.
  defp approve_all_confirm(assigns) do
    ~H"""
    <div
      data-role="queue-approve-all-confirm"
      role="dialog"
      aria-label="Approve all"
      class="mx-4 mt-3 space-y-3 rounded-xl border border-primary/40 bg-base-200 p-3 sm:mx-5"
    >
      <p class="text-sm font-medium">Approve {length(@approvable)} posts?</p>
      <ul class="space-y-1 text-sm">
        <li :for={v <- @approvable} class="flex items-center gap-2" data-role="queue-approve-all-item">
          <SocialPreview.glyph platform={v.account.platform} class="size-4 shrink-0" />
          <span class="font-medium">{v.label}</span>
          <span class="truncate text-base-content/70">{v.account.handle}</span>
          <span class="ml-auto shrink-0 font-mono text-xs text-base-content/70">
            {if v.post.scheduled_at, do: when_text(v.post.scheduled_at, v.tz), else: "Now"}
          </span>
        </li>
      </ul>
      <div class="flex items-center gap-2">
        <button
          type="button"
          phx-click="q_all_cancel"
          phx-target={@myself}
          data-role="queue-approve-all-cancel"
          class="btn btn-ghost btn-sm"
        >
          Cancel
        </button>
        <button
          type="button"
          phx-click="q_all_confirm"
          phx-value-fps={fps(@approvable)}
          phx-target={@myself}
          phx-disable-with="Approving"
          data-role="queue-approve-all-go"
          class="btn btn-primary btn-sm ml-auto"
        >
          Approve {length(@approvable)}
        </button>
      </div>
    </div>
    """
  end

  attr :v, :map, required: true
  attr :index, :integer, required: true
  attr :current?, :boolean, default: false
  attr :mode, :atom, default: nil
  attr :text, :string, default: ""
  attr :notice, :string, default: nil
  attr :cover_controls, :boolean, default: false
  attr :myself, :any, required: true

  defp version_column(assigns) do
    ~H"""
    <section
      id={"#{@v.dom}-#{@v.post.id}"}
      data-role="queue-version"
      data-index={@index}
      data-platform={@v.account.platform}
      data-version-role={@v.role}
      data-current={to_string(@current?)}
      class="w-full shrink-0 snap-center space-y-3 sm:w-[400px]"
    >
      <p
        :if={not @v.content?}
        data-role="queue-status-only"
        class="rounded-lg border border-edge px-3 py-2 text-sm text-base-content/70"
      >
        {@v.label} · {(@v.status && @v.status.text) || "Needs approval"}
      </p>
      <SocialPreview.preview
        :if={@v.content?}
        id={"#{@v.dom}-preview-#{@v.post.id}"}
        platform={@v.account.platform}
        account={preview_account(@v)}
        body={if @mode == :edit, do: @text, else: @v.post.body || ""}
        media={@v.media}
        link_url={@v.post.link_url}
        cover={@v.post.cover_file_id && "/files/blob/#{@v.post.cover_file_id}"}
        viewer_owner?={@v.viewer_owner?}
        flags={@v.flags}
      />

      <.cover_control :if={@cover_controls and @v.cover} v={@v} />

      <p :if={@v.alt != []} data-role="queue-alt-note" class="text-xs text-base-content/60">
        {Enum.join(@v.alt, ", ")} (alt text comes later)
      </p>

      <div data-role="queue-when" class="rounded-lg bg-base-200 px-3 py-2 text-sm">
        <p class="flex items-center gap-1.5 font-medium">
          <.icon name="hero-clock-mini" class="size-4 shrink-0 text-base-content/70" />
          <span :if={@v.post.scheduled_at} data-role="queue-suggested">
            {when_text(@v.post.scheduled_at, @v.tz)}
          </span>
          <span :if={!@v.post.scheduled_at} data-role="queue-suggested">
            No time suggested: goes out when approved
          </span>
        </p>
        <p
          :if={present?(@v.post.schedule_reason)}
          data-role="queue-reason"
          class="mt-0.5 pl-[22px] text-[13px] text-base-content/70"
        >
          {@v.post.schedule_reason}
        </p>
      </div>

      <p
        :if={@v.status && @v.status.text != "Needs approval"}
        data-role="queue-status"
        data-tone={@v.status.tone}
        class={["text-sm font-medium", tone_class(@v.status.tone)]}
      >
        {@v.status.text}
        <a
          :if={@v.status[:external_url]}
          href={@v.status.external_url}
          target="_blank"
          rel="noopener noreferrer"
          class="link ml-1"
        >
          View post
        </a>
      </p>
      <p :if={@v.edited_by} data-role="queue-edited" class="text-[13px] text-base-content/60">
        Edited by {@v.edited_by}
      </p>

      <p
        :if={@notice}
        role="alert"
        data-role="queue-notice"
        class="rounded-lg border border-error/40 px-3 py-2 text-sm text-error"
      >
        {@notice}
      </p>

      <.mode_form :if={@mode} v={@v} mode={@mode} text={@text} myself={@myself} />

      <div
        :if={@v.role == :waiting and @v.waiting?}
        data-role="queue-waiting"
        class="flex items-center"
      >
        <span class="badge badge-info badge-sm font-medium">Waiting for {@v.owner_name}</span>
      </div>

      <.actions :if={@v.actions != [] and is_nil(@mode)} v={@v} myself={@myself} />
    </section>
    """
  end

  attr :v, :map, required: true

  # A video post's Cover control (task 01a165ec stage 4): opens the Queue
  # tab's picker (`cover_open`, untargeted, so the tab handles it).
  defp cover_control(assigns) do
    assigns =
      assign(assigns, :label, PlatformWeb.SocialCardComponent.cover_label(assigns.v.cover))

    ~H"""
    <button
      :if={@v.role == :approver and @v.cover.editable?}
      type="button"
      phx-click="cover_open"
      phx-value-post-id={@v.post.id}
      data-role="social-card-cover"
      data-cover-kind={@v.cover.kind}
      class="btn btn-ghost btn-sm -ml-2 px-2 text-[15px] font-normal"
    >
      <.icon name="hero-photo-mini" class="size-4" /> {@label}
    </button>
    <p
      :if={not (@v.role == :approver and @v.cover.editable?)}
      data-role="social-card-cover-label"
      data-cover-kind={@v.cover.kind}
      class="text-[15px] text-subtle"
    >
      {@label}
    </p>
    """
  end

  defp preview_account(v) do
    %{
      handle: v.account.handle,
      approval_mode: v.account.approval_mode,
      status: v.account.status,
      name: v.profile && v.profile.name,
      owner_name: v.owner_name
    }
  end

  attr :v, :map, required: true
  attr :myself, :any, required: true

  # Inline actions. On a phone, Approve / Revise / Reject live in the
  # sticky bar instead (max-sm:hidden here); Next slot and Edit stay.
  defp actions(assigns) do
    ~H"""
    <div data-role="queue-actions" class="flex flex-wrap items-center gap-2">
      <button
        :if={:approve in @v.actions}
        type="button"
        phx-click="q_approve"
        phx-value-post-id={@v.post.id}
        phx-value-fingerprint={@v.fingerprint}
        phx-target={@myself}
        phx-disable-with="Approving"
        data-role="queue-approve"
        class="btn btn-primary btn-sm max-sm:hidden"
      >
        {approve_label(@v)}
      </button>
      <button
        :if={:copy in @v.actions}
        type="button"
        id={"#{@v.dom}-copy-#{@v.post.id}"}
        phx-hook="CopyToClipboard"
        data-clipboard-text={@v.post.body}
        data-role="queue-copy"
        class="btn btn-primary btn-sm max-sm:hidden"
      >
        Copy text
      </button>
      <button
        :if={@v.next_slot}
        type="button"
        phx-click="q_approve_slot"
        phx-value-post-id={@v.post.id}
        phx-value-fingerprint={@v.fingerprint}
        phx-value-slot={DateTime.to_iso8601(@v.next_slot)}
        phx-target={@myself}
        phx-disable-with="Approving"
        data-role="queue-approve-slot"
        class="btn btn-outline btn-sm"
      >
        Next slot · {when_text(@v.next_slot, @v.tz)}
      </button>
      <button
        :if={:edit in @v.actions}
        type="button"
        phx-click="q_edit_open"
        phx-value-post-id={@v.post.id}
        phx-target={@myself}
        data-role="queue-edit"
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-pencil-square-mini" class="size-4" /> Edit
      </button>
      <button
        :if={:edit in @v.actions}
        type="button"
        phx-click="q_revise_open"
        phx-value-post-id={@v.post.id}
        phx-target={@myself}
        data-role="queue-revise"
        class="btn btn-ghost btn-sm max-sm:hidden"
      >
        <.icon name="hero-arrow-uturn-left-mini" class="size-4" /> Ask to revise
      </button>
      <button
        :if={:reject in @v.actions}
        type="button"
        phx-click="q_reject_open"
        phx-value-post-id={@v.post.id}
        phx-target={@myself}
        data-role="queue-reject"
        class="btn btn-ghost btn-sm text-error max-sm:hidden"
      >
        Reject
      </button>
    </div>
    """
  end

  defp approve_label(%{post: %{scheduled_at: %DateTime{} = at}, tz: tz}),
    do: "Approve · " <> when_text(at, tz)

  defp approve_label(_v), do: "Approve · now"

  attr :v, :map, required: true
  attr :mode, :atom, required: true
  attr :text, :string, default: ""
  attr :myself, :any, required: true

  defp mode_form(assigns) do
    assigns =
      assign(assigns,
        submit:
          %{edit: "q_edit_save", revise: "q_revise_submit", reject: "q_reject_submit"}[
            assigns.mode
          ],
        label:
          %{
            edit: "Post text",
            revise: "What should the agent change?",
            reject: "Why reject it?"
          }[assigns.mode],
        button: %{edit: "Save text", revise: "Ask to revise", reject: "Reject post"}[assigns.mode]
      )

    ~H"""
    <form
      id={"#{@v.dom}-form-#{@v.post.id}"}
      phx-change="q_text"
      phx-submit={@submit}
      phx-target={@myself}
      data-role={"queue-#{@mode}-form"}
      class="space-y-2"
    >
      <input type="hidden" name="post-id" value={@v.post.id} />
      <input type="hidden" name="fingerprint" value={@v.fingerprint} />
      <label class="block text-sm font-medium" for={"#{@v.dom}-text-#{@v.post.id}"}>{@label}</label>
      <textarea
        id={"#{@v.dom}-text-#{@v.post.id}"}
        name="text"
        rows={if @mode == :edit, do: 7, else: 3}
        maxlength={if @mode == :edit, do: nil, else: 2000}
        phx-debounce="150"
        phx-mounted={JS.focus()}
        class="textarea textarea-bordered w-full text-base"
      >{@text}</textarea>
      <div class="flex items-center gap-2">
        <button
          type="button"
          phx-click="q_cancel"
          phx-target={@myself}
          data-role="queue-form-cancel"
          class="btn btn-ghost btn-sm"
        >
          Cancel
        </button>
        <button
          type="submit"
          disabled={@mode != :edit and String.trim(@text) == ""}
          data-role="queue-form-submit"
          class={[
            "btn btn-sm ml-auto",
            if(@mode == :reject, do: "btn-error", else: "btn-primary")
          ]}
        >
          {@button}
        </button>
      </div>
    </form>
    """
  end

  attr :versions, :list, required: true
  attr :current, :integer, required: true

  # Which version is on screen (phone): a dot per version. Swipe or the
  # arrow keys move; the dots only show where you are.
  defp dots(assigns) do
    ~H"""
    <div
      data-role="queue-dots"
      aria-hidden="true"
      class="-mt-2 flex justify-center gap-1.5 pb-3 sm:hidden"
    >
      <span
        :for={{_v, i} <- Enum.with_index(@versions)}
        class={[
          "block size-2 rounded-full",
          if(i == @current, do: "bg-base-content", else: "bg-base-content/25")
        ]}
      >
      </span>
    </div>
    """
  end

  attr :v, :map, required: true
  attr :mode, :atom, default: nil
  attr :myself, :any, required: true
  attr :count, :integer, required: true
  attr :index, :integer, required: true

  # The phone's sticky bar: the version on screen, then Reject, Revise and
  # Approve at thumb reach. It sits on top of the app's bottom nav
  # (`--bottom-nav-height`, 0 where there is none) and the safe area. Only what card_view grants; nothing for a viewer.
  defp phone_bar(assigns) do
    ~H"""
    <div
      :if={is_nil(@mode) and (@v.actions != [] or (@v.role == :waiting and @v.waiting?))}
      data-role="queue-phone-bar"
      data-post={@v.post.id}
      class="fixed inset-x-0 bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))] z-30 border-t border-edge bg-base-100/95 px-3 pt-2 pb-3 shadow-lg backdrop-blur sm:hidden"
    >
      <p class="mb-2 flex items-center gap-1.5 text-[13px] text-base-content/70">
        <SocialPreview.glyph platform={@v.account.platform} class="size-3.5" />
        <span class="font-medium text-base-content">{@v.label}</span>
        <span :if={@count > 1}>· {@index + 1} of {@count}</span>
        <span class="ml-auto truncate">
          {if @v.post.scheduled_at, do: when_text(@v.post.scheduled_at, @v.tz), else: "Now"}
        </span>
      </p>
      <%= if @v.role == :waiting do %>
        <p class="pb-1 text-center">
          <span class="badge badge-info font-medium">Waiting for {@v.owner_name}</span>
        </p>
      <% else %>
        <div class="flex items-center gap-2">
          <button
            :if={:reject in @v.actions}
            type="button"
            phx-click="q_reject_open"
            phx-value-post-id={@v.post.id}
            phx-target={@myself}
            data-role="queue-bar-reject"
            aria-label="Reject"
            class="btn btn-ghost h-12 min-h-12 w-12 px-0 text-error"
          >
            <.icon name="hero-x-mark" class="size-6" />
          </button>
          <button
            :if={:edit in @v.actions}
            type="button"
            phx-click="q_revise_open"
            phx-value-post-id={@v.post.id}
            phx-target={@myself}
            data-role="queue-bar-revise"
            class="btn btn-outline h-12 min-h-12"
          >
            Revise
          </button>
          <button
            :if={:approve in @v.actions}
            type="button"
            phx-click="q_approve"
            phx-value-post-id={@v.post.id}
            phx-value-fingerprint={@v.fingerprint}
            phx-target={@myself}
            phx-disable-with="Approving"
            data-role="queue-bar-approve"
            class="btn btn-primary h-12 min-h-12 flex-1 text-base"
          >
            <.icon name="hero-check" class="size-5" /> Approve
          </button>
          <button
            :if={:copy in @v.actions}
            type="button"
            id={"#{@v.dom}-bar-copy-#{@v.post.id}"}
            phx-hook="CopyToClipboard"
            data-clipboard-text={@v.post.body}
            data-role="queue-bar-copy"
            class="btn btn-primary h-12 min-h-12 flex-1 text-base"
          >
            Copy text
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp tone_class(:success), do: "text-success"
  defp tone_class(:error), do: "text-error"
  defp tone_class(:warning), do: "text-base-content"
  defp tone_class(_), do: "text-base-content/70"

  defp present?(s), do: is_binary(s) and String.trim(s) != ""
end
