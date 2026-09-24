defmodule Platform.Experiments.ExperimentTenancyTest do
  @moduledoc """
  Tenancy is the `org_id` / `project_id` COLUMNS (task 01a0d415, the
  experimentation-layer ADR-0052). There is no `scope` field.
  """

  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Experiment
  alias Platform.Tasks

  defp unique, do: System.unique_integer([:positive])

  defp project!(org_id) do
    {:ok, project} = Tasks.create_project(%{name: "Tenancy #{unique()}", org_id: org_id})
    project
  end

  defp experiment!(attrs) do
    {:ok, experiment} =
      Experiments.create_experiment(Map.merge(%{slug: "ten-#{unique()}", name: "Tenancy"}, attrs))

    {:ok, _} = Experiments.add_variant(experiment, %{slug: "control", content: "c", weight: 1})
    experiment
  end

  test "there is no scope field" do
    refute :scope in Experiment.__schema__(:fields)
    assert :org_id in Experiment.__schema__(:fields)
    assert :project_id in Experiment.__schema__(:fields)
  end

  test "an experiment with project P and no org gets P's org_id" do
    org = tenant_org_id("soylent")
    project = project!(org)

    experiment = experiment!(%{project_id: project.id})

    assert experiment.project_id == project.id
    assert experiment.org_id == org
    assert Repo.get!(Experiment, experiment.id).org_id == org
  end

  test "a project/org mismatch is a changeset error" do
    project = project!(tenant_org_id("soylent"))

    assert {:error, changeset} =
             Experiments.create_experiment(%{
               slug: "mismatch-#{unique()}",
               name: "Mismatch",
               project_id: project.id,
               org_id: tenant_org_id("sxi")
             })

    assert {"project does not belong to org", _} = changeset.errors[:project_id]
  end

  test "an unscoped experiment stays install-wide: both columns NULL" do
    experiment = experiment!(%{})

    assert experiment.org_id == nil
    assert experiment.project_id == nil
  end

  test "an experiment scoped to project P gives a subject in project Q no assignment row" do
    org = tenant_org_id("soylent")
    p = project!(org)
    q = project!(org)
    experiment = experiment!(%{project_id: p.id})

    outsider = Ecto.UUID.generate()

    assert :no_opinion =
             Assignments.assign_once(experiment, {"task", outsider}, %{project_id: q.id})

    assert Repo.aggregate(from(a in Assignment, where: a.experiment_id == ^experiment.id), :count) ==
             0

    # Positive control: a subject in P IS assigned, so the refusal above is
    # the scope check and not a broken experiment.
    insider = Ecto.UUID.generate()

    assert {:ok, %Assignment{variant_slug: "control", excluded_reason: nil}} =
             Assignments.assign_once(experiment, {"task", insider}, %{project_id: p.id})

    assert Repo.aggregate(from(a in Assignment, where: a.experiment_id == ^experiment.id), :count) ==
             1
  end

  test "an org-wide experiment takes subjects of its org only" do
    org = tenant_org_id("soylent")
    experiment = experiment!(%{org_id: org})

    assert :no_opinion =
             Assignments.assign_once(experiment, {"task", Ecto.UUID.generate()}, %{
               org_id: tenant_org_id("sxi")
             })

    assert {:ok, %Assignment{}} =
             Assignments.assign_once(experiment, {"task", Ecto.UUID.generate()}, %{org_id: org})
  end

  test "a subject with no project is not in a project-scoped experiment" do
    p = project!(tenant_org_id("soylent"))
    experiment = experiment!(%{project_id: p.id})

    assert :no_opinion = Assignments.assign_once(experiment, {"task", Ecto.UUID.generate()}, %{})
  end
end
