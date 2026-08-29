defmodule Platform.Meetings.TriageReconcileTest do
  @moduledoc """
  Triage reconciles against the live card path instead of re-filing it
  (task 01a03fda).

  ## The collision this exists for

  `Platform.Meetings.CandidateSweeper` files tasks DURING the meeting via
  `Candidates.graduate/2`. `Triage.file_tasks_from_canvas/2` then reads
  the same utterances back out of the transcript afterwards. The first
  test here is a CHARACTERISATION of what that costs with no identity
  link: three live cards plus four re-parsed action items produce seven
  tasks and the fuzzy dedup gate absorbs none of them, because
  `graduate/2` titles its task with the verbatim utterance while an
  action item is a normalised imperative.

  ## Anti-vacuity

  Every `refute`-shaped claim here is a claim that a task was NOT filed,
  and a test that only counted a suppression would pass under an
  implementation that never files anything at all. So:

    * the suppression tests each carry a POSITIVE CONTROL in the same
      test — the same title, same batch, with the reconciling id removed
      or pointed elsewhere — and assert THAT one files. A reconciler
      that suppressed everything fails on the control, not on the claim.
    * `files everything when the live path filed nothing` is the
      ticket's own third acceptance criterion and exists precisely so a
      reconciler that never files cannot pass the other two.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Meetings.CandidateSweeper
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.Triage
  alias Platform.Repo
  alias Platform.Tasks.Task

  # What was said out loud. `graduate/2` titles the task it mints with
  # `truncate(evidence_quote)` — the verbatim utterance.
  @quotes [
    "somebody should write up the onboarding funnel changes",
    "we need to add rate limiting to the public API before launch",
    "can someone chase the vendor about the SOC2 renewal"
  ]

  # What the triage-officer's parse of the same transcript produces:
  # normalised imperatives. Measured jaro distances against the quotes
  # above are 0.7477 / 0.7183 / 0.7805 — all three sit BELOW the 0.85
  # dedup threshold, which is why the fuzzy gate cannot do this job.
  @parsed_titles [
    "Write up the onboarding funnel changes",
    "Add rate limiting to the public API",
    "Chase the vendor about the SOC2 renewal"
  ]

  @new_title "Book the Q4 planning offsite"

  setup do
    %{project: project, meeting: meeting, canvas: canvas} = meeting_fixture!()
    %{project: project, meeting: meeting, canvas: canvas}
  end

  defp meeting_fixture! do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Reconcile #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/reconcile"
      })

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Reconcile Space #{System.unique_integer([:positive])}",
        slug: "reconcile-#{System.unique_integer([:positive])}",
        kind: "meeting"
      })

    meeting =
      %Platform.Meetings.Meeting{}
      |> Platform.Meetings.Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "reconcile-#{System.unique_integer([:positive])}",
        name: "Reconcile Meeting",
        livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
      })
      |> Repo.insert!()

    {:ok, participant} =
      Platform.Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "TriageAgent",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Platform.Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Scribe completion canvas"
      })

    %{project: project, meeting: meeting, canvas: canvas, space: space}
  end

  # Open a card that is already past its deadline, so one sweep fires it.
  defp arm!(meeting, quote) do
    {:ok, candidate} =
      Candidates.create(%{
        meeting_id: meeting.id,
        evidence_quote: quote,
        state: :heard,
        outcome_kind: :task,
        acts_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    candidate
  end

  # Run the real server-side countdown, not `graduate/2` directly, so
  # these tests exercise the path that actually reaches production.
  defp fire_all!(count) do
    fired = CandidateSweeper.sweep(now: DateTime.utc_now())

    assert length(fired) == count,
           "the live countdown must fire #{count} cards; fired #{length(fired)}"

    assert Enum.all?(fired, &is_binary(&1.task_id)),
           "each fired card must carry a real task id"

    fired
  end

  defp project_task_count(project_id) do
    Repo.aggregate(
      from(t in Task, where: t.project_id == ^project_id, where: is_nil(t.deleted_at)),
      :count
    )
  end

  defp titles(project_id) do
    Repo.all(from(t in Task, where: t.project_id == ^project_id, select: t.title))
  end

  # ── The collision, characterised ────────────────────────────────────────

  describe "the collision this ticket names" do
    test "with no identity link the two paths file the same work twice",
         %{project: project, meeting: meeting, canvas: canvas} do
      Enum.each(@quotes, &arm!(meeting, &1))
      fire_all!(3)

      assert project_task_count(project.id) == 3

      items = Enum.map(@parsed_titles ++ [@new_title], &%{title: &1})

      {:ok, result} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          meeting_id: meeting.id,
          action_items: items
        )

      # The fuzzy gate absorbs NONE of it. This is the measurement, not
      # an aspiration: if a future change makes `similar_open_titles/3`
      # catch these, this assertion is the thing that should be revisited
      # deliberately rather than the collision quietly changing shape.
      assert result.skipped == [],
             "the fuzzy dedup gate is expected to absorb none of the live path's tasks"

      assert length(result.filed) == 4
      assert project_task_count(project.id) == 7
    end
  end

  # ── Acceptance criterion 1 ──────────────────────────────────────────────

  describe "reconciliation by candidate id" do
    test "three filed live + four action items yields exactly one new task",
         %{project: project, meeting: meeting, canvas: canvas} do
      candidates = Enum.map(@quotes, &arm!(meeting, &1))
      fired = fire_all!(3)

      by_id = Map.new(fired, &{&1.id, &1.task_id})

      items =
        Enum.zip(candidates, @parsed_titles)
        |> Enum.map(fn {candidate, title} ->
          %{title: title, candidate_id: candidate.id}
        end)
        |> Kernel.++([%{title: @new_title}])

      {:ok, result} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          meeting_id: meeting.id,
          action_items: items
        )

      # Positive control, same batch: the item the live path MISSED is
      # filed. Without it a reconciler that suppressed all four would
      # also see `project_task_count == 4` and pass.
      assert [%Task{title: @new_title}] = result.filed

      assert length(result.skipped) == 3

      assert Enum.all?(result.skipped, &(&1.reason == :already_filed_live))

      # The skip must name the task the LIVE path actually created — not
      # merely "a task". A reconciler that skipped with the wrong id
      # would leave the reviewer chasing the wrong row.
      for {candidate, skip} <- Enum.zip(candidates, result.skipped) do
        assert skip.candidate_id == candidate.id
        assert skip.existing_task_id == Map.fetch!(by_id, candidate.id)
      end

      assert project_task_count(project.id) == 4,
             "3 filed live + 1 genuinely new; got #{project_task_count(project.id)}"
    end

    test "a candidate that graduated is skipped as filed, never as closed-against",
         %{project: project, meeting: meeting, canvas: canvas} do
      candidate = arm!(meeting, hd(@quotes))
      [fired] = fire_all!(1)

      # `graduate/2` writes `state: :closed` AND `closed_reason: :done`.
      # A reconciler that read every closed candidate as a rejection
      # would classify this one as `:closed_in_meeting` and hand back a
      # nil task id — suppressing the item while losing the pointer to
      # the task the meeting actually produced.
      reloaded = Candidates.get(candidate.id)
      assert reloaded.state == :closed
      assert reloaded.closed_reason == :done

      {:ok, result} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          meeting_id: meeting.id,
          action_items: [%{title: hd(@parsed_titles), candidate_id: candidate.id}]
        )

      assert [skip] = result.skipped
      assert skip.reason == :already_filed_live
      assert skip.existing_task_id == fired.task_id
      refute skip.existing_task_id == nil
    end
  end

  # ── Acceptance criterion 2 ──────────────────────────────────────────────

  describe "a candidate closed during the meeting" do
    for reason <- [:retracted, :duplicate, :vetoed, :dismissed] do
      test "#{reason} is respected and the item is not re-filed",
           %{project: project, meeting: meeting, canvas: canvas} do
        reason = unquote(reason)

        {:ok, closed} =
          Candidates.create(%{
            meeting_id: meeting.id,
            evidence_quote: hd(@quotes),
            state: :closed,
            closed_reason: reason,
            outcome_kind: :task
          })

        # POSITIVE CONTROL, same batch, same title: an item that names no
        # candidate is filed. So "not re-filed" below is a statement
        # about the reconciler and not about a batch that files nothing.
        items = [
          %{title: hd(@parsed_titles), candidate_id: closed.id},
          %{title: @new_title}
        ]

        {:ok, result} =
          Triage.file_tasks_from_canvas(canvas,
            project_id: project.id,
            meeting_id: meeting.id,
            action_items: items
          )

        assert [%Task{title: @new_title}] = result.filed

        assert [skip] = result.skipped
        assert skip.reason == :closed_in_meeting
        assert skip.closed_reason == reason
        assert skip.candidate_id == closed.id

        # No task to point at — the meeting decided this was not work.
        assert skip.existing_task_id == nil

        refute hd(@parsed_titles) in titles(project.id),
               "a candidate closed as #{reason} must not be re-filed by triage"

        assert project_task_count(project.id) == 1
      end
    end

    test "a candidate still open is NOT suppressed", %{
      project: project,
      meeting: meeting,
      canvas: canvas
    } do
      # The mirror image of the four tests above. An `:acting` candidate
      # has neither graduated nor been closed against, so triage must
      # still file it — otherwise "reconcile" would mean "suppress
      # anything the meeting ever mentioned".
      {:ok, open} =
        Candidates.create(%{
          meeting_id: meeting.id,
          evidence_quote: hd(@quotes),
          state: :acting,
          outcome_kind: :task
        })

      {:ok, result} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          meeting_id: meeting.id,
          action_items: [%{title: hd(@parsed_titles), candidate_id: open.id}]
        )

      assert [%Task{}] = result.filed
      assert result.skipped == []
    end
  end

  # ── Acceptance criterion 3 ──────────────────────────────────────────────

  describe "triage still files when the live path filed nothing" do
    test "every action item lands", %{project: project, meeting: meeting, canvas: canvas} do
      assert Repo.aggregate(
               from(c in Platform.Meetings.MeetingCandidate,
                 where: c.meeting_id == ^meeting.id
               ),
               :count
             ) == 0

      items = Enum.map(@parsed_titles ++ [@new_title], &%{title: &1})

      {:ok, result} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          meeting_id: meeting.id,
          action_items: items
        )

      assert length(result.filed) == 4
      assert result.skipped == []
      assert project_task_count(project.id) == 4
    end
  end

  # ── Scoping and the rollback interaction ────────────────────────────────

  describe "the reconciler's blast radius" do
    test "a candidate from another meeting does not suppress this one's item",
         %{project: project, canvas: canvas} do
      other = meeting_fixture!()
      candidate = arm!(other.meeting, hd(@quotes))
      fire_all!(1)

      this = meeting_fixture!()

      # The item names a real, genuinely-graduated candidate — but one
      # belonging to a DIFFERENT meeting. Reconciliation is scoped to the
      # meeting the pass was told about, so this must file.
      {:ok, result} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          meeting_id: this.meeting.id,
          action_items: [%{title: hd(@parsed_titles), candidate_id: candidate.id}]
        )

      assert [%Task{}] = result.filed
      assert result.skipped == []
    end

    test "a live task that was rolled back no longer suppresses the item",
         %{project: project, meeting: meeting, canvas: canvas} do
      candidate = arm!(meeting, hd(@quotes))
      [fired] = fire_all!(1)

      item = %{title: hd(@parsed_titles), candidate_id: candidate.id}

      # POSITIVE CONTROL: while the live task is alive, the item is
      # suppressed. Without this half, the assertion below would pass
      # under an implementation that never suppressed anything.
      {:ok, before} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          meeting_id: meeting.id,
          action_items: [item]
        )

      assert before.filed == []
      assert [%{reason: :already_filed_live}] = before.skipped

      # Now roll the live task back, the way a bad meeting is undone.
      Repo.get!(Task, fired.task_id)
      |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
      |> Repo.update!()

      {:ok, after_junk} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          meeting_id: meeting.id,
          action_items: [item]
        )

      assert [%Task{title: title}] = after_junk.filed
      assert title == hd(@parsed_titles)
      assert after_junk.skipped == []
    end

    test "without :meeting_id nothing is reconciled", %{
      project: project,
      meeting: meeting,
      canvas: canvas
    } do
      candidate = arm!(meeting, hd(@quotes))
      fire_all!(1)

      item = %{title: hd(@parsed_titles), candidate_id: candidate.id}

      # POSITIVE CONTROL: the exact same item WITH the meeting named is
      # suppressed, so the filing below is caused by the missing opt and
      # not by the item being unreconcilable in the first place.
      {:ok, scoped} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          meeting_id: meeting.id,
          action_items: [item]
        )

      assert scoped.filed == []

      {:ok, unscoped} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          action_items: [item]
        )

      assert [%Task{}] = unscoped.filed
      assert unscoped.skipped == []
    end
  end

  # ── The provenance stamp ────────────────────────────────────────────────

  describe "graduate/2 provenance" do
    test "the minted task names the meeting and the candidate", %{
      meeting: meeting
    } do
      candidate = arm!(meeting, hd(@quotes))
      [fired] = fire_all!(1)

      task = Repo.get!(Task, fired.task_id)

      assert task.metadata["meeting_id"] == meeting.id
      assert task.metadata["candidate_id"] == candidate.id
      assert task.metadata["source"] == "meetings.candidate"
    end

    test "a live task does not consume triage's backlog-promotion budget", %{
      project: project,
      meeting: meeting,
      canvas: canvas
    } do
      Enum.each(Enum.take(@quotes, 2), &arm!(meeting, &1))
      fire_all!(2)

      # `Triage` counts its own backlog against
      # `metadata->>'source' = "meetings.triage"`. If the live path wore
      # that same source string, these two tasks would have exhausted a
      # cap of 1 and the triage filing below would land unpromoted.
      {:ok, result} =
        Triage.file_tasks_from_canvas(canvas,
          project_id: project.id,
          meeting_id: meeting.id,
          backlog_cap: 1,
          action_items: [%{title: @new_title}]
        )

      assert [%Task{needs_promotion: true}] = result.filed
    end
  end
end
