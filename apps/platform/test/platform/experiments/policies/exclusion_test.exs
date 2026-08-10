defmodule Platform.Experiments.Policies.ExclusionTest do
  @moduledoc """
  The exclusion filter, asserted across EVERY policy rather than once against
  the helper.

  Asserting only `Policy.excluded?/2` would prove the helper works and say
  nothing about whether any policy calls it. Each policy buckets on its own
  path, so each must be shown to consult the filter before it does.

  Every assertion matches the `{:excluded, reason}` TUPLE. `refute result ==
  {:ok, "control"}` would pass on `:no_opinion`, which means something
  entirely different — the subject was never a candidate — and would leave a
  policy that silently defers instead of excluding indistinguishable from
  one that works.
  """

  use ExUnit.Case, async: true

  alias Platform.Experiments.Policies.Composite
  alias Platform.Experiments.Policies.EpicScoped
  alias Platform.Experiments.Policies.RandomBuckets
  alias Platform.Experiments.Policies.TaskCohort
  alias Platform.Experiments.Policies.TimeWindow
  alias Platform.Experiments.Policy
  alias Platform.Experiments.Subject

  @experiment_id "3a2b1c00-0000-4000-8000-000000000002"
  @bad_project "9c000000-0000-4000-8000-00000000000a"
  @bad_epic "9c000000-0000-4000-8000-00000000000b"
  @ok_project "9c000000-0000-4000-8000-00000000000c"
  @ok_epic "9c000000-0000-4000-8000-00000000000d"

  @variants [{"control", 1}, {"treatment", 1}]
  @exclude [exclude: [project_ids: [@bad_project], epic_ids: [@bad_epic]]]

  @now ~U[2026-08-09 12:00:00Z]

  defp subject(attributes),
    do: Subject.new("task", "77777777-7777-4777-8777-777777777777", attributes)

  # Options that make every policy WANT to bucket this subject, so the only
  # thing that can produce an exclusion is the filter. A policy that was
  # simply out of scope would return :no_opinion and the tuple assertion
  # would catch it.
  defp all_in_opts(subject) do
    [
      experiment_id: @experiment_id,
      variants: @variants,
      epic_ids: [subject.attributes[:epic_id]],
      cohort: [{:project_id, [subject.attributes[:project_id]]}],
      from: ~U[2026-01-01 00:00:00Z],
      until: ~U[2026-12-31 00:00:00Z]
    ] ++ @exclude
  end

  describe "Policy.excluded?/2" do
    test "an unlisted subject is not excluded" do
      subject = subject(%{project_id: @ok_project, epic_id: @ok_epic})
      assert Policy.excluded?(subject, @exclude) == false
    end

    test "a subject with no scoping attributes is not excluded" do
      assert Policy.excluded?(subject(%{}), @exclude) == false
    end

    test "a nil attribute does not match a list containing nil" do
      # Otherwise one nil in the exclusion list empties the experiment.
      assert Policy.excluded?(subject(%{}), exclude: [project_ids: [nil]]) == false
    end

    test "an absent :exclude excludes nothing" do
      subject = subject(%{project_id: @bad_project})
      assert Policy.excluded?(subject, []) == false
    end
  end

  for {name, module} <- [
        {"RandomBuckets", Platform.Experiments.Policies.RandomBuckets},
        {"EpicScoped", Platform.Experiments.Policies.EpicScoped},
        {"TaskCohort", Platform.Experiments.Policies.TaskCohort},
        {"TimeWindow", Platform.Experiments.Policies.TimeWindow}
      ] do
    describe "#{name} exclusion" do
      test "an excluded project yields {:excluded, reason}, never a slug" do
        subject = subject(%{project_id: @bad_project, epic_id: @ok_epic, inserted_at: @now})

        assert {:excluded, reason} = unquote(module).assign(subject, all_in_opts(subject))
        assert reason == "project excluded"
      end

      test "an excluded epic yields {:excluded, reason}, never a slug" do
        subject = subject(%{project_id: @ok_project, epic_id: @bad_epic, inserted_at: @now})

        assert {:excluded, reason} = unquote(module).assign(subject, all_in_opts(subject))
        assert reason == "epic excluded"
      end

      test "an unexcluded subject in scope still receives a slug" do
        # Anti-vacuity for the two tests above: if these options excluded
        # everything, or the policy deferred on all four subjects, the
        # exclusion assertions would be true for the wrong reason.
        subject = subject(%{project_id: @ok_project, epic_id: @ok_epic, inserted_at: @now})

        assert {:ok, slug} = unquote(module).assign(subject, all_in_opts(subject))
        assert slug in ["control", "treatment"]
      end
    end
  end

  describe "Composite exclusion" do
    test "an excluded subject is excluded even though a member would bucket it" do
      subject = subject(%{project_id: @bad_project, epic_id: @ok_epic, inserted_at: @now})

      opts =
        [policies: [{RandomBuckets, [experiment_id: @experiment_id, variants: @variants]}]] ++
          @exclude

      assert {:excluded, "project excluded"} = Composite.assign(subject, opts)
    end

    test "the composite's own filter holds even when no member checks" do
      # The member below deliberately ignores :exclude, the way a policy
      # written elsewhere might. If Composite delegated the guarantee to its
      # members, this excluded subject would come back with a slug. This is
      # the test that fails when the excluded?/2 call is removed from
      # Composite — the other cases here survive it, because every policy in
      # this library also checks.
      subject = subject(%{epic_id: @bad_epic})

      opts = [policies: [{Platform.Experiments.PolicyTestStubs.AlwaysBuckets, []}]] ++ @exclude

      assert {:excluded, "epic excluded"} = Composite.assign(subject, opts)
    end

    test "an unexcluded subject still reaches the member" do
      subject = subject(%{epic_id: @ok_epic})
      opts = [policies: [{Platform.Experiments.PolicyTestStubs.AlwaysBuckets, []}]] ++ @exclude

      assert Composite.assign(subject, opts) == {:ok, "always"}
    end
  end

  describe "scope-limited policies out of scope" do
    test "EpicScoped defers rather than excluding" do
      subject = subject(%{epic_id: @ok_epic})
      assert EpicScoped.assign(subject, epic_ids: ["someone-else"]) == :no_opinion
    end

    test "TaskCohort defers rather than excluding" do
      subject = subject(%{project_id: @ok_project})
      assert TaskCohort.assign(subject, cohort: [{:project_id, ["someone-else"]}]) == :no_opinion
    end

    test "TimeWindow defers rather than excluding" do
      subject = subject(%{inserted_at: @now})

      assert TimeWindow.assign(subject,
               from: ~U[2020-01-01 00:00:00Z],
               until: ~U[2020-02-01 00:00:00Z]
             ) == :no_opinion
    end
  end
end
