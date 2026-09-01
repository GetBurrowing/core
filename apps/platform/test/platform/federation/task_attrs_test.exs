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

  # ── Auto-approve fan-out on :create (task 01a05877, ADR 0044 §5) ────────
  #
  # task_create with auto_approve_plan: true and an agent-typed flat pair
  # refused unconditionally before the fan-out: flat routing only ever
  # filled `phase_attrs["planning"]`, but the auto-approve precondition
  # requires agent-resolved execution + review slots. On :create with the
  # flag, the flat agent now fills every ABSENT one of the three slots.
  # All expectations below are LITERAL maps built from the fixture ids —
  # never re-derived from the builder — so a mutant that over- or
  # under-fills cannot pass by construction.
  describe "build_task_attrs/3 — auto-approve fan-out on :create" do
    @fanout_opts [auto_route_flat_assignee_current_phase: true, current_phase: "planning"]

    test "flat agent (assignee_type absent) + flag fans out to the literal three-slot map" do
      args = %{
        "title" => "t",
        "project_id" => "p",
        "assignee_id" => @agent_id,
        "auto_approve_plan" => true
      }

      assert {:ok, flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :create, @fanout_opts)

      assert flat == %{title: "t", project_id: "p", auto_approve_plan: true}
      refute Map.has_key?(flat, :assignee_id)
      refute Map.has_key?(flat, :assignee_type)

      assert phase_attrs == %{
               "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"},
               "execution" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"},
               "review" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "flat agent (assignee_type \"agent\") + flag fans out to the literal three-slot map" do
      args = %{
        "title" => "t",
        "project_id" => "p",
        "assignee_id" => @agent_id,
        "assignee_type" => "agent",
        "auto_approve_plan" => true
      }

      assert {:ok, flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :create, @fanout_opts)

      refute Map.has_key?(flat, :assignee_id)
      refute Map.has_key?(flat, :assignee_type)

      assert phase_attrs == %{
               "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"},
               "execution" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"},
               "review" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "flag false routes planning-only (mutation probe: fan-out is flag-gated)" do
      args = %{
        "title" => "t",
        "project_id" => "p",
        "assignee_id" => @agent_id,
        "assignee_type" => "agent",
        "auto_approve_plan" => false
      }

      assert {:ok, _flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :create, @fanout_opts)

      assert phase_attrs == %{
               "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "flag absent routes planning-only (mutation probe: fan-out is flag-gated)" do
      args = %{
        "title" => "t",
        "project_id" => "p",
        "assignee_id" => @agent_id,
        "assignee_type" => "agent"
      }

      assert {:ok, _flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :create, @fanout_opts)

      assert phase_attrs == %{
               "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "flat USER-typed pair + flag routes planning-only, no fan-out" do
      args = %{
        "title" => "t",
        "project_id" => "p",
        "assignee_id" => @user_id,
        "assignee_type" => "user",
        "auto_approve_plan" => true
      }

      assert {:ok, _flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :create, @fanout_opts)

      assert phase_attrs == %{
               "planning" => %{"assignee_id" => @user_id, "assignee_type" => "user"}
             }
    end

    test "empty-string assignee_id + flag does not fan out (non-empty binary required)" do
      args = %{
        "title" => "t",
        "project_id" => "p",
        "assignee_id" => "",
        "auto_approve_plan" => true
      }

      assert {:ok, _flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :create, @fanout_opts)

      assert phase_attrs == %{
               "planning" => %{"assignee_id" => "", "assignee_type" => "agent"}
             }
    end

    test "explicit planning entry wins; execution + review fill from the flat agent (literal map)" do
      args = %{
        "title" => "t",
        "project_id" => "p",
        "assignee_id" => @agent_id,
        "assignee_type" => "agent",
        "auto_approve_plan" => true,
        "phase_assignees" => %{
          "planning" => %{"assignee_id" => @sponsor_id, "assignee_type" => "agent"}
        }
      }

      assert {:ok, _flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :create, @fanout_opts)

      assert phase_attrs == %{
               "planning" => %{"assignee_id" => @sponsor_id, "assignee_type" => "agent"},
               "execution" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"},
               "review" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "explicitly-nil slot is never filled and stays nil" do
      args = %{
        "title" => "t",
        "project_id" => "p",
        "assignee_id" => @agent_id,
        "assignee_type" => "agent",
        "auto_approve_plan" => true,
        "phase_assignees" => %{"execution" => nil}
      }

      assert {:ok, _flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :create, @fanout_opts)

      assert phase_attrs == %{
               "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"},
               "execution" => nil,
               "review" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end

    test "DELIBERATE ASYMMETRY PIN: :update mode with the same args + opts routes planning-only" do
      # task_update never fans out — its flat pair keeps routing to the
      # current-phase slot only, because fanning would clobber existing
      # per-phase assignments on a live task.
      args = %{
        "assignee_id" => @agent_id,
        "assignee_type" => "agent",
        "auto_approve_plan" => true
      }

      assert {:ok, _flat, phase_attrs} = TaskAttrs.build_task_attrs(args, :update, @fanout_opts)

      assert phase_attrs == %{
               "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
             }
    end
  end

  # ── check_auto_approve_preconditions/4 (task 019f5145) ─────────────────
  #
  # Pure-function precondition on the auto_approve_plan flag: when the
  # flag is (or will be) `true`, BOTH the execution and review phase slots
  # must resolve to a live agent. Stubs the resolver so these stay
  # Repo-free.
  describe "check_auto_approve_preconditions/4" do
    @exec_agent "01900000-0000-7000-8000-000000000e01"
    @review_agent "01900000-0000-7000-8000-000000000e02"
    @unknown_agent "01900000-0000-7000-8000-0000000000ff"

    # Stub resolver: only the two seeded ids resolve; everything else
    # returns nil. Mirrors the shape of `Platform.Repo.get(Agent, id)`.
    defp stub_resolver do
      known = MapSet.new([@exec_agent, @review_agent])

      fn id ->
        if MapSet.member?(known, id), do: %Platform.Agents.Agent{id: id}, else: nil
      end
    end

    defp full_phase_attrs do
      %{
        "execution" => %{"assignee_id" => @exec_agent, "assignee_type" => "agent"},
        "review" => %{"assignee_id" => @review_agent, "assignee_type" => "agent"}
      }
    end

    test "flag false + no phase_attrs + no existing task → :ok (gate closed)" do
      assert :ok =
               TaskAttrs.check_auto_approve_preconditions(
                 %{auto_approve_plan: false},
                 nil,
                 nil,
                 agent_resolver: stub_resolver()
               )
    end

    test "flag off + existing task with auto_approve_plan=true and no phase_attrs → :ok" do
      # Regression: nothing being touched, do NOT re-run the check on an
      # update that leaves auto_approve_plan alone. Only rewrites to
      # phase_assignees under a still-true flag open the gate.
      existing = %Platform.Tasks.Task{auto_approve_plan: true, phase_assignees: %{}}

      assert :ok =
               TaskAttrs.check_auto_approve_preconditions(
                 %{},
                 nil,
                 existing,
                 agent_resolver: stub_resolver()
               )
    end

    test "flag on + phase_attrs supplies both exec+review agents → :ok" do
      assert :ok =
               TaskAttrs.check_auto_approve_preconditions(
                 %{auto_approve_plan: true},
                 full_phase_attrs(),
                 nil,
                 agent_resolver: stub_resolver()
               )
    end

    test "flag on + only review slot → rejects with execution missing (absent)" do
      phase_attrs = %{
        "review" => %{"assignee_id" => @review_agent, "assignee_type" => "agent"}
      }

      assert {:error,
              {:auto_approve_precondition_missing,
               %{missing_phases: ["execution"], reasons: %{"execution" => :absent}}}} =
               TaskAttrs.check_auto_approve_preconditions(
                 %{auto_approve_plan: true},
                 phase_attrs,
                 nil,
                 agent_resolver: stub_resolver()
               )
    end

    test "flag on + only execution slot → rejects with review missing (absent)" do
      phase_attrs = %{
        "execution" => %{"assignee_id" => @exec_agent, "assignee_type" => "agent"}
      }

      assert {:error,
              {:auto_approve_precondition_missing,
               %{missing_phases: ["review"], reasons: %{"review" => :absent}}}} =
               TaskAttrs.check_auto_approve_preconditions(
                 %{auto_approve_plan: true},
                 phase_attrs,
                 nil,
                 agent_resolver: stub_resolver()
               )
    end

    test "flag on + both slots absent → rejects with stable [execution, review] order" do
      assert {:error, {:auto_approve_precondition_missing, %{missing_phases: phases}}} =
               TaskAttrs.check_auto_approve_preconditions(
                 %{auto_approve_plan: true},
                 nil,
                 nil,
                 agent_resolver: stub_resolver()
               )

      # `missing_phases` is documented as stable [execution, review]
      # order — the reduce walks @auto_approve_required_phases in
      # declaration order and appends.
      assert phases == ["execution", "review"]
    end

    test "flag on + execution slot present but user-typed → rejects :non_agent_type" do
      phase_attrs = %{
        "execution" => %{"assignee_id" => @exec_agent, "assignee_type" => "user"},
        "review" => %{"assignee_id" => @review_agent, "assignee_type" => "agent"}
      }

      assert {:error,
              {:auto_approve_precondition_missing,
               %{missing_phases: ["execution"], reasons: %{"execution" => :non_agent_type}}}} =
               TaskAttrs.check_auto_approve_preconditions(
                 %{auto_approve_plan: true},
                 phase_attrs,
                 nil,
                 agent_resolver: stub_resolver()
               )
    end

    test "flag on + execution slot with agent type but resolver returns nil → :agent_not_found" do
      phase_attrs = %{
        "execution" => %{"assignee_id" => @unknown_agent, "assignee_type" => "agent"},
        "review" => %{"assignee_id" => @review_agent, "assignee_type" => "agent"}
      }

      assert {:error,
              {:auto_approve_precondition_missing,
               %{missing_phases: ["execution"], reasons: %{"execution" => :agent_not_found}}}} =
               TaskAttrs.check_auto_approve_preconditions(
                 %{auto_approve_plan: true},
                 phase_attrs,
                 nil,
                 agent_resolver: stub_resolver()
               )
    end

    test ":update regression — existing full auto_approve task + title-only update → :ok" do
      # No flag toggle, no phase_attrs → gate stays closed even though
      # the existing task carries auto_approve_plan=true. This is the
      # regression trap for `task_update(title: ...)` on a task already
      # satisfying the invariant.
      existing = %Platform.Tasks.Task{
        auto_approve_plan: true,
        phase_assignees: full_phase_attrs()
      }

      assert :ok =
               TaskAttrs.check_auto_approve_preconditions(
                 %{title: "Renamed"},
                 nil,
                 existing,
                 agent_resolver: stub_resolver()
               )
    end

    test ":update — full-auto task with phase_attrs rewriting exec to a user → rejects" do
      # Auto-approve stays on (flag absent from flat_attrs), but the
      # caller is rewriting the execution slot. Gate opens; the new
      # user-typed slot fails :non_agent_type.
      existing = %Platform.Tasks.Task{
        auto_approve_plan: true,
        phase_assignees: full_phase_attrs()
      }

      phase_attrs = %{
        "execution" => %{"assignee_id" => "some-user-id", "assignee_type" => "user"}
      }

      assert {:error, {:auto_approve_precondition_missing, %{missing_phases: ["execution"]}}} =
               TaskAttrs.check_auto_approve_preconditions(
                 %{},
                 phase_attrs,
                 existing,
                 agent_resolver: stub_resolver()
               )
    end

    test ":update — flipping auto_approve_plan false → true on a slotless task rejects both" do
      existing = %Platform.Tasks.Task{auto_approve_plan: false, phase_assignees: %{}}

      assert {:error,
              {:auto_approve_precondition_missing, %{missing_phases: ["execution", "review"]}}} =
               TaskAttrs.check_auto_approve_preconditions(
                 %{auto_approve_plan: true},
                 nil,
                 existing,
                 agent_resolver: stub_resolver()
               )
    end

    test "agent_resolver opt is not called when the gate is closed" do
      # Confirms the short-circuit: an update-mode call with the flag
      # absent and no matching existing-task state must not touch the
      # resolver. A raising resolver would blow up if the gate opened.
      raising_resolver = fn _id -> raise "should not be called" end

      assert :ok =
               TaskAttrs.check_auto_approve_preconditions(
                 %{title: "Untouched"},
                 nil,
                 nil,
                 agent_resolver: raising_resolver
               )
    end
  end

  # ── auto_approve_corrected_args/3 (task 01a05877 stage 2) ───────────────
  #
  # Mechanical corrected_args for a refused auto-approve precondition.
  # All expectations are LITERAL maps built from the fixture ids — never
  # re-derived from the function under test — so a mutant that over- or
  # under-fills cannot pass by construction.
  describe "auto_approve_corrected_args/3" do
    @task_id "01900000-0000-7000-8000-000000000004"

    test "flat agent + flag + every failing slot absent → corrected args with the literal three-slot map" do
      args = %{
        "task_id" => @task_id,
        "auto_approve_plan" => true,
        "assignee_id" => @agent_id,
        "assignee_type" => "agent"
      }

      # The merged map the precondition read on a slotless task whose
      # flat pair routed to the current (planning) phase slot.
      merged = %{"planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}}

      assert TaskAttrs.auto_approve_corrected_args(args, merged, ["execution", "review"]) == %{
               "task_id" => @task_id,
               "auto_approve_plan" => true,
               "assignee_id" => @agent_id,
               "assignee_type" => "agent",
               "phase_assignees" => %{
                 "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"},
                 "execution" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"},
                 "review" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
               }
             }
    end

    test "user-typed flat pair → nil (caller must choose an agent id)" do
      args = %{
        "task_id" => @task_id,
        "auto_approve_plan" => true,
        "assignee_id" => @user_id,
        "assignee_type" => "user"
      }

      assert TaskAttrs.auto_approve_corrected_args(args, %{}, ["execution", "review"]) == nil
    end

    test "absent flat pair → nil" do
      args = %{"task_id" => @task_id, "auto_approve_plan" => true}

      assert TaskAttrs.auto_approve_corrected_args(args, %{}, ["execution", "review"]) == nil
    end

    test "flag off → nil (mutation probe: the correction is flag-gated)" do
      args = %{
        "task_id" => @task_id,
        "auto_approve_plan" => false,
        "assignee_id" => @agent_id,
        "assignee_type" => "agent"
      }

      assert TaskAttrs.auto_approve_corrected_args(args, %{}, ["execution", "review"]) == nil
    end

    test "empty-string assignee_id → nil (non-empty binary required)" do
      args = %{
        "task_id" => @task_id,
        "auto_approve_plan" => true,
        "assignee_id" => "",
        "assignee_type" => "agent"
      }

      assert TaskAttrs.auto_approve_corrected_args(args, %{}, ["execution", "review"]) == nil
    end

    test "failing slot present-but-user-typed in merged → nil (fill cannot repair)" do
      args = %{
        "task_id" => @task_id,
        "auto_approve_plan" => true,
        "assignee_id" => @agent_id,
        "assignee_type" => "agent"
      }

      merged = %{"execution" => %{"assignee_id" => @user_id, "assignee_type" => "user"}}

      assert TaskAttrs.auto_approve_corrected_args(args, merged, ["execution", "review"]) == nil
    end

    test "failing slot present-but-nil in merged → nil (explicitly cleared slot is never filled)" do
      args = %{
        "task_id" => @task_id,
        "auto_approve_plan" => true,
        "assignee_id" => @agent_id,
        "assignee_type" => "agent"
      }

      assert TaskAttrs.auto_approve_corrected_args(args, %{"execution" => nil}, [
               "execution",
               "review"
             ]) == nil
    end

    test "failing slot present with an unknown agent id → nil (fill cannot repair)" do
      args = %{
        "task_id" => @task_id,
        "auto_approve_plan" => true,
        "assignee_id" => @agent_id,
        "assignee_type" => "agent"
      }

      merged = %{"execution" => %{"assignee_id" => @unknown_agent, "assignee_type" => "agent"}}

      assert TaskAttrs.auto_approve_corrected_args(args, merged, ["execution", "review"]) == nil
    end

    test "explicit submitted phase_assignees keys are kept; only absent slots are filled" do
      args = %{
        "task_id" => @task_id,
        "auto_approve_plan" => true,
        "assignee_id" => @agent_id,
        "assignee_type" => "agent",
        "phase_assignees" => %{
          "execution" => %{"assignee_id" => @exec_agent, "assignee_type" => "agent"}
        }
      }

      # The existing task already supplies the live execution slot, so
      # only review is failing — the explicit execution key survives.
      merged = %{"execution" => %{"assignee_id" => @exec_agent, "assignee_type" => "agent"}}

      assert TaskAttrs.auto_approve_corrected_args(args, merged, ["review"]) == %{
               "task_id" => @task_id,
               "auto_approve_plan" => true,
               "assignee_id" => @agent_id,
               "assignee_type" => "agent",
               "phase_assignees" => %{
                 "planning" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"},
                 "execution" => %{"assignee_id" => @exec_agent, "assignee_type" => "agent"},
                 "review" => %{"assignee_id" => @agent_id, "assignee_type" => "agent"}
               }
             }
    end
  end
end
