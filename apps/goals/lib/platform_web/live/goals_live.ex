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

  Daily brief deviations are recorded in `PlatformWeb.GoalsBriefComponent`.

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

  Stage 5 (retro and the slower loop, Goals 8/8):

   26. No Agree / Not this pills and no Start the next push or its note:
       suggestions are chosen in the existing check-in answer path.
   27. Read the last retro replaces Preview the retro: an unwritten retro
       cannot be previewed. The footer describes the actual retro rhythm.
   28. Predictions, stalled line, Change the goal?, journey and Notebook
       retro links, slowed line, Retro settings and Not working are new
       pieces required by the ticket, absent from the canvas.
   29. The by-line drops the prototype-only suffix · example data.
   30. Keep it replaces sample-specific second pills. Switch changes names
       the settings actually written; sample quizzes are not stored settings.
   31. The shared ask box replaces canned questions and an instant reply:
       the coach answers at its next check-in. No Undo after a decision;
       the owner can change settings on the goal page.
   32. The pace sentence omits the sample 52 joined this week, and adds
       an on-track form the canvas does not show. If things go sideways
       remains absent because there is no stored field or owner.

  Goals 5/8 stage 3 (the New goal screen, `PlatformWeb.GoalsNew`, at
  `/m/goals?new=1`):

   33. The box stays under the stream for the whole conversation (the
       canvas hides it after the first send; a real person has to be able
       to type).
   34. The greeting is screen copy shown in the agent's message style; the
       agent did not post it.
   35. The journey card, the summary card and Create goal are drawn by the
       page in the stream, not inside an agent message. The journey card
       sits at the time the stops were settled, so it comes just before the
       agent's message about them (the agent records, then speaks).
   36. The settled lines use general wording; the canvas lines carry sample
       detail ("You film.", "from your flash cards").
   37. No "Sign in to YouTube" reply exists because no connected source is
       built; the agent offers the sources the install has.
   38. "What would you try first?", the tick list and "Looks right, open
       the goal" are not built: suggestions are recorded at check-ins
       (member 3). "Open the goal" replaces the last chip. The toast after
       opening the goal is not built.
   39. The conversation is the person's ordinary direct conversation with
       the lead agent, so it also appears in Chat, and anything else said
       in that DM after the opening message shows here too.
   40. The canvas screen `idea` (accept or decline a suggestion) belongs to
       Goals 6/8.
   41. Built and not in the canvas: the "Open the goal" chip, "Start over",
       the no-lead-agent empty state, the offline line, the
       changed-proposal toast, the shared-suggestion privacy line, and the
       disabled Send and Create goal while a click is in flight.
   42. The stream's journey card is member 4's journey component unchanged:
       its sub-line is "by {day month}" or the caption, without the
       canvas's " · {theme}".
   43. The desktop New goal button and the phone chip are links (they
       navigate to `/m/goals?new=1`), styled as the canvas's button and
       chip.
   44. If the lead role moves to another agent mid-conversation, the screen
       names the conversation's agent from its DM participant row, in the
       default colour slot.
  """
  use PlatformWeb, :live_view

  alias Platform.Goals
  alias PlatformWeb.ExtensionPageLive.NotFoundError
  alias PlatformWeb.GoalsList
  alias PlatformWeb.GoalsPage
  alias PlatformWeb.GoalsRead
  alias PlatformWeb.GoalsOpenUp
  alias PlatformWeb.GoalsCheckIn
  alias PlatformWeb.GoalsIdea
  alias PlatformWeb.GoalsRetro
  alias PlatformWeb.GoalsSettings
  alias PlatformWeb.GoalsNew

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
        toast: nil,
        screen: nil,
        check_choices: %{},
        retro_question_sent: false,
        new: nil,
        from_brief: is_map(query) and query["from"] == "brief"
      )

    case goal_param(query) do
      nil ->
        if is_map(query) and
             (Map.has_key?(query, "check") or Map.has_key?(query, "idea") or
                Map.has_key?(query, "retro")),
           do: raise(NotFoundError)

        socket = assign(socket, card: nil, page: nil)

        {:ok,
         if(is_map(query) and Map.has_key?(query, "new"),
           do: GoalsNew.mount(socket, user),
           else: socket
         )}

      goal_id ->
        with {:ok, card} <- Goals.describe_goal(user, goal_id),
             {:ok, page} <- GoalsPage.load(user, card) do
          {:ok,
           socket |> assign(card: card, page: page) |> load_options(card) |> open_screen(query)}
        else
          _ -> raise NotFoundError
        end
    end
  end

  @impl true
  # New screens derive their ask from the validated route, never event identity.
  def handle_event(event, params, socket) when event in ["retro_switch", "retro_keep"] do
    with {:ok, socket} <- reload_retro(socket),
         true <-
           not Map.has_key?(params, "entry_id") or
             params["entry_id"] == socket.assigns.screen.entry.id,
         {:ok, _} <-
           Goals.decide_retro_change(
             socket.assigns.user,
             goal_id(socket),
             socket.assigns.screen.entry.id,
             if(event == "retro_switch", do: "switch", else: "keep")
           ),
         {:ok, socket} <- reload_retro(socket) do
      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("retro_question", params, socket) do
    with {:ok, socket} <- reload_retro(socket),
         true <- socket.assigns.card.role == :owner,
         {:ok, _} <- Goals.ask_coach(socket.assigns.user, goal_id(socket), params["question"]) do
      {:noreply, assign(socket, :retro_question_sent, true)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("check_choice", params, socket) do
    with {:ok, socket} <- reload_screen(socket, :check),
         true <- matching_screen?(socket, params),
         {:ok, index} <- choice_index(params["index"]),
         true <- index >= 0 and index < length(GoalsCheckIn.suggestions(socket.assigns.screen)),
         choice when choice in ["do", "not_now"] <- params["choice"],
         false <- GoalsCheckIn.final_answer?(socket.assigns.screen.answer) do
      {:noreply,
       assign(socket, :check_choices, Map.put(socket.assigns.check_choices, index, choice))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("check_finish", params, socket) do
    with {:ok, socket} <- reload_screen(socket, :check),
         true <- matching_screen?(socket, params) do
      screen = socket.assigns.screen

      choices =
        screen
        |> GoalsCheckIn.suggestions()
        |> Enum.with_index()
        |> Enum.map(fn {_, i} ->
          %{"index" => i, "choice" => Map.get(socket.assigns.check_choices, i, "not_now")}
        end)

      answer =
        if choices == [] or Enum.any?(choices, &(&1["choice"] == "do")),
          do: "used",
          else: "declined"

      case Goals.answer_ask(socket.assigns.user, screen.ask.id, answer, %{"choices" => choices}) do
        {:ok, _} ->
          Goals.refresh_brief(socket.assigns.user, screen.ask.id)

          case reload_screen(socket, :check) do
            {:ok, socket} -> {:noreply, socket}
            _ -> {:noreply, socket}
          end

        _ ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("idea_answer", params, socket) do
    with {:ok, socket} <- reload_screen(socket, :idea),
         true <- matching_screen?(socket, params),
         answer when answer in ["used", "declined"] <- params["answer"],
         {:ok, _} <- Goals.answer_ask(socket.assigns.user, socket.assigns.screen.ask.id, answer) do
      screen = socket.assigns.screen
      Goals.refresh_brief(socket.assigns.user, screen.ask.id)

      message =
        if answer == "used",
          do: GoalsCheckIn.coach_name(screen.coach) <> " starts on it at the next check-in",
          else: "Saved for later"

      {:noreply,
       socket
       |> refresh(socket.assigns.card)
       |> assign(screen: nil, toast: %{message: message, undo: {:ask, screen.ask.id}})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("undo", _, %{assigns: %{toast: %{undo: {:ask, ask_id}}}} = socket) do
    with {:ok, user} <- screen_user(socket),
         {:ok, ask} <- Goals.get_ask(user, ask_id),
         true <- ask.goal_id == goal_id(socket) and user.id in ask.addressed_user_ids,
         {:ok, _} <- Goals.withdraw_answer(user, ask.id) do
      Goals.refresh_brief(user, ask.id)
      {:noreply, socket |> assign(:user, user) |> reload() |> assign(screen: nil, toast: nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Log a value (stage 3). Re-reads the goal through the context and calls
  # `Platform.Goals.log_reading/3` for EVERY submit, whoever sends it: the
  # refusal (a viewer, a measured source) is the context's, not this page's.
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
        Map.new(~w(rhythm rhythm_weekday outreach agent_mode retro_every), fn key ->
          {key, Map.get(card.goal, String.to_existing_atom(key))}
        end)

      {:noreply, socket |> refresh(card) |> assign(settings_open: true, settings: settings)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("settings_select", %{"field" => field, "value" => value}, socket)
      when field in ~w(rhythm rhythm_weekday outreach agent_mode retro_every) do
    with {:ok, _card} <- owner_card(socket) do
      {:noreply,
       assign(
         socket,
         :settings,
         Map.put(
           socket.assigns.settings,
           field,
           if(field == "retro_every" and value == "", do: nil, else: value)
         )
       )}
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

  # Goals 5/8: the New goal screen owns every `new_*` event.
  def handle_event("new_" <> _ = event, params, socket),
    do: GoalsNew.handle_event(event, params, socket)

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(message, socket), do: {:noreply, GoalsNew.handle_info(message, socket)}

  defp open_screen(socket, query) when is_map(query) do
    case {query["check"], query["idea"], query["retro"]} do
      {id, _, _} when is_binary(id) -> mount_screen(socket, :check, id)
      {_, id, _} when is_binary(id) -> mount_screen(socket, :idea, id)
      {_, _, id} when is_binary(id) -> mount_screen(socket, :retro, id)
      _ -> socket
    end
  end

  defp mount_screen(socket, kind, id) do
    with {:ok, user} <- screen_user(socket),
         {:ok, screen} <- screen_load(kind, user, socket.assigns.page, id) do
      assign(socket, user: user, screen: screen)
    else
      _ -> raise NotFoundError
    end
  end

  defp screen_load(:retro, user, page, id), do: GoalsRetro.load(user, page, id)
  defp screen_load(:check, user, page, id), do: GoalsCheckIn.load(user, page, id)
  defp screen_load(:idea, user, page, id), do: GoalsIdea.load(user, page, id)

  defp screen_user(socket) do
    with %{id: id} <- socket.assigns.user,
         %Platform.Accounts.User{} = user <- Platform.Accounts.get_user(id),
         true <- Goals.enabled?(),
         true <- Platform.Access.can?(Platform.Access.Scope.for_user(user), "goals.use") do
      {:ok, user}
    else
      _ -> {:error, :not_found}
    end
  end

  defp reload_retro(%{assigns: %{screen: %{kind: :retro, entry: entry}}} = socket) do
    with {:ok, user} <- screen_user(socket),
         {:ok, card} <- Goals.describe_goal(user, goal_id(socket)),
         {:ok, page} <- GoalsPage.load(user, card),
         {:ok, screen} <- GoalsRetro.load(user, page, entry.id) do
      {:ok, assign(socket, user: user, card: card, page: page, screen: screen)}
    end
  end

  defp reload_retro(_), do: {:error, :not_found}

  defp reload_screen(%{assigns: %{screen: %{kind: kind, ask: ask}}} = socket, kind) do
    with {:ok, user} <- screen_user(socket),
         {:ok, card} <- Goals.describe_goal(user, goal_id(socket)),
         {:ok, page} <- GoalsPage.load(user, card),
         {:ok, screen} <- screen_load(kind, user, page, ask.id) do
      {:ok, assign(socket, user: user, card: card, page: page, screen: screen)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp reload_screen(_, _), do: {:error, :not_found}

  defp matching_screen?(socket, params) do
    (not Map.has_key?(params, "ask_id") or params["ask_id"] == socket.assigns.screen.ask.id) and
      (not Map.has_key?(params, "goal_id") or params["goal_id"] == goal_id(socket))
  end

  defp choice_index(index) when is_integer(index), do: {:ok, index}

  defp choice_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp choice_index(_), do: :error

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
      <div :if={is_nil(@card) and is_nil(@new)} class="min-w-0 flex-1 lg:hidden">
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
          is_nil(@card) && is_nil(@new) && "max-lg:hidden"
        ]}
        data-role="goals-detail-pane"
        aria-label="Goal"
      >
        <GoalsNew.screen :if={@new} new={@new} />
        <p
          :if={is_nil(@card) and is_nil(@new)}
          class="flex h-full items-center justify-center p-6 text-sm text-subtle"
          data-role="goals-detail-empty"
        >
          Select a goal
        </p>
        <GoalsCheckIn.screen
          :if={@screen && @screen.kind == :check}
          screen={@screen}
          choices={@check_choices}
        />
        <GoalsRetro.screen
          :if={@screen && @screen.kind == :retro}
          screen={@screen}
          sent={@retro_question_sent}
        />
        <GoalsIdea.screen :if={@screen && @screen.kind == :idea} screen={@screen} />
        <GoalsRead.short_read :if={@page && @read && is_nil(@screen)} page={@page} focus={@read} />
        <GoalsPage.goal_page
          :if={@page && is_nil(@read) && is_nil(@screen)}
          page={@page}
          from_brief={@from_brief}
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
