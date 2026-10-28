defmodule Platform.Meetings.CandidateSweeperTest do
  @moduledoc "Live task candidates never fire; artifact countdowns still create canvases."

  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.CandidateSweeper
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo
  alias Platform.Tasks.Task, as: WorkTask

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Sweeper Project #{n}",
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Sweeper Meeting #{n}",
        slug: "sweeper-meeting-#{n}"
      })

    meeting
    |> Meetings.Meeting.status_changeset("live", %{started_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  # A real host participant, so an `:artifact` candidate has somebody to
  # be `created_by`. `Chat.Canvas` validates `created_by` as required, so
  # without this the artifact branch would fail its mint and the test
  # would be asserting the failure path while claiming to assert the
  # success one.
  defp with_host!(meeting) do
    {:ok, participant} =
      Platform.Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Sweeper Host",
        joined_at: DateTime.utc_now()
      })

    meeting
    |> Meetings.Meeting.changeset(%{host_participant_id: participant.id})
    |> Repo.update!()
  end

  # A card in the state the live rail leaves one in: heard, then
  # classified a second or two later by the mirror. The second half is
  # `IntentQueue.Server.mirror_enqueue/3`'s exact call.
  #
  # It is part of the fixture rather than of the individual tests
  # because a card the classifier has NOT answered for is not eligible
  # to graduate — see "a candidate the classifier has not answered for
  # yet" below — and every test in this file is about timing,
  # exactly-once, automation or the stop button, none of which are
  # questions about the model's answer. `classify: false` opts out, and
  # is what that one describe block uses.
  defp heard!(meeting, at, opts \\ []) do
    chunk_id = Ecto.UUID.generate()
    text = Keyword.get(opts, :text, "we should build the CSV export")
    speaker = Keyword.get(opts, :speaker, "alice")
    outcome_kind = Keyword.get(opts, :outcome_kind, :task)

    {:ok, candidate} =
      Candidates.record_heard(%{
        meeting_id: meeting.id,
        transcript_chunk_id: chunk_id,
        evidence_quote: text,
        speaker: speaker,
        heard_at: at,
        outcome_kind: outcome_kind
      })

    if Keyword.get(opts, :classify, true) do
      {intent, role} = classification_for(outcome_kind)

      {:ok, _} =
        Candidates.create_or_attach(%{
          intent_id: Ecto.UUID.generate(),
          meeting_id: meeting.id,
          transcript_chunk_id: chunk_id,
          transcript_chunk_ids: [chunk_id],
          evidence_quote: text,
          speaker: speaker,
          classified_intent: intent,
          target_role: role,
          state: :heard,
          queue_status: "queued",
          outcome_kind: outcome_kind,
          heard_at: at,
          last_utterance_at: at
        })
    end

    candidate
  end

  defp classification_for(:artifact), do: {"visual_adjust", "designer"}
  defp classification_for(_), do: {"action_items", "meeting_scribe"}

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  defp tasks_for(project_id) do
    Repo.all(from(t in WorkTask, where: t.project_id == ^project_id))
  end

  test "task skeletons and classified task candidates never arm, even with explicit deadlines" do
    meeting = meeting!()
    now = DateTime.utc_now()

    for classify <- [true, false] do
      candidate = heard!(meeting, now, classify: classify, speaker: Ecto.UUID.generate())
      assert is_nil(reload!(candidate).acts_at)
    end

    {:ok, candidate} =
      Candidates.create(%{
        meeting_id: meeting.id,
        evidence_quote: "a raw utterance",
        outcome_kind: :task,
        classified_intent: "open_question",
        target_role: "meeting_scribe",
        acts_at: now
      })

    assert is_nil(candidate.acts_at)
    assert CandidateSweeper.sweep(now: DateTime.add(now, 1000, :second)) == []
    assert tasks_for(meeting.project_id) == []
  end

  test "stale task rows cannot be claimed, fired directly, graduated or rearmed" do
    meeting = meeting!()
    now = DateTime.utc_now()
    candidate = heard!(meeting, now)

    candidate =
      candidate
      |> Ecto.Changeset.change(acts_at: DateTime.add(now, -60, :second))
      |> Repo.update!()

    assert Candidates.claim_due(now) == []
    assert CandidateSweeper.sweep(now: now) == []
    assert {:error, :task_requires_triage} = Candidates.fire(candidate)
    assert {:error, :task_requires_triage} = Candidates.graduate(candidate.id)
    assert {:error, :not_armed} = Candidates.rearm(candidate, now)
    assert tasks_for(meeting.project_id) == []
  end

  test "concurrent acknowledgement and sweep of stale task rows mint nothing" do
    meeting = meeting!()
    now = DateTime.utc_now()
    candidate = heard!(meeting, now)

    candidate =
      candidate
      |> Ecto.Changeset.change(acts_at: DateTime.add(now, -60, :second))
      |> Repo.update!()

    parent = self()

    jobs = [
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        Candidates.complete_by_ack(candidate)
      end),
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        CandidateSweeper.sweep(now: now)
      end)
    ]

    Enum.each(jobs, &Task.await/1)
    assert tasks_for(meeting.project_id) == []
    row = reload!(candidate)
    assert row.state == :closed
    assert row.disposition == :accepted
    assert row.acts_at == nil
  end

  test "artifact deadline still fires a canvas exactly once and no task" do
    meeting = meeting!() |> with_host!()
    now = DateTime.utc_now()
    candidate = heard!(meeting, now, outcome_kind: :artifact) |> reload!()
    assert %DateTime{} = candidate.acts_at
    assert CandidateSweeper.sweep(now: DateTime.add(candidate.acts_at, -1, :second)) == []
    assert [fired] = CandidateSweeper.sweep(now: candidate.acts_at)
    assert fired.id == candidate.id
    assert fired.canvas_id
    assert Repo.get(Platform.Chat.Canvas, fired.canvas_id)
    assert fired.task_id == nil
    assert fired.closed_reason == :done
    assert CandidateSweeper.sweep(now: candidate.acts_at) == []
    assert tasks_for(meeting.project_id) == []
  end

  test "artifact claims stay exactly once under concurrent sweepers" do
    meeting = meeting!() |> with_host!()
    candidate = heard!(meeting, DateTime.utc_now(), outcome_kind: :artifact) |> reload!()
    parent = self()

    jobs =
      for _ <- 1..2,
          do:
            Task.async(fn ->
              Sandbox.allow(Repo, parent, self())
              CandidateSweeper.sweep(now: candidate.acts_at)
            end)

    assert jobs |> Enum.flat_map(&Task.await/1) |> length() == 1

    assert Repo.aggregate(
             from(c in Platform.Chat.Canvas, where: c.space_id == ^meeting.chat_space_id),
             :count
           ) == 1

    assert tasks_for(meeting.project_id) == []
  end

  test "muting suppresses artifact countdown until automation resumes" do
    meeting = meeting!() |> with_host!()
    candidate = heard!(meeting, DateTime.utc_now(), outcome_kind: :artifact) |> reload!()
    meeting |> Ecto.Changeset.change(intent_muted_at: DateTime.utc_now()) |> Repo.update!()
    assert CandidateSweeper.sweep(now: candidate.acts_at) == []
    meeting |> Repo.reload!() |> Ecto.Changeset.change(intent_muted_at: nil) |> Repo.update!()
    assert [_] = CandidateSweeper.sweep(now: candidate.acts_at)
    assert tasks_for(meeting.project_id) == []
  end

  test "unclassified artifact orphans are reaped after grace, without deliverables" do
    meeting = meeting!()
    now = DateTime.utc_now()
    candidate = heard!(meeting, now, outcome_kind: :artifact, classify: false)
    assert candidate.acts_at
    grace = CandidateSweeper.default_unclassified_grace_ms()
    before = DateTime.add(candidate.acts_at, grace - 1, :millisecond)
    assert %{fired: [], reaped: []} = CandidateSweeper.sweep_all(now: before)

    assert %{fired: [], reaped: [reaped]} =
             CandidateSweeper.sweep_all(now: DateTime.add(before, 1, :millisecond))

    assert reaped.id == candidate.id
    assert reaped.closed_reason == :unclassified
    assert reaped.disposition == :timed_out
    assert tasks_for(meeting.project_id) == []
  end

  @classifier_providers [
    Platform.Agents.Providers.Ollama,
    Platform.Agents.Providers.Anthropic,
    Platform.Agents.Providers.OpenAI,
    Platform.Agents.Providers.Codex
  ]

  test "the default grace is at or above every provider's receive timeout" do
    grace = CandidateSweeper.default_unclassified_grace_ms()

    # Every concrete provider module is accounted for, so a new adapter
    # cannot ship without being pinned here.
    concrete =
      "../../../lib/platform/agents/providers/*.ex"
      |> Path.expand(__DIR__)
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".ex"))
      |> Enum.reject(&(&1 == "provider"))
      |> Enum.sort()

    pinned =
      @classifier_providers
      |> Enum.map(&(&1 |> Module.split() |> List.last() |> String.downcase()))
      |> Enum.sort()

    assert concrete == pinned

    for provider <- @classifier_providers do
      Code.ensure_loaded!(provider)

      assert function_exported?(provider, :receive_timeout_ms, 0),
             "#{inspect(provider)} exposes no receive_timeout_ms/0 to pin against"

      timeout = provider.receive_timeout_ms()

      assert grace >= timeout,
             "#{inspect(provider)} allows a #{timeout}ms model call but the reaper's grace " <>
               "is #{grace}ms — a genuine late answer would be reaped"
    end
  end
end
