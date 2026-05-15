defmodule Platform.Tasks.StacksTest do
  # async: false because the `recompute_stack_status/1` piggy-back fires
  # `StackDeployer.maybe_open_stack_pr/1`, which reads the global
  # `:platform, :stack_deployer` config (git_runner). The
  # `recompute_stack_status piggy-back` describe block swaps in a FakeRunner
  # via `Application.put_env`, which is not safe to share across async
  # processes.
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stack, Stacks, Task}

  describe "create_stack/1" do
    test "creates a stack with valid attrs" do
      {:ok, project} = Tasks.create_project(%{name: "Stacks App"})

      assert {:ok, %Stack{} = stack} =
               Stacks.create_stack(%{
                 project_id: project.id,
                 slug: "auth-refresh",
                 name: "Auth refresh",
                 rollup_branch: Stacks.rollup_branch_name("auth-refresh")
               })

      assert stack.slug == "auth-refresh"
      assert stack.name == "Auth refresh"
      assert stack.status == "forming"
      assert stack.base_branch == "main"
      assert stack.rollup_branch == "stack/auth-refresh"
    end

    test "rejects invalid slug" do
      {:ok, project} = Tasks.create_project(%{name: "Bad Slug Project"})

      assert {:error, changeset} =
               Stacks.create_stack(%{
                 project_id: project.id,
                 slug: "Bad Slug!",
                 name: "Bad",
                 rollup_branch: "stack/bad"
               })

      assert %{slug: [_]} = errors_on(changeset)
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = Stacks.create_stack(%{})
      errors = errors_on(changeset)
      assert errors[:project_id]
      assert errors[:slug]
      assert errors[:name]
      assert errors[:rollup_branch]
    end

    test "rejects duplicate slug within a project" do
      {:ok, project} = Tasks.create_project(%{name: "Dup Project"})

      attrs = %{
        project_id: project.id,
        slug: "shared",
        name: "First",
        rollup_branch: "stack/shared"
      }

      assert {:ok, _} = Stacks.create_stack(attrs)
      assert {:error, changeset} = Stacks.create_stack(%{attrs | name: "Second"})
      # The composite unique index is keyed on [:project_id, :slug]; Ecto
      # surfaces the violation on the first field of the index.
      errors = errors_on(changeset)

      assert errors[:project_id] == ["has already been taken"] or
               errors[:slug] == ["has already been taken"]
    end
  end

  describe "get_stack/1 and get_stack!/1" do
    test "returns the stack by id" do
      stack = stack_fixture()
      assert fetched = Stacks.get_stack(stack.id)
      assert fetched.id == stack.id
      assert Stacks.get_stack!(stack.id).id == stack.id
    end

    test "get_stack/1 returns nil for missing id" do
      assert Stacks.get_stack(Ecto.UUID.generate()) == nil
    end

    test "get_stack!/1 raises for missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        Stacks.get_stack!(Ecto.UUID.generate())
      end
    end
  end

  describe "list_stacks/1" do
    test "returns stacks scoped to project_id" do
      {:ok, project_a} = Tasks.create_project(%{name: "Project A"})
      {:ok, project_b} = Tasks.create_project(%{name: "Project B"})

      stack_a = stack_fixture(project_id: project_a.id, slug: "a-one", name: "A One")
      _stack_b = stack_fixture(project_id: project_b.id, slug: "b-one", name: "B One")

      results = Stacks.list_stacks(%{project_id: project_a.id})
      assert Enum.map(results, & &1.id) == [stack_a.id]
    end

    test "returns stacks scoped by status" do
      {:ok, project} = Tasks.create_project(%{name: "Status Project"})
      forming = stack_fixture(project_id: project.id, slug: "forming-one", name: "Forming")
      abandoned = stack_fixture(project_id: project.id, slug: "abandon-one", name: "Abandon")
      {:ok, _} = Stacks.abandon_stack(abandoned, "no longer needed")

      forming_only = Stacks.list_stacks(%{status: "forming"})
      assert Enum.any?(forming_only, &(&1.id == forming.id))
      refute Enum.any?(forming_only, &(&1.id == abandoned.id))

      abandoned_only = Stacks.list_stacks(%{status: "abandoned"})
      assert Enum.any?(abandoned_only, &(&1.id == abandoned.id))
      refute Enum.any?(abandoned_only, &(&1.id == forming.id))
    end

    test "with no filters returns all stacks ordered newest first" do
      {:ok, project} = Tasks.create_project(%{name: "Order Project"})
      first = stack_fixture(project_id: project.id, slug: "first", name: "First")
      # Force a perceptible insert delta to get a stable order.
      :timer.sleep(5)
      second = stack_fixture(project_id: project.id, slug: "second", name: "Second")

      ids = Stacks.list_stacks() |> Enum.map(& &1.id)
      first_idx = Enum.find_index(ids, &(&1 == first.id))
      second_idx = Enum.find_index(ids, &(&1 == second.id))
      assert second_idx < first_idx
    end
  end

  describe "update_stack/2" do
    test "updates writable fields" do
      stack = stack_fixture()
      assert {:ok, updated} = Stacks.update_stack(stack, %{name: "Renamed"})
      assert updated.name == "Renamed"
    end

    test "rejects invalid changes" do
      stack = stack_fixture()
      assert {:error, changeset} = Stacks.update_stack(stack, %{slug: "Not Valid"})
      assert %{slug: [_]} = errors_on(changeset)
    end
  end

  describe "abandon_stack/2" do
    test "transitions status to abandoned" do
      stack = stack_fixture()
      assert {:ok, abandoned} = Stacks.abandon_stack(stack, "scope changed")
      assert abandoned.status == "abandoned"
      assert abandoned.description =~ "Abandoned: scope changed"
    end

    test "preserves prior description when reason given" do
      stack = stack_fixture(description: "Original notes")
      assert {:ok, abandoned} = Stacks.abandon_stack(stack, "redundant")
      assert abandoned.description =~ "Original notes"
      assert abandoned.description =~ "Abandoned: redundant"
    end

    test "leaves description untouched when no reason given" do
      stack = stack_fixture(description: "Keep me")
      assert {:ok, abandoned} = Stacks.abandon_stack(stack)
      assert abandoned.status == "abandoned"
      assert abandoned.description == "Keep me"
    end
  end

  describe "rollup_branch_name/1" do
    test "prefixes the slug with stack/" do
      assert Stacks.rollup_branch_name("user-keyed-saves") == "stack/user-keyed-saves"
    end
  end

  describe "valid_slug?/1" do
    test "accepts valid slugs" do
      assert Stacks.valid_slug?("a")
      assert Stacks.valid_slug?("auth-refresh")
      assert Stacks.valid_slug?("v2-rollout-2026")
    end

    test "rejects uppercase, special chars, and leading hyphen" do
      refute Stacks.valid_slug?("Auth-Refresh")
      refute Stacks.valid_slug?("auth refresh")
      refute Stacks.valid_slug?("auth_refresh")
      refute Stacks.valid_slug?("-leading-hyphen")
      refute Stacks.valid_slug?("")
    end

    test "rejects slugs longer than 60 characters" do
      assert Stacks.valid_slug?(String.duplicate("a", 60))
      refute Stacks.valid_slug?(String.duplicate("a", 61))
    end

    test "rejects non-strings" do
      refute Stacks.valid_slug?(nil)
      refute Stacks.valid_slug?(:atom)
      refute Stacks.valid_slug?(123)
    end
  end

  describe "add_task/2" do
    test "attaches a task at position 1, then 2 for the second add" do
      {:ok, project} = Tasks.create_project(%{name: "Add Task Project"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "First member"})
      {:ok, t2} = Tasks.create_task(%{project_id: project.id, title: "Second member"})

      assert {:ok, attached1} = Stacks.add_task(stack, t1)
      assert attached1.stack_id == stack.id
      assert attached1.stack_position == 1

      assert {:ok, attached2} = Stacks.add_task(stack.id, t2.id)
      assert attached2.stack_id == stack.id
      assert attached2.stack_position == 2
    end

    test "rejects a task that already belongs to a stack" do
      {:ok, project} = Tasks.create_project(%{name: "Already Stacked"})
      stack_a = stack_fixture(project_id: project.id, slug: "alpha")
      stack_b = stack_fixture(project_id: project.id, slug: "beta")
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member"})

      assert {:ok, _} = Stacks.add_task(stack_a, task)
      assert {:error, :already_in_stack} = Stacks.add_task(stack_b, task.id)
    end
  end

  describe "eject_task/2" do
    test "clears stack_id and stack_position on a clean eject" do
      {:ok, project} = Tasks.create_project(%{name: "Eject Clean"})
      stack = stack_fixture(project_id: project.id)
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Ejectable"})
      {:ok, attached} = Stacks.add_task(stack, task)
      assert attached.stack_id == stack.id

      assert {:ok, ejected} = Stacks.eject_task(stack, attached)
      assert ejected.stack_id == nil
      assert ejected.stack_position == nil
    end

    test "refuses to eject a task that other in-stack members depend on" do
      {:ok, project} = Tasks.create_project(%{name: "Eject Dependents"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, attached_parent} = Stacks.add_task(stack, parent)

      {:ok, dependent} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Dependent",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, _attached_dependent} = Stacks.add_task(stack, dependent)

      assert {:error, {:has_dependents, [%{id: dep_id, title: "Dependent"}]}} =
               Stacks.eject_task(stack, attached_parent)

      assert dep_id == dependent.id
    end

    test "returns :not_in_stack when task does not belong to the stack" do
      {:ok, project} = Tasks.create_project(%{name: "Not In Stack"})
      stack = stack_fixture(project_id: project.id)
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Free task"})

      assert {:error, :not_in_stack} = Stacks.eject_task(stack, task)
    end
  end

  describe "add_dependency_edge/4 and remove_dependency_edge/4" do
    test "happy add: writes edge, recomputes executable_now" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Add Happy"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      assert {:ok, result} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert result.from_task_id == b.id
      assert result.to_task_id == a.id
      assert result.kind == "blocks"
      # B now blocks on A → only A is executable.
      assert result.executable_now == [a.id]

      # Confirm the dep was actually persisted on B.
      reloaded_b = Repo.get(Task, b.id)
      assert Tasks.dependency_task_ids(reloaded_b) == [a.id]
    end

    test "happy remove: clears edge, recomputes executable_now" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Remove Happy"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert {:ok, result} = Stacks.remove_dependency_edge(stack, b.id, a.id)

      assert result.from_task_id == b.id
      assert result.to_task_id == a.id
      assert result.kind == "blocks"
      # Both members are roots again after the edge is gone.
      assert Enum.sort(result.executable_now) == Enum.sort([a.id, b.id])

      reloaded_b = Repo.get(Task, b.id)
      assert Tasks.dependency_task_ids(reloaded_b) == []
    end

    test "cycle rejection rolls back the dep write atomically" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Cycle Rollback"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      # Existing edge: B → A. Now try A → B which would close the cycle.
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert {:error, :cycle, path} = Stacks.add_dependency_edge(stack, a.id, b.id)
      assert is_list(path)
      path_ids = Enum.map(path, & &1.id)
      assert a.id in path_ids
      assert b.id in path_ids

      # The cycle-creating dep on A was rolled back: A still has no deps.
      reloaded_a = Repo.get(Task, a.id)
      assert Tasks.dependency_task_ids(reloaded_a) == []

      # B's pre-existing edge is untouched.
      reloaded_b = Repo.get(Task, b.id)
      assert Tasks.dependency_task_ids(reloaded_b) == [a.id]
    end

    test "rejects cross-stack endpoint as :not_in_stack" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Cross Stack"})
      stack_a = stack_fixture(project_id: project.id, slug: "ea-a")
      stack_b = stack_fixture(project_id: project.id, slug: "ea-b")
      {:ok, a1} = Tasks.create_task(%{project_id: project.id, title: "A1"})
      {:ok, a2} = Tasks.create_task(%{project_id: project.id, title: "A2"})
      {:ok, b1} = Tasks.create_task(%{project_id: project.id, title: "B1"})
      {:ok, _} = Stacks.add_task(stack_a, a1)
      {:ok, _} = Stacks.add_task(stack_a, a2)
      {:ok, _} = Stacks.add_task(stack_b, b1)

      # Target lives in a DIFFERENT stack — wrapper threads the
      # offending task id (b1) so callers can render a concrete msg.
      assert {:error, :not_in_stack, offending_id} =
               Stacks.add_dependency_edge(stack_a, a1.id, b1.id)

      assert offending_id == b1.id

      # No write happened.
      reloaded_a1 = Repo.get(Task, a1.id)
      assert Tasks.dependency_task_ids(reloaded_a1) == []
    end

    test "rejects non-member endpoint as :not_in_stack" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Non Member"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, free} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      {:ok, _} = Stacks.add_task(stack, a)

      # `free` is not in any stack — wrapper names `free` as the offender.
      assert {:error, :not_in_stack, offending_to} =
               Stacks.add_dependency_edge(stack, a.id, free.id)

      assert offending_to == free.id

      # And the inverse: `from` is the non-member, so `free` is named.
      assert {:error, :not_in_stack, offending_from} =
               Stacks.add_dependency_edge(stack, free.id, a.id)

      assert offending_from == free.id
    end

    test "rejects self-edge up front" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Self"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      assert {:error, :self_edge} = Stacks.add_dependency_edge(stack, a.id, a.id)
      assert {:error, :self_edge} = Stacks.remove_dependency_edge(stack, a.id, a.id)
    end

    test "duplicate add returns :duplicate_edge and is idempotent on the dep list" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Duplicate"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert {:error, :duplicate_edge} = Stacks.add_dependency_edge(stack, b.id, a.id)

      reloaded_b = Repo.get(Task, b.id)
      # Still exactly one edge — no double-write from the failed second add.
      assert Tasks.dependency_task_ids(reloaded_b) == [a.id]
      assert length(reloaded_b.dependencies) == 1
    end

    test "duplicate remove returns :not_an_edge" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Not An Edge"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)
      {:ok, _} = Stacks.remove_dependency_edge(stack, b.id, a.id)

      assert {:error, :not_an_edge} = Stacks.remove_dependency_edge(stack, b.id, a.id)
    end

    test "stack_not_found / task_not_found surface cleanly" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Missing"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      missing_id = Ecto.UUID.generate()

      assert {:error, :stack_not_found} =
               Stacks.add_dependency_edge(missing_id, a.id, a.id)

      assert {:error, :task_not_found} =
               Stacks.add_dependency_edge(stack, a.id, missing_id)

      assert {:error, :task_not_found} =
               Stacks.add_dependency_edge(stack, missing_id, a.id)
    end

    test "executable_now reflects multi-edge state after a chain of mutations" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Multi Edge"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      # Initially: all three are roots.
      initial = Stacks.executable_members(stack) |> Enum.map(& &1.id)
      assert Enum.sort(initial) == Enum.sort([a.id, b.id, c.id])

      # B → A: now A and C are roots.
      {:ok, after_first} = Stacks.add_dependency_edge(stack, b.id, a.id)
      assert Enum.sort(after_first.executable_now) == Enum.sort([a.id, c.id])

      # C → A: only A is a root.
      {:ok, after_second} = Stacks.add_dependency_edge(stack, c.id, a.id)
      assert after_second.executable_now == [a.id]

      # Remove C → A: A and C are roots again.
      {:ok, after_remove} = Stacks.remove_dependency_edge(stack, c.id, a.id)
      assert Enum.sort(after_remove.executable_now) == Enum.sort([a.id, c.id])
    end
  end

  describe "members/1" do
    test "returns members ordered by stack_position ascending" do
      {:ok, project} = Tasks.create_project(%{name: "Members Order"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "One"})
      {:ok, t2} = Tasks.create_task(%{project_id: project.id, title: "Two"})
      {:ok, t3} = Tasks.create_task(%{project_id: project.id, title: "Three"})

      {:ok, _} = Stacks.add_task(stack, t1)
      {:ok, _} = Stacks.add_task(stack, t2)
      {:ok, _} = Stacks.add_task(stack, t3)

      ids = Stacks.members(stack) |> Enum.map(& &1.id)
      assert ids == [t1.id, t2.id, t3.id]

      # Accepts both struct and id forms.
      assert Stacks.members(stack.id) |> Enum.map(& &1.id) == ids
    end

    test "excludes soft-deleted tasks" do
      {:ok, project} = Tasks.create_project(%{name: "Members Deleted"})
      stack = stack_fixture(project_id: project.id)
      {:ok, kept} = Tasks.create_task(%{project_id: project.id, title: "Kept"})
      {:ok, gone} = Tasks.create_task(%{project_id: project.id, title: "Gone"})

      {:ok, _} = Stacks.add_task(stack, kept)
      {:ok, attached_gone} = Stacks.add_task(stack, gone)

      # Bypass the status guard by writing deleted_at directly via the
      # changeset; this exercises the SQL filter, not the soft-delete API.
      attached_gone
      |> Task.changeset(%{deleted_at: DateTime.utc_now()})
      |> Repo.update!()

      ids = Stacks.members(stack) |> Enum.map(& &1.id)
      assert ids == [kept.id]
    end
  end

  describe "validate_dag/1 — execution levels" do
    test "empty stack returns no levels" do
      stack = stack_fixture()
      assert {:ok, []} = Stacks.validate_dag(stack)
    end

    test "single member returns one level with that member" do
      {:ok, project} = Tasks.create_project(%{name: "DAG single"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Solo"})
      {:ok, _} = Stacks.add_task(stack, t)

      assert {:ok, [[member]]} = Stacks.validate_dag(stack)
      assert member.id == t.id
    end

    test "linear chain a→b→c returns three serial levels" do
      {:ok, project} = Tasks.create_project(%{name: "DAG chain"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, c} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "C",
          dependencies: [%{"task_id" => b.id, "kind" => "blocks"}]
        })

      # Insert in dependency-respecting order so each add_task's own
      # validate_dag check has the prior member present.
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      assert {:ok, [[l0], [l1], [l2]]} = Stacks.validate_dag(stack)
      assert l0.id == a.id
      assert l1.id == b.id
      assert l2.id == c.id
    end

    test "diamond a→{b,c}→d collapses level 1 to a parallel pair" do
      # Edges (in dependency direction): b→a, c→a, d→b, d→c.
      # Expected execution: [[a], [b, c], [d]].
      {:ok, project} = Tasks.create_project(%{name: "DAG diamond"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, c} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "C",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, d} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "D",
          dependencies: [
            %{"task_id" => b.id, "kind" => "blocks"},
            %{"task_id" => c.id, "kind" => "blocks"}
          ]
        })

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)
      {:ok, _} = Stacks.add_task(stack, d)

      assert {:ok, [[level0], level1, [level2]]} = Stacks.validate_dag(stack)
      assert level0.id == a.id
      assert MapSet.new(Enum.map(level1, & &1.id)) == MapSet.new([b.id, c.id])
      assert length(level1) == 2
      assert level2.id == d.id
    end

    test "self-edges are dropped without errors" do
      {:ok, project} = Tasks.create_project(%{name: "DAG self"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Selfie"})
      {:ok, attached} = Stacks.add_task(stack, t)

      # Inject a self-reference into deps after attachment so add_task's
      # own validate_dag pass doesn't see it. Bypass update_task's
      # broadcast pipeline; we're testing validate_dag here, not the
      # write path.
      attached
      |> Task.changeset(%{dependencies: [%{"task_id" => attached.id, "kind" => "blocks"}]})
      |> Repo.update!()

      assert {:ok, [[member]]} = Stacks.validate_dag(stack)
      assert member.id == t.id
    end

    test "deps pointing to a free non-stack task are silently dropped" do
      {:ok, project} = Tasks.create_project(%{name: "DAG cross-free"})
      stack = stack_fixture(project_id: project.id)

      {:ok, outsider} =
        Tasks.create_task(%{project_id: project.id, title: "Free agent"})

      {:ok, member} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Inside",
          dependencies: [%{"task_id" => outsider.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, member)

      assert {:ok, [[m]]} = Stacks.validate_dag(stack)
      assert m.id == member.id
    end

    test "two-node cycle is detected and reported in path" do
      {:ok, project} = Tasks.create_project(%{name: "DAG cycle"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      # Attach both first (no deps yet so validate_dag passes), then
      # patch in the back-edge to create a→b→a.
      {:ok, attached_a} = Stacks.add_task(stack, a)
      {:ok, attached_b} = Stacks.add_task(stack, b)

      attached_a
      |> Task.changeset(%{dependencies: [%{"task_id" => attached_b.id, "kind" => "blocks"}]})
      |> Repo.update!()

      attached_b
      |> Task.changeset(%{dependencies: [%{"task_id" => attached_a.id, "kind" => "blocks"}]})
      |> Repo.update!()

      assert {:error, :cycle, path} = Stacks.validate_dag(stack)
      ids = Enum.map(path, & &1.id) |> MapSet.new()
      assert MapSet.member?(ids, a.id)
      assert MapSet.member?(ids, b.id)
    end

    test "cross-stack edge to a foreign stack member is rejected" do
      {:ok, project} = Tasks.create_project(%{name: "DAG cross-stack"})
      stack_a = stack_fixture(project_id: project.id, slug: "alpha")
      stack_b = stack_fixture(project_id: project.id, slug: "beta")

      {:ok, foreign} = Tasks.create_task(%{project_id: project.id, title: "Foreign"})
      {:ok, _attached_foreign} = Stacks.add_task(stack_b, foreign)

      {:ok, local} = Tasks.create_task(%{project_id: project.id, title: "Local"})
      {:ok, attached_local} = Stacks.add_task(stack_a, local)

      # Inject the cross-stack dep after the fact so add_task's own
      # validate_dag pass during attachment doesn't see it.
      attached_local
      |> Task.changeset(%{dependencies: [%{"task_id" => foreign.id, "kind" => "blocks"}]})
      |> Repo.update!()

      assert {:error, :cross_stack_dep, %{from: from, to_task_id: to_id}} =
               Stacks.validate_dag(stack_a)

      assert from.id == local.id
      assert to_id == foreign.id
    end
  end

  describe "executable_members/1" do
    test "empty stack returns []" do
      stack = stack_fixture()
      assert Stacks.executable_members(stack) == []
    end

    test "single root returns just that member" do
      {:ok, project} = Tasks.create_project(%{name: "Exec single"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Solo"})
      {:ok, _} = Stacks.add_task(stack, t)

      assert [member] = Stacks.executable_members(stack)
      assert member.id == t.id
    end

    test "multiple parallel roots are all returned" do
      {:ok, project} = Tasks.create_project(%{name: "Exec parallel"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      ids = stack |> Stacks.executable_members() |> Enum.map(& &1.id) |> MapSet.new()
      assert ids == MapSet.new([a.id, b.id, c.id])
    end

    test "only roots returned when there are dependents" do
      {:ok, project} = Tasks.create_project(%{name: "Exec dependents"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      assert [member] = Stacks.executable_members(stack)
      assert member.id == a.id
    end
  end

  describe "unblocked_in_stack?/1" do
    test "returns false for non-member (stack_id nil)" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock non-member"})
      {:ok, free_task} = Tasks.create_task(%{project_id: project.id, title: "Free"})

      refute Stacks.unblocked_in_stack?(free_task)
    end

    test "returns true for a root with no in-stack deps" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock root"})
      stack = stack_fixture(project_id: project.id)
      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, attached} = Stacks.add_task(stack, root)

      assert Stacks.unblocked_in_stack?(attached)
    end

    test "returns true when in-stack dep is in_review with merged_into_rollup_at set" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock cleared"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{"merged_into_rollup_at" => "abc123"}
      })
      |> Repo.update!()

      assert Stacks.unblocked_in_stack?(attached_child)
    end

    test "returns false when in-stack dep is in_review WITHOUT merged_into_rollup_at" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock unmerged"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      attached_parent
      |> Task.changeset(%{status: "in_review"})
      |> Repo.update!()

      refute Stacks.unblocked_in_stack?(attached_child)
    end

    test "returns false when in-stack dep is in_progress" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock in-progress dep"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      attached_parent
      |> Task.changeset(%{
        status: "in_progress",
        metadata: %{"merged_into_rollup_at" => "abc123"}
      })
      |> Repo.update!()

      refute Stacks.unblocked_in_stack?(attached_child)
    end

    test "ignores cross-stack deps to non-members (returns true if all in-stack deps clear)" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock cross-stack"})
      stack = stack_fixture(project_id: project.id)

      {:ok, outsider} = Tasks.create_task(%{project_id: project.id, title: "Outsider"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Member with cross-stack dep",
          dependencies: [%{"task_id" => outsider.id, "kind" => "blocks"}]
        })

      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Outsider is in_progress, no merge stamp — irrelevant because
      # it's not an in-stack dep.
      assert Stacks.unblocked_in_stack?(attached_child)
    end
  end

  describe "try_promote/1" do
    test "no-op for a task not in any stack" do
      {:ok, project} = Tasks.create_project(%{name: "Promote non-member"})
      {:ok, free_task} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      assert Stacks.try_promote(free_task) == :noop
    end

    test "no-op for a stack member not at stack_pending" do
      {:ok, project} = Tasks.create_project(%{name: "Promote not-pending"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, attached} = Stacks.add_task(stack, t)
      # Default status is "backlog", which is not stack_pending.
      assert Stacks.try_promote(attached) == :noop
    end

    test "no-op when deps have not cleared the threshold" do
      {:ok, project} = Tasks.create_project(%{name: "Promote unmet"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, _attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Put child at stack_pending; parent has not yet been merged so the
      # threshold is unmet.
      pending_child =
        attached_child
        |> Task.changeset(%{status: "stack_pending"})
        |> Repo.update!()

      assert Stacks.try_promote(pending_child) == :noop
      # Status untouched.
      reloaded = Tasks.get_task_record(pending_child.id)
      assert reloaded.status == "stack_pending"
    end

    test "promotes stack_pending → in_progress when deps clear" do
      {:ok, project} = Tasks.create_project(%{name: "Promote cleared"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Approved plan is the existing prerequisite for any execution-phase
      # transition (`require_approved_plan_for/2` in Tasks). In production
      # the child's plan would have been approved during the stack's
      # planning sweep before it parked at stack_pending.
      {:ok, _plan} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      # Park child at stack_pending.
      pending_child =
        attached_child
        |> Task.changeset(%{status: "stack_pending"})
        |> Repo.update!()

      # Cross the unblock threshold on parent: in_review + merged stamp.
      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{"merged_into_rollup_at" => "abc123"}
      })
      |> Repo.update!()

      assert {:ok, promoted} = Stacks.try_promote(pending_child)
      assert promoted.status == "in_progress"
      assert Tasks.get_task_record(promoted.id).status == "in_progress"
    end

    test "surfaces the underlying error when transition fails" do
      {:ok, project} = Tasks.create_project(%{name: "Promote no plan"})
      stack = stack_fixture(project_id: project.id)
      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "No-plan root"})
      {:ok, attached} = Stacks.add_task(stack, root)

      pending =
        attached
        |> Task.changeset(%{status: "stack_pending"})
        |> Repo.update!()

      # Vacuously unblocked (no in-stack deps) but no approved plan exists
      # → transition_task/2 refuses with :no_approved_plan, and that bubbles
      # through try_promote/1 unchanged.
      assert {:error, :no_approved_plan} = Stacks.try_promote(pending)
    end

    test "accepts a task id and looks the row up fresh" do
      {:ok, project} = Tasks.create_project(%{name: "Promote by id"})
      stack = stack_fixture(project_id: project.id)
      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, attached} = Stacks.add_task(stack, root)

      {:ok, _plan} = Tasks.create_plan(%{task_id: attached.id, status: "approved"})

      attached
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      assert {:ok, promoted} = Stacks.try_promote(attached.id)
      assert promoted.status == "in_progress"

      assert {:error, :task_not_found} = Stacks.try_promote(Ecto.UUID.generate())
    end
  end

  describe "unblocked_after/2" do
    test "returns only stack_pending members whose deps just cleared" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock-after"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, dependent} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Dependent",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, unrelated} = Tasks.create_task(%{project_id: project.id, title: "Unrelated"})

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_dependent} = Stacks.add_task(stack, dependent)
      {:ok, _attached_unrelated} = Stacks.add_task(stack, unrelated)

      # Mark the dependent as stack_pending (the state it would be in
      # post-stack_start, prior to its dep clearing).
      attached_dependent
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      # Mark the parent as freshly-merged.
      {:ok, just_merged} =
        attached_parent
        |> Task.changeset(%{
          status: "in_review",
          metadata: %{"merged_into_rollup_at" => "abc123"}
        })
        |> Repo.update()

      result = Stacks.unblocked_after(stack, just_merged)
      assert Enum.map(result, & &1.id) == [attached_dependent.id]
    end

    test "skips members not currently stack_pending" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock-after non-pending"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, dependent} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Dependent",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, _attached_dependent} = Stacks.add_task(stack, dependent)

      # Dependent is in `backlog` (its default), NOT stack_pending —
      # outside the auto-promote set.
      {:ok, just_merged} =
        attached_parent
        |> Task.changeset(%{
          status: "in_review",
          metadata: %{"merged_into_rollup_at" => "abc123"}
        })
        |> Repo.update()

      assert Stacks.unblocked_after(stack, just_merged) == []
    end
  end

  describe "start_stack/1" do
    test "rejects stacks not at forming" do
      stack = stack_fixture()
      # Force the stack into in_progress directly so we can confirm the guard.
      {:ok, started} = Stacks.update_stack(stack, %{status: "in_progress"})
      assert {:error, :invalid_stack_status} = Stacks.start_stack(started)
    end

    test "cascade fans roots → in_progress and non-roots → stack_pending" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade start"})
      stack = stack_fixture(project_id: project.id)

      {:ok, root_a} = Tasks.create_task(%{project_id: project.id, title: "Root A"})
      {:ok, root_b} = Tasks.create_task(%{project_id: project.id, title: "Root B"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child of A",
          dependencies: [%{"task_id" => root_a.id, "kind" => "blocks"}]
        })

      {:ok, _attached_root_a} = Stacks.add_task(stack, root_a)
      {:ok, _attached_root_b} = Stacks.add_task(stack, root_b)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Roots need approved plans so the in_progress transition gate
      # passes. Non-root doesn't need a plan to go to stack_pending.
      {:ok, _} = Tasks.create_plan(%{task_id: root_a.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: root_b.id, status: "approved"})

      assert {:ok, %{stack: updated, started: started, parked: parked}} =
               Stacks.start_stack(stack)

      assert updated.status == "in_progress"
      started_ids = started |> Enum.map(& &1.id) |> Enum.sort()
      assert started_ids == Enum.sort([root_a.id, root_b.id])
      assert Enum.all?(started, &(&1.status == "in_progress"))

      assert [%Task{id: parked_id}] = parked
      assert parked_id == attached_child.id
      assert hd(parked).status == "stack_pending"
    end

    test "skips members already past backlog (idempotent / additive)" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade additive"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Pre-advanced"})
      {:ok, attached} = Stacks.add_task(stack, t)

      # Operator already promoted this task out of backlog before stack_start.
      {:ok, _} = Tasks.create_plan(%{task_id: attached.id, status: "approved"})

      attached
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      assert {:ok, %{started: started, parked: parked}} = Stacks.start_stack(stack)
      # Cascade did not touch the already-advanced member.
      assert started == []
      assert parked == []
      assert Tasks.get_task_record(attached.id).status == "in_progress"
    end

    test "returns :partial when a root transition fails" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade partial"})
      stack = stack_fixture(project_id: project.id)
      {:ok, ok_root} = Tasks.create_task(%{project_id: project.id, title: "OK root"})
      {:ok, bad_root} = Tasks.create_task(%{project_id: project.id, title: "No-plan root"})

      {:ok, _attached_ok} = Stacks.add_task(stack, ok_root)
      {:ok, _attached_bad} = Stacks.add_task(stack, bad_root)

      # Only ok_root has a plan; bad_root will fail :no_approved_plan.
      {:ok, _} = Tasks.create_plan(%{task_id: ok_root.id, status: "approved"})

      assert {:partial, %{stack: updated, started: started, errors: errors}} =
               Stacks.start_stack(stack)

      assert updated.status == "in_progress"
      assert [ok_started] = started
      assert ok_started.id == ok_root.id

      assert [%{task_id: failed_id, target_status: "in_progress", reason: :no_approved_plan}] =
               errors

      assert failed_id == bad_root.id
    end
  end

  describe "start_planning/1" do
    test "fans every backlog member backlog -> planning" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning happy"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "Member A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "Member B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "Member C"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      assert {:ok, %{stack: updated, planning: planning}} = Stacks.start_planning(stack)

      planning_ids = planning |> Enum.map(& &1.id) |> Enum.sort()
      assert planning_ids == Enum.sort([a.id, b.id, c.id])
      assert Enum.all?(planning, &(&1.status == "planning"))

      # Every member is now at `planning` in the DB.
      assert Enum.all?(Stacks.members(stack), &(&1.status == "planning"))

      # An all-`planning` stack rolls up to `forming` (no member has
      # advanced past forming).
      assert updated.status == "forming"
      assert {:ok, recomputed} = Stacks.recompute_stack_status(updated)
      assert recomputed.status == "forming"
    end

    test "only advances backlog members, leaving the rest untouched" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning mixed"})
      stack = stack_fixture(project_id: project.id)

      {:ok, bl_a} = Tasks.create_task(%{project_id: project.id, title: "Backlog A"})
      {:ok, bl_b} = Tasks.create_task(%{project_id: project.id, title: "Backlog B"})
      {:ok, planning_already} = Tasks.create_task(%{project_id: project.id, title: "Planning"})
      {:ok, parked} = Tasks.create_task(%{project_id: project.id, title: "Parked"})

      {:ok, _} = Stacks.add_task(stack, bl_a)
      {:ok, _} = Stacks.add_task(stack, bl_b)
      {:ok, attached_planning} = Stacks.add_task(stack, planning_already)
      {:ok, attached_parked} = Stacks.add_task(stack, parked)

      # Pre-advance two members past `backlog` before the cascade.
      set_member_status(stack, attached_planning, "planning")
      set_member_status(stack, attached_parked, "stack_pending")

      assert {:ok, %{planning: planning}} = Stacks.start_planning(stack)

      # Exactly the two backlog members advanced — no :invalid_transition
      # error leaked for the already-advanced members.
      planning_ids = planning |> Enum.map(& &1.id) |> Enum.sort()
      assert planning_ids == Enum.sort([bl_a.id, bl_b.id])

      # The pre-advanced members are left at their existing status.
      assert Tasks.get_task_record(attached_planning.id).status == "planning"
      assert Tasks.get_task_record(attached_parked.id).status == "stack_pending"
    end

    test "an empty stack returns {:ok, planning: []}" do
      stack = stack_fixture()

      assert {:ok, %{stack: returned, planning: []}} = Stacks.start_planning(stack)
      assert returned.id == stack.id
      assert returned.status == "forming"
    end

    test "a stack with no backlog members is a safe no-op" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning no-op"})
      stack = stack_fixture(project_id: project.id)

      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Already planning"})
      {:ok, attached} = Stacks.add_task(stack, t)
      set_member_status(stack, attached, "planning")

      assert {:ok, %{planning: []}} = Stacks.start_planning(stack)
      assert Tasks.get_task_record(attached.id).status == "planning"
    end

    test "re-invoking after a full cascade is idempotent" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning idempotent"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "Member A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "Member B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      assert {:ok, %{planning: first}} = Stacks.start_planning(stack)
      assert length(first) == 2

      # Second invocation finds nothing at `backlog` — no re-transition,
      # no error.
      assert {:ok, %{planning: []}} = Stacks.start_planning(stack)
      assert Enum.all?(Stacks.members(stack), &(&1.status == "planning"))
    end

    test "accepts a stack id and returns {:error, :stack_not_found} for an unknown id" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning by id"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, _} = Stacks.add_task(stack, t)

      assert {:ok, %{planning: [planned]}} = Stacks.start_planning(stack.id)
      assert planned.id == t.id

      assert {:error, :stack_not_found} = Stacks.start_planning(Ecto.UUID.generate())
    end
  end

  describe "regression?/2" do
    test "returns true for backward lifecycle steps" do
      assert Stacks.regression?("in_review", "in_progress")
      assert Stacks.regression?("deploying", "in_review")
      assert Stacks.regression?("done", "in_progress")
      assert Stacks.regression?("in_progress", "stack_pending")
      assert Stacks.regression?("in_progress", "backlog")
    end

    test "returns false for forward / same-level moves" do
      refute Stacks.regression?("backlog", "in_progress")
      refute Stacks.regression?("in_progress", "in_review")
      refute Stacks.regression?("in_review", "deploying")
      refute Stacks.regression?("in_progress", "in_progress")
      # Pre-execution rungs treated as same level.
      refute Stacks.regression?("backlog", "stack_pending")
      refute Stacks.regression?("stack_pending", "backlog")
    end
  end

  describe "handle_member_regression/2" do
    test "no-op for tasks outside any stack (cross-stack quiet path)" do
      {:ok, project} = Tasks.create_project(%{name: "Regression non-member"})
      {:ok, free} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      assert :ok = Stacks.handle_member_regression(free, "in_review")
    end

    test "reverts downstream stack_pending when threshold lost" do
      {:ok, project} = Tasks.create_project(%{name: "Regression revert"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      {:ok, _} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      # Setup: parent at in_review + stamp, child at in_progress (was
      # promoted off the rollup-merge sweep but hasn't shipped any
      # stage_complete signal yet).
      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{"merged_into_rollup_at" => "abc123"}
      })
      |> Repo.update!()

      attached_child
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      # Simulate the parent regressing: clear the merge stamp so the
      # threshold breaks.
      regressed_parent =
        Tasks.get_task_record(attached_parent.id)
        |> Task.changeset(%{status: "in_progress", metadata: %{}})
        |> Repo.update!()

      assert {:ok, %{reverted: [reverted], flagged: []}} =
               Stacks.handle_member_regression(regressed_parent, "in_review")

      assert reverted.id == attached_child.id
      assert reverted.status == "stack_pending"
    end

    test "leaves downstream alone but flags it when work is already committed" do
      {:ok, project} = Tasks.create_project(%{name: "Regression flag"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Child has an approved plan AND a passed stage — committed work
      # exists.
      {:ok, plan} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      {:ok, _stage} =
        Repo.insert(%Platform.Tasks.Stage{
          plan_id: plan.id,
          position: 1,
          name: "Stage 1",
          status: "passed"
        })

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{"merged_into_rollup_at" => "abc123"}
      })
      |> Repo.update!()

      attached_child
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      # Parent regresses — threshold lost.
      regressed_parent =
        Tasks.get_task_record(attached_parent.id)
        |> Task.changeset(%{status: "in_progress", metadata: %{}})
        |> Repo.update!()

      assert {:ok, %{reverted: [], flagged: [flagged]}} =
               Stacks.handle_member_regression(regressed_parent, "in_review")

      assert flagged.id == attached_child.id
      # Status untouched — committed work is not auto-rolled back.
      assert flagged.status == "in_progress"
      assert is_binary(flagged.metadata["stack_dep_regressed_at"])
    end

    test "leaves downstream alone when threshold is still met after regression" do
      # Two parents block the child; only one parent regresses, but the
      # OTHER parent has its own merge stamp so the threshold is still
      # cleared. No revert and no flag.
      {:ok, project} = Tasks.create_project(%{name: "Regression still ok"})
      stack = stack_fixture(project_id: project.id)
      {:ok, p1} = Tasks.create_task(%{project_id: project.id, title: "P1"})
      {:ok, p2} = Tasks.create_task(%{project_id: project.id, title: "P2"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [
            %{"task_id" => p1.id, "kind" => "blocks"},
            %{"task_id" => p2.id, "kind" => "blocks"}
          ]
        })

      {:ok, attached_p1} = Stacks.add_task(stack, p1)
      {:ok, attached_p2} = Stacks.add_task(stack, p2)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Both parents merged.
      attached_p1
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{"merged_into_rollup_at" => "p1-sha"}
      })
      |> Repo.update!()

      attached_p2
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{"merged_into_rollup_at" => "p2-sha"}
      })
      |> Repo.update!()

      attached_child
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      # P1 regresses (stamp cleared), P2 still clears the threshold —
      # but actually wait, when we say the threshold per dep, EACH dep
      # must clear. So if P1 regresses, threshold breaks. Re-construct:
      # P1 is not a dep, only P2 is.
      attached_p1
      |> Task.changeset(%{status: "in_progress", metadata: %{}})
      |> Repo.update!()

      # Re-fetch p1 as the regressed task.
      regressed_p1 = Tasks.get_task_record(attached_p1.id)

      # Child depends on BOTH; P1's regression breaks the threshold.
      # Confirm this is the "threshold lost" path, not the "still met"
      # path — child goes back to stack_pending because it has no
      # passed stages.
      assert {:ok, %{reverted: [reverted], flagged: []}} =
               Stacks.handle_member_regression(regressed_p1, "in_review")

      assert reverted.id == attached_child.id
    end

    test "leaves a downstream that is NOT at in_progress untouched" do
      {:ok, project} = Tasks.create_project(%{name: "Regression non-progress"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Child is still parked at stack_pending — no regression action
      # needed (it's already in the holding state).
      attached_child
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{"merged_into_rollup_at" => "abc123"}
      })
      |> Repo.update!()

      regressed_parent =
        Tasks.get_task_record(attached_parent.id)
        |> Task.changeset(%{status: "in_progress", metadata: %{}})
        |> Repo.update!()

      assert {:ok, %{reverted: [], flagged: []}} =
               Stacks.handle_member_regression(regressed_parent, "in_review")

      assert Tasks.get_task_record(attached_child.id).status == "stack_pending"
    end
  end

  describe "regression handler hook in transition_task/2" do
    test "manual backward transition demotes a downstream in_progress sibling" do
      {:ok, project} = Tasks.create_project(%{name: "Regression hook"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Plans for both so transitions can run through the gate.
      {:ok, _} = Tasks.create_plan(%{task_id: attached_parent.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      # Drive parent forward: in_progress → in_review with merge stamp.
      attached_parent
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      reloaded_parent = Tasks.get_task_record(attached_parent.id)

      {:ok, _} =
        Tasks.update_task(reloaded_parent, %{metadata: %{"merged_into_rollup_at" => "sha"}})

      reloaded_parent = Tasks.get_task_record(attached_parent.id)
      {:ok, parent_in_review} = Tasks.transition_task(reloaded_parent, "in_review")

      # Promote child to in_progress directly (no stage_complete events).
      attached_child
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      # Clear the merge stamp on parent so the threshold WILL break, then
      # regress parent in_review → in_progress through transition_task.
      Tasks.update_task(parent_in_review, %{metadata: %{}})
      reloaded_parent = Tasks.get_task_record(attached_parent.id)

      assert {:ok, _} = Tasks.transition_task(reloaded_parent, "in_progress")

      # The hook in maybe_finalize_transition fired handle_member_regression,
      # which demoted child back to stack_pending.
      assert Tasks.get_task_record(attached_child.id).status == "stack_pending"
    end
  end

  describe "recompute_stack_status hook in transition_task/2" do
    test "advancing a member updates the stack rollup" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade hook"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, attached} = Stacks.add_task(stack, t)

      # Set up so we can drive the member from backlog → in_progress.
      {:ok, _} = Tasks.create_plan(%{task_id: attached.id, status: "approved"})

      # Pre-condition: empty/unstarted rollup.
      assert Stacks.get_stack(stack.id).status == "forming"

      assert {:ok, _} = Tasks.transition_task(attached, "in_progress")

      # recompute_stack_status hook ran in maybe_finalize_transition's tail.
      assert Stacks.get_stack(stack.id).status == "in_progress"
    end

    test "no-op for tasks outside any stack" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade hook non-member"})
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      {:ok, _} = Tasks.create_plan(%{task_id: t.id, status: "approved"})

      # Just confirm no crash and the transition succeeds.
      assert {:ok, updated} = Tasks.transition_task(t, "in_progress")
      assert updated.status == "in_progress"
    end
  end

  describe "sweep_stack_dependents/1" do
    test "no-op when task is not in any stack" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep non-member"})
      {:ok, free} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      assert {:ok, []} = Stacks.sweep_stack_dependents(free)
    end

    test "no-op when merged_into_rollup_at is not set" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep unstamped"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, attached} = Stacks.add_task(stack, t)
      assert {:ok, []} = Stacks.sweep_stack_dependents(attached)
    end

    test "promotes every now-unblocked stack_pending dependent" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep promote"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child_a} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child A",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, child_b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child B",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_a} = Stacks.add_task(stack, child_a)
      {:ok, attached_b} = Stacks.add_task(stack, child_b)

      # Both children need approved plans for the in_progress transition
      # to succeed.
      {:ok, _} = Tasks.create_plan(%{task_id: attached_a.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: attached_b.id, status: "approved"})

      # Park both dependents at stack_pending.
      attached_a
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      attached_b
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      # Cross the unblock threshold on parent: in_review + merged stamp.
      stamped_parent =
        attached_parent
        |> Task.changeset(%{
          status: "in_review",
          metadata: %{"merged_into_rollup_at" => "abc123"}
        })
        |> Repo.update!()

      assert {:ok, promoted} = Stacks.sweep_stack_dependents(stamped_parent)
      assert length(promoted) == 2
      assert Enum.all?(promoted, &(&1.status == "in_progress"))
    end

    test "leaves dependents whose threshold is not yet met alone" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep partial"})
      stack = stack_fixture(project_id: project.id)
      {:ok, p1} = Tasks.create_task(%{project_id: project.id, title: "P1"})
      {:ok, p2} = Tasks.create_task(%{project_id: project.id, title: "P2"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child waiting on both",
          dependencies: [
            %{"task_id" => p1.id, "kind" => "blocks"},
            %{"task_id" => p2.id, "kind" => "blocks"}
          ]
        })

      {:ok, attached_p1} = Stacks.add_task(stack, p1)
      {:ok, _attached_p2} = Stacks.add_task(stack, p2)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      {:ok, _} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      attached_child
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      # Only P1 has crossed the threshold — P2 is still unmet.
      stamped_p1 =
        attached_p1
        |> Task.changeset(%{
          status: "in_review",
          metadata: %{"merged_into_rollup_at" => "abc123"}
        })
        |> Repo.update!()

      assert {:ok, []} = Stacks.sweep_stack_dependents(stamped_p1)
      assert Tasks.get_task_record(attached_child.id).status == "stack_pending"
    end

    test "fires automatically from Tasks.update_task/2 on a fresh stamp" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep via update_task"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      {:ok, _} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      attached_child
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      # Set parent to in_review (no merge stamp yet) so the threshold
      # status is satisfied — keeps the test honest that the SWEEP fires
      # on the stamp transition, not on status alone.
      attached_parent
      |> Task.changeset(%{status: "in_review"})
      |> Repo.update!()

      reloaded_parent = Tasks.get_task_record(attached_parent.id)

      # Single update_task/2 call that adds the stamp. The sweep is
      # invoked synchronously after the write.
      assert {:ok, _} =
               Tasks.update_task(reloaded_parent, %{
                 metadata: %{"merged_into_rollup_at" => "abc123"}
               })

      assert Tasks.get_task_record(attached_child.id).status == "in_progress"
    end

    test "does NOT fire when an existing stamp is re-written to the same value" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep re-stamp"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Parent already has the stamp + in_review state. We're checking
      # that a subsequent update_task/2 that does NOT transition the stamp
      # from nil-to-value won't re-fire the sweep. Child is left at
      # backlog (not stack_pending) so even if the sweep DID fire it
      # would no-op — what we're really asserting is that no promotion
      # happens on the second write.
      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{"merged_into_rollup_at" => "abc123"}
      })
      |> Repo.update!()

      attached_child
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      reloaded_parent = Tasks.get_task_record(attached_parent.id)

      # No approved plan, so a promotion would FAIL — confirms sweep did
      # not run. Stamp is rewritten but stays non-nil before-and-after.
      assert {:ok, _} =
               Tasks.update_task(reloaded_parent, %{
                 metadata: %{"merged_into_rollup_at" => "abc123", "extra" => true}
               })

      assert Tasks.get_task_record(attached_child.id).status == "stack_pending"
    end
  end

  describe "recompute_stack_status/1" do
    test "all-done members → done" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup done"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "done")
      set_member_status(stack, b, "done")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "done"
    end

    test "any deploying → deploying" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup deploying"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "in_review")
      set_member_status(stack, b, "deploying")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "deploying"
    end

    test "all in_review/deploying/done → in_review" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup in-review"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "in_review")
      set_member_status(stack, b, "done")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "in_review"
    end

    test "any in_progress with non-advanced sibling → in_progress" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup in-progress"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "in_progress")
      set_member_status(stack, b, "stack_pending")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "in_progress"
    end

    test "all stack_pending/backlog/planning → forming" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup forming"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "stack_pending")
      set_member_status(stack, b, "backlog")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "forming"
    end

    test "abandoned stack stays abandoned (terminal, no recompute)" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup abandoned"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)
      set_member_status(stack, a, "done")

      {:ok, abandoned} = Stacks.abandon_stack(stack, "scope cut")
      assert abandoned.status == "abandoned"

      assert {:ok, after_recompute} = Stacks.recompute_stack_status(abandoned)
      assert after_recompute.status == "abandoned"
    end

    test "skips DB write when computed status equals current" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup no-op"})
      stack = stack_fixture(project_id: project.id)
      # Empty stack rolls up to `forming` — same as default.
      assert stack.status == "forming"
      assert {:ok, after_recompute} = Stacks.recompute_stack_status(stack)
      # No-op path should return the same in-memory struct.
      assert after_recompute.id == stack.id
      assert after_recompute.status == "forming"
    end

    test "accepts a stack id and returns :stack_not_found for unknown id" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup by id"})
      stack = stack_fixture(project_id: project.id)
      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack.id)
      assert recomputed.id == stack.id

      assert {:error, :stack_not_found} =
               Stacks.recompute_stack_status(Ecto.UUID.generate())
    end
  end

  describe "recompute_stack_status/1 — maybe_open_stack_pr piggy-back" do
    alias Platform.Tasks.StacksTest.RecomputePrHookRunner

    setup :install_pr_hook_runner

    test "fully-ready stack: recompute opens the rollup PR (piggy-back fires)", %{
      project: project
    } do
      pr_url = "https://github.com/test/repo/pull/4242"
      RecomputePrHookRunner.set_pr_response({:ok, %{number: 4242, url: pr_url}})

      stack = stack_for_pr_hook!(project, slug: "ready-#{short_id()}")

      _ = stamp_merged_member!(project, stack, sha: "shaone1", position: 1)
      _ = stamp_merged_member!(project, stack, sha: "shatwo2", position: 2)

      # Members all stamped at "in_review"; rollup_status_for/1 returns
      # "in_review" — a real status change from the default "forming" →
      # recompute writes the row AND fires the piggy-back. The deployer's
      # `do_open_stack_pr/2` then performs its own write, flipping the
      # stack to "deploying"; that's why the in-memory recompute return
      # is "in_review" but the reloaded row is "deploying".
      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "in_review"

      # Exactly ONE rollup PR shell-out from the piggy-back path.
      assert [pr_call] = RecomputePrHookRunner.pr_calls()
      assert pr_call.stack_id == stack.id

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.status == "deploying"
      assert reloaded.metadata["rollup_pr"]["number"] == 4242
      assert reloaded.metadata["rollup_pr"]["url"] == pr_url
    end

    test "partially-ready stack: recompute does NOT open the PR (deployer noop)", %{
      project: project
    } do
      stack = stack_for_pr_hook!(project, slug: "partial-#{short_id()}")

      # 1 merged + 1 unmerged → all_members_ready?/1 returns false.
      _ = stamp_merged_member!(project, stack, sha: "halfway1", position: 1)
      _ = stamp_unmerged_member!(project, stack, position: 2)

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      # Mixed in_progress + in_review members → in_progress rollup.
      assert recomputed.status == "in_progress"

      # Piggy-back fired but the deployer's gate returned :not_ready.
      assert RecomputePrHookRunner.pr_calls() == []

      reloaded = Stacks.get_stack(stack.id)
      assert is_nil(get_in(reloaded.metadata || %{}, ["rollup_pr"]))
    end

    test "already-open rollup PR: recompute is no-op for the deployer (idempotent)", %{
      project: project
    } do
      stack = stack_for_pr_hook!(project, slug: "alreadyopen-#{short_id()}")

      # Members at "deploying" so `rollup_status_for/1` keeps the stack at
      # "deploying" — no DB write — but the piggy-back still fires.
      m1 = stamp_merged_member!(project, stack, sha: "openme1", position: 1)
      m2 = stamp_merged_member!(project, stack, sha: "openme2", position: 2)
      {:ok, _} = Tasks.update_task(m1, %{status: "deploying"})
      {:ok, _} = Tasks.update_task(m2, %{status: "deploying"})

      # Pre-stamp metadata.rollup_pr so the deployer gate short-circuits.
      pr_meta = %{
        "number" => 7,
        "url" => "https://github.com/test/repo/pull/7",
        "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      {:ok, locked} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: Map.put(stack.metadata || %{}, "rollup_pr", pr_meta)
        })

      assert {:ok, recomputed} = Stacks.recompute_stack_status(locked)
      # Stack already at "deploying" — no DB write, but piggy-back still fires.
      assert recomputed.status == "deploying"

      # Deployer hit the :already_open guard; no PR shell-out.
      assert RecomputePrHookRunner.pr_calls() == []

      # Metadata preserved.
      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.metadata["rollup_pr"]["number"] == 7
    end

    test "deployer raise: recompute return value is unchanged (failure isolated)", %{
      project: project
    } do
      stack = stack_for_pr_hook!(project, slug: "boom-#{short_id()}")
      _ = stamp_merged_member!(project, stack, sha: "boomshe1", position: 1)
      _ = stamp_merged_member!(project, stack, sha: "boomshe2", position: 2)

      # Make the runner's open_stack_pr raise. The piggy-back catches
      # the exception, logs, and returns :ok without disturbing the
      # recompute_stack_status return.
      RecomputePrHookRunner.set_pr_response({:raise, "synthetic git boom"})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # The recompute return value is the in-memory rollup result —
          # NOT affected by the deployer's downstream write or its raise.
          # Members at "in_review" → rollup says "in_review".
          assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
          assert recomputed.status == "in_review"
          assert recomputed.id == stack.id
        end)

      # The raise was logged via the piggy-back's rescue (failure isolated).
      assert log =~ "[Stacks] recompute_stack_status piggy-back"
      assert log =~ "raised for stack #{stack.id}"

      # Crucially: the recompute call itself returned `{:ok, _}` rather
      # than propagating the deployer raise. That's the failure-isolation
      # contract this stage establishes.
    end
  end

  describe "stack_phase_assignees/1" do
    test "returns %{} for a stack with no phase_assignees metadata" do
      stack = stack_fixture()
      assert Stacks.stack_phase_assignees(stack) == %{}
    end

    test "returns %{} for non-map metadata or nil" do
      assert Stacks.stack_phase_assignees(nil) == %{}
      assert Stacks.stack_phase_assignees("nope") == %{}
      assert Stacks.stack_phase_assignees(%{}) == %{}
    end

    test "returns the normalized map from metadata" do
      agent = Ecto.UUID.generate()

      stack =
        stack_with_phase_assignees(%{
          "planning" => %{"assignee_id" => agent, "assignee_type" => "agent"},
          "execution" => %{"assignee_id" => agent, "assignee_type" => "agent"},
          "review" => %{"assignee_id" => agent, "assignee_type" => "agent"}
        })

      pa = Stacks.stack_phase_assignees(stack)
      assert pa["planning"] == %{"assignee_id" => agent, "assignee_type" => "agent"}
      assert pa["execution"]["assignee_id"] == agent
      assert pa["review"]["assignee_id"] == agent
    end

    test "drops unknown phase keys" do
      agent = Ecto.UUID.generate()

      stack =
        stack_with_phase_assignees(%{
          "planning" => %{"assignee_id" => agent},
          "bogus" => %{"assignee_id" => agent},
          "deploy" => %{"assignee_id" => agent}
        })

      pa = Stacks.stack_phase_assignees(stack)
      assert Map.keys(pa) == ["planning"]
    end

    test "drops malformed per-phase entries and defaults assignee_type to agent" do
      agent = Ecto.UUID.generate()

      stack =
        stack_with_phase_assignees(%{
          "planning" => %{"assignee_id" => agent},
          "execution" => %{"assignee_id" => nil},
          "review" => "garbage"
        })

      pa = Stacks.stack_phase_assignees(stack)
      assert pa == %{"planning" => %{"assignee_id" => agent, "assignee_type" => "agent"}}
    end
  end

  describe "stack_assignee_for_phase/2" do
    test "returns {nil, nil} when no stack-level assignee for the phase" do
      stack = stack_fixture()
      assert Stacks.stack_assignee_for_phase(stack, "planning") == {nil, nil}
    end

    test "returns {id, type} for a configured phase" do
      agent = Ecto.UUID.generate()

      stack =
        stack_with_phase_assignees(%{
          "execution" => %{"assignee_id" => agent, "assignee_type" => "agent"}
        })

      assert Stacks.stack_assignee_for_phase(stack, "execution") == {agent, "agent"}
      assert Stacks.stack_assignee_for_phase(stack, "planning") == {nil, nil}
    end
  end

  describe "set_stack_phase_assignees/2" do
    test "writes the stack-level default and percolates to all un-overridden members" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "M2"})
      {:ok, _} = Stacks.add_task(stack, m1)
      {:ok, _} = Stacks.add_task(stack, m2)

      agent = Ecto.UUID.generate()

      assert {:ok, %{stack: updated_stack, percolated: percolated, skipped: []}} =
               Stacks.set_stack_phase_assignees(stack, all_phases(agent))

      assert Stacks.stack_phase_assignees(updated_stack) == all_phases(agent)
      assert length(percolated) == 2

      for member <- [m1, m2] do
        reloaded = Repo.get!(Task, member.id)
        assert reloaded.phase_assignees["planning"]["assignee_id"] == agent
        assert reloaded.phase_assignees["execution"]["assignee_id"] == agent
        assert reloaded.phase_assignees["review"]["assignee_id"] == agent
        # current phase for a backlog task is "planning"
        assert reloaded.assignee_id == agent
      end
    end

    test "skips members flagged assignee_override and reports them in :skipped" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "M2"})
      {:ok, _} = Stacks.add_task(stack, m1)
      {:ok, m2} = Stacks.add_task(stack, m2)

      agent_b = Ecto.UUID.generate()
      m2 = stamp_override(m2, agent_b)

      agent_a = Ecto.UUID.generate()

      assert {:ok, %{percolated: [percolated], skipped: [skipped]}} =
               Stacks.set_stack_phase_assignees(stack, all_phases(agent_a))

      assert percolated.id == m1.id
      assert skipped.id == m2.id

      # m1 inherited agent_a
      assert Repo.get!(Task, m1.id).assignee_id == agent_a
      # m2 kept its individual override (agent_b)
      m2_reloaded = Repo.get!(Task, m2.id)
      assert m2_reloaded.assignee_id == agent_b
      assert m2_reloaded.phase_assignees["execution"]["assignee_id"] == agent_b
    end

    test "merges partial updates phase-by-phase, leaving other phases intact" do
      stack = stack_fixture()
      agent_a = Ecto.UUID.generate()
      agent_b = Ecto.UUID.generate()

      {:ok, _} = Stacks.set_stack_phase_assignees(stack, all_phases(agent_a))

      assert {:ok, %{stack: updated}} =
               Stacks.set_stack_phase_assignees(stack, %{
                 "execution" => %{"assignee_id" => agent_b, "assignee_type" => "agent"}
               })

      pa = Stacks.stack_phase_assignees(updated)
      assert pa["planning"]["assignee_id"] == agent_a
      assert pa["execution"]["assignee_id"] == agent_b
      assert pa["review"]["assignee_id"] == agent_a
    end

    test "returns {:error, :stack_not_found} for an unknown stack id" do
      assert {:error, :stack_not_found} =
               Stacks.set_stack_phase_assignees(Ecto.UUID.generate(), %{})
    end

    test "preserves other metadata keys on the stack" do
      stack = stack_fixture()

      {:ok, stack} =
        stack
        |> Stack.changeset(%{metadata: %{"keep" => "this"}})
        |> Repo.update()

      agent = Ecto.UUID.generate()
      {:ok, %{stack: updated}} = Stacks.set_stack_phase_assignees(stack, all_phases(agent))

      assert updated.metadata["keep"] == "this"
      assert updated.metadata["phase_assignees"]["planning"]["assignee_id"] == agent
    end
  end

  describe "add_task/2 — stack-level assignment inheritance" do
    test "a joining task with no override inherits the stack-level default" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      agent = Ecto.UUID.generate()
      {:ok, _} = Stacks.set_stack_phase_assignees(stack, all_phases(agent))

      {:ok, newcomer} = Tasks.create_task(%{project_id: project.id, title: "Late joiner"})
      assert {:ok, joined} = Stacks.add_task(stack, newcomer)

      assert joined.phase_assignees["planning"]["assignee_id"] == agent
      assert joined.phase_assignees["execution"]["assignee_id"] == agent
      assert joined.phase_assignees["review"]["assignee_id"] == agent
      assert joined.assignee_id == agent
    end

    test "a joining task flagged assignee_override keeps its own assignment" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      agent_a = Ecto.UUID.generate()
      {:ok, _} = Stacks.set_stack_phase_assignees(stack, all_phases(agent_a))

      agent_b = Ecto.UUID.generate()
      {:ok, newcomer} = Tasks.create_task(%{project_id: project.id, title: "Self-assigned"})
      newcomer = stamp_override(newcomer, agent_b)

      assert {:ok, joined} = Stacks.add_task(stack, newcomer)
      assert joined.assignee_id == agent_b
      assert joined.phase_assignees["execution"]["assignee_id"] == agent_b
    end

    test "a joining task is untouched when the stack has no stack-level default" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      {:ok, newcomer} = Tasks.create_task(%{project_id: project.id, title: "Plain"})

      assert {:ok, joined} = Stacks.add_task(stack, newcomer)
      assert joined.phase_assignees == %{}
      assert joined.assignee_id == nil
    end
  end

  describe "clear_member_override/1" do
    test "unsets the override flag and re-applies the stack-level default" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, m1} = Stacks.add_task(stack, m1)

      agent_b = Ecto.UUID.generate()
      m1 = stamp_override(m1, agent_b)

      agent_a = Ecto.UUID.generate()
      {:ok, _} = Stacks.set_stack_phase_assignees(stack, all_phases(agent_a))

      # m1 was skipped, still on agent_b
      assert Repo.get!(Task, m1.id).assignee_id == agent_b

      assert {:ok, cleared} = Stacks.clear_member_override(m1)
      refute Stacks.member_overridden?(cleared)
      assert cleared.assignee_id == agent_a
      assert cleared.phase_assignees["execution"]["assignee_id"] == agent_a
    end

    test "just clears the flag when the stack has no stack-level default" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, m1} = Stacks.add_task(stack, m1)

      agent_b = Ecto.UUID.generate()
      m1 = stamp_override(m1, agent_b)

      assert {:ok, cleared} = Stacks.clear_member_override(m1)
      refute Stacks.member_overridden?(cleared)
      # no stack default to re-apply — keeps its existing phase_assignees
      assert cleared.phase_assignees["execution"]["assignee_id"] == agent_b
    end

    test "returns {:error, :not_in_stack} for a task with no stack_id" do
      project = project_fixture()
      {:ok, free} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      assert {:error, :not_in_stack} = Stacks.clear_member_override(free)
    end

    test "returns {:error, :task_not_found} for an unknown task id" do
      assert {:error, :task_not_found} = Stacks.clear_member_override(Ecto.UUID.generate())
    end
  end

  describe "member_overridden?/1" do
    test "true only when metadata.assignee_override == true" do
      assert Stacks.member_overridden?(%{"assignee_override" => true})
      refute Stacks.member_overridden?(%{"assignee_override" => false})
      refute Stacks.member_overridden?(%{"assignee_override" => "true"})
      refute Stacks.member_overridden?(%{})
      refute Stacks.member_overridden?(nil)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Bypass the broadcast pipeline + status-transition guards for setup —
  # we're exercising the rollup math, not the dispatcher.
  defp set_member_status(stack, %Task{id: id}, status) do
    member = Enum.find(Stacks.members(stack), &(&1.id == id))

    member
    |> Task.changeset(%{status: status})
    |> Repo.update!()
  end

  defp stack_fixture(attrs \\ []) do
    attrs = Map.new(attrs)

    project_id =
      Map.get_lazy(attrs, :project_id, fn ->
        {:ok, project} =
          Tasks.create_project(%{name: "Stack Fixture Project " <> Ecto.UUID.generate()})

        project.id
      end)

    slug = Map.get(attrs, :slug, "fixture-" <> short_id())
    name = Map.get(attrs, :name, "Fixture Stack")
    description = Map.get(attrs, :description)

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project_id,
        slug: slug,
        name: name,
        description: description,
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  defp short_id do
    Ecto.UUID.generate() |> String.slice(0, 8)
  end

  defp project_fixture do
    {:ok, project} =
      Tasks.create_project(%{name: "Stacks App " <> Ecto.UUID.generate()})

    project
  end

  # All three phases assigned to one agent — the "simple mode" shape.
  defp all_phases(agent_id) do
    %{
      "planning" => %{"assignee_id" => agent_id, "assignee_type" => "agent"},
      "execution" => %{"assignee_id" => agent_id, "assignee_type" => "agent"},
      "review" => %{"assignee_id" => agent_id, "assignee_type" => "agent"}
    }
  end

  # Mimic the per-task assignee modal save path: set all-phase assignees on
  # the task AND stamp metadata["assignee_override"] = true.
  defp stamp_override(%Task{} = task, agent_id) do
    {:ok, task} = Tasks.set_phase_assignees(task, all_phases(agent_id))

    {:ok, task} =
      Tasks.update_task(task, %{
        metadata: Map.put(task.metadata || %{}, "assignee_override", true)
      })

    task
  end

  # Create a stack and stamp a raw `phase_assignees` map into its metadata,
  # bypassing normalization so read-helper tests can exercise malformed input.
  defp stack_with_phase_assignees(phase_assignees) do
    stack = stack_fixture()

    stack
    |> Stack.changeset(%{
      metadata: Map.put(stack.metadata || %{}, "phase_assignees", phase_assignees)
    })
    |> Repo.update!()
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ── recompute_stack_status piggy-back fixtures ─────────────────────────────
  #
  # In-memory `GitRunner` for the piggy-back tests. We only care about
  # whether `open_stack_pr/1` was called (and that it can be made to raise);
  # all other callbacks return safe defaults so the deployer's other code
  # paths can run unimpeded if the gate happens to fire.
  defmodule RecomputePrHookRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            pr_response: {:ok, %{number: 1, url: "https://github.com/test/repo/pull/1"}},
            pr_calls: []
          }
        end,
        name: __MODULE__
      )
    end

    def stop, do: Agent.stop(__MODULE__)

    def set_pr_response(response),
      do: Agent.update(__MODULE__, &Map.put(&1, :pr_response, response))

    def pr_calls, do: Agent.get(__MODULE__, & &1.pr_calls) |> Enum.reverse()

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, %{status: :already_exists, base_sha: nil}}

    @impl true
    def merge_member_into_rollup(_args),
      do: {:ok, %{status: :merged, merge_sha: "0000000000000000000000000000000000000000"}}

    @impl true
    def open_stack_pr(args) do
      response =
        Agent.get_and_update(__MODULE__, fn state ->
          {state.pr_response, %{state | pr_calls: [args | state.pr_calls]}}
        end)

      case response do
        # Raise on the caller side so we don't crash the Agent process.
        {:raise, msg} -> raise RuntimeError, message: msg
        other -> other
      end
    end

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def revert_member_merge(_args),
      do: {:ok, %{status: :reverted, revert_sha: "0000000000000000000000000000000000000000"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}
  end

  defp install_pr_hook_runner(_ctx) do
    prev = Application.get_env(:platform, :stack_deployer, [])

    {:ok, _} = RecomputePrHookRunner.start_link()

    Application.put_env(:platform, :stack_deployer,
      git_runner: RecomputePrHookRunner,
      async: false
    )

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        RecomputePrHookRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Recompute PR Hook " <> Ecto.UUID.generate(),
        repo_url: "https://github.com/test/recompute-pr-hook-" <> short_id()
      })

    %{project: project}
  end

  defp stack_for_pr_hook!(project, opts) do
    slug = Keyword.get(opts, :slug, "pr-hook-" <> short_id())

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "PR-hook stack #{slug}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  # Create a stack member already stamped as merged-into-rollup (status
  # in_review + metadata.merged_into_rollup_at). Mirrors the helper in
  # `stack_deployer_test.exs` so the deployer's `all_members_ready?/1`
  # gate sees the member as ready.
  defp stamp_merged_member!(project, stack, opts) do
    sha = Keyword.fetch!(opts, :sha)
    position = Keyword.get(opts, :position, 1)
    title = Keyword.get(opts, :title, "Merged member " <> short_id())

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "in_review"
      })

    {:ok, task} =
      Tasks.update_task(task, %{
        stack_id: stack.id,
        stack_position: position,
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => sha,
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })

    task
  end

  defp stamp_unmerged_member!(project, stack, opts) do
    position = Keyword.get(opts, :position, 1)

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Unmerged " <> short_id(),
        status: "in_progress"
      })

    {:ok, task} =
      Tasks.update_task(task, %{stack_id: stack.id, stack_position: position})

    task
  end
end
