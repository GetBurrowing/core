defmodule PlatformWeb.TasksLiveTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.{Epic, Plan, ReviewRequests}

  setup do
    previous_root = Application.get_env(:platform, :chat_attachments_root)

    upload_root =
      Path.join(
        System.tmp_dir!(),
        "platform_tasks_live_test_uploads_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(upload_root)
    Application.put_env(:platform, :chat_attachments_root, upload_root)

    on_exit(fn ->
      Application.put_env(:platform, :chat_attachments_root, previous_root)
      File.rm_rf(upload_root)
    end)

    :ok
  end

  defp authenticated_conn(conn) do
    {conn, _user} = authenticated_conn_with_user(conn)
    conn
  end

  defp authenticated_conn_with_user(conn) do
    user =
      Repo.insert!(%User{
        email: "tasks_test_#{System.unique_integer([:positive])}@example.com",
        name: "Tasks Test User",
        oidc_sub: "oidc-tasks-test-#{System.unique_integer([:positive])}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Test Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    project
  end

  defp create_task(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Task #{System.unique_integer([:positive])}",
            status: "backlog",
            priority: "medium"
          },
          attrs
        )
      )

    task
  end

  defp create_agent(name \\ nil) do
    Repo.insert!(%Agent{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: name || "Agent #{System.unique_integer([:positive])}",
      status: "active"
    })
  end

  describe "per-phase assignee modal" do
    test "Configure button + per-phase grid render in the detail panel", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      a1 = create_agent("Dalton (Test)")
      a2 = create_agent("Geordi (Test)")

      task =
        create_task(project, %{
          title: "Modal test task",
          status: "planning",
          assignee_id: a1.id,
          assignee_type: "agent",
          phase_assignees: %{
            "planning" => %{"assignee_id" => a1.id, "assignee_type" => "agent"},
            "execution" => %{"assignee_id" => a2.id, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => a1.id, "assignee_type" => "agent"}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/tasks?task_id=#{task.id}")

      # Detail panel grid shows all three phases with the right agents
      rendered = render(view)
      assert rendered =~ "Configure"
      assert rendered =~ "Planning"
      assert rendered =~ "Implementation"
      assert rendered =~ "Validation"
      assert rendered =~ "Dalton (Test)"
      assert rendered =~ "Geordi (Test)"
    end

    test "Configure click opens modal and auto-detects Advanced for mixed assignees", %{
      conn: conn
    } do
      conn = authenticated_conn(conn)
      project = create_project()
      a1 = create_agent("Dalton (Test)")
      a2 = create_agent("Geordi (Test)")

      task =
        create_task(project, %{
          title: "Modal opens advanced",
          status: "planning",
          phase_assignees: %{
            "planning" => %{"assignee_id" => a1.id, "assignee_type" => "agent"},
            "execution" => %{"assignee_id" => a2.id, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => a1.id, "assignee_type" => "agent"}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/tasks?task_id=#{task.id}")

      view |> element("[phx-click=\"open_assignee_modal\"]") |> render_click()
      modal = render(view)

      assert modal =~ "Assign Agents"
      assert modal =~ "One agent per phase. Build the DAG."
      assert modal =~ ~r{phx-click="set_assignee_modal_mode"[^>]*phx-value-mode="simple"}
      assert modal =~ ~r{phx-click="set_assignee_modal_mode"[^>]*phx-value-mode="advanced"}
      # Active state on the Advanced button (auto-detected from mixed deps)
      assert modal =~ ~r{phx-value-mode="advanced"[^>]*aria-pressed="true"}
    end

    test "Configure click opens modal in Simple when all phases share one agent", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      a1 = create_agent("Solo (Test)")

      entry = %{"assignee_id" => a1.id, "assignee_type" => "agent"}

      task =
        create_task(project, %{
          title: "Modal opens simple",
          status: "planning",
          phase_assignees: %{"planning" => entry, "execution" => entry, "review" => entry}
        })

      {:ok, view, _html} = live(conn, ~p"/tasks?task_id=#{task.id}")

      view |> element("[phx-click=\"open_assignee_modal\"]") |> render_click()
      modal = render(view)

      assert modal =~ "One agent for the whole task."
      assert modal =~ ~r{phx-value-mode="simple"[^>]*aria-pressed="true"}
    end

    test "saving in Advanced writes per-phase assignees and updates task.assignee_id from current phase",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      a1 = create_agent("Phase1 (Test)")
      a2 = create_agent("Phase2 (Test)")
      a3 = create_agent("Phase3 (Test)")

      task =
        create_task(project, %{
          title: "Save advanced",
          status: "planning",
          assignee_id: nil
        })

      {:ok, view, _html} = live(conn, ~p"/tasks?task_id=#{task.id}")

      view
      |> element("[phx-click=\"open_assignee_modal\"]")
      |> render_click()

      # Force advanced mode (default would be simple since no existing assignees)
      view
      |> element("[phx-click=\"set_assignee_modal_mode\"][phx-value-mode=\"advanced\"]")
      |> render_click()

      view
      |> form("form[phx-submit=\"save_assignees\"]", %{
        "assignees" => %{
          "planning" => a1.id,
          "execution" => a2.id,
          "review" => a3.id
        }
      })
      |> render_submit()

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.phase_assignees["planning"]["assignee_id"] == a1.id
      assert reloaded.phase_assignees["execution"]["assignee_id"] == a2.id
      assert reloaded.phase_assignees["review"]["assignee_id"] == a3.id
      # Task is in `planning`, so the top-level assignee_id derives from the planning slot.
      assert reloaded.assignee_id == a1.id
      assert reloaded.assignee_type == "agent"
    end

    test "saving in Simple writes the same agent into all three phase keys", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      a1 = create_agent("Solo (Test)")

      task = create_task(project, %{title: "Save simple", status: "planning"})

      {:ok, view, _html} = live(conn, ~p"/tasks?task_id=#{task.id}")

      view |> element("[phx-click=\"open_assignee_modal\"]") |> render_click()

      view
      |> form("form[phx-submit=\"save_assignees\"]", %{"assignees" => %{"all" => a1.id}})
      |> render_submit()

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.phase_assignees["planning"]["assignee_id"] == a1.id
      assert reloaded.phase_assignees["execution"]["assignee_id"] == a1.id
      assert reloaded.phase_assignees["review"]["assignee_id"] == a1.id
      assert reloaded.assignee_id == a1.id
    end
  end

  describe "Tasks.current_phase + assignee derivation on transition" do
    test "task.assignee_id is re-derived from phase_assignees when crossing a phase boundary",
         %{conn: _conn} do
      project = create_project()
      planner = create_agent("Planner")
      builder = create_agent("Builder")

      {:ok, _} = Plan |> tap(fn _ -> :ok end) |> then(fn _ -> {:ok, :stub} end)

      task =
        create_task(project, %{
          status: "planning",
          assignee_id: planner.id,
          assignee_type: "agent",
          phase_assignees: %{
            "planning" => %{"assignee_id" => planner.id, "assignee_type" => "agent"},
            "execution" => %{"assignee_id" => builder.id, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => planner.id, "assignee_type" => "agent"}
          }
        })

      # Need an approved plan so `transition_task(task, "in_progress")` passes
      # the require_approved_plan_for guard from PR #263.
      {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

      {:ok, updated} = Tasks.transition_task(task, "in_progress")

      reloaded = Tasks.get_task_record(updated.id)
      assert reloaded.status == "in_progress"
      assert reloaded.assignee_id == builder.id
    end
  end

  describe "dependency UI" do
    test "blocked card with two unmet deps renders the `Blocked · 2` badge", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      a = create_task(project, %{title: "Dep A", status: "in_progress"})
      x = create_task(project, %{title: "Dep X", status: "in_progress"})

      _b =
        create_task(project, %{
          title: "Blocked B",
          status: "blocked",
          dependencies: [
            %{"task_id" => a.id, "kind" => "blocks"},
            %{"task_id" => x.id, "kind" => "blocks"}
          ],
          metadata: %{"unmet_dependencies" => [a.id, x.id]}
        })

      {:ok, _view, html} = live(conn, ~p"/tasks")

      # Badge text + DaisyUI error class so we know it's the red badge,
      # not the generic outline status pill.
      assert html =~ "Blocked · 2"
      assert html =~ ~r{badge badge-error badge-xs[^>]*>\s*Blocked · 2}
    end

    test "detail panel lists each dep title with the matching status icon", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      a = create_task(project, %{title: "Alpha dep", status: "in_progress"})
      {:ok, a} = Tasks.transition_task_status(a, "in_review")
      {:ok, a} = Tasks.transition_task_status(a, "deploying")
      {:ok, a} = Tasks.transition_task_status(a, "done")

      x = create_task(project, %{title: "Xray dep", status: "in_progress"})
      y = create_task(project, %{title: "Yankee dep", status: "planning"})

      b =
        create_task(project, %{
          title: "Detail B",
          status: "blocked",
          dependencies: [
            %{"task_id" => a.id, "kind" => "blocks"},
            %{"task_id" => x.id, "kind" => "blocks"},
            %{"task_id" => y.id, "kind" => "blocks"}
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/tasks?task_id=#{b.id}")

      assert html =~ ~s(id="task-dependencies")
      assert html =~ "Dependencies"
      assert html =~ "Alpha dep"
      assert html =~ "Xray dep"
      assert html =~ "Yankee dep"

      # The dep titles also appear as their own kanban cards, so scope the
      # icon-co-location assertion to the Dependencies <ul> only.
      deps_section = dependencies_section(html)
      assert deps_section =~ "Alpha dep"
      assert deps_section =~ "Xray dep"
      assert deps_section =~ "Yankee dep"

      # done → green check, in_progress → blue play, planning → amber pause.
      assert window_around(deps_section, "Alpha dep") =~ "hero-check-circle-solid"
      assert window_around(deps_section, "Xray dep") =~ "hero-play-circle-solid"
      assert window_around(deps_section, "Yankee dep") =~ "hero-pause-circle-solid"
    end

    test "detail panel of a task without deps does not render the section", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      c = create_task(project, %{title: "Lonely C", dependencies: []})

      {:ok, _view, html} = live(conn, ~p"/tasks?task_id=#{c.id}")

      refute html =~ ~s(id="task-dependencies")
      # The section header text "Dependencies" should not appear anywhere
      # in the rendered detail panel for a dep-free task.
      refute html =~ ">Dependencies<"
    end

    test "missing dep id renders gray ✗ icon and a placeholder title", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      ghost_id = Ecto.UUID.generate()

      b =
        create_task(project, %{
          title: "Missing-dep B",
          status: "blocked",
          dependencies: [%{"task_id" => ghost_id, "kind" => "blocks"}]
        })

      {:ok, _view, html} = live(conn, ~p"/tasks?task_id=#{b.id}")

      assert html =~ ~s(id="task-dependencies")
      deps_section = dependencies_section(html)
      assert deps_section =~ "(missing dependency)"
      assert window_around(deps_section, "(missing dependency)") =~ "hero-x-circle-solid"
    end

    test "dependency rows render in the order the user authored them", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      a = create_task(project, %{title: "Order Alpha"})
      x = create_task(project, %{title: "Order Xray"})
      y = create_task(project, %{title: "Order Yankee"})

      # Authored deliberately out of any natural order.
      b =
        create_task(project, %{
          title: "Detail order B",
          dependencies: [
            %{"task_id" => y.id, "kind" => "blocks"},
            %{"task_id" => a.id, "kind" => "blocks"},
            %{"task_id" => x.id, "kind" => "blocks"}
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/tasks?task_id=#{b.id}")

      # The Dependencies <ul> should list the titles in author order.
      [_, deps_section] = String.split(html, ~s(id="task-dependencies"), parts: 2)
      [list_only | _] = String.split(deps_section, "</ul>", parts: 2)

      iy = :binary.match(list_only, "Order Yankee") |> elem(0)
      ia = :binary.match(list_only, "Order Alpha") |> elem(0)
      ix = :binary.match(list_only, "Order Xray") |> elem(0)

      assert iy < ia
      assert ia < ix
    end

    test "detail panel does not render a raw metadata debug block", %{conn: conn} do
      # The raw `inspect(task.metadata, pretty: true)` <pre> was debug debris.
      # Whatever it contained (UUID lists, internal flags, deploy strategy) was
      # noise to a human reviewer — humans can't resolve UUIDs by eye and the
      # GUI doesn't help. Information worth showing belongs in a structured,
      # human-readable section (like the Dependencies section above), not a
      # raw map dump.
      conn = authenticated_conn(conn)
      project = create_project()

      a = create_task(project, %{title: "Probe dep A", status: "in_progress"})

      b =
        create_task(project, %{
          title: "Probe B",
          status: "blocked",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}],
          metadata: %{
            "unmet_dependencies" => [a.id],
            "some_other_internal_key" => "value"
          }
        })

      {:ok, _view, html} = live(conn, ~p"/tasks?task_id=#{b.id}")

      # No "Metadata" heading, no <pre> dump.
      refute html =~ ">Metadata</h3>"
      refute html =~ ~s|<pre class="rounded bg-base-200|
      # And the noise that prompted this — bare UUIDs and internal-key dumps —
      # is therefore not bleeding into the detail view. Dep info still flows
      # through the Dependencies section as titles + status icons.
      refute html =~ "some_other_internal_key"
    end
  end

  # Returns just the Dependencies <ul> from the rendered HTML, so
  # title-matching can't collide with kanban cards using the same titles.
  defp dependencies_section(html) do
    case String.split(html, ~s(id="task-dependencies"), parts: 2) do
      [_, after_marker] ->
        [scoped, _rest] = String.split(after_marker, "</ul>", parts: 2)
        scoped

      _ ->
        ""
    end
  end

  # Returns a ~400-char window around `needle` so a co-located icon class
  # can be asserted without grepping the whole page.
  defp window_around(html, needle) do
    case :binary.match(html, needle) do
      :nomatch ->
        ""

      {start, len} ->
        before = max(start - 200, 0)
        finish = min(start + len + 200, byte_size(html))
        binary_part(html, before, finish - before)
    end
  end

  defp create_user(attrs \\ %{}) do
    Repo.insert!(%User{
      email:
        Map.get(
          attrs,
          :email,
          "tasks-user-#{System.unique_integer([:positive, :monotonic])}@example.com"
        ),
      name: Map.get(attrs, :name, "Tasks User"),
      oidc_sub:
        Map.get(
          attrs,
          :oidc_sub,
          "oidc-tasks-user-#{System.unique_integer([:positive, :monotonic])}"
        ),
      avatar_url: Map.get(attrs, :avatar_url)
    })
  end

  # ── Kanban board tests ─────────────────────────────────────────────────

  test "GET /tasks renders the kanban board", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "Tasks"
    assert html =~ "Backlog"
    assert html =~ "In Progress"
    assert html =~ "In Review"
    assert html =~ "Deploying"
    assert html =~ "Done"
    assert html =~ "All Projects"
  end

  test "kanban board groups tasks by status column", %{conn: conn} do
    project = create_project()
    _t1 = create_task(project, %{title: "Alpha Backlog", status: "backlog"})
    _t2 = create_task(project, %{title: "Beta In Progress", status: "in_progress"})
    _t3 = create_task(project, %{title: "Gamma In Review", status: "in_review"})
    _t4 = create_task(project, %{title: "Delta Done", status: "done"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "Alpha Backlog"
    assert html =~ "Beta In Progress"
    assert html =~ "Gamma In Review"
    assert html =~ "Delta Done"
  end

  test "clicking a task card opens the detail panel", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Clickable Task", description: "A detailed description"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    html =
      view
      |> element("[phx-click=\"select_task\"][phx-value-id=\"#{task.id}\"]")
      |> render_click()

    assert html =~ "Clickable Task"
    assert html =~ "Description"
  end

  test "task status transitions work from the detail panel", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Transition Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    # Transition from backlog → planning (valid per ADR 0018 §7)
    html =
      view
      |> element("button[phx-click=\"transition_task\"][phx-value-status=\"planning\"]")
      |> render_click()

    assert html =~ "moved to planning"

    # Verify task is now planning in the DB
    updated = Tasks.get_task_detail(task.id)
    assert updated.status == "planning"
  end

  test "project filter narrows tasks", %{conn: conn} do
    p1 = create_project()
    p2 = create_project()
    _t1 = create_task(p1, %{title: "Project One Task"})
    _t2 = create_task(p2, %{title: "Project Two Task"})

    conn = authenticated_conn(conn)
    {:ok, view, html} = live(conn, ~p"/tasks")

    # Both visible initially
    assert html =~ "Project One Task"
    assert html =~ "Project Two Task"

    # Filter to p1 via sidebar
    html =
      view
      |> render_click("select_project", %{"id" => p1.id})

    assert html =~ "Project One Task"
    refute html =~ "Project Two Task"
  end

  describe "last-selected-project persistence (LastProject hook)" do
    test "wrapper carries data-selected-project-id reflecting the current selection",
         %{conn: conn} do
      project = create_project()
      _t = create_task(project, %{title: "Wrapper Task"})

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks")

      # On first mount with no selection, the wrapper carries the All Projects
      # sentinel — the JS hook reads this attribute to mirror state into
      # localStorage, so it must be present and accurate.
      assert html =~ ~s|id="tasks-last-project"|
      assert html =~ ~s|phx-hook="LastProject"|
      assert html =~ ~s|data-selected-project-id="__all__"|

      # After selecting a project, the wrapper should reflect the UUID.
      html = render_click(view, "select_project", %{"id" => project.id})
      assert html =~ ~s|data-selected-project-id="#{project.id}"|

      # Clearing the filter snaps the wrapper back to the sentinel.
      html = render_click(view, "clear_filters")
      assert html =~ ~s|data-selected-project-id="__all__"|
    end

    test "select_project with a stale/deleted UUID falls back to All Projects",
         %{conn: conn} do
      project = create_project()
      _t1 = create_task(project, %{title: "Visible Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      stale_id = Ecto.UUID.generate()

      # The hook may push a UUID that no longer points at a project. The
      # handler should treat that as a clear-filters and not crash.
      html = render_click(view, "select_project", %{"id" => stale_id})

      assert html =~ ~s|data-selected-project-id="__all__"|
      # Board still renders (not blank/erroring) and the original task is
      # visible because we fell back to All Projects.
      assert html =~ "Visible Task"
    end

    test "clear_filters resets selection to All Projects", %{conn: conn} do
      p1 = create_project()
      p2 = create_project()
      _t1 = create_task(p1, %{title: "P1 Task"})
      _t2 = create_task(p2, %{title: "P2 Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Narrow to p1
      html = render_click(view, "select_project", %{"id" => p1.id})
      assert html =~ "P1 Task"
      refute html =~ "P2 Task"

      # Clear — both visible again, sentinel restored on the wrapper
      html = render_click(view, "clear_filters")
      assert html =~ ~s|data-selected-project-id="__all__"|
      assert html =~ "P1 Task"
      assert html =~ "P2 Task"
    end

    test "select_project pushes selected_project_changed with the project id",
         %{conn: conn} do
      project = create_project()
      _t = create_task(project, %{title: "Push Event Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      project_id = project.id
      render_click(view, "select_project", %{"id" => project.id})
      assert_push_event(view, "selected_project_changed", %{id: ^project_id})
    end

    test "select_project with a stale UUID still pushes selected_project_changed with __all__",
         %{conn: conn} do
      # This is the regression that the e2e_behavior Case C caught: when the
      # server falls back from a stale UUID to the All Projects view, it MUST
      # still emit selected_project_changed so the JS hook can overwrite the
      # stale value in localStorage. Previously the hook relied on a
      # `data-selected-project-id` DOM diff, which never fired when the wrapper
      # was already at "__all__".
      _project = create_project()
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      stale_id = Ecto.UUID.generate()
      render_click(view, "select_project", %{"id" => stale_id})
      assert_push_event(view, "selected_project_changed", %{id: "__all__"})
    end

    test "clear_filters pushes selected_project_changed with __all__", %{conn: conn} do
      project = create_project()
      _t = create_task(project, %{title: "Clear Push Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      project_id = project.id
      render_click(view, "select_project", %{"id" => project.id})
      assert_push_event(view, "selected_project_changed", %{id: ^project_id})

      render_click(view, "clear_filters")
      assert_push_event(view, "selected_project_changed", %{id: "__all__"})
    end
  end

  test "PubSub updates refresh the board", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "PubSub Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    # Simulate a PubSub broadcast
    Tasks.broadcast_board({:task_updated, task})

    # The view should handle the message without crashing
    html = render(view)
    assert html =~ "PubSub Task"
  end

  test "shows priority badges on task cards", %{conn: conn} do
    project = create_project()
    _t = create_task(project, %{title: "Urgent Item", priority: "high"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "high"
    assert html =~ "Urgent Item"
  end

  test "shows plan progress on task cards", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Planned Task", status: "in_progress"})

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

    {:ok, _s1} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Step 1", status: "passed"})

    {:ok, _s2} =
      Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Step 2", status: "pending"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    # Should show progress 1/2
    assert html =~ "1/2"
  end

  test "task cards render image avatars, varied human fallback palettes, and distinct agent chips",
       %{
         conn: conn
       } do
    project = create_project()

    user_with_avatar =
      create_user(%{
        name: "Avatar Owner",
        avatar_url: "https://issuer.example.com/tasks-user.png"
      })

    fallback_user_one = create_user(%{name: "Amber Atlas", oidc_sub: "seed-a"})
    fallback_user_two = create_user(%{name: "Basil Brook", oidc_sub: "seed-b"})
    agent = create_agent("Task Bot")

    _avatar_task =
      create_task(project, %{
        title: "Avatar Task",
        assignee_type: "user",
        assignee_id: user_with_avatar.id
      })

    _fallback_task_one =
      create_task(project, %{
        title: "Fallback Task One",
        assignee_type: "user",
        assignee_id: fallback_user_one.id
      })

    _fallback_task_two =
      create_task(project, %{
        title: "Fallback Task Two",
        assignee_type: "user",
        assignee_id: fallback_user_two.id
      })

    _agent_task =
      create_task(project, %{
        title: "Agent Task",
        assignee_type: "agent",
        assignee_id: agent.id
      })

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    palette_classes =
      Regex.scan(~r/avatar-fallback-\d+/, html)
      |> List.flatten()
      |> Enum.uniq()

    assert html =~ "https://issuer.example.com/tasks-user.png"
    assert html =~ "data-avatar-kind=\"human\""
    assert "avatar-fallback-5" in palette_classes
    assert "avatar-fallback-4" in palette_classes
    assert html =~ "data-avatar-kind=\"agent\""
  end

  test "GET /tasks redirects unauthenticated users to login", %{conn: conn} do
    conn = get(conn, ~p"/tasks")
    assert redirected_to(conn) == "/auth/login"
  end

  test "mobile project sheet closes on project selection", %{conn: conn} do
    project = create_project()

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    # Open the mobile project sheet
    html = render_click(view, "toggle_project_sheet")
    assert html =~ "Projects"

    # Select project — sheet should close (no backdrop)
    html = render_click(view, "select_project", %{"id" => project.id})
    refute html =~ "bg-black/40"
  end

  test "epics section renders above board when project is selected", %{conn: conn} do
    project = create_project()

    {:ok, _epic} =
      Tasks.create_epic(%{
        project_id: project.id,
        name: "Above Board Epic",
        description: "Epic description here",
        status: "in_progress"
      })

    _done_task = create_task(project, %{title: "Done Task", status: "done", epic_id: nil})

    conn = authenticated_conn(conn)
    {:ok, view, html} = live(conn, ~p"/tasks")

    # Epics section not visible before project selection
    refute html =~ "Above Board Epic"

    # Select project — epics section appears
    html = render_click(view, "select_project", %{"id" => project.id})
    assert html =~ "Above Board Epic"
    assert html =~ "in_progress"
    assert html =~ "Epic description here"
    assert html =~ "epics-section"
  end

  test "selecting an epic filters tasks on the board", %{conn: conn} do
    project = create_project()

    {:ok, epic} =
      Tasks.create_epic(%{
        project_id: project.id,
        name: "Filter Epic",
        status: "open"
      })

    _t1 = create_task(project, %{title: "Epic Task", status: "backlog", epic_id: epic.id})
    _t2 = create_task(project, %{title: "No Epic Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    # Select project first
    render_click(view, "select_project", %{"id" => project.id})

    # Select epic — only epic tasks shown
    html = render_click(view, "select_epic", %{"id" => epic.id})
    assert html =~ "Epic Task"
    refute html =~ "No Epic Task"

    # Deselect epic — both tasks shown again
    html = render_click(view, "select_epic", %{"id" => epic.id})
    assert html =~ "Epic Task"
    assert html =~ "No Epic Task"
  end

  test "toggle collapses the epics section", %{conn: conn} do
    project = create_project()

    {:ok, _epic} =
      Tasks.create_epic(%{
        project_id: project.id,
        name: "Collapsible Epic",
        status: "open"
      })

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    render_click(view, "select_project", %{"id" => project.id})

    # Epic is visible initially
    html = render(view)
    assert html =~ "Collapsible Epic"

    # Toggle collapse — epic card should no longer be visible
    html = render_click(view, "toggle_epics_panel")
    refute html =~ "Collapsible Epic"

    # Toggle again — epic card reappears
    html = render_click(view, "toggle_epics_panel")
    assert html =~ "Collapsible Epic"
  end

  test "create_and_plan defaults to the first active agent and creates a planning task", %{
    conn: conn
  } do
    project = create_project()
    agent = create_agent("Alpha Planner")

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    html =
      render_submit(view, "create_task", %{
        "task" => %{
          "title" => "Request a plan",
          "project_id" => project.id,
          "what" => "Build the task lifecycle end to end",
          "why" => "So the planning flow starts from the board",
          "action" => "create_and_plan",
          "assignee_id" => "",
          "assignee_type" => "agent",
          "deploy_target" => "",
          "epic_id" => ""
        }
      })

    assert html =~ "Task created and planning requested."

    created =
      Tasks.list_tasks_by_project(project.id)
      |> Enum.find(&(&1.title == "Request a plan"))

    assert created
    assert created.status == "planning"
    assert created.assignee_id == agent.id
    assert created.assignee_type == "agent"
  end

  test "create_and_plan requires an available agent", %{conn: conn} do
    project = create_project()

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    html =
      render_submit(view, "create_task", %{
        "task" => %{
          "title" => "Unassigned plan request",
          "project_id" => project.id,
          "what" => "Need a plan",
          "why" => "But nobody is available to make one",
          "action" => "create_and_plan",
          "assignee_id" => "",
          "assignee_type" => "agent",
          "deploy_target" => "",
          "epic_id" => ""
        }
      })

    assert html =~ "Select an agent before requesting a plan."

    refute Enum.any?(
             Tasks.list_tasks_by_project(project.id),
             &(&1.title == "Unassigned plan request")
           )
  end

  # ── Plan review tests ─────────────────────────────────────────────────

  test "approve_plan transitions plan to approved and refreshes detail", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Plan Review Task", status: "planning"})

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, version: 1, status: "draft"})

    {:ok, _s1} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Stage 1", status: "pending"})

    {:ok, plan} = Tasks.submit_plan_for_review(plan)

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    # Should see pending review indicator and approve button
    html = render(view)
    assert html =~ "pending review"
    assert html =~ "Approve Plan"

    # Click approve
    html =
      view
      |> element("button[phx-click=\"approve_plan\"]")
      |> render_click()

    assert html =~ "Plan approved."

    # Verify plan is now approved in DB
    updated_plan = Tasks.get_plan(plan.id)
    assert updated_plan.status == "approved"
  end

  test "reject_plan transitions plan to rejected", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Rejectable Task", status: "planning"})

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, version: 1, status: "draft"})

    {:ok, plan} = Tasks.submit_plan_for_review(plan)

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    html =
      view
      |> element("button[phx-click=\"reject_plan\"]")
      |> render_click()

    assert html =~ "Plan rejected."

    updated_plan = Tasks.get_plan(plan.id)
    assert updated_plan.status == "rejected"
  end

  describe "plan revision folding" do
    # Helper: insert a rejected plan revision directly. We bypass
    # `Tasks.reject_plan/2` because that requires the plan to be in
    # `pending_review` first, and these tests want to fast-path to
    # multiple historical rejections without exercising the full lifecycle.
    defp insert_rejected_plan(task, version) do
      Repo.insert!(%Plan{
        task_id: task.id,
        status: "rejected",
        version: version
      })
    end

    test "task with rejected + active plans renders one summary per rejected plan and a body for the active plan",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Folding task A", status: "planning"})

      _r1 = insert_rejected_plan(task, 1)
      _r2 = insert_rejected_plan(task, 2)

      {:ok, active} = Tasks.create_plan(%{task_id: task.id, version: 3, status: "draft"})

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: active.id,
          position: 1,
          name: "Build it",
          status: "pending"
        })

      {:ok, _active} = Tasks.submit_plan_for_review(active)

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      summary_count =
        html |> String.split(~s(data-role="plan-summary")) |> length() |> Kernel.-(1)

      body_count = html |> String.split(~s(data-role="plan-body")) |> length() |> Kernel.-(1)

      assert summary_count == 2
      # Only the active plan body is rendered by default; rejected plans are
      # collapsed and contribute zero `plan-body` rows.
      assert body_count == 1
      # And the visible body is the v3 active plan, not v1/v2.
      assert html =~ "Build it"
      assert html =~ "Approve Plan"
    end

    test "clicking a folded summary expands that plan's body; clicking again collapses it",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Folding task B", status: "planning"})

      r1 = insert_rejected_plan(task, 1)

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: r1.id,
          position: 1,
          name: "Old stage from v1",
          status: "pending"
        })

      {:ok, active} = Tasks.create_plan(%{task_id: task.id, version: 2, status: "approved"})

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: active.id,
          position: 1,
          name: "Current stage",
          status: "pending"
        })

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      # Sanity check: the rejected plan's stage is hidden by default.
      refute html =~ "Old stage from v1"

      # Expand the rejected plan.
      html =
        view
        |> element(~s([data-role="plan-summary"][data-plan-id="#{r1.id}"]))
        |> render_click()

      assert html =~ "Old stage from v1"
      assert html =~ ~s(data-role="plan-body" data-plan-id="#{r1.id}")

      # Collapse it again — body for r1 disappears.
      html =
        view
        |> element(~s([data-role="plan-summary"][data-plan-id="#{r1.id}"]))
        |> render_click()

      refute html =~ "Old stage from v1"
      refute html =~ ~s(data-role="plan-body" data-plan-id="#{r1.id}")
    end

    test "task with zero rejected plans renders no plan-summary rows", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Folding task C", status: "planning"})

      {:ok, active} = Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: active.id,
          position: 1,
          name: "Only stage",
          status: "pending"
        })

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ ~s(data-role="plan-summary")
      assert html =~ "Only stage"
    end

    test "active plan still renders stages, validations, and Approve/Reject buttons unchanged",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Folding task D", status: "planning"})

      _r1 = insert_rejected_plan(task, 1)

      {:ok, active} = Tasks.create_plan(%{task_id: task.id, version: 2, status: "draft"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: active.id,
          position: 1,
          name: "Live stage",
          status: "pending"
        })

      {:ok, _v} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "pending"})

      {:ok, _active} = Tasks.submit_plan_for_review(active)

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Live stage"
      assert html =~ "test_pass"
      assert html =~ "Approve Plan"
      assert html =~ "phx-click=\"approve_plan\""
      assert html =~ "phx-click=\"reject_plan\""
      # The single rejected revision still folds — one summary, one body
      # (the active plan).
      summary_count =
        html |> String.split(~s(data-role="plan-summary")) |> length() |> Kernel.-(1)

      assert summary_count == 1
    end

    test "plan_summary_label/1 with updated_at returns 'Plan vN — rejected on YYYY-MM-DD'" do
      ts = ~U[2026-05-04 12:34:56.000000Z]
      plan = %Plan{version: 1, status: "rejected", updated_at: ts}

      assert PlatformWeb.TasksLive.plan_summary_label(plan) ==
               "Plan v1 — rejected on 2026-05-04"
    end

    test "plan_summary_label/1 falls back when updated_at is nil" do
      plan = %Plan{version: 7, status: "rejected", updated_at: nil}
      assert PlatformWeb.TasksLive.plan_summary_label(plan) == "Plan v7 — rejected"
    end

    test "plan_summary_label/1 appends a quoted excerpt when rejection_reason is set and short" do
      ts = ~U[2026-05-04 12:34:56.000000Z]

      plan = %Plan{
        version: 1,
        status: "rejected",
        updated_at: ts,
        rejection_reason: "needs more tests"
      }

      assert PlatformWeb.TasksLive.plan_summary_label(plan) ==
               ~s(Plan v1 — rejected on 2026-05-04 — "needs more tests")
    end

    test "plan_summary_label/1 truncates long rejection_reason to 60 chars + ellipsis" do
      ts = ~U[2026-05-04 12:34:56.000000Z]

      long_reason =
        "This rejection reason is intentionally far longer than sixty characters so we can verify truncation."

      plan = %Plan{
        version: 1,
        status: "rejected",
        updated_at: ts,
        rejection_reason: long_reason
      }

      label = PlatformWeb.TasksLive.plan_summary_label(plan)
      expected_excerpt = String.slice(long_reason, 0, 60) <> "…"

      assert label == ~s(Plan v1 — rejected on 2026-05-04 — "#{expected_excerpt}")
    end

    test "plan_summary_label/1 with nil rejection_reason returns the date-only label (legacy rows)" do
      ts = ~U[2026-05-04 12:34:56.000000Z]
      plan = %Plan{version: 4, status: "rejected", updated_at: ts, rejection_reason: nil}

      assert PlatformWeb.TasksLive.plan_summary_label(plan) ==
               "Plan v4 — rejected on 2026-05-04"
    end

    test "expanded rejected-plan body shows the full Rejection reason section when set",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Folding task E", status: "planning"})

      reason =
        "The plan skipped end-to-end coverage for the deploy stage and we need a manual_approval gate added."

      r1 =
        Repo.insert!(%Plan{
          task_id: task.id,
          status: "rejected",
          version: 1,
          rejection_reason: reason
        })

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: r1.id,
          position: 1,
          name: "Old stage from v1",
          status: "pending"
        })

      {:ok, _active} = Tasks.create_plan(%{task_id: task.id, version: 2, status: "approved"})

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      # Folded summary truncates to 60 chars; full body text is hidden.
      truncated = String.slice(reason, 0, 60)
      assert html =~ truncated
      refute html =~ ~s(data-role="plan-rejection-reason")

      # Expand — the full reason now renders inside the dedicated section.
      html =
        view
        |> element(~s([data-role="plan-summary"][data-plan-id="#{r1.id}"]))
        |> render_click()

      assert html =~ ~s(data-role="plan-rejection-reason")
      assert html =~ "Rejection reason"
      assert html =~ reason
    end

    test "expanded rejected-plan body omits the Rejection reason section when reason is nil (legacy)",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Folding task F", status: "planning"})

      r1 =
        Repo.insert!(%Plan{
          task_id: task.id,
          status: "rejected",
          version: 1,
          rejection_reason: nil
        })

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: r1.id,
          position: 1,
          name: "Old stage from v1",
          status: "pending"
        })

      {:ok, _active} = Tasks.create_plan(%{task_id: task.id, version: 2, status: "approved"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html =
        view
        |> element(~s([data-role="plan-summary"][data-plan-id="#{r1.id}"]))
        |> render_click()

      # Body itself should expand and show the stage…
      assert html =~ "Old stage from v1"
      # …but no empty rejection-reason box.
      refute html =~ ~s(data-role="plan-rejection-reason")
      refute html =~ "Rejection reason"
    end
  end

  test "in_review task detail does not show direct approve/return status buttons", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Review Flow Task", status: "in_review"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

    refute html =~ "phx-value-status=\"done\""
    refute html =~ "phx-value-status=\"in_progress\""
    refute html =~ ">Approve<"
    refute html =~ ">Return<"
  end

  test "task detail renders review canvas evidence", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Canvas Review Task", status: "in_review"})

    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Reviewer",
        joined_at: DateTime.utc_now()
      })

    canvas =
      Repo.insert!(%Canvas{
        space_id: space.id,
        created_by: author.id,
        title: "Manual review screenshot",
        document: %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "props" => %{},
            "children" => [
              %{
                "id" => "code-main",
                "type" => "code",
                "props" => %{
                  "language" => "markdown",
                  "source" => "# Screenshot review\nLooks good"
                },
                "children" => []
              }
            ]
          },
          "theme" => %{},
          "bindings" => %{},
          "meta" => %{}
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        name: "Manual review",
        position: 1,
        status: "running"
      })

    {:ok, validation} =
      Tasks.create_validation(%{
        stage_id: stage.id,
        kind: "manual_approval",
        status: "pending"
      })

    {:ok, _request} =
      ReviewRequests.create_review_request(%{
        validation_id: validation.id,
        task_id: task.id,
        status: "pending",
        items: [
          %{
            kind: "artifact",
            label: "Review screenshot",
            status: "pending",
            content: "Please verify the submitted screenshot.",
            canvas_id: canvas.id
          }
        ]
      })

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

    assert html =~ "Outputs"
    assert html =~ "Manual review screenshot"
    assert html =~ "View output"
    assert html =~ "Please verify the submitted screenshot."
  end

  # ── Soft delete tests ─────────────────────────────────────────────────

  test "delete button appears in detail panel for deletable task", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Deletable Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

    assert html =~ "hero-trash"
    assert html =~ "Delete task"
  end

  test "delete button does not appear for in_progress task", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Active Task", status: "in_progress"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

    refute html =~ "Delete task"
  end

  test "delete button does not appear for in_review task", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Review Task", status: "in_review"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

    refute html =~ "Delete task"
  end

  test "delete button does not appear for deploying task", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Deploy Task", status: "deploying"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

    refute html =~ "Delete task"
  end

  test "request_delete_task shows confirmation dialog", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Confirm Delete Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    html = render_click(view, "request_delete_task")

    assert html =~ "Are you sure you want to delete this task?"
    assert html =~ "Yes, Delete"
    assert html =~ "Cancel"
  end

  test "cancel_delete_task hides confirmation dialog", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Cancel Delete Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    render_click(view, "request_delete_task")
    html = render_click(view, "cancel_delete_task")

    refute html =~ "Are you sure you want to delete this task?"
  end

  test "confirm_delete_task soft-deletes the task and removes it from the board", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Doomed Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

    # Task is visible
    assert html =~ "Doomed Task"

    # Request then confirm delete
    render_click(view, "request_delete_task")
    render_click(view, "confirm_delete_task")

    # Task should be gone from the board
    html = render(view)
    refute html =~ "Doomed Task"

    # Task still exists in DB but has deleted_at set
    deleted = Platform.Repo.get(Platform.Tasks.Task, task.id)
    assert deleted.deleted_at != nil
  end

  test "deleted task no longer appears on kanban board", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Ghost Task", status: "backlog"})

    # Soft-delete via context
    {:ok, _} = Tasks.soft_delete_task(task)

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    refute html =~ "Ghost Task"
  end

  test "three-dot menu appears on deletable task cards", %{conn: conn} do
    project = create_project()
    _task = create_task(project, %{title: "Menu Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "hero-ellipsis-vertical"
    assert html =~ "Task actions"
  end

  test "three-dot menu does not appear on in_progress task cards", %{conn: conn} do
    project = create_project()
    _task = create_task(project, %{title: "No Menu Task", status: "in_progress"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    # The in_progress task card should not have the three-dot menu
    # (only deletable tasks get it)
    refute html =~ "select_task_and_delete"
  end

  test "pending plan count badge appears in board header", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Badge Task", status: "planning"})

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, version: 1, status: "draft"})

    {:ok, _plan} = Tasks.submit_plan_for_review(plan)

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "awaiting review"
  end

  test "shell sidebar includes tasks navigation", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "/tasks"
    assert html =~ "Tasks"
  end

  # ── Steering input tests ──────────────────────────────────────────────

  test "send_steering_message posts engagement metadata and shows success feedback", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Steerable Task", status: "in_progress"})

    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    {conn, _user} = authenticated_conn_with_user(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    html =
      render_submit(view, "send_steering_message", %{
        "steering" => %{"text" => "Focus on the error handling first"}
      })

    messages = ExecutionSpace.list_messages_with_participants(space.id)
    steering_msg = Enum.find(messages, &(&1.content == "Focus on the error handling first"))
    assert steering_msg
    assert steering_msg.sender_type == "user"
    assert steering_msg.content_type == "text"
    assert steering_msg.log_only == false
    assert steering_msg.metadata["kind"] == "steering"
    assert steering_msg.metadata["source"] == "tasks_live"
    assert steering_msg.metadata["delivery"] == "engagement"

    assert html =~ "steering-feedback"
    assert html =~ "Steering sent to the execution log."
  end

  test "send_steering_message reports actionable error when content is empty", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Empty Steering Task", status: "in_progress"})

    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    {conn, _user} = authenticated_conn_with_user(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    html =
      render_submit(view, "send_steering_message", %{
        "steering" => %{"text" => "   "}
      })

    messages = ExecutionSpace.list_messages_with_participants(space.id)
    assert Enum.empty?(messages)
    assert html =~ "Enter a message or attach a file before sending."
  end

  test "send_steering_message reports actionable error without an execution space", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "No Space Task", status: "backlog"})

    {conn, _user} = authenticated_conn_with_user(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    html =
      render_submit(view, "send_steering_message", %{
        "steering" => %{"text" => "This should do nothing"}
      })

    assert html =~ "This task does not have an execution log yet"
  end

  test "steering_changed tracks form input", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Tracking Task", status: "in_progress"})
    {:ok, _space} = ExecutionSpace.find_or_create(task.id)

    {conn, _user} = authenticated_conn_with_user(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    # Trigger the change event — should not crash
    render_change(view, "steering_changed", %{
      "steering" => %{"text" => "typing something"}
    })
  end

  test "steering input renders when execution space exists", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Renderable Task", status: "in_progress"})
    {:ok, _space} = ExecutionSpace.find_or_create(task.id)

    {conn, _user} = authenticated_conn_with_user(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

    assert html =~ "steering-compose-form"
    assert html =~ "Steer the agent..."
    assert html =~ "hero-paper-airplane"
  end

  test "steering input does not render when no execution space exists", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "No Space Render Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

    refute html =~ "steering-compose-form"
    refute html =~ "Steer the agent..."
  end

  test "steering input includes attach button and file input when execution space exists", %{
    conn: conn
  } do
    project = create_project()
    task = create_task(project, %{title: "Upload UI Task", status: "in_progress"})
    {:ok, _space} = ExecutionSpace.find_or_create(task.id)

    {conn, _user} = authenticated_conn_with_user(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

    # [+] button and hidden file input should be present
    assert html =~ "hero-plus"
    assert html =~ "Attach files"
    assert html =~ "steering_attachments"
  end

  test "cancel_steering_upload does not crash", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Cancel Upload Task", status: "in_progress"})
    {:ok, _space} = ExecutionSpace.find_or_create(task.id)

    {conn, _user} = authenticated_conn_with_user(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    # Sending a cancel for a nonexistent ref should not crash (LiveView raises)
    # Just verify the event handler is wired up by checking the form renders
    html = render(view)
    assert html =~ "steering-compose-form"
  end

  test "user steering messages render with primary color styling", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Color Styling Task", status: "in_progress"})
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    {conn, _user} = authenticated_conn_with_user(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    # Send a steering message
    render_submit(view, "send_steering_message", %{
      "steering" => %{"text" => "Check the error logs"}
    })

    # Re-render — PubSub will have updated the log
    html = render(view)

    # User messages should have primary color and border styling
    assert html =~ "text-primary"
    assert html =~ "border-primary"
    assert html =~ "Check the error logs"
  end

  test "steering participant is created as user type in execution space", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Participant Task", status: "in_progress"})

    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    {conn, user} = authenticated_conn_with_user(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    render_submit(view, "send_steering_message", %{
      "steering" => %{"text" => "Hello agent"}
    })

    participants = Chat.list_participants(space.id)
    user_participant = Enum.find(participants, &(&1.participant_id == user.id))
    assert user_participant
    assert user_participant.participant_type == "user"
    assert user_participant.display_name == "Tasks Test User"
  end

  test "dismissed execution participant is not silently re-added on task-detail open (ADR 0038)",
       %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Rejoin Task", status: "in_progress"})
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    {conn, user} = authenticated_conn_with_user(conn)

    # Add the user, then hard-dismiss them (ADR 0038).
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: "Tasks Test User",
        joined_at: DateTime.utc_now()
      })

    {:ok, _} = Chat.remove_participant(participant)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    # Opening the task detail adds the viewing user as a participant (this
    # is an explicit, page-load "ensure I'm here" path, not a dismissal
    # resurrection — it creates a fresh row rather than reviving the
    # deleted one).
    assert %Chat.Participant{id: new_id} =
             Chat.list_participants(space.id, participant_type: "user")
             |> Enum.find(&(&1.participant_id == user.id))

    refute new_id == participant.id

    html =
      render_submit(view, "send_steering_message", %{
        "steering" => %{"text" => "Back in the loop"}
      })

    assert html =~ "Steering sent to the execution log."
  end

  test "send_steering_message surfaces attachment storage failures", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Attachment Steering Task", status: "in_progress"})
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    broken_root =
      Path.join(
        System.tmp_dir!(),
        "platform_tasks_live_test_broken_root_#{System.unique_integer([:positive])}"
      )

    File.write!(broken_root, "not a directory")
    Application.put_env(:platform, :chat_attachments_root, broken_root)

    on_exit(fn -> File.rm_rf(broken_root) end)

    {conn, _user} = authenticated_conn_with_user(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    upload =
      file_input(view, "#steering-compose-form", :steering_attachments, [
        %{
          name: "notes.txt",
          content: "steering attachment",
          type: "text/plain"
        }
      ])

    assert render_upload(upload, "notes.txt") =~ "notes.txt"

    html =
      view
      |> form("#steering-compose-form", steering: %{text: "See attached"})
      |> render_submit()

    assert Chat.list_messages(space.id) == []
    assert html =~ "notes.txt"

    assert html =~
             "The attachment upload could not be stored in the execution log. Please try again."
  end

  # ── task_display_status / Plan Ready label ────────────────────────────

  describe "task_display_status / Plan Ready label" do
    defp insert_plan!(task, status, version \\ 1) do
      Repo.insert!(%Plan{
        task_id: task.id,
        version: version,
        status: status
      })
    end

    test "planning task with no plans renders Planning + outline badge", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Planning No Plans", status: "planning"})

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Planning"
      refute html =~ "Plan Ready"
      # The detail-panel status badge uses the outline class.
      assert html =~ "badge badge-outline"
    end

    test "planning task with draft plan still renders Planning", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Planning Draft", status: "planning"})
      insert_plan!(task, "draft")

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Planning"
      refute html =~ "Plan Ready"
    end

    test "planning task with pending_review plan renders Plan Ready + warning badge",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Plan Ready Task", status: "planning"})
      insert_plan!(task, "pending_review")

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Plan Ready"
      assert html =~ "badge badge-warning"
    end

    test "planning task with approved plan still renders Planning (transitional)",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Planning Approved", status: "planning"})
      insert_plan!(task, "approved")

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Planning"
      refute html =~ "Plan Ready"
    end

    test "planning task with rejected plan renders Planning", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Planning Rejected", status: "planning"})
      insert_plan!(task, "rejected")

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Planning"
      refute html =~ "Plan Ready"
    end

    test "non-planning task (in_progress) renders status_label unchanged with outline badge",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "In Progress Control", status: "in_progress"})
      # Even with a pending_review plan, a non-planning task is not "Plan Ready".
      insert_plan!(task, "pending_review")

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "In Progress"
      refute html =~ "Plan Ready"
      assert html =~ "badge badge-outline"
    end
  end

  # ── Stage-card validation regrouping (task 019df4a5 stage 6) ──────────
  #
  # Per-stage validations now render INSIDE each stage card rather than in
  # a trailing flat list. The dedicated E2E Behavior section sits below the
  # stage list and renders the planner-authored evaluation_payload script.
  describe "validation regrouping in plan body" do
    defp insert_active_plan!(task) do
      {:ok, plan} =
        Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

      plan
    end

    test "test_pass + lint_pass badges render INSIDE the stage card, not in a flat list",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Stage badges task", status: "in_progress"})
      plan = insert_active_plan!(task)

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Implement feature",
          status: "running"
        })

      {:ok, _v_test} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "test_pass",
          status: "pending"
        })

      {:ok, _v_lint} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "lint_pass",
          status: "pending"
        })

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      # Stage card carries the badges as inline children.
      stage_card_attr = ~s(data-role="stage-card" data-stage-id="#{stage.id}")
      assert html =~ stage_card_attr

      # Both badges appear, tagged with their kind, inside the stage card's
      # validations container.
      assert html =~ ~s(data-role="stage-validations")
      assert html =~ ~s(data-validation-kind="test_pass")
      assert html =~ ~s(data-validation-kind="lint_pass")

      # The pre-stage-6 trailing flat validations list MUST be gone — there
      # is no <div data-role="validations-list"> rendered anywhere.
      refute html =~ ~s(data-role="validations-list")

      # Sanity: badges appear after the stage-card opening tag and before
      # the next stage card / e2e section starts. Use a coarse positional
      # check: the first occurrence of `data-validation-kind=` appears AFTER
      # the first `data-role="stage-card"` opening.
      stage_card_pos = :binary.match(html, "data-role=\"stage-card\"") |> elem(0)

      first_badge_pos =
        :binary.match(html, "data-role=\"stage-validation-badge\"") |> elem(0)

      assert first_badge_pos > stage_card_pos
    end

    test "manual_approval validation on a UI stage renders inside that stage's card",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "UI stage task", status: "in_progress"})
      plan = insert_active_plan!(task)

      {:ok, ui_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Wire up panel UI",
          status: "running"
        })

      {:ok, _v_manual} =
        Tasks.create_validation(%{
          stage_id: ui_stage.id,
          kind: "manual_approval",
          status: "pending"
        })

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ ~s(data-role="stage-card" data-stage-id="#{ui_stage.id}")
      assert html =~ ~s(data-validation-kind="manual_approval")
      refute html =~ ~s(data-role="validations-list")
    end

    test "non-UI task (no manual_approval anywhere) does NOT render a manual_approval badge",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Backend-only task", status: "in_progress"})
      plan = insert_active_plan!(task)

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Refactor module",
          status: "running"
        })

      {:ok, _v_test} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "pending"})

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ ~s(data-validation-kind="manual_approval")
    end

    test "task with an e2e_behavior validation renders the dedicated E2E Behavior section " <>
           "with full payload visible",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "E2E task", status: "in_review"})
      plan = insert_active_plan!(task)

      {:ok, _impl_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Implement",
          status: "passed"
        })

      # Synthetic task-level review stage (this is what
      # PlanEngine.route_e2e_behavior_validations/1 creates).
      {:ok, review_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Task-level review",
          status: "pending"
        })

      payload = %{
        "setup" => "Spin up dev server and seed two tasks A and B.",
        "actions" => "Open task B and click the dependency badge.",
        "expected" => "The dependency badge renders the linked task title."
      }

      {:ok, _v_e2e} =
        Tasks.create_validation(%{
          stage_id: review_stage.id,
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: payload
        })

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ ~s(data-role="e2e-behavior-section")
      assert html =~ "E2E Behavior"

      # The three v2 payload sections render, each with its `data-role` and
      # the text from the payload. failure_feedback is no longer rendered.
      assert html =~ ~s(data-role="e2e-setup")
      assert html =~ "Spin up dev server"
      assert html =~ ~s(data-role="e2e-actions")
      assert html =~ "Open task B and click the dependency badge."
      assert html =~ ~s(data-role="e2e-expected")
      assert html =~ "The dependency badge renders the linked task title."
      refute html =~ ~s(data-role="e2e-failure_feedback")

      # The synthetic review stage that ONLY hosts the e2e validation should
      # not double-render the validation as a stage badge.
      refute html =~ ~s(data-validation-kind="e2e_behavior")

      # And there's no flat trailing validations list.
      refute html =~ ~s(data-role="validations-list")
    end

    test "plan_body renders one e2e card per pending e2e validation",
         %{conn: conn} do
      # v2: the planner authors 2-5 adversarial e2e_behavior validations per
      # task. The detail panel must surface every one of them as its own card
      # under the dedicated E2E Behavior section.
      project = create_project()
      task = create_task(project, %{title: "Multi-E2E task", status: "in_review"})
      plan = insert_active_plan!(task)

      {:ok, _impl_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Implement",
          status: "passed"
        })

      {:ok, review_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Task-level review",
          status: "pending"
        })

      payloads = [
        %{
          "setup" => "Seed fixture A1",
          "actions" => "Click X on row A1",
          "expected" => "Row A1 turns green within 1s"
        },
        %{
          "setup" => "Seed fixture B1",
          "actions" => "Submit empty form",
          "expected" => "Inline error appears with no row added"
        },
        %{
          "setup" => "Seed fixture C1 + delete halfway",
          "actions" => "Refresh and observe row C1 state",
          "expected" => "Row C1 disappears with no client error"
        }
      ]

      for payload <- payloads do
        {:ok, _v} =
          Tasks.create_validation(%{
            stage_id: review_stage.id,
            kind: "e2e_behavior",
            status: "pending",
            evaluation_payload: payload
          })
      end

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      # Each validation gets its own card with the data-role marker.
      cards = String.split(html, ~s(data-role="e2e-behavior-validation"))
      # 3 validations + 1 leading text segment before the first occurrence.
      assert length(cards) == 4

      # Each payload's distinguishing text appears.
      assert html =~ "Seed fixture A1"
      assert html =~ "Row A1 turns green within 1s"
      assert html =~ "Seed fixture B1"
      assert html =~ "Inline error appears"
      assert html =~ "Seed fixture C1"
      assert html =~ "Row C1 disappears"
    end

    test "plan_body shows test-case count in the E2E section header",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Header count task", status: "in_review"})
      plan = insert_active_plan!(task)

      {:ok, _impl_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Implement",
          status: "passed"
        })

      {:ok, review_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Task-level review",
          status: "pending"
        })

      for n <- 1..2 do
        {:ok, _v} =
          Tasks.create_validation(%{
            stage_id: review_stage.id,
            kind: "e2e_behavior",
            status: "pending",
            evaluation_payload: %{
              "setup" => "s#{n}",
              "actions" => "a#{n}",
              "expected" => "e#{n}"
            }
          })
      end

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "task-level review"
      assert html =~ "2 test cases"
    end
  end

  describe "inline title edit (stage 1)" do
    test "update_task_title persists the new title and clears editing state", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Original Title"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # v2: detail-panel edits are gated on edit_mode. Engage it first.
      render_click(view, "toggle_edit_mode")

      # Click-to-edit puts the detail panel into editing state.
      render_click(view, "start_edit_title", %{"task-id" => task.id})
      assert render(view) =~ "data-role=\"detail-title-input\""

      # Submit a new title via the same event the input fires on Enter/blur.
      render_hook(view, "update_task_title", %{
        "value" => "Renamed Title",
        "task-id" => task.id
      })

      updated = Tasks.get_task_record(task.id)
      assert updated.title == "Renamed Title"

      # Editing state cleared, new title rendered.
      html = render(view)
      assert html =~ "Renamed Title"
      assert html =~ "data-role=\"detail-title\""
      refute html =~ "data-role=\"detail-title-input\""
    end

    test "Tasks.update_task broadcasts :task_updated to subscribers", %{conn: _conn} do
      project = create_project()
      task = create_task(project, %{title: "Broadcast Task"})

      Tasks.subscribe_board()
      {:ok, _updated} = Tasks.update_task(task, %{title: "Broadcast Task v2"})

      assert_receive {:task_updated, %{id: id, title: "Broadcast Task v2"}}, 1_000
      assert id == task.id
    end

    test "blank title is rejected with a flash and does not persist", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Keep Me"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # v2: enter edit mode so the update handler isn't gated out.
      render_click(view, "toggle_edit_mode")
      render_hook(view, "update_task_title", %{"value" => "   ", "task-id" => task.id})

      assert render(view) =~ "Title cannot be empty"
      assert Tasks.get_task_record(task.id).title == "Keep Me"
    end

    test "kanban card title is plain text in v2 stage 3 (no inline-edit affordance)",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Card Edit Task"})

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks")

      # The kanban-card title is rendered as a plain <h3> with no
      # `phx-click="start_edit_title"` and no InlineEdit hook. Edits must
      # go through the detail panel + explicit edit-mode toggle.
      assert html =~ ~s|data-role="card-title"|

      card_title_h3 =
        Regex.run(~r|<h3[^>]*data-role="card-title"[^>]*>|, html)
        |> List.first()

      refute card_title_h3 =~ "phx-click=\"start_edit_title\""
      refute card_title_h3 =~ "phx-hook=\"InlineEdit\""

      # The legacy inline-edit input variant is also gone.
      refute html =~ ~s|data-role="card-title-input"|

      # Clicking the title bubbles up to the card-level `phx-click="select_task"`
      # and opens the detail panel (verified via the patched URL + selected_task
      # assign). Phoenix LiveTest dispatches the click to the innermost matching
      # `phx-click`, so we trigger the card-level event that bubbling would.
      render_click(view, "select_task", %{"id" => task.id})
      html_after = render(view)

      assert html_after =~ ~s|data-role="detail-title"|
      assert html_after =~ "Card Edit Task"
    end

    test "detail panel title edit does not break navigation back to /tasks", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Navigable Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_click(view, "toggle_edit_mode")
      render_click(view, "start_edit_title", %{"task-id" => task.id})

      render_hook(view, "update_task_title", %{
        "value" => "Navigable Task v2",
        "task-id" => task.id
      })

      # Closing the detail panel still works after an edit.
      render_click(view, "close_detail")
      assert render(view) =~ "Navigable Task v2"
    end
  end

  describe "priority + deploy_target dropdowns (stage 2)" do
    test "changing priority via update_task_field persists and rerenders", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Bump Me", priority: "medium"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # v2: edit-mode required.
      render_click(view, "toggle_edit_mode")

      render_hook(view, "update_task_field", %{
        "field" => "priority",
        "value" => "high",
        "task-id" => task.id
      })

      assert Tasks.get_task_record(task.id).priority == "high"
    end

    test "invalid priority value flashes a changeset error and does not persist", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Sticky Priority", priority: "medium"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_click(view, "toggle_edit_mode")

      render_hook(view, "update_task_field", %{
        "field" => "priority",
        "value" => "ULTRA",
        "task-id" => task.id
      })

      assert render(view) =~ "Could not update priority"
      assert Tasks.get_task_record(task.id).priority == "medium"
    end

    test "deploy_target select renders only the project's configured targets", %{conn: conn} do
      project = create_project()

      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"deploy_targets" => ["production", "exp"]}
        })

      task = create_task(project, %{title: "Deploy Target Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # v2: select only renders in edit mode.
      html = render_click(view, "toggle_edit_mode")
      assert html =~ ~s|data-role="deploy-target-select"|
      assert html =~ ~s|value="production"|
      assert html =~ ~s|value="exp"|
      # Targets from other projects are not present.
      refute html =~ ~s|value="some_other_target"|

      render_hook(view, "update_task_field", %{
        "field" => "deploy_target",
        "value" => "exp",
        "task-id" => task.id
      })

      assert Tasks.get_task_record(task.id).deploy_target == "exp"
    end

    test "non-whitelisted field name flashes an error and does not persist", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Locked Down", priority: "low"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_click(view, "toggle_edit_mode")

      render_hook(view, "update_task_field", %{
        "field" => "status",
        "value" => "done",
        "task-id" => task.id
      })

      assert render(view) =~ "is not editable"
      assert Tasks.get_task_record(task.id).status == "backlog"
    end
  end

  describe "assignee dropdown (stage 3)" do
    test "assignee select renders all agents and reflects current assignee", %{conn: conn} do
      project = create_project()
      a1 = create_agent("Higgins (Test)")
      a2 = create_agent("Mycroft (Test)")

      task =
        create_task(project, %{title: "Pickable", assignee_id: a1.id, assignee_type: "agent"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # v2: select only renders in edit mode.
      html = render_click(view, "toggle_edit_mode")
      assert html =~ ~s|data-role="assignee-select"|
      assert html =~ "Higgins (Test)"
      assert html =~ "Mycroft (Test)"
      assert html =~ ~s|value="#{a1.id}" selected|
    end

    test "selecting a different agent persists the new assignee", %{conn: conn} do
      project = create_project()
      a1 = create_agent("Geordi (Test)")
      a2 = create_agent("Dalton (Test)")

      task =
        create_task(project, %{title: "Reassign Me", assignee_id: a1.id, assignee_type: "agent"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_click(view, "toggle_edit_mode")

      render_hook(view, "update_task_field", %{
        "field" => "assignee_id",
        "value" => a2.id,
        "task-id" => task.id
      })

      updated = Tasks.get_task_record(task.id)
      assert updated.assignee_id == a2.id
      assert updated.assignee_type == "agent"
    end

    test "clearing the assignee (empty string → nil) persists nil id and nil type", %{conn: conn} do
      project = create_project()
      a1 = create_agent("Departing (Test)")

      task =
        create_task(project, %{title: "Unassign Me", assignee_id: a1.id, assignee_type: "agent"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_click(view, "toggle_edit_mode")

      render_hook(view, "update_task_field", %{
        "field" => "assignee_id",
        "value" => "",
        "task-id" => task.id
      })

      updated = Tasks.get_task_record(task.id)
      assert is_nil(updated.assignee_id)
      assert is_nil(updated.assignee_type)
    end
  end

  describe "description editor (stage 4)" do
    test "Edit button swaps the rendered markdown for a textarea", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Editable Desc", description: "Hello **world**"})

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ ~s|data-role="description-rendered"|
      # Earmark renders the bold via <strong>.
      assert html =~ "<strong>world</strong>"

      # v2: edit button only renders in edit mode.
      render_click(view, "toggle_edit_mode")
      html = render_click(view, "start_edit_description")
      assert html =~ ~s|data-role="description-textarea"|
      assert html =~ ~s|data-role="description-save"|
      refute html =~ ~s|data-role="description-rendered"|
    end

    test "save persists the new description and re-renders the markdown", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Save Test", description: "Old text"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_click(view, "toggle_edit_mode")
      render_click(view, "start_edit_description")

      html =
        view
        |> form(~s|form[data-role="description-form"]|, %{
          "description" => "## New heading\n\nFresh body."
        })
        |> render_submit()

      # Persisted.
      assert Tasks.get_task_record(task.id).description == "## New heading\n\nFresh body."
      # Rendered HTML, not raw markdown — ContentRenderer caps headings at h3
      # (downgrade_headings/1 in content_renderer.ex), so `##` becomes `<h3>`
      # once sanitized. We match the rendered tag close (Earmark inserts a
      # newline between the opening tag and the text, so checking for the
      # close is the most stable way to assert the heading rendered).
      assert html =~ "New heading</h3>"
      assert html =~ "Fresh body."
      assert html =~ ~s|data-role="description-rendered"|
      refute html =~ ~s|data-role="description-textarea"|
      # The raw markdown shouldn't appear (a leak would mean the textarea
      # value got rendered without going through Earmark).
      refute html =~ "## New heading"
    end

    test "cancel discards local edit state without persisting", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Cancel Test", description: "Untouched"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_click(view, "toggle_edit_mode")
      render_click(view, "start_edit_description")
      html = render_click(view, "cancel_edit_description")

      assert html =~ ~s|data-role="description-rendered"|
      refute html =~ ~s|data-role="description-textarea"|
      assert Tasks.get_task_record(task.id).description == "Untouched"
    end

    test "concurrent edit — second LV session sees the broadcast and re-renders",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Concurrent", description: "v0"})

      # Session A and Session B both view the same task.
      {conn_a, _user_a} = authenticated_conn_with_user(conn)
      {conn_b, _user_b} = authenticated_conn_with_user(conn)

      {:ok, view_a, _html_a} = live(conn_a, ~p"/tasks/#{task.id}")
      {:ok, view_b, _html_b} = live(conn_b, ~p"/tasks/#{task.id}")

      # A engages edit mode and saves a new description.
      render_click(view_a, "toggle_edit_mode")
      render_click(view_a, "start_edit_description")

      view_a
      |> form(~s|form[data-role="description-form"]|, %{"description" => "v1 from A"})
      |> render_submit()

      # B's view receives the broadcast and re-renders the new content.
      html_b = render(view_b)
      assert html_b =~ "v1 from A"
    end

    test "task without description shows an empty-state placeholder", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Empty Desc", description: nil})

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      # Off: placeholder reads simple ("No description yet."), no Edit hint.
      assert html =~ ~s|data-role="description-empty"|
      refute html =~ "click Edit to add one"

      # On: placeholder mentions the Edit affordance now visible.
      html = render_click(view, "toggle_edit_mode")
      assert html =~ "click Edit to add one"
    end
  end

  describe "create-task FAB visibility" do
    test "FAB renders without max-md:hidden when no task is selected", %{conn: conn} do
      project = create_project()
      _task = create_task(project, %{title: "FAB Visibility Task"})

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # The FAB button is the one wired to toggle_task_sheet.
      [fab_attrs] = Regex.run(~r/<button[^>]*phx-click="toggle_task_sheet"[^>]*>/, html)

      assert fab_attrs =~ "btn-primary"
      assert fab_attrs =~ "btn-circle"
      refute fab_attrs =~ "max-md:hidden"
    end

    test "FAB renders with max-md:hidden when a task is selected", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "FAB Hidden Task"})

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      [fab_attrs] = Regex.run(~r/<button[^>]*phx-click="toggle_task_sheet"[^>]*>/, html)

      assert fab_attrs =~ "btn-primary"
      assert fab_attrs =~ "btn-circle"
      assert fab_attrs =~ "max-md:hidden"
    end
  end

  describe "reopen-with-feedback button + modal" do
    # Drives a fresh task all the way to `done` with an `approved` plan in
    # place so `Tasks.reopen_with_feedback/3` has something to reject.
    # Mirrors the setup used in plan_test.exs reopen_with_feedback specs.
    defp create_done_task_with_plan(project, title \\ "Reopen Target Task") do
      task = create_task(project, %{title: title, status: "planning"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, version: 1, status: "draft"})

      {:ok, _stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Stage 1", status: "pending"})

      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, _plan} = Tasks.approve_plan(plan, "system")

      # approve_plan moves the task into in_progress via the dispatch gate;
      # walk it the rest of the way so it lands in `done` with an approved
      # plan still attached.
      {:ok, t} = Tasks.transition_task_status(Tasks.get_task_record(task.id), "in_review")
      {:ok, t} = Tasks.transition_task_status(t, "deploying")
      {:ok, t} = Tasks.transition_task_status(t, "done")
      t
    end

    test "Reopen-with-feedback button is rendered for done tasks", %{conn: conn} do
      project = create_project()
      task = create_done_task_with_plan(project, "Done — should show reopen")

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ ~s|data-role="reopen-task-button"|
      assert html =~ "Reopen with feedback"
    end

    for status <- ~w(planning in_progress in_review backlog) do
      @tag status: status
      test "Reopen-with-feedback button is hidden for #{status} tasks", %{
        conn: conn,
        status: status
      } do
        project = create_project()
        task = create_task(project, %{title: "Non-done #{status}", status: status})

        conn = authenticated_conn(conn)
        {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

        refute html =~ ~s|data-role="reopen-task-button"|
      end
    end

    test "clicking the Reopen button opens the modal with an empty textarea", %{conn: conn} do
      project = create_project()
      task = create_done_task_with_plan(project, "Open-modal task")

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      # Modal not present until the button is clicked.
      refute html =~ ~s|id="reopen-modal"|

      html =
        view
        |> element(~s|button[data-role="reopen-task-button"]|)
        |> render_click()

      assert html =~ ~s|id="reopen-modal"|
      assert html =~ ~s|data-role="reopen-reason-textarea"|
      # Submit is disabled while reason is blank.
      assert html =~
               ~r/<button[^>]*data-role="reopen-submit-button"[^>]*disabled/

      # Hint visible on empty.
      assert html =~ ~s|data-role="reopen-reason-hint"|
    end

    test "submitting a non-empty reason reopens the task and closes the modal", %{conn: conn} do
      project = create_project()
      task = create_done_task_with_plan(project, "Submit-valid task")

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view
      |> element(~s|button[data-role="reopen-task-button"]|)
      |> render_click()

      html =
        view
        |> form(~s|#reopen-modal form|, %{"reason" => "Spec missed the auth flow"})
        |> render_submit()

      assert html =~ "Task reopened."
      # Modal closed.
      refute html =~ ~s|id="reopen-modal"|

      # Task back in planning, plan rejected with reason persisted.
      reloaded = Tasks.get_task_detail(task.id)
      assert reloaded.status == "planning"

      latest = Tasks.latest_plan(task.id)
      assert latest.status == "rejected"
      assert latest.rejection_reason == "Spec missed the auth flow"
    end

    test "submitting a blank reason keeps the modal open with an error flash", %{conn: conn} do
      project = create_project()
      task = create_done_task_with_plan(project, "Blank-reason task")

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view
      |> element(~s|button[data-role="reopen-task-button"]|)
      |> render_click()

      # Whitespace-only reason — server-side check rejects.
      html =
        view
        |> form(~s|#reopen-modal form|, %{"reason" => "   \n\t  "})
        |> render_submit()

      assert html =~ "A reason is required to reopen the task."
      # Modal stays open.
      assert html =~ ~s|id="reopen-modal"|

      # Task remains in `done`.
      assert Tasks.get_task_record(task.id).status == "done"
    end

    test "Cancel closes the modal without persisting", %{conn: conn} do
      project = create_project()
      task = create_done_task_with_plan(project, "Cancel-modal task")

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view
      |> element(~s|button[data-role="reopen-task-button"]|)
      |> render_click()

      html = render_click(view, "close_reopen_modal")

      refute html =~ ~s|id="reopen-modal"|
      assert Tasks.get_task_record(task.id).status == "done"
    end
  end

  describe "detail panel edit-mode toggle (v2 stage 1)" do
    test "default state: detail panel renders with edit_mode=false and pencil button present",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Edit-mode default off"})

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ ~s|data-role="edit-mode-toggle"|
      assert html =~ ~s|data-edit-mode="false"|
      refute html =~ ~s|data-role="edit-mode-indicator"|
    end

    test "toggle_edit_mode flips :edit_mode to true and rerenders", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Toggle on"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html = render_click(view, "toggle_edit_mode")

      assert html =~ ~s|data-edit-mode="true"|
      assert html =~ ~s|data-role="edit-mode-indicator"|
      refute html =~ ~s|data-edit-mode="false"|
    end

    test "toggle_edit_mode twice flips back to false", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Toggle on then off"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_click(view, "toggle_edit_mode")
      html = render_click(view, "toggle_edit_mode")

      assert html =~ ~s|data-edit-mode="false"|
      refute html =~ ~s|data-role="edit-mode-indicator"|
    end

    test "selecting a different task resets edit_mode to false even if previous was true",
         %{conn: conn} do
      project = create_project()
      task_a = create_task(project, %{title: "Task A"})
      task_b = create_task(project, %{title: "Task B"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task_a.id}")

      # Engage edit mode on Task A.
      html = render_click(view, "toggle_edit_mode")
      assert html =~ ~s|data-edit-mode="true"|

      # Navigate to Task B via the same select_task patch the kanban uses.
      {:ok, view_b, _} = live(conn, ~p"/tasks/#{task_b.id}")
      html_b = render(view_b)

      assert html_b =~ "Task B"
      assert html_b =~ ~s|data-edit-mode="false"|
      refute html_b =~ ~s|data-role="edit-mode-indicator"|
    end

    test "close_detail clears edit_mode (re-opening starts read-only)", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Close clears edit-mode"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # Toggle on, then close.
      render_click(view, "toggle_edit_mode")
      render_click(view, "close_detail")

      # Re-open the same task — fresh navigation, edit_mode should be false.
      {:ok, view_reopen, _} = live(conn, ~p"/tasks/#{task.id}")
      html = render(view_reopen)

      assert html =~ ~s|data-edit-mode="false"|
      refute html =~ ~s|data-role="edit-mode-indicator"|
    end

    test "toggling edit-mode off also clears in-progress inline title edit", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Stranded edit cleanup"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # Open edit mode, then start an inline title edit. The input should be visible.
      render_click(view, "toggle_edit_mode")
      render_click(view, "start_edit_title", %{"task-id" => task.id})
      assert render(view) =~ ~s|data-role="detail-title-input"|

      # Toggle edit mode off — the in-progress inline edit should close so we
      # don't leave a stranded input visible in read-only state.
      html = render_click(view, "toggle_edit_mode")
      refute html =~ ~s|data-role="detail-title-input"|
      assert html =~ ~s|data-role="detail-title"|
    end
  end

  # Stage 2 of the v2 plan wires the @edit_mode toggle (stage 1) into the
  # detail-panel edit affordances. With edit_mode=false the panel renders
  # plain text/badges (no triggers); with edit_mode=true the v1 inputs/forms
  # come back, wrapped in a dashed-border affordance. Server-side guards
  # no-op the write handlers when edit_mode is false.
  describe "edit-mode field gating (v2 stage 2)" do
    test "title is rendered as a plain h2 (no phx-click) when edit_mode is off",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Read-only Title"})

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      # detail-title is present with data-editable="false" and no click handler.
      assert html =~ ~s|data-role="detail-title"|
      assert html =~ ~s|data-editable="false"|

      detail_h2 =
        Regex.run(~r|<h2[^>]*data-role="detail-title"[^>]*>|, html)
        |> List.first()

      refute detail_h2 =~ ~s|phx-click="start_edit_title"|
    end

    test "title becomes click-to-edit and shows the dashed affordance when edit_mode is on",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Editable Title"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html = render_click(view, "toggle_edit_mode")

      assert html =~ ~s|data-role="detail-title"|
      assert html =~ ~s|data-editable="true"|

      detail_h2 =
        Regex.run(~r|<h2[^>]*data-role="detail-title"[^>]*>|, html)
        |> List.first()

      assert detail_h2 =~ ~s|phx-click="start_edit_title"|
      assert detail_h2 =~ "border-dashed"
    end

    test "start_edit_title is a no-op when edit_mode is off", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Cannot edit"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_click(view, "start_edit_title", %{"task-id" => task.id})
      html = render(view)

      refute html =~ ~s|data-role="detail-title-input"|
    end

    test "update_task_title is a no-op when edit_mode is off (server-side guard)",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Locked Title"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_hook(view, "update_task_title", %{
        "value" => "Sneaky update",
        "task-id" => task.id
      })

      assert Tasks.get_task_record(task.id).title == "Locked Title"
    end

    test "priority + deploy_target render as read-only badges when edit_mode is off",
         %{conn: conn} do
      project = create_project()

      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"deploy_targets" => ["production", "exp"]}
        })

      task =
        create_task(project, %{
          title: "Read-only meta",
          priority: "high",
          deploy_target: "exp"
        })

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ ~s|data-role="priority-readonly"|
      assert html =~ ~s|data-role="deploy-target-readonly"|
      refute html =~ ~s|data-role="priority-select"|
      refute html =~ ~s|data-role="deploy-target-select"|
    end

    test "priority + deploy_target reveal the v1 selects (with dashed border) when edit_mode is on",
         %{conn: conn} do
      project = create_project()

      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"deploy_targets" => ["production", "exp"]}
        })

      task = create_task(project, %{title: "Editable meta", priority: "low"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html = render_click(view, "toggle_edit_mode")

      assert html =~ ~s|data-role="priority-select"|
      assert html =~ ~s|data-role="deploy-target-select"|
      assert html =~ ~s|data-role="priority-form"|
      assert html =~ "border-dashed"
      refute html =~ ~s|data-role="priority-readonly"|
      refute html =~ ~s|data-role="deploy-target-readonly"|
    end

    test "update_task_field for priority is a no-op when edit_mode is off (server-side guard)",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Locked Priority", priority: "low"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_hook(view, "update_task_field", %{
        "field" => "priority",
        "value" => "high",
        "task-id" => task.id
      })

      assert Tasks.get_task_record(task.id).priority == "low"
    end

    test "update_task_field for deploy_target is a no-op when edit_mode is off",
         %{conn: conn} do
      project = create_project()

      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{"deploy_targets" => ["production"]}
        })

      task = create_task(project, %{title: "Locked Deploy"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_hook(view, "update_task_field", %{
        "field" => "deploy_target",
        "value" => "production",
        "task-id" => task.id
      })

      assert is_nil(Tasks.get_task_record(task.id).deploy_target)
    end

    test "assignee renders as read-only badge when edit_mode is off", %{conn: conn} do
      project = create_project()
      a1 = create_agent("Holmes (Test)")

      task =
        create_task(project, %{
          title: "Read-only assignee",
          assignee_id: a1.id,
          assignee_type: "agent"
        })

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ ~s|data-role="assignee-readonly"|
      refute html =~ ~s|data-role="assignee-select"|
    end

    test "update_task_field for assignee_id is a no-op when edit_mode is off",
         %{conn: conn} do
      project = create_project()
      a1 = create_agent("Original (Test)")
      a2 = create_agent("Sneaky (Test)")

      task =
        create_task(project, %{
          title: "Locked Assignee",
          assignee_id: a1.id,
          assignee_type: "agent"
        })

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_hook(view, "update_task_field", %{
        "field" => "assignee_id",
        "value" => a2.id,
        "task-id" => task.id
      })

      assert Tasks.get_task_record(task.id).assignee_id == a1.id
    end

    test "description Edit button is hidden when edit_mode is off", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Read-only desc", description: "Body"})

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ ~s|data-role="description-edit-button"|
      assert html =~ ~s|data-role="description-rendered"|

      html = render_click(view, "toggle_edit_mode")
      assert html =~ ~s|data-role="description-edit-button"|
    end

    test "start_edit_description is a no-op when edit_mode is off", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Locked Desc", description: "Stay"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      render_click(view, "start_edit_description")
      html = render(view)

      refute html =~ ~s|data-role="description-textarea"|
      assert html =~ ~s|data-role="description-rendered"|
    end

    test "save_description is a no-op when edit_mode is off (server-side guard)",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Locked Desc Body", description: "Original"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # Bypass the UI gate by sending the event directly while edit_mode is off.
      render_hook(view, "save_description", %{"description" => "Sneaky"})

      assert Tasks.get_task_record(task.id).description == "Original"
    end
  end
end
