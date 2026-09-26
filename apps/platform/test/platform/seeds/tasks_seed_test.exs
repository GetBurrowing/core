defmodule Platform.Seeds.TasksSeedTest do
  @moduledoc """
  Runs `priv/repo/seeds/tasks_seed.exs` against the sandbox (task 01a08c4f
  stage 1).

  The sandbox holds what a freshly migrated DB holds: the root org seeded by
  `20260519143620_seed_root_orgs.exs` and no projects. The precondition
  asserts that explicitly, so a future migration that seeds a project makes
  this test fail loudly instead of quietly exercising the populated path.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Platform.Repo
  alias Platform.Tasks.{Epic, Plan, Project, Stage, Task, Validation}
  alias Platform.Tenancy.Org

  @seed_path Path.expand("priv/repo/seeds/tasks_seed.exs", File.cwd!())

  defp run_seed do
    capture_io(fn -> Code.eval_file(@seed_path) end)
  end

  defp counts do
    %{
      projects: Repo.aggregate(Project, :count),
      epics: Repo.aggregate(Epic, :count),
      tasks: Repo.aggregate(Task, :count),
      plans: Repo.aggregate(Plan, :count),
      stages: Repo.aggregate(Stage, :count),
      validations: Repo.aggregate(Validation, :count)
    }
  end

  setup do
    assert Repo.aggregate(Project, :count) == 0,
           "precondition: the sandbox must hold no project (the fresh-DB condition)"

    roots = Repo.all(from(o in Org, where: is_nil(o.parent_org_id)))
    assert [root] = roots, "precondition: exactly one root org, got #{length(roots)}"

    %{root: root}
  end

  test "A: one run on a DB with no project seeds the project under the root org", %{root: root} do
    run_seed()

    assert [project] = Repo.all(Project)
    assert project.slug == "startup-suite-core"
    assert project.org_id == root.id

    assert %{projects: 1, epics: 2, tasks: 8, plans: 2, stages: 6, validations: 3} = counts()
  end

  test "B: a second run adds nothing" do
    run_seed()
    first = counts()

    run_seed()
    assert counts() == first
    assert %{projects: 1, epics: 2, tasks: 8, plans: 2, stages: 6, validations: 3} = first
  end
end
