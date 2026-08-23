defmodule PlatformWeb.TasksLiveExecSpaceHolderTest do
  @moduledoc """
  Task `01a01a1b` stage 4 — a project switch on `/tasks` must release only
  TasksLive's own hold on `chat:space:<execution space>`.

  ## The defect this pins closed

  `PlatformWeb.ShellLive` is an `on_mount` hook on `live_session
  :authenticated` (`router.ex`), so it runs **in the same pid** as
  `PlatformWeb.TasksLive`. Its presence branch subscribes
  `chat:space:<id>` for every space in the viewer's presence set. Before this
  stage, `TasksLive.resubscribe_execution_space(nil)` called
  `Chat.PubSub.unsubscribe/1` — a bare `Registry.unregister/2`, which drops
  **every** registration the pid holds for a topic. A project switch therefore
  destroyed presence's registration too, silently and for the rest of the
  session. The comment above `select_project/2` asserted the opposite, on the
  strength of a survey that covered ONE FILE. File scope is not process scope.

  ## Measurement discipline

  Counts are read **directly** off `Registry.lookup(Platform.PubSub, topic)`,
  filtered to the LiveView pid. Deliberately NOT through a `ChatPubSub` helper,
  NOT through `:chat_space_holders` and NOT through
  `:subscribed_execution_space_id` — all three are written by the code under
  test, so reading them to check it would be circular.

  **A count of 1 is not delivery.** `Registry.unregister/2` is not the only way
  a topic can go quiet, so the retained registration is also exercised: a real
  broadcast is fired on it after the switch and arrival **at the LiveView
  process** is observed with `:erlang.trace/3`. That is the claim — the pid
  still receives — rather than a proxy for it. A never-held control topic is
  broadcast on in the same test so the trace cannot be a rubber stamp.

  Fixture names are invented; `core` is a PUBLIC repo.

  `async: false` — `Platform.PubSub`'s registry is VM-global.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp create_viewer! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "exec-holder-#{n}@example.com",
      name: "Holder Viewer",
      oidc_sub: "oidc-exec-holder-#{n}"
    })
    |> Platform.TenancyFixtures.member_of_all_orgs!()
  end

  defp create_project! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Fernbrook Ledger #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:example/fernbrook.git"
      })

    project
  end

  defp create_task!(project, title) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "in_progress",
        priority: "medium"
      })

    task
  end

  # Membership is what puts a space in `Chat.list_viewer_presence_space_ids/1`,
  # which is what makes ShellLive's presence branch take a `:presence` hold on
  # it. Without this row the whole test is vacuous: there would be no second
  # holder for the old over-broad unsubscribe to have destroyed.
  defp join!(space_id, %User{} = user) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: "Holder Viewer",
        joined_at: DateTime.utc_now()
      })

    p
  end

  # ── Measurement ───────────────────────────────────────────────────────────

  # `Registry.lookup/2` on a `:duplicate` registry returns one `{pid, value}`
  # entry PER registration, so a length-after-filter is the exact count.
  defp registration_count(pid, space_id) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.space_topic(space_id))
    |> Enum.count(fn {entry_pid, _value} -> entry_pid == pid end)
  end

  # Both of ShellLive's async loaders resolve by `send/2` before returning, so
  # a completed `render_async/1` implies the presence message is already in the
  # mailbox; the trailing `render/1` is the round trip that drains it. Never
  # `Process.sleep/1`, which would pin the box's timing rather than the code's.
  defp settle(view) do
    _ = render_async(view)
    _ = render(view)
    _ = :sys.get_state(view.pid)
    view
  end

  defp sidebar_click(view, event, params) do
    _ = render_click(with_target(view, "#tasks-sidebar"), event, params)
    render(view)
  end

  describe "project switch releases :tasks_exec without taking presence's hold with it" do
    test "one registration survives the switch, and it still delivers", %{conn: conn} do
      viewer = create_viewer!()
      project_a = create_project!()
      project_b = create_project!()
      task_a = create_task!(project_a, "Marlowe Freight Audit")
      _task_b = create_task!(project_b, "Quillon Intake Rewrite")

      {:ok, exec_space} = ExecutionSpace.find_or_create(task_a.id)
      join!(exec_space.id, viewer)

      # CONTROL — a space the viewer never joins and no task points at, so no
      # surface on this pid ever holds it. It exists to prove the trace-based
      # delivery observation below can report absence.
      {:ok, control_space} =
        Chat.create_space(%{
          name: "Alder Control",
          slug: "alder-control-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, view, _html} =
        conn
        |> init_test_session(current_user_id: viewer.id)
        |> live(~p"/tasks/#{task_a.id}")

      view = settle(view)
      pid = view.pid

      # ANTI-VACUITY, both halves separately. If either holder were absent the
      # post-switch count of 1 would be true for the wrong reason: with no
      # presence hold it would be 0 (and this test would pass only once the
      # bug returned as a different bug), and with no `:tasks_exec` hold the
      # switch would release nothing at all.
      assert exec_space.id in Chat.list_viewer_presence_space_ids(viewer),
             "anti-vacuity failed: the execution space is not in the viewer's presence " <>
               "set, so ShellLive's presence branch never held it and the switch has " <>
               "no second holder to spare"

      assert :sys.get_state(pid).socket.assigns[:subscribed_execution_space_id] ==
               exec_space.id,
             "anti-vacuity failed: TasksLive never took the execution-space hold, so " <>
               "the project switch below releases nothing"

      # Two holders, ONE registration — SpaceTopics subscribes only when the
      # holder set was empty. Recorded as an equality so a regression to the
      # raw double-subscribe moves this line deliberately.
      assert registration_count(pid, exec_space.id) == 1

      # POSITIVE CONTROL: the same broadcast DOES reach the pid before the
      # switch, so a delivery observation after it is not measuring a dead
      # instrument.
      assert_exec_message_delivered(pid, exec_space.id, "Marlowe control ping")

      _ = sidebar_click(view, "sidebar_select_project", %{"id" => project_b.id})
      _ = :sys.get_state(pid)

      # THE FIX. Was 0 before this stage: `resubscribe_execution_space(nil)`
      # was `Registry.unregister/2` and took presence's registration with it.
      # Now `:tasks_exec` releases only its own hold and `:presence` keeps the
      # topic alive.
      assert registration_count(pid, exec_space.id) == 1,
             "expected presence's hold to survive the project switch; a 0 here means " <>
               "TasksLive's release destroyed a registration it does not own"

      # A count of 1 is not delivery. Prove the retained registration still
      # carries traffic to the process.
      assert_exec_message_delivered(pid, exec_space.id, "Marlowe post-switch ping")

      # And that the observation can say no: the pid holds nothing on the
      # control topic, and nothing arrives from it.
      assert registration_count(pid, control_space.id) == 0
      refute_exec_message_delivered(pid, control_space.id, "Alder control ping")
    end
  end

  # Fires a REAL message post through the same path the app uses, then observes
  # arrival at the LiveView process itself via the VM's receive trace. Tracing
  # the pid is the only observation that is about delivery rather than about
  # some downstream render, which after the switch is not drawn at all.
  defp assert_exec_message_delivered(pid, space_id, body) do
    :erlang.trace(pid, true, [:receive])

    try do
      {:ok, _} = ExecutionSpace.post_engagement(space_id, body)
      assert_receive {:trace, ^pid, :receive, {:new_message, _}}, 1_000
    after
      :erlang.trace(pid, false, [:receive])
    end
  end

  defp refute_exec_message_delivered(pid, space_id, body) do
    :erlang.trace(pid, true, [:receive])

    try do
      {:ok, _} = ExecutionSpace.post_engagement(space_id, body)
      refute_receive {:trace, ^pid, :receive, {:new_message, _}}, 300
    after
      :erlang.trace(pid, false, [:receive])
    end
  end
end
