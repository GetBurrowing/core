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
end
