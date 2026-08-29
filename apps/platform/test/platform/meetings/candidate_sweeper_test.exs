defmodule Platform.Meetings.CandidateSweeperTest do
  @moduledoc """
  The countdown actually firing, with nobody watching, exactly once
  (task 01a03fba stage 3).

  `async: false` so `Platform.DataCase` puts the sandbox in shared mode:
  the exactly-once test needs two REAL concurrent processes contending
  for one row, and in `async: true` neither of them could reach the
  Repo.

  ## The trap this file is written against

  A countdown that never fires and a countdown that always fires both
  pass a test that only asks "did something happen eventually". So the
  timing claim here is a BRACKET on one candidate: a sweep one second
  before its deadline must leave it untouched, and a sweep at its
  deadline must fire it. An implementation with the comparison inverted,
  dropped, or off by the whole countdown fails one half or the other.
  """

  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Meetings
  alias Platform.Meetings.CandidateEvents
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
        org_id: Platform.Tenancy.get_org_by_slug!("fabrikam").id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Sweeper Meeting #{n}",
        slug: "sweeper-meeting-#{n}"
      })

    meeting
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

  defp heard!(meeting, at, opts \\ []) do
    {:ok, candidate} =
      Candidates.record_heard(%{
        meeting_id: meeting.id,
        transcript_chunk_id: Ecto.UUID.generate(),
        evidence_quote: Keyword.get(opts, :text, "we should build the CSV export"),
        speaker: Keyword.get(opts, :speaker, "alice"),
        heard_at: at,
        outcome_kind: Keyword.get(opts, :outcome_kind, :task)
      })

    candidate
  end

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  defp tasks_for(project_id) do
    Repo.all(from(t in WorkTask, where: t.project_id == ^project_id))
  end

  # ── The bracket ───────────────────────────────────────────────────────────

  describe "timing" do
    test "one second before the deadline: nothing. AT the deadline: it fires" do
      meeting = meeting!()
      at = DateTime.utc_now()
      candidate = heard!(meeting, at)

      acts_at = reload!(candidate).acts_at
      assert DateTime.diff(acts_at, at, :second) == 30

      # ── one second early ──
      early = DateTime.add(acts_at, -1, :second)

      assert CandidateSweeper.sweep(now: early) == []

      still_open = reload!(candidate)
      assert still_open.state == :heard
      # The deadline is untouched — an implementation that "claimed" it
      # and then declined to mint would show a nil `acts_at` here.
      assert still_open.acts_at == acts_at
      assert tasks_for(meeting.project_id) == []

      # ── at the deadline, same candidate, same sweeper ──
      assert [fired] = CandidateSweeper.sweep(now: acts_at)
      assert fired.id == candidate.id

      row = reload!(candidate)
      assert row.state == :closed
      assert row.disposition == :accepted
      assert row.closed_reason == :done
      assert row.task_id
      assert is_nil(row.acts_at)

      assert [task] = tasks_for(meeting.project_id)
      assert task.id == row.task_id
    end

    test "a disarmed candidate is never swept, however overdue its meeting is" do
      meeting = meeting!()
      overdue = DateTime.add(DateTime.utc_now(), -600, :second)

      disarmed = heard!(meeting, overdue, text: "we should redo the billing page")
      {:ok, _} = Candidates.stop(disarmed, Ecto.UUID.generate())

      armed = heard!(meeting, overdue, speaker: "bob", text: "somebody rewrite the FAQ copy")

      fired = CandidateSweeper.sweep(now: DateTime.utc_now())
      fired_ids = Enum.map(fired, & &1.id)

      # The refutation...
      refute disarmed.id in fired_ids
      # ...and the control that makes it mean something: the SAME sweep
      # fired the other card. A sweeper that returned `[]` unconditionally
      # would fail here.
      assert armed.id in fired_ids
    end
  end

  # ── Nobody watching ───────────────────────────────────────────────────────

  describe "with no LiveView mounted" do
    test "the deliverable exists in the database and the card is closed and accepted" do
      # The ticket's actual acceptance criterion: a closed tab must not
      # stop the card firing. Nothing in this test mounts, renders or
      # subscribes anything — every assertion is a Repo read.
      meeting = meeting!()
      candidate = heard!(meeting, DateTime.add(DateTime.utc_now(), -60, :second))

      assert [_] = CandidateSweeper.sweep(now: DateTime.utc_now())

      row = Repo.get!(MeetingCandidate, candidate.id)
      assert row.state == :closed
      assert row.disposition == :accepted

      assert [task] = tasks_for(meeting.project_id)
      assert task.id == row.task_id
      assert task.title =~ "CSV export"
    end

    test "an :artifact candidate mints a canvas and NO task" do
      meeting = with_host!(meeting!())

      candidate =
        heard!(meeting, DateTime.add(DateTime.utc_now(), -60, :second),
          outcome_kind: :artifact,
          text: "we should sketch the pricing comparison"
        )

      assert [_] = CandidateSweeper.sweep(now: DateTime.utc_now())

      row = reload!(candidate)
      assert row.canvas_id
      assert is_nil(row.task_id)
      assert tasks_for(meeting.project_id) == []
    end

    test "the fire narrates itself on the existing candidate event stream" do
      meeting = meeting!()
      candidate = heard!(meeting, DateTime.add(DateTime.utc_now(), -60, :second))

      Meetings.PubSub.subscribe_candidate_events(meeting.id)

      assert [_] = CandidateSweeper.sweep(now: DateTime.utc_now())

      assert_receive {:candidate_event, %{kind: :countdown_fired}}
      assert :countdown_fired in CandidateEvents.kinds_for_candidate(candidate.id)
    end

    test "telemetry names the candidate and its deliverable" do
      meeting = meeting!()
      candidate = heard!(meeting, DateTime.add(DateTime.utc_now(), -60, :second))

      parent = self()
      handler = "countdown-fired-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        CandidateSweeper.telemetry_event(),
        fn _event, measurements, metadata, _ ->
          send(parent, {:fired, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert [_] = CandidateSweeper.sweep(now: DateTime.utc_now())

      assert_receive {:fired, %{count: 1}, %{candidate_id: id, task_id: task_id}}
      assert id == candidate.id
      assert task_id
    end
  end

  # ── Automation off ────────────────────────────────────────────────────────

  describe "automation mode" do
    test "a mute placed AFTER arming suppresses the fire, and lifting it restores it" do
      meeting = meeting!()
      candidate = heard!(meeting, DateTime.add(DateTime.utc_now(), -60, :second))

      # Armed while automated, so the row carries a past deadline.
      assert %DateTime{} = reload!(candidate).acts_at

      {:ok, _} = Meetings.set_automation_mode(meeting, :off)

      # The refutation: the claim re-checks the mode, so a meeting muted
      # mid-countdown does not fire. This is the half that a check only
      # at arming time would miss.
      assert CandidateSweeper.sweep(now: DateTime.utc_now()) == []
      assert reload!(candidate).state == :heard

      # The control, on the SAME row: with the mute lifted it fires. A
      # claim query that returned `[]` unconditionally fails here.
      {:ok, _} = Meetings.set_automation_mode(meeting, :automated)
      assert [fired] = CandidateSweeper.sweep(now: DateTime.utc_now())
      assert fired.id == candidate.id
    end
  end

  # ── Exactly once ──────────────────────────────────────────────────────────

  describe "exactly once" do
    test "two concurrent sweeps over one overdue candidate produce ONE task" do
      # There is no advisory lock, leader election or `:global`
      # registration anywhere in `lib/`, so nothing outside the claim
      # statement makes this safe. Dropping the `WHERE` predicate from
      # `Candidates.claim_ids/2` is the named mutation for this test.
      meeting = meeting!()
      candidate = heard!(meeting, DateTime.add(DateTime.utc_now(), -60, :second))
      now = DateTime.utc_now()

      parent = self()

      results =
        1..2
        |> Enum.map(fn _ ->
          Elixir.Task.async(fn ->
            Sandbox.allow(Repo, parent, self())
            CandidateSweeper.sweep(now: now)
          end)
        end)
        |> Elixir.Task.await_many(10_000)

      # Exactly one sweep claimed it...
      assert Enum.count(results, &(&1 != [])) == 1
      assert [[fired]] = Enum.reject(results, &(&1 == []))
      assert fired.id == candidate.id

      # ...and — the assertion that actually matters — one task exists,
      # not two. This is what a dropped claim predicate breaks.
      assert [_one] = tasks_for(meeting.project_id)
    end

    test "sweeping twice in a row also produces one task" do
      # The sequential half. MEASURED, and reported rather than dressed
      # up: this test does NOT redden when the `WHERE` predicates are
      # dropped from `claim_ids/2`. It cannot, because by the second
      # sweep `graduate/2` has already closed the row and the `due_ids`
      # read excludes `:closed` on its own. The concurrent test above is
      # the only thing that catches that mutation, and this one is kept
      # for what it does prove — that a claimed row is not re-offered on
      # the next tick, which is the ordinary once-a-second case.
      meeting = meeting!()
      candidate = heard!(meeting, DateTime.add(DateTime.utc_now(), -60, :second))
      now = DateTime.utc_now()

      assert [fired] = CandidateSweeper.sweep(now: now)
      assert fired.id == candidate.id
      assert CandidateSweeper.sweep(now: now) == []
      assert [_one] = tasks_for(meeting.project_id)
    end

    test "a failed mint leaves the row disarmed rather than retrying forever" do
      meeting = meeting!()
      candidate = heard!(meeting, DateTime.add(DateTime.utc_now(), -60, :second))

      # Freeze the project so `Tasks.create_task/2` refuses through
      # `Tenancy.Lifecycle.ensure_project_writable/1`, which reads
      # `projects.archived_at`. Stamped directly rather than through
      # `Lifecycle.archive_project/2` so the test does not also have to
      # build an actor with archive authority.
      {1, _} =
        Repo.update_all(
          from(p in Platform.Tasks.Project, where: p.id == ^meeting.project_id),
          set: [archived_at: DateTime.utc_now()]
        )

      refute Platform.Tenancy.Lifecycle.project_writable?(meeting.project_id)

      assert CandidateSweeper.sweep(now: DateTime.utc_now()) == []

      row = reload!(candidate)
      # It WAS claimed — the claim and the mint are separate steps.
      assert row.state == :acting
      assert is_nil(row.acts_at)
      assert is_nil(row.task_id)

      # And it is not re-armed, so the next tick does not retry a
      # permanent error every second for the life of the meeting.
      assert CandidateSweeper.sweep(now: DateTime.utc_now()) == []
    end
  end

  # ── The GenServer ─────────────────────────────────────────────────────────

  describe "the sweeper process" do
    test "ticks on its own and fires without anybody calling sweep/1" do
      meeting = meeting!()
      candidate = heard!(meeting, DateTime.add(DateTime.utc_now(), -60, :second))

      name = :"countdown_sweeper_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {CandidateSweeper, tick_interval_ms: 25, name: name},
          id: name
        )

      Sandbox.allow(Repo, self(), pid)

      assert_eventually(fn -> reload!(candidate).state == :closed end)
      assert reload!(candidate).task_id
    end
  end
end
