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

  # ── The state the live rail actually leaves a card in ─────────────────────

  describe "a card an agent has already picked up" do
    # The 0/280 bug (task 01a06575 stage 2), pinned close to the guard.
    #
    # Every test above starts from `record_heard/1` and a card that
    # stays `:heard` — a state the live pipeline leaves a card in for
    # about one second. What it really produces is `:acting`, written by
    # `IntentQueue.Server`'s ack mirror when the recipient agent answers
    # `intent_ack(status: :working)`, and `claim_due/2` used to treat
    # that as "already claimed by a sweeper" and skip it forever.
    test "is still claimed at its deadline: :acting is not a disarm" do
      meeting = meeting!()
      overdue = DateTime.add(DateTime.utc_now(), -60, :second)

      acked = heard!(meeting, overdue, text: "Priya will write the migration")
      # Exactly what `apply_ack_status(candidate, :working)` does.
      {:ok, acked} = Candidates.advance(acked, :acting, %{queue_status: "acked"})

      assert acked.state == :acting
      # Still armed. The ack does not and must not disarm the countdown:
      # the cursor gates dispatch, the countdown gates graduation.
      assert acked.acts_at

      fired_ids = CandidateSweeper.sweep(now: DateTime.utc_now()) |> Enum.map(& &1.id)

      assert acked.id in fired_ids

      row = reload!(acked)
      assert row.task_id
      assert [task] = tasks_for(meeting.project_id)
      assert task.id == row.task_id
    end

    # The refutation that keeps the test above from passing for the
    # wrong reason. `:acting` is not a blanket free pass — a row the
    # SWEEPER claimed is `:acting` too, and it is disarmed, and it must
    # stay unclaimable.
    test "but a sweeper-claimed row (:acting AND disarmed) is not re-claimed" do
      meeting = meeting!()
      overdue = DateTime.add(DateTime.utc_now(), -60, :second)

      claimed = heard!(meeting, overdue, text: "somebody redo the onboarding email")
      {:ok, claimed} = Candidates.advance(claimed, :acting, %{})

      {1, _} =
        Repo.update_all(
          from(c in MeetingCandidate, where: c.id == ^claimed.id),
          set: [acts_at: nil]
        )

      # A control on the same sweep, so a sweeper that fired nothing
      # cannot pass this.
      live = heard!(meeting, overdue, speaker: "bob", text: "and rewrite the FAQ copy")

      fired_ids = CandidateSweeper.sweep(now: DateTime.utc_now()) |> Enum.map(& &1.id)

      refute claimed.id in fired_ids
      assert live.id in fired_ids
      assert is_nil(reload!(claimed).task_id)
    end

    test "a human can still stop it — an ack is not the sweeper winning" do
      meeting = meeting!()
      card = heard!(meeting, DateTime.utc_now(), text: "we should ship the CSV export")
      {:ok, card} = Candidates.advance(card, :acting, %{queue_status: "acked"})

      # Before task 01a06575 stage 2 this answered `{:error, :already_fired}`
      # — telling the human a task existed when none did.
      assert {:ok, stopped} = Candidates.stop(card, Ecto.UUID.generate())
      assert stopped.state == :closed
      assert stopped.closed_reason == :dismissed
      assert is_nil(reload!(card).acts_at)

      # And the stop actually held: the deadline has passed and nothing
      # fires.
      assert CandidateSweeper.sweep(now: DateTime.add(DateTime.utc_now(), 60, :second)) == []
      assert tasks_for(meeting.project_id) == []
    end

    test "stopping a row the sweeper claimed is still refused, even with no deliverable" do
      # The half `stop/2`'s `disposition == :accepted` pre-check cannot
      # answer: a claimed row whose mint FAILED carries no disposition,
      # so the refusal has to come from `do_stop/3`'s WHERE.
      meeting = meeting!()
      card = heard!(meeting, DateTime.add(DateTime.utc_now(), -60, :second))

      {1, _} =
        Repo.update_all(
          from(p in Platform.Tasks.Project, where: p.id == ^meeting.project_id),
          set: [archived_at: DateTime.utc_now()]
        )

      assert CandidateSweeper.sweep(now: DateTime.utc_now()) == []

      row = reload!(card)
      assert row.state == :acting
      assert is_nil(row.acts_at)
      assert is_nil(row.disposition)

      assert {:error, :already_fired} = Candidates.stop(card, Ecto.UUID.generate())
    end
  end

  # ── An unvetted card never graduates ──────────────────────────────────────

  describe "a candidate the classifier has not answered for yet" do
    # Task 01a06575, round 3, door 2 — reproduced on a real clock with
    # nothing killed.
    #
    # The skeleton is armed at the moment somebody SPOKE, deliberately:
    # anchoring the deadline to the classification instead would move it
    # by the model's latency. The answer normally lands a second or two
    # later. But the providers set `receive_timeout: 60_000` —
    # `Platform.Agents.Providers.Anthropic`, `.OpenAI` and `.Codex` — which
    # is DOUBLE this countdown, so a classification taking 31 to 60
    # seconds is inside what the HTTP client permits and outside what
    # the countdown tolerates. The sweeper ticks every second, so the
    # window is wide open.
    #
    # `routable_attrs?/1` cannot close it: every other outcome (a model
    # error, a dedupe, an unqueued chunk) closes the skeleton through
    # `IntentClassifier.close_skeleton/4`, but SLOW is not an outcome —
    # the sweeper arrives before any outcome exists. The card then
    # graduates carrying `classified_intent: nil`, titled with the raw
    # utterance, having been vetted by nothing.
    test "is not graduated at its deadline, and mints nothing" do
      meeting = meeting!()
      overdue = DateTime.add(DateTime.utc_now(), -60, :second)

      unvetted =
        heard!(meeting, overdue,
          classify: false,
          text: "did you catch the game last night, that last quarter was something"
        )

      # The premise: armed, overdue, and nothing has classified it.
      assert is_nil(reload!(unvetted).classified_intent)
      assert %DateTime{} = reload!(unvetted).acts_at

      assert CandidateSweeper.sweep(now: DateTime.utc_now()) == []
      assert tasks_for(meeting.project_id) == []

      row = reload!(unvetted)
      assert is_nil(row.task_id)
      refute row.state == :closed

      # And it was not claimed-and-refused either. A card whose answer is
      # merely LATE must still act on it when it arrives, so this has to
      # be an eligibility rule; claiming nils `acts_at` and would strand
      # every slow-but-real ask — which is the 0-of-280 failure the
      # previous stage of this task was about, wearing different clothes.
      assert %DateTime{} = row.acts_at
      assert row.state == :heard
    end

    test "graduates on the very next sweep once the classification lands" do
      # The positive control, on the SAME row and the same code path. A
      # sweeper that refused everything, or one that permanently stranded
      # the late card, fails here.
      meeting = meeting!()
      overdue = DateTime.add(DateTime.utc_now(), -60, :second)

      late =
        heard!(meeting, overdue,
          classify: false,
          text: "somebody should write up the migration runbook"
        )

      assert CandidateSweeper.sweep(now: DateTime.utc_now()) == []

      # The slow answer finally arrives — routable, and 60 seconds late.
      {:ok, _} =
        Candidates.create_or_attach(%{
          intent_id: Ecto.UUID.generate(),
          meeting_id: meeting.id,
          transcript_chunk_id: reload!(late).transcript_chunk_id,
          transcript_chunk_ids: [reload!(late).transcript_chunk_id],
          evidence_quote: "somebody should write up the migration runbook",
          speaker: "alice",
          classified_intent: "action_items",
          target_role: "meeting_scribe",
          state: :heard,
          queue_status: "queued",
          outcome_kind: :task,
          heard_at: overdue,
          last_utterance_at: overdue
        })

      assert [fired] = CandidateSweeper.sweep(now: DateTime.utc_now())
      assert fired.id == late.id
      assert [task] = tasks_for(meeting.project_id)
      assert task.id == reload!(late).task_id
    end

    test "a late answer of off_topic is disarmed instead, and still mints nothing" do
      # The other half of the same window: the two doors compose. The
      # unvetted card is ineligible while the model is thinking, and
      # `routable_attrs?/1` disarms it for good when the answer turns out
      # to be small talk.
      meeting = meeting!()
      overdue = DateTime.add(DateTime.utc_now(), -60, :second)
      text = "did you catch the game last night, that last quarter was something"

      small_talk = heard!(meeting, overdue, classify: false, text: text)

      assert CandidateSweeper.sweep(now: DateTime.utc_now()) == []

      {:ok, _} =
        Candidates.create_or_attach(%{
          intent_id: Ecto.UUID.generate(),
          meeting_id: meeting.id,
          transcript_chunk_id: reload!(small_talk).transcript_chunk_id,
          transcript_chunk_ids: [reload!(small_talk).transcript_chunk_id],
          evidence_quote: text,
          speaker: "alice",
          classified_intent: "off_topic",
          target_role: "meeting_scribe",
          state: :heard,
          queue_status: "queued",
          outcome_kind: :task,
          heard_at: overdue,
          last_utterance_at: overdue
        })

      assert is_nil(reload!(small_talk).acts_at)
      assert CandidateSweeper.sweep(now: DateTime.utc_now()) == []
      assert tasks_for(meeting.project_id) == []
    end
  end

  # ── The reaper ────────────────────────────────────────────────────────────

  describe "an unclassified card is reaped, not graduated" do
    # Task 01a06638 stage 2. The eligibility rule above has a tail: a
    # card whose classification NEVER arrives stays armed and overdue
    # forever, passed over on every tick. It must close — on the record,
    # with a reason — once no genuine answer can still be coming, and
    # not one second before.
    #
    # The grace here is deliberately tiny and injected through the seam;
    # the shipped default is pinned against the providers separately.
    @grace_ms 5_000

    defp reaped_handler_id, do: {__MODULE__, :reaped, self()}

    defp attach_reaped! do
      test_pid = self()

      :ok =
        :telemetry.attach(
          reaped_handler_id(),
          CandidateSweeper.reap_telemetry_event(),
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:reaped, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(reaped_handler_id()) end)
    end

    test "is left alone one second inside the grace, and closed at it" do
      attach_reaped!()
      meeting = meeting!()
      heard_at = DateTime.add(DateTime.utc_now(), -120, :second)
      orphan = heard!(meeting, heard_at, classify: false, text: "an orphan nobody classified")
      acts_at = reload!(orphan).acts_at
      assert %DateTime{} = acts_at

      # One second inside the grace: overdue, unclassified, and untouched.
      early = DateTime.add(acts_at, @grace_ms - 1_000, :millisecond)
      assert CandidateSweeper.sweep(now: early, grace_ms: @grace_ms) == []
      row = reload!(orphan)
      refute row.state == :closed
      assert row.acts_at == acts_at
      assert is_nil(row.classified_intent)
      refute_received {:reaped, _, _}

      # At the grace: closed, labelled, narrated, and nothing minted.
      at = DateTime.add(acts_at, @grace_ms, :millisecond)

      assert %{fired: [], reaped: [reaped]} =
               CandidateSweeper.sweep_all(now: at, grace_ms: @grace_ms)

      assert reaped.id == orphan.id

      row = reload!(orphan)
      assert row.state == :closed
      assert row.closed_reason == :unclassified
      assert row.disposition == :timed_out
      assert row.closed_note =~ "no classification arrived"
      assert is_nil(row.task_id)
      assert tasks_for(meeting.project_id) == []

      assert Enum.any?(CandidateEvents.list_for_candidate(orphan.id), fn event ->
               event.kind == :closed and event.detail["reason"] == "unclassified"
             end)

      assert_received {:reaped, %{count: 1, age_ms: age_ms}, metadata}
      assert age_ms >= @grace_ms
      assert metadata.candidate_id == orphan.id
      assert metadata.meeting_id == meeting.id
    end

    test "a classified card past the grace is fired, not reaped" do
      # The positive control: the reaper's predicate is `classified_intent
      # IS NULL`. A reaper that dropped it would close every overdue card.
      attach_reaped!()
      meeting = meeting!()
      heard_at = DateTime.add(DateTime.utc_now(), -120, :second)
      vetted = heard!(meeting, heard_at)
      at = DateTime.add(reload!(vetted).acts_at, @grace_ms, :millisecond)

      # The reaper on its own, BEFORE the sweep fires the card. Inside
      # one sweep the fire runs first and nils `acts_at`, which would hide
      # a reaper that had lost its `classified_intent IS NULL` predicate;
      # a card in a muted meeting, or a reaper called by anything but the
      # sweeper, has no such cover.
      assert Candidates.reap_unclassified(at, grace_ms: @grace_ms) == []
      refute reload!(vetted).state == :closed

      assert %{fired: [fired], reaped: []} =
               CandidateSweeper.sweep_all(now: at, grace_ms: @grace_ms)

      assert fired.id == vetted.id
      assert [task] = tasks_for(meeting.project_id)
      assert task.id == reload!(vetted).task_id
      refute reload!(vetted).closed_reason == :unclassified
      refute_received {:reaped, _, _}
    end

    test "a late answer inside the grace still graduates the card" do
      # The P1 this stage must not reintroduce: overdue-but-inside-grace is
      # merely late. A reaper without the grace bound closes this card
      # before its answer lands, and the answer then mints nothing.
      meeting = meeting!()
      heard_at = DateTime.add(DateTime.utc_now(), -120, :second)
      text = "somebody should write up the migration runbook"
      late = heard!(meeting, heard_at, classify: false, text: text)
      acts_at = reload!(late).acts_at
      inside = DateTime.add(acts_at, div(@grace_ms, 2), :millisecond)

      assert %{fired: [], reaped: []} =
               CandidateSweeper.sweep_all(now: inside, grace_ms: @grace_ms)

      refute reload!(late).state == :closed

      {:ok, _} =
        Candidates.create_or_attach(%{
          intent_id: Ecto.UUID.generate(),
          meeting_id: meeting.id,
          transcript_chunk_id: reload!(late).transcript_chunk_id,
          transcript_chunk_ids: [reload!(late).transcript_chunk_id],
          evidence_quote: text,
          speaker: "alice",
          classified_intent: "action_items",
          target_role: "meeting_scribe",
          state: :heard,
          queue_status: "queued",
          outcome_kind: :task,
          heard_at: heard_at,
          last_utterance_at: heard_at
        })

      assert [fired] = CandidateSweeper.sweep(now: inside, grace_ms: @grace_ms)
      assert fired.id == late.id
      assert [task] = tasks_for(meeting.project_id)
      assert task.id == reload!(late).task_id
    end

    test "sweep/1 keeps returning only the fired list" do
      meeting = meeting!()
      heard_at = DateTime.add(DateTime.utc_now(), -120, :second)
      orphan = heard!(meeting, heard_at, classify: false, text: "an orphan nobody classified")
      at = DateTime.add(reload!(orphan).acts_at, @grace_ms, :millisecond)

      assert CandidateSweeper.sweep(now: at, grace_ms: @grace_ms) == []
      assert reload!(orphan).closed_reason == :unclassified
    end

    # The shipped grace must be at or above the receive timeout of EVERY
    # provider the classifier can be configured with, or a genuine answer
    # landing inside the provider's window finds its card already closed
    # — the P1 regression in a new coat. Ollama (the default,
    # `IntentClassifier.init/1`) allows 300_000 ms; the others 60_000.
    # Ollama's number is runtime config, so this test is the pin, not a
    # compile-time assertion. A new provider goes in this list.
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
