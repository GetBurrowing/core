defmodule Platform.Role.WebBootTest do
  @moduledoc """
  The request paths a person drives on a web node run with only the web
  child set alive (task 01a155a6 stage 4).

  This VM booted the full role, so the web node is emulated by terminating
  every background child `Platform.Supervisor` is running (the ids in
  `Platform.Role.background_ids/0`) and setting the role to `:web` with no
  cluster peer: the partition a web node is in when it boots, or when its
  peer is down. Every web child keeps running. The children are restarted on
  exit.

  The positive control shows the emulation can fire: a call into a
  background child (`TaskRouterSupervisor`) exits `:noproc` here. The paths
  under test (a chat send, a task status change, the presence, active-agent,
  lease and context reads their LiveViews make) must not.

  NOT async: it stops shared processes and sets the node role.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, ContextPlane}
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.{LeaseManager, TaskRouterSupervisor, TaskRouterWatcher}
  alias Platform.Repo
  alias Platform.Role
  alias Platform.Role.Relay
  alias Platform.Tasks

  # The consumers' original-event handlers outlive their process when it is
  # terminated without trapping exits; a handler left attached to a dead
  # consumer's missing table would raise and be detached for the rest of the
  # run. Detached here, re-attached by the consumer's own init on restart.
  @consumer_handler_ids ["context-plane-handlers"]

  setup do
    previous = Map.new([:role, :cluster_peer], &{&1, Application.fetch_env(:platform, &1)})
    background = MapSet.new(Role.background_ids())

    stopped =
      for {id, pid, _type, _mods} <- Supervisor.which_children(Platform.Supervisor),
          is_pid(pid),
          MapSet.member?(background, id),
          restartable?(id) do
        id
      end

    Enum.each(@consumer_handler_ids, &Relay.detach_many/1)
    Enum.each(stopped, &(:ok = Supervisor.terminate_child(Platform.Supervisor, &1)))

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end

      for id <- stopped do
        case Supervisor.restart_child(Platform.Supervisor, id) do
          {:ok, _} -> :ok
          {:ok, _, _} -> :ok
          {:error, :running} -> :ok
          {:error, reason} -> raise "could not restart #{inspect(id)}: #{inspect(reason)}"
        end
      end
    end)

    Application.put_env(:platform, :role, :web)
    Application.delete_env(:platform, :cluster_peer)
    :ok = Relay.attach()

    %{stopped: stopped}
  end

  # A :temporary child's spec is dropped when it is terminated, so it could
  # not be put back. Only the boot seeds are temporary, and test env runs none.
  defp restartable?(id) do
    case :supervisor.get_childspec(Platform.Supervisor, id) do
      {:ok, %{restart: :temporary}} -> false
      {:ok, _} -> true
      _ -> false
    end
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Web #{n}",
      email: "web-boot-#{n}@example.com",
      oidc_sub: "web-boot-#{n}"
    })
  end

  test "positive control: the background children are gone, so a call into one exits :noproc",
       %{stopped: stopped} do
    assert Platform.Orchestration.TaskRouterSupervisor in stopped
    assert Platform.Orchestration.LeaseManager in stopped
    assert Process.whereis(TaskRouterSupervisor) == nil

    assert {:noproc, _} =
             catch_exit(
               DynamicSupervisor.start_child(TaskRouterSupervisor, {Task, fn -> :ok end})
             )
  end

  test "a chat send, and the reads a chat LiveView makes, run without a background child" do
    user = user!()

    {:ok, space} =
      Chat.create_space(%{
        name: "Web boot",
        slug: "web-boot-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: "Avery",
        joined_at: DateTime.utc_now()
      })

    assert {:ok, message} =
             Chat.post_message(%{
               space_id: space.id,
               participant_id: participant.id,
               content_type: "text",
               content: "sent on a web node"
             })

    assert message.space_id == space.id
    assert ActiveAgentStore.get_active(space.id) == nil
    refute RuntimePresence.online?("runtime-#{System.unique_integer([:positive])}")
    assert %{} = ContextPlane.build_context_bundle(space.id)
  end

  test "a task status change, and the router and lease reads it makes, run without a background child" do
    sponsor = user!()

    {:ok, project} =
      Tasks.create_project(%{name: "Web boot #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Moved on exp",
        sponsor_user_id: sponsor.id
      })

    assert {:ok, task} = Tasks.transition_task(task, "in_progress", {:user, sponsor.id})
    assert task.status == "in_progress"

    # in_progress -> in_review runs the hook that calls force_dispatch/1. A gate
    # may refuse it; a refusal is an error tuple, never an exit.
    result = Tasks.transition_task(task, "in_review", {:user, sponsor.id})
    assert match?({:ok, _}, result) or match?({:error, _}, result), inspect(result)

    assert TaskRouterWatcher.force_dispatch(task.id) == :noop
    assert LeaseManager.get(task.id) == nil
    assert %Platform.Tasks.Task{} = Repo.get(Platform.Tasks.Task, task.id)
  end
end
