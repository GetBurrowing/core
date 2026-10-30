defmodule Platform.Meetings.Completion do
  @moduledoc """
  One persisted completion run per meeting. Capture and summarization finish
  before the scribe sees an ordered snapshot; only the triage officer files.
  Dispatch delivery is not completion: callbacks advance the durable run.
  """
  import Ecto.Query
  alias Platform.{Repo, Meetings}

  alias Platform.Meetings.{
    Meeting,
    Transcript,
    Room,
    CompletionRun,
    CompletionPrompt,
    Triage,
    MeetingCandidate
  }

  alias Platform.Chat.Canvas

  def resume(meeting_id) do
    with %Meeting{status: "ended"} = meeting <- Repo.get(Meeting, meeting_id) do
      Repo.insert!(%CompletionRun{meeting_id: meeting.id},
        on_conflict: :nothing,
        conflict_target: :meeting_id
      )

      outcome = locked(meeting.id, fn run -> advance(run, meeting) end)
      Platform.Responsibilities.Handlers.MeetingBriefSynthesis.run(meeting.id)
      refresh_briefing(meeting)
      outcome
    else
      _ -> {:error, :meeting_not_ended}
    end
  end

  def transcript_changed(%Transcript{space_id: nil}), do: :ok

  def transcript_changed(%Transcript{meeting_id: meeting_id}) when is_binary(meeting_id) do
    case Repo.get(Meeting, meeting_id) do
      %Meeting{status: "ended"} -> resume(meeting_id)
      _ -> :ok
    end
  end

  def transcript_changed(%Transcript{space_id: space_id} = transcript) do
    started_at = transcript.started_at || transcript.inserted_at

    case Repo.one(
           from(m in Meeting,
             where: m.chat_space_id == ^space_id and m.status == "ended",
             where: m.started_at <= ^started_at and m.ended_at >= ^started_at,
             order_by: [desc: m.started_at],
             limit: 1
           )
         ) do
      nil -> :ok
      meeting -> resume(meeting.id)
    end
  end

  def capture_finished_for_space(space_id) do
    case Repo.one(
           from(m in Meeting,
             where: m.chat_space_id == ^space_id and m.status == "ended",
             order_by: [desc: m.started_at],
             limit: 1
           )
         ) do
      nil ->
        :ok

      meeting ->
        resume(meeting.id)

        Repo.all(
          from(t in Transcript, where: t.space_id == ^space_id and t.status == "recording")
        )
        |> Enum.filter(&(&1.segments != [] and belongs_to_meeting?(&1, meeting)))
        |> Enum.each(fn transcript ->
          case Meetings.finalize_transcript(transcript.id) do
            {:ok, finalized} -> Platform.Meetings.Summarizer.summarize_async(finalized)
            _ -> :ok
          end
        end)

        Repo.update_all(from(r in CompletionRun, where: r.meeting_id == ^meeting.id),
          set: [capture_finished_at: DateTime.utc_now()]
        )

        resume(meeting.id)
    end
  end

  def reopened(meeting_id) do
    Repo.update_all(from(r in CompletionRun, where: r.meeting_id == ^meeting_id),
      inc: [generation: 1],
      set: [
        capture_finished_at: nil,
        dispatched_at: nil,
        status: "waiting",
        snapshot_hash: nil
      ]
    )

    if meeting = Repo.get(Meeting, meeting_id) do
      ids =
        Repo.all(
          from(t in Transcript,
            where: t.space_id == ^meeting.chat_space_id and t.status != "complete"
          )
        )
        |> Enum.filter(&belongs_to_meeting?(&1, meeting))
        |> Enum.map(& &1.id)

      Repo.update_all(from(t in Transcript, where: t.id in ^ids),
        inc: [summary_epoch: 1],
        set: [summary_input_hash: nil, router_dispatched_at: nil]
      )
    end

    :ok
  end

  def sweep do
    Repo.all(from(m in Meeting, where: m.status == "ended", select: m.id))
    |> Enum.each(&resume/1)

    :ok
  end

  def scribe_complete(agent_id, params) do
    callback(agent_id, "meeting_scribe", params, fn run, meeting, canvas ->
      cond do
        run.status == "filed" ->
          result(run)

        run.canvas_id && run.canvas_id != canvas.id ->
          {:error, :canvas_mismatch}

        true ->
          run =
            save(run,
              canvas_id: canvas.id,
              status: "triage_pending",
              last_error: nil
            )

          :ok = synthesis_changed(meeting.id, run.id, run.snapshot_hash, "pending")
          dispatch_triage(run, meeting)
          result(Repo.get!(CompletionRun, run.id))
      end
    end)
  end

  def triage_file(agent_id, params) do
    callback(agent_id, "triage_officer", params, fn run, meeting, canvas ->
      with true <- run.canvas_id == canvas.id || {:error, :canvas_mismatch},
           true <-
             run.status in ["triage_pending", "triage_dispatched", "filed"] ||
               {:error, :scribe_incomplete},
           items when is_list(items) <- params["action_items"],
           :ok <- validate_priorities(items),
           :ok <- validate_items(items, run, canvas),
           :ok <- validate_candidate_provenance(items, run, meeting) do
        {ledger, errors} =
          Enum.reduce(items, {run.item_results, []}, fn item, {ledger, errors} ->
            key = item["item_id"]

            cond do
              Map.has_key?(ledger, key) ->
                {ledger, errors}

              item["decision"] in ["duplicate", "conflict", "exclude"] ->
                {Map.put(ledger, key, %{
                   "status" => item["decision"],
                   "candidate_ids" => item["candidate_ids"] || []
                 }), errors}

              true ->
                case Triage.file_tasks_from_canvas(canvas,
                       project_id: meeting.project_id,
                       meeting_id: meeting.id,
                       transcript_id: run.transcript_id,
                       agent_id: agent_id,
                       action_items: [triage_item(item)],
                       render_junk_control: false,
                       extra_metadata: %{
                         "completion_run_id" => run.id,
                         "completion_item_id" => key,
                         "source_segment_ids" => item["source_segment_ids"]
                       }
                     ) do
                  {:ok, %{errors: []} = filed} ->
                    entry = %{
                      "status" => "processed",
                      "candidate_ids" => item["candidate_ids"] || [],
                      "task_ids" => Enum.map(filed.filed, & &1.id),
                      "existing_task_ids" => Enum.map(filed.skipped, & &1.existing_task_id)
                    }

                    {Map.put(ledger, key, entry), errors}

                  {:ok, failure} ->
                    {ledger, [inspect(failure.errors) | errors]}

                  {:error, reason} ->
                    {ledger, [inspect(reason) | errors]}
                end
            end
          end)

        errors =
          if Enum.any?(ledger, fn {_key, entry} -> (entry["task_ids"] || []) != [] end) do
            case Triage.ensure_completion_batch_control(canvas, run.id) do
              :ok -> errors
              {:error, reason} -> ["batch control: #{inspect(reason)}" | errors]
            end
          else
            errors
          end

        run =
          save(run,
            item_results: ledger,
            status: if(errors == [], do: "filed", else: "triage_pending"),
            last_error: if(errors == [], do: nil, else: Enum.join(errors, "; "))
          )

        result(run)
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_action_items}
      end
    end)
  end

  @doc "Register or complete an optional synthesis prerequisite for a specific captured snapshot."
  def synthesis_changed(meeting_id, run_id, snapshot_hash, status)
      when status in ["pending", "complete"] do
    outcome =
      locked(meeting_id, fn run ->
        with %Meeting{status: "ended"} = meeting <-
               Repo.one(from(m in Meeting, where: m.id == ^meeting_id, lock: "FOR UPDATE")),
             true <- run.id == run_id and run.snapshot_hash == snapshot_hash,
             {:ok, current, _} <- snapshot(meeting),
             true <- snapshot_hash(run, current) == snapshot_hash do
          save(run, synthesis: %{"snapshot_hash" => snapshot_hash, "status" => status})
          :ok
        else
          _ -> {:error, :stale_snapshot}
        end
      end)

    if outcome == :ok, do: refresh_briefing(Repo.get!(Meeting, meeting_id))
    outcome
  end

  defp refresh_briefing(meeting) do
    Platform.Meetings.MeetingBriefings.deliver(meeting)
  rescue
    error ->
      require Logger
      Logger.warning("Meeting briefing retry failed: #{Exception.message(error)}")
      :ok
  end

  defp callback(agent_id, role, params, fun) do
    with true <-
           (is_binary(agent_id) and Platform.Roles.agent_id_for_role(role) == agent_id) ||
             {:error, :unauthorized_role},
         true <-
           Enum.all?(
             ~w(meeting_id run_id transcript_id canvas_id),
             &Platform.UUID.valid?(params[&1])
           ) || {:error, :invalid_identity},
         %Meeting{status: "ended"} = meeting <- Repo.get(Meeting, params["meeting_id"]),
         %Canvas{deleted_at: nil} = canvas <- Repo.get(Canvas, params["canvas_id"]),
         true <- canvas.space_id == meeting.chat_space_id || {:error, :foreign_canvas} do
      outcome =
        locked(meeting.id, fn run ->
          current = Repo.one!(from(m in Meeting, where: m.id == ^meeting.id, lock: "FOR UPDATE"))

          with true <- current.status == "ended" || {:error, :meeting_not_finalized},
               true <- not is_nil(run.capture_finished_at) || {:error, :capture_active},
               true <-
                 (run.id == params["run_id"] and run.transcript_id == params["transcript_id"] and
                    run.snapshot_hash == params["snapshot_hash"]) || {:error, :run_mismatch},
               {:ok, snapshot, _} <- snapshot(meeting),
               true <-
                 snapshot_hash(run, snapshot) == run.snapshot_hash ||
                   {:error, :transcript_changed} do
            fun.(run, meeting, canvas)
          end
        end)

      Platform.Responsibilities.Handlers.MeetingBriefSynthesis.run(meeting.id)
      refresh_briefing(meeting)
      outcome
    else
      {:error, _} = error -> error
      _ -> {:error, :meeting_not_finalized}
    end
  end

  defp validate_items(items, run, canvas) do
    item_ids = canvas_item_ids(canvas.document) |> MapSet.new()
    segments = MapSet.new(Enum.map(run.snapshot["segments"] || [], & &1["id"]))

    valid =
      Enum.all?(items, fn item ->
        is_map(item) and is_binary(item["item_id"]) and MapSet.member?(item_ids, item["item_id"]) and
          (item["decision"] in ["duplicate", "conflict", "exclude"] or
             (is_binary(item["title"]) and String.trim(item["title"]) != "" and
                is_binary(item["description"]) and String.trim(item["description"]) != "" and
                is_list(item["source_segment_ids"]) and item["source_segment_ids"] != [] and
                Enum.all?(item["source_segment_ids"], &MapSet.member?(segments, &1))))
      end)

    if valid and length(Enum.uniq_by(items, & &1["item_id"])) == length(items),
      do: :ok,
      else: {:error, :ungrounded_action_item}
  end

  defp validate_priorities(items) do
    if Enum.all?(items, fn item ->
         is_map(item) and
           (not Map.has_key?(item, "priority") or
              item["priority"] in ~w(low medium high critical))
       end),
       do: :ok,
       else: {:error, :invalid_priority}
  end

  defp triage_item(item) do
    # The validated association is authoritative; do not let a separate,
    # unvalidated singular identity redirect the existing reconciler.
    item = item |> Map.delete("candidate_id") |> Map.put_new("priority", "medium")

    case item["candidate_ids"] do
      [id] -> Map.put(item, "candidate_id", id)
      _ -> item
    end
  end

  # An officer must explicitly account for accepted actions. Transcript-only
  # actions use an empty list; guessing identities from title resemblance is
  # forbidden. Legacy callbacks remain valid when there are no accepted actions.
  defp validate_candidate_provenance(items, run, meeting) do
    accepted = MapSet.new(accepted_actions(meeting), & &1.id)

    valid =
      Enum.all?(items, fn item ->
        ids = item["candidate_ids"]
        previous = (run.item_results || %{})[item["item_id"]]

        (is_list(ids) or (is_nil(ids) and MapSet.size(accepted) == 0)) and
          Enum.all?(ids || [], &MapSet.member?(accepted, &1)) and
          (is_nil(previous) or Enum.sort(previous["candidate_ids"] || []) == Enum.sort(ids || []))
      end)

    covered =
      MapSet.new(
        Enum.flat_map(items, fn item ->
          if is_list(item["candidate_ids"]), do: item["candidate_ids"], else: []
        end) ++
          Enum.flat_map(run.item_results || %{}, fn {_key, entry} ->
            entry["candidate_ids"] || []
          end)
      )

    if valid and MapSet.subset?(accepted, covered),
      do: :ok,
      else: {:error, :invalid_candidate_provenance}
  end

  defp accepted_actions(meeting) do
    Repo.all(
      from(c in MeetingCandidate,
        where: c.meeting_id == ^meeting.id and c.disposition == :accepted,
        where: c.classified_intent == "action_items",
        where:
          is_nil(c.closed_reason) or c.closed_reason not in [:retracted, :duplicate, :vetoed],
        order_by: [asc: c.inserted_at, asc: c.id],
        select: %{id: c.id, quote: c.evidence_quote, canvas_id: c.canvas_id}
      )
    )
  end

  defp canvas_item_ids(%{"type" => "checklist_item", "id" => id} = node),
    do: [id | Enum.flat_map(Map.get(node, "children", []), &canvas_item_ids/1)]

  defp canvas_item_ids(map) when is_map(map),
    do: Enum.flat_map(Map.values(map), &canvas_item_ids/1)

  defp canvas_item_ids(list) when is_list(list), do: Enum.flat_map(list, &canvas_item_ids/1)
  defp canvas_item_ids(_), do: []

  defp advance(run, meeting) do
    case if(run.capture_finished_at, do: snapshot(meeting), else: {:error, :capture_active}) do
      {:ok, snap, transcript} ->
        run =
          if snapshot_hash(run, snap) != run.snapshot_hash,
            do:
              save(run,
                snapshot: snap,
                snapshot_hash: snapshot_hash(run, snap),
                transcript_id: transcript.id,
                status: "scribe_pending",
                dispatched_at: nil
              ),
            else: run

        cond do
          run.status == "filed" ->
            result(run)

          run.dispatched_at && DateTime.diff(DateTime.utc_now(), run.dispatched_at) < 120 ->
            result(run)

          run.canvas_id && run.status in ["triage_pending", "triage_dispatched"] ->
            dispatch_triage(run, meeting)

          true ->
            dispatch(
              run,
              "meeting_scribe",
              fn agent ->
                payload = payload(run, meeting)
                {:ok, prompt} = CompletionPrompt.render(:scribe, payload, meeting)

                Platform.Federation.dispatch_scribe_attention(
                  agent,
                  payload
                  |> Map.put(:reason, "meeting_scribe_completion")
                  |> Map.put(:prompt, prompt)
                )
              end,
              "scribe_dispatched"
            )
        end

      {:error, reason} ->
        save(run, status: "waiting", last_error: Atom.to_string(reason))
        {:error, reason}
    end
  end

  @doc "Current bounded, owned transcript snapshot, shared with briefing readiness."
  def snapshot(meeting) do
    room = Repo.get_by(Room, space_id: meeting.chat_space_id)

    transcripts =
      Repo.all(
        from(t in Transcript,
          where: t.space_id == ^meeting.chat_space_id,
          order_by: [asc: t.started_at, asc: t.id]
        )
      )
      |> Enum.filter(&belongs_to_meeting?(&1, meeting))

    canonical = Enum.find(Enum.reverse(transcripts), &(&1.status == "complete"))

    # The room-finished fence is capture completion. Recording `processing`
    # means MP4/file finalization after capture stopped, not pending speech;
    # it must not hold an already-final transcript hostage.
    cond do
      room && room.status != "idle" ->
        {:error, :capture_active}

      Enum.any?(
        transcripts,
        &(&1.status == "processing" or (&1.status == "recording" and &1.segments != []))
      ) ->
        {:error, :transcription_pending}

      is_nil(canonical) ->
        {:error, :transcription_pending}

      true ->
        segments =
          Enum.flat_map(transcripts, fn t ->
            Enum.map(
              t.segments || [],
              &Map.put(&1, "source_transcript_id", t.id)
            )
          end)
          |> Enum.sort_by(&{&1["spoken_at"] || "", &1["start_time"] || 0, &1["id"] || ""})

        {:ok,
         %{"source_transcript_ids" => Enum.map(transcripts, & &1.id), "segments" => segments},
         canonical}
    end
  end

  def belongs_to_meeting?(%Transcript{meeting_id: id}, %Meeting{id: id}) when not is_nil(id),
    do: true

  def belongs_to_meeting?(%Transcript{meeting_id: id}, _) when not is_nil(id), do: false

  def belongs_to_meeting?(transcript, meeting) do
    started_at = transcript.started_at || transcript.inserted_at

    not is_nil(meeting.started_at) and DateTime.compare(started_at, meeting.started_at) != :lt and
      (is_nil(meeting.ended_at) or DateTime.compare(started_at, meeting.ended_at) != :gt)
  end

  defp dispatch_triage(run, _meeting) do
    dispatch(
      run,
      "triage_officer",
      fn _agent ->
        Meetings.on_scribe_canvas_created(
          Repo.get!(Transcript, run.transcript_id),
          Repo.get!(Canvas, run.canvas_id)
        )
      end,
      "triage_dispatched"
    )
  end

  def dispatch_payload(transcript_id),
    do: transcript_id |> dispatch_payload_with_meeting() |> elem(0)

  @doc """
  `dispatch_payload/1` plus the meeting it was built from (`nil` when the
  transcript has no completion run), so the triage dispatch can render its
  prompt without re-querying the meeting.
  """
  def dispatch_payload_with_meeting(transcript_id) do
    case Repo.one(from(r in CompletionRun, where: r.transcript_id == ^transcript_id)) do
      nil ->
        {%{}, nil}

      run ->
        meeting = Repo.get!(Meeting, run.meeting_id)
        {payload(run, meeting), meeting}
    end
  end

  defp payload(run, meeting),
    do: %{
      meeting_id: meeting.id,
      run_id: run.id,
      space_id: meeting.chat_space_id,
      room_id: meeting.livekit_room_name,
      transcript_id: run.transcript_id,
      canvas_id: run.canvas_id,
      snapshot_hash: run.snapshot_hash,
      completion_transcript: run.snapshot["segments"],
      source_transcript_ids: run.snapshot["source_transcript_ids"],
      accepted_action_candidates: accepted_actions(meeting),
      candidate_provenance_instructions:
        "For each accepted_action_candidates entry, preserve its id in the final checklist note and submit that id in candidate_ids on the matching meeting_triage_file action item. Every accepted action must be explicitly accounted for by a filed item or an explicit exclude/duplicate/conflict decision. Use candidate_ids: [] for novel transcript-only follow-ups. Never infer candidate identity from title similarity; preserve item_id on replay."
    }

  defp dispatch(run, role, fun, status) do
    outcome =
      case Platform.Roles.agent_id_for_role(role) do
        nil -> {:error, :role_unassigned}
        agent -> fun.(agent)
      end

    case outcome do
      :ok ->
        save(run, status: status, last_error: nil, dispatched_at: DateTime.utc_now()) |> result()

      {:error, reason} ->
        save(run, last_error: inspect(reason), dispatched_at: nil)
        {:error, reason}
    end
  end

  defp locked(meeting_id, fun) do
    case Repo.transaction(fn ->
           case Repo.one(
                  from(r in CompletionRun, where: r.meeting_id == ^meeting_id, lock: "FOR UPDATE")
                ) do
             nil -> {:error, :run_not_found}
             run -> fun.(run)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp save(run, attrs), do: run |> Ecto.Changeset.change(attrs) |> Repo.update!()

  @doc "Callback identity includes the persisted reopen generation, even when speech is unchanged."
  def snapshot_hash(run, snapshot),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary({run.generation, snapshot})) |> Base.encode16()

  defp result(run),
    do:
      {:ok,
       %{
         meeting_id: run.meeting_id,
         run_id: run.id,
         status: run.status,
         canvas_id: run.canvas_id,
         task_ids: Enum.flat_map(run.item_results, fn {_, v} -> v["task_ids"] || [] end)
       }}
end

