defmodule Platform.Tasks.StacksTest do
  use Platform.DataCase, async: true

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

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
