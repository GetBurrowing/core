defmodule Platform.Meetings.Completion do
  @moduledoc """
  One persisted completion run per meeting. Capture and summarization finish
  before the scribe sees an ordered snapshot; only the triage officer files.
  Dispatch delivery is not completion: callbacks advance the durable run.
  """
  import Ecto.Query
  alias Platform.{Repo, Meetings}
  alias Platform.Meetings.{Meeting, Transcript, Room, Recording, CompletionRun, Triage}
  alias Platform.Chat.Canvas

  def resume(meeting_id) do
    with %Meeting{status: "ended"} = meeting <- Repo.get(Meeting, meeting_id) do
      Repo.insert!(%CompletionRun{meeting_id: meeting.id},
        on_conflict: :nothing,
        conflict_target: :meeting_id
      )

      locked(meeting.id, fn run -> advance(run, meeting) end)
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
      set: [
        capture_finished_at: nil,
        dispatched_at: nil,
        status: "waiting",
        snapshot_hash: nil
      ]
    )

    :ok
  end

  def sweep do
    Repo.all(from(r in CompletionRun, where: r.status != "filed", select: r.meeting_id))
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
          run = save(run, canvas_id: canvas.id, status: "triage_pending", last_error: nil)
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
           :ok <- validate_items(items, run, canvas) do
        {ledger, errors} =
          Enum.reduce(items, {run.item_results, []}, fn item, {ledger, errors} ->
            key = item["item_id"]

            cond do
              Map.has_key?(ledger, key) ->
                {ledger, errors}

              item["decision"] in ["duplicate", "conflict", "exclude"] ->
                {Map.put(ledger, key, %{"status" => item["decision"]}), errors}

              true ->
                case Triage.file_tasks_from_canvas(canvas,
                       project_id: meeting.project_id,
                       meeting_id: meeting.id,
                       transcript_id: run.transcript_id,
                       agent_id: agent_id,
                       action_items: [item],
                       extra_metadata: %{
                         "completion_run_id" => run.id,
                         "completion_item_id" => key,
                         "source_segment_ids" => item["source_segment_ids"]
                       }
                     ) do
                  {:ok, %{errors: []} = filed} ->
                    entry = %{
                      "status" => "processed",
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
      locked(meeting.id, fn run ->
        current = Repo.one!(from(m in Meeting, where: m.id == ^meeting.id, lock: "FOR UPDATE"))

        with true <- current.status == "ended" || {:error, :meeting_not_finalized},
             true <- not is_nil(run.capture_finished_at) || {:error, :capture_active},
             true <-
               (run.id == params["run_id"] and run.transcript_id == params["transcript_id"] and
                  run.snapshot_hash == params["snapshot_hash"]) || {:error, :run_mismatch},
             {:ok, snapshot, _} <- snapshot(meeting),
             true <- hash(snapshot) == run.snapshot_hash || {:error, :transcript_changed} do
          fun.(run, meeting, canvas)
        end
      end)
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
          if hash(snap) != run.snapshot_hash,
            do:
              save(run,
                snapshot: snap,
                snapshot_hash: hash(snap),
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
                Platform.Federation.dispatch_scribe_attention(
                  agent,
                  payload(run, meeting)
                  |> Map.put(:reason, "meeting_scribe_completion")
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

  defp snapshot(meeting) do
    room = Repo.get_by(Room, space_id: meeting.chat_space_id)

    transcripts =
      Repo.all(
        from(t in Transcript,
          where: t.space_id == ^meeting.chat_space_id,
          order_by: [asc: t.started_at, asc: t.id]
        )
      )
      |> Enum.filter(&belongs_to_meeting?(&1, meeting))

    active_recording =
      room &&
        Repo.exists?(
          from(r in Recording,
            where: r.room_id == ^room.id and r.status in ["recording", "processing"]
          )
        )

    canonical = Enum.find(Enum.reverse(transcripts), &(&1.status == "complete"))

    cond do
      room && room.status != "idle" ->
        {:error, :capture_active}

      active_recording ->
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

  defp belongs_to_meeting?(%Transcript{meeting_id: id}, %Meeting{id: id}) when not is_nil(id),
    do: true

  defp belongs_to_meeting?(%Transcript{meeting_id: id}, _) when not is_nil(id), do: false

  defp belongs_to_meeting?(transcript, meeting) do
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

  def dispatch_payload(transcript_id) do
    case Repo.one(from(r in CompletionRun, where: r.transcript_id == ^transcript_id)) do
      nil -> %{}
      run -> payload(run, Repo.get!(Meeting, run.meeting_id))
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
      source_transcript_ids: run.snapshot["source_transcript_ids"]
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

  defp hash(snapshot),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(snapshot)) |> Base.encode16()

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
