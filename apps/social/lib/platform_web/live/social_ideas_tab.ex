defmodule PlatformWeb.SocialIdeasTab do
  @moduledoc """
  The Ideas tab: one list of the scope's ideas in three views (All ideas,
  With votes, Selected for research), with quick add, a human "Select for
  research" action, and an idea detail (`PlatformWeb.SocialIdeaDetail`).

  ## One list, three views

  `Platform.Social.IdeaBoard.views/2` reads the active ideas once and their
  agent votes once, and derives the three views and their counts in memory.
  Only the current view's cards are rendered (a plain assign: a view is a
  filter of one list, and a second load before the first render must not keep
  the first's rows, as a stream reset would). No lane,
  stage or shortlist is shown: an idea's posts live in its detail, in Queue and
  in Calendar. `?tab=ideas&view=all|voted|selected` opens the right view. The
  board subscribes to `Platform.Social.Ideas.posts_topic/1` of every profile in
  scope and re-reads (after `:ideas_refresh_ms`, default 200).

  ## Who may change what

  Everyone who can open the profile in Social sees the list and the detail.

    * Select / Unselect: offered only to a viewer who passes the selection
      authority (`Platform.Social.Ideas.may_select?/2`). A click carries only
      an idea id; the acting user is `socket.assigns.user.id`, the id is
      re-found among the profiles in scope NOW (a forged id of another brand is
      "no longer here"), and `Ideas.select_for_research/3` decides again on
      locked rows.
    * Quick add, Draft it, Archive, notes and platform options: an approver of
      the idea's profile (`Platform.Social.approver_check/3`), re-checked on
      every write. The "Add what you find as a note" prompt is shown by the same
      predicate as the note writer's, so a selector who is not an approver never
      sees a prompt they cannot act on.

  ## Draft it

  Draft it lives in the idea's detail. While
  `PlatformWeb.SocialComposer.enabled?/0` is true it opens the composer on the
  idea; "Ask <agent> to draft" mentions the drafting agent in the profile's
  approval space (`Platform.Social.Ideas.ask_to_draft/3`).

  ## The view and brand are in the address

  Social is nested by `live_render/3`, which has no `push_patch` and no
  `handle_params`, and the page must not write history itself (a hook's
  `pushState` raced LiveView's own popstate handling and Back / Forward left
  the address and the page disagreeing). The three view controls are therefore
  ORDINARY LINKS (`<a href="?tab=ideas&view=..&profile=..">`, a full page load):
  the browser owns Back, Forward, reload and "open in a new tab", and
  `from_query/2` reads the address once at mount, with fresh server-side checks.
  The brand in each link is the scope SHOWN now (`profile=all` for All brands,
  else the shown brand's id), so the address after the next click is truthful
  even after the in-page brand switcher (which writes no address).

  `profile=all` is honoured HERE only (the other tabs keep reading `profile`
  as before): All brands for a viewer who can see more than one brand, else the
  usual fallback. An unknown or unauthorised brand id selects nothing, and the
  page shows the default brand; the links then carry that brand.

  ## Phone

  The three view links stay on one row with short labels ("All", "Votes",
  "Selected") whose full names are their accessible names. The detail is a full
  screen (a right-hand drawer from sm up). `?tab=ideas&idea=<id>` opens an idea.
  """

  use PlatformWeb.SocialTab

  alias Platform.Social
  alias Platform.Social.{Idea, IdeaBoard, IdeaNotes, Ideas, Profile}
  alias PlatformWeb.{SocialIdeaDetail, SocialScope}

  @view_labels %{
    "all" => "All ideas",
    "voted" => "With votes",
    "selected" => "Selected for research"
  }
  @view_short %{"all" => "All", "voted" => "Votes", "selected" => "Selected"}

  @empty_copy %{
    "all" => "No ideas yet. Add one, or ask an agent for theirs.",
    "voted" => "No idea has a vote yet. Agents vote on each other's ideas; counts appear here.",
    "selected" =>
      "Nothing selected yet. Open All ideas and choose Select for research on one worth exploring."
  }

  @events ~w(ideas_vote ideas_open ideas_close ideas_quick_open ideas_quick_cancel
             ideas_quick_save ideas_select ideas_unselect ideas_ask_draft ideas_compose
             ideas_archive ideas_note_save ideas_options_save)

  @impl true
  def enabled?, do: true

  @impl true
  def all_brands?, do: true

  @impl true
  def events, do: @events

  @doc "The view keys, in button order."
  def views, do: IdeaBoard.views()

  @impl true
  def init(socket) do
    socket
    |> assign(:ideas_cards, [])
    |> assign(:ideas_view, "all")
    |> assign(:ideas_counts, Map.new(views(), &{&1, 0}))
    |> assign(:ideas_topics, [])
    |> assign(:ideas_profiles, [])
    |> assign(:ideas_can_add?, false)
    |> assign(:ideas_quick?, false)
    |> assign(:ideas_quick_form, quick_form())
    |> assign(:ideas_open, nil)
    |> assign(:ideas_detail, nil)
    |> assign(:ideas_notice, nil)
    |> assign(:ideas_announcement, nil)
    |> assign(:ideas_announce_seq, 0)
    |> assign(:ideas_note_form, note_form())
    |> assign(:ideas_options_errors, %{})
    |> assign(:ideas_rev, 0)
    |> assign(:ideas_refresh_pending?, false)
  end

  # ── Load ─────────────────────────────────────────────────────────────

  # The scope's ideas, derived into the three views and the current view
  # re-streamed with `reset: true`; the open idea (if any) re-read with them.
  @impl true
  def load(socket) do
    profiles = scope_profiles(socket)
    user_id = user_id(socket)
    writers = Map.new(profiles, &{&1.id, writer?(socket, &1)})
    selectors = Map.new(profiles, &{&1.id, Ideas.may_select?(&1, user_id)})

    views = IdeaBoard.views(profiles, user_id)

    cards =
      views
      |> Map.fetch!(String.to_existing_atom(socket.assigns.ideas_view))
      |> Enum.map(fn card ->
        pid = card.idea.profile_id

        card
        |> Map.put(:can_write?, Map.get(writers, pid, false))
        |> Map.put(:can_select?, Map.get(selectors, pid, false))
      end)

    socket
    |> assign(:ideas_cards, cards)
    |> subscribe(profiles)
    |> assign(:ideas_profiles, profiles)
    |> assign(:ideas_counts, views.counts)
    |> assign(:ideas_can_add?, can_add?(socket))
    |> assign(:ideas_rev, socket.assigns.ideas_rev + 1)
    |> load_detail()
  end

  # One brand: that profile (if still visible). All brands: every visible one.
  defp scope_profiles(socket) do
    visible = SocialScope.visible_profiles(socket)

    case socket.assigns[:scope] do
      :all -> visible
      {:profile, %Profile{id: id}} -> Enum.filter(visible, &(&1.id == id))
      _ -> []
    end
  end

  defp user_id(%{assigns: %{user: %{id: id}}}), do: id
  defp user_id(_socket), do: nil

  defp can_add?(%{assigns: %{scope: {:profile, %Profile{}}}} = socket),
    do: match?({:ok, _, _}, authorize(socket))

  defp can_add?(_socket), do: false

  defp subscribe(socket, profiles) do
    topics = Enum.map(profiles, &Ideas.posts_topic(&1.id))

    if connected?(socket) do
      old = socket.assigns.ideas_topics
      Enum.each(old -- topics, &Phoenix.PubSub.unsubscribe(Platform.PubSub, &1))
      Enum.each(topics -- old, &Phoenix.PubSub.subscribe(Platform.PubSub, &1))
      assign(socket, :ideas_topics, topics)
    else
      socket
    end
  end

  defp load_detail(%{assigns: %{ideas_open: nil}} = socket),
    do: assign(socket, :ideas_detail, nil)

  defp load_detail(socket) do
    case IdeaBoard.detail(
           socket.assigns.ideas_profiles,
           socket.assigns.ideas_open,
           user_id(socket)
         ) do
      nil ->
        socket |> assign(:ideas_open, nil) |> assign(:ideas_detail, nil)

      detail ->
        assign(
          socket,
          :ideas_detail,
          detail
          |> Map.put(:can_write?, writer?(socket, detail.profile))
          |> Map.put(:can_select?, Ideas.may_select?(detail.profile, user_id(socket)))
        )
    end
  end

  # Approver of `profile`, re-read now.
  defp writer?(socket, %Profile{} = profile) do
    with id when is_binary(id) <- user_id(socket),
         %Profile{} = fresh <- Social.get_profile(profile.org_id, profile.id) do
      Social.approver_check(fresh.org_id, fresh, id) == :ok
    else
      _ -> false
    end
  end

  @impl true
  def on_select(%{assigns: %{tab: "ideas"}} = socket), do: load(socket)
  def on_select(socket), do: socket

  # `?tab=ideas&view=all|voted|selected` picks the view (an unknown view is All);
  # `&profile=all` selects All brands (see `all_brands_requested?/2`); `&idea=<id>`
  # opens that idea's detail, if it is in scope.
  @impl true
  def from_query(socket, %{"tab" => "ideas"} = query) do
    socket =
      if all_brands_requested?(socket, query), do: SocialScope.select_all(socket), else: socket

    view = if query["view"] in views(), do: query["view"], else: "all"

    socket =
      if view != socket.assigns.ideas_view,
        do: socket |> assign(:ideas_view, view) |> load(),
        else: socket

    case query["idea"] do
      id when is_binary(id) -> socket |> assign(:ideas_open, id) |> load_detail()
      _ -> socket
    end
  end

  def from_query(socket, _query), do: socket

  @doc """
  Opens idea `idea_id` on the Ideas tab (the Calendar's click on an idea's
  post). `{:ok, socket}` when the idea is in scope, else `:error`.
  """
  @spec open_idea(Phoenix.LiveView.Socket.t(), term()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | :error
  def open_idea(socket, idea_id) when is_binary(idea_id) do
    socket = socket |> assign(:ideas_open, idea_id) |> SocialScope.select_tab("ideas")

    if socket.assigns.ideas_detail && socket.assigns.tab == "ideas",
      do: {:ok, socket},
      else: :error
  end

  def open_idea(_socket, _idea_id), do: :error

  # ── Events ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("ideas_vote", %{"id" => _id, "action" => action}, socket)
      when action in ~w(vote unvote) do
    {:noreply, socket |> say("Only agents can vote on ideas.", :warning) |> load()}
  end

  def handle_event("ideas_select", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, set_selection(socket, id, :select)}

  def handle_event("ideas_unselect", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, set_selection(socket, id, :unselect)}

  def handle_event("ideas_open", %{"id" => id}, socket) when is_binary(id) do
    socket =
      socket
      |> assign(:ideas_open, id)
      |> assign(:ideas_notice, nil)
      |> assign(:ideas_quick?, false)
      |> assign(:ideas_note_form, note_form())
      |> assign(:ideas_options_errors, %{})
      |> load_detail()

    {:noreply, socket}
  end

  def handle_event("ideas_close", _params, socket),
    do: {:noreply, socket |> assign(:ideas_open, nil) |> assign(:ideas_detail, nil)}

  def handle_event("ideas_quick_open", _params, socket),
    do:
      {:noreply, socket |> assign(:ideas_quick?, true) |> assign(:ideas_quick_form, quick_form())}

  def handle_event("ideas_quick_cancel", _params, socket),
    do: {:noreply, assign(socket, :ideas_quick?, false)}

  def handle_event("ideas_quick_save", %{"idea" => params}, socket) when is_map(params) do
    attrs = %{
      "title" => params["title"],
      "brief" => blank_to_nil(params["brief"] || ""),
      "source_kind" => "human"
    }

    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, _idea} <- Ideas.create(profile.org_id, profile.id, attrs, {:user, user_id}) do
      {:noreply,
       socket
       |> assign(:ideas_quick?, false)
       |> assign(:ideas_quick_form, quick_form())
       |> assign(:ideas_announcement, nil)
       |> load()
       |> say_added()}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(
           socket,
           :ideas_quick_form,
           to_form(Map.put(changeset, :action, :insert), as: :idea)
         )}

      _ ->
        {:noreply,
         socket |> assign(:ideas_quick?, false) |> say("Only approvers can add ideas.", :warning)}
    end
  end

  def handle_event("ideas_ask_draft", %{"id" => id}, socket) do
    socket =
      case with_idea(socket, id, fn org_id, user_id -> Ideas.ask_to_draft(org_id, id, user_id) end) do
        {:ok, %{agent_name: name}} -> say(socket, "Asked #{name} to draft it.", :info)
        {:error, reason} -> say(socket, refusal(reason), :warning)
      end

    {:noreply, load_detail(socket)}
  end

  # "Draft it" with the composer on: the composer opens on this idea
  # (`PlatformWeb.SocialComposer.open_idea/1`) once the idea is re-found in
  # scope and the viewer is an approver of its brand; the drawer closes so
  # the composer is on top.
  def handle_event("ideas_compose", %{"id" => id}, socket) do
    with true <- PlatformWeb.SocialComposer.enabled?(),
         %Idea{} = idea <- IdeaBoard.find_idea(scope_profiles(socket), id),
         %Profile{} = profile <- Enum.find(scope_profiles(socket), &(&1.id == idea.profile_id)),
         true <- writer?(socket, profile) do
      PlatformWeb.SocialComposer.open_idea(idea.id)
      {:noreply, socket |> assign(:ideas_open, nil) |> assign(:ideas_detail, nil)}
    else
      _ -> {:noreply, say(socket, refusal(:not_an_approver), :warning)}
    end
  end

  def handle_event("ideas_archive", %{"id" => id}, socket) do
    case with_idea(socket, id, fn org_id, user_id ->
           Ideas.archive_by_human(org_id, id, user_id)
         end) do
      {:ok, _idea} ->
        {:noreply,
         socket
         |> assign(:ideas_open, nil)
         |> say("Idea archived.", :info)
         |> load()}

      {:error, reason} ->
        {:noreply, socket |> say(refusal(reason), :warning) |> load_detail()}
    end
  end

  def handle_event("ideas_note_save", %{"note" => %{"body" => body}}, socket) do
    id = socket.assigns.ideas_open

    case with_idea(socket, id, fn org_id, user_id ->
           IdeaNotes.add(org_id, id, {:human, user_id}, body)
         end) do
      {:ok, _note} ->
        {:noreply, socket |> assign(:ideas_note_form, note_form()) |> load_detail()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:ideas_note_form, note_form(body, refusal(reason)))
         |> load_detail()}
    end
  end

  def handle_event("ideas_options_save", %{"post_id" => post_id} = params, socket) do
    options = Map.get(params, "options", %{})

    result =
      with %{profile: profile, posts: posts} <- socket.assigns.ideas_detail,
           true <- Enum.any?(posts, &(&1.id == post_id)) || {:error, :not_found},
           user_id when is_binary(user_id) <- user_id(socket) do
        Social.set_platform_options(profile.org_id, user_id, post_id, options)
      else
        {:error, _} = error -> error
        _ -> {:error, :not_found}
      end

    socket =
      case result do
        {:ok, _post} ->
          socket
          |> assign(
            :ideas_options_errors,
            Map.delete(socket.assigns.ideas_options_errors, post_id)
          )
          |> load_detail()

        {:error, {:invalid_options, errors}} ->
          assign(
            socket,
            :ideas_options_errors,
            Map.put(socket.assigns.ideas_options_errors, post_id, errors)
          )

        {:error, reason} ->
          socket
          |> assign(
            :ideas_options_errors,
            Map.put(socket.assigns.ideas_options_errors, post_id, %{"_" => refusal(reason)})
          )
          |> load_detail()
      end

    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # `profile=all` (this tab's own reading of the address): All brands, but only
  # for a viewer who can see more than one brand right now; otherwise the usual
  # `profile` handling stands (a single-brand viewer's `all` selects nothing).
  defp all_brands_requested?(socket, query) do
    (query["profile"] || query["profile_id"]) == "all" and
      match?([_, _ | _], SocialScope.visible_profiles(socket))
  end

  # The brand segment of a view link: what is SHOWN now.
  defp scope_param(%{scope: :all}), do: "all"
  defp scope_param(%{scope: {:profile, %Profile{id: id}}}), do: id
  defp scope_param(_assigns), do: nil

  defp view_href(assigns, view) do
    params =
      [tab: "ideas", view: view] ++ if(p = scope_param(assigns), do: [profile: p], else: [])

    "?" <> URI.encode_query(params)
  end

  # One click. The acting user is the session's; the client supplies only an
  # idea id, which is re-found among the profiles in scope now (so a forged id of
  # another brand or org is not found). The writer decides again under its locks.
  defp set_selection(socket, id, op) do
    result =
      with user_id when is_binary(user_id) <- user_id(socket) || {:error, :not_authorized},
           %Idea{} = idea <-
             IdeaBoard.find_idea(scope_profiles(socket), id) || {:error, :not_found} do
        case op do
          :select -> Ideas.select_for_research(idea.org_id, idea.id, {:user, user_id})
          :unselect -> Ideas.unselect_for_research(idea.org_id, idea.id, {:user, user_id})
        end
      end

    case result do
      {:ok, _idea, _how} ->
        before = socket.assigns.ideas_cards

        socket
        |> assign(:ideas_notice, nil)
        |> announce(if(op == :select, do: "Selected for research", else: "Unselected"))
        |> load()
        |> then(&push_focus(&1, focus_target(before, &1.assigns.ideas_cards, id)))

      {:error, reason} ->
        socket |> say(refusal(reason), :warning) |> load()
    end
  end

  defp announce(socket, text) do
    socket
    |> assign(:ideas_announcement, text)
    |> assign(:ideas_announce_seq, socket.assigns.ideas_announce_seq + 1)
  end

  defp push_focus(socket, id), do: Phoenix.LiveView.push_event(socket, "ideas:focus", %{id: id})

  # Where focus goes after a Select / Unselect of `id` re-read the list: the
  # row's own control (now the opposite button) while the row is still listed;
  # when the row left the view, the next row's control, else the row before it,
  # else the view heading (the list is empty).
  defp focus_target(before, after_cards, id) do
    case Enum.find(after_cards, &(&1.id == id)) do
      %{} = card ->
        control_id(card)

      nil ->
        remaining = MapSet.new(after_cards, & &1.id)
        {head, tail} = Enum.split_while(before, &(&1.id != id))
        tail = Enum.drop(tail, 1)

        survivor =
          Enum.find(tail, &(&1.id in remaining)) ||
            head |> Enum.reverse() |> Enum.find(&(&1.id in remaining))

        case survivor && Enum.find(after_cards, &(&1.id == survivor.id)) do
          %{} = card -> control_id(card)
          _ -> "ideas-view-heading"
        end
    end
  end

  defp control_id(%{can_select?: true, selected?: true, id: id}), do: "idea-unselect-#{id}"
  defp control_id(%{can_select?: true, id: id}), do: "idea-select-#{id}"
  defp control_id(%{id: id}), do: "idea-open-#{id}"

  # The idea re-found among the profiles in scope NOW, then `fun` with its
  # org and the viewer's id (the context re-checks the approver).
  defp with_idea(socket, id, fun) do
    profiles = scope_profiles(socket)

    with %Idea{} = idea <- IdeaBoard.find_idea(profiles, id) || {:error, :not_found},
         user_id when is_binary(user_id) <- user_id(socket) || {:error, :not_an_approver} do
      fun.(idea.org_id, user_id)
    end
  end

  defp say(socket, text, tone), do: assign(socket, :ideas_notice, {text, tone})

  # A new idea lands in All ideas; from another view the viewer is told so
  # (the view is not switched: the address names the view, and only a link changes it).
  defp say_added(%{assigns: %{ideas_view: "all"}} = socket), do: socket
  defp say_added(socket), do: say(socket, "Idea added to All ideas.", :info)

  defp refusal(:not_an_approver), do: "Only approvers of this brand can do that."
  defp refusal(:not_found), do: "That idea is no longer here."
  defp refusal(:own_idea), do: "You cannot vote for your own idea."

  defp refusal(reason) when reason in [:not_authorized, :not_a_human],
    do: "You can't select ideas for research in this brand."

  defp refusal(:idea_archived), do: "This idea is archived."
  defp refusal(:has_published), do: "An idea with a published post can't be archived."

  defp refusal(:no_drafting_agent),
    do: "No drafting agent is set. Choose one in Settings, then ask again."

  defp refusal(:profile_has_no_channel),
    do: "This brand has no approval channel, so the agent can't be asked."

  defp refusal(:body_required), do: "Write a note first."
  defp refusal(:body_too_long), do: "Keep the note under 4,000 characters."
  defp refusal(:post_locked), do: "This version is past approval, so its options are fixed."
  defp refusal(:not_the_owner), do: "Only the account's owner can change this version."
  defp refusal(_), do: "That didn't work. Try again."

  # ── Live updates ─────────────────────────────────────────────────────

  @impl true
  def handle_info({:social_ideas_changed, profile_id}, socket) do
    if Ideas.posts_topic(profile_id) in socket.assigns.ideas_topics,
      do: {:noreply, schedule_refresh(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:ideas_refresh, socket),
    do: {:noreply, socket |> assign(:ideas_refresh_pending?, false) |> load()}

  def handle_info(_message, _socket), do: :unhandled

  # Coalesces a burst of entries into one re-read. A delay of 0 re-reads
  # now (tests).
  defp schedule_refresh(socket) do
    case Application.get_env(:social, :ideas_refresh_ms, 200) do
      0 ->
        load(socket)

      ms ->
        if socket.assigns.ideas_refresh_pending? do
          socket
        else
          Process.send_after(self(), :ideas_refresh, ms)
          assign(socket, :ideas_refresh_pending?, true)
        end
    end
  end

  # ── Forms ────────────────────────────────────────────────────────────

  defp quick_form, do: to_form(%{"title" => "", "brief" => ""}, as: :idea)

  defp note_form(body \\ "", error \\ nil) do
    errors = if error, do: [body: {error, []}], else: []
    to_form(%{"body" => body}, as: :note, errors: errors)
  end

  # ── Render ───────────────────────────────────────────────────────────

  @impl true
  def pane(assigns) do
    assigns =
      assign(assigns,
        all?: assigns.scope == :all,
        view_items:
          Enum.map(
            views(),
            &%{
              key: &1,
              label: @view_labels[&1],
              short: @view_short[&1],
              href: view_href(assigns, &1)
            }
          ),
        all_ideas_href: view_href(assigns, "all"),
        empty_copy: @empty_copy,
        view_labels: @view_labels
      )

    ~H"""
    <div
      id="social-ideas"
      phx-hook="SocialIdeas"
      data-role="social-ideas"
      class="mx-auto w-full max-w-3xl space-y-4 pb-8"
    >
      <p
        id="ideas-announcer"
        role="status"
        aria-live="polite"
        data-role="ideas-announcement"
        class="sr-only"
      >
        <span :if={@ideas_announcement} id={"ideas-announcement-#{@ideas_announce_seq}"}>
          {@ideas_announcement}
        </span>
      </p>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 space-y-1">
          <h2 class="text-xl font-semibold" data-role="ideas-heading">Ideas</h2>
          <p class="text-sm text-subtle">Agents vote. People select ideas for research.</p>
        </div>
        <button
          :if={@ideas_can_add? and not @ideas_quick?}
          type="button"
          phx-click="ideas_quick_open"
          data-role="ideas-quick-open"
          class="btn btn-primary btn-sm min-h-11 shrink-0"
        >
          <.icon name="hero-plus-mini" class="size-4" />
          <span class="max-sm:sr-only">Add idea</span>
        </button>
      </div>

      <div data-role="ideas-quick-add">
        <.quick_add :if={@ideas_quick?} form={@ideas_quick_form} />
        <p
          :if={@all? and not @ideas_quick?}
          class="text-xs text-base-content"
          data-role="ideas-quick-pick-brand"
        >
          Pick a brand to add an idea.
        </p>
      </div>

      <p
        :if={@ideas_notice && is_nil(@ideas_detail)}
        role="status"
        data-role="ideas-notice"
        data-tone={elem(@ideas_notice, 1)}
        class="rounded-lg bg-base-200 px-3 py-2 text-sm"
      >
        {elem(@ideas_notice, 0)}
      </p>

      <nav
        aria-label="Idea views"
        data-role="ideas-view-control"
        class="grid grid-cols-3 gap-1 rounded-lg border border-base-300 bg-base-200 p-1"
      >
        <a
          :for={item <- @view_items}
          href={item.href}
          aria-current={if @ideas_view == item.key, do: "page"}
          aria-label={"#{item.label} #{@ideas_counts[item.key]}"}
          data-role="ideas-view-tab"
          data-view={item.key}
          class={[
            "flex min-h-11 items-center justify-center gap-1.5 rounded-md px-1 text-sm leading-tight",
            if(@ideas_view == item.key,
              do: "bg-base-100 font-semibold text-base-content shadow-sm",
              else: "text-base-content"
            )
          ]}
        >
          <span class="sm:hidden">{item.short}</span>
          <span class="hidden sm:inline">{item.label}</span>
          <span class="tabular-nums" data-role="ideas-view-count">{@ideas_counts[item.key]}</span>
        </a>
      </nav>

      <h3
        id="ideas-view-heading"
        tabindex="-1"
        data-role="ideas-view-heading"
        class="text-sm font-semibold focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
      >
        {@view_labels[@ideas_view]}
      </h3>

      <div
        :if={@ideas_counts[@ideas_view] == 0}
        data-role="ideas-empty"
        data-view={@ideas_view}
        class="rounded-xl border border-dashed border-base-300 px-3 py-6 text-center text-sm text-base-content"
      >
        <p>{@empty_copy[@ideas_view]}</p>
        <a
          :if={@ideas_view == "selected"}
          href={@all_ideas_href}
          data-role="ideas-empty-all"
          class="btn btn-ghost btn-sm mt-2 min-h-11"
        >
          Open All ideas
        </a>
      </div>

      <ul
        id="ideas-list"
        class="space-y-2"
        data-role="ideas-list"
        data-view={@ideas_view}
      >
        <li :for={card <- @ideas_cards} id={"idea-card-#{card.id}"}>
          <.idea_card card={card} show_brand?={@all?} />
        </li>
      </ul>
    </div>
    """
  end

  attr(:form, :any, required: true)

  defp quick_add(assigns) do
    ~H"""
    <.form
      for={@form}
      id="ideas-quick-form"
      phx-submit="ideas_quick_save"
      data-role="ideas-quick-form"
      class="space-y-2 rounded-xl border border-base-300 bg-base-100 p-3"
    >
      <.input
        field={@form[:title]}
        type="text"
        label="Idea"
        placeholder="In a few words"
        maxlength="200"
        required
        autofocus
      />
      <.input
        field={@form[:brief]}
        type="textarea"
        label="Brief (optional)"
        placeholder="What should the posts say?"
        rows="3"
      />
      <div class="flex items-center justify-end gap-2">
        <button
          type="button"
          class="btn btn-ghost btn-sm min-h-11"
          phx-click="ideas_quick_cancel"
          data-role="ideas-quick-cancel"
        >
          Cancel
        </button>
        <button type="submit" class="btn btn-primary btn-sm min-h-11" data-role="ideas-quick-save">
          Add idea
        </button>
      </div>
    </.form>
    """
  end

  attr(:card, :map, required: true)
  attr(:show_brand?, :boolean, default: false)

  defp idea_card(assigns) do
    ~H"""
    <article
      data-role="idea-card"
      data-idea-id={@card.id}
      data-selected={to_string(@card.selected?)}
      class="rounded-xl border border-base-300 bg-base-100 text-base-content shadow-sm"
    >
      <div
        data-role="idea-card-row"
        class="flex flex-col gap-2 p-3 sm:flex-row sm:items-start sm:gap-3"
      >
        <div data-role="idea-card-content" class="flex w-full min-w-0 items-start gap-3 sm:flex-1">
          <span
            data-role="idea-vote-count"
            class="mt-0.5 min-w-8 shrink-0 text-center text-sm font-semibold tabular-nums"
          >
            <span aria-hidden="true">▲ {@card.vote_count}</span>
            <span class="sr-only">
              {@card.vote_count} {if @card.vote_count == 1, do: "agent vote", else: "agent votes"}
            </span>
          </span>

          <div class="min-w-0 flex-1 space-y-1">
            <button
              id={"idea-open-#{@card.id}"}
              type="button"
              phx-click="ideas_open"
              phx-value-id={@card.id}
              data-role="idea-card-open"
              data-href={"?tab=ideas&idea=#{@card.id}"}
              class="block w-full min-h-11 text-left font-semibold leading-snug break-words hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
            >
              <span data-role="idea-card-title">{@card.idea.title}</span>
            </button>

            <p class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content">
              <span data-role="idea-card-agent">{@card.creator_name}</span>
              <span aria-hidden="true">·</span>
              <time data-role="idea-card-date" datetime={DateTime.to_iso8601(@card.idea.inserted_at)}>
                {Calendar.strftime(@card.idea.inserted_at, "%-d %b")}
              </time>
              <span :if={@show_brand? and @card.profile} class="contents">
                <span aria-hidden="true">·</span>
                <span data-role="idea-card-brand" class="font-semibold">{@card.profile.name}</span>
              </span>
              <span
                :if={@card.wikipedia?}
                data-role="idea-wikipedia-source"
                class="badge badge-primary badge-outline badge-sm"
              >
                <.icon name="hero-globe-alt-micro" class="size-3.5" /> From Wikipedia
              </span>
            </p>

            <p
              :if={@card.selected?}
              class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm"
              data-role="idea-selection"
            >
              <span data-role="idea-selected-by" class="font-medium">
                <.icon name="hero-star-solid" class="size-4" />
                Selected for research by {@card.selected_by_name}
              </span>
              <span data-role="idea-notes-count" class="text-xs">
                {@card.notes_count} {if @card.notes_count == 1, do: "note", else: "notes"}
              </span>
            </p>

            <button
              :if={@card.selected? and @card.can_write?}
              type="button"
              phx-click="ideas_open"
              phx-value-id={@card.id}
              data-role="idea-research-prompt"
              class="link min-h-11 text-left text-sm"
            >
              Add what you find as a note
            </button>
          </div>
        </div>

        <div :if={@card.can_select?} data-role="idea-actions" class="shrink-0 max-sm:w-full">
          <button
            :if={not @card.selected?}
            id={"idea-select-#{@card.id}"}
            type="button"
            phx-click="ideas_select"
            phx-value-id={@card.id}
            phx-disable-with="Selecting"
            data-role="idea-select"
            class="btn btn-sm btn-outline min-h-11 max-sm:w-full"
          >
            Select for research
          </button>
          <button
            :if={@card.selected?}
            id={"idea-unselect-#{@card.id}"}
            type="button"
            phx-click="ideas_unselect"
            phx-value-id={@card.id}
            phx-disable-with="Unselecting"
            data-role="idea-unselect"
            class="btn btn-sm btn-ghost min-h-11 max-sm:w-full"
          >
            Unselect
          </button>
        </div>
      </div>
    </article>
    """
  end

  # ── Detail overlay ───────────────────────────────────────────────────

  @impl true
  def overlay(%{tab: "ideas", ideas_detail: %{}} = assigns) do
    assigns = assign(assigns, :composer?, PlatformWeb.SocialComposer.enabled?())

    ~H"""
    <SocialIdeaDetail.drawer
      detail={@ideas_detail}
      user={@user}
      rev={@ideas_rev}
      notice={@ideas_notice}
      note_form={@ideas_note_form}
      options_errors={@ideas_options_errors}
      composer?={@composer?}
    />
    """
  end

  def overlay(assigns), do: PlatformWeb.SocialTab.nothing(assigns)
end
