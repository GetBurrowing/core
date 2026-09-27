# Pins that the CASE TEMPLATE runs `Platform.SandboxHelpers.stop_task_routers_or_warn/1`
# (task 01a0d4d6 stage 2). The sibling `sandbox_helpers_stop_task_routers_test.exs`
# calls the helper itself, so it stays green if the `Platform.DataCase` wiring is
# deleted. This file does not call it.
#
# The one test starts a supervised router and returns with it still running.
# Only the DataCase teardown can end it. The verdict is read in `setup_all`'s
# `on_exit`, which runs after every per-test teardown. It asserts two things:
#
#   * the router is gone, and
#   * its `terminate/2` row ("Task router stopped for task …") was BROADCAST.
#     `Chat.post_message/2` broadcasts only after its insert commits, so the
#     broadcast shows the write landed on a live connection. The row itself was
#     rolled back with the sandbox by then, so the broadcast is what can still
#     be observed.
#
# Delete the helper call from `Platform.DataCase` and nothing stops the router,
# so the verdict fails on "router still running".
defmodule Platform.SandboxHelpersStopTaskRoutersWiringTest do
  use Platform.DataCase, async: false

  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.TaskRouterSupervisor
  alias Platform.Tasks

  setup_all do
    witness = spawn(fn -> witness_loop(%{task_id: nil, router: nil, seen: false}) end)

    on_exit(fn ->
      ref = make_ref()
      send(witness, {:report, self(), ref})

      report =
        receive do
          {^ref, report} -> report
        after
          5_000 -> flunk("the witness process did not answer")
        end

      Process.exit(witness, :kill)

      assert is_pid(report.router), "the test never registered its router with the witness"

      if Process.alive?(report.router) do
        # Clean up before failing. The owner is gone, so this terminate/2 cannot
        # write anything; its rescue absorbs that.
        TaskRouterSupervisor.stop_assignment(report.task_id)

        flunk("""
        The TaskRouter started by the test was still running after the
        Platform.DataCase teardown. The case template no longer stops task
        routers before Sandbox.stop_owner/1. See
        Platform.SandboxHelpers.stop_task_routers_or_warn/1.
        """)
      end

      assert report.seen,
             "the router is gone but its terminate/2 row was never broadcast, so its " <>
               "post_log did not land on a live connection"
    end)

    %{witness: witness}
  end

  test "the case template stops a router the test left running", %{witness: witness} do
    {:ok, project} = Tasks.create_project(%{name: "Router wiring #{unique()}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Router wiring"})

    assignee = %{type: :federated, id: "runtime-wiring-#{unique()}"}
    {:ok, router} = TaskRouterSupervisor.start_assignment(task.id, assignee)
    :ok = sync_router(task.id)

    assert %{id: space_id} = ExecutionSpace.find_by_task_id(task.id)

    ref = make_ref()
    send(witness, {:watch, self(), ref, space_id, task.id, router})
    assert_receive {^ref, :watching}

    # Returns with the router still running, on purpose.
    assert Process.alive?(router)
  end

  defp witness_loop(state) do
    receive do
      {:watch, from, ref, space_id, task_id, router} ->
        :ok = Phoenix.PubSub.subscribe(Platform.PubSub, ChatPubSub.space_topic(space_id))
        send(from, {ref, :watching})
        witness_loop(%{state | task_id: task_id, router: router})

      {:new_message, %{content: content}} ->
        seen = state.seen or content == "Task router stopped for task #{state.task_id}"
        witness_loop(%{state | seen: seen})

      {:report, from, ref} ->
        send(from, {ref, state})
        witness_loop(state)

      _other ->
        witness_loop(state)
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
