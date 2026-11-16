defmodule Platform.Goals.RetroChanges do
  @moduledoc "Validation and scoped notebook reads for retro changes."
  import Ecto.Query
  alias Platform.Goals.{Entry, Goal, Limits, Stop, Visibility}
  alias Platform.Repo

  defp rows(actor, schema, goal_id) do
    from(r in schema,
      join: g in subquery(Visibility.visible_goals(actor)),
      on: r.goal_id == g.id,
      where: g.id == ^goal_id,
      select: r
    )
  end

  defp field(attrs, key), do: Map.get(attrs, key, Map.get(attrs, String.to_atom(key)))
  defp blank?(v), do: not is_binary(v) or String.trim(v) == ""

  defp error(message),
    do: {:error, Ecto.Changeset.add_error(Ecto.Changeset.change(%Entry{}), :details, message)}

  def entry_attrs(actor, goal, wake, attrs) when is_map(attrs) do
    title = field(attrs, "title")
    summary = field(attrs, "summary")
    check = field(attrs, "check_in_change")
    change = field(attrs, "goal_change")
    snapshot = wake.briefing["retro"] || %{}

    cond do
      blank?(title) or blank?(summary) ->
        {:error, :summary_required}

      String.length(title) > 200 ->
        error("title is too long")

      not is_nil(check) and not is_nil(change) ->
        {:error, :one_change_only}

      snapshot["goal_change_required"] == true and not is_nil(check) ->
        {:error, :goal_change_only}

      snapshot["goal_change_required"] == true and is_nil(change) ->
        {:error, :goal_change_required}

      true ->
        with :ok <- validate_lists(actor, goal, attrs),
             :ok <- validate_proposal(goal, check, :check_in),
             :ok <- validate_proposal(goal, change, :goal),
             :ok <- linked(actor, goal.id, Stop, field(attrs, "stop_id"), nil) do
          details =
            Map.new(
              ~w(worked didnt_work dropped learned next_push check_in_change goal_change),
              &{&1, field(attrs, &1)}
            )

          details =
            Map.merge(details, %{
              "wake_up_id" => wake.id,
              "verdicts" => snapshot["predictions"] || [],
              "window" => Map.take(snapshot, ~w(since change flat flat_retros)),
              "stalled" => snapshot["goal_change_required"] == true
            })

          {:ok,
           %{
             kind: "retro",
             title: title,
             body: summary,
             stop_id: field(attrs, "stop_id"),
             reading_id: wake.reading_id,
             occurred_at: Platform.Goals.Clock.now(),
             details: details
           }}
        end
    end
  end

  def entry_attrs(_, _, _, _), do: error("must be an object")

  defp list_valid?(v, fun),
    do: is_list(v) and length(v) <= Limits.max_retro_rows() and Enum.all?(v, fun)

  defp map_text?(v, key), do: is_map(v) and not blank?(v[key])
  defp optional_text?(m, key), do: is_nil(m[key]) or is_binary(m[key])

  defp validate_lists(actor, goal, attrs) do
    worked = field(attrs, "worked") || []
    didnt = field(attrs, "didnt_work") || []
    dropped = field(attrs, "dropped") || []
    learned = field(attrs, "learned") || []
    push = field(attrs, "next_push")

    valid =
      list_valid?(worked, fn m ->
        map_text?(m, "label") and optional_text?(m, "note") and
          (is_nil(m["percent"]) or
             (is_number(m["percent"]) and m["percent"] >= 0 and m["percent"] <= 100))
      end) and
        list_valid?(didnt, &map_text?(&1, "text")) and list_valid?(learned, &(not blank?(&1))) and
        list_valid?(dropped, fn m ->
          is_map(m) and optional_text?(m, "reason") and
            linked(actor, goal.id, Entry, m["entry_id"], "action") == :ok and
            not is_nil(m["entry_id"])
        end) and
        (is_nil(push) or
           (map_text?(push, "title") and
              list_valid?(push["suggestions"] || [], fn m ->
                map_text?(m, "title") and m["tag"] in ~w(keep start stop) and
                  optional_text?(m, "why") and
                  linked(actor, goal.id, Entry, m["takeaway_id"], "takeaway") == :ok
              end)))

    if valid, do: :ok, else: error("invalid retro rows")
  end

  defp linked(_, _, _, nil, _), do: :ok

  defp linked(actor, goal_id, schema, raw, kind) do
    with {:ok, id} <- Ecto.UUID.cast(raw) do
      q = from(r in rows(actor, schema, goal_id), where: r.id == ^id)
      q = if kind, do: from(r in q, where: r.kind == ^kind), else: q
      if Repo.exists?(q), do: :ok, else: error("reference must belong to this goal")
    else
      _ -> error("invalid reference")
    end
  end

  defp validate_proposal(_, nil, _), do: :ok

  defp validate_proposal(goal, change, type) when is_map(change) do
    set = change["set"]

    allowed =
      case {type, change["kind"]} do
        {:check_in, _} -> ~w(rhythm rhythm_weekday outreach retro_every)
        {:goal, "target"} -> ~w(target_value)
        {:goal, "scope"} -> ~w(title why)
        {:goal, "end"} -> ~w(status)
        _ -> []
      end

    if not blank?(change["summary"]) and String.length(change["summary"]) <= 500 and is_map(set) and
         map_size(set) > 0 and Enum.all?(Map.keys(set), &(&1 in allowed)) and
         (type != :goal or change["kind"] != "end" or set == %{"status" => "finished"}) do
      cs = Goal.changeset(goal, set)

      cond do
        not cs.valid? ->
          {:error, cs}

        type == :goal and change["kind"] == "target" and
            is_nil(Ecto.Changeset.get_field(cs, :target_value)) ->
          error("target must be a number")

        map_size(cs.changes) == 0 ->
          error("change must differ from current settings")

        true ->
          :ok
      end
    else
      error("invalid proposed change")
    end
  end

  defp validate_proposal(_, _, _), do: error("invalid proposed change")

  def retro(actor, goal_id, raw) do
    with {:ok, id} <- Ecto.UUID.cast(raw),
         %Entry{} = entry <-
           Repo.one(
             from(e in rows(actor, Entry, goal_id), where: e.id == ^id and e.kind == "retro")
           ) do
      {:ok, entry}
    else
      _ -> {:error, :nothing_to_decide}
    end
  end

  def proposal(entry) do
    cond do
      is_map(entry.details["check_in_change"]) -> {"check_in", entry.details["check_in_change"]}
      is_map(entry.details["goal_change"]) -> {"goal", entry.details["goal_change"]}
      true -> {nil, nil}
    end
  end

  def decision(actor, goal_id, id) do
    Repo.one(
      from(e in rows(actor, Entry, goal_id),
        where:
          e.author_type == "user" and fragment("?->>'request'", e.details) == "retro_change" and
            fragment("?->>'retro_entry_id'", e.details) == ^id,
        order_by: [asc: e.occurred_at],
        limit: 1
      )
    )
  end

  def describe(actor, goal, id) do
    with {:ok, entry} <- retro(actor, goal.id, id) do
      {kind, proposed} = proposal(entry)
      answer = decision(actor, goal.id, entry.id)

      state =
        case answer && answer.details["decision"] do
          "switch" -> :switched
          "keep" -> :kept
          _ -> :open
        end

      change =
        if proposed,
          do: %{
            kind: String.to_existing_atom(kind),
            goal_change_kind: proposed["kind"],
            summary: proposed["summary"],
            set: proposed["set"],
            lines: lines(goal, proposed["set"]),
            state: state
          },
          else: nil

      coach =
        Repo.one(
          from(a in Platform.Agents.Agent, where: a.id == ^goal.coach_agent_id, select: a.name)
        )

      stop =
        if entry.stop_id,
          do: Repo.one(from(s in rows(actor, Stop, goal.id), where: s.id == ^entry.stop_id)),
          else: nil

      {:ok,
       %{
         entry: entry,
         coach_name: coach,
         stop: stop,
         verdicts: entry.details["verdicts"] || [],
         stalled: entry.details["stalled"] == true,
         flat_retros: get_in(entry.details, ["window", "flat_retros"]) || 0,
         change: change,
         can_decide?:
           match?(%Platform.Accounts.User{id: user_id} when user_id == goal.owner_user_id, actor) and
             not is_nil(change) and state == :open
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp lines(goal, set) do
    Enum.map(Enum.sort(set), fn {key, value} ->
      old = Map.get(goal, String.to_existing_atom(key))

      case key do
        "status" -> "Finish this goal"
        "rhythm" -> "Check-ins: #{human(old)} -> #{human(value)}"
        "outreach" -> "Nudges: #{old} -> #{value}"
        "target_value" -> "Target: #{old} -> #{value} #{goal.unit}"
        "rhythm_weekday" -> "Check-in weekday: #{old} -> #{value}"
        "retro_every" -> "Retro every: #{old} -> #{value} check-ins"
        "title" -> "Title: #{old} -> #{value}"
        "why" -> "Why: #{old} -> #{value}"
      end
    end)
  end

  defp human("daily"), do: "every day"
  defp human(v), do: v

  def states(actor, goal_id) do
    actions = Repo.all(from(e in rows(actor, Entry, goal_id), where: e.kind == "action"))

    retros =
      Repo.all(
        from(e in rows(actor, Entry, goal_id),
          where: e.kind == "retro",
          order_by: [desc: e.occurred_at, desc: e.id]
        )
      )

    result =
      Map.new(actions, fn action ->
        dropped =
          Enum.find(retros, fn r ->
            Enum.any?(r.details["dropped"] || [], &(&1["entry_id"] == action.id))
          end)

        row =
          Enum.find_value(retros, fn r ->
            Enum.find(r.details["verdicts"] || [], &(&1["entry_id"] == action.id))
          end)

        state =
          cond do
            dropped ->
              {:stopped, DateTime.to_date(dropped.occurred_at)}

            is_nil(row) ->
              :just_started

            true ->
              case row["verdict"] do
                "came_true" -> :working
                "did_not" -> :not_working
                "too_early" -> :too_early
                _ -> :none
              end
          end

        {action.id, state}
      end)

    {:ok, result}
  end
end
