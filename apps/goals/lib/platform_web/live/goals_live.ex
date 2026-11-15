defmodule PlatformWeb.GoalsLive do
  @moduledoc """
  The Goals screen (task 01a1dfc1, Goals 4/8), nested by core's generic
  `/m/<prefix>` page (`Platform.Extension.live_pages/0`,
  `Platform.Goals.Extension.live_pages/0`).

  ## Nothing is inherited from the parent page

  Core hands this LiveView `%{"user_id" => id}` plus, when the URL carried
  any, `"query"`: the URL's query as untrusted strings. It runs no
  live_session hook on it. `mount/3` re-reads the user
  (`Platform.Accounts.get_user/1`) and reads every goal through
  `Platform.Goals`, which decides who sees what in its queries. This module
  never touches the database itself (`web_layer_guard_test.exs`).

  ## One route, two views

  `/m/goals` lists the goals the user sees (`Platform.Goals.describe_goals/1`).
  `/m/goals?goal=<id>` shows one (`Platform.Goals.describe_goal/2`). Anything
  but `{:ok, card}` there raises `PlatformWeb.ExtensionPageLive.NotFoundError`,
  so a goal the user may not see, a goal that does not exist and a malformed
  id are the same 404 response, with no message that tells them apart. Rows
  link with `navigate`, so opening a goal remounts the page with the new
  query. Any `handle_event/3` a later stage adds re-reads the goal through
  the context before acting and never trusts an id from the client.

  The list (`PlatformWeb.GoalsList`, stage 2) matches the agreed prototype
  (canvas 01a15ef6, Goals prototype v4): Inbox's two panes at `lg` and up,
  the phone list below. The goal page, short read, privacy and owner
  settings use the same component recipes in stages 3 and 4.

  ## Design deviations

  The one place deviations from the prototype are recorded; later stages
  append here and copy this list into their evidence canvas.

    1. A goal's address is `/m/goals?goal=<id>`, not a path of its own,
       because core serves one route per module (`/m/:prefix`).
    2. On phone the Goals row follows Voice and Tasks in the More sheet. On
       main Inbox is a bottom-bar tab and not a More row, where the canvas
       shows Inbox as the row above Goals.
    3. Where Social is also visible, Goals follows Social: core keeps
       extension rows in registration order.
    4. Stage 1's plain goal view was replaced by the goal page in stage 3.

  Stage 2 (the list, `PlatformWeb.GoalsList`):

    5. No status pill ("On track", "A little behind"): pacing belongs to
       Goals 8/8.
    6. No "New goal" button (desktop) or chip (phone): Goals 5/8 adds them.
       An empty `data-goals-slot="new-goal"` element marks each place.
    7. Row times read "Updated 3h ago" / "Added Oct 2" (core's
       `InboxItem.relative_time/1`), not the canvas's clock time "7:00":
       the nested page gets no viewer time zone from core.
    8. Every row carries a privacy chip ("Only you", "Shared: {names}",
       "Shared by {owner}"), which the canvas does not show: the ticket
       requires a privacy badge on every row. On phone it sits on line 3
       after the kind words.
    9. Kind line precedence: someone else's goal reads "Shared by {owner}"
       (not in the canvas); an opened goal of yours reads "Shared with
       {names}" even when it has a coach; then "{coach} leads / coaches /
       advises" ("advises" is not in the canvas); else your first name.
   10. A goal with a target but no reading (no source, an unknown source,
       a source that refuses, no reading yet) reads "Target: {target}
       {unit}" (not in the canvas). An empty list shows core's minimal
       empty state "No goals yet" (not in the canvas).
   11. Phone "Back to More" clicks the bottom bar's More tab, because the
       sheet's `open_more_sheet` event belongs to core's parent page and a
       nested LiveView cannot push to it.

  Stage 3 (the goal page, `PlatformWeb.GoalsPage`, and the short read,
  `PlatformWeb.GoalsRead`):

   12. "If things go sideways" is not built: the schema has no field for
       it, and no field is added here.
   13. No pace sentence after the number ("We'd hoped for about ...") and
       no status pill on trying cards: pacing and prediction verdicts
       belong to Goals 8/8. No "Stopped {date}" state either: no stored
       field says an action stopped.
   14. No "See the numbers" link or chart, no "Up next" section, no brief
       note ("You came here from today's briefing.") and no retro preview
       footer: Goals 6/8 and 8/8.
   15. The short read has no intro card (not stored) and drops the sample
       suffix "(placeholder names)" and "· sources are placeholder names".
       Its h2 is "What we've learned".
   16. The meta line carries no rhythm word ("daily"); the source part is
       the source's label as listed by `list_sources/1`, e.g.
       "Self-reported", not "from YouTube".
   17. Stage 4 fills the privacy slot with the badge and owner controls.
   18. Built and not in the canvas: the Notebook section (wake-ups,
       actions, asks, waits, retros, newest first) and the "Log a value"
       form, which stands where the canvas has "Fix the count".
   19. A goal with no stops still gets the number card (the sentence needs
       a home); only the journey row inside it is absent.
   20. A reached stop's circle is the hero check icon, not the "✓"
       character (hero icons only). The "This stop is about" checklist
       shows "(done)" or "({found} found)", never the canvas's live number
       "(640)".
   21. The learned card's intro sentence is shown only when the goal has a
       coach (it names them).

  Stage 4 (privacy, settings and status):

   22. The settings sheet, Pause and Finish controls, viewer badge and empty
       audience tabs are new pieces absent from the canvas, built from the
       Open up sheet's parts. The canvas's "Everyone in the org" sub-line
       is sample text and is not derived.
   23. No PubSub in this member: another user's open page changes on its
       next event or load.
   24. Core's right Sheet supplies its desktop width and close button. Its
       right variant does not switch placement on phone, so scoped layout
       utilities anchor its panel at the bottom, capped at 90dvh. The
       single toast also has a Dismiss control; settings label weekdays
       with a Day legend.
   25. Core rejects external users before the extension mounts: they get
       the same 403 for existing and missing goal URLs. Internal viewers
       and root admins get the goal's uniform 404 when it is hidden.
  """
  use PlatformWeb, :live_view

  alias Platform.Goals
  alias PlatformWeb.ExtensionPageLive.NotFoundError
  alias PlatformWeb.GoalsList
  alias PlatformWeb.GoalsPage
  alias PlatformWeb.GoalsRead
  alias PlatformWeb.GoalsOpenUp
  alias PlatformWeb.GoalsSettings

  @impl true
  def mount(_params, session, socket) do
    user = Platform.Accounts.get_user(session["user_id"])
    query = session["query"]

    socket =
      socket
      |> assign(:user, user)
      |> assign(:rows, GoalsList.rows(user, list_cards(user)))
      |> assign(:read, read_param(query))
      |> assign(:log_error, nil)
      |> assign(
        share_open: false,
        settings_open: false,
        share_tab: "people",
        share_snapshot: [],
        audience_options: %{people: [], teams: [], spaces: []},
        settings: %{},
        toast: nil
      )

    case goal_param(query) do
      nil ->
        {:ok, assign(socket, card: nil, page: nil)}

      goal_id ->
        with {:ok, card} <- Goals.describe_goal(user, goal_id),
             {:ok, page} <- GoalsPage.load(user, card) do
          {:ok, socket |> assign(card: card, page: page) |> load_options(card)}
        else
          _ -> raise NotFoundError
        end
    end
  end

  # Log a value (stage 3). Re-reads the goal through the context and calls
  # `Platform.Goals.log_reading/3` for EVERY submit, whoever sends it: the
  # refusal (a viewer, a measured source) is the context's, not this page's.
  @impl true
  def handle_event("log_value", params, %{assigns: %{card: %{goal: goal}}} = socket) do
    user = socket.assigns.user
    value = params |> Map.get("value", "") |> to_string() |> String.trim()

    with {:ok, card} <- Goals.describe_goal(user, goal.id) do
      case Goals.log_reading(user, card.goal.id, %{value: value}) do
        {:ok, _reading} -> {:noreply, refresh(socket, card)}
        {:error, %Ecto.Changeset{}} -> {:noreply, assign(socket, :log_error, "Enter a number")}
        {:error, _refused} -> {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("log_value", _params, socket), do: {:noreply, socket}

  def handle_event("open_share", _params, socket) do
    with {:ok, card} <- owner_card(socket),
         {:ok, options} <- Goals.list_audience_options(socket.assigns.user, card.goal.id) do
      {:noreply,
       socket
       |> refresh(card)
       |> assign(
         share_open: true,
         share_tab: "people",
         audience_options: options,
         share_snapshot: audience_keys(card),
         toast: nil
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("share_tab", %{"tab" => tab}, socket)
      when tab in ["people", "teams", "spaces"] do
    with {:ok, card} <- owner_card(socket),
         {:ok, options} <- Goals.list_audience_options(socket.assigns.user, card.goal.id) do
      {:noreply, socket |> refresh(card) |> assign(share_tab: tab, audience_options: options)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_audience", %{"type" => type, "id" => id}, socket)
      when type in ["user", "team", "space"] do
    audience = {Map.fetch!(%{"user" => :user, "team" => :team, "space" => :space}, type), id}

    with {:ok, card} <- Goals.describe_goal(socket.assigns.user, goal_id(socket)) do
      fun = if audience in audience_keys(card), do: &Goals.close_goal/3, else: &Goals.open_goal/3

      case fun.(socket.assigns.user, card.goal.id, audience) do
        {:ok, _} ->
          {:noreply, reload(socket)}

        {:error, :audience_not_available} ->
          {:noreply, assign(socket, toast: %{message: "That one can't be added", undo: nil})}

        _ ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("share_done", _params, socket) do
    with {:ok, card} <- owner_card(socket) do
      changed = MapSet.new(audience_keys(card)) != MapSet.new(socket.assigns.share_snapshot)
      socket = socket |> refresh(card) |> assign(:share_open, false)

      toast =
        if changed,
          do: %{
            message: audience_message(socket),
            undo: {:audience, socket.assigns.share_snapshot}
          },
          else: nil

      {:noreply, assign(socket, :toast, toast)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_share", _params, socket),
    do: {:noreply, assign(socket, :share_open, false)}

  def handle_event("close_settings", _params, socket),
    do: {:noreply, assign(socket, :settings_open, false)}

  def handle_event("dismiss_toast", _params, socket), do: {:noreply, assign(socket, :toast, nil)}

  def handle_event("open_settings", _params, socket) do
    with {:ok, card} <- owner_card(socket) do
      settings =
        Map.new(~w(rhythm rhythm_weekday outreach agent_mode), fn key ->
          {key, Map.get(card.goal, String.to_existing_atom(key))}
        end)

      {:noreply, socket |> refresh(card) |> assign(settings_open: true, settings: settings)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("settings_select", %{"field" => field, "value" => value}, socket)
      when field in ~w(rhythm rhythm_weekday outreach agent_mode) do
    with {:ok, _card} <- owner_card(socket) do
      {:noreply, assign(socket, :settings, Map.put(socket.assigns.settings, field, value))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save_settings", _params, socket) do
    with {:ok, card} <- owner_card(socket) do
      attrs = socket.assigns.settings

      attrs =
        if attrs["rhythm"] in ["weekly", "biweekly"],
          do: Map.put(attrs, "rhythm_weekday", attrs["rhythm_weekday"] || 1),
          else: Map.delete(attrs, "rhythm_weekday")

      case Goals.update_goal(socket.assigns.user, card.goal.id, attrs) do
        {:ok, _} -> {:noreply, socket |> reload() |> assign(:settings_open, false)}
        _ -> {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("goal_status", %{"status" => status}, socket)
      when status in ~w(active paused finished) do
    with {:ok, card} <- owner_card(socket),
         {:ok, _} <- Goals.update_goal(socket.assigns.user, card.goal.id, %{status: status}) do
      message =
        %{"active" => "Goal resumed", "paused" => "Goal paused", "finished" => "Goal finished"}[
          status
        ]

      {:noreply,
       socket
       |> reload()
       |> assign(:toast, %{message: message, undo: {:status, card.goal.status}})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("undo", _params, socket) do
    with {:ok, card} <- owner_card(socket) do
      case socket.assigns.toast do
        %{undo: {:audience, snapshot}} ->
          current = audience_keys(card)
          Enum.each(current -- snapshot, &Goals.close_goal(socket.assigns.user, card.goal.id, &1))
          Enum.each(snapshot -- current, &Goals.open_goal(socket.assigns.user, card.goal.id, &1))

        %{undo: {:status, status}} ->
          Goals.update_goal(socket.assigns.user, card.goal.id, %{status: status})

        _ ->
          :ok
      end

      {:noreply, socket |> reload() |> assign(:toast, nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp goal_id(socket), do: socket.assigns.card && socket.assigns.card.goal.id

  defp owner_card(socket) do
    case Goals.describe_goal(socket.assigns.user, goal_id(socket)) do
      {:ok, %{role: :owner} = card} -> {:ok, card}
      _ -> {:error, :forbidden}
    end
  end

  defp audience_keys(%{audience: audience}) when is_list(audience),
    do: Enum.map(audience, &{&1.type, &1.id})

  defp audience_keys(_card), do: []

  defp load_options(socket, %{role: :owner} = card) do
    case Goals.list_audience_options(socket.assigns.user, card.goal.id) do
      {:ok, options} -> assign(socket, :audience_options, options)
      _ -> socket
    end
  end

  defp load_options(socket, _card), do: socket

  defp reload(socket) do
    case Goals.describe_goal(socket.assigns.user, goal_id(socket)) do
      {:ok, card} -> socket |> refresh(card) |> load_options(card)
      _ -> socket
    end
  end

  defp audience_message(socket) do
    case GoalsOpenUp.label(socket.assigns.card, socket.assigns.audience_options) do
      "Only you" -> "Only you can see it now"
      label -> label
    end
  end

  defp refresh(socket, card) do
    user = socket.assigns.user

    case GoalsPage.load(user, card) do
      {:ok, page} ->
        socket
        |> assign(card: card, page: page, log_error: nil)
        |> assign(:rows, GoalsList.rows(user, list_cards(user)))

      _ ->
        socket
    end
  end

  defp read_param(%{"read" => read}) when is_binary(read) and read != "", do: read
  defp read_param(_query), do: nil

  defp goal_param(%{"goal" => id}) when is_binary(id), do: id
  defp goal_param(_query), do: nil

  defp list_cards(user) do
    case Goals.describe_goals(user) do
      {:ok, cards} -> cards
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative flex h-full min-h-0" data-role="goals-page">
      <%!-- Below lg the phone list is the screen; with a goal open it steps
           aside for the goal view (Inbox's breakpoints). --%>
      <div :if={is_nil(@card)} class="min-w-0 flex-1 lg:hidden">
        <GoalsList.phone_list rows={@rows} />
      </div>
      <%!-- Two panes at lg and up: the list as a 380px column. --%>
      <div
        class="h-full min-w-0 flex-1 overflow-y-auto clears-tab-bar max-lg:hidden lg:w-95 lg:flex-none lg:border-r lg:border-edge lg:bg-base-100"
        data-role="goals-list"
      >
        <GoalsList.desktop_list rows={@rows} selected_id={@card && @card.goal.id} />
      </div>
      <section
        class={[
          "min-w-0 flex-1 overflow-auto bg-base-200",
          is_nil(@card) && "max-lg:hidden"
        ]}
        data-role="goals-detail-pane"
        aria-label="Goal"
      >
        <p
          :if={is_nil(@card)}
          class="flex h-full items-center justify-center p-6 text-sm text-subtle"
          data-role="goals-detail-empty"
        >
          Select a goal
        </p>
        <GoalsRead.short_read :if={@page && @read} page={@page} focus={@read} />
        <GoalsPage.goal_page
          :if={@page && is_nil(@read)}
          page={@page}
          log_error={@log_error}
          audience_options={@audience_options}
        />
      </section>
      <GoalsOpenUp.audience_sheet
        :if={@share_open && @card && @card.role == :owner}
        card={@card}
        options={@audience_options}
        tab={@share_tab}
      />
      <GoalsSettings.settings_sheet
        :if={@settings_open && @card && @card.role == :owner}
        settings={@settings}
        coach_name={@card.coach_name}
      />
      <GoalsOpenUp.toast :if={@toast} toast={@toast} />
    </div>
    """
  end
end
