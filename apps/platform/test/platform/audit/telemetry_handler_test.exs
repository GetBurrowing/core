defmodule Platform.Audit.TelemetryHandlerTest do
  use Platform.DataCase

  import Platform.TenancyFixtures

  alias Platform.Audit
  alias Platform.Audit.Event
  alias Platform.Audit.TelemetryHandler

  setup do
    # Ensure handler is attached for each test (Application.start may not
    # run in the test env the way we expect) AND restored on exit —
    # it is VM-global, so leaving it detached silences audit writes for
    # every later test in this BEAM (task 019f9d80).
    Platform.TelemetryHelpers.ensure_boot_handler!(TelemetryHandler)
    :ok
  end

  # Snapshot the current set of Platform.TaskSupervisor child pids. Used
  # by the historian bridging tests to observe the async dispatch itself
  # — the spawn is the behaviour under test there, independently of
  # whether the row lands.
  #
  # The old version of this comment said the row could NOT land ("spawned
  # children aren't in the DataCase sandbox owner chain, so their
  # Repo.insert raises OwnershipError and the handler swallows it").
  # Measured false in task 019f9d80 stage 3: this module is `async: false`,
  # the sandbox is in shared mode, the children inherit this test's
  # connection and the insert succeeds. See the "supervised audit writes"
  # describe block at the bottom of this file.
  defp children_pids do
    Platform.TaskSupervisor
    |> Task.Supervisor.children()
    |> MapSet.new()
  end

  # Wait until a fresh child appears under Platform.TaskSupervisor
  # (compared to the given baseline set), monitor it, and wait for it
  # to exit. Returns :ok or raises with a diagnostic if the timeout
  # elapses.
  defp wait_for_new_child(before, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    new_child = poll_for_new_child(before, deadline)

    ref = Process.monitor(new_child)

    receive do
      {:DOWN, ^ref, :process, ^new_child, _reason} -> :ok
    after
      timeout_ms ->
        flunk(
          "spawned Task.Supervisor child #{inspect(new_child)} did not exit within #{timeout_ms}ms"
        )
    end
  end

  defp poll_for_new_child(before, deadline) do
    now = children_pids()
    diff = MapSet.difference(now, before)

    cond do
      MapSet.size(diff) > 0 ->
        diff |> MapSet.to_list() |> hd()

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("no new child appeared under Platform.TaskSupervisor within timeout")

      true ->
        Process.sleep(5)
        poll_for_new_child(before, deadline)
    end
  end

  describe "telemetry → audit persistence" do
    test "auth login event is persisted" do
      :telemetry.execute(
        [:platform, :auth, :login],
        %{system_time: System.system_time()},
        %{
          action: "redirect",
          ip_address: "10.0.0.1"
        }
      )

      events = Audit.list(event_type: "platform.auth.login")
      assert [%Event{action: "redirect", ip_address: "10.0.0.1"}] = events
    end

    test "auth callback success event captures actor" do
      user_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :auth, :callback],
        %{system_time: System.system_time()},
        %{
          action: "success",
          actor_id: user_id,
          actor_type: "user",
          resource_type: "session",
          resource_id: user_id,
          ip_address: "10.0.0.1",
          email: "test@example.com"
        }
      )

      events = Audit.list(event_type: "platform.auth.callback")
      assert [%Event{action: "success", actor_id: ^user_id, actor_type: "user"} = event] = events
      assert event.metadata["email"] == "test@example.com"
    end

    test "auth callback failure event captures reason" do
      :telemetry.execute(
        [:platform, :auth, :callback],
        %{system_time: System.system_time()},
        %{
          action: "failure",
          ip_address: "10.0.0.1",
          reason: "invalid_state"
        }
      )

      events = Audit.list(event_type: "platform.auth.callback")
      assert [%Event{action: "failure"} = event] = events
      assert event.metadata["reason"] == "invalid_state"
    end

    test "auth logout event is persisted" do
      user_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :auth, :logout],
        %{system_time: System.system_time()},
        %{
          action: "logout",
          actor_id: user_id,
          actor_type: "user",
          ip_address: "10.0.0.1"
        }
      )

      events = Audit.list(event_type: "platform.auth.logout")
      assert [%Event{action: "logout", actor_id: ^user_id}] = events
    end

    test "access blocked event captures route" do
      :telemetry.execute(
        [:platform, :auth, :access_blocked],
        %{system_time: System.system_time()},
        %{
          action: "blocked",
          actor_type: "anonymous",
          resource_type: "route",
          resource_id: "/admin/secrets",
          ip_address: "10.0.0.1",
          reason: "no_session"
        }
      )

      events = Audit.list(event_type: "platform.auth.access_blocked")

      assert [%Event{resource_type: "route", resource_id: "/admin/secrets"} = event] =
               events

      assert event.metadata["reason"] == "no_session"
    end

    test "metadata excludes top-level fields to avoid duplication" do
      :telemetry.execute(
        [:platform, :auth, :login],
        %{},
        %{
          action: "redirect",
          actor_id: Ecto.UUID.generate(),
          ip_address: "10.0.0.1",
          extra_field: "should-appear"
        }
      )

      [event] = Audit.list(event_type: "platform.auth.login")
      refute Map.has_key?(event.metadata, "actor_id")
      refute Map.has_key?(event.metadata, "ip_address")
      assert event.metadata["extra_field"] == "should-appear"
    end

    test "handler survives exceptions without detaching" do
      # Emit a malformed event (handler should rescue, not crash)
      :telemetry.execute(
        [:platform, :auth, :login],
        %{system_time: System.system_time()},
        %{action: "test-before"}
      )

      # Verify handler is still attached by emitting a second event
      :telemetry.execute(
        [:platform, :auth, :login],
        %{system_time: System.system_time()},
        %{action: "test-after"}
      )

      events = Audit.list(event_type: "platform.auth.login")
      actions = Enum.map(events, & &1.action)
      assert "test-before" in actions
      assert "test-after" in actions
    end
  end

  # Task 019f921d Gap 3 — the commencement gate_check fires on every gate
  # evaluation; the handler must persist + warn ONLY on the forming-lockout
  # signature (open=false AND blocked_by_count=0), and drop every benign
  # check without a write.
  describe "commencement gate_check anomaly alerting (Gap 3)" do
    test "persists an audit row on the open=false, blocked_by_count=0 signature" do
      stack_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :stacks, :commencement, :gate_check],
        %{blocked_by_count: 0},
        %{stack_id: stack_id, task_id: task_id, open: false}
      )

      assert [event] = Audit.list(event_type: "platform.stacks.commencement.gate_check")
      assert event.action == "gate_check_anomaly"
      assert event.resource_type == "stack"
      assert event.resource_id == stack_id
      assert event.metadata["task_id"] == task_id
      assert event.metadata["open"] == "false"
    end

    test "does NOT persist when the gate is open (open=true)" do
      :telemetry.execute(
        [:platform, :stacks, :commencement, :gate_check],
        %{blocked_by_count: 0},
        %{stack_id: Ecto.UUID.generate(), task_id: Ecto.UUID.generate(), open: true}
      )

      assert Audit.list(event_type: "platform.stacks.commencement.gate_check") == []
    end

    test "does NOT persist when blocked by a real plan gap (blocked_by_count > 0)" do
      :telemetry.execute(
        [:platform, :stacks, :commencement, :gate_check],
        %{blocked_by_count: 2},
        %{stack_id: Ecto.UUID.generate(), task_id: Ecto.UUID.generate(), open: false}
      )

      assert Audit.list(event_type: "platform.stacks.commencement.gate_check") == []
    end
  end

  describe "actor_org_id threading (ADR 0040)" do
    test "actor_org_id from telemetry metadata persists to audit_events.actor_org_id" do
      user_id = Ecto.UUID.generate()
      org_id = acme_org_id()

      :telemetry.execute(
        [:platform, :auth, :callback],
        %{system_time: System.system_time()},
        %{
          action: "success",
          actor_id: user_id,
          actor_type: "user",
          actor_org_id: org_id,
          ip_address: "10.0.0.1"
        }
      )

      [event] = Audit.list(event_type: "platform.auth.callback")
      assert event.actor_id == user_id
      assert event.actor_org_id == org_id
    end

    test "actor_org_id is excluded from metadata blob (top-level field deduplication)" do
      :telemetry.execute(
        [:platform, :auth, :login],
        %{},
        %{
          action: "redirect",
          actor_id: Ecto.UUID.generate(),
          actor_org_id: acme_org_id(),
          ip_address: "10.0.0.1"
        }
      )

      [event] = Audit.list(event_type: "platform.auth.login")
      refute Map.has_key?(event.metadata, "actor_org_id")
    end

    test "events without actor_org_id leave the column NULL" do
      :telemetry.execute(
        [:platform, :auth, :login],
        %{system_time: System.system_time()},
        %{action: "redirect", ip_address: "10.0.0.1"}
      )

      [event] = Audit.list(event_type: "platform.auth.login")
      assert is_nil(event.actor_org_id)
    end

    test "federated_user actor_type with both actor_id (handle) and actor_org_id" do
      pseudonymous_handle = Ecto.UUID.generate()
      peer_org_id = tenant_org_id("initech")

      :telemetry.execute(
        [:platform, :auth, :callback],
        %{system_time: System.system_time()},
        %{
          action: "success",
          actor_id: pseudonymous_handle,
          actor_type: "federated_user",
          actor_org_id: peer_org_id,
          ip_address: "203.0.113.1"
        }
      )

      [event] = Audit.list(event_type: "platform.auth.callback")
      assert event.actor_type == "federated_user"
      assert event.actor_id == pseudonymous_handle
      assert event.actor_org_id == peer_org_id
    end
  end

  describe "historian namespace bridging (async, task 019f5bc4)" do
    # These tests observe the SPAWN itself — monitor the new child pid and
    # wait for :DOWN — because "the handler dispatched asynchronously"
    # is the property task 019f5bc4 added and the property a regression
    # to a synchronous `Repo.insert` would break. Row persistence is a
    # separate property, asserted in "supervised audit writes" below.

    test "historian window_dispatched with workspace_id spawns a Task.Supervisor child" do
      workspace_id = Ecto.UUID.generate()

      # Enumerate current children so we can find the new one after emit.
      before_children = children_pids()

      :telemetry.execute(
        [:platform, :historian, :window_dispatched],
        %{token_count: 100, window_index: 1, day_bytes: 100},
        %{
          workspace_id: workspace_id,
          resource_type: "workspace",
          resource_id: workspace_id,
          corpus: :pages,
          oversize: false,
          action: "window_dispatched",
          actor_type: "system"
        }
      )

      # The child pid is fire-and-forget; wait for it to exit (via
      # monitor) so we know the async body ran to completion.
      wait_for_new_child(before_children, 500)
    end

    test "historian event without workspace_id or org_id is dropped with a warning log" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :telemetry.execute(
            [:platform, :historian, :window_dispatched],
            %{token_count: 100},
            %{corpus: :pages, oversize: false, action: "window_dispatched"}
          )

          # Wait for the spawned Task to run.
          Process.sleep(100)
        end)

      assert log =~ "missing workspace_id and org_id"
      # No row should have been persisted — event_type is derived server-
      # side so an emit without a proper scope shouldn't leak an audit row
      # even if the sandbox somehow allowed it. list/1 stays empty from
      # the test process view.
      assert Audit.list(event_type: "platform.historian.window_dispatched") == []
    end

    test "handle_event returns fast for historian events (async dispatch)" do
      workspace_id = Ecto.UUID.generate()

      measurements = %{token_count: 100, window_index: 1, day_bytes: 100}

      metadata = %{
        workspace_id: workspace_id,
        resource_type: "workspace",
        resource_id: workspace_id,
        corpus: :pages,
        oversize: false,
        action: "window_dispatched",
        actor_type: "system"
      }

      # Prime the JIT with a few no-op emits before measuring.
      for _ <- 1..10 do
        :telemetry.execute([:platform, :historian, :window_dispatched], measurements, metadata)
      end

      samples =
        for _ <- 1..100 do
          t0 = System.monotonic_time(:microsecond)

          :telemetry.execute(
            [:platform, :historian, :window_dispatched],
            measurements,
            metadata
          )

          System.monotonic_time(:microsecond) - t0
        end

      sorted = Enum.sort(samples)
      # p99 across 100 samples (index 99).
      p99 = Enum.at(sorted, 99)

      assert p99 < 5_000,
             "historian emit p99=#{p99}µs exceeded 5000µs budget — handler may have regressed to sync dispatch"
    end

    test "handler is attached to all seven historian events" do
      events = TelemetryHandler.events()

      historian_events =
        Enum.filter(events, fn
          [:platform, :historian | _] -> true
          _ -> false
        end)

      # 5 → 7 for task 019fa1cc stage 4. `window_truncated` and
      # `item_skipped` are the audit trail for the cursor invariant: a
      # window whose cursor was held short of `window_end`, and a row the
      # sweep stepped past because it exceeds the window budget alone. An
      # unregistered emit is a skip nobody can query, which is the silent
      # advance the stage exists to remove — so this census is the guard
      # that the events are actually persisted, not merely emitted.
      assert length(historian_events) == 7

      assert [:platform, :historian, :pass_started] in historian_events
      assert [:platform, :historian, :pass_completed] in historian_events
      assert [:platform, :historian, :window_dispatched] in historian_events
      assert [:platform, :historian, :cursor_advanced] in historian_events
      assert [:platform, :historian, :error] in historian_events
      assert [:platform, :historian, :window_truncated] in historian_events
      assert [:platform, :historian, :item_skipped] in historian_events
    end
  end

  describe "agents.historian namespace bridging (task 019f5e7d stage 5)" do
    # Two new events under the `[:platform, :agents, :historian | _]`
    # namespace — emitted by Higgins's runtime (no_op_pass) and
    # MeetingHistorianHandler (dispatch_debounced). Same async persist
    # path as the sibling 3-element historian events. These tests emit
    # `:telemetry.execute` directly and assert the audit_events row lands
    # via the child spawn under Platform.TaskSupervisor.

    test "handler is attached to all three agents.historian events" do
      events = TelemetryHandler.events()

      agents_historian_events =
        Enum.filter(events, fn
          [:platform, :agents, :historian | _] -> true
          _ -> false
        end)

      # 2 → 3 for task 01a0a12e stage 3: `meeting_curation_withheld` is the
      # audit row for a meeting-ended curation dispatch the handler declined
      # by default. An unregistered emit would be a silent drop.
      assert length(agents_historian_events) == 3
      assert [:platform, :agents, :historian, :no_op_pass] in agents_historian_events
      assert [:platform, :agents, :historian, :dispatch_debounced] in agents_historian_events

      assert [:platform, :agents, :historian, :meeting_curation_withheld] in agents_historian_events
    end

    test "meeting_curation_withheld with org_id spawns a Task.Supervisor child" do
      org_id = Ecto.UUID.generate()

      before_children = children_pids()

      :telemetry.execute(
        [:platform, :agents, :historian, :meeting_curation_withheld],
        %{count: 1},
        %{
          org_id: org_id,
          meeting_id: Ecto.UUID.generate(),
          project_id: Ecto.UUID.generate(),
          reason: :default_withheld,
          action: "meeting_curation_withheld",
          actor_type: "system"
        }
      )

      wait_for_new_child(before_children, 500)
    end

    test "no_op_pass with workspace_id spawns a Task.Supervisor child" do
      workspace_id = Ecto.UUID.generate()

      before_children = children_pids()

      :telemetry.execute(
        [:platform, :agents, :historian, :no_op_pass],
        %{elapsed_ms: 12},
        %{
          workspace_id: workspace_id,
          trigger: "historian.threshold",
          resource_type: "workspace",
          resource_id: workspace_id,
          action: "no_op_pass",
          actor_type: "system"
        }
      )

      wait_for_new_child(before_children, 500)
    end

    test "dispatch_debounced with workspace_id spawns a Task.Supervisor child" do
      workspace_id = Ecto.UUID.generate()

      before_children = children_pids()

      :telemetry.execute(
        [:platform, :agents, :historian, :dispatch_debounced],
        %{elapsed_ms: 240, debounce_ms: 900_000},
        %{
          workspace_id: workspace_id,
          trigger: "meeting_ended",
          meeting_id: Ecto.UUID.generate(),
          project_id: Ecto.UUID.generate(),
          resource_type: "workspace",
          resource_id: workspace_id,
          action: "dispatch_debounced",
          actor_type: "system"
        }
      )

      wait_for_new_child(before_children, 500)
    end

    test "agents.historian event without workspace_id or org_id is dropped with a warning log" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :telemetry.execute(
            [:platform, :agents, :historian, :dispatch_debounced],
            %{elapsed_ms: 42},
            %{
              # Deliberately no workspace_id / org_id — mirrors stage 4's
              # current emit shape from MeetingHistorianHandler which only
              # populates meeting_id + project_id. scope_check should drop
              # it exactly like the 3-element sibling would.
              meeting_id: Ecto.UUID.generate(),
              project_id: Ecto.UUID.generate(),
              action: "dispatch_debounced",
              actor_type: "system"
            }
          )

          Process.sleep(100)
        end)

      assert log =~ "missing workspace_id and org_id"
      assert Audit.list(event_type: "platform.agents.historian.dispatch_debounced") == []
    end

    test "handle_event returns fast for agents.historian events (async dispatch)" do
      workspace_id = Ecto.UUID.generate()

      measurements = %{elapsed_ms: 12}

      metadata = %{
        workspace_id: workspace_id,
        trigger: "historian.threshold",
        resource_type: "workspace",
        resource_id: workspace_id,
        action: "no_op_pass",
        actor_type: "system"
      }

      # Prime the JIT with a few no-op emits before measuring.
      for _ <- 1..10 do
        :telemetry.execute([:platform, :agents, :historian, :no_op_pass], measurements, metadata)
      end

      samples =
        for _ <- 1..100 do
          t0 = System.monotonic_time(:microsecond)

          :telemetry.execute(
            [:platform, :agents, :historian, :no_op_pass],
            measurements,
            metadata
          )

          System.monotonic_time(:microsecond) - t0
        end

      sorted = Enum.sort(samples)
      # p99 across 100 samples (index 99).
      p99 = Enum.at(sorted, 99)

      assert p99 < 5_000,
             "agents.historian emit p99=#{p99}µs exceeded 5000µs budget — handler may have regressed to sync dispatch"
    end
  end

  describe "auto-approve plan bridging (task 019f25f2 corrective)" do
    test "auto_approved event persists with resource pointing at the plan" do
      task_id = Ecto.UUID.generate()
      plan_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :plan, :auto_approved],
        %{count: 1},
        %{
          task_id: task_id,
          plan_id: plan_id,
          resource_type: "plan",
          resource_id: plan_id,
          action: "auto_approved",
          actor_type: "system"
        }
      )

      [event] = Audit.list(event_type: "platform.plan.auto_approved")
      assert event.resource_type == "plan"
      assert event.resource_id == plan_id
      assert event.action == "auto_approved"
      assert event.actor_type == "system"
      # task_id + plan_id remain in the metadata blob for correlation.
      assert event.metadata["task_id"] == task_id
      assert event.metadata["plan_id"] == plan_id
      # Top-level fields are deduplicated out of metadata.
      refute Map.has_key?(event.metadata, "resource_type")
      refute Map.has_key?(event.metadata, "resource_id")
    end

    test "auto_approve_skipped event persists with reason in metadata" do
      task_id = Ecto.UUID.generate()
      plan_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :plan, :auto_approve_skipped],
        %{count: 1},
        %{
          task_id: task_id,
          plan_id: plan_id,
          reason: :no_execution_assignee,
          resource_type: "plan",
          resource_id: plan_id,
          action: "auto_approve_skipped",
          actor_type: "system"
        }
      )

      [event] = Audit.list(event_type: "platform.plan.auto_approve_skipped")
      assert event.resource_type == "plan"
      assert event.resource_id == plan_id
      assert event.action == "auto_approve_skipped"
      assert event.actor_type == "system"
      # Atom reason is json-safed to a string by ensure_json_safe/1.
      assert event.metadata["reason"] == "no_execution_assignee"
      assert event.metadata["task_id"] == task_id
      assert event.metadata["plan_id"] == plan_id
    end
  end

  describe "project_files deploy bridging (task 019f5e66 stage 5)" do
    test "deployed event persists with resource pointing at the attachment" do
      source_task_id = Ecto.UUID.generate()
      target_project_id = Ecto.UUID.generate()
      attachment_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :deploy, :project_files, :deployed],
        %{system_time: System.system_time()},
        %{
          actor_type: "system",
          action: "deployed",
          resource_type: "chat_attachment",
          resource_id: attachment_id,
          source_task_id: source_task_id,
          target_project_id: target_project_id,
          folder: "Deliverables",
          filename: "Deliverables/spec.md",
          version_id: attachment_id
        }
      )

      [event] = Audit.list(event_type: "platform.deploy.project_files.deployed")
      assert event.actor_type == "system"
      assert event.action == "deployed"
      assert event.resource_type == "chat_attachment"
      assert event.resource_id == attachment_id
      assert event.metadata["source_task_id"] == source_task_id
      assert event.metadata["target_project_id"] == target_project_id
      assert event.metadata["folder"] == "Deliverables"
      assert event.metadata["filename"] == "Deliverables/spec.md"
      assert event.metadata["version_id"] == attachment_id
      # Top-level fields deduplicated out of metadata (see @top_level_keys).
      refute Map.has_key?(event.metadata, "resource_type")
      refute Map.has_key?(event.metadata, "resource_id")
      refute Map.has_key?(event.metadata, "actor_type")
      refute Map.has_key?(event.metadata, "action")
    end

    test "cross_tenant_rejected event persists with resource pointing at the target project" do
      source_task_id = Ecto.UUID.generate()
      target_project_id = Ecto.UUID.generate()
      source_workspace_id = Ecto.UUID.generate()
      target_workspace_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :deploy, :project_files, :cross_tenant_rejected],
        %{system_time: System.system_time()},
        %{
          actor_type: "system",
          action: "cross_tenant_rejected",
          resource_type: "project",
          resource_id: target_project_id,
          source_task_id: source_task_id,
          target_project_id: target_project_id,
          source_workspace_id: source_workspace_id,
          target_workspace_id: target_workspace_id
        }
      )

      [event] = Audit.list(event_type: "platform.deploy.project_files.cross_tenant_rejected")
      assert event.actor_type == "system"
      assert event.action == "cross_tenant_rejected"
      assert event.resource_type == "project"
      assert event.resource_id == target_project_id
      assert event.metadata["source_task_id"] == source_task_id
      assert event.metadata["target_project_id"] == target_project_id
      assert event.metadata["source_workspace_id"] == source_workspace_id
      assert event.metadata["target_workspace_id"] == target_workspace_id
    end

    test "both project_files events are registered on the handler" do
      events = TelemetryHandler.events()

      assert [:platform, :deploy, :project_files, :deployed] in events
      assert [:platform, :deploy, :project_files, :cross_tenant_rejected] in events
    end
  end

  describe "stage dispatch fallback bridging is retired (ADR-0046 member 9)" do
    # GUARD. Task 019f5d47 registered
    # `[:platform, :plans, :stage_dispatch, :assignee_unresolvable]` so the
    # TaskRouter's stage-responsibility fallback reached the audit trail. ADR
    # 0046 member 9 deleted the only emitter, so the registration went with it.
    test "the plans.stage_dispatch.assignee_unresolvable event is no longer registered, while its two meetings siblings still are" do
      events = TelemetryHandler.events()

      # FIX DETECTOR: re-adding the registration (or reviving the emitter and
      # its registration together) detonates here.
      refute [:platform, :plans, :stage_dispatch, :assignee_unresolvable] in events

      # POSITIVE CONTROL — scope of the deletion. Both siblings share the
      # `:assignee_unresolvable` suffix, so a removal done by grepping that
      # suffix rather than by the `:plans` namespace would take them too. They
      # are also the cheapest proof `events/0` is a populated list, which is
      # what stops the refute above passing on an empty return.
      assert [:platform, :meetings, :scribe_dispatch, :assignee_unresolvable] in events
      assert [:platform, :meetings, :triage_dispatch, :assignee_unresolvable] in events
    end
  end

  describe "orchestration.alarm_silence bridging (task 019f6791-c01b stage 3)" do
    test "alarm_silence event persists with resource pointing at the task" do
      task_id = Ecto.UUID.generate()
      runtime_id = "runtime-alarm-silence-test-#{System.unique_integer([:positive])}"
      stage_id = Ecto.UUID.generate()

      silenced_until_iso =
        DateTime.utc_now() |> DateTime.add(1800, :second) |> DateTime.to_iso8601()

      :telemetry.execute(
        [:platform, :orchestration, :alarm_silence],
        %{count: 1},
        %{
          task_id: task_id,
          stage_id: stage_id,
          silenced_until: silenced_until_iso,
          reason: "operator override — stale MCP catalog",
          runtime_id: runtime_id,
          actor_type: "system",
          resource_type: "task",
          resource_id: task_id,
          action: "silence"
        }
      )

      [event] = Audit.list(event_type: "platform.orchestration.alarm_silence")
      assert event.resource_type == "task"
      assert event.resource_id == task_id
      assert event.actor_type == "system"
      assert event.action == "silence"
      assert event.metadata["task_id"] == task_id
      assert event.metadata["stage_id"] == stage_id
      assert event.metadata["reason"] == "operator override — stale MCP catalog"
      assert event.metadata["runtime_id"] == runtime_id
      # Top-level fields are deduplicated out of metadata.
      refute Map.has_key?(event.metadata, "resource_type")
      refute Map.has_key?(event.metadata, "resource_id")
      refute Map.has_key?(event.metadata, "actor_type")
      refute Map.has_key?(event.metadata, "action")
    end

    test "handler is attached to the alarm_silence event" do
      events = TelemetryHandler.events()
      assert [:platform, :orchestration, :alarm_silence] in events
    end
  end

  describe "meeting scribe dispatch fallback bridging (task 019f5e0b)" do
    test "assignee_unresolvable event persists with resource pointing at the agent" do
      agent_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :meetings, :scribe_dispatch, :assignee_unresolvable],
        %{count: 1},
        %{
          agent_id: agent_id,
          reason: :agent_not_found,
          actor_type: "system",
          resource_type: "agent",
          resource_id: agent_id
        }
      )

      [event] = Audit.list(event_type: "platform.meetings.scribe_dispatch.assignee_unresolvable")
      assert event.resource_type == "agent"
      assert event.resource_id == agent_id
      assert event.actor_type == "system"
      # Correlation IDs remain in the metadata blob.
      assert event.metadata["agent_id"] == agent_id
      # Atom reason is json-safed to a string by ensure_json_safe/1.
      assert event.metadata["reason"] == "agent_not_found"
      # Top-level fields are deduplicated out of metadata.
      refute Map.has_key?(event.metadata, "resource_type")
      refute Map.has_key?(event.metadata, "resource_id")
      refute Map.has_key?(event.metadata, "actor_type")
    end
  end

  describe "meeting triage dispatch fallback bridging (task 019f5e2a)" do
    test "triage_dispatch event is registered in @events for the audit handler" do
      assert [:platform, :meetings, :triage_dispatch, :assignee_unresolvable] in TelemetryHandler.events()
    end

    test "assignee_unresolvable event persists with resource pointing at the agent" do
      agent_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :meetings, :triage_dispatch, :assignee_unresolvable],
        %{count: 1},
        %{
          agent_id: agent_id,
          reason: :runtime_unresolvable,
          actor_type: "system",
          resource_type: "agent",
          resource_id: agent_id
        }
      )

      [event] = Audit.list(event_type: "platform.meetings.triage_dispatch.assignee_unresolvable")
      assert event.resource_type == "agent"
      assert event.resource_id == agent_id
      assert event.actor_type == "system"
      # Correlation IDs remain in the metadata blob.
      assert event.metadata["agent_id"] == agent_id
      # Atom reason is json-safed to a string by ensure_json_safe/1.
      assert event.metadata["reason"] == "runtime_unresolvable"
      # Top-level fields are deduplicated out of metadata.
      refute Map.has_key?(event.metadata, "resource_type")
      refute Map.has_key?(event.metadata, "resource_id")
      refute Map.has_key?(event.metadata, "actor_type")
    end
  end

  describe "attach/0 idempotency across every boot-attached handler (task 019f9d80)" do
    # The seven handlers Platform.Application.start/2 attaches at boot
    # (application.ex:12-27). They are VM-global, so a test that detaches
    # one and does not restore it silences that bridge for every later
    # test in the same BEAM — and the symptom is an audit assertion that
    # passes because nothing is listening, not an error. Making attach/0
    # idempotent is what removes the reason to detach first.
    @boot_handlers [
      Platform.Audit.TelemetryHandler,
      Platform.Vault.TelemetryHandler,
      Platform.Chat.TelemetryHandler,
      Platform.Meetings.TelemetryHandler,
      Platform.Meetings.IntentCorrections.TelemetryHandler,
      Platform.Memory.TelemetryHandler,
      Platform.Accounts.ExternalAdmissionNotifier
    ]

    test "attach/0 returns :ok when the handler is already attached" do
      for module <- @boot_handlers do
        assert :ok = module.attach(), "#{inspect(module)}.attach/0 did not return :ok"

        assert :ok = module.attach(),
               "#{inspect(module)}.attach/0 is not idempotent — a second attach must be a no-op"
      end
    end

    test "a repeated attach/0 installs one handler, not two" do
      for module <- @boot_handlers do
        :ok = module.attach()
        before = handler_ids_for(module)

        assert length(before) == 1,
               "expected exactly one handler id for #{inspect(module)}, got #{inspect(before)}"

        :ok = module.attach()

        assert handler_ids_for(module) == before,
               "#{inspect(module)}.attach/0 duplicated its handler registration"
      end
    end

    test "ensure_boot_handler!/1 re-attaches a handler that is currently detached" do
      # Register the unconditional restore BEFORE detaching. This module's
      # `setup` only covers Platform.Audit.TelemetryHandler, so without
      # this line a failure on the assertion below would leave the VAULT
      # bridge detached for the rest of the BEAM — the precise leak this
      # test is about. Caught by
      # test/platform/regression/boot_telemetry_handler_detach_audit_test.exs,
      # which requires a restore registered ahead of every detach.
      assert :ok = Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Vault.TelemetryHandler)

      # The state a leaked test leaves behind: handler gone, no error
      # anywhere, later audit assertions quietly reading [].
      Platform.Vault.TelemetryHandler.detach()
      assert handler_ids_for(Platform.Vault.TelemetryHandler) == []

      assert :ok = Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Vault.TelemetryHandler)

      assert handler_ids_for(Platform.Vault.TelemetryHandler) == ["platform-vault-telemetry"]
    end

    test "ensure_boot_handler!/1 rejects a module that is not a telemetry handler" do
      assert_raise ArgumentError, ~r/does not export attach\/0/, fn ->
        Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.Event)
      end
    end
  end

  describe "supervised audit writes (task 019f9d80 stage 3)" do
    # The async historian branch spawns a Task.Supervisor child with NO
    # lifecycle tie to the emitting process. Under the shared sandbox that
    # child borrows this test's connection, so when this process exits the
    # connection is torn down underneath any child still writing.
    #
    # The property these cases pin is that the owner can WAIT for those
    # writers — which is the fix — rather than that some rescue clause
    # catches their corpses, which would be the defect.

    @burst 200

    test "a historian emit's async write is retrievable once the writers drain" do
      workspace_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :historian, :window_dispatched],
        %{token_count: 100, window_index: 1, day_bytes: 100},
        %{
          workspace_id: workspace_id,
          resource_type: "workspace",
          resource_id: workspace_id,
          corpus: :pages,
          oversize: false,
          action: "window_dispatched",
          actor_type: "system"
        }
      )

      assert :ok = Platform.SandboxHelpers.await_supervised_writes(timeout: 5_000)

      assert [%Event{} = row] =
               Audit.list(
                 event_type: "platform.historian.window_dispatched",
                 resource_id: workspace_id
               )

      assert row.action == "window_dispatched"
      assert row.actor_type == "system"
      assert row.metadata["workspace_id"] == workspace_id

      # HONEST NOTE (see notes/2026-07-26-boot-telemetry-detach.md §11):
      # this assertion also passes WITHOUT the drain, because the child
      # usually wins the race against `Audit.list/1`. It is a
      # characterization test for the async branch's persistence, not the
      # regression detector for this stage. The detector is the next case.
    end

    test "await_supervised_writes/1 returns only after every spawned writer has finished" do
      workspace_id = Ecto.UUID.generate()

      measurements = %{token_count: 100, window_index: 1, day_bytes: 100}

      metadata = %{
        workspace_id: workspace_id,
        resource_type: "workspace",
        resource_id: workspace_id,
        corpus: :pages,
        oversize: false,
        action: "window_dispatched",
        actor_type: "system"
      }

      for _ <- 1..@burst do
        :telemetry.execute([:platform, :historian, :window_dispatched], measurements, metadata)
      end

      # The condition the fix exists for: emitting outruns draining, so
      # the emitting process reaches its own teardown with live writers
      # still holding its sandbox connection.
      assert Platform.SandboxHelpers.active_children() > 0,
             "expected the #{@burst}-event burst to outrun the single shared sandbox " <>
               "connection and leave live writers behind"

      assert :ok = Platform.SandboxHelpers.await_supervised_writes(timeout: 30_000)

      assert Platform.SandboxHelpers.active_children() == 0

      rows =
        Audit.list(
          event_type: "platform.historian.window_dispatched",
          resource_id: workspace_id,
          limit: @burst * 2
        )

      assert length(rows) == @burst,
             "expected all #{@burst} supervised writes to have landed before the drain " <>
               "returned, got #{length(rows)}"
    end

    test "active_children/1 reports 0 for a supervisor that is not running" do
      # Several test setups boot a trimmed supervision tree; "not started"
      # must read as "nothing in flight" rather than crashing teardown.
      assert Platform.SandboxHelpers.active_children(:no_such_supervisor_019f9d80) == 0
    end

    test "await_supervised_writes/1 reports a timeout instead of blocking forever" do
      {:ok, pid} =
        Task.Supervisor.start_child(Platform.TaskSupervisor, fn -> Process.sleep(500) end)

      assert {:timeout, active} = Platform.SandboxHelpers.await_supervised_writes(timeout: 50)
      assert active > 0

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end
  end

  # All handler ids currently registered whose callback lives in `module`.
  # Derived from the registry rather than hardcoding @handler_id strings,
  # so it stays correct if an id is renamed. attach_many/4 registers one
  # entry per event under a single id, hence the uniq.
  defp handler_ids_for(module) do
    []
    |> :telemetry.list_handlers()
    |> Enum.filter(fn handler ->
      Function.info(handler.function, :module) == {:module, module}
    end)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end
end
