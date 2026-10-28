defmodule Platform.Meetings.CandidateUndoTest do
  @moduledoc """
  `Candidates.reopen/2` — taking a stop back (task 01a0740e stage 5).

  ## Why each guard has a test of its own

  `reopen/2` is the only function in `Candidates` that un-sets
  `closed_reason`, so what it REFUSES is the whole of its safety. A
  single "it reopens a stopped card" test is satisfied by a function
  with no guards at all, which would also un-close a vetoed card, a
  deduped one, and a card that has already minted a task.

  So the three refusals below each name a different fact:

    * `disposition == :accepted` — it graduated and the deliverable
      exists. Tested TWICE: once through a real `graduate/2`, and once
      against a card that is `:accepted` AND stopped, which is the only
      shape where this clause is the one deciding the answer rather
      than being shadowed by the `closed_reason` check underneath it.
    * `closed_reason != :dismissed` — `:duplicate` and `:vetoed` are
      judgements somebody else made, not stops.
    * no `:countdown_stopped` event — `Not now` (`decline_candidate`)
      writes the SAME `:dismissed` reason through `close/2`, so the
      reason column alone cannot tell a stop from a decline. The event
      is what can.

  ## Why the state comes back out of Postgres

  `reopen/2` restores `state` from a jsonb detail written by
  `do_stop/3`. Both the write and the read cross the jsonb boundary,
  where an atom becomes a string, so an assertion on the struct the
  write returned would pass against an implementation that never
  persisted the change. Every assertion here reloads the row.
  """

  use Platform.DataCase, async: false

  alias Platform.Meetings.CandidateEvents
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo

  setup do
    %{meeting: create_meeting!(Platform.TenancyFixtures.acme_org_id())}
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp create_meeting!(org_id) do
    n = System.unique_integer([:positive])

    {:ok, project} = Platform.Tasks.create_project(%{name: "Undo #{n}", org_id: org_id})

    {:ok, space} =
      Platform.Chat.create_space(%{name: "Undo Space #{n}", slug: "undo-#{n}", kind: "meeting"})

    %Platform.Meetings.Meeting{}
    |> Platform.Meetings.Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "undo-meeting-#{n}",
      name: "Undo Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  # An OPEN, ARMED card at `:shaping` — the state a card is usually in
  # when somebody presses stop, and the one that renders review controls
  # when it comes back (a `:heard` card with no classification comes back
  # to the skeleton, which is also correct and is not what this file is
  # about).
  defp armed!(meeting, overrides \\ %{}) do
    {:ok, candidate} =
      Candidates.create(
        Map.merge(
          %{
            meeting_id: meeting.id,
            evidence_quote: "we should rotate the staging secrets",
            speaker: "alice",
            classified_intent: "action_items",
            target_role: "meeting_scribe",
            state: :shaping,
            outcome_kind: :task,
            acts_at: DateTime.add(DateTime.utc_now(), 30, :second)
          },
          overrides
        )
      )

    candidate
  end

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  describe "reopen/2 puts a stopped card back" do
    test "it restores the state the stop recorded and clears every closed column", %{
      meeting: meeting
    } do
      participant_id = Ecto.UUID.generate()
      candidate = armed!(meeting)

      {:ok, _stopped} = Candidates.stop(candidate, participant_id, actor_name: "Alice")

      # The control. Without this the assertions below are satisfied by a
      # card that was never closed in the first place.
      stopped = reload!(candidate)
      assert stopped.state == :closed
      assert stopped.closed_reason == :dismissed
      assert %DateTime{} = stopped.closed_at
      assert stopped.closed_note == "Stopped by Alice"
      assert stopped.closed_by_participant_id == participant_id

      {:ok, _reopened} = Candidates.reopen(stopped, Ecto.UUID.generate())

      row = reload!(candidate)

      # Back to the state `do_stop/3` recorded in the event's `"from"`,
      # not to a default and not to `:heard`.
      assert row.state == :shaping

      assert is_nil(row.closed_reason)
      assert is_nil(row.closed_at)
      assert is_nil(row.closed_note)
      assert is_nil(row.closed_by_participant_id)

      # DISARMED. Restoring the deadline would fire the card the instant
      # the stop was undone; minting a fresh one would invent a consent
      # nobody gave.
      assert is_nil(row.acts_at)

      # And the reversal is on the log as its own kind, so a reader is
      # not left with a stop the row no longer agrees with.
      kinds = CandidateEvents.kinds_for_candidate(candidate.id)
      assert :countdown_stopped in kinds
      assert :countdown_undone in kinds
      assert List.last(kinds) == :countdown_undone
    end

    test "a second undo is refused — there is no stop left to take back", %{meeting: meeting} do
      candidate = armed!(meeting)
      {:ok, _} = Candidates.stop(candidate, Ecto.UUID.generate())
      {:ok, _} = Candidates.reopen(candidate)

      assert {:error, :not_stopped} = Candidates.reopen(candidate)

      # Unchanged by the refusal: still open, still at the restored state.
      row = reload!(candidate)
      assert row.state == :shaping
      assert is_nil(row.closed_reason)
    end
  end

  describe "reopen/2 refuses what is not a stop" do
    test "a GRADUATED card — the deliverable exists and there is nothing to undo", %{
      meeting: meeting
    } do
      candidate = armed!(meeting)

      :ok = Candidates.complete_by_ack(candidate)
      graduated = reload!(candidate)
      assert graduated.disposition == :accepted
      assert is_nil(graduated.task_id)

      assert {:error, :already_fired} = Candidates.reopen(candidate)

      row = reload!(candidate)
      assert row.state == :closed
      assert row.closed_reason == :done
      assert row.task_id == graduated.task_id
    end

    test "the ACCEPTED check decides on its own, ahead of the reason check", %{meeting: meeting} do
      # A stopped card — `:dismissed`, with a `:countdown_stopped` event,
      # so both of the other guards would let it through — that has since
      # been marked `:accepted`. Only the disposition clause can refuse
      # this, which is what makes it the clause under test rather than a
      # passenger behind `closed_reason != :dismissed`.
      candidate = armed!(meeting)
      {:ok, _} = Candidates.stop(candidate, Ecto.UUID.generate())
      {:ok, _} = Candidates.record_disposition(candidate, :accepted)

      accepted = reload!(candidate)
      assert accepted.closed_reason == :dismissed
      assert accepted.disposition == :accepted
      assert :countdown_stopped in CandidateEvents.kinds_for_candidate(candidate.id)

      assert {:error, :already_fired} = Candidates.reopen(candidate)
      assert reload!(candidate).state == :closed
    end

    test "a DUPLICATE close — somebody else's judgement, not a stop", %{meeting: meeting} do
      candidate = armed!(meeting)

      {:ok, _} = Candidates.close(candidate, {:duplicate, "same ask as the card above"})

      assert {:error, :not_stopped} = Candidates.reopen(candidate)

      row = reload!(candidate)
      assert row.state == :closed
      assert row.closed_reason == :duplicate
      assert row.closed_note == "same ask as the card above"
    end

    test "the REASON check decides on its own, on a row that was genuinely stopped", %{
      meeting: meeting
    } do
      # The mirror of the `:accepted` test above, and it exists for the
      # same reason. A `:duplicate` card reached the normal way carries
      # no `:countdown_stopped` event either, so the test above is
      # refused by TWO guards and cannot say which one did it.
      #
      # This row is stopped for real — event and all — and then relabelled
      # in place, which is the only shape where `closed_reason` is the
      # clause deciding the answer. Written through `Repo` on purpose:
      # `close/2` is idempotent on an already-closed card precisely so a
      # late cancel cannot relabel a close, so there is no context call
      # that produces this and the guard would otherwise be untestable.
      candidate = armed!(meeting)
      {:ok, _} = Candidates.stop(candidate, Ecto.UUID.generate())

      relabelled =
        candidate
        |> reload!()
        |> Ecto.Changeset.change(closed_reason: :duplicate)
        |> Repo.update!()

      assert relabelled.closed_reason == :duplicate
      assert :countdown_stopped in CandidateEvents.kinds_for_candidate(candidate.id)

      assert {:error, :not_stopped} = Candidates.reopen(candidate)
      assert reload!(candidate).state == :closed
    end

    test "a VETOED close, and a `Not now` DECLINE that shares the stop's own reason", %{
      meeting: meeting
    } do
      vetoed = armed!(meeting)
      {:ok, _} = Candidates.close(vetoed, :vetoed)
      assert {:error, :not_stopped} = Candidates.reopen(vetoed)
      assert reload!(vetoed).closed_reason == :vetoed

      # `decline_candidate` closes `:dismissed` — the same reason a stop
      # writes — through `close/2`, and emits no `:countdown_stopped`.
      # This is the case the reason column CANNOT answer, and the reason
      # the guard reads the event.
      declined = armed!(meeting)
      {:ok, _} = Candidates.close(declined, {:dismissed, "Not now — Alice"})

      assert reload!(declined).closed_reason == :dismissed
      refute :countdown_stopped in CandidateEvents.kinds_for_candidate(declined.id)
      assert {:error, :not_stopped} = Candidates.reopen(declined)
      assert reload!(declined).state == :closed
    end

    test "an OPEN card — nothing has been stopped", %{meeting: meeting} do
      candidate = armed!(meeting)

      assert {:error, :not_stopped} = Candidates.reopen(candidate)

      row = reload!(candidate)
      assert row.state == :shaping
      assert is_nil(row.acts_at)
    end

    test "an id that names nothing" do
      assert {:error, :not_found} = Candidates.reopen(Ecto.UUID.generate())
    end
  end
end
