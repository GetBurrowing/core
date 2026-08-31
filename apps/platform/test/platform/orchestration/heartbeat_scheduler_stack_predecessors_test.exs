defmodule Platform.Orchestration.HeartbeatSchedulerStackPredecessorsTest do
  @moduledoc """
  Task 01a05394-8300 stage 5 — predecessor landing state on the EXECUTION
  dispatch (`HeartbeatScheduler.render_stack_predecessors_section/1`).

  DataCase because the resolver reads the predecessor rows (title, status,
  `merged_into_rollup_at` stamp) from the DB; `heartbeat_scheduler_test.exs`
  is `use ExUnit.Case` with plain-map fixtures and cannot reach them.

  Every claim is paired: the section names both predecessors — the DIRECT dep
  B and the TRANSITIVE one A (chain C -> B -> A, C not declaring A) — and
  distinguishes landed from unlanded; the same holds for a member that
  declares both directly; AND a root member / a non-stack task render no
  header at all. A sibling-boundary guard pins that the git-workflow block is still
  rendered beside it (asserted on tokens stable across the sibling rewrite).
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Tasks
  alias Platform.Tasks.Stacks

  @heading "## Stack predecessors (landing state)"
  @landed "[LANDED]"
  @not_landed "[NOT LANDED]"
  # Stable across the c79c stage-4 rewrite of the stack git-workflow section:
  # the `Base branch:` label and the membership sub-heading were not reworded.
  @git_workflow_heading "## Git Workflow (CRITICAL)"
  @membership_heading "## Task Stack Membership"

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Predecessors #{uniq()}",
        repo_url: "https://github.com/test/predecessors-#{uniq()}"
      })

    slug = "preds-#{uniq()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stack #{slug}",
        base_branch: "main",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    {:ok, _} = Stacks.update_stack(stack, %{status: "in_progress", metadata: ready_stamp()})

    {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "Root member A #{uniq()}"})

    {:ok, b} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Middle member B #{uniq()}",
        dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
      })

    # C declares B ONLY — A is reachable through B alone. This is the chain
    # the behavioural gate renders; a single-hop resolver names B and not A.
    {:ok, c} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Leaf member C #{uniq()}",
        dependencies: [%{"task_id" => b.id, "kind" => "blocks"}]
      })

    # Dependency-respecting insertion order: each add_task's own validate_dag
    # needs the prior member present.
    {:ok, _} = Stacks.add_task(stack, a)
    {:ok, _} = Stacks.add_task(stack, b)
    {:ok, _} = Stacks.add_task(stack, c)

    # A has landed on the rollup; B has not. `Task.changeset` rejects a stamp
    # without `at`, so the fixture carries the full shape.
    {:ok, _} =
      Tasks.update_task(Tasks.get_task_detail(a.id), %{
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => "abc1234abc1234", "at" => "2026-08-30T12:00:00Z"}
        }
      })

    {:ok, solo} = Tasks.create_task(%{project_id: project.id, title: "Solo task #{uniq()}"})

    {:ok, project: project, stack: stack, a: a, b: b, c: c, solo: solo}
  end

  describe "chain C -> B -> A where C declares B only (transitive predecessor)" do
    test "names both predecessor ids and distinguishes landed from unlanded", %{a: a, b: b, c: c} do
      # Precondition of the claim: C's own row does NOT declare A.
      refute a.id in declared_dep_ids(c)

      section = predecessors_section(render(c))
      assert_a_landed_b_not(section, a, b)
    end

    test "predecessors are listed in stack_position order (A before B)", %{a: a, b: b, c: c} do
      section = predecessors_section(render(c))
      {a_at, _} = :binary.match(section, "`#{a.id}`")
      {b_at, _} = :binary.match(section, "`#{b.id}`")
      assert a_at < b_at
    end

    test "PAIRED: a member declaring BOTH A and B directly renders the same two lines", %{
      project: project,
      stack: stack,
      a: a,
      b: b
    } do
      {:ok, d} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Direct-deps member D #{uniq()}",
          dependencies: [
            %{"task_id" => a.id, "kind" => "blocks"},
            %{"task_id" => b.id, "kind" => "blocks"}
          ]
        })

      {:ok, _} = Stacks.add_task(stack, d)

      section = predecessors_section(render(d))
      assert_a_landed_b_not(section, a, b)
    end

    test "a diamond (E -> {B, D} -> A) lists each ancestor exactly once", %{
      project: project,
      stack: stack,
      a: a,
      b: b
    } do
      {:ok, d} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Other middle D #{uniq()}",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, d)

      {:ok, e} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Diamond leaf E #{uniq()}",
          dependencies: [
            %{"task_id" => b.id, "kind" => "blocks"},
            %{"task_id" => d.id, "kind" => "blocks"}
          ]
        })

      {:ok, _} = Stacks.add_task(stack, e)

      section = predecessors_section(render(e))
      bullets = bullet_lines(section)

      assert length(bullets) == 3
      assert Enum.count(bullets, &String.contains?(&1, "`#{a.id}`")) == 1
      assert Enum.count(bullets, &String.contains?(&1, "`#{b.id}`")) == 1
      assert Enum.count(bullets, &String.contains?(&1, "`#{d.id}`")) == 1
      assert line_for(section, a.id) =~ @landed
      refute section =~ "`#{e.id}`"
    end

    test "a dependency cycle written past the DAG guard terminates and never lists the member itself",
         %{a: a, b: b, c: c} do
      # `Stacks.add_task` validates the DAG, so a cycle can only arrive via a
      # direct row update. The walk must still reach a fixpoint.
      {:ok, _} =
        Tasks.update_task(Tasks.get_task_detail(a.id), %{
          dependencies: [%{"task_id" => c.id, "kind" => "blocks"}]
        })

      section = predecessors_section(render(c))
      bullets = bullet_lines(section)

      assert length(bullets) == 2
      assert line_for(section, a.id) =~ @landed
      assert line_for(section, b.id) =~ @not_landed
      refute section =~ "`#{c.id}`"
    end

    test "the git-workflow section is still rendered beside it (sibling boundary guard)", %{
      stack: stack,
      c: c
    } do
      prompt = render(c)

      assert prompt =~ @git_workflow_heading
      assert prompt =~ @membership_heading
      assert prompt =~ "Base branch:"
      assert prompt =~ "-b task/#{c.id} origin/#{stack.rollup_branch}"

      # Joined, not replaced: the git block precedes the predecessor section
      # (both survive, in that order) and the contract is still present.
      {git_at, _} = :binary.match(prompt, @git_workflow_heading)
      {preds_at, _} = :binary.match(prompt, @heading)
      assert git_at < preds_at
      assert prompt =~ "## Stage Execution Contract"
    end
  end

  describe "paired negatives" do
    test "a ROOT member renders no predecessor header at all, but keeps the git-workflow section",
         %{a: a} do
      prompt = render(a)

      refute prompt =~ @heading
      refute prompt =~ @landed
      refute prompt =~ @not_landed
      assert prompt =~ @git_workflow_heading
      assert prompt =~ @membership_heading
    end

    test "a NON-stack task renders no predecessor section, and keeps its git-workflow section", %{
      solo: solo
    } do
      prompt = render(solo)

      refute prompt =~ @heading
      refute prompt =~ @landed
      refute prompt =~ @not_landed
      assert prompt =~ @git_workflow_heading
      refute prompt =~ @membership_heading
    end

    test "a dep on a task OUTSIDE the stack contributes no predecessor line", %{
      project: project,
      stack: stack,
      solo: solo
    } do
      {:ok, d} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Member with cross-stack dep #{uniq()}",
          dependencies: [%{"task_id" => solo.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, d)

      prompt = render(d)

      refute prompt =~ @heading
      refute prompt =~ solo.id
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Reload with `:stack` preloaded (the shape the router hands the renderer)
  # and put the task in the execution status the in_progress dispatch keys on
  # — the renderer only reads the field.
  defp load(task), do: task.id |> Tasks.get_task_detail() |> Map.put(:status, "in_progress")

  defp render(task), do: HeartbeatScheduler.dispatch_prompt(load(task), plan(), stage())

  defp plan, do: %{version: 1, stages: [%{}]}

  defp stage do
    %{
      id: "01a05394-preds-stage",
      position: 1,
      name: "coding",
      description: "Predecessor probe stage",
      validations: [%{id: "val-preds-1", kind: "test_pass"}]
    }
  end

  defp ready_stamp do
    %{"rollup_branch_ready" => %{"at" => "2026-08-30T00:00:00Z", "base_sha" => "abc1234"}}
  end

  # The section runs from its heading to the next heading / context anchor.
  defp predecessors_section(prompt) do
    assert prompt =~ @heading
    [_, rest] = String.split(prompt, @heading, parts: 2)

    [section | _] =
      String.split(rest, ~r/\n## |\nThe attention signal|\nThe Stage Description block above/,
        parts: 2
      )

    section
  end

  # Bullet lines only: the section's prose legitimately mentions the tokens once.
  defp bullet_lines(section),
    do: section |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "- `"))

  defp assert_a_landed_b_not(section, a, b) do
    a_line = line_for(section, a.id)
    b_line = line_for(section, b.id)

    assert a_line =~ @landed
    refute a_line =~ @not_landed
    assert b_line =~ @not_landed
    refute b_line =~ @landed

    # Title and status are rendered from the row, not invented.
    a_row = Tasks.get_task_detail(a.id)
    b_row = Tasks.get_task_detail(b.id)
    assert a_line =~ a_row.title
    assert a_line =~ "(status: `#{a_row.status}`)"
    assert b_line =~ b_row.title
    assert b_line =~ "(status: `#{b_row.status}`)"

    # Exactly one landed and one unlanded LINE — a constant flag renders two
    # of the same token.
    bullets = bullet_lines(section)
    assert length(bullets) == 2
    assert Enum.count(bullets, &String.contains?(&1, @landed)) == 1
    assert Enum.count(bullets, &String.contains?(&1, @not_landed)) == 1
  end

  defp declared_dep_ids(task) do
    task.id
    |> Tasks.get_task_detail()
    |> Map.get(:dependencies)
    |> List.wrap()
    |> Enum.map(&(Map.get(&1, "task_id") || Map.get(&1, :task_id)))
  end

  defp line_for(section, id) do
    section
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, "`#{id}`")) ||
      flunk("no predecessor line for #{id} in:\n#{section}")
  end

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()
end
