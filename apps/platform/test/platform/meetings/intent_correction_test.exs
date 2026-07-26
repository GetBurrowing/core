defmodule Platform.Meetings.IntentCorrectionTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentCorrection` — the schema behind
  `meeting_intent_corrections`, the ONE durable table task 019f70b8
  introduces (stage 6).

  Covers the changeset's required set, `Ecto.Enum` rejection on all
  three enum columns, the `:corrected`-must-name-a-target cross-field
  rule, and — via `EXPLAIN` — that the two access patterns the table
  exists to serve actually reach their indexes rather than sequentially
  scanning a corpus that only grows.
  """

  use Platform.DataCase, async: true

  alias Platform.Meetings.IntentCorrection
  alias Platform.Repo

  # `Platform.DataCase` does not ship an `errors_on/1`; every schema test
  # in this directory defines its own (see `meeting_test.exs`).
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        meeting_id: Platform.Types.UUIDv7.generate(),
        org_id: Platform.Types.UUIDv7.generate(),
        transcript_chunk_excerpt: "we should book a follow-up on the onboarding funnel",
        classified_intent: "action_items",
        classified_target_agent_id: Platform.Types.UUIDv7.generate(),
        dispatch_outcome: :acked,
        correction: :removed_no_action,
        reason: :wrong_target
      },
      overrides
    )
  end

  describe "changeset/2 — required fields" do
    test "valid attrs produce a valid changeset" do
      assert IntentCorrection.changeset(%IntentCorrection{}, valid_attrs()).valid?
    end

    test "meeting_id, classified_intent, correction and reason are required" do
      changeset = IntentCorrection.changeset(%IntentCorrection{}, %{})

      refute changeset.valid?

      for field <- [:meeting_id, :classified_intent, :correction, :reason] do
        assert %{^field => ["can't be blank"]} = errors_on(changeset)
      end
    end

    test "actor_participant_id is NOT required — the AC14 auto-writes have no human actor" do
      changeset =
        IntentCorrection.changeset(
          %IntentCorrection{},
          valid_attrs(%{actor_participant_id: nil})
        )

      assert changeset.valid?
      refute Map.has_key?(errors_on(changeset), :actor_participant_id)
    end

    test "dispatch_outcome is optional — a :queued row pulled by the producer never dispatched" do
      changeset =
        IntentCorrection.changeset(%IntentCorrection{}, valid_attrs(%{dispatch_outcome: nil}))

      assert changeset.valid?
    end
  end

  describe "changeset/2 — enum membership" do
    test "every declared dispatch_outcome casts" do
      for outcome <- IntentCorrection.dispatch_outcomes() do
        changeset =
          IntentCorrection.changeset(
            %IntentCorrection{},
            valid_attrs(%{dispatch_outcome: outcome})
          )

        assert changeset.valid?, "#{outcome} should be a valid dispatch_outcome"
      end
    end

    test "the dispatch_outcome set matches the queue's statuses minus :queued" do
      # The corpus records where an intent HAD GOT TO when it was
      # corrected. `:queued` is expressed as a nil outcome (it never
      # left), so every other queue status must have a corpus value — a
      # tenth queue status shipping without one would silently normalize
      # to nil in the telemetry handler and lose the distinction Saru's
      # status semantics exist to preserve.
      queue_statuses = Platform.Meetings.IntentQueue.statuses() -- [:queued]

      assert Enum.sort(queue_statuses) == Enum.sort(IntentCorrection.dispatch_outcomes())
    end

    test "an unknown dispatch_outcome is rejected" do
      changeset =
        IntentCorrection.changeset(
          %IntentCorrection{},
          valid_attrs(%{dispatch_outcome: :abandoned})
        )

      refute changeset.valid?
      assert %{dispatch_outcome: ["is invalid"]} = errors_on(changeset)
    end

    test "an unknown correction is rejected" do
      changeset =
        IntentCorrection.changeset(%IntentCorrection{}, valid_attrs(%{correction: :reworded}))

      refute changeset.valid?
      assert %{correction: ["is invalid"]} = errors_on(changeset)
    end

    test "an unknown reason is rejected" do
      changeset =
        IntentCorrection.changeset(%IntentCorrection{}, valid_attrs(%{reason: :vibes}))

      refute changeset.valid?
      assert %{reason: ["is invalid"]} = errors_on(changeset)
    end

    test "both correction values cast" do
      assert IntentCorrection.corrections() == [:removed_no_action, :corrected]

      assert IntentCorrection.changeset(
               %IntentCorrection{},
               valid_attrs(%{correction: :corrected, corrected_intent: "brief_worthy"})
             ).valid?
    end

    test "all four reasons cast" do
      for reason <- IntentCorrection.reasons() do
        assert IntentCorrection.changeset(%IntentCorrection{}, valid_attrs(%{reason: reason})).valid?
      end
    end
  end

  describe "changeset/2 — :corrected must name what right looks like" do
    test "a :corrected row with neither corrected_intent nor corrected_target_agent_id is rejected" do
      changeset =
        IntentCorrection.changeset(
          %IntentCorrection{},
          valid_attrs(%{
            correction: :corrected,
            corrected_intent: nil,
            corrected_target_agent_id: nil
          })
        )

      refute changeset.valid?,
             "a :corrected exemplar with no target trains the model on nothing"

      assert %{correction: [message]} = errors_on(changeset)
      assert message =~ "corrected_intent"
    end

    test "a corrected_intent alone satisfies the rule" do
      assert IntentCorrection.changeset(
               %IntentCorrection{},
               valid_attrs(%{correction: :corrected, corrected_intent: "open_question"})
             ).valid?
    end

    test "a corrected_target_agent_id alone satisfies the rule" do
      assert IntentCorrection.changeset(
               %IntentCorrection{},
               valid_attrs(%{
                 correction: :corrected,
                 corrected_target_agent_id: Platform.Types.UUIDv7.generate()
               })
             ).valid?
    end

    test ":removed_no_action carries no such requirement" do
      assert IntentCorrection.changeset(
               %IntentCorrection{},
               valid_attrs(%{
                 correction: :removed_no_action,
                 corrected_intent: nil,
                 corrected_target_agent_id: nil
               })
             ).valid?
    end
  end

  describe "persistence" do
    test "a row round-trips with its enums as atoms" do
      {:ok, row} =
        %IntentCorrection{}
        |> IntentCorrection.changeset(valid_attrs())
        |> Repo.insert()

      reloaded = Repo.get!(IntentCorrection, row.id)

      assert reloaded.dispatch_outcome == :acked
      assert reloaded.correction == :removed_no_action
      assert reloaded.reason == :wrong_target
      assert reloaded.transcript_chunk_excerpt =~ "onboarding funnel"
    end

    test "org_id is nullable — an unresolvable meeting still gets its row" do
      {:ok, row} =
        %IntentCorrection{}
        |> IntentCorrection.changeset(valid_attrs(%{org_id: nil}))
        |> Repo.insert()

      assert is_nil(Repo.get!(IntentCorrection, row.id).org_id)
    end
  end

  describe "indexes" do
    # Both access patterns are hot-path reads against a table that only
    # grows: the classifier hits the org scope once per transcript chunk,
    # and the producer surface hits the meeting scope on every render.
    # Asserting the PLAN rather than the result is the only way to catch
    # an index being dropped — a sequential scan returns identical rows.
    #
    # `SET enable_seqscan = off` is deliberately NOT used: it would make
    # the assertion pass against a table with no indexes at all.

    setup do
      # Seed enough rows that the planner has a reason to prefer an index,
      # and make the scoped org/meeting SELECTIVE — a handful of rows out
      # of hundreds. An org matching half the corpus is cheapest to reach
      # by walking `inserted_at` backwards, which is a correct plan but
      # tells us nothing about the index this test is about.
      org_id = Platform.Types.UUIDv7.generate()
      meeting_id = Platform.Types.UUIDv7.generate()

      for _ <- 1..400 do
        {:ok, _} =
          %IntentCorrection{}
          |> IntentCorrection.changeset(valid_attrs())
          |> Repo.insert()
      end

      for _ <- 1..3 do
        {:ok, _} =
          %IntentCorrection{}
          |> IntentCorrection.changeset(valid_attrs(%{org_id: org_id, meeting_id: meeting_id}))
          |> Repo.insert()
      end

      Repo.query!("ANALYZE meeting_intent_corrections")

      %{org_id: org_id, meeting_id: meeting_id}
    end

    defp explain(sql, params) do
      %{rows: rows} = Repo.query!("EXPLAIN " <> sql, params)
      Enum.map_join(rows, "\n", fn [line] -> line end)
    end

    test "the org-scoped exemplar read uses the (org_id, inserted_at) index", %{org_id: org_id} do
      plan =
        explain(
          """
          SELECT * FROM meeting_intent_corrections
          WHERE org_id = $1
          ORDER BY inserted_at DESC
          LIMIT 10
          """,
          [Ecto.UUID.dump!(org_id)]
        )

      assert plan =~ "meeting_intent_corrections_org_id_inserted_at_index",
             "recent_exemplars/2 must not seq-scan the corpus. Plan:\n#{plan}"
    end

    test "the per-meeting history read uses the (meeting_id, inserted_at) index", %{
      meeting_id: meeting_id
    } do
      plan =
        explain(
          """
          SELECT * FROM meeting_intent_corrections
          WHERE meeting_id = $1
          ORDER BY inserted_at DESC
          """,
          [Ecto.UUID.dump!(meeting_id)]
        )

      assert plan =~ "meeting_intent_corrections_meeting_id_inserted_at_index",
             "list_for_meeting/2 must not seq-scan the corpus. Plan:\n#{plan}"
    end
  end
end
