defmodule Platform.Meetings.MeetingCandidateTest do
  @moduledoc """
  Tests for `Platform.Meetings.MeetingCandidate` — the schema behind
  `meeting_candidates`, the durable candidate-lifecycle store (task
  01a03fb8 stage 1).

  Covers the changeset's required set, `Ecto.Enum` rejection on all four
  enum columns, and the three cross-field rules.

  ## Anti-vacuity

  Every cross-field rule is tested in BOTH directions in this file: a
  deliberate violation that must be rejected, AND a positive control
  that must pass the changeset. A rule that rejected everything would
  look identical to a working rule if only the negative case were
  asserted. The asymmetry rule (rule 3) is itself a positive control for
  rule 2 — a mistakenly symmetrised implementation fails it.
  """

  use Platform.DataCase, async: true

  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo

  # `Platform.DataCase` does not ship an `errors_on/1`; every schema test
  # in this directory defines its own (see `intent_correction_test.exs`).
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp valid_attrs(overrides) do
    Map.merge(
      %{
        meeting_id: Platform.Types.UUIDv7.generate(),
        org_id: Platform.Types.UUIDv7.generate(),
        room_id: Platform.Types.UUIDv7.generate(),
        intent_id: Platform.Types.UUIDv7.generate(),
        transcript_chunk_id: Platform.Types.UUIDv7.generate(),
        evidence_quote: "somebody should write up the onboarding funnel changes",
        state: :heard,
        outcome_kind: :task
      },
      overrides
    )
  end

  defp changeset(overrides \\ %{}) do
    MeetingCandidate.changeset(%MeetingCandidate{}, valid_attrs(overrides))
  end

  describe "changeset/2 — required fields" do
    test "valid attrs produce a valid changeset" do
      assert changeset().valid?
    end

    test "meeting_id, state and outcome_kind are required" do
      cs = MeetingCandidate.changeset(%MeetingCandidate{}, %{state: nil, outcome_kind: nil})

      refute cs.valid?

      for field <- [:meeting_id, :state, :outcome_kind] do
        assert %{^field => ["can't be blank"]} = errors_on(cs)
      end
    end

    test "org_id is NOT required — it is derived in stage 2" do
      cs = changeset(%{org_id: nil})

      assert cs.valid?
      refute Map.has_key?(errors_on(cs), :org_id)
    end

    test "intent_id is NOT required — a candidate can predate its queue row" do
      assert changeset(%{intent_id: nil}).valid?
    end
  end

  describe "changeset/2 — enum membership" do
    test "every declared state casts" do
      for state <- MeetingCandidate.states() do
        overrides =
          if state == :closed, do: %{state: state, closed_reason: :done}, else: %{state: state}

        assert changeset(overrides).valid?, "#{state} should be a valid state"
      end
    end

    test "the state set is exactly the five-value lifecycle" do
      assert MeetingCandidate.states() == [:heard, :thinking, :shaping, :acting, :closed]
    end

    test "an unknown state is rejected" do
      cs = changeset(%{state: :marinating})

      refute cs.valid?
      assert %{state: ["is invalid"]} = errors_on(cs)
    end

    test "every declared outcome_kind casts" do
      for kind <- MeetingCandidate.outcome_kinds() do
        assert changeset(%{outcome_kind: kind}).valid?, "#{kind} should be a valid outcome_kind"
      end
    end

    test "an unknown outcome_kind is rejected" do
      cs = changeset(%{outcome_kind: :decision})

      refute cs.valid?
      assert %{outcome_kind: ["is invalid"]} = errors_on(cs)
    end

    test "every declared closed_reason casts" do
      for reason <- MeetingCandidate.closed_reasons() do
        assert changeset(%{state: :closed, closed_reason: reason}).valid?,
               "#{reason} should be a valid closed_reason"
      end
    end

    test "an unknown closed_reason is rejected" do
      # An unrecognised value casts to nil, so rule 1 fires alongside the
      # enum rejection on a :closed row — assert membership, not equality.
      cs = changeset(%{state: :closed, closed_reason: :forgotten})

      refute cs.valid?
      assert %{closed_reason: messages} = errors_on(cs)
      assert "is invalid" in messages
    end

    test "an unknown closed_reason is rejected on a non-closed row too" do
      # The same rejection with rule 1 out of the picture entirely, so the
      # enum check is shown to fire on its own.
      cs = changeset(%{state: :acting, closed_reason: :forgotten})

      refute cs.valid?
      assert %{closed_reason: ["is invalid"]} = errors_on(cs)
    end

    test "every declared disposition casts" do
      for disposition <- MeetingCandidate.dispositions() do
        assert changeset(%{disposition: disposition}).valid?,
               "#{disposition} should be a valid disposition"
      end
    end

    test "an unknown disposition is rejected" do
      cs = changeset(%{disposition: :deferred})

      refute cs.valid?
      assert %{disposition: ["is invalid"]} = errors_on(cs)
    end

    test "queue_status is a free string, not an enum — it echoes whatever the queue reported" do
      # Deliberately a status the coarse `state` enum cannot express, and
      # deliberately one nobody has declared here: mirroring is a
      # recording act, and refusing an unrecognised status would drop
      # exactly the new value somebody wants to measure.
      assert changeset(%{queue_status: "no_ack_spawn_failed"}).valid?
      assert changeset(%{queue_status: "some_status_invented_next_quarter"}).valid?
    end
  end

  describe "changeset/2 — rule 1: a closed candidate must say why" do
    test "state: :closed with no closed_reason is rejected" do
      cs = changeset(%{state: :closed, closed_reason: nil})

      refute cs.valid?, "a closed card with no reason is what the board cannot render"
      assert %{closed_reason: [message]} = errors_on(cs)
      assert message =~ "closed_reason"
    end

    test "POSITIVE CONTROL: state: :closed WITH a closed_reason passes" do
      assert changeset(%{state: :closed, closed_reason: :done}).valid?
    end

    test "POSITIVE CONTROL: a non-closed state needs no reason" do
      assert changeset(%{state: :acting, closed_reason: nil}).valid?
    end
  end

  describe "changeset/2 — rule 2: an artifact carries no task id" do
    test "outcome_kind: :artifact with a task_id is rejected" do
      cs =
        changeset(%{outcome_kind: :artifact, task_id: Platform.Types.UUIDv7.generate()})

      refute cs.valid?
      assert %{task_id: [message]} = errors_on(cs)
      assert message =~ "must not carry a task id"
    end

    test "POSITIVE CONTROL: :artifact with no task_id passes" do
      assert changeset(%{outcome_kind: :artifact, task_id: nil}).valid?
    end

    test "POSITIVE CONTROL: :artifact with a canvas_id passes — that IS its deliverable" do
      assert changeset(%{
               outcome_kind: :artifact,
               task_id: nil,
               canvas_id: Platform.Types.UUIDv7.generate()
             }).valid?
    end

    test "POSITIVE CONTROL: :task with a task_id passes" do
      assert changeset(%{outcome_kind: :task, task_id: Platform.Types.UUIDv7.generate()}).valid?
    end
  end

  describe "changeset/2 — rule 3: the asymmetry is deliberate" do
    test ":task WITH a canvas_id is legal — a task may produce a supporting canvas" do
      # This is the guard against rule 2 being "tidied" into a symmetric
      # rule. If someone mirrors the artifact check onto :task/canvas_id,
      # this test is what fails.
      cs = changeset(%{outcome_kind: :task, canvas_id: Platform.Types.UUIDv7.generate()})

      assert cs.valid?, "a task candidate may legitimately have produced a supporting canvas"
      refute Map.has_key?(errors_on(cs), :canvas_id)
    end

    test ":task with BOTH a task_id and a canvas_id is legal" do
      assert changeset(%{
               outcome_kind: :task,
               task_id: Platform.Types.UUIDv7.generate(),
               canvas_id: Platform.Types.UUIDv7.generate()
             }).valid?
    end
  end

  describe "persistence" do
    test "a row round-trips with its enums as atoms" do
      {:ok, row} = Repo.insert(changeset(%{state: :closed, closed_reason: :vetoed}))

      reloaded = Repo.get!(MeetingCandidate, row.id)

      assert reloaded.state == :closed
      assert reloaded.closed_reason == :vetoed
      assert reloaded.outcome_kind == :task
      assert reloaded.evidence_quote =~ "onboarding funnel"
      assert reloaded.transcript_chunk_ids == []
    end

    test "transcript_chunk_ids accretes later segments" do
      ids = [Platform.Types.UUIDv7.generate(), Platform.Types.UUIDv7.generate()]

      {:ok, row} = Repo.insert(changeset(%{transcript_chunk_ids: ids}))

      assert Repo.get!(MeetingCandidate, row.id).transcript_chunk_ids == ids
    end

    test "intent_id is unique — the stage-3 mirror's idempotence key" do
      intent_id = Platform.Types.UUIDv7.generate()

      {:ok, _} = Repo.insert(changeset(%{intent_id: intent_id}))

      assert {:error, cs} = Repo.insert(changeset(%{intent_id: intent_id}))
      assert %{intent_id: ["has already been taken"]} = errors_on(cs)
    end

    test "two candidates with a nil intent_id both insert" do
      {:ok, _} = Repo.insert(changeset(%{intent_id: nil}))
      assert {:ok, _} = Repo.insert(changeset(%{intent_id: nil}))
    end
  end

  # ── Threading columns (task 01a03fb9 stage 1) ─────────────────────────────
  #
  # A `{:array, :map}` schema field over a `:map` (jsonb) COLUMN is the
  # pairing `tasks.dependencies` uses, and it is the kind of thing that
  # compiles cleanly and then fails at dump time — so the round trip is
  # asserted through `Repo`, not through the struct held in memory.
  describe "persistence — threading columns" do
    test "threading_events defaults to an empty list and round-trips a populated log" do
      {:ok, bare} = Repo.insert(changeset())

      # The default is the DB's, read back — not the struct's.
      assert Repo.get!(MeetingCandidate, bare.id).threading_events == []

      events = [
        %{"reason" => "same_speaker_within_window", "at" => "2026-08-28T21:00:00Z"},
        %{"reason" => "same_speaker_within_window", "at" => "2026-08-28T21:00:08Z"}
      ]

      {:ok, logged} = Repo.insert(changeset(%{threading_events: events}))

      reloaded = Repo.get!(MeetingCandidate, logged.id)

      # By VALUE, not merely non-empty: an append that dropped the reason
      # would satisfy `length == 2` and lose the only thing that makes a
      # wrong attachment diagnosable afterwards.
      assert reloaded.threading_events == events

      assert Enum.map(reloaded.threading_events, & &1["reason"]) == [
               "same_speaker_within_window",
               "same_speaker_within_window"
             ]
    end

    test "speaker and last_utterance_at round-trip, and last_utterance_at is not heard_at" do
      heard_at = ~U[2026-08-28 21:00:00.000000Z]
      last_utterance_at = ~U[2026-08-28 21:00:08.000000Z]

      {:ok, row} =
        Repo.insert(
          changeset(%{
            speaker: "alice",
            heard_at: heard_at,
            last_utterance_at: last_utterance_at
          })
        )

      reloaded = Repo.get!(MeetingCandidate, row.id)

      assert reloaded.speaker == "alice"
      assert reloaded.last_utterance_at == last_utterance_at

      # The two timestamps are independently writable. If a later change
      # ever collapses them into one column, this is the assertion that
      # notices — a time-window rule reading `heard_at` would call a
      # candidate that has been accreting for a minute a minute stale.
      assert reloaded.heard_at == heard_at
      refute reloaded.heard_at == reloaded.last_utterance_at
    end

    test "an unattributed candidate carries a nil speaker, never an empty string" do
      # nil is the value that cannot match itself. Two unattributed
      # utterances stored as "" would read as the same person to the
      # same-speaker rule stage 3 adds.
      {:ok, row} = Repo.insert(changeset())

      assert is_nil(Repo.get!(MeetingCandidate, row.id).speaker)
    end
  end
end
