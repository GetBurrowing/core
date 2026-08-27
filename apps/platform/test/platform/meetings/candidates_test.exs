defmodule Platform.Meetings.CandidatesTest do
  @moduledoc """
  Tests for `Platform.Meetings.Candidates` — the candidate-lifecycle
  context (task 01a03fb8 stage 2).

  ## Anti-vacuity

  Two checks here could go green without proving anything, so both are
  written to make that impossible:

    * The backwards-transition assertion is only meaningful if the
      candidate genuinely holds a LATER state first. Every such test
      advances forward and asserts the resulting `state` before asking
      for the backwards move, so a `advance/3` that silently no-opped
      would fail on the positive control rather than pass on the
      negative one.
    * The stamp-not-overwritten assertion is only meaningful if a
      SECOND advance actually happened. Those tests assert the second
      advance returned `{:ok, _}` AND that the state moved, then compare
      the stamp — a rejected second advance cannot masquerade as a
      preserved timestamp.
  """

  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Meetings.Candidates
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo

  # ── Real association chain ────────────────────────────────────────────────

  defp create_meeting!(org_id) do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Candidates #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Candidate Space #{System.unique_integer([:positive])}",
        slug: "candidates-#{System.unique_integer([:positive])}",
        kind: "meeting"
      })

    %Platform.Meetings.Meeting{}
    |> Platform.Meetings.Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "candidates-#{System.unique_integer([:positive])}",
      name: "Candidates Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp seat!(meeting) do
    {:ok, participant} =
      Platform.Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Candidate Host",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp candidate_attrs(meeting_id, overrides \\ %{}) do
    Map.merge(
      %{
        meeting_id: meeting_id,
        evidence_quote: "somebody should write up the onboarding funnel changes",
        state: :heard,
        outcome_kind: :task
      },
      overrides
    )
  end

  defp orphan_candidate!(overrides \\ %{}) do
    {:ok, candidate} =
      Candidates.create(candidate_attrs(Platform.Types.UUIDv7.generate(), overrides))

    candidate
  end

  # ── create/1 ──────────────────────────────────────────────────────────────

  describe "create/1 — org derivation" do
    test "derives org_id from a real meeting -> project chain" do
      org_id = fabrikam_org_id()
      meeting = create_meeting!(org_id)

      {:ok, candidate} = Candidates.create(candidate_attrs(meeting.id))

      assert candidate.org_id == org_id
    end

    test "two meetings in different orgs derive different org_ids" do
      fabrikam = fabrikam_org_id()
      sxi = tenant_org_id("sxi")

      {:ok, fabrikam_candidate} = Candidates.create(candidate_attrs(create_meeting!(fabrikam).id))
      {:ok, sxi_candidate} = Candidates.create(candidate_attrs(create_meeting!(sxi).id))

      assert fabrikam_candidate.org_id == fabrikam
      assert sxi_candidate.org_id == sxi
      refute fabrikam_candidate.org_id == sxi_candidate.org_id
    end

    test "a meeting id that resolves to nothing still writes, with a nil org_id" do
      orphan_id = Platform.Types.UUIDv7.generate()

      {:ok, candidate} = Candidates.create(candidate_attrs(orphan_id))

      assert is_nil(candidate.org_id)
      assert candidate.meeting_id == orphan_id
      assert candidate.state == :heard
    end

    test "a malformed meeting id is non-fatal for derivation" do
      # Derivation rescues the cast error and leaves org_id nil rather
      # than propagating. Proving that requires reaching the insert,
      # which then fails on the column type — an Ecto.ChangeError, NOT
      # the ArgumentError a bare derivation would have raised first. The
      # exception type is the whole assertion here.
      assert_raise Ecto.ChangeError, fn ->
        Candidates.create(candidate_attrs("not-a-uuid"))
      end

      # Positive control on the rescue itself.
      assert is_nil(Platform.Meetings.IntentCorrections.org_id_for_meeting("not-a-uuid"))
    end

    test "an explicit org_id wins over derivation" do
      meeting = create_meeting!(fabrikam_org_id())
      explicit = tenant_org_id("paragon")

      {:ok, candidate} = Candidates.create(candidate_attrs(meeting.id, %{org_id: explicit}))

      assert candidate.org_id == explicit
    end

    test "an explicit nil org_id still derives" do
      org_id = fabrikam_org_id()
      meeting = create_meeting!(org_id)

      {:ok, candidate} = Candidates.create(candidate_attrs(meeting.id, %{org_id: nil}))

      assert candidate.org_id == org_id
    end

    test "string-keyed attrs derive too" do
      org_id = fabrikam_org_id()
      meeting = create_meeting!(org_id)

      {:ok, candidate} =
        Candidates.create(%{
          "meeting_id" => meeting.id,
          "evidence_quote" => "let's ship the digest",
          "state" => "heard",
          "outcome_kind" => "task"
        })

      assert candidate.org_id == org_id
    end
  end

  # ── reads ─────────────────────────────────────────────────────────────────

  describe "get/1, get_by_intent_id/1, list_for_meeting/1" do
    test "get/1 round-trips and tolerates nil and garbage" do
      candidate = orphan_candidate!()

      assert Candidates.get(candidate.id).id == candidate.id
      assert is_nil(Candidates.get(nil))
      assert is_nil(Candidates.get("not-a-uuid"))
      assert is_nil(Candidates.get(:not_even_a_binary))
      assert is_nil(Candidates.get(Platform.Types.UUIDv7.generate()))
    end

    test "get_by_intent_id/1 finds the mirrored row" do
      intent_id = Platform.Types.UUIDv7.generate()
      candidate = orphan_candidate!(%{intent_id: intent_id})

      assert Candidates.get_by_intent_id(intent_id).id == candidate.id
      assert is_nil(Candidates.get_by_intent_id(nil))
      assert is_nil(Candidates.get_by_intent_id(Platform.Types.UUIDv7.generate()))
    end

    test "list_for_meeting/1 returns oldest first and scopes to the meeting" do
      meeting_id = Platform.Types.UUIDv7.generate()
      other_meeting_id = Platform.Types.UUIDv7.generate()

      {:ok, first} = Candidates.create(candidate_attrs(meeting_id, %{evidence_quote: "one"}))
      {:ok, second} = Candidates.create(candidate_attrs(meeting_id, %{evidence_quote: "two"}))
      {:ok, third} = Candidates.create(candidate_attrs(meeting_id, %{evidence_quote: "three"}))
      {:ok, _other} = Candidates.create(candidate_attrs(other_meeting_id))

      assert Enum.map(Candidates.list_for_meeting(meeting_id), & &1.id) ==
               [first.id, second.id, third.id]

      assert Candidates.list_for_meeting(nil) == []
    end
  end

  # ── advance/3 ─────────────────────────────────────────────────────────────

  describe "advance/3 — forward-only" do
    test "walks the whole arc forward" do
      candidate = orphan_candidate!()

      {:ok, thinking} = Candidates.advance(candidate, :thinking)
      assert thinking.state == :thinking

      {:ok, shaping} = Candidates.advance(thinking, :shaping)
      assert shaping.state == :shaping

      {:ok, acting} = Candidates.advance(shaping, :acting)
      assert acting.state == :acting
    end

    test "rejects a backwards transition from a genuinely later state" do
      candidate = orphan_candidate!()

      # Positive control FIRST: the candidate must actually be :acting
      # before the backwards assertion below means anything.
      {:ok, acting} = Candidates.advance(candidate, :acting)
      assert acting.state == :acting
      assert Repo.get(MeetingCandidate, candidate.id).state == :acting

      assert {:error, {:invalid_transition, :acting, :heard}} =
               Candidates.advance(acting, :heard)

      assert {:error, {:invalid_transition, :acting, :shaping}} =
               Candidates.advance(acting, :shaping)

      # And nothing was written.
      assert Repo.get(MeetingCandidate, candidate.id).state == :acting
    end

    test "rejects a transition to the same state" do
      candidate = orphan_candidate!()
      {:ok, shaping} = Candidates.advance(candidate, :shaping)
      assert shaping.state == :shaping

      assert {:error, {:invalid_transition, :shaping, :shaping}} =
               Candidates.advance(shaping, :shaping)
    end

    test "close is reachable from every non-closed state" do
      for state <- [:heard, :thinking, :shaping, :acting] do
        candidate = orphan_candidate!()

        candidate =
          if state == :heard do
            candidate
          else
            {:ok, advanced} = Candidates.advance(candidate, state)
            assert advanced.state == state
            advanced
          end

        {:ok, closed} = Candidates.advance(candidate, :closed, %{closed_reason: :retracted})

        assert closed.state == :closed
        assert closed.closed_reason == :retracted
      end
    end

    test "advance accepts an id as well as a struct, and reports a missing row" do
      candidate = orphan_candidate!()

      {:ok, advanced} = Candidates.advance(candidate.id, :shaping)
      assert advanced.state == :shaping

      assert {:error, :not_found} =
               Candidates.advance(Platform.Types.UUIDv7.generate(), :shaping)
    end

    test "advance merges caller attrs" do
      candidate = orphan_candidate!()

      {:ok, advanced} =
        Candidates.advance(candidate, :shaping, %{assigned_agent_slug: "dalton"})

      assert advanced.assigned_agent_slug == "dalton"
    end
  end

  describe "advance/3 — stamps" do
    test "stamps dispatched_at and acted_at on first entry" do
      candidate = orphan_candidate!()
      assert is_nil(candidate.dispatched_at)
      assert is_nil(candidate.acted_at)

      {:ok, shaping} = Candidates.advance(candidate, :shaping)
      assert %DateTime{} = shaping.dispatched_at
      assert is_nil(shaping.acted_at)

      {:ok, acting} = Candidates.advance(shaping, :acting)
      assert %DateTime{} = acting.acted_at
    end

    test "a SECOND advance does not overwrite an existing stamp" do
      candidate = orphan_candidate!()

      {:ok, shaping} = Candidates.advance(candidate, :shaping)
      original = shaping.dispatched_at
      assert %DateTime{} = original

      # Force wall-clock separation so an overwrite would be visible.
      Process.sleep(5)

      # The second advance must ACTUALLY happen — assert both its :ok
      # and the state move, otherwise "unchanged stamp" would also be
      # true of an advance that was rejected.
      {:ok, acting} = Candidates.advance(shaping, :acting)
      assert acting.state == :acting
      assert acting.dispatched_at == original

      Process.sleep(5)

      {:ok, closed} = Candidates.advance(acting, :closed, %{closed_reason: :done})
      assert closed.state == :closed
      assert closed.dispatched_at == original
      assert closed.acted_at == acting.acted_at
    end

    test "an explicit stamp in attrs is honoured on first entry" do
      candidate = orphan_candidate!()
      explicit = ~U[2026-01-01 00:00:00.000000Z]

      {:ok, advanced} = Candidates.advance(candidate, :shaping, %{dispatched_at: explicit})

      assert advanced.dispatched_at == explicit
    end
  end

  # ── record_disposition/3 ──────────────────────────────────────────────────

  describe "record_disposition/3" do
    test "is settable while the candidate is still in flight" do
      candidate = orphan_candidate!()
      {:ok, acting} = Candidates.advance(candidate, :acting)
      assert acting.state == :acting

      {:ok, disposed} = Candidates.record_disposition(acting, :accepted)

      # State untouched — the two axes are independent.
      assert disposed.state == :acting
      assert disposed.disposition == :accepted
      assert %DateTime{} = disposed.disposition_at
    end

    test "accepted and rejected both round-trip, and both can end :closed" do
      for disposition <- [:accepted, :rejected, :timed_out] do
        candidate = orphan_candidate!()

        {:ok, disposed} = Candidates.record_disposition(candidate, disposition)
        assert disposed.disposition == disposition

        {:ok, closed} = Candidates.close(disposed, :done)

        # Both end :closed with the same reason — reading "closed" as
        # "rejected" is the bug this separation exists to prevent.
        assert closed.state == :closed
        assert closed.closed_reason == :done
        assert closed.disposition == disposition
      end
    end

    test "reports a missing row" do
      assert {:error, :not_found} =
               Candidates.record_disposition(Platform.Types.UUIDv7.generate(), :accepted)
    end
  end

  # ── close/2 ───────────────────────────────────────────────────────────────

  describe "close/2" do
    test "accepts each of the five reasons and produces the same shaped row" do
      rows =
        for reason <- MeetingCandidate.closed_reasons() do
          {:ok, closed} = Candidates.close(orphan_candidate!(), reason)
          closed
        end

      assert Enum.map(rows, & &1.closed_reason) == MeetingCandidate.closed_reasons()

      for row <- rows do
        assert row.state == :closed
        assert %DateTime{} = row.closed_at
        assert is_nil(row.closed_note)
        assert is_nil(row.disposition)
        assert row.outcome_kind == :task
      end
    end

    test "accepts a {reason, note} tuple" do
      {:ok, closed} =
        Candidates.close(orphan_candidate!(), {:vetoed, "Rowan said not this quarter"})

      assert closed.closed_reason == :vetoed
      assert closed.closed_note == "Rowan said not this quarter"
    end

    test "is idempotent — the first close is the true one" do
      candidate = orphan_candidate!()

      {:ok, first} = Candidates.close(candidate, {:vetoed, "not this quarter"})
      assert first.closed_reason == :vetoed

      {:ok, second} = Candidates.close(first, :duplicate)

      assert second.closed_reason == :vetoed
      assert second.closed_note == "not this quarter"
      assert second.closed_at == first.closed_at

      # And durably so.
      reloaded = Repo.get(MeetingCandidate, candidate.id)
      assert reloaded.closed_reason == :vetoed
      assert reloaded.closed_note == "not this quarter"
    end

    test "accepts an id and reports a missing row" do
      candidate = orphan_candidate!()

      {:ok, closed} = Candidates.close(candidate.id, :done)
      assert closed.state == :closed

      assert {:error, :not_found} =
               Candidates.close(Platform.Types.UUIDv7.generate(), :done)
    end
  end

  # ── queue-status mapping ──────────────────────────────────────────────────

  describe "queue_status_to_state/1 and queue_status_to_disposition/1" do
    test "maps every one of the nine IntentQueue statuses" do
      expected = [
        {:queued, :heard, nil, nil},
        {:dispatched, :shaping, nil, nil},
        {:acked, :acting, nil, nil},
        {:completed, :closed, :accepted, :done},
        {:cancelled, :closed, :rejected, :retracted},
        {:cancelled_late, :closed, :rejected, :retracted},
        {:timed_out, :closed, :timed_out, :dismissed},
        {:dispatch_failed, :closed, :rejected, :dismissed},
        {:no_ack_spawn_failed, :closed, :rejected, :dismissed}
      ]

      # Guard: the table above must cover the queue's actual status set,
      # so a tenth status added upstream fails here rather than silently
      # mirroring as nil.
      assert Enum.sort(Enum.map(expected, &elem(&1, 0))) ==
               Enum.sort(Platform.Meetings.IntentQueue.Server.statuses())

      for {status, state, disposition, reason} <- expected do
        assert Candidates.queue_status_to_state(status) == state
        assert Candidates.queue_status_to_disposition(status) == disposition
        assert Candidates.queue_status_to_closed_reason(status) == reason
      end
    end

    test "string statuses map identically" do
      assert Candidates.queue_status_to_state("completed") == :closed
      assert Candidates.queue_status_to_disposition("completed") == :accepted
    end

    test "an unrecognised status degrades to nil rather than raising" do
      assert is_nil(Candidates.queue_status_to_state(:invented_upstream))
      assert is_nil(Candidates.queue_status_to_state("never_seen_before_status"))
      assert is_nil(Candidates.queue_status_to_disposition(nil))
      assert is_nil(Candidates.queue_status_to_closed_reason(nil))
    end
  end

  # ── graduate ──────────────────────────────────────────────────────────────

  describe "graduate/2" do
    setup do
      %{meeting: create_meeting!(fabrikam_org_id())}
    end

    test "a :task candidate gets a real task, and canvas_id stays nil", %{meeting: meeting} do
      {:ok, candidate} =
        Candidates.create(candidate_attrs(meeting.id, %{outcome_kind: :task}))

      before_count = Repo.aggregate(Platform.Tasks.Task, :count)

      assert {:ok, graduated} = Candidates.graduate(candidate)

      assert graduated.task_id
      assert graduated.canvas_id == nil
      assert graduated.state == :closed
      assert graduated.disposition == :accepted
      assert graduated.closed_reason == :done

      # A real row, in the meeting's project — not merely a non-nil id.
      task = Repo.get(Platform.Tasks.Task, graduated.task_id)
      assert task
      assert task.project_id == meeting.project_id
      assert Repo.aggregate(Platform.Tasks.Task, :count) == before_count + 1
    end

    test "an :artifact candidate gets a canvas and NO task at all", %{meeting: meeting} do
      participant = seat!(meeting)

      {:ok, candidate} =
        Candidates.create(candidate_attrs(meeting.id, %{outcome_kind: :artifact}))

      # Both halves of acceptance criterion 3. Asserting only the canvas
      # id would pass code that creates BOTH deliverables — the count is
      # what makes this test non-vacuous.
      before_count = Repo.aggregate(Platform.Tasks.Task, :count)

      assert {:ok, graduated} = Candidates.graduate(candidate, created_by: participant.id)

      assert graduated.canvas_id
      assert Repo.get(Platform.Chat.Canvas, graduated.canvas_id)

      assert graduated.task_id == nil
      assert Repo.aggregate(Platform.Tasks.Task, :count) == before_count

      assert graduated.state == :closed
      assert graduated.disposition == :accepted
    end

    test "a frozen project surfaces the create_task/2 error and leaves the candidate un-closed",
         %{meeting: meeting} do
      Repo.get!(Platform.Tasks.Project, meeting.project_id)
      |> Ecto.Changeset.change(%{archived_at: DateTime.utc_now()})
      |> Repo.update!()

      {:ok, candidate} =
        Candidates.create(candidate_attrs(meeting.id, %{outcome_kind: :task}))

      before_count = Repo.aggregate(Platform.Tasks.Task, :count)

      assert {:error, :project_archived} = Candidates.graduate(candidate)

      assert Repo.aggregate(Platform.Tasks.Task, :count) == before_count

      reloaded = Candidates.get(candidate.id)
      assert reloaded.state == :heard
      refute reloaded.state == :closed
      assert reloaded.task_id == nil
      assert reloaded.closed_reason == nil
      assert reloaded.disposition == nil
    end
  end

  # ── close is ONE function ─────────────────────────────────────────────────

  describe "module surface" do
    test "no retract/dismiss/veto/mark_duplicate wrappers exist" do
      names = Candidates.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      refute :retract in names
      refute :dismiss in names
      refute :veto in names
      refute :mark_duplicate in names
      assert :close in names
    end
  end
end
