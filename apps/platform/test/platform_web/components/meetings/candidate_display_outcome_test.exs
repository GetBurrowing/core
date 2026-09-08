defmodule PlatformWeb.Components.Meetings.CandidateDisplayOutcomeTest do
  @moduledoc """
  The closed row's deliverable: where it lives, what kind it is, and the
  one case where saying nothing would be a lie (task 01a078d0 stage 1).

  ## Every claim here is keyed on a STORED ID

  That is the organising rule, and it is inherited from `outcome_label/1`
  rather than invented here. `Platform.Meetings.Candidates.graduate/2`
  can fail against an archived project and leave a CLOSED row with no
  deliverable at all, so anything derived from `state` — or from
  `outcome_kind`, which records what the card was aiming at rather than
  what it reached — would announce a task that was never created.

  So the fixtures below vary the ids and hold everything else still, and
  the `outcome_kind` on the both-ids row is deliberately set to the
  value that would give the WRONG answer if the code branched on it.

  ## Why the two kinds are compared against each other

  `outcome_path/1` and `outcome_kind_label/1` each have a task clause
  and a canvas clause, and a single fixture proves nothing about which
  one ran — a function that ignored `canvas_id` entirely and always
  built a `/tasks/` path would satisfy any test that only ever looked at
  a task row. Each of the two is therefore asserted to produce a
  DIFFERENT string for the two kinds, in the same test, so the branch
  itself is what is under test rather than one side of it.
  """

  use ExUnit.Case, async: true

  alias Platform.Meetings.MeetingCandidate
  alias PlatformWeb.Components.Meetings.CandidateDisplay

  @task_id "01a07a65-0000-7001-8000-0000000000a1"
  @canvas_id "01a07a65-0000-7001-8000-0000000000c2"

  # Structs, not bare maps, for the reason `candidate_rail_test.exs`
  # gives: a key typo (`:cavnas_id`) would answer nil through a map
  # pattern and the test would pass on the wrong reading, whereas
  # `MeetingCandidate` rejects an unknown key at compile time.
  defp candidate(attrs) do
    struct!(
      %MeetingCandidate{
        id: Ecto.UUID.generate(),
        evidence_quote: "we should rotate the staging secrets",
        state: :closed,
        task_id: nil,
        canvas_id: nil,
        disposition: nil
      },
      attrs
    )
  end

  describe "outcome_path/1" do
    test "a task row links to the task, a canvas row links to the canvas, and the two differ" do
      task_row = candidate(task_id: @task_id)
      canvas_row = candidate(canvas_id: @canvas_id)

      task_path = CandidateDisplay.outcome_path(task_row)
      canvas_path = CandidateDisplay.outcome_path(canvas_row)

      assert task_path == "/tasks/" <> @task_id
      assert canvas_path == "/canvases/" <> @canvas_id

      # The discriminating assertion: one fixture proves nothing about
      # the branch. A function that ignored `canvas_id` and always built
      # a `/tasks/` path would pass both lines above only if these two
      # were allowed to coincide.
      refute task_path == canvas_path
    end

    test "a row carrying BOTH ids resolves to the task, even when outcome_kind says artifact" do
      # `outcome_kind: :artifact` is the value that would produce the
      # WRONG answer if the code branched on the kind instead of the
      # ids. It is set here precisely so that mistake cannot pass.
      both = candidate(task_id: @task_id, canvas_id: @canvas_id, outcome_kind: :artifact)

      assert CandidateDisplay.outcome_path(both) == "/tasks/" <> @task_id
      refute CandidateDisplay.outcome_path(both) == "/canvases/" <> @canvas_id
    end

    test "a row that reached nothing has no route" do
      assert CandidateDisplay.outcome_path(candidate([])) == nil
    end
  end

  describe "outcome_kind_label/1" do
    test "names the two kinds differently" do
      task_label = CandidateDisplay.outcome_kind_label(candidate(task_id: @task_id))
      canvas_label = CandidateDisplay.outcome_kind_label(candidate(canvas_id: @canvas_id))

      assert task_label == "TASK"
      assert canvas_label == "CANVAS"
      refute task_label == canvas_label
    end

    test "a row carrying BOTH ids is a TASK" do
      both = candidate(task_id: @task_id, canvas_id: @canvas_id, outcome_kind: :artifact)

      assert CandidateDisplay.outcome_kind_label(both) == "TASK"
    end

    test "a row that reached nothing has no kind" do
      assert CandidateDisplay.outcome_kind_label(candidate([])) == nil
    end
  end

  describe "closed_outcome_line/1" do
    test "an ACCEPTED row with neither id says nothing was created" do
      accepted = candidate(disposition: :accepted)

      assert CandidateDisplay.closed_outcome_line(accepted) == "Nothing was created"

      # The other two stay silent on the same row: there is no
      # deliverable to point at, and a link here would 404.
      assert CandidateDisplay.outcome_path(accepted) == nil
      assert CandidateDisplay.outcome_kind_label(accepted) == nil
    end

    test "a NON-accepted row with neither id stays quiet on all three" do
      # Nothing was supposed to be created, so the absence is not a
      # failure and must not be reported as one.
      for disposition <- [:rejected, :timed_out, nil] do
        row = candidate(disposition: disposition)

        assert CandidateDisplay.closed_outcome_line(row) == nil,
               "expected silence for disposition #{inspect(disposition)}"

        assert CandidateDisplay.outcome_path(row) == nil
        assert CandidateDisplay.outcome_kind_label(row) == nil
      end
    end

    test "an accepted row that DID produce something says nothing" do
      # The line is about the empty-handed case only; a row with a
      # deliverable is described by `outcome_path/1` instead.
      assert CandidateDisplay.closed_outcome_line(
               candidate(disposition: :accepted, task_id: @task_id)
             ) == nil

      assert CandidateDisplay.closed_outcome_line(
               candidate(disposition: :accepted, canvas_id: @canvas_id)
             ) == nil
    end
  end
end
