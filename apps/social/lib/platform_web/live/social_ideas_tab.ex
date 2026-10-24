defmodule PlatformWeb.SocialIdeasTab do
  @moduledoc """
  The Ideas tab (Social authoring 7/11, task 01a16c50-ea67): a board of
  the scope's ideas in five lanes, Inbox → Drafting → In review →
  Scheduled → Live, with quick add, and an idea detail
  (`PlatformWeb.SocialIdeaDetail`).

  ## Lanes are derived

  A card's lane is `Platform.Social.Ideas.stage/1` of its posts, read by
  `Platform.Social.IdeaBoard`. Nothing is stored and nothing is dragged:
  an idea moves when its posts move. Each lane is a LiveView stream,
  re-streamed with `reset: true` on every load. The board subscribes to
  `Platform.Social.Ideas.posts_topic/1` of every profile in scope, and
  every change-log entry, new idea, archive or note there re-reads it
  (after `:ideas_refresh_ms`, default 200, because a change-log entry is
  broadcast from inside its transaction).

  ## Who may change what

  Everyone who can open the profile in Social sees the board and the
  detail. Quick add, Draft it, Archive, notes and platform options are
  offered only to an approver of the idea's profile
  (`Platform.Social.approver_check/3`), and every write re-checks it
  server-side on a fresh read; the version actions are the shared
  `PlatformWeb.SocialIdeaCard`'s, checked there.

  ## Draft it

  An Inbox idea has "Draft it". While `PlatformWeb.SocialComposer.enabled?/0`
  is true it opens the composer (6/11) on the idea
  (`PlatformWeb.SocialComposer.open_idea/1`, prefilled, sending joins the
  idea). "Ask <agent> to draft" sits beside it (and is the only offer while
  the composer is off): `Platform.Social.Ideas.ask_to_draft/3`, one mention
  of the drafting agent in the profile's approval space.

  ## Phone

  Below sm the lanes become a segmented control, one lane per screen; the
  detail is a full screen (a right-hand drawer from sm up).
  `?tab=ideas&idea=<id>` opens straight onto an idea.
  """

  use PlatformWeb.SocialTab

  alias Platform.Social
  alias Platform.Social.{Idea, IdeaBoard, IdeaNotes, Ideas, Profile}
  alias PlatformWeb.{SocialIdeaDetail, SocialPreview, SocialScope}

  @lane_labels %{
    "inbox" => "Inbox",
    "drafting" => "Drafting",
    "in_review" => "In review",
    "scheduled" => "Scheduled",
    "live" => "Live"
  }

  @empty_copy %{
    "inbox" => "No ideas yet. Add one here; an agent's ideas land here too.",
    "drafting" => "Ideas move here when an agent starts drafting them.",
    "in_review" => "Ideas move here when a draft is submitted for approval.",
    "scheduled" => "Ideas move here when every version is approved.",
    "live" => "Ideas move here when a version is published."
  }

  @events ~w(ideas_lane ideas_open ideas_close ideas_quick_open ideas_quick_cancel
             ideas_quick_save ideas_ask_draft ideas_compose ideas_archive ideas_note_save
             ideas_options_save)

  @impl true
  def enabled?, do: true

  @impl true
  def all_brands?, do: true

  @impl true
  def events, do: @events

  @doc "The lane keys, in board order."
  def lanes, do: IdeaBoard.lanes()

  @doc "A lane's label."
  def lane_label(lane), do: Map.fetch!(@lane_labels, lane)

  @impl true
  def init(socket) do
    socket =
      Enum.reduce(lanes(), socket, fn lane, acc ->
        Phoenix.LiveView.stream_configure(acc, stream_name(lane), dom_id: &"idea-card-#{&1.id}")
      end)

    socket
    |> assign(:ideas_lane, "inbox")
    |> assign(:ideas_counts, Map.new(lanes(), &{&1, 0}))
    |> assign(:ideas_topics, [])
    |> assign(:ideas_profiles, [])
    |> assign(:ideas_can_add?, false)
    |> assign(:ideas_quick?, false)
    |> assign(:ideas_quick_form, quick_form())
    |> assign(:ideas_open, nil)
    |> assign(:ideas_detail, nil)
    |> assign(:ideas_notice, nil)
    |> assign(:ideas_note_form, note_form())
    |> assign(:ideas_options_errors, %{})
    |> assign(:ideas_rev, 0)
    |> assign(:ideas_refresh_pending?, false)
  end

  @stream_names %{
    "inbox" => :ideas_inbox,
    "drafting" => :ideas_drafting,
    "in_review" => :ideas_in_review,
    "scheduled" => :ideas_scheduled,
    "live" => :ideas_live
  }

  defp stream_name(lane), do: Map.fetch!(@stream_names, lane)

  # ── Load ─────────────────────────────────────────────────────────────

  # The scope's ideas, re-read and re-streamed per lane with `reset: true`,
  # and the open idea (if any) re-read with them.
  @impl true
  def load(socket) do
    profiles = scope_profiles(socket)
    user_id = user_id(socket)
    writers = Map.new(profiles, &{&1.id, writer?(socket, &1)})

    cards =
      profiles
      |> IdeaBoard.cards(user_id)
      |> Enum.map(&Map.put(&1, :can_write?, Map.get(writers, &1.idea.profile_id, false)))

    by_lane = Enum.group_by(cards, & &1.lane)

    socket =
      Enum.reduce(lanes(), socket, fn lane, acc ->
        stream(acc, stream_name(lane), Map.get(by_lane, lane, []), reset: true)
      end)

    socket
    |> subscribe(profiles)
    |> assign(:ideas_profiles, profiles)
    |> assign(:ideas_counts, Map.new(lanes(), &{&1, length(Map.get(by_lane, &1, []))}))
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
    case IdeaBoard.detail(socket.assigns.ideas_profiles, socket.assigns.ideas_open) do
      nil ->
        socket |> assign(:ideas_open, nil) |> assign(:ideas_detail, nil)

      detail ->
        assign(
          socket,
          :ideas_detail,
          Map.put(detail, :can_write?, writer?(socket, detail.profile))
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

  # `?tab=ideas&idea=<id>`: that idea's detail opens, if it is in scope.
  @impl true
  def from_query(socket, %{"tab" => "ideas", "idea" => id}) when is_binary(id),
    do: socket |> assign(:ideas_open, id) |> load_detail()

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
  def handle_event("ideas_lane", %{"lane" => lane}, socket) do
    if lane in lanes(),
      do: {:noreply, assign(socket, :ideas_lane, lane)},
      else: {:noreply, socket}
  end

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
       |> assign(:ideas_lane, "inbox")
       |> load()}
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

  defp refusal(:not_an_approver), do: "Only approvers of this brand can do that."
  defp refusal(:not_found), do: "That idea is no longer here."
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
        lane_items: Enum.map(lanes(), &%{key: &1, label: lane_label(&1)}),
        empty_copy: @empty_copy,
        tz_for: tz_fun(assigns[:ideas_profiles] || []),
        composer?: PlatformWeb.SocialComposer.enabled?()
      )

    ~H"""
    <div data-role="social-ideas" class="mx-auto w-full max-w-[96rem] space-y-4 pb-8">
      <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h2 class="text-xl font-semibold" data-role="ideas-heading">Ideas</h2>
        <p class="text-sm text-base-content/70">
          Each idea moves along on its own as its posts are drafted, approved and published.
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

      <div
        role="tablist"
        aria-label="Lanes"
        data-role="ideas-lane-control"
        class="grid grid-cols-5 gap-1 rounded-lg border border-base-300 bg-base-200 p-1 sm:hidden"
      >
        <button
          :for={item <- @lane_items}
          type="button"
          role="tab"
          aria-selected={to_string(@ideas_lane == item.key)}
          phx-click="ideas_lane"
          phx-value-lane={item.key}
          data-role="ideas-lane-tab"
          data-lane={item.key}
          class={[
            "flex min-h-11 flex-col items-center justify-center rounded-md px-1 text-xs leading-tight",
            if(@ideas_lane == item.key,
              do: "bg-base-100 font-semibold text-base-content shadow-sm",
              else: "text-base-content/70"
            )
          ]}
        >
          <span>{item.label}</span>
          <span class="tabular-nums">{@ideas_counts[item.key]}</span>
        </button>
      </div>

      <div
        data-role="ideas-board"
        class="flex gap-3 sm:overflow-x-auto sm:pb-2 lg:grid lg:grid-cols-5 lg:overflow-visible"
      >
        <section
          :for={item <- @lane_items}
          aria-labelledby={"ideas-lane-#{item.key}-title"}
          data-role="ideas-lane"
          data-lane={item.key}
          class={[
            "w-full min-w-0 shrink-0 space-y-2 rounded-2xl bg-base-200 p-2 sm:w-72 lg:w-auto",
            @ideas_lane != item.key && "max-sm:hidden"
          ]}
        >
          <header class="flex items-center gap-2 px-1 pt-1">
            <h3 id={"ideas-lane-#{item.key}-title"} class="text-sm font-semibold">
              {item.label}
            </h3>
            <span
              class="badge badge-ghost badge-sm tabular-nums"
              data-role="ideas-lane-count"
            >
              {@ideas_counts[item.key]}
            </span>
          </header>

          <div :if={item.key == "inbox"} data-role="ideas-quick-add">
            <%= cond do %>
              <% @ideas_quick? -> %>
                <.quick_add form={@ideas_quick_form} />
              <% @ideas_can_add? -> %>
                <button
                  type="button"
                  phx-click="ideas_quick_open"
                  data-role="ideas-quick-open"
                  class="btn btn-ghost btn-sm w-full justify-start"
                >
                  <.icon name="hero-plus-mini" class="size-4" /> Idea
                </button>
              <% @all? -> %>
                <p class="px-1 text-xs text-base-content/70" data-role="ideas-quick-pick-brand">
                  Pick a brand to add an idea.
                </p>
              <% true -> %>
                <span></span>
            <% end %>
          </div>

          <p
            :if={@ideas_counts[item.key] == 0}
            data-role="ideas-lane-empty"
            class="rounded-xl border border-dashed border-base-300 px-3 py-4 text-center text-sm text-base-content/70"
          >
            {@empty_copy[item.key]}
          </p>

          <ul
            id={"ideas-lane-#{item.key}"}
            phx-update="stream"
            class="space-y-2"
            data-role="ideas-lane-cards"
          >
            <li :for={{dom_id, card} <- @streams[stream_atom(item.key)]} id={dom_id}>
              <.idea_card
                card={card}
                show_brand?={@all?}
                tz={@tz_for.(card)}
                composer?={@composer?}
                can_draft?={card.lane == "inbox" and card.can_write?}
              />
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  defp stream_atom(lane), do: stream_name(lane)

  defp tz_fun(_profiles), do: fn card -> PlatformWeb.SocialIdeaCard.profile_tz(card.profile) end

  attr :form, :any, required: true

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
          class="btn btn-ghost btn-sm"
          phx-click="ideas_quick_cancel"
          data-role="ideas-quick-cancel"
        >
          Cancel
        </button>
        <button type="submit" class="btn btn-primary btn-sm" data-role="ideas-quick-save">
          Add to Inbox
        </button>
      </div>
    </.form>
    """
  end

  attr :card, :map, required: true
  attr :show_brand?, :boolean, default: false
  attr :tz, :string, required: true
  attr :composer?, :boolean, default: false
  attr :can_draft?, :boolean, default: false

  defp idea_card(assigns) do
    assigns = assign(assigns, :source, SocialIdeaDetail.source_chip(assigns.card.idea))

    ~H"""
    <article
      data-role="idea-card"
      data-idea-id={@card.id}
      data-stage={@card.stage}
      class="rounded-xl border border-base-300 bg-base-100 text-base-content shadow-sm"
    >
      <button
        type="button"
        phx-click="ideas_open"
        phx-value-id={@card.id}
        data-role="idea-card-open"
        data-href={"?tab=ideas&idea=#{@card.id}"}
        class="block w-full space-y-2 rounded-xl p-3 text-left hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
      >
        <div class="flex flex-wrap items-center gap-1.5 text-xs">
          <span
            data-role="idea-card-source"
            data-source={@card.idea.source_kind}
            class="inline-flex items-center gap-1 rounded-full border border-base-300 bg-base-200 px-2 py-0.5 font-medium"
          >
            <.icon name={@source.icon} class="size-3.5" /> {@source.label}
          </span>
          <span
            :if={@show_brand? and @card.profile}
            data-role="idea-card-brand"
            class="inline-flex max-w-[9rem] items-center truncate rounded border border-base-300 px-1.5 font-semibold"
          >
            {@card.profile.name}
          </span>
          <span
            :if={@card.failed?}
            data-role="idea-card-failed"
            class="ml-auto inline-flex items-center gap-1 text-base-content/60"
          >
            <.icon name="hero-exclamation-triangle-micro" class="size-3.5" /> Failed
          </span>
        </div>

        <p class="font-semibold leading-snug" data-role="idea-card-title">{@card.idea.title}</p>

        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/70">
          <span
            :if={@card.platforms != []}
            class="inline-flex items-center gap-1"
            data-role="idea-card-platforms"
          >
            <span
              :for={platform <- @card.platforms}
              data-role="idea-card-platform"
              data-platform={platform}
              title={platform_label(platform)}
            >
              <SocialPreview.glyph platform={platform} class="size-3.5" />
              <span class="sr-only">{platform_label(platform)}</span>
            </span>
          </span>
          <span
            :if={@card.agent_name}
            data-role="idea-card-agent"
            class="inline-flex items-center gap-1"
          >
            <.icon name="hero-sparkles-micro" class="size-3.5" /> {@card.agent_name}
          </span>
          <span
            :if={@card.next_at}
            data-role="idea-card-next"
            class="inline-flex items-center gap-1 font-mono tabular-nums"
          >
            <.icon name="hero-clock-micro" class="size-3.5" />
            {PlatformWeb.SocialIdeaCard.when_text(@card.next_at, @tz)}
          </span>
        </div>

        <span
          :if={@card.waiting > 0}
          data-role="idea-card-waiting"
          class="badge badge-primary badge-sm font-medium"
        >
          {@card.waiting} waiting on you
        </span>
      </button>

      <div :if={@can_draft?} class="border-t border-base-300 px-3 py-2">
        <SocialIdeaDetail.draft_button
          idea_id={@card.id}
          composer?={@composer?}
          agent_name={@card.agent_name}
          size="btn-xs"
        />
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
