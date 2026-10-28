# Task 01a1830b-026a-7000-b529-bd66e4a4a70b: exact-meeting, no-push one-off.
# Release eval: Code.eval_file("/tmp/repair_meeting_briefing.exs");
# MeetingBriefingRepair.run("01a182f9-2143-7000-a92f-2cf62a92cefc") # dry run
# MeetingBriefingRepair.run("01a182f9-2143-7000-a92f-2cf62a92cefc", apply: true)
# Defines a NEW helper only; never hot-loads any Platform module.
defmodule MeetingBriefingRepair do
  import Ecto.Query
  alias Platform.{Repo, Meetings, Inbox}
  alias Platform.Meetings.{Meeting, MeetingBriefing, MeetingCandidate, CompletionRun, Transcript}
  @meeting_id "01a182f9-2143-7000-a92f-2cf62a92cefc"
  @withdrawn_reasons [:retracted, :duplicate, :vetoed]

  def run(meeting_id, opts \\ []) do
    if meeting_id != @meeting_id, do: raise(ArgumentError, "meeting not authorized")
    preflight!()

    {:ok, result} =
      Repo.transaction(fn ->
        meeting = Repo.get!(Meeting, meeting_id)
        if meeting.status != "ended", do: raise("meeting not ended")

        briefing =
          Repo.one!(
            from(b in MeetingBriefing, where: b.meeting_id == ^meeting_id, lock: "FOR UPDATE")
          )

        attrs = replacement(briefing, meeting)

        changed? =
          briefing.items != attrs.items or briefing.summary != attrs.summary or
            briefing.transcript_id != attrs.transcript_id

        before = counts(briefing.items)
        after_counts = counts(attrs.items)

        if Keyword.get(opts, :apply, false) and changed? do
          briefing |> MeetingBriefing.changeset(attrs) |> Repo.update!()
        end

        %{
          changed: changed?,
          applied: Keyword.get(opts, :apply, false),
          before: before,
          after: after_counts,
          briefing_id: briefing.id
        }
      end)

    if result.applied and result.changed do
      briefing = Repo.get!(MeetingBriefing, result.briefing_id)

      Enum.each(briefing.attendee_user_ids, fn id ->
        Phoenix.PubSub.broadcast(Platform.PubSub, Inbox.topic(id), {:inbox_changed, id})
      end)

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        "meeting_briefing:" <> briefing.id,
        {:meeting_briefing_changed, briefing.id}
      )
    end

    result
  end

  # Only columns used by this one-off are inspected; mismatch aborts before writes.
  def preflight! do
    expected = %{
      "meeting_briefings" =>
        ~w(id meeting_id items receipts summary transcript_id attendee_user_ids),
      "meeting_candidates" =>
        ~w(id meeting_id disposition classified_intent closed_reason evidence_quote task_id),
      "meeting_completion_runs" => ~w(meeting_id item_results),
      "meeting_transcripts" => ~w(id meeting_id space_id status summary started_at completed_at)
    }

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='public'",
        []
      )

    Enum.each(expected, fn {table, columns} ->
      actual = for [^table, col] <- rows, do: col
      unless Enum.all?(columns, &(&1 in actual)), do: raise("schema mismatch: " <> table)
    end)

    :ok
  end

  @doc false
  def replacement(briefing, meeting) do
    tasks =
      meeting
      |> Meetings.meeting_tasks_query()
      |> select([task: t], %{id: t.id, title: t.title, status: t.status})
      |> Repo.all()

    task_items =
      Map.new(tasks, fn t ->
        ref = "task:" <> t.id

        {"m" <> (Base.encode16(:crypto.hash(:sha256, ref), case: :lower) |> binary_part(0, 16)),
         %{"kind" => "task", "ref" => ref, "title" => t.title || "", "filed_status" => t.status}}
      end)

    %{
      items:
        task_items |> Map.merge(briefing.items || %{}) |> Map.put("_content", content(meeting))
    }
    |> Map.merge(summary_attrs(meeting))
    |> Map.put_new(:summary, briefing.summary)
    |> Map.put_new(:transcript_id, briefing.transcript_id)
  end

  defp counts(items) do
    c = items["_content"] || %{}

    %{
      questions: length(c["open_questions"] || []),
      unfiled_actions: length(c["unfiled_action_items"] || [])
    }
  end

  defp belongs_to_meeting?(t, meeting) do
    t.meeting_id == meeting.id or
      (is_nil(t.meeting_id) and not is_nil(meeting.started_at) and
         not is_nil(t.started_at || t.inserted_at) and
         DateTime.compare(t.started_at || t.inserted_at, meeting.started_at) != :lt and
         DateTime.compare(t.started_at || t.inserted_at, meeting.ended_at) != :gt)
  end

  def content(%Meeting{} = meeting) do
    candidates =
      from(c in MeetingCandidate,
        where: c.meeting_id == ^meeting.id,
        where: c.classified_intent in ["open_question", "action_items"],
        where: c.disposition == :accepted,
        where: is_nil(c.closed_reason) or c.closed_reason not in ^@withdrawn_reasons,
        order_by: [asc: c.inserted_at, asc: c.id],
        select: %{
          id: c.id,
          intent: c.classified_intent,
          quote: c.evidence_quote,
          task_id: c.task_id
        }
      )
      |> Repo.all()

    filed_candidate_ids = filed_candidate_ids(meeting)

    %{
      "open_questions" => for(%{intent: "open_question"} = c <- candidates, do: content_entry(c)),
      "unfiled_action_items" =>
        for(
          %{intent: "action_items", task_id: nil} = c <- candidates,
          not MapSet.member?(filed_candidate_ids, c.id),
          do: content_entry(c)
        ),
      "transcript_url" => "/meetings/" <> meeting.slug
    }
  end

  # Only identity can reconcile a candidate with a final checklist item. A
  # shared canvas or similar title is not evidence that this action was filed.
  # Keep the task query canonical, including its soft-deletion/access scope.
  defp filed_candidate_ids(meeting) do
    tasks =
      meeting
      |> Meetings.meeting_tasks_query()
      |> select([task: t], %{id: t.id, metadata: t.metadata})
      |> Repo.all()

    task_ids = MapSet.new(tasks, & &1.id)
    direct_ids = Enum.map(tasks, & &1.metadata["candidate_id"])

    ledger_ids =
      case Repo.get_by(CompletionRun, meeting_id: meeting.id) do
        nil ->
          []

        run ->
          for {_item_id, entry} <- run.item_results || %{},
              entry["status"] == "processed",
              Enum.any?(
                (entry["task_ids"] || []) ++ (entry["existing_task_ids"] || []),
                &MapSet.member?(task_ids, &1)
              ),
              candidate_id <- entry["candidate_ids"] || [],
              do: candidate_id
      end

    MapSet.new(direct_ids ++ ledger_ids)
  end

  defp content_entry(candidate), do: %{"id" => candidate.id, "text" => candidate.quote || ""}

  # ── Summary ───────────────────────────────────────────────────────────────

  defp summary_attrs(meeting) do
    transcripts = owned_transcripts(meeting) |> Enum.filter(&(&1.status == "complete"))

    case List.last(transcripts) do
      nil ->
        %{}

      transcript ->
        summaries =
          Enum.map(transcripts, & &1.summary)
          |> Enum.filter(&(is_binary(&1) && String.trim(&1) != ""))

        %{
          summary: if(summaries == [], do: nil, else: Enum.join(summaries, "\n\n")),
          transcript_id: transcript.id
        }
    end
  end

  defp owned_transcripts(meeting) do
    Repo.all(
      from(t in Transcript,
        where: t.space_id == ^meeting.chat_space_id,
        order_by: [asc: t.started_at, asc: t.id]
      )
    )
    |> Enum.filter(&belongs_to_meeting?(&1, meeting))
  end
end
