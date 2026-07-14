defmodule Platform.Audit.TelemetryHandlerTest do
  use Platform.DataCase

  import Platform.TenancyFixtures

  alias Platform.Audit
  alias Platform.Audit.Event
  alias Platform.Audit.TelemetryHandler

  setup do
    # Ensure handler is attached for each test (Application.start may not
    # run in the test env the way we expect).
    TelemetryHandler.detach()
    TelemetryHandler.attach()
    on_exit(fn -> TelemetryHandler.detach() end)
    :ok
  end

  # Snapshot the current set of Platform.TaskSupervisor child pids. Used
  # by the historian bridging tests to observe async dispatch without
  # depending on the DB row (spawned children aren't in the DataCase
  # sandbox owner chain, so their Repo.insert raises OwnershipError and
  # the handler swallows it — see telemetry_handler.ex:rescue clause).
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

  describe "actor_org_id threading (ADR 0040)" do
    test "actor_org_id from telemetry metadata persists to audit_events.actor_org_id" do
      user_id = Ecto.UUID.generate()
      org_id = fabrikam_org_id()

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
          actor_org_id: fabrikam_org_id(),
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
      peer_org_id = tenant_org_id("soylent")

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
    # Task children spawn under Platform.TaskSupervisor, which is NOT in
    # the DataCase sandbox owner chain. We can't observe the DB row from
    # the test process, so these tests observe the SPAWN itself: monitor
    # the child pid, wait for :DOWN, then assert either (a) the row was
    # inserted (if the child inherited the sandbox — happens when we call
    # Sandbox.allow) or (b) that Logger emitted the drop/rescue message.
    # The plan (stage 4) covers full end-to-end persistence via IEx e2e.

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

    test "handler is attached to all five historian events" do
      events = TelemetryHandler.events()

      historian_events =
        Enum.filter(events, fn
          [:platform, :historian | _] -> true
          _ -> false
        end)

      assert length(historian_events) == 5

      assert [:platform, :historian, :pass_started] in historian_events
      assert [:platform, :historian, :pass_completed] in historian_events
      assert [:platform, :historian, :window_dispatched] in historian_events
      assert [:platform, :historian, :cursor_advanced] in historian_events
      assert [:platform, :historian, :error] in historian_events
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

  describe "stage dispatch fallback bridging (task 019f5d47)" do
    test "assignee_unresolvable event persists with resource pointing at the stage" do
      stage_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()
      fallback_runtime_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :plans, :stage_dispatch, :assignee_unresolvable],
        %{count: 1},
        %{
          stage_id: stage_id,
          task_id: task_id,
          responsibility: "designer",
          fallback_runtime_id: fallback_runtime_id,
          reason: :role_unresolvable,
          actor_type: "system",
          resource_type: "stage",
          resource_id: stage_id
        }
      )

      [event] = Audit.list(event_type: "platform.plans.stage_dispatch.assignee_unresolvable")
      assert event.resource_type == "stage"
      assert event.resource_id == stage_id
      assert event.actor_type == "system"
      # Correlation IDs remain in the metadata blob.
      assert event.metadata["stage_id"] == stage_id
      assert event.metadata["task_id"] == task_id
      assert event.metadata["responsibility"] == "designer"
      assert event.metadata["fallback_runtime_id"] == fallback_runtime_id
      # Atom reason is json-safed to a string by ensure_json_safe/1.
      assert event.metadata["reason"] == "role_unresolvable"
      # Top-level fields are deduplicated out of metadata.
      refute Map.has_key?(event.metadata, "resource_type")
      refute Map.has_key?(event.metadata, "resource_id")
      refute Map.has_key?(event.metadata, "actor_type")
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
end
