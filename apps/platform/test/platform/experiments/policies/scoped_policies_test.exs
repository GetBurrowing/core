defmodule Platform.Experiments.Policies.ScopedPoliciesTest do
  @moduledoc """
  The three scope-limited policies and the composite chain.

  The property under test throughout is that being out of scope produces
  `:no_opinion` and NOT a bucket. A policy that quietly bucketed out-of-scope
  subjects would still return a well-formed slug, still write a legitimate
  assignment row, and the only symptom would be an experiment running on a
  population nobody chose.
  """

  use ExUnit.Case, async: true

  alias Platform.Experiments.Policies.Composite
  alias Platform.Experiments.Policies.EpicScoped
  alias Platform.Experiments.Policies.RandomBuckets
  alias Platform.Experiments.Policies.TaskCohort
  alias Platform.Experiments.Policies.TimeWindow
  alias Platform.Experiments.Subject

  @experiment_id "3a2b1c00-0000-4000-8000-000000000003"
  @variants [{"control", 1}, {"treatment", 1}]
  @bucketing [experiment_id: @experiment_id, variants: @variants]

  @in_epic "aa000000-0000-4000-8000-00000000000a"
  @other_epic "aa000000-0000-4000-8000-00000000000b"

  defp subject(attributes),
    do: Subject.new("task", "88888888-8888-4888-8888-888888888888", attributes)

  defp slug?({:ok, slug}), do: slug in ["control", "treatment"]
  defp slug?(_other), do: false

  describe "EpicScoped" do
    test "assigns a subject whose epic is in scope" do
      result =
        EpicScoped.assign(subject(%{epic_id: @in_epic}), [epic_ids: [@in_epic]] ++ @bucketing)

      assert slug?(result)
    end

    test "defers on a subject in another epic" do
      assert EpicScoped.assign(
               subject(%{epic_id: @other_epic}),
               [epic_ids: [@in_epic]] ++ @bucketing
             ) == :no_opinion
    end

    test "defers when the subject has no epic at all" do
      # Not "in scope by default": an unscoped subject is not in every epic.
      assert EpicScoped.assign(subject(%{}), [epic_ids: [@in_epic]] ++ @bucketing) == :no_opinion
    end

    test "defers when no scope is configured" do
      assert EpicScoped.assign(subject(%{epic_id: @in_epic}), @bucketing) == :no_opinion
    end
  end

  describe "TaskCohort" do
    test "assigns when every cohort clause matches" do
      result =
        TaskCohort.assign(
          subject(%{kind: "plan", priority: "high"}),
          [cohort: [{:kind, ["plan"]}, {:priority, ["high", "urgent"]}]] ++ @bucketing
        )

      assert slug?(result)
    end

    test "defers when one clause of several fails" do
      # Every clause must hold. A cohort that matched on ANY clause would
      # silently widen with each key added to it.
      assert TaskCohort.assign(
               subject(%{kind: "plan", priority: "low"}),
               [cohort: [{:kind, ["plan"]}, {:priority, ["high"]}]] ++ @bucketing
             ) == :no_opinion
    end

    test "defers when the subject is missing a cohort key" do
      assert TaskCohort.assign(
               subject(%{kind: "plan"}),
               [cohort: [{:priority, ["high"]}]] ++ @bucketing
             ) == :no_opinion
    end

    test "an empty cohort matches nothing rather than everything" do
      # A predicate with no clauses is vacuously true, which would turn a
      # missing configuration into a silent 100% rollout.
      assert TaskCohort.assign(subject(%{kind: "plan"}), [cohort: []] ++ @bucketing) ==
               :no_opinion

      assert TaskCohort.assign(subject(%{kind: "plan"}), @bucketing) == :no_opinion
    end
  end

  describe "TimeWindow" do
    @from ~U[2026-08-01 00:00:00Z]
    @until ~U[2026-08-31 00:00:00Z]
    @window [from: @from, until: @until]

    test "assigns a subject inside the window" do
      assert slug?(
               TimeWindow.assign(
                 subject(%{inserted_at: ~U[2026-08-15 00:00:00Z]}),
                 @window ++ @bucketing
               )
             )
    end

    test "both bounds are inclusive" do
      assert slug?(TimeWindow.assign(subject(%{inserted_at: @from}), @window ++ @bucketing))
      assert slug?(TimeWindow.assign(subject(%{inserted_at: @until}), @window ++ @bucketing))
    end

    test "defers on a subject before and after the window" do
      assert TimeWindow.assign(
               subject(%{inserted_at: ~U[2026-07-31 23:59:59Z]}),
               @window ++ @bucketing
             ) == :no_opinion

      assert TimeWindow.assign(
               subject(%{inserted_at: ~U[2026-09-01 00:00:01Z]}),
               @window ++ @bucketing
             ) == :no_opinion
    end

    test "a missing timestamp defers instead of defaulting to now" do
      # A default of `now` would put every subject the caller failed to
      # describe inside any window that includes today, invisibly.
      assert TimeWindow.assign(subject(%{}), @window ++ @bucketing) == :no_opinion
      assert TimeWindow.assign(subject(%{inserted_at: nil}), @window ++ @bucketing) == :no_opinion

      # And the control: a window that includes today still does not admit it.
      open_ended = [from: ~U[2000-01-01 00:00:00Z]]
      assert TimeWindow.assign(subject(%{}), open_ended ++ @bucketing) == :no_opinion
    end

    test "an omitted bound is unbounded on that side" do
      subject = subject(%{inserted_at: ~U[2026-08-15 00:00:00Z]})

      assert slug?(TimeWindow.assign(subject, [from: @from] ++ @bucketing))
      assert slug?(TimeWindow.assign(subject, [until: @until] ++ @bucketing))
    end
  end

  describe "Composite" do
    test "returns the first member with an opinion" do
      subject = subject(%{epic_id: @in_epic})

      opts = [
        policies: [
          {EpicScoped, [epic_ids: [@in_epic]] ++ @bucketing},
          {Platform.Experiments.PolicyTestStubs.AlwaysBuckets, []}
        ]
      ]

      # The first member has an opinion, so the second is never consulted.
      assert slug?(Composite.assign(subject, opts))
      refute Composite.assign(subject, opts) == {:ok, "always"}
    end

    test ":no_opinion from member 1 falls through to member 2" do
      subject = subject(%{epic_id: @other_epic})

      opts = [
        policies: [
          {EpicScoped, [epic_ids: [@in_epic]] ++ @bucketing},
          {RandomBuckets, @bucketing}
        ]
      ]

      assert slug?(Composite.assign(subject, opts))
    end

    test "every member deferring is :no_opinion, not a fabricated bucket" do
      subject = subject(%{epic_id: @other_epic})

      opts = [
        policies: [
          {EpicScoped, [epic_ids: [@in_epic]] ++ @bucketing},
          {TimeWindow, [from: ~U[2020-01-01 00:00:00Z]] ++ @bucketing}
        ]
      ]

      assert Composite.assign(subject, opts) == :no_opinion
    end

    test "an empty chain is :no_opinion" do
      assert Composite.assign(subject(%{}), policies: []) == :no_opinion
      assert Composite.assign(subject(%{}), []) == :no_opinion
    end

    test "order decides: the same members reversed give a different answer" do
      # Order is the whole mechanism, and nothing warns when a broad member
      # placed first makes a narrow one unreachable.
      subject = subject(%{epic_id: @in_epic})

      narrow_first = [
        policies: [
          {EpicScoped, [epic_ids: [@in_epic]] ++ @bucketing},
          {Platform.Experiments.PolicyTestStubs.AlwaysBuckets, []}
        ]
      ]

      broad_first = [
        policies: [
          {Platform.Experiments.PolicyTestStubs.AlwaysBuckets, []},
          {EpicScoped, [epic_ids: [@in_epic]] ++ @bucketing}
        ]
      ]

      assert slug?(Composite.assign(subject, narrow_first))
      assert Composite.assign(subject, broad_first) == {:ok, "always"}
    end
  end
end
