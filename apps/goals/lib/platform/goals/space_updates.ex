defmodule Platform.Goals.SpaceUpdates do
  @moduledoc """
  One short update in each space a goal is opened to, after the coach
  closes a check-in (task 01a1dfc1-dffb, Goals 7/8 stage 4).

  `publish/5` is called by `Platform.Goals.close_wake_up/4` AFTER its
  transaction commits, and from nowhere else. It is rescued: a failure to
  post is logged and never fails or undoes the close. It returns the ids of
  the spaces it posted to.

  ## When a space gets an update

  For each space grant of the goal, read as the coach through
  `Platform.Goals.Visibility.visible_goals/1`:

    1. The author is the coach's own participant row in that space. With no
       row, nothing is posted there: this module never adds an agent to a
       space (that would hand it the space's history).
    2. The plan or the number changed: the outcome is do or ask, or the
       check-in's reading (`"<population>|<value>"`) differs from the
       grant's `last_update_number`. A wait with the same number, or with no
       number at all, posts nothing.
    3. The grant is claimed BEFORE the post, in one UPDATE that sets
       `last_update_wake_up_id`, `last_update_at` and `last_update_number`
       where `last_update_wake_up_id IS DISTINCT FROM` this check-in. Zero
       rows means the check-in was already published there. A crash between
       the claim and the post loses that one update; it can never double it.
    4. The post goes through `Platform.Chat.post_message/2` (injectable as
       `:goals, :space_update_poster`) as plain text, with metadata exactly
       `%{"source" => "goals.update"}`: no goal id and no check-in id.

  A personal goal has no grants, so it never posts.

  ## What the update says

  At most two lines and 500 characters (`text/1`): the goal's title and the
  number sentence the goal page shows (`Platform.Goals.NumberText`), then
  for do "<coach> did: <entry title>" with the count and names of any tasks
  handed out, for ask "<coach> asked: <entry title>", and for wait nothing.
  Every interpolated value passes through
  `Platform.Security.ExternalContent.escape_mentions/1`. Nothing else goes
  in: no ask body or payload, no addressee, no task title or description, no
  notebook body, no link, no id. Each piece is something every participant
  of the space can already read on the goal page.

  ## How far the post reaches

  The post is NOT unrouted; core has no such post in a channel (`log_only`
  is honoured in execution spaces only). It is bounded by who wrote it: an
  agent author has no reply target and never fans out through the space's
  attention policy, and its mention scan cannot add a participant. What
  remains is the active-agent mutex: when ANOTHER agent holds it, that one
  agent is routed the message once. Goals posts only from `close_wake_up/4`,
  never in answer to a message, so a reply cannot start a loop.

  A posted update stays in the space's history after the goal is closed to
  that space: closing deletes the grant, not the messages.
  """

  import Ecto.Query

  require Logger

  alias Platform.Goals.{Grant, NumberText, Reading, Visibility}
  alias Platform.Repo
  alias Platform.Security.ExternalContent

  @max_length 500
  @metadata %{"source" => "goals.update"}

  @doc """
  Posts the update for a closed check-in to every space that should get one.
  Returns the ids of the spaces posted to; never raises.
  """
  @spec publish(term(), map() | binary(), map(), map(), [map()]) :: [binary()]
  def publish(coach, goal, wake_up, entry, tasks) do
    if Platform.Goals.enabled?(), do: do_publish(coach, goal, wake_up, entry, tasks), else: []
  rescue
    error ->
      Logger.warning("[goals] space update failed: " <> Exception.message(error))
      []
  end

  defp do_publish(coach, goal, wake_up, entry, tasks) do
    goal_id = if is_binary(goal), do: goal, else: goal.id
    number_now = number_now(coach, goal_id, wake_up)
    plan_changed? = wake_up.outcome in ["do", "ask"]

    candidates =
      for grant <- space_grants(coach, goal_id),
          plan_changed? or (number_now != nil and number_now != grant.last_update_number),
          participant <- [Platform.Chat.get_agent_participant(grant.space_id, coach.id)],
          participant != nil,
          do: {grant, participant}

    case candidates do
      [] ->
        []

      _ ->
        content = text(update(coach, goal_id, wake_up, entry, tasks))

        for {grant, participant} <- candidates,
            claim(coach, grant, wake_up, number_now),
            post(grant.space_id, participant, content),
            do: grant.space_id
    end
  end

  @doc """
  The update's plain text from `%{title, number_sentence, outcome,
  coach_name, entry_title, task_assignees}`: two lines at most, every
  interpolated value escaped, cut to 500 characters.
  """
  @spec text(map()) :: String.t()
  def text(update) do
    first = "#{escape(update.title)}: #{escape(update.number_sentence)}"

    [first | second_line(update)]
    |> Enum.join("\n")
    |> String.slice(0, @max_length)
  end

  defp second_line(%{outcome: "do"} = u) do
    ["#{escape(u.coach_name)} did: #{escape(u.entry_title)}" <> tasks_clause(u.task_assignees)]
  end

  defp second_line(%{outcome: "ask"} = u),
    do: ["#{escape(u.coach_name)} asked: #{escape(u.entry_title)}"]

  defp second_line(_wait), do: []

  defp tasks_clause([]), do: ""

  defp tasks_clause(names),
    do: " Tasks handed out: #{length(names)} (#{Enum.map_join(names, ", ", &escape/1)})."

  defp escape(nil), do: ""
  defp escape(value), do: ExternalContent.escape_mentions(to_string(value))

  # ── reads, all through the coach's visible goals ─────────────────────────

  defp space_grants(coach, goal_id) do
    Repo.all(
      from(gr in Grant,
        join: g in subquery(Visibility.visible_goals(coach)),
        on: g.id == gr.goal_id,
        where: gr.goal_id == ^goal_id and gr.audience_type == "space",
        order_by: [asc: gr.inserted_at, asc: gr.id]
      )
    )
  end

  defp number_now(_coach, _goal_id, %{reading_id: nil}), do: nil

  defp number_now(coach, goal_id, %{reading_id: reading_id}) do
    reading =
      Repo.one(
        from(r in Reading,
          join: g in subquery(Visibility.visible_goals(coach)),
          on: g.id == r.goal_id,
          where: r.id == ^reading_id and r.goal_id == ^goal_id
        )
      )

    case reading do
      %Reading{value: %Decimal{} = value} = r ->
        "#{r.population}|#{value |> Decimal.normalize() |> Decimal.to_string(:normal)}"

      _ ->
        nil
    end
  end

  defp update(coach, goal_id, wake_up, entry, tasks) do
    {:ok, card} = Platform.Goals.describe_goal(coach, goal_id)

    number =
      case Platform.Goals.goal_number(coach, goal_id) do
        {:ok, result} -> result
        _ -> nil
      end

    %{
      title: card.goal.title,
      number_sentence: NumberText.sentence(card.goal, card.current_stop, number),
      outcome: wake_up.outcome,
      coach_name: coach.name,
      entry_title: entry && entry.title,
      task_assignees: task_assignees(tasks)
    }
  end

  defp task_assignees(tasks) do
    tasks
    |> Enum.map(&Map.take(&1, [:phase_assignees, :assignee_id, :assignee_type]))
    |> Platform.Goals.GoalTasks.annotate()
    |> Enum.map(& &1.assignee_name)
    |> Enum.reject(&is_nil/1)
  end

  # ── the claim, then the post ─────────────────────────────────────────────

  defp claim(coach, grant, wake_up, number_now) do
    visible_ids = from(g in subquery(Visibility.visible_goals(coach)), select: g.id)

    {count, _} =
      from(gr in Grant,
        where:
          gr.id == ^grant.id and gr.goal_id in subquery(visible_ids) and
            fragment(
              "? IS DISTINCT FROM ?",
              gr.last_update_wake_up_id,
              type(^wake_up.id, Ecto.UUID)
            ),
        update: [
          set: [
            last_update_wake_up_id: ^wake_up.id,
            last_update_at: ^Platform.Goals.Clock.now(),
            last_update_number:
              fragment("COALESCE(?, ?)", type(^number_now, :string), gr.last_update_number)
          ]
        ]
      )
      |> Repo.update_all([])

    count == 1
  end

  defp post(space_id, participant, content) do
    {module, function} =
      Application.get_env(:goals, :space_update_poster, {Platform.Chat, :post_message})

    case apply(module, function, [
           %{
             space_id: space_id,
             participant_id: participant.id,
             content_type: "text",
             content: content,
             metadata: @metadata
           }
         ]) do
      {:ok, _message} ->
        true

      other ->
        Logger.warning("[goals] space update not posted: #{inspect(other)}")
        false
    end
  end
end
