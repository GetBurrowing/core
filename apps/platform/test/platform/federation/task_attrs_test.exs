defmodule Platform.Federation.TaskAttrsTest do
  # Pure map I/O — no DB, no fixtures.
  use ExUnit.Case, async: true

  alias Platform.Federation.TaskAttrs

  @agent_id "01900000-0000-7000-8000-0000000000aa"
  @user_id "01900000-0000-7000-8000-0000000000bb"
  @sponsor_id "01900000-0000-7000-8000-0000000000cc"

  describe "explicitly_nilable/0" do
    test "includes sponsor_user_id (ADR 0042) and deploy_target (ADR 0044)" do
      keys = TaskAttrs.explicitly_nilable()
      assert "sponsor_user_id" in keys
      assert "deploy_target" in keys
    end
  end

  describe "emptystring_clears/0" do
    test "includes deploy_target" do
      assert "deploy_target" in TaskAttrs.emptystring_clears()
    end
  end

  describe "build_task_attrs/3 — :create mode" do
    test "round-trips the canonical field set into flat_attrs" do
      args = %{
        "title" => "Hello",
        "description" => "world",
        "project_id" => "proj-1",
        "status" => "backlog",
        "priority" => "medium",
        "sponsor_user_id" => @sponsor_id,
        "deploy_target" => "exp",
        "auto_approve_plan" => false
      }

      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :create)

      assert flat == %{
               title: "Hello",
               description: "world",
               project_id: "proj-1",
               status: "backlog",
               priority: "medium",
               sponsor_user_id: @sponsor_id,
               deploy_target: "exp",
               auto_approve_plan: false
             }
    end

    test "atom-keyed args are accepted" do
      args = %{title: "atomic", project_id: "proj-1"}
      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :create)
      assert flat == %{title: "atomic", project_id: "proj-1"}
    end

    test "sponsor_user_id nil is DROPPED in :create (no existing value to clear)" do
      args = %{"title" => "t", "project_id" => "p", "sponsor_user_id" => nil}
      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :create)
      refute Map.has_key?(flat, :sponsor_user_id)
    end

    test "deploy_target empty string normalizes to nil then drops in :create" do
      args = %{"title" => "t", "project_id" => "p", "deploy_target" => ""}
      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :create)
      refute Map.has_key?(flat, :deploy_target)
    end

    test "unknown keys are silently dropped" do
      args = %{"title" => "t", "project_id" => "p", "gibberish" => "value"}
      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :create)
      refute Map.has_key?(flat, :gibberish)
      refute Map.has_key?(flat, "gibberish")
    end

    test "flat assignee_id + assignee_type emit into flat_attrs when auto-routing is OFF" do
      args = %{
        "title" => "t",
        "project_id" => "p",
        "assignee_id" => @agent_id,
        "assignee_type" => "agent"
      }

      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :create)
      assert flat[:assignee_id] == @agent_id
      assert flat[:assignee_type] == "agent"
    end

    test "flat assignee auto-routes to phase_attrs at current_phase when opts opt in" do
      args = %{
        "title" => "t",
        "project_id" => "p",
        "assignee_id" => @agent_id,
        "assignee_type" => "agent"
      }

      assert {:ok, flat, phase_attrs} =
               TaskAttrs.build_task_attrs(args, :create,
                 auto_route_flat_assignee_current_phase: true,
                 current_phase: "planning"
               )

      # Flat pair is stripped when auto-routing.
      refute Map.has_key?(flat, :assignee_id)
      refute Map.has_key?(flat, :assignee_type)

      # And lifted into phase_attrs at the current-phase slot.
      assert phase_attrs == %{
               "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "auto_route with no current_phase is an error" do
      args = %{"title" => "t", "assignee_id" => @agent_id, "assignee_type" => "agent"}

      assert {:error, :auto_route_requires_current_phase} =
               TaskAttrs.build_task_attrs(args, :create,
                 auto_route_flat_assignee_current_phase: true
               )
    end

    test "auto_route with invalid current_phase is an error" do
      assert {:error, {:invalid_current_phase, "bogus"}} =
               TaskAttrs.build_task_attrs(%{}, :create,
                 auto_route_flat_assignee_current_phase: true,
                 current_phase: "bogus"
               )
    end

    test "structured phase_assignees passes through to phase_attrs and NOT flat_attrs" do
      args = %{
        "title" => "t",
        "phase_assignees" => %{
          "execution" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
        }
      }

      assert {:ok, flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :create)

      refute Map.has_key?(flat, :phase_assignees)

      assert phase_attrs == %{
               "execution" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "structured phase_assignees wins; flat assignee_* is silently dropped" do
      args = %{
        "title" => "t",
        "assignee_id" => @user_id,
        "assignee_type" => "user",
        "phase_assignees" => %{
          "review" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
        }
      }

      assert {:ok, flat, phase_attrs} =
               TaskAttrs.build_task_attrs(args, :create,
                 # Auto-route is opt-in, but structured input outranks it.
                 auto_route_flat_assignee_current_phase: true,
                 current_phase: "planning"
               )

      # Flat pair silently dropped.
      refute Map.has_key?(flat, :assignee_id)
      refute Map.has_key?(flat, :assignee_type)

      # Structured phase_attrs is preserved as-is.
      assert phase_attrs == %{
               "review" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "phase_assignees with an unknown phase key is an error" do
      args = %{
        "phase_assignees" => %{
          "shipping" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
        }
      }

      assert {:error, {:invalid_phase_keys, ["shipping"]}} =
               TaskAttrs.build_task_attrs(args, :create)
    end

    test "phase_assignees non-map is an error" do
      args = %{"phase_assignees" => "not a map"}

      assert {:error, {:invalid_phase_assignees_shape, "not a map"}} =
               TaskAttrs.build_task_attrs(args, :create)
    end

    test "empty phase_assignees map is treated as nil (no per-phase intent)" do
      args = %{"title" => "t", "phase_assignees" => %{}}
      assert {:ok, _flat, nil} = TaskAttrs.build_task_attrs(args, :create)
    end
  end

  describe "build_task_attrs/3 — :update mode" do
    test "propagates the canonical field set as flat_attrs" do
      args = %{
        "title" => "renamed",
        "priority" => "high",
        "deploy_target" => "production"
      }

      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :update)

      assert flat == %{
               title: "renamed",
               priority: "high",
               deploy_target: "production"
             }
    end

    test "sponsor_user_id: nil PROPAGATES in :update (explicit-null-clears per ADR 0042)" do
      args = %{"sponsor_user_id" => nil}
      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :update)
      assert Map.fetch(flat, :sponsor_user_id) == {:ok, nil}
    end

    test "deploy_target: nil PROPAGATES in :update (explicit-null-clears)" do
      args = %{"deploy_target" => nil}
      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :update)
      assert Map.fetch(flat, :deploy_target) == {:ok, nil}
    end

    test "deploy_target empty string normalizes to nil and propagates in :update" do
      args = %{"deploy_target" => ""}
      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :update)
      assert Map.fetch(flat, :deploy_target) == {:ok, nil}
    end

    test "sponsor_user_id key omitted → not in output (untouched contract)" do
      args = %{"title" => "just a title update"}
      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :update)
      refute Map.has_key?(flat, :sponsor_user_id)
    end

    test "other nil-valued keys drop out (e.g. priority: nil is not a 'clear priority')" do
      args = %{"title" => "t", "priority" => nil}
      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :update)
      refute Map.has_key?(flat, :priority)
      assert flat[:title] == "t"
    end

    test "unknown keys silently dropped" do
      args = %{"title" => "t", "wat" => "no"}
      assert {:ok, flat, nil} = TaskAttrs.build_task_attrs(args, :update)
      refute Map.has_key?(flat, :wat)
    end

    test "flat assignee auto-routes to current_phase (execution) on an in_progress task" do
      args = %{"assignee_id" => @agent_id, "assignee_type" => "agent"}

      assert {:ok, flat, phase_attrs} =
               TaskAttrs.build_task_attrs(args, :update,
                 auto_route_flat_assignee_current_phase: true,
                 current_phase: "execution"
               )

      refute Map.has_key?(flat, :assignee_id)
      refute Map.has_key?(flat, :assignee_type)

      assert phase_attrs == %{
               "execution" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "flat assignee_id without assignee_type defaults type to 'agent' when auto-routing" do
      args = %{"assignee_id" => @agent_id}

      assert {:ok, _flat, phase_attrs} =
               TaskAttrs.build_task_attrs(args, :update,
                 auto_route_flat_assignee_current_phase: true,
                 current_phase: "execution"
               )

      assert phase_attrs == %{
               "execution" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "structured phase_assignees can write ONE slot in :update without disturbing others" do
      args = %{
        "phase_assignees" => %{
          "review" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
        }
      }

      assert {:ok, _flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :update)

      # The builder emits only the review slot — merging with existing
      # per-phase entries is `Tasks.set_phase_assignees/2`'s job.
      assert phase_attrs == %{
               "review" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "structured phase_assignees + flat assignee_* both supplied → structured wins" do
      args = %{
        "assignee_id" => @user_id,
        "assignee_type" => "user",
        "phase_assignees" => %{
          "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
        }
      }

      assert {:ok, flat, phase_attrs} =
               TaskAttrs.build_task_attrs(args, :update,
                 auto_route_flat_assignee_current_phase: true,
                 current_phase: "planning"
               )

      refute Map.has_key?(flat, :assignee_id)
      refute Map.has_key?(flat, :assignee_type)

      assert phase_attrs == %{
               "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end
  end

  describe "build_task_attrs/3 — canonical field set parity" do
    test "the same set of fields is accepted in :create and :update" do
      # Every field present in the top-of-plan-audit table has to
      # survive round-trip in BOTH modes. Test that the same input
      # emits the same key set (nilable rules aside).
      args = %{
        "title" => "t",
        "description" => "d",
        "status" => "backlog",
        "priority" => "medium",
        "epic_id" => "epic-1",
        "project_id" => "proj-1",
        "sponsor_user_id" => @sponsor_id,
        "deploy_target" => "exp",
        "auto_approve_plan" => true,
        "reported_by" => @user_id
      }

      assert {:ok, create_flat, nil} = TaskAttrs.build_task_attrs(args, :create)
      assert {:ok, update_flat, nil} = TaskAttrs.build_task_attrs(args, :update)

      # Same key set (both modes accept the same canonical fields).
      assert MapSet.new(Map.keys(create_flat)) == MapSet.new(Map.keys(update_flat))
    end
  end
end
