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

  # An ARMED row — still counting down, nothing produced. Both ids are
  # nil because that is the only shape an armed row has: `acts_at` is
  # nilled in the same write that moves the row to `:acting`, and
  # `graduate/2` writes an id strictly after that. A fixture with an id
  # on it would not be an armed card, and a test built on one would pass
  # against an implementation that renders nothing during the countdown.
  defp armed(attrs) do
    struct!(
      %MeetingCandidate{
        id: Ecto.UUID.generate(),
        evidence_quote: "we should rotate the staging secrets",
        state: :shaping,
        acts_at: ~U[2026-09-08 22:00:00Z],
        task_id: nil,
        canvas_id: nil,
        disposition: nil
      },
      attrs
    )
  end

  describe "armed_outcome_label/1" do
    test "a :task row names a task" do
      label = CandidateDisplay.armed_outcome_label(armed(outcome_kind: :task))

      assert is_binary(label)
      assert label != ""
    end

    test "an :artifact row names a canvas" do
      label = CandidateDisplay.armed_outcome_label(armed(outcome_kind: :artifact))

      assert is_binary(label)
      assert label != ""
    end

    test "names the two armed kinds differently" do
      # The only assertion in this describe that catches the real bug.
      # Each of the two tests above passes against a function that
      # returns one constant for everything; this one does not.
      task_label = CandidateDisplay.armed_outcome_label(armed(outcome_kind: :task))
      artifact_label = CandidateDisplay.armed_outcome_label(armed(outcome_kind: :artifact))

      refute task_label == artifact_label
    end

    test "an armed row with NEITHER id still names what it is aiming at" do
      # The real shape of an armed card. Anything keyed on `task_id` /
      # `canvas_id` answers nil here, which is a blank line on screen for
      # the whole countdown.
      row = armed(outcome_kind: :artifact)

      assert row.task_id == nil
      assert row.canvas_id == nil
      assert CandidateDisplay.armed_outcome_label(row) != nil

      # The nil-safe clause, on the same family of id-less rows: a row
      # whose kind was never recorded renders nothing rather than raising
      # and taking the rail down with it.
      assert CandidateDisplay.armed_outcome_label(armed(outcome_kind: nil)) == nil
    end

    test "the stored :artifact token never reaches the DOM as the word artifact" do
      label = CandidateDisplay.armed_outcome_label(armed(outcome_kind: :artifact))

      refute String.downcase(label) =~ "artifact"
    end

    test "every outcome_kind gets its own word" do
      # Walks the enum rather than naming the two members, so a third
      # `outcome_kind` fails HERE — loudly, at the point somebody adds
      # it — instead of rendering a blank noun during a live meeting.
      labels =
        Map.new(MeetingCandidate.outcome_kinds(), fn kind ->
          label = CandidateDisplay.armed_outcome_label(armed(outcome_kind: kind))

          assert is_binary(label) and label != "",
                 "no armed word for outcome_kind #{inspect(kind)}"

          {kind, label}
        end)

      distinct = labels |> Map.values() |> Enum.uniq()

      assert length(distinct) == map_size(labels),
             "two outcome_kinds share one armed word: #{inspect(labels)}"
    end
  end
end
