defmodule PlatformWeb.TabSwitchProbeTest do
  @moduledoc """
  Task 01a17b00 stage 1: the dev-only server probe the tab-switch harness
  loads into a dev node (`e2e/scripts/tab_switch_probe.exs`). These cases
  check that what it reports for a chat -> tasks arrival is what the
  01a166be budget test counts for the same arrival (one refresh_board, one
  count_by_scope), so the harness's tasks rows rest on a probe that has been
  compared against an independent counter, and that it keeps no data
  beyond module names, durations and counts.

  async: false: the probe uses VM-wide call tracing and telemetry.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Accounts, Repo, Tasks}

  @probe Path.expand("../../../../../e2e/scripts/tab_switch_probe.exs", __DIR__)

  setup do
    unless Code.ensure_loaded?(probe_module()), do: Code.compile_file(@probe)
    probe(:reset)
    on_exit(fn -> probe(:uninstall) end)

    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "tab_probe_#{n}@example.com",
        name: "Tab Probe #{n}",
        oidc_sub: "oidc-tab-probe-#{n}"
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    {:ok, project} = Tasks.create_project(%{name: "Probe P #{n}"})

    for i <- 1..5 do
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "probe task #{i}"})
    end

    %{user: user, project: project}
  end

  # The probe is loaded from a script at runtime, so it is called through a
  # runtime module name (a literal remote call warns at compile time).
  defp probe_module, do: Module.concat(["TabSwitchProbe"])
  defp probe(fun), do: apply(probe_module(), fun, [])

  defp conn_for(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp arrive(user) do
    {:ok, chat, _} = live(conn_for(user), ~p"/chat")
    _ = render(chat)
    probe(:reset)
    {:ok, tasks, _} = live_redirect(chat, to: ~p"/tasks")
    _ = render(tasks)
    _ = render(tasks)
    mounts = probe(:dump) |> Jason.decode!()
    {tasks, Enum.filter(mounts, &(&1["view"] == "PlatformWeb.TasksLive" and &1["connected"]))}
  end

  test "S1 arrival: one connected TasksLive mount, one board load, one count_by_scope, narrowed",
       %{user: user, project: project} do
    {:ok, _} = Accounts.put_tasks_project_pref(user.id, project.id, nil)

    {tasks, [mount]} = arrive(user)

    assert mount["pid"] == inspect(tasks.pid)
    assert mount["refresh_board"] == 1
    assert mount["count_by_scope"] == 1
    assert [%{"project" => "one"}] = mount["list_all_tasks"]
    assert is_number(mount["mount_ms"]) and mount["mount_ms"] > 0
    assert mount["arrival_queries"] > 0
  end

  test "S2 arrival: the first (only) board load is the widest one", %{user: user} do
    {_tasks, [mount]} = arrive(user)

    assert mount["refresh_board"] == 1
    assert mount["count_by_scope"] == 1
    assert [%{"project" => "all"}] = mount["list_all_tasks"]
  end

  test "queries after the first handle_event are not counted as arrival", %{user: user} do
    {tasks, [before]} = arrive(user)

    # A real event after arrival: the phone list's "show every row" hook.
    tasks |> element("#tasks-my-list") |> render_hook("tasks_my_list_rows", %{})

    [later] =
      probe(:dump)
      |> Jason.decode!()
      |> Enum.filter(&(&1["pid"] == inspect(tasks.pid)))

    assert later["arrival_queries"] == before["arrival_queries"]
    assert later["queries_by_phase"]["event"]["count"] >= 0
  end

  test "the dump carries only names, durations and counts", %{user: user} do
    keys =
      ~w(pid t0_us view connected mount_ms handle_params_ms arrival_queries arrival_query_ms
         queries_by_phase refresh_board refresh_board_ms count_by_scope list_all_tasks)

    {_tasks, [mount]} = arrive(user)
    assert Enum.sort(Map.keys(mount)) == Enum.sort(keys)
  end
end
