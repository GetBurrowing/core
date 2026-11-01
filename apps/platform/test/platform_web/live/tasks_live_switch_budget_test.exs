defmodule PlatformWeb.TasksLiveSwitchBudgetTest do
  @moduledoc """
  Task 01a166be: how much work a chat -> tasks tab switch does on the server.

  The tabs are `<.link navigate>` inside one `live_session`, so a switch is a
  live redirect: the old LiveView exits and the new one runs a full connected
  mount, its first `handle_params/3`, and then whatever it sent to itself
  (selection messages, the stored-project pin's replace patch, the
  preference hold/settle).

  Two counters, both read ONLY for events emitted by the arriving LiveView's
  own pid:

    * `[:platform_web, :tasks, :refresh_board, :stop]`, the span around
      `PlatformWeb.Tasks.BoardHooks.refresh_board/1`: one per board load.
    * `[:platform, :repo, :query]`: Repo queries the arrival ran.

  `:telemetry` runs handlers in the emitting process, so the handler sends
  `self()` along and the test compares it with `view.pid`. That keeps other
  processes (this test's own setup inserts, a sibling async module's
  LiveViews, the outgoing LiveView) out of the counts.

  Scenarios:

    * S1: the user has a stored tasks project, restored from the server pref.
    * S2: no stored project: the bare URL is pinned to `?project=all`.

  Stage 1 recorded the pre-fix baseline at feat/redesign 441b5571: S1 ran
  3 board loads and 75 queries per arrival, S2 1 load and 49 queries. Stage 2
  turns that into a BUDGET: one board load per arrival, and no more Repo
  queries than main runs for the same arrival (measured with this same
  harness on main ea157a735, which carries no stored preference and
  restored the project through a since-deleted client hook's
  `sidebar_select_project` replay instead):

    * main S1, arrival + replay: 2 loads, 48 + 12 = 60 queries
    * main S2, arrival:          1 load,  48 queries
    * main tasks -> chat:        0 loads, 76 queries
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}

  @refresh_stop [:platform_web, :tasks, :refresh_board, :stop]
  @repo_query [:platform, :repo, :query]
  @params_stop [:phoenix, :live_view, :handle_params, :stop]

  # Main's numbers for the same arrivals (see the moduledoc), main ea157a735.
  @main_s1_queries 60
  @main_s2_queries 48
  @main_chat_queries 76

  defp u, do: System.unique_integer([:positive])

  defp user! do
    n = u()

    Repo.insert!(%User{
      email: "switch_budget_#{n}@example.com",
      name: "Switch Budget #{n}",
      oidc_sub: "oidc-switch-budget-#{n}",
      preferences: %{"first_run_goal" => "existing"}
    })
    |> Platform.TenancyFixtures.member_of_all_orgs!()
  end

  defp backdate!(user) do
    {1, _} =
      Repo.update_all(from(x in User, where: x.id == ^user.id),
        set: [updated_at: ~N[2000-01-01 00:00:00]]
      )

    ~N[2000-01-01 00:00:00]
  end

  defp updated_at(user), do: Repo.get!(User, user.id).updated_at

  defp task_ids(tasks), do: tasks |> Enum.map(& &1.id) |> MapSet.new()

  defp project_with_tasks!(name, count) do
    {:ok, project} = Tasks.create_project(%{name: "#{name} #{u()}"})

    for i <- 1..count do
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "#{name} task #{i}"})
    end

    project
  end

  defp conn_for(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # ── counting ─────────────────────────────────────────────────────────────

  @doc false
  # Runs in the EMITTING process. It must never raise: `:telemetry` detaches
  # a raising handler VM-wide, and the counts here would then read zero
  # while unrelated suites lost their handler too. Only processes that have
  # this test in `$callers` (its LiveViews) are forwarded at all.
  def forward(event, _measurements, _metadata, %{test_pid: test_pid, tag: tag}) do
    try do
      callers = Process.get(:"$callers", [])

      if self() == test_pid or test_pid in callers do
        send(test_pid, {tag, event, self()})
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp attach_counters! do
    tag = make_ref()
    id = "tasks-switch-budget-#{inspect(self())}-#{u()}"
    config = %{test_pid: self(), tag: tag}

    :ok =
      :telemetry.attach_many(
        id,
        [@refresh_stop, @repo_query, @params_stop],
        &__MODULE__.forward/4,
        config
      )

    on_exit(fn -> :telemetry.detach(id) end)
    tag
  end

  # Settle everything the arrival sent to itself, then drain the mailbox and
  # count the events the given pid emitted. `render/1` is a synchronous call
  # into the LiveView, so every message it had queued before the call has
  # been handled when it returns; two rounds cover a handler that sends once
  # more (hold -> settled -> sync).
  defp settle_and_count(view, tag) do
    _ = render(view)
    _ = render(view)
    _ = :sys.get_state(view.pid)
    drain(tag, view.pid, %{refresh_board: 0, queries: 0, handle_params: 0})
  end

  defp drain(tag, pid, acc) do
    receive do
      {^tag, @refresh_stop, ^pid} -> drain(tag, pid, Map.update!(acc, :refresh_board, &(&1 + 1)))
      {^tag, @repo_query, ^pid} -> drain(tag, pid, Map.update!(acc, :queries, &(&1 + 1)))
      {^tag, @params_stop, ^pid} -> drain(tag, pid, Map.update!(acc, :handle_params, &(&1 + 1)))
      {^tag, _event, _other_pid} -> drain(tag, pid, acc)
    after
      0 -> acc
    end
  end

  # Drop everything counted so far (the /chat mount, setup inserts).
  defp flush(tag) do
    receive do
      {^tag, _event, _pid} -> flush(tag)
    after
      0 -> :ok
    end
  end

  defp chat_to_tasks(user, tag, path \\ ~p"/tasks") do
    {:ok, chat, _html} = live(conn_for(user), ~p"/chat")
    _ = render(chat)
    flush(tag)
    navigate(chat, path, tag)
  end

  defp navigate(chat, path, tag) do
    # The pin's replace patch is issued inside the join, so the LiveView
    # re-runs handle_params in-process and the test client sees no separate
    # patch; `tasks_pin_url` flipping to false is the evidence it ran.
    {:ok, tasks, _html} = live_redirect(chat, to: path)
    counts = settle_and_count(tasks, tag)
    {tasks, assigns(tasks), counts}
  end

  setup do
    user = user!()
    p = project_with_tasks!("Budget P", 6)
    q = project_with_tasks!("Budget Q", 4)
    tag = attach_counters!()
    %{user: user, p: p, q: q, tag: tag}
  end

  test "the handler is attached under a unique id and forwards only this test's pids", %{
    tag: tag
  } do
    # Positive control: an emission from the test process itself counts.
    :telemetry.execute(@refresh_stop, %{duration: 1}, %{})
    assert_receive {^tag, @refresh_stop, pid} when pid == self()

    # A process outside this test's caller chain is never forwarded.
    {stranger, ref} =
      spawn_monitor(fn ->
        Process.delete(:"$callers")
        :telemetry.execute(@refresh_stop, %{duration: 1}, %{})
      end)

    assert_receive {:DOWN, ^ref, :process, ^stranger, :normal}
    refute_received {^tag, @refresh_stop, ^stranger}
  end

  test "S1: one board load per arrival with a stored project, and nothing written", %{
    user: user,
    p: p,
    tag: tag
  } do
    {:ok, _} = Accounts.put_tasks_project_pref(user.id, p.id, nil)
    pinned = backdate!(user)

    {tasks, assigns, counts} = chat_to_tasks(user, tag)

    # Positive controls: the stored project is restored and the bare URL was
    # pinned (rung 15b behaviour), so the counts are about a real arrival on
    # project P.
    assert assigns.selected_project_id == p.id
    assert assigns.tasks_pin_url == false
    assert task_ids(assigns.all_tasks) == task_ids(Tasks.list_all_tasks(project_id: p.id))

    # Was 3 at 441b5571: mount's widest load, the selection cond, and
    # select_project/2 from {:sidebar_project_selected, _}.
    assert counts.refresh_board == 1, "refresh_board passes: #{inspect(counts)}"
    assert counts.queries <= @main_s1_queries, "Repo queries: #{inspect(counts)}"

    # The pin's replace patch re-entered handle_params (2 calls) and that
    # second pass found nothing changed: still one board load.
    assert counts.handle_params == 2, "handle_params calls: #{inspect(counts)}"

    # An arrival that resolves to the stored selection writes nothing.
    assert updated_at(user) == pinned
    assert Accounts.tasks_project_pref(Repo.get!(User, user.id)) == {p.id, nil}

    # A later selection still goes through the message path and is stored.
    flush(tag)
    send(tasks.pid, {:sidebar_project_selected, nil})
    later = settle_and_count(tasks, tag)
    assert later.refresh_board == 1
    assert Accounts.tasks_project_pref(Repo.get!(User, user.id)) == {nil, nil}
  end

  test "S1 with a stored epic: still one board load", %{user: user, p: p, tag: tag} do
    {:ok, epic} = Tasks.create_epic(%{project_id: p.id, name: "Budget Epic #{u()}"})
    {:ok, _} = Accounts.put_tasks_project_pref(user.id, p.id, epic.id)

    {_tasks, assigns, counts} = chat_to_tasks(user, tag)

    assert assigns.selected_project_id == p.id
    assert assigns.selected_epic_id == epic.id
    assert counts.refresh_board == 1, "refresh_board passes: #{inspect(counts)}"
  end

  test "S1 through the resumed URL (?project=P): one board load", %{
    user: user,
    p: p,
    tag: tag
  } do
    {:ok, _} = Accounts.put_tasks_project_pref(user.id, p.id, nil)

    {_tasks, assigns, counts} = chat_to_tasks(user, tag, ~p"/tasks?project=#{p.id}")

    assert assigns.selected_project_id == p.id
    assert counts.refresh_board == 1, "refresh_board passes: #{inspect(counts)}"
    assert counts.queries <= @main_s1_queries, "Repo queries: #{inspect(counts)}"
  end

  test "an archived stored project falls back to All in the same single load", %{
    user: user,
    p: p,
    tag: tag
  } do
    {:ok, _} = Accounts.put_tasks_project_pref(user.id, p.id, nil)
    {:ok, _} = Tasks.update_project(p, %{archived_at: DateTime.utc_now()})

    {_tasks, assigns, counts} = chat_to_tasks(user, tag)

    assert assigns.selected_project_id == nil
    assert counts.refresh_board == 1, "refresh_board passes: #{inspect(counts)}"
    # The stored value heals.
    assert Accounts.tasks_project_pref(Repo.get!(User, user.id)) == {nil, nil}
  end

  test "S2: one board load with no stored project", %{
    user: user,
    tag: tag
  } do
    pinned = backdate!(user)

    {_tasks, assigns, counts} = chat_to_tasks(user, tag)

    assert assigns.selected_project_id == nil
    assert assigns.tasks_pin_url == false

    assert counts.refresh_board == 1, "refresh_board passes: #{inspect(counts)}"
    assert counts.queries <= @main_s2_queries, "Repo queries: #{inspect(counts)}"
    assert counts.handle_params == 2, "handle_params calls: #{inspect(counts)}"
    assert updated_at(user) == pinned
  end

  test "a board PubSub event on /tasks refreshes exactly once", %{user: user, p: p, tag: tag} do
    {:ok, _} = Accounts.put_tasks_project_pref(user.id, p.id, nil)
    {tasks, _assigns, _counts} = chat_to_tasks(user, tag)
    flush(tag)

    # The board event shape, broadcast on the real topic. An existing task is
    # used so no create_task broadcast of its own can land mid-count.
    [task | _] = Tasks.list_all_tasks(project_id: p.id)
    :ok = Phoenix.PubSub.broadcast(Platform.PubSub, Tasks.board_topic(), {:task_created, task})
    counts = settle_and_count(tasks, tag)

    assert counts.refresh_board == 1, "refresh_board passes: #{inspect(counts)}"
    assert task.id in task_ids(assigns(tasks).all_tasks)
  end

  test "five rapid chat <-> tasks navigations end on the stored project", %{
    user: user,
    p: p,
    tag: tag
  } do
    {:ok, _} = Accounts.put_tasks_project_pref(user.id, p.id, nil)
    {:ok, chat, _html} = live(conn_for(user), ~p"/chat")

    {:ok, tasks, _} = live_redirect(chat, to: ~p"/tasks")
    {:ok, chat, _} = live_redirect(tasks, to: ~p"/chat")
    {:ok, tasks, _} = live_redirect(chat, to: ~p"/tasks")
    {:ok, chat, _} = live_redirect(tasks, to: ~p"/chat")
    _ = render(chat)
    flush(tag)
    {tasks, assigns, counts} = navigate(chat, ~p"/tasks", tag)

    assert Process.alive?(tasks.pid)
    assert assigns.selected_project_id == p.id
    assert task_ids(assigns.all_tasks) == task_ids(Tasks.list_all_tasks(project_id: p.id))
    assert counts.refresh_board == 1, "refresh_board passes: #{inspect(counts)}"
  end

  test "a direct /tasks/:task_id arrival still loads the board once", %{
    user: user,
    p: p,
    tag: tag
  } do
    [task | _] = Tasks.list_all_tasks(project_id: p.id)

    {_tasks, assigns, counts} = chat_to_tasks(user, tag, ~p"/tasks/#{task.id}")

    assert assigns.show_detail == true
    assert is_list(assigns.all_tasks) and assigns.all_tasks != []
    assert counts.refresh_board == 1, "refresh_board passes: #{inspect(counts)}"
  end

  test "the dead render of /tasks still renders a board", %{user: user, p: p} do
    {:ok, _} = Accounts.put_tasks_project_pref(user.id, p.id, nil)

    html = conn_for(user) |> get(~p"/tasks") |> html_response(200)

    assert html =~ "Budget P task 1"
  end

  # The phone "my tasks" list renders on top of the board, and with no
  # project its rows are every board task: stage 3 measured a desktop S2 join
  # reply of 651 KB vs main's 353 KB, and the review measured phone S2
  # slower than main. A join renders none of them at lg (the list is
  # `display: none` there) and a screenful on a phone.
  defp my_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#tasks-my-list [data-role=tasks-my-row]")
    |> Enum.count()
  end

  test "S2 desktop arrival: the hidden phone list ships no rows until it can show", %{
    user: user,
    tag: tag
  } do
    # Positive control: a join without the desktop flag (phone, LiveViewTest
    # default) renders one row per board task.
    {phone, phone_assigns, _} = chat_to_tasks(user, tag)
    board = length(phone_assigns.filtered_tasks)
    assert board >= 10
    assert my_rows(phone) == board

    desktop_user = user |> conn_for() |> put_connect_params(%{"viewport_lg" => true})
    {:ok, chat, _html} = live(desktop_user, ~p"/chat")
    flush(tag)
    {desktop, assigns, counts} = navigate(chat, ~p"/tasks", tag)

    # Same board, same single load and query budget, no phone rows.
    assert length(assigns.filtered_tasks) == board
    assert counts.refresh_board == 1, "refresh_board passes: #{inspect(counts)}"
    assert counts.queries <= @main_s2_queries, "Repo queries: #{inspect(counts)}"
    assert has_element?(desktop, "#tasks-my-list[data-rows=none]")
    assert my_rows(desktop) == 0
    assert byte_size(render(desktop)) < byte_size(render(phone))

    # The window narrows below lg: the hook asks once and the rows render.
    desktop |> element("#tasks-my-list") |> render_hook("tasks_my_list_rows", %{})
    assert my_rows(desktop) == board
    assert has_element?(desktop, "#tasks-my-list[data-rows=all]")
  end

  test "S2 phone arrival: the list ships one screenful of rows until scrolled", %{
    user: user,
    tag: tag
  } do
    # More board tasks than a phone screenful (the setup seeds 10).
    project_with_tasks!("Budget R", 25)

    # Positive control: a join with no viewport flag renders every row.
    {all, all_assigns, _} = chat_to_tasks(user, tag)
    board = length(all_assigns.filtered_tasks)
    assert board > 30
    assert my_rows(all) == board
    refute has_element?(all, "#tasks-my-list-more")

    phone_user = user |> conn_for() |> put_connect_params(%{"viewport_lg" => false})
    {:ok, chat, _html} = live(phone_user, ~p"/chat")
    flush(tag)
    {phone, assigns, counts} = navigate(chat, ~p"/tasks", tag)

    assert length(assigns.filtered_tasks) == board
    assert counts.refresh_board == 1, "refresh_board passes: #{inspect(counts)}"
    assert counts.queries <= @main_s2_queries, "Repo queries: #{inspect(counts)}"
    assert has_element?(phone, "#tasks-my-list[data-rows=some]")
    assert has_element?(phone, "#tasks-my-list-more")

    # The first 30, in the list's own order.
    first_ids =
      phone
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#tasks-my-list [data-role=tasks-my-row]")
      |> Enum.map(&(LazyHTML.attribute(&1, "data-row-task-id") |> List.first()))

    assert first_ids == assigns.filtered_tasks |> Enum.take(30) |> Enum.map(& &1.id)
    assert byte_size(render(phone)) < byte_size(render(all))

    # Scrolled near the end: the hook asks once and every row renders.
    phone |> element("#tasks-my-list") |> render_hook("tasks_my_list_rows", %{})
    assert my_rows(phone) == board
    assert has_element?(phone, "#tasks-my-list[data-rows=all]")
    refute has_element?(phone, "#tasks-my-list-more")
  end

  test "tasks -> chat: the chat arrival loads no task board", %{user: user, p: p, tag: tag} do
    {:ok, _} = Accounts.put_tasks_project_pref(user.id, p.id, nil)
    {tasks, _assigns, _counts} = chat_to_tasks(user, tag)

    {:ok, chat, _html} = live_redirect(tasks, to: ~p"/chat")
    counts = settle_and_count(chat, tag)

    assert counts.refresh_board == 0, "refresh_board passes: #{inspect(counts)}"
    assert counts.queries <= @main_chat_queries, "Repo queries: #{inspect(counts)}"
  end
end
