defmodule Platform.Experiments.PolicySpecTest do
  @moduledoc """
  `assignment_policy` as data (task 01a0d415, the experimentation-layer ADR-0052):
  the map builds the EXISTING policy modules, and `Assignments.assign_once/3`
  applies it.
  """

  use Platform.DataCase, async: true

  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Policies.Composite
  alias Platform.Experiments.Policies.EpicScoped
  alias Platform.Experiments.Policies.RandomBuckets
  alias Platform.Experiments.Policies.TaskCohort
  alias Platform.Experiments.Policies.TimeWindow
  alias Platform.Experiments.PolicySpec

  defp unique, do: System.unique_integer([:positive])

  defp experiment!(policy) do
    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "pol-#{unique()}",
        name: "Policy",
        assignment_policy: policy
      })

    {:ok, _} = Experiments.add_variant(experiment, %{slug: "control", content: "c", weight: 1})
    {:ok, _} = Experiments.add_variant(experiment, %{slug: "treatment", content: "t", weight: 1})
    experiment
  end

  defp rows(experiment) do
    Repo.all(from(a in Assignment, where: a.experiment_id == ^experiment.id))
  end

  describe "build/2 — data maps build the existing policies" do
    test "each type maps to its module, with context injected" do
      epic = Ecto.UUID.generate()
      ctx = [experiment_id: "exp-1", variants: [{"control", 1}]]

      assert {RandomBuckets, opts} = PolicySpec.build(%{"type" => "random_buckets"}, ctx)
      assert opts[:experiment_id] == "exp-1"
      assert opts[:variants] == [{"control", 1}]

      assert {EpicScoped, opts} =
               PolicySpec.build(%{"type" => "epic_scoped", "epic_ids" => [epic]}, ctx)

      assert opts[:epic_ids] == [epic]

      assert {TaskCohort, opts} =
               PolicySpec.build(%{"type" => "task_cohort", "cohort" => %{"epic_id" => [epic]}})

      assert opts[:cohort] == [epic_id: [epic]]

      assert {TimeWindow, opts} =
               PolicySpec.build(%{"type" => "time_window", "from" => "2026-09-01T00:00:00Z"})

      assert opts[:from] == ~U[2026-09-01 00:00:00Z]
      refute Keyword.has_key?(opts, :until)
    end

    test "composite members are built recursively and each receives the context" do
      epic = Ecto.UUID.generate()

      assert {Composite, opts} =
               PolicySpec.build(
                 %{
                   "type" => "composite",
                   "policies" => [
                     %{"type" => "epic_scoped", "epic_ids" => [epic]},
                     %{"type" => "random_buckets"}
                   ]
                 },
                 experiment_id: "exp-2",
                 variants: []
               )

      assert [{EpicScoped, epic_opts}, {RandomBuckets, rb_opts}] = opts[:policies]
      assert epic_opts[:experiment_id] == "exp-2"
      assert rb_opts[:experiment_id] == "exp-2"
    end

    test "the shared exclude key becomes the policy library's :exclude option" do
      project = Ecto.UUID.generate()

      assert {RandomBuckets, opts} =
               PolicySpec.build(%{"exclude" => %{"project_ids" => [project]}})

      assert opts[:exclude] == [project_ids: [project]]
    end

    test "an empty map is :none — the weighted pick — and build/2 refuses it" do
      assert PolicySpec.parse(%{}, []) == :none
      assert PolicySpec.validate(%{}) == :ok
      assert_raise ArgumentError, fn -> PolicySpec.build(%{}) end
    end

    test "malformed maps are errors, never a silent default" do
      for bad <- [
            %{"type" => "everyone"},
            %{"type" => "epic_scoped"},
            %{"type" => "epic_scoped", "epic_ids" => "not-a-list"},
            %{"type" => "task_cohort", "cohort" => %{"favourite_colour" => ["blue"]}},
            %{"type" => "time_window", "from" => "yesterday"},
            %{"type" => "composite", "policies" => []},
            %{"type" => "random_buckets", "surprise" => true},
            %{"exclude" => %{"team_ids" => []}}
          ] do
        assert {:error, [_ | _]} = PolicySpec.validate(bad), inspect(bad)
      end
    end

    test "a policy written with 'kind' instead of 'type' names the key, not random_buckets" do
      assert {:error, [message]} =
               PolicySpec.validate(%{"kind" => "task_cohort", "project_id" => "p"})

      assert message =~ "unknown policy key 'kind'"
      assert message =~ "use"
      assert message =~ "'type'"
      refute message =~ "random_buckets takes no parameters"
    end

    test "the experiment changeset refuses a malformed policy" do
      assert {:error, changeset} =
               Experiments.create_experiment(%{
                 slug: "badpol-#{unique()}",
                 name: "Bad policy",
                 assignment_policy: %{"type" => "everyone"}
               })

      assert {message, _} = changeset.errors[:assignment_policy]
      assert message =~ "unknown policy type"
    end
  end

  describe "Assignments.assign_once/3 applies the policy" do
    test "an excluded subject leaves a row with a reason" do
      project = Ecto.UUID.generate()
      experiment = experiment!(%{"exclude" => %{"project_ids" => [project]}})
      subject_id = Ecto.UUID.generate()

      assert {:ok, %Assignment{excluded_reason: "project excluded", variant_slug: "control"}} =
               Assignments.assign_once(experiment, {"task", subject_id}, %{project_id: project})

      assert [%Assignment{subject_id: ^subject_id, excluded_reason: "project excluded"}] =
               rows(experiment)

      # Visible, and out of both sides of every ratio.
      assert Metrics.subject_ids(experiment.id, "control") == []
    end

    test "no_opinion leaves no row" do
      in_scope = Ecto.UUID.generate()
      experiment = experiment!(%{"type" => "epic_scoped", "epic_ids" => [in_scope]})

      assert :no_opinion =
               Assignments.assign_once(experiment, {"task", Ecto.UUID.generate()}, %{
                 epic_id: Ecto.UUID.generate()
               })

      assert rows(experiment) == []

      # Positive control: an in-scope subject is assigned.
      assert {:ok, %Assignment{excluded_reason: nil, variant_slug: slug}} =
               Assignments.assign_once(experiment, {"task", Ecto.UUID.generate()}, %{
                 epic_id: in_scope
               })

      assert slug in ["control", "treatment"]
      assert length(rows(experiment)) == 1
    end

    test "an empty policy with no project is the weighted pick, unchanged" do
      experiment = experiment!(%{})

      assert {:ok, %Assignment{excluded_reason: nil, variant_slug: slug}} =
               Assignments.assign_once(experiment, {"task", Ecto.UUID.generate()}, %{})

      assert slug in ["control", "treatment"]
    end
  end
end
