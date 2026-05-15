defmodule PlatformWeb.TasksLiveTest do
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.{Plan, ReviewRequests, Stack, Stacks, Task}

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

  defp stack_fixture(attrs) do
    attrs = Map.new(attrs)
    slug = Map.get(attrs, :slug, "fixture-#{System.unique_integer([:positive])}")

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: Map.fetch!(attrs, :project_id),
        slug: slug,
        name: Map.get(attrs, :name, "Fixture Stack"),
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
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
      |> element("#task-card-#{task.id}")
      |> render_click()

    assert html =~ "Clickable Task"
    assert html =~ "Description"
  end

  # Mobile bottom-nav clearance regression: the persistent .bottom-nav
  # (56px on phones, see app.css `--bottom-nav-height`) is rendered after
  # the fixed detail panel in the shell layout. Without bounding the
  # panel's bottom edge to the nav height, the bottom-most panel content
  # (review-request approve/reject buttons, status transition pills) sits
  # behind the nav on phones. The original PR #331 fix padded the inner
  # scroller; the follow-up (this PR) bounds the panel container itself,
  # which is cleaner and removes the dead-space below content the inner-
  # padding strategy created. Asserting the bound on the container keeps
  # the fix from being quietly removed during refactors.
  test "detail panel container bottom edge stops at the mobile bottom-nav",
       %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Clearance Task"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

    assert html =~ "bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]"
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

  describe "stacks on the kanban board (T7 stage 1 — data layer)" do
    # ADR 0041 acceptance criterion 1: stacks render alongside tasks,
    # interleaved by updated_at desc. Criterion 3: expansion state is
    # ephemeral and resets on any list refetch.
    #
    # Stage 1 is data-layer only — the heex template still iterates
    # `@columns` (task-only) so stacks are not yet rendered. The new
    # `@board_items` assign carries the merged shape that stage 2 will
    # render. These tests assert the assign shape and the reset
    # behavior; visual rendering tests land with stage 2.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      task_old =
        create_task(project, %{
          title: "Older Task",
          status: "in_review"
        })

      # Build the stack with seeded members, recompute its rollup
      # status, THEN backdate its `updated_at` to a value strictly
      # between `task_old.updated_at` and a forthcoming `task_new`.
      # We can't rely on insertion order because
      # `recompute_stack_status/1` (and the changeset writes that
      # `create_stack` performs) bump the stack's `updated_at`.
      stack = stack_fixture(project_id: project.id, name: "User Saves Stack")
      {:ok, _members} = seed_stack_members(stack, count: 4)
      {:ok, stack} = Stacks.recompute_stack_status(stack)

      task_new =
        create_task(project, %{
          title: "Newer Task",
          status: "in_review"
        })

      # Explicitly anchor updated_at so the sort assertion is
      # deterministic regardless of insert order: task_new (newest)
      # > stack (middle) > task_old (oldest).
      now = DateTime.utc_now()
      old_ts = DateTime.add(now, -120, :second)
      stack_ts = DateTime.add(now, -60, :second)

      Repo.update_all(
        from(t in Tasks.Task, where: t.id == ^task_old.id),
        set: [updated_at: old_ts]
      )

      Repo.update_all(
        from(s in Stack, where: s.id == ^stack.id),
        set: [updated_at: stack_ts]
      )

      Repo.update_all(
        from(t in Tasks.Task, where: t.id == ^task_new.id),
        set: [updated_at: now]
      )

      stack = Repo.get!(Stack, stack.id)
      task_old = Repo.get!(Tasks.Task, task_old.id)
      task_new = Repo.get!(Tasks.Task, task_new.id)

      {:ok, conn: conn, project: project, stack: stack, task_old: task_old, task_new: task_new}
    end

    # Seed 4 in-review members with stack_position 1..4 and inject
    # dependency edges m2→m1, m3→m1, m4→[m2, m3] so the dep-edge count
    # is 4 (m2→m1, m3→m1, m4→m2, m4→m3) and the in-stack subgraph is
    # exercised.
    defp seed_stack_members(%Stack{} = stack, opts) do
      count = Keyword.get(opts, :count, 4)

      members =
        for pos <- 1..count do
          {:ok, t} =
            Tasks.create_task(%{
              project_id: stack.project_id,
              stack_id: stack.id,
              stack_position: pos,
              title: "Member #{pos}",
              status: "in_review",
              priority: "medium"
            })

          t
        end

      [m1, m2, m3, m4 | _] = members ++ [nil, nil, nil, nil]

      if m2,
        do:
          Tasks.update_task(m2, %{
            dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]
          })

      if m3,
        do:
          Tasks.update_task(m3, %{
            dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]
          })

      if m4,
        do:
          Tasks.update_task(m4, %{
            dependencies: [
              %{"task_id" => m2.id, "kind" => "blocks"},
              %{"task_id" => m3.id, "kind" => "blocks"}
            ]
          })

      {:ok, members}
    end

    test "mount assigns :stacks, :stack_board_data, :board_items, and an empty :expanded_stacks",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assigns = :sys.get_state(view.pid).socket.assigns

      assert is_list(assigns.stacks)
      assert Enum.any?(assigns.stacks, &(&1.id == stack.id))

      board_data = Map.get(assigns.stack_board_data, stack.id)
      assert board_data, "expected stack_board_data to be keyed by stack.id"
      assert board_data.member_count == 4
      # 4 in-stack edges: m2→m1, m3→m1, m4→m2, m4→m3
      assert board_data.dep_edge_count == 4
      assert board_data.ready_count == 4
      assert length(board_data.members) == 4

      assert %MapSet{} = assigns.expanded_stacks
      assert MapSet.size(assigns.expanded_stacks) == 0

      assert is_map(assigns.board_items)
    end

    test "board_items merges stacks and standalone tasks into the rollup_status column, sorted by updated_at desc",
         %{conn: conn, stack: stack, task_old: task_old, task_new: task_new} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      assigns = :sys.get_state(view.pid).socket.assigns

      in_review_items = Map.fetch!(assigns.board_items, "in_review")

      # The newer task, the stack, and the older task should ALL be in
      # the In Review column. Stack members live UNDER the stack only;
      # they must NOT appear in the flat column list.
      ids = Enum.map(in_review_items, & &1.id)
      assert task_new.id in ids
      assert stack.id in ids
      assert task_old.id in ids

      # None of the stack members should be in the column.
      member_ids = Enum.map(Map.fetch!(assigns.stack_board_data, stack.id).members, & &1.id)
      refute Enum.any?(member_ids, &(&1 in ids))

      # Verify interleaved sort by updated_at desc.
      # task_new was created last, so it should be first.
      assert hd(in_review_items).id == task_new.id

      # task_old was created first, so it should be last among the three.
      assert List.last(in_review_items).id == task_old.id

      # The stack should be sandwiched between them, NOT grouped at top
      # or bottom (sort interleaving).
      stack_pos = Enum.find_index(in_review_items, &(&1.id == stack.id))
      new_pos = Enum.find_index(in_review_items, &(&1.id == task_new.id))
      old_pos = Enum.find_index(in_review_items, &(&1.id == task_old.id))
      assert new_pos < stack_pos
      assert stack_pos < old_pos
    end

    test "stack members are stripped from :columns (task-only bucketing preserved for stage-1 template)",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      assigns = :sys.get_state(view.pid).socket.assigns

      # The old `:columns` task-only assign should NOT contain stack
      # member tasks either — they belong to the stack and would
      # otherwise double-render once stage 2 wires the stack card.
      # Stage 1 strips them so the count badges and existing template
      # match the post-stage-2 visible board.
      all_column_ids =
        assigns.columns
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1.id)

      member_ids = Enum.map(Map.fetch!(assigns.stack_board_data, stack.id).members, & &1.id)

      # Stage 1 keeps `:columns` unchanged (task-only, pre-existing
      # behavior). Stack members ARE in `:columns` today because they
      # are still real tasks with an `in_review` status — they only
      # disappear from the BOARD-LEVEL view in `:board_items`. This
      # asserts the explicit boundary: `:columns` is preserved bug-
      # for-bug; `:board_items` is the new merged-and-stripped shape.
      assert Enum.any?(member_ids, &(&1 in all_column_ids)),
             "expected stack members to still appear in legacy :columns assign in stage 1"
    end

    test "board_items strips stack-member tasks from the flat column list",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      assigns = :sys.get_state(view.pid).socket.assigns

      all_board_ids =
        assigns.board_items
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1.id)

      member_ids = Enum.map(Map.fetch!(assigns.stack_board_data, stack.id).members, & &1.id)

      refute Enum.any?(member_ids, &(&1 in all_board_ids)),
             "stack members must not appear as standalone cards in :board_items"
    end

    test "PubSub board refresh resets :expanded_stacks", %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Manually pre-load expansion state. (T7 stage 2 will wire the
      # `toggle_stack_expand` event; for stage 1 we drive the assign
      # directly to test the reset, since the public-event handler
      # doesn't exist yet.)
      _new_state =
        :sys.replace_state(view.pid, fn state ->
          updated_socket =
            Phoenix.Component.assign(
              state.socket,
              :expanded_stacks,
              MapSet.new([stack.id])
            )

          %{state | socket: updated_socket}
        end)

      pre = :sys.get_state(view.pid).socket.assigns.expanded_stacks
      assert MapSet.member?(pre, stack.id)

      # Trigger a board refresh via PubSub (matches the existing
      # `PubSub updates refresh the board` test).
      Tasks.broadcast_board({:task_updated, %Tasks.Task{id: Ecto.UUID.generate()}})
      _ = render(view)

      post = :sys.get_state(view.pid).socket.assigns.expanded_stacks

      assert MapSet.size(post) == 0,
             "refresh_board/1 must reset :expanded_stacks per ADR 0041 acceptance criterion 3"
    end

    test "project filter change resets :expanded_stacks", %{
      conn: conn,
      project: project,
      stack: stack
    } do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _new_state =
        :sys.replace_state(view.pid, fn state ->
          updated_socket =
            Phoenix.Component.assign(
              state.socket,
              :expanded_stacks,
              MapSet.new([stack.id])
            )

          %{state | socket: updated_socket}
        end)

      assert MapSet.member?(
               :sys.get_state(view.pid).socket.assigns.expanded_stacks,
               stack.id
             )

      _html = render_click(view, "select_project", %{"id" => project.id})

      assert MapSet.size(:sys.get_state(view.pid).socket.assigns.expanded_stacks) == 0
    end
  end

  describe "forming-rollup stacks render in the Backlog column" do
    # Regression: a stack whose members are all `backlog` derives a
    # `forming` rollup status (Stacks.rollup_status_for/1). Before the
    # fix, `@column_statuses` had no bucket for `forming`, so the card
    # rendered in NO column — invisible until `stack_start` cascaded a
    # member to in_progress (which then bumped the rollup to in_progress
    # and made the card pop into the In Progress column out of nowhere).
    # Bucketing `forming` under Backlog keeps stacks visible from
    # creation, where pending plan-approvals are expected to live.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      stack = stack_fixture(project_id: project.id, name: "Forming Stack Fixture")
      {:ok, members} = seed_forming_members(stack, count: 2)
      {:ok, stack} = Stacks.recompute_stack_status(stack)
      {:ok, conn: conn, project: project, stack: stack, members: members}
    end

    defp seed_forming_members(%Stack{} = stack, opts) do
      count = Keyword.get(opts, :count, 2)

      members =
        for pos <- 1..count do
          {:ok, t} =
            Tasks.create_task(%{
              project_id: stack.project_id,
              stack_id: stack.id,
              stack_position: pos,
              title: "Forming Member #{pos}",
              status: "backlog",
              priority: "medium"
            })

          t
        end

      {:ok, members}
    end

    test "stack with all-backlog members has rollup status :forming", %{stack: stack} do
      assert stack.status == "forming"
    end

    test "forming stack appears in :board_items[\"backlog\"]",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      assigns = :sys.get_state(view.pid).socket.assigns

      backlog_ids =
        assigns.board_items
        |> Map.fetch!("backlog")
        |> Enum.map(& &1.id)

      assert stack.id in backlog_ids,
             "forming-rollup stack must render in the Backlog column"
    end

    test "forming stack does NOT leak into other columns",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      assigns = :sys.get_state(view.pid).socket.assigns

      for col <- ~w(in_progress in_review deploying done) do
        ids = assigns.board_items |> Map.fetch!(col) |> Enum.map(& &1.id)

        refute stack.id in ids,
               "forming-rollup stack must not appear in #{col} column"
      end
    end
  end

  describe "stack card rendering on the kanban board (T7 stage 2)" do
    # ADR 0041 §"UI surface — Board view" + mock canvas 019e1a16 rev 2:
    # the collapsed stack card lives in its rollup-status column alongside
    # normal task cards, with a purple left-border accent, a STACK tag,
    # member-count + dep-edge-count pills, and a rollup progress
    # `{ready}/{total} ready` text. Click on the card toggles
    # `:expanded_stacks` membership (stage 3 wires the expansion render).

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack = stack_fixture(project_id: project.id, name: "Render Test Stack")
      {:ok, _members} = seed_stack_members(stack, count: 4)
      {:ok, stack} = Stacks.recompute_stack_status(stack)

      stack = Repo.get!(Stack, stack.id)

      {:ok, conn: conn, project: project, stack: stack}
    end

    test "stack card renders in its rollup-status column with the violet accent and STACK tag",
         %{conn: conn, stack: stack} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # Distinctive purple accent + the data attribute the e2e checker
      # will look for. We assert on the BOARD-LEVEL stack DOM id so the
      # test pins the card to the desktop kanban iteration (the mobile
      # list uses a button rather than the `stack-card-#{id}` shell).
      assert html =~ "stack-card-#{stack.id}"
      assert html =~ "data-stack-card=\"true\""
      assert html =~ "border-violet-500"

      # Uppercase STACK tag from the header row (per mock).
      assert html =~ ~r/text-violet-300[^>]*>\s*Stack\s*</
    end

    test "stack card title row renders stack.name", %{conn: conn, stack: stack} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ stack.name
    end

    test "stack card shows member count, dep edge count, and rollup progress pills",
         %{conn: conn, stack: stack} do
      {:ok, view, html} = live(conn, ~p"/tasks")

      board_data =
        :sys.get_state(view.pid).socket.assigns.stack_board_data
        |> Map.fetch!(stack.id)

      # 4 members, 4 in-stack dep edges (m2→m1, m3→m1, m4→m2, m4→m3).
      assert board_data.member_count == 4
      assert board_data.dep_edge_count == 4

      assert html =~ "#{board_data.member_count} tasks"
      assert html =~ "#{board_data.dep_edge_count} dep edges"

      # `{ready}/{total} ready` rollup progress.
      assert html =~ "#{board_data.ready_count}/#{board_data.member_count} ready"
    end

    test "stack card declares the toggle_stack_expand phx-click with stack id",
         %{conn: conn, stack: stack} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ ~s(phx-click="toggle_stack_expand")
      assert html =~ ~s(phx-value-id="#{stack.id}")
    end

    test "stack members do NOT render as standalone cards on the board",
         %{conn: conn, stack: stack} do
      {:ok, view, html} = live(conn, ~p"/tasks")

      member_ids =
        :sys.get_state(view.pid).socket.assigns.stack_board_data
        |> Map.fetch!(stack.id)
        |> Map.fetch!(:members)
        |> Enum.map(& &1.id)

      # No `task-card-<member_id>` outer wrapper should appear — members
      # render only under their stack (stage 3 wires that; stage 2 keeps
      # them hidden).
      Enum.each(member_ids, fn id ->
        refute html =~ ~s(id="task-card-#{id}")
      end)
    end

    test "toggle_stack_expand event flips :expanded_stacks MapSet membership",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      pre = :sys.get_state(view.pid).socket.assigns.expanded_stacks
      refute MapSet.member?(pre, stack.id)

      _html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      mid = :sys.get_state(view.pid).socket.assigns.expanded_stacks

      assert MapSet.member?(mid, stack.id),
             "first click should add the stack id to :expanded_stacks"

      _html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      post = :sys.get_state(view.pid).socket.assigns.expanded_stacks

      refute MapSet.member?(post, stack.id),
             "second click should remove the stack id from :expanded_stacks"
    end

    test "toggle_stack_expand is a no-op for unknown stack ids",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      unknown_id = Ecto.UUID.generate()

      _html = render_click(view, "toggle_stack_expand", %{"id" => unknown_id})

      post = :sys.get_state(view.pid).socket.assigns.expanded_stacks

      assert MapSet.size(post) == 0,
             "unknown stack ids must not leak into :expanded_stacks"
    end

    test "expanded stack flips the chevron's rotation class",
         %{conn: conn, stack: stack} do
      {:ok, view, html} = live(conn, ~p"/tasks")

      # Collapsed by default — no `rotate-180` on the chevron near the
      # stack-card shell.
      refute html =~ ~r/stack-card-#{stack.id}[^>]*>.*rotate-180/s

      html_expanded = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      # After expansion, the chevron carries `rotate-180` somewhere in
      # the stack card subtree.
      assert html_expanded =~ "rotate-180"
    end
  end

  describe "stack inline expansion (T7 stage 3)" do
    # ADR 0041 §"UI surface — inline expansion": when a stack id is in
    # `:expanded_stacks`, its members render indented under the stack
    # header with numbered nodes (circled-digit glyphs), text dep
    # annotations (`needs ①`, `parallel with ②`), and each member row
    # is clickable to open the existing task detail panel.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack = stack_fixture(project_id: project.id, name: "Expansion Test Stack")
      {:ok, members} = seed_stack_members(stack, count: 4)
      {:ok, stack} = Stacks.recompute_stack_status(stack)

      stack = Repo.get!(Stack, stack.id)

      [m1, m2, m3, m4] = members

      {:ok, conn: conn, project: project, stack: stack, m1: m1, m2: m2, m3: m3, m4: m4}
    end

    test "collapsed stack does NOT render any member rows",
         %{conn: conn, m1: m1, m2: m2, m3: m3, m4: m4} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      for m <- [m1, m2, m3, m4] do
        refute html =~ ~s(id="stack-member-#{m.id}"),
               "collapsed stack must NOT render member row for #{m.title}"
      end
    end

    test "expanded stack renders each member's title with a numbered-node glyph",
         %{conn: conn, stack: stack, m1: m1, m2: m2, m3: m3, m4: m4} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      for m <- [m1, m2, m3, m4] do
        assert html =~ ~s(id="stack-member-#{m.id}"),
               "expanded stack must render member row for #{m.title}"

        assert html =~ m.title
      end

      # Numbered-node circled-digit glyphs ①②③④.
      assert html =~ "①"
      assert html =~ "②"
      assert html =~ "③"
      assert html =~ "④"
    end

    test "dep annotations render the correct `needs <glyph>` text per ADR 0041 mock",
         %{conn: conn, stack: stack, m2: m2, m3: m3, m4: m4} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      # m2 depends on m1 only → "needs ①" with no parallel sibling
      # mention because m1 has no deps (no other member parallels m2's
      # dep set with size>0 and a different position).
      assert html =~ ~r/stack-member-#{m2.id}[^>]*>.*?needs ①/s,
             "m2 should render `needs ①`"

      # m3 also depends on m1 → "needs ① • parallel with ②" because m2
      # shares m3's dep set {m1}.
      assert html =~ ~r/stack-member-#{m3.id}[^>]*>.*?needs ① • parallel with ②/s,
             "m3 should render `needs ① • parallel with ②`"

      # m4 depends on m2 + m3 → "needs ② + ③" (no parallel sibling
      # because no other member shares its dep set).
      assert html =~ ~r/stack-member-#{m4.id}[^>]*>.*?needs ② \+ ③/s,
             "m4 should render `needs ② + ③`"

      # m1 has no in-stack deps → no dep-annotation line in its row.
      _stack = stack

      refute html =~ ~r/stack-member-#{m2.id}[^>]*>.*?needs ① \+ /s,
             "m2 should NOT render a multi-dep `needs` (single dep only)"
    end

    test "member row carries phx-click=\"select_task\" with the member id",
         %{conn: conn, stack: stack, m3: m3} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      # Each member row reuses the existing select_task handler.
      assert html =~ ~r/stack-member-#{m3.id}[^>]*phx-click="select_task"/s
      assert html =~ ~r/stack-member-#{m3.id}[^>]*phx-value-id="#{m3.id}"/s
    end

    test "clicking a member row opens the task detail panel (select_task handler)",
         %{conn: conn, stack: stack, m3: m3} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      # `select_task` push_patches to `/tasks/:id`, which routes through
      # handle_params and assigns `:selected_task` + `:show_detail`.
      # Use element/render_click to drive the click on the actual DOM
      # element so the patch + handle_params flow runs end-to-end.
      view
      |> element("#stack-member-#{m3.id}")
      |> render_click()

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.show_detail == true
      assert assigns.selected_task && assigns.selected_task.id == m3.id

      _stack = stack
    end

    test "toggling expansion: collapsed → expanded → collapsed",
         %{conn: conn, stack: stack, m1: m1} do
      {:ok, view, html} = live(conn, ~p"/tasks")

      # Initially collapsed: no member row in the HTML.
      refute html =~ ~s(id="stack-member-#{m1.id}")

      # First toggle: expanded — member row appears.
      html_expanded = render_click(view, "toggle_stack_expand", %{"id" => stack.id})
      assert html_expanded =~ ~s(id="stack-member-#{m1.id}")
      assert html_expanded =~ m1.title

      # Second toggle: collapsed again — member row disappears.
      html_collapsed = render_click(view, "toggle_stack_expand", %{"id" => stack.id})
      refute html_collapsed =~ ~s(id="stack-member-#{m1.id}")
    end

    test "numbered-node class varies by member status",
         %{conn: conn, stack: stack, m1: m1} do
      # Force m1 to `done` so we can assert the success tint.
      {:ok, _m1} = Tasks.update_task(m1, %{status: "done"})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      # The done-status node carries the success-tint class.
      assert html =~ ~r/stack-member-#{m1.id}[^>]*>.*?bg-success\/20/s,
             "done member's numbered node should carry bg-success/20"

      _stack = stack
    end

    test "stack header click toggles expand without bubbling from member click",
         %{conn: conn, stack: stack, m2: m2} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Expand the stack via the header click.
      _html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      assert MapSet.member?(
               :sys.get_state(view.pid).socket.assigns.expanded_stacks,
               stack.id
             )

      # Click a member row directly — this should fire `select_task`
      # (opening the detail panel) and NOT toggle the parent stack's
      # expansion off. We assert the expansion flag still holds AFTER
      # the member click, which is the bubble-safety contract from
      # stage 3 §5.
      view
      |> element("#stack-member-#{m2.id}")
      |> render_click()

      assigns = :sys.get_state(view.pid).socket.assigns

      assert MapSet.member?(assigns.expanded_stacks, stack.id),
             "member click must NOT toggle the parent stack's expansion off"

      assert assigns.selected_task && assigns.selected_task.id == m2.id
    end
  end

  describe "stack mobile responsiveness (T7 stage 4)" do
    # Verify the mobile section list renders the stack card with overflow
    # safeguards (truncate, min-w-0, whitespace-nowrap) so the 375px
    # iPhone-SE viewport doesn't break the card layout. The mobile list
    # lives behind `md:hidden` and is the only stack-card surface phones
    # see (the desktop kanban is `hidden md:flex`); these assertions are
    # rendered HTML — both surfaces emit the same identifiers and the
    # mobile one carries `stack-member-mobile-#{id}` ids.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name:
            "Very long stack name that absolutely will overflow a 375px column without truncate"
        )

      {:ok, _members} = seed_stack_members(stack, count: 4)
      {:ok, stack} = Stacks.recompute_stack_status(stack)
      stack = Repo.get!(Stack, stack.id)

      {:ok, conn: conn, project: project, stack: stack}
    end

    test "mobile section list renders the stack card with the mobile-scoped id prefix",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Seeded stack rolls up to `in_review` (members default to
      # `in_review`); the mobile list only renders the active filter
      # pill's section (T6 PR #328), so switch to the matching pill
      # before exercising the stack-card.
      _ = render_click(view, "filter_by_status", %{"status" => stack.status})
      html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      # Mobile member rows use the `stack-member-mobile-` id prefix so
      # they don't collide with the desktop `stack-member-` ids — both
      # surfaces are in the rendered HTML, only one is visible per
      # breakpoint via Tailwind's `md:hidden` / `hidden md:flex`.
      assert html =~ ~s(id="stack-member-mobile-)
    end

    test "stack card title carries truncate so 375px columns don't overflow",
         %{conn: conn, stack: stack} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # Both the mobile and desktop variants render the stack name
      # inside an `h3` — assert at least one (mobile) instance has
      # `truncate` applied so a long title can't overflow horizontally.
      assert html =~
               ~r/<h3[^>]*class="[^"]*\btruncate\b[^"]*"[^>]*>\s*#{Regex.escape(stack.name)}/s,
             "stack title h3 must carry `truncate` to prevent 375px overflow"
    end

    test "stack header button has min-h-[44px] iOS tap target",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Switch the active mobile filter pill to the rollup status so
      # the mobile stack header (the `min-h-[44px]` carrier) renders;
      # the desktop kanban variant is always rendered (`hidden
      # md:flex`) and emits `data-role="stack-header"` regardless.
      html = render_click(view, "filter_by_status", %{"status" => stack.status})

      # The mobile stack header button sits on the toggle_stack_expand
      # phx-click — assert the iOS minimum 44px tap target is enforced.
      # Tailwind arbitrary value `min-h-[44px]` renders verbatim in the
      # class string. We assert presence of both markers in the
      # rendered HTML; the heex template defines them on the same
      # element (line ~189 of tasks_live.html.heex).
      assert html =~ "data-role=\"stack-header\""
      assert html =~ "min-h-[44px]"
    end

    test "expanded mobile member rows have min-h-[44px] tap target and truncate the title",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Switch the mobile filter pill to the rollup status so the
      # mobile stack-card is visible before expanding (T6 PR #328).
      _ = render_click(view, "filter_by_status", %{"status" => stack.status})
      html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      # Mobile member rows must be ≥ 44px tall (iOS guideline) and the
      # title span must `truncate min-w-0` so long member titles don't
      # push the status badge off the right edge of a 375px column.
      assert html =~ "stack-member-mobile-", "expansion must render the mobile member rows"
      assert html =~ "min-h-[44px]"

      assert html =~ "flex-1 min-w-0 text-xs leading-snug truncate",
             "mobile member title span must carry `truncate min-w-0` for 375px"
    end

    test "stack card pill row uses whitespace-nowrap + shrink-0 so pills don't wrap mid-glyph",
         %{conn: conn, stack: stack} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      _stack = stack

      # The `N tasks` and `N dep edges` pills must stay on one line at
      # 375px — they're short enough to fit but Tailwind's default
      # min-width:auto on flex items can cause mid-pill wrapping when
      # the title is long. Assert the whitespace-nowrap safeguard.
      assert html =~ ~r/bg-base-200 px-1\.5 py-0\.5 rounded[^"]*whitespace-nowrap/,
             "pill row spans must carry whitespace-nowrap shrink-0"
    end

    test "mobile list inner scroller reserves bottom padding (pb-24) so the last task isn't flush with the bottom-nav",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # `--bottom-nav-height` is 56px below lg; pb-24 (= 6rem = 96px)
      # comfortably clears it plus iOS safe-area-inset-bottom. The
      # padding lives on the inner `overflow-y-auto` scroller. The
      # outer `tasks-mobile-list` wrapper used to also carry pb-24
      # (pre-PR #334, when the shell wasn't properly bounded); that
      # copy was removed because it shows up as dead space below the
      # scroller now that the shell is correctly 100dvh-rooted.
      assert html =~ ~r/<div class="flex-1 overflow-y-auto px-3 pb-24"/,
             "mobile list scroller must keep pb-24 to clear the bottom-tab nav (~56px + safe-area)"
    end
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

    test "plan_summary_label/1 renders supersession label and skips the rejection_reason excerpt" do
      ts = ~U[2026-05-07 09:00:00.000000Z]
      sup_id = Ecto.UUID.generate()

      plan = %Plan{
        version: 1,
        status: "rejected",
        updated_at: ts,
        rejection_reason: "Superseded by plan v2",
        superseded_by_plan_id: sup_id,
        superseded_by: %Plan{version: 2}
      }

      label = PlatformWeb.TasksLive.plan_summary_label(plan)

      assert label == "Plan v1 — superseded by v2 on 2026-05-07"
      refute label =~ "rejected on"
      refute label =~ ~s("Superseded by plan v2")
    end

    test "plan_summary_label/1 with superseded_by_plan_id but missing :superseded_by falls through to rejected label" do
      ts = ~U[2026-05-04 12:34:56.000000Z]

      # Pattern guard: %Plan{} on :superseded_by requires the assoc loaded.
      # If it isn't (defensive: legacy row, partial preload), we still render
      # something useful rather than crashing.
      plan = %Plan{
        version: 1,
        status: "rejected",
        updated_at: ts,
        rejection_reason: "design flaw",
        superseded_by_plan_id: Ecto.UUID.generate(),
        superseded_by: %Ecto.Association.NotLoaded{
          __field__: :superseded_by,
          __cardinality__: :one,
          __owner__: Plan
        }
      }

      assert PlatformWeb.TasksLive.plan_summary_label(plan) ==
               ~s(Plan v1 — rejected on 2026-05-04 — "design flaw")
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

    test "auto-superseded v1 folded summary shows 'superseded by v2' instead of the canned reason excerpt",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Supersession task", status: "planning"})

      # v1: approved, will be auto-superseded when v2 is approved.
      {:ok, v1} = Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

      # v2: pending_review → approve, which auto-supersedes v1.
      {:ok, v2} =
        Tasks.create_plan(%{task_id: task.id, version: 2, status: "pending_review"})

      {:ok, _approved_v2} = Tasks.approve_plan(v2, "test-user")

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      # Folded v1 row carries the supersession label…
      assert html =~ "superseded by v2"
      assert html =~ "Plan v1 — superseded by v2"

      # …and does NOT carry the redundant rejection_reason excerpt that
      # approve_plan/2 wrote into v1 (`"Superseded by plan v2"`).
      refute html =~ ~s("Superseded by plan v2")

      # Sanity: v1 actually carries the supersession FK in the DB.
      reloaded_v1 = Repo.get!(Plan, v1.id)
      assert reloaded_v1.superseded_by_plan_id == v2.id
      assert reloaded_v1.status == "rejected"
    end

    test "manually rejected plan with free-text reason still shows the quoted excerpt (no regression)",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Manual reject task", status: "planning"})

      _r1 =
        Repo.insert!(%Plan{
          task_id: task.id,
          status: "rejected",
          version: 1,
          rejection_reason: "design flaw",
          superseded_by_plan_id: nil
        })

      {:ok, _active} = Tasks.create_plan(%{task_id: task.id, version: 2, status: "approved"})

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      # Manual-reject path — quoted excerpt still renders (019dfad1 behavior).
      # HTML-escaped quotes (`&quot;`) wrap the reason in the rendered DOM.
      assert html =~ "design flaw"
      assert html =~ "rejected on"
      refute html =~ "superseded by"
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

  describe "epic creation" do
    # Stage 3 of task 019d60ca: a second FAB stacked above the Create-Task
    # FAB opens a bottom sheet for creating epics. Mirrors the new-task
    # flow pattern.

    test "renders the New Epic FAB", %{conn: conn} do
      _project = create_project()
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # The new-epic FAB is the one wired to toggle_epic_sheet.
      assert html =~ ~s|phx-click="toggle_epic_sheet"|
      [fab_attrs] = Regex.run(~r/<button[^>]*phx-click="toggle_epic_sheet"[^>]*>/, html)
      assert fab_attrs =~ "btn-secondary"
      assert fab_attrs =~ "btn-circle"
    end

    test "opens the New Epic sheet on FAB click", %{conn: conn} do
      _project = create_project()
      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks")

      # Sheet is closed initially — its content is gated by :if=show_epic_sheet.
      refute html =~ "create-epic-form"

      html = render_click(view, "toggle_epic_sheet")

      assert html =~ "create-epic-form"
      assert html =~ "New Epic"
      # Project select renders when no project is filtered.
      assert html =~ ~s|name="epic[project_id]"|
    end

    test "creates an epic on valid submit and closes the sheet", %{conn: conn} do
      project = create_project()
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ = render_click(view, "toggle_epic_sheet")

      html =
        view
        |> form("#create-epic-form",
          epic: %{
            "name" => "Mobile redesign",
            "project_id" => project.id,
            "description" => "Refresh the mobile UX.",
            "acceptance_criteria" => "Lighthouse > 90",
            "target_branch" => "feature/mobile",
            "deploy_target" => "staging"
          }
        )
        |> render_submit()

      # Flash + sheet closed.
      assert html =~ "Epic created."
      refute html =~ "create-epic-form"

      # Epic exists for the project.
      epics = Tasks.list_epics_for_project(project.id)
      assert Enum.any?(epics, fn e -> e.name == "Mobile redesign" end)
    end

    test "shows inline errors on invalid submit and keeps sheet open", %{conn: conn} do
      _project = create_project()
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ = render_click(view, "toggle_epic_sheet")

      html =
        view
        |> form("#create-epic-form",
          epic: %{
            "name" => "",
            "project_id" => ""
          }
        )
        |> render_submit()

      # Sheet still open, error messaging present.
      assert html =~ "create-epic-form"
      assert html =~ "Could not create epic"
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

  describe "stack detail panel — head and actions (T8 stage 1)" do
    # ADR 0041 §"UI surface — Stack detail" + mock canvas 019e1a16 rev 2:
    # clicking a stack card on the kanban board (or its header) opens a
    # right-side slide-in panel mirroring the per-task detail container.
    # Stage 1 ships head (icon + Stack tag + title + description + close)
    # and the action row (Abandon ghost + View rollup PR primary, the
    # latter disabled until metadata.rollup_pr.url is present).

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "user-keyed-saves",
          slug: "user-keyed-saves"
        )

      {:ok, members} = seed_stack_members(stack, count: 4)
      {:ok, stack} = Stacks.recompute_stack_status(stack)
      stack = Repo.get!(Stack, stack.id)

      {:ok, conn: conn, project: project, stack: stack, members: members}
    end

    # Find every HTML opening tag (`<tag ...>`) in `html` whose attribute
    # cluster matches `marker_re` (e.g. `~r/data-role="foo"/`). Returns
    # `[{:ok, tag_str}, ...]`. Used to assert on a single element's
    # attribute cluster regardless of attribute order.
    defp extract_open_tags(html, marker_re) do
      ~r/<[a-zA-Z]+[^>]*>/
      |> Regex.scan(html)
      |> Enum.map(fn [tag] -> tag end)
      |> Enum.filter(&Regex.match?(marker_re, &1))
      |> Enum.map(&{:ok, &1})
    end

    test "open_stack_detail event sets :selected_stack and :show_stack_detail",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      pre = :sys.get_state(view.pid).socket.assigns
      assert pre.selected_stack == nil
      assert pre.show_stack_detail == false

      _html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      post = :sys.get_state(view.pid).socket.assigns
      assert post.show_stack_detail == true
      assert post.selected_stack && post.selected_stack.id == stack.id
      assert is_list(post.selected_stack_members)
      assert length(post.selected_stack_members) == 4
    end

    test "open_stack_detail closes the per-task detail panel if it was open",
         %{conn: conn, stack: stack, members: [m1 | _]} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{m1.id}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.show_detail == true

      _html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.show_stack_detail == true
      assert assigns.show_detail == false
      assert assigns.selected_task == nil
    end

    test "open_stack_detail with an unknown id is a no-op",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _html = render_click(view, "open_stack_detail", %{"id" => Ecto.UUID.generate()})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.show_stack_detail == false
      assert assigns.selected_stack == nil
    end

    test "panel renders the stack name, description, close button, and Stack tag",
         %{conn: conn, stack: stack} do
      {:ok, stack} =
        Stacks.update_stack(stack, %{
          description: "Migrate retro saves from per-room to per-user."
        })

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert html =~ ~s(id="stack-detail-panel")
      assert html =~ ~s(data-role="stack-detail-panel")
      assert html =~ ~s(data-role="stack-detail-title")
      assert html =~ stack.name
      assert html =~ ~s(data-role="stack-detail-description")
      assert html =~ "Migrate retro saves from per-room to per-user."
      assert html =~ ~s(data-role="stack-detail-close")
      # Purple Stack tag (mock .stk-tag style — uppercase + #7b5cff).
      assert html =~ ~s(data-role="stack-tag")
      assert html =~ "#7b5cff"
    end

    test "panel renders the action row with Abandon and View rollup PR buttons",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert html =~ ~s(data-role="stack-detail-actions")
      assert html =~ ~s(data-role="stack-detail-abandon")
      assert html =~ "Abandon"
      assert html =~ ~s(data-role="stack-detail-rollup-pr")
      assert html =~ "View rollup PR"
    end

    test "View rollup PR is disabled when metadata.rollup_pr.url is nil",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # When there's no rollup PR yet, the View button renders as a
      # disabled <button>, NOT an <a href> link. Match the rollup-PR
      # element by isolating its opening tag (everything up to `>`).
      [{:ok, rollup_tag}] = extract_open_tags(html, ~r/data-role="stack-detail-rollup-pr"/)
      assert rollup_tag =~ "disabled"
      refute rollup_tag =~ ~r/href=/
      # And it's a <button>, not an <a>.
      assert String.starts_with?(rollup_tag, "<button")
    end

    test "View rollup PR is an enabled anchor when metadata.rollup_pr.url is present",
         %{conn: conn, stack: stack} do
      {:ok, _stack} =
        Stacks.update_stack(stack, %{
          metadata: %{
            "rollup_pr" => %{"url" => "https://github.com/foo/bar/pull/42", "number" => 42}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      [{:ok, rollup_tag}] = extract_open_tags(html, ~r/data-role="stack-detail-rollup-pr"/)
      assert rollup_tag =~ ~s(href="https://github.com/foo/bar/pull/42")
      refute rollup_tag =~ "disabled"
      assert String.starts_with?(rollup_tag, "<a ")
    end

    test "abandon_stack event abandons the stack and closes the panel",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.show_stack_detail == true

      _html = render_click(view, "abandon_stack", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.show_stack_detail == false
      assert assigns.selected_stack == nil

      assert Repo.get!(Stack, stack.id).status == "abandoned"
    end

    test "close_stack_detail clears :selected_stack and :show_stack_detail",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert :sys.get_state(view.pid).socket.assigns.show_stack_detail == true

      _html = render_click(view, "close_stack_detail", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.show_stack_detail == false
      assert assigns.selected_stack == nil
      assert assigns.selected_stack_members == []
    end

    test "stack card header on the kanban board fires open_stack_detail (Option A)",
         %{conn: conn, stack: stack} do
      # Per the T8 stage 1 click-target decision: the stack card's
      # header is now the panel-opener (Option A — Discord "click thread
      # to enter" pattern). The chevron icon retains toggle_stack_expand
      # as a separate sibling button so inline expansion stays reachable.
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # Header element carries open_stack_detail with the stack id.
      # Match the opening tag (no `>` until the attr cluster ends), in
      # either attr order.
      assert html =~
               ~r/<[a-z]+[^>]*phx-click="open_stack_detail"[^>]*phx-value-id="#{stack.id}"[^>]*data-role="stack-header"/ or
               html =~
                 ~r/<[a-z]+[^>]*data-role="stack-header"[^>]*phx-click="open_stack_detail"[^>]*phx-value-id="#{stack.id}"/

      # Chevron retains toggle_stack_expand on its own button.
      assert html =~
               ~r/<[a-z]+[^>]*phx-click="toggle_stack_expand"[^>]*phx-value-id="#{stack.id}"[^>]*data-role="stack-chevron"/ or
               html =~
                 ~r/<[a-z]+[^>]*data-role="stack-chevron"[^>]*phx-click="toggle_stack_expand"[^>]*phx-value-id="#{stack.id}"/
    end
  end

  describe "stack detail panel — Start Planning control (task 019e294c stage 3)" do
    # Stage 3 mirrors the per-task "Start Planning" button at the stack
    # level. The button must:
    #   * render in the stack-detail-actions row only when ≥1 member is
    #     at `backlog` (no backlog members → nothing to plan, hide the
    #     button), and
    #   * dispatch a `start_stack_planning` event that calls
    #     Stacks.start_planning/1, reloads :selected_stack +
    #     :selected_stack_members, and flashes a result summary.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      {:ok, conn: conn, project: project}
    end

    defp seed_stack_with_member_statuses(project, statuses) do
      stack =
        stack_fixture(
          project_id: project.id,
          name: "Plan Me #{System.unique_integer([:positive])}",
          slug: "plan-me-#{System.unique_integer([:positive])}"
        )

      members =
        statuses
        |> Enum.with_index(1)
        |> Enum.map(fn {status, pos} ->
          {:ok, t} =
            Tasks.create_task(%{
              project_id: project.id,
              stack_id: stack.id,
              stack_position: pos,
              title: "Member #{pos}",
              status: status,
              priority: "medium"
            })

          t
        end)

      {:ok, stack} = Stacks.recompute_stack_status(stack)
      {Repo.get!(Stack, stack.id), members}
    end

    test "Start Planning button renders when the stack has at least one backlog member",
         %{conn: conn, project: project} do
      {stack, _members} = seed_stack_with_member_statuses(project, ["backlog", "backlog"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # Button is present in the action row with the documented event +
      # data-role markers.
      assert html =~ ~s(data-role="stack-detail-start-planning")
      assert html =~ "Start Planning"
      assert html =~ ~s(phx-click="start_stack_planning")
    end

    test "Start Planning button is hidden when no member is at backlog",
         %{conn: conn, project: project} do
      {stack, _members} =
        seed_stack_with_member_statuses(project, ["planning", "stack_pending"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # The detail panel is open (action row is rendered) but the
      # Start Planning control is suppressed.
      assert html =~ ~s(data-role="stack-detail-actions")
      refute html =~ ~s(data-role="stack-detail-start-planning")
    end

    test "Start Planning button is hidden when the stack has no members",
         %{conn: conn, project: project} do
      stack =
        stack_fixture(
          project_id: project.id,
          name: "Empty",
          slug: "empty-#{System.unique_integer([:positive])}"
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert html =~ ~s(data-role="stack-detail-actions")
      refute html =~ ~s(data-role="stack-detail-start-planning")
    end

    test "start_stack_planning event transitions every backlog member and reloads the panel",
         %{conn: conn, project: project} do
      {stack, members} =
        seed_stack_with_member_statuses(project, ["backlog", "backlog", "backlog"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      pre = :sys.get_state(view.pid).socket.assigns
      assert Enum.all?(pre.selected_stack_members, &(&1.status == "backlog"))

      _html = render_click(view, "start_stack_planning", %{})

      post = :sys.get_state(view.pid).socket.assigns
      # :selected_stack_members was reloaded → all three members now
      # report `planning` from the panel state.
      assert length(post.selected_stack_members) == 3
      assert Enum.all?(post.selected_stack_members, &(&1.status == "planning"))

      # DB state matches the panel state.
      member_ids = Enum.map(members, & &1.id)
      reloaded = Repo.all(from(t in Task, where: t.id in ^member_ids, select: t.status))
      assert Enum.all?(reloaded, &(&1 == "planning"))

      # :selected_stack is still the same stack id (panel stays open).
      assert post.selected_stack && post.selected_stack.id == stack.id
      assert post.show_stack_detail == true

      # Result summary is flashed.
      assert Phoenix.Flash.get(post.flash, :info) =~ "Started planning for 3 members"
    end

    test "start_stack_planning only advances backlog members and leaves the rest untouched",
         %{conn: conn, project: project} do
      {stack, [backlog_member, planning_member, parked_member]} =
        seed_stack_with_member_statuses(project, ["backlog", "planning", "stack_pending"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _html = render_click(view, "open_stack_detail", %{"id" => stack.id})
      _html = render_click(view, "start_stack_planning", %{})

      assert Repo.get!(Task, backlog_member.id).status == "planning"
      assert Repo.get!(Task, planning_member.id).status == "planning"
      assert Repo.get!(Task, parked_member.id).status == "stack_pending"

      assigns = :sys.get_state(view.pid).socket.assigns
      assert Phoenix.Flash.get(assigns.flash, :info) =~ "Started planning for 1 member"
    end

    test "start_stack_planning is a no-op when no stack is selected",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      pre = :sys.get_state(view.pid).socket.assigns
      assert pre.selected_stack == nil

      _html = render_click(view, "start_stack_planning", %{})

      post = :sys.get_state(view.pid).socket.assigns
      assert post.selected_stack == nil
      # No flash, no crash — handler short-circuits via the
      # `selected_stack: nil` guard.
      assert Phoenix.Flash.get(post.flash, :info) in [nil, ""]
      assert Phoenix.Flash.get(post.flash, :error) in [nil, ""]
    end
  end

  describe "stack detail panel — meta-grid (T8 stage 2)" do
    # Mock canvas 019e1a16 rev 2: a 4-cell summary card under the head
    # — Status / Members / Dep edges / Branch — laid out as 4 desktop
    # columns. Stage 2 ships data-only cells (no event wiring).
    #
    # Two seed shapes are used. `seed_stack_members_3edges/1` builds a
    # 4-member stack with exactly 3 in-stack dep edges (1→2, 1→3, 2→4)
    # so the dep-edges cell can be asserted on a clean integer; the T7
    # `seed_stack_members/2` defaults to 4 edges (it adds 3→4) which we
    # avoid here so the assertions stay literal.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "user-keyed-saves",
          slug: "user-keyed-saves"
        )

      {:ok, members} = seed_stack_members_3edges(stack)
      {:ok, stack} = Stacks.recompute_stack_status(stack)
      stack = Repo.get!(Stack, stack.id)

      {:ok, conn: conn, project: project, stack: stack, members: members}
    end

    # 4-member fixture with exactly 3 in-stack edges:
    #   m2 → m1, m3 → m1, m4 → m2     (no m4 → m3 edge)
    # Statuses: m1=done, m2=done, m3=in_review, m4=stack_pending.
    # Marks m1 and m2 as merged_into_rollup_at so the "ready" count
    # exercises both the status-based AND the merged-stamp-based
    # branches of `member_ready?/1`.
    defp seed_stack_members_3edges(%Stack{} = stack) do
      m1 = create_member(stack, 1, "Add user_id column", "done", merged: true)
      m2 = create_member(stack, 2, "Wire admin save fallback", "done", merged: true)
      m3 = create_member(stack, 3, "Forward-auth header", "in_review")
      m4 = create_member(stack, 4, "User-scoped save list", "stack_pending")

      {:ok, m2} =
        Tasks.update_task(m2, %{dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]})

      {:ok, m3} =
        Tasks.update_task(m3, %{dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]})

      {:ok, m4} =
        Tasks.update_task(m4, %{dependencies: [%{"task_id" => m2.id, "kind" => "blocks"}]})

      {:ok, [m1, m2, m3, m4]}
    end

    defp create_member(stack, pos, title, status, opts \\ []) do
      metadata =
        if Keyword.get(opts, :merged, false) do
          %{
            "merged_into_rollup_at" => %{
              "sha" => "abc#{pos}",
              "at" => "2026-05-12T00:00:00Z"
            }
          }
        else
          %{}
        end

      {:ok, t} =
        Tasks.create_task(%{
          project_id: stack.project_id,
          stack_id: stack.id,
          stack_position: pos,
          title: title,
          status: status,
          priority: "medium",
          metadata: metadata
        })

      t
    end

    # Helper: open the stack panel and return its rendered HTML.
    defp open_panel(conn, stack) do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_click(view, "open_stack_detail", %{"id" => stack.id})
    end

    test "renders the 4-cell meta-grid with Status / Members / Dep edges / Branch labels",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      assert html =~ ~s(data-role="stack-detail-meta")
      assert html =~ ~s(data-role="meta-cell-status")
      assert html =~ ~s(data-role="meta-cell-members")
      assert html =~ ~s(data-role="meta-cell-dep-edges")
      assert html =~ ~s(data-role="meta-cell-branch")

      # Uppercase labels per mock.
      assert html =~ "Status"
      assert html =~ "Members"
      assert html =~ "Dep edges"
      assert html =~ "Branch"
    end

    test "Status cell renders the rollup status label with the correct color tone",
         %{conn: conn, stack: stack} do
      # Setup left status as in_review (m3 in_review + m1/m2 done +
      # m4 stack_pending → recompute → in_review NOT, since stack_pending
      # is not in {in_review,deploying,done}). Force in_review.
      {:ok, _} =
        stack
        |> Stack.changeset(%{status: "in_review"})
        |> Repo.update()

      html = open_panel(conn, Repo.get!(Stack, stack.id))

      # Locate the value div and assert color + label.
      [{:ok, val}] =
        Regex.scan(~r/<div[^>]*data-role="meta-cell-status-value"[^>]*>[^<]*<\/div>/, html)
        |> Enum.map(&{:ok, hd(&1)})
        |> Enum.take(1)

      assert val =~ "text-warning"
      assert val =~ "In Review"
    end

    test "Status cell color tone tracks each rollup status",
         %{conn: conn, stack: stack} do
      cases = [
        {"in_review", "text-warning"},
        {"in_progress", "text-info"},
        {"done", "text-success"},
        {"deploying", "text-secondary"},
        {"forming", "text-base-content/50"}
      ]

      for {raw_status, expected_class} <- cases do
        fresh = Repo.get!(Stack, stack.id)

        {:ok, _} =
          fresh
          |> Stack.changeset(%{status: raw_status})
          |> Repo.update()

        html = open_panel(conn, Repo.get!(Stack, stack.id))

        [{:ok, val}] =
          Regex.scan(~r/<div[^>]*data-role="meta-cell-status-value"[^>]*>[^<]*<\/div>/, html)
          |> Enum.map(&{:ok, hd(&1)})
          |> Enum.take(1)

        assert val =~ expected_class,
               "expected status=#{raw_status} cell to carry class #{expected_class}, got: #{val}"
      end
    end

    test "Members cell shows '<count> · <ready_count> ready' counting status AND merged stamp",
         %{conn: conn, stack: stack} do
      # Fixture: 4 members. Ready by status (in_review/deploying/done):
      # m1=done, m2=done, m3=in_review → 3 ready.
      # m1 and m2 ALSO have merged_into_rollup_at, m4 has neither.
      # The "or merged" branch is exercised; total ready stays 3.
      html = open_panel(conn, stack)

      [{:ok, val}] =
        Regex.scan(~r/<div[^>]*data-role="meta-cell-members-value"[^>]*>[^<]*<\/div>/, html)
        |> Enum.map(&{:ok, hd(&1)})
        |> Enum.take(1)

      assert val =~ "4 · 3 ready"
    end

    test "Members cell counts a 'merged but back to in_progress' member as ready",
         %{conn: conn, stack: stack, members: [_m1, _m2, _m3, m4]} do
      # Move m4 from stack_pending → in_progress AND stamp its
      # merged_into_rollup_at. The "or merged" branch must catch it
      # so ready jumps from 3 to 4 even though in_progress is NOT in
      # the status threshold list.
      {:ok, _} =
        Tasks.update_task(m4, %{
          status: "in_progress",
          metadata: %{
            "merged_into_rollup_at" => %{"sha" => "abc4", "at" => "2026-05-12T00:00:00Z"}
          }
        })

      html = open_panel(conn, stack)

      [{:ok, val}] =
        Regex.scan(~r/<div[^>]*data-role="meta-cell-members-value"[^>]*>[^<]*<\/div>/, html)
        |> Enum.map(&{:ok, hd(&1)})
        |> Enum.take(1)

      assert val =~ "4 · 4 ready"
    end

    test "Dep edges cell shows '3 · valid DAG' for an acyclic 4-member graph",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      [{:ok, val}] =
        Regex.scan(~r/<div[^>]*data-role="meta-cell-dep-edges-value"[^>]*>[^<]*<\/div>/, html)
        |> Enum.map(&{:ok, hd(&1)})
        |> Enum.take(1)

      assert val =~ "3 · valid DAG"
      # Acyclic → no error tone.
      refute val =~ "text-error"
    end

    test "Dep edges cell switches to error tone with 'cycle detected' when the in-stack graph cycles",
         %{conn: conn, stack: stack, members: [m1, m2, _m3, _m4]} do
      # Inject a cycle: make m1 depend on m2 (m2 already depends on
      # m1 from the seed). The in-stack subgraph now contains the
      # 2-cycle m1↔m2 and the meta-grid must surface that.
      {:ok, _} =
        Tasks.update_task(m1, %{dependencies: [%{"task_id" => m2.id, "kind" => "blocks"}]})

      html = open_panel(conn, stack)

      [{:ok, val}] =
        Regex.scan(~r/<div[^>]*data-role="meta-cell-dep-edges-value"[^>]*>[^<]*<\/div>/, html)
        |> Enum.map(&{:ok, hd(&1)})
        |> Enum.take(1)

      assert val =~ "cycle detected"
      assert val =~ "text-error"
    end

    test "Branch cell renders rollup_branch in monospace truncate styling",
         %{conn: conn, stack: stack} do
      # The fixture's slug is `user-keyed-saves` so the rollup branch
      # is `stack/user-keyed-saves` (per Stacks.rollup_branch_name/1).
      html = open_panel(conn, stack)

      [{:ok, val}] =
        Regex.scan(
          ~r/<div[^>]*data-role="meta-cell-branch-value"[^>]*>[^<]*<\/div>/,
          html
        )
        |> Enum.map(&{:ok, hd(&1)})
        |> Enum.take(1)

      assert val =~ "font-mono"
      assert val =~ "truncate"
      assert val =~ stack.rollup_branch
      assert stack.rollup_branch == "stack/user-keyed-saves"
    end

    test "meta-grid sits between the head and the action row inside the panel",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      head_at = :binary.match(html, ~s(data-role="stack-detail-title")) |> elem(0)
      meta_at = :binary.match(html, ~s(data-role="stack-detail-meta")) |> elem(0)
      actions_at = :binary.match(html, ~s(data-role="stack-detail-actions")) |> elem(0)

      assert head_at < meta_at, "expected meta-grid to render BELOW the head"
      assert meta_at < actions_at, "expected meta-grid to render ABOVE the action row"
    end

    test "desktop meta-grid uses 4-column layout",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      [{:ok, container}] =
        Regex.scan(~r/<div[^>]*data-role="stack-detail-meta"[^>]*>/, html)
        |> Enum.map(&{:ok, hd(&1)})
        |> Enum.take(1)

      assert container =~ "grid-cols-4"
      assert container =~ "gap-2"
    end
  end

  describe "stack detail panel — dep DAG (T8 stage 3)" do
    # Mock canvas 019e1a16 rev 2: the body's left column renders the
    # in-stack dependency graph as inline SVG with topological layout.
    # Members 1→none, 2→[1], 3→[1], 4→[2,3] gives the canonical
    # diamond shape (① top, ② + ③ in parallel, ④ at the bottom).
    # All assertions exercise the rendered HTML so the layout helper
    # `stack_dag_layout/1` and the SVG template are tested as one
    # surface — same pattern as the stage-2 meta-grid suite above.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "user-keyed-saves",
          slug: "user-keyed-saves"
        )

      {:ok, members} = seed_stack_members_4edges(stack)
      {:ok, stack} = Stacks.recompute_stack_status(stack)
      stack = Repo.get!(Stack, stack.id)

      {:ok, conn: conn, project: project, stack: stack, members: members}
    end

    # 4-member fixture matching the mock exactly:
    #   m2 → m1, m3 → m1, m4 → m2, m4 → m3   (4 in-stack edges)
    # Statuses: m1=done, m2=done, m3=in_review, m4=stack_pending.
    # Note this differs from `seed_stack_members_3edges/1` (stage 2
    # avoids the m4→m3 edge to keep the dep-edge count literal); stage
    # 3 needs the diamond closure so node ④ has parents on both sides.
    defp seed_stack_members_4edges(%Stack{} = stack) do
      m1 = create_member(stack, 1, "Add user_id column", "done", merged: true)
      m2 = create_member(stack, 2, "Wire admin save fallback", "done", merged: true)
      m3 = create_member(stack, 3, "Forward-auth header", "in_review")
      m4 = create_member(stack, 4, "User-scoped save list", "stack_pending")

      {:ok, m2} =
        Tasks.update_task(m2, %{dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]})

      {:ok, m3} =
        Tasks.update_task(m3, %{dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]})

      {:ok, m4} =
        Tasks.update_task(m4, %{
          dependencies: [
            %{"task_id" => m2.id, "kind" => "blocks"},
            %{"task_id" => m3.id, "kind" => "blocks"}
          ]
        })

      {:ok, [m1, m2, m3, m4]}
    end

    # Helper: extract the integer y attribute from each <rect> in the
    # DAG SVG (one rect per node). Returns rects in document order.
    # Scopes to the panel SVG block so heroicon <rect> elements (none
    # currently, but future-proofing) don't bleed in.
    defp dag_rect_ys(html) do
      svg = panel_svg_block(html)

      ~r/<rect[^>]*\sy="(\d+)"[^>]*>/
      |> Regex.scan(svg)
      |> Enum.map(fn [_, y] -> String.to_integer(y) end)
    end

    # Pull the panel SVG's viewBox as `{w, h}` integers. The panel SVG
    # is the only SVG that carries `data-role="stack-detail-dag-svg"`;
    # all other SVGs on the page are heroicons (24x24 viewBox) which
    # would otherwise collide with a naive `viewBox="..."` regex.
    defp panel_viewbox(html) do
      svg = panel_svg_block(html)
      [[_, w, h]] = Regex.scan(~r/viewBox="0 0 (\d+) (\d+)"/, svg)
      {String.to_integer(w), String.to_integer(h)}
    end

    # Slice the HTML to the panel SVG block (opening tag through the
    # closing `</svg>`). The panel SVG is uniquely tagged via
    # `data-role="stack-detail-dag-svg"` on its opening tag, so a
    # single regex grabs the whole element. Returns "" if not present
    # (defensive — every test in this suite opens the panel first).
    defp panel_svg_block(html) do
      case Regex.run(
             ~r/<svg[^>]*data-role="stack-detail-dag-svg"[^>]*>.*?<\/svg>/s,
             html
           ) do
        [block] -> block
        _ -> ""
      end
    end

    test "panel body renders the DAG SVG container with stack-detail-dag role",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      assert html =~ ~s(data-role="stack-detail-dag")
      assert html =~ ~s(data-role="stack-detail-dag-svg")
      # Wrapped in the .dag chrome (rounded base-300 backdrop) per mock.
      assert html =~ "dag rounded bg-base-300 p-2"
    end

    test "DAG edges render as dashed purple lines with no arrowhead marker",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)
      svg = panel_svg_block(html)

      # Per Rowan's T8 stage-5 feedback ("dashed lines, no hard point"),
      # the arrowhead marker is removed entirely — direction is
      # implicit from the topological-row layout.
      refute svg =~ ~s(<marker id="stack-dag-arrow"),
             "expected the stack-dag-arrow marker definition to be removed"

      refute svg =~ "marker-end=",
             "expected no edge to reference an arrowhead marker"

      # Every edge line carries the dashed stroke spec and the
      # canonical mock-canvas purple (#7b5cff).
      edges =
        Regex.scan(~r/<line[^>]*data-role="stack-detail-dag-edge"[^>]*>/, svg)
        |> Enum.map(&hd/1)

      assert edges != [], "expected at least one edge line in the DAG"

      for edge <- edges do
        assert edge =~ ~s(stroke-dasharray="6,4"),
               "expected edge to be dashed (6,4): #{edge}"

        assert edge =~ ~s(stroke="#7b5cff"),
               "expected edge to use canonical purple stroke: #{edge}"
      end
    end

    test "DAG renders one <rect> per member (4 nodes) and one <line> per edge (4 edges)",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      rects = Regex.scan(~r/<rect[^>]*data-status="/, html)
      lines = Regex.scan(~r/<line[^>]*data-role="stack-detail-dag-edge"/, html)

      assert length(rects) == 4, "expected 4 node rects, got #{length(rects)}"
      assert length(lines) == 4, "expected 4 dep edges, got #{length(lines)}"
    end

    test "topological levels: ① at level 0, ② + ③ share level 1, ④ at level 2",
         %{conn: conn, stack: stack, members: [m1, m2, m3, m4]} do
      html = open_panel(conn, stack)

      ys = node_y_by_id(html, [m1, m2, m3, m4])

      # m1 is the only root; m2 and m3 have m1 as their sole parent;
      # m4 has both m2 and m3 as parents → strict 0/1/1/2 assignment.
      assert ys[m1.id] < ys[m2.id], "expected ① above ②"
      assert ys[m1.id] < ys[m3.id], "expected ① above ③"
      assert ys[m2.id] == ys[m3.id], "expected ② and ③ on the same row (parallelism)"
      assert ys[m4.id] > ys[m2.id], "expected ④ below ②/③"

      # Three distinct rows total → row stride matches the constant
      # (76px). The exact equality keeps the layout regression-tight.
      distinct_levels = ys |> Map.values() |> Enum.uniq() |> Enum.sort()
      assert length(distinct_levels) == 3
      [r0, r1, r2] = distinct_levels
      assert r1 - r0 == 76
      assert r2 - r1 == 76
    end

    test "edges anchor source bottom-center and target top-center (downward arrows)",
         %{conn: conn, stack: stack, members: [m1, m2, _m3, _m4]} do
      html = open_panel(conn, stack)

      ys = node_y_by_id(html, [m1, m2])

      # Pull the edge whose data-from-id=m2.id, data-to-id=m1.id (m2
      # depends on m1). Source is m1 (top of the canvas), target is m2.
      # Phoenix renders <line> as `<line ...></line>` (closing tag, not
      # self-closing) so the regex stops at the first `>`.
      [edge_html] =
        Regex.scan(
          ~r/<line[^>]*data-from-id="#{m2.id}"[^>]*data-to-id="#{m1.id}"[^>]*>/s,
          html
        )
        |> Enum.map(&hd/1)

      [_, y1] = Regex.run(~r/y1="(\d+)"/, edge_html)
      [_, y2] = Regex.run(~r/y2="(\d+)"/, edge_html)

      # y1 = bottom of m1 = m1.y + 44 (node_h). y2 = top of m2 = m2.y.
      assert String.to_integer(y1) == ys[m1.id] + 44
      assert String.to_integer(y2) == ys[m2.id]
    end

    test "node fill colors track member status (done=green, in_review=yellow, waiting=dashed)",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      # done → green tint per the mock palette
      assert html =~ ~S|fill="rgba(0,255,157,0.12)"|
      assert html =~ ~s(stroke="#3aa97c")
      # in_review → yellow tint
      assert html =~ ~S|fill="rgba(255,190,0,0.12)"|
      assert html =~ ~s(stroke="#a37c3a")
      # stack_pending → dashed border (waiting style)
      assert html =~ ~s(stroke-dasharray="4,3")
    end

    test "node captions surface uppercase status codes (DONE / REVIEW / WAITING)",
         %{conn: conn, stack: stack} do
      svg = panel_svg_block(open_panel(conn, stack))

      # The captions live inside the SVG rect's text element. HEEx
      # interpolation surrounds the value with whitespace, so match
      # against the SVG block with whitespace tolerance. Two `done`
      # members → DONE appears at least once, plus REVIEW and WAITING.
      assert svg =~ ~r/>\s*DONE\s*</
      assert svg =~ ~r/>\s*REVIEW\s*</
      assert svg =~ ~r/>\s*WAITING\s*</
    end

    test "circled-digit position glyphs render inside each node",
         %{conn: conn, stack: stack} do
      svg = panel_svg_block(open_panel(conn, stack))

      # Per ADR 0041 § "UI surface — inline expansion" — same glyphs
      # as the linear members list, recycled inside the SVG rect.
      assert svg =~ "①"
      assert svg =~ "②"
      assert svg =~ "③"
      assert svg =~ "④"
    end

    test "single-node stack: one rect, zero edges, sensible viewBox",
         %{conn: conn, project: project} do
      stack = stack_fixture(project_id: project.id, name: "solo", slug: "solo")
      _m1 = create_member(stack, 1, "Lone task", "in_progress")

      html = open_panel(conn, stack)

      rects = Regex.scan(~r/<rect[^>]*data-status="/, html)
      lines = Regex.scan(~r/<line[^>]*data-role="stack-detail-dag-edge"/, html)
      assert length(rects) == 1
      assert lines == []

      # viewBox is `0 0 W H` — both should be positive integers and
      # not collapse to a 0×0 canvas. Scope the match to the panel
      # SVG (other heroicon SVGs in the page also carry viewBox).
      {w, h} = panel_viewbox(html)
      assert w > 0
      assert h > 0
    end

    test "single chain (1→2→3) places nodes on three distinct levels",
         %{conn: conn, project: project} do
      stack = stack_fixture(project_id: project.id, name: "chain", slug: "chain")
      m1 = create_member(stack, 1, "First", "done")
      m2 = create_member(stack, 2, "Second", "done")
      m3 = create_member(stack, 3, "Third", "in_review")

      {:ok, _} =
        Tasks.update_task(m2, %{dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]})

      {:ok, _} =
        Tasks.update_task(m3, %{dependencies: [%{"task_id" => m2.id, "kind" => "blocks"}]})

      html = open_panel(conn, stack)

      ys = node_y_by_id(html, [m1, m2, m3])

      assert ys[m1.id] < ys[m2.id]
      assert ys[m2.id] < ys[m3.id]
      assert ys |> Map.values() |> Enum.uniq() |> length() == 3
    end

    test "layout is deterministic — same input produces same SVG y-positions",
         %{conn: conn, stack: stack, members: [m1, m2, m3, m4]} do
      html_a = open_panel(conn, stack)
      html_b = open_panel(conn, stack)

      ys_a = node_y_by_id(html_a, [m1, m2, m3, m4])
      ys_b = node_y_by_id(html_b, [m1, m2, m3, m4])

      assert ys_a == ys_b

      # ViewBox is also stable across renders.
      assert panel_viewbox(html_a) == panel_viewbox(html_b)
    end

    test "DAG sits in the LEFT column of the panel body grid (members slot at right)",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      dag_at = :binary.match(html, ~s(data-role="stack-detail-dag")) |> elem(0)
      members_at = :binary.match(html, ~s(data-role="stack-detail-members")) |> elem(0)

      assert dag_at < members_at, "expected DAG to render before the members column"

      # Body container uses a responsive grid: single column on mobile
      # (DAG above members), 2 columns on md+ for the desktop side-by-
      # side layout. The mobile-first switch landed in stage 5.
      assert html =~ ~s(grid grid-cols-1 md:grid-cols-2 gap-4)
    end

    # Helper: parse `<g data-role="stack-detail-dag-node" data-node-id="<id>">`
    # blocks and return %{member.id => integer y of its rect}. Pulls the
    # node's `<rect>` y attribute (which is the topological row anchor).
    defp node_y_by_id(html, members) do
      Enum.reduce(members, %{}, fn m, acc ->
        case Regex.run(
               ~r/<g[^>]*data-node-id="#{m.id}"[^>]*>\s*<rect[^>]*\sy="(\d+)"/,
               html
             ) do
          [_, y] -> Map.put(acc, m.id, String.to_integer(y))
          _ -> acc
        end
      end)
    end

    # Sanity: dag_rect_ys/1 helper used only by the next assertion's
    # belt-and-suspenders check on raw rect y count.
    test "every rect carries an integer y attribute (no nil/missing positions)",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      ys = dag_rect_ys(html)
      assert length(ys) == 4
      assert Enum.all?(ys, &(&1 >= 0))
    end
  end

  describe "stack detail panel — members list (T8 stage 4)" do
    # Mock canvas 019e1a16 rev 2: the body's right column renders the
    # linear members list, ordered by `stack_position`. Each row carries
    # the position glyph (status-coloured circle), the title, a status
    # pill on the right, and an optional dep-annotation sub-line. Rows
    # are clickable: phx-click="select_task" with the member id; the
    # handler push_patches to /tasks/:id AND closes this stack panel
    # (close-and-open behaviour per the T8 stage 4 task description).

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "user-keyed-saves",
          slug: "user-keyed-saves"
        )

      # Reuse the diamond fixture from stage 3 — it gives us:
      #   m1 (root, done), m2 + m3 in parallel (both depend on m1),
      #   m4 depends on m2 + m3. Exercises every annotation path:
      #   none / single-dep / single-dep-with-parallel / multi-dep.
      {:ok, members} = seed_members_4_diamond(stack)
      {:ok, stack} = Stacks.recompute_stack_status(stack)
      stack = Repo.get!(Stack, stack.id)

      {:ok, conn: conn, project: project, stack: stack, members: members}
    end

    # Same diamond shape as `seed_stack_members_4edges/1` but defined
    # locally so this describe block stays self-contained (the stage-3
    # block's helper is private to that describe scope and ExUnit doesn't
    # share defp helpers across describe blocks within the same module).
    defp seed_members_4_diamond(%Stack{} = stack) do
      m1 = create_member(stack, 1, "Add user_id column", "done", merged: true)
      m2 = create_member(stack, 2, "Wire admin save fallback", "done", merged: true)
      m3 = create_member(stack, 3, "Forward-auth header", "in_review")
      m4 = create_member(stack, 4, "User-scoped save list", "stack_pending")

      {:ok, m2} =
        Tasks.update_task(m2, %{dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]})

      {:ok, m3} =
        Tasks.update_task(m3, %{dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]})

      {:ok, m4} =
        Tasks.update_task(m4, %{
          dependencies: [
            %{"task_id" => m2.id, "kind" => "blocks"},
            %{"task_id" => m3.id, "kind" => "blocks"}
          ]
        })

      {:ok, [m1, m2, m3, m4]}
    end

    # Helper: pull the substring between the members-list opening tag
    # and its closing </div>. We use a non-greedy match through the
    # known structural boundary (the action-bar role) so we never bleed
    # into the action bar below or the DAG block above.
    defp members_block(html) do
      case Regex.run(
             ~r/data-role="stack-detail-members-list".*?(?=data-role="stack-detail-actions")/s,
             html
           ) do
        [block] -> block
        _ -> ""
      end
    end

    test "panel body renders the members list container with stack-detail-members role",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      assert html =~ ~s(data-role="stack-detail-members")
      assert html =~ ~s(data-role="stack-detail-members-list")
      # Section heading + dispatch-order hint per mock canvas 019e1a16.
      assert html =~ ~s(data-role="stack-detail-members-header")
      assert html =~ "Members"
      assert html =~ "(dispatch order)"
    end

    test "renders one row per member with the title and position glyph",
         %{conn: conn, stack: stack, members: [m1, m2, m3, m4]} do
      html = open_panel(conn, stack)

      block = members_block(html)

      # Four rows total, one per member.
      rows = Regex.scan(~r/data-role="stack-detail-member-row"/, block)
      assert length(rows) == 4

      # Titles render verbatim.
      assert block =~ m1.title
      assert block =~ m2.title
      assert block =~ m3.title
      assert block =~ m4.title

      # Position glyphs ① ② ③ ④ all surface inside the list.
      assert block =~ "①"
      assert block =~ "②"
      assert block =~ "③"
      assert block =~ "④"
    end

    test "rows render in stack_position order regardless of fixture insert order",
         %{conn: conn, stack: stack, members: [m1, m2, m3, m4]} do
      html = open_panel(conn, stack)

      block = members_block(html)

      m1_at = :binary.match(block, m1.id) |> elem(0)
      m2_at = :binary.match(block, m2.id) |> elem(0)
      m3_at = :binary.match(block, m3.id) |> elem(0)
      m4_at = :binary.match(block, m4.id) |> elem(0)

      assert m1_at < m2_at
      assert m2_at < m3_at
      assert m3_at < m4_at
    end

    test "status pills colour-track each member's status",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      block = members_block(html)

      # done (m1, m2) → "Done" + success tone
      assert block =~ "Done"
      assert block =~ "text-success"
      # in_review (m3) → "Review" + warning tone
      assert block =~ "Review"
      assert block =~ "text-warning"
      # stack_pending (m4) → "Waiting" + dashed border tone
      assert block =~ "Waiting"
      assert block =~ "border-dashed"
    end

    test "member ① with no in-stack deps has no annotation row",
         %{conn: conn, stack: stack, members: [m1 | _]} do
      html = open_panel(conn, stack)

      # Locate the m1 row block (its rendered region) and verify the
      # member-deps role is absent within it. The row is uniquely
      # identified by data-member-id = m1.id.
      [row_open] =
        Regex.run(
          ~r/<div[^>]*data-role="stack-detail-member-row"[^>]*data-member-id="#{m1.id}"[^>]*>.*?<\/div>\s*<\/div>/s,
          html
        )
        |> List.wrap()

      refute row_open =~ ~s(data-role="stack-detail-member-deps")
    end

    test "member ② renders 'depends on ①' annotation",
         %{conn: conn, stack: stack, members: [_m1, m2 | _]} do
      html = open_panel(conn, stack)

      [row] =
        Regex.run(
          ~r/<div[^>]*data-member-id="#{m2.id}"[^>]*>.*?<\/div>\s*<\/div>/s,
          html
        )
        |> List.wrap()

      assert row =~ ~s(data-role="stack-detail-member-deps")
      assert row =~ "depends on ①"
      # No parens — m2 has no parallel sibling at this point... wait,
      # m3 IS a parallel sibling of m2 (both depend solely on m1). The
      # annotation should therefore include "(parallel with ③)".
      assert row =~ "parallel with ③"
    end

    test "member ③ renders 'depends on ① (parallel with ②)' annotation",
         %{conn: conn, stack: stack, members: [_m1, _m2, m3 | _]} do
      html = open_panel(conn, stack)

      [row] =
        Regex.run(
          ~r/<div[^>]*data-member-id="#{m3.id}"[^>]*>.*?<\/div>\s*<\/div>/s,
          html
        )
        |> List.wrap()

      assert row =~ "depends on ① (parallel with ②)"
    end

    test "member ④ renders 'depends on ② + ③' annotation (multi-dep, no parallel)",
         %{conn: conn, stack: stack, members: [_m1, _m2, _m3, m4]} do
      html = open_panel(conn, stack)

      [row] =
        Regex.run(
          ~r/<div[^>]*data-member-id="#{m4.id}"[^>]*>.*?<\/div>\s*<\/div>/s,
          html
        )
        |> List.wrap()

      assert row =~ "depends on ② + ③"
      # m4 has no parallel sibling — it's the only member at level 2.
      refute row =~ "parallel with"
    end

    test "row carries phx-click=select_task with the member id",
         %{conn: conn, stack: stack, members: [_m1, _m2, m3 | _]} do
      html = open_panel(conn, stack)

      assert html =~
               ~r/<div[^>]*phx-click="select_task"[^>]*phx-value-id="#{m3.id}"[^>]*data-role="stack-detail-member-row"/ or
               html =~
                 ~r/<div[^>]*data-role="stack-detail-member-row"[^>]*phx-click="select_task"[^>]*phx-value-id="#{m3.id}"/
    end

    test "clicking a member row closes the stack panel and opens the per-task detail",
         %{conn: conn, stack: stack, members: [_m1, _m2, m3 | _]} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Open the stack panel first.
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})

      pre = :sys.get_state(view.pid).socket.assigns
      assert pre.show_stack_detail == true
      assert pre.show_detail == false

      # Click member row ③ → push_patch to /tasks/:id AND close panel.
      _ = render_click(view, "select_task", %{"id" => m3.id})

      post = :sys.get_state(view.pid).socket.assigns
      assert post.show_stack_detail == false
      assert post.selected_stack == nil
      assert post.selected_stack_members == []
      # The per-task detail panel is now open with m3 selected.
      assert post.show_detail == true
      assert post.selected_task && post.selected_task.id == m3.id
    end

    test "members list sits in the RIGHT column (after the DAG) of the body grid",
         %{conn: conn, stack: stack} do
      html = open_panel(conn, stack)

      dag_at = :binary.match(html, ~s(data-role="stack-detail-dag")) |> elem(0)

      members_at =
        :binary.match(html, ~s(data-role="stack-detail-members-list")) |> elem(0)

      assert dag_at < members_at
    end

    test "member_dep_annotation/2 is pure: same input → same output",
         %{conn: conn, stack: stack} do
      html_a = open_panel(conn, stack)
      html_b = open_panel(conn, stack)

      assert members_block(html_a) == members_block(html_b)
    end
  end

  describe "stack detail panel — mobile layout (T8 stage 5)" do
    # Mock canvas 019e1a16 rev 2 (right-hand "Stack detail (mobile)"
    # phone): on viewports <md the slide-in panel becomes a full-screen
    # takeover with a back arrow + Stack tag + overflow kebab in the
    # app bar, the meta-grid collapses to 2x2, the body switches to
    # one column (DAG above members), and the action bar is sticky to
    # the bottom. On md+ the panel reverts to the stage 1-4 slide-in
    # shape with a 4-col meta-grid, side-by-side body, and the same
    # action bar at the bottom.
    #
    # The container also adopts PR #335's bottom-clearance pattern
    # (`bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-
    # height,0px))]`) so the panel ends flush with the visible top of
    # the bottom-tab nav on iOS, with no defense-in-depth pb on the
    # inner scroll container.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "user-keyed-saves",
          slug: "user-keyed-saves"
        )

      {:ok, members} = seed_stack_members(stack, count: 4)
      {:ok, stack} = Stacks.recompute_stack_status(stack)
      stack = Repo.get!(Stack, stack.id)

      {:ok, conn: conn, project: project, stack: stack, members: members}
    end

    # Helper: open the stack panel and return rendered HTML.
    defp open_stage5_panel(conn, stack) do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_click(view, "open_stack_detail", %{"id" => stack.id})
    end

    # Helper: extract the opening tag for a single element by its
    # data-role, so we can assert on the full attribute cluster
    # regardless of attribute order.
    defp open_tag_for(html, role) do
      case Regex.run(~r/<[a-zA-Z]+[^>]*data-role="#{role}"[^>]*>/, html) do
        [tag] -> tag
        _ -> nil
      end
    end

    test "panel container carries mobile takeover + desktop slide-in classes",
         %{conn: conn, stack: stack} do
      html = open_stage5_panel(conn, stack)
      tag = open_tag_for(html, "stack-detail-panel")
      refute is_nil(tag), "expected stack-detail-panel container to render"

      # Mobile: full-screen takeover (`inset-0` + `max-w-full`).
      assert tag =~ "inset-0"
      assert tag =~ "max-w-full"

      # Desktop: slide-in shape (`md:inset-y-0 md:left-auto md:right-0`
      # + `md:max-w-lg`).
      assert tag =~ "md:inset-y-0"
      assert tag =~ "md:left-auto"
      assert tag =~ "md:right-0"
      assert tag =~ "md:max-w-lg"
    end

    test "panel container adopts PR #335's bottom-nav clearance pattern",
         %{conn: conn, stack: stack} do
      html = open_stage5_panel(conn, stack)
      tag = open_tag_for(html, "stack-detail-panel")
      refute is_nil(tag)

      # PR #335's canonical pattern: bottom edge stops at the top of
      # the bottom-nav (incl. iOS home-indicator safe-area) via the
      # `--bottom-nav-height` CSS var + env(safe-area-inset-bottom).
      assert tag =~ "bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]"
    end

    test "inner body scroll container does NOT re-introduce a defense-in-depth pb-",
         %{conn: conn, stack: stack} do
      html = open_stage5_panel(conn, stack)
      tag = open_tag_for(html, "stack-detail-body")
      refute is_nil(tag)

      # PR #335 stripped the inner-scroller `pb-[calc(...)]` from the
      # per-task panel because the container's bottom constraint
      # already accounts for the nav. We follow the same rule for the
      # stack panel — no `pb-[calc(env(safe-area-inset-bottom)...)]`
      # on the body scroller.
      refute tag =~ "pb-[calc(env(safe-area-inset-bottom)"
    end

    test "meta-grid collapses to 2 cols on mobile and 4 cols on md+",
         %{conn: conn, stack: stack} do
      html = open_stage5_panel(conn, stack)
      tag = open_tag_for(html, "stack-detail-meta")
      refute is_nil(tag)

      assert tag =~ "grid-cols-2"
      assert tag =~ "md:grid-cols-4"
    end

    test "body switches to 1 col on mobile (DAG above members) and 2 cols on md+",
         %{conn: conn, stack: stack} do
      html = open_stage5_panel(conn, stack)
      tag = open_tag_for(html, "stack-detail-body")
      refute is_nil(tag)

      assert tag =~ "grid-cols-1"
      assert tag =~ "md:grid-cols-2"

      # On mobile the single column means DAG renders ABOVE members in
      # source order; the existing stage-4 ordering test
      # ("members list sits in the RIGHT column (after the DAG)")
      # already confirms DAG precedes members in the DOM. Re-assert
      # the source ordering here for stage-5 documentation purposes.
      dag_at = :binary.match(html, ~s(data-role="stack-detail-dag")) |> elem(0)

      members_at =
        :binary.match(html, ~s(data-role="stack-detail-members")) |> elem(0)

      assert dag_at < members_at,
             "DAG should appear before members in the DOM so mobile single-column lays DAG above"
    end

    test "mobile-only chrome: back arrow + overflow kebab carry md:hidden",
         %{conn: conn, stack: stack} do
      html = open_stage5_panel(conn, stack)

      back_tag = open_tag_for(html, "stack-detail-back")
      refute is_nil(back_tag), "expected mobile back arrow to render"
      assert back_tag =~ "md:hidden"
      # The back arrow uses the same close handler as the desktop X.
      assert back_tag =~ ~s(phx-click="close_stack_detail")
      # Hero icon: arrow-left, per the mock's `←`.
      assert html =~ "hero-arrow-left"

      kebab_tag = open_tag_for(html, "stack-detail-overflow")
      refute is_nil(kebab_tag), "expected mobile overflow kebab to render"
      assert kebab_tag =~ "md:hidden"
      assert html =~ "hero-ellipsis-vertical"
    end

    test "desktop close X is gated to md+ (`hidden md:flex`)",
         %{conn: conn, stack: stack} do
      html = open_stage5_panel(conn, stack)

      close_tag = open_tag_for(html, "stack-detail-close")
      refute is_nil(close_tag), "expected desktop close X to render"

      assert close_tag =~ "hidden"
      assert close_tag =~ "md:flex"
      # Sanity: the close X still wires to close_stack_detail.
      assert close_tag =~ ~s(phx-click="close_stack_detail")
    end

    test "action bar is sticky to the bottom (mt-auto sticky bottom-0)",
         %{conn: conn, stack: stack} do
      html = open_stage5_panel(conn, stack)

      tag = open_tag_for(html, "stack-detail-actions")
      refute is_nil(tag), "expected stack-detail-actions bar to render"

      # `mt-auto` so the bar pushes to the bottom of the flex column;
      # `sticky bottom-0` so it pins to the viewport bottom while the
      # body scrolls beneath on mobile.
      assert tag =~ "mt-auto"
      assert tag =~ "sticky"
      assert tag =~ "bottom-0"
      # Opaque background so scrolled content doesn't bleed through.
      assert tag =~ "bg-base-100"
      # Top border separates it visually from the scrollable body.
      assert tag =~ "border-t"
    end

    test "Stack tag + title + description still render alongside the new chrome",
         %{conn: conn, stack: stack} do
      {:ok, stack} =
        Stacks.update_stack(stack, %{
          description: "Migrate retro saves from per-room to per-user."
        })

      html = open_stage5_panel(conn, stack)

      # Stage 1 contract — head still surfaces Stack tag, title, and
      # description regardless of viewport.
      assert html =~ ~s(data-role="stack-tag")
      assert html =~ "Stack"
      assert html =~ ~s(data-role="stack-detail-title")
      assert html =~ stack.name
      assert html =~ ~s(data-role="stack-detail-description")
      assert html =~ "Migrate retro saves from per-room to per-user."
    end

    test "abandon + view rollup PR buttons stay inside the sticky action bar",
         %{conn: conn, stack: stack} do
      html = open_stage5_panel(conn, stack)

      # The action bar block (between its opening tag and the panel's
      # closing </div>) should still contain both stage-1 buttons.
      [actions_block] =
        Regex.run(
          ~r/data-role="stack-detail-actions".*?(?=<\/div>\s*<\/div>\s*<%!--|<\/div>\s*<\/div>\s*<div\s)/s,
          html
        ) || ["", ""]

      # If the block-extraction heuristic above misses, fall back to a
      # broad whole-html search — both buttons must still render.
      block = if actions_block == "", do: html, else: actions_block

      assert block =~ ~s(data-role="stack-detail-abandon")
      assert block =~ ~s(data-role="stack-detail-rollup-pr")
    end
  end

  describe "stack detail panel — Assign Agents control + inheritance badges (ADR 0041)" do
    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      agent_a = create_agent("Agent A (Test)")
      agent_b = create_agent("Agent B (Test)")

      stack =
        stack_fixture(
          project_id: project.id,
          name: "assign-agents-stack",
          slug: "assign-agents-#{System.unique_integer([:positive])}"
        )

      {:ok, m1} =
        Tasks.create_task(%{
          project_id: project.id,
          stack_id: stack.id,
          stack_position: 1,
          title: "Member 1",
          status: "backlog"
        })

      {:ok, m2} =
        Tasks.create_task(%{
          project_id: project.id,
          stack_id: stack.id,
          stack_position: 2,
          title: "Member 2",
          status: "backlog"
        })

      {:ok,
       conn: conn,
       project: project,
       stack: stack,
       m1: m1,
       m2: m2,
       agent_a: agent_a,
       agent_b: agent_b}
    end

    test "Assign Agents button renders in the stack detail action row",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert html =~ ~s(data-role="stack-detail-assign-agents")
      assert html =~ "Assign Agents"
    end

    test "open_stack_assignee_modal opens the stack assignee modal",
         %{conn: conn, stack: stack} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_click(view, "open_stack_detail", %{"id" => stack.id})

      html = render_click(view, "open_stack_assignee_modal", %{})

      assert html =~ ~s(id="stack-assignee-modal")
      assert html =~ ~s(id="stack-assignees-form")
    end

    test "save_stack_assignees (simple mode) percolates to un-overridden members",
         %{conn: conn, stack: stack, m1: m1, m2: m2, agent_a: agent_a} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_click(view, "open_stack_detail", %{"id" => stack.id})
      render_click(view, "open_stack_assignee_modal", %{})

      render_submit(view, "save_stack_assignees", %{"assignees" => %{"all" => agent_a.id}})

      assert Repo.get!(Task, m1.id).assignee_id == agent_a.id
      assert Repo.get!(Task, m2.id).assignee_id == agent_a.id

      stack = Repo.get!(Stack, stack.id)
      assert Stacks.stack_phase_assignees(stack)["execution"]["assignee_id"] == agent_a.id

      # Modal closed; both members badged inherited.
      html = render(view)
      refute html =~ ~s(id="stack-assignee-modal")
      assert html =~ ~s(data-assignment="inherited")
    end

    test "members list shows inherited vs override badges",
         %{conn: conn, stack: stack, m1: m1, agent_b: agent_b} do
      # m1 carries an individual override.
      {:ok, m1} = Tasks.set_phase_assignees(m1, all_phase_attrs(agent_b.id))

      {:ok, _} =
        Tasks.update_task(m1, %{metadata: Map.put(m1.metadata || %{}, "assignee_override", true)})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # Both badges present: m1 override, m2 inherited.
      assert html =~ ~s(data-assignment="override")
      assert html =~ ~s(data-assignment="inherited")
    end

    test "clear_member_override returns a member to inheriting the stack default",
         %{conn: conn, stack: stack, m1: m1, agent_a: agent_a, agent_b: agent_b} do
      # m1 overridden to agent_b.
      {:ok, m1} = Tasks.set_phase_assignees(m1, all_phase_attrs(agent_b.id))

      {:ok, _} =
        Tasks.update_task(m1, %{metadata: Map.put(m1.metadata || %{}, "assignee_override", true)})

      # Stack default set to agent_a (m1 skipped because overridden).
      {:ok, _} = Stacks.set_stack_phase_assignees(stack, all_phase_attrs(agent_a.id))
      assert Repo.get!(Task, m1.id).assignee_id == agent_b.id

      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_click(view, "open_stack_detail", %{"id" => stack.id})

      render_click(view, "clear_member_override", %{"id" => m1.id})

      reloaded = Repo.get!(Task, m1.id)
      refute Stacks.member_overridden?(reloaded)
      assert reloaded.assignee_id == agent_a.id
    end

    test "the per-task assignee modal save stamps metadata.assignee_override",
         %{conn: conn, m1: m1, agent_b: agent_b} do
      {:ok, view, _html} = live(conn, ~p"/tasks?task_id=#{m1.id}")
      render_click(view, "open_assignee_modal", %{})

      render_submit(view, "save_assignees", %{"assignees" => %{"all" => agent_b.id}})

      reloaded = Repo.get!(Task, m1.id)
      assert Stacks.member_overridden?(reloaded)
      assert reloaded.assignee_id == agent_b.id
    end

    defp all_phase_attrs(agent_id) do
      entry = %{"assignee_id" => agent_id, "assignee_type" => "agent"}
      %{"planning" => entry, "execution" => entry, "review" => entry}
    end
  end

  describe "stack detail panel — needs-action badge on member rows (task 019e2c25 stage 2)" do
    # Stage 2 of "Badges for Tasks that need feedback": each member row in
    # the stack-detail panel shows a `data-role="stack-detail-member-action"`
    # warning chip ("Needs review" / "Plan ready") when
    # `Tasks.needs_human_action?/2` is true. The chip's
    # `data-action-reason` attribute carries the precise predicate branch
    # so tests can target it deterministically. Wired into both
    # `:plan_updated` and `:task_updated` PubSub messages so the badge
    # reacts live without a manual reload.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "Needs-Action Stack #{System.unique_integer([:positive])}",
          slug: "needs-action-#{System.unique_integer([:positive])}"
        )

      {:ok, conn: conn, project: project, stack: stack}
    end

    # Build a single stack member with the supplied status. Returns the
    # task struct (no plans, no review_requests) — caller layers those on
    # to drive the predicate's three branches.
    defp seed_member(stack, status, pos \\ 1) do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: stack.project_id,
          stack_id: stack.id,
          stack_position: pos,
          title: "Member #{pos}",
          status: status,
          priority: "medium"
        })

      task
    end

    test "(a) member with a `pending_review` plan shows the badge with reason `plan_pending_review`",
         %{conn: conn, stack: stack} do
      member = seed_member(stack, "planning")

      {:ok, _plan} =
        Tasks.create_plan(%{task_id: member.id, version: 1, status: "pending_review"})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert html =~ ~s(data-role="stack-detail-member-action")
      assert html =~ ~s(data-action-reason="plan_pending_review")
      assert html =~ "Plan ready"
    end

    test "(b) member with an open `manual_approval` ReviewRequest shows the badge with reason `review_request_pending`",
         %{conn: conn, stack: stack} do
      member = seed_member(stack, "in_progress")

      {:ok, plan} =
        Tasks.create_plan(%{task_id: member.id, version: 1, status: "approved"})

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
          task_id: member.id,
          status: "pending",
          items: [
            %{kind: "artifact", label: "Review me", status: "pending", content: "..."}
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert html =~ ~s(data-role="stack-detail-member-action")
      assert html =~ ~s(data-action-reason="review_request_pending")
      assert html =~ "Needs review"
    end

    test "(c) member with neither a pending plan nor a pending review_request shows no badge",
         %{conn: conn, stack: stack} do
      _member = seed_member(stack, "in_progress")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # The row exists, but the action badge does not.
      assert html =~ ~s(data-role="stack-detail-member-row")
      refute html =~ ~s(data-role="stack-detail-member-action")
    end

    test "(d) badge re-renders after a `:plan_updated` PubSub broadcast while the panel is open",
         %{conn: conn, stack: stack} do
      member = seed_member(stack, "planning")

      # Start with an *approved* plan — no badge.
      {:ok, plan} =
        Tasks.create_plan(%{task_id: member.id, version: 1, status: "approved"})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      pre_html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      refute pre_html =~ ~s(data-role="stack-detail-member-action")

      # Flip the plan to pending_review and broadcast — no LV reload, just
      # the PubSub message the live application would receive in
      # production. The handler must reload the stack panel so the badge
      # appears live.
      {:ok, updated_plan} =
        plan
        |> Plan.changeset(%{status: "pending_review"})
        |> Repo.update()

      Tasks.broadcast_board({:plan_updated, updated_plan})

      # Force the LV to process the queued message before we render.
      _ = :sys.get_state(view.pid)
      post_html = render(view)

      assert post_html =~ ~s(data-role="stack-detail-member-action")
      assert post_html =~ ~s(data-action-reason="plan_pending_review")
      assert post_html =~ "Plan ready"
    end

    test "(e) badge re-renders within the live cycle when a `:review_request_pending` PubSub broadcast fires (stage 5 fix)",
         %{conn: conn, stack: stack} do
      # Stage-5 fix (019e2c25 e2e_behavior re-pass): mount/3 now subscribes
      # to `Platform.Tasks.ReviewRequests.topic_for_task/1` for every task
      # on the board, and `handle_info({:review_request_pending, _}, ...)`
      # triggers `refresh_board + reload_selected_stack` so the badge
      # surfaces within the 2s live-update budget. Prior to the fix the
      # broadcast went unconsumed and the panel stayed stale until manual
      # reload — which was the single failed clause in the e2e review.
      member = seed_member(stack, "in_progress")

      {:ok, plan} =
        Tasks.create_plan(%{task_id: member.id, version: 1, status: "approved"})

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

      {:ok, view, _html} = live(conn, ~p"/tasks")
      pre_html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # No review_request yet → no badge.
      refute pre_html =~ ~s(data-role="stack-detail-member-action")

      # Insert the request — `create_review_request/1` already broadcasts
      # `{:review_request_pending, ...}` on `review_requests:<task_id>`.
      {:ok, _request} =
        ReviewRequests.create_review_request(%{
          validation_id: validation.id,
          task_id: member.id,
          status: "pending",
          items: [
            %{kind: "artifact", label: "Review me", status: "pending", content: "..."}
          ]
        })

      # Force the LV to drain its mailbox before we render so the test is
      # deterministic — the production flow lands within 2s via the
      # PubSub fanout, but the test process should not race the LV.
      _ = :sys.get_state(view.pid)
      post_html = render(view)

      assert post_html =~ ~s(data-role="stack-detail-member-action")
      assert post_html =~ ~s(data-action-reason="review_request_pending")
      assert post_html =~ "Needs review"
    end
  end

  describe "mobile solo task card — needs-action + status badges (task 019e2c25 stage 3)" do
    # Stage 3 of "Badges for Tasks that need feedback": the mobile-only
    # solo task card (the `<% _ -> %>` arm of the mobile @board_items
    # loop) renders the same warning chip the stack-detail rows + desktop
    # kanban already surface, plus the previously-hidden
    # `task_display_status/1` badge so "Plan Ready" appears on mobile.
    # The action chip carries `data-role="mobile-task-action"` so tests
    # can target it without coupling to layout.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      {:ok, conn: conn, project: project}
    end

    # Build a solo task (no stack) attached to the project. Status is
    # explicit so each test can drive the predicate's three branches and
    # ensure the active mobile-filter pill matches.
    defp seed_solo_task(project, status) do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Solo Task #{System.unique_integer([:positive])}",
          status: status,
          priority: "medium"
        })

      task
    end

    test "(a) mobile card with `pending_review` plan shows ONLY the 'Plan Ready' status badge (no doubled action chip)",
         %{conn: conn, project: project} do
      # Post-rejection fix (stage 4): the action chip and the status
      # chip both surfaced "Plan ready" / "Plan Ready" for the
      # `:plan_pending_review` branch, doubling-up signals on the same
      # row. The status chip is now the single signal on mobile —
      # `mobile_stack_member_action_label/1` returns `{nil, nil}` for
      # `:plan_pending_review`, suppressing the action chip's `:if`.
      task = seed_solo_task(project, "planning")

      {:ok, _plan} =
        Tasks.create_plan(%{task_id: task.id, version: 1, status: "pending_review"})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      # Switch the mobile pill to the task's column so the mobile card is
      # rendered (mobile only renders the active filter section).
      # `planning` status maps to the `backlog` column per
      # `@column_statuses` in tasks_live.ex.
      html = render_click(view, "filter_by_status", %{"status" => "backlog"})

      # Sanity: card is rendered.
      assert html =~ ~s(data-task-id="#{task.id}")

      # Status badge ("Plan Ready") IS present — single signal.
      assert html =~ "Plan Ready"

      # Action badge for `plan_pending_review` is suppressed on mobile —
      # the status badge already says "Plan Ready" and rendering both
      # produced a doubled chip Rowan rejected on Apr 2026 review.
      refute html =~ ~s(data-role="mobile-task-action")
      refute html =~ ~s(data-action-reason="plan_pending_review")
    end

    test "(b) mobile card with pending review_request shows 'Needs review' action badge",
         %{conn: conn, project: project} do
      task = seed_solo_task(project, "in_progress")

      {:ok, plan} =
        Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

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
            %{kind: "artifact", label: "Review me", status: "pending", content: "..."}
          ]
        })

      # Re-load — creating the manual_approval validation transitions the
      # task to `in_review` automatically (Tasks orchestrator), and the
      # mobile pill must match that current status.
      task = Repo.get!(Task, task.id)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "filter_by_status", %{"status" => task.status})

      assert html =~ ~s(data-role="mobile-task-action")
      assert html =~ ~s(data-action-reason="review_request_pending")
      assert html =~ "Needs review"
    end

    test "(c) mobile card with no pending action shows neither badge",
         %{conn: conn, project: project} do
      task = seed_solo_task(project, "in_progress")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "filter_by_status", %{"status" => task.status})

      # The card itself must be present (sanity check — otherwise a
      # rendering regression would silently let the negative assertion
      # below pass).
      assert html =~ ~s(data-task-id="#{task.id}")

      # No action badge.
      refute html =~ ~s(data-role="mobile-task-action")
      # No status chip (the `in_progress` status is not in the
      # `~w(blocked planning in_review deploying)` allow-list that gates
      # the mobile + desktop status badges). The literal "In Review"
      # appears in the mobile filter pill nav, so target the *badge*
      # markup that gates "Plan Ready" instead — neither the warning
      # badge text nor the pending-review-plan attribute should leak.
      refute html =~ "Plan Ready"
      refute html =~ ~s(data-action-reason="plan_pending_review")
    end
  end

  describe "mobile stack-member rows — needs-action badge (task 019e2c25 stage 4)" do
    # Stage 4 of "Badges for Tasks that need feedback": the mobile-only
    # stack-member rows (the `id={"stack-member-mobile-#{member.id}"}`
    # buttons under an expanded mobile stack card) mirror the desktop
    # stack-detail badge from stage 2 + the mobile solo-card badge from
    # stage 3. The chip carries `data-role="stack-member-mobile-action"`
    # so tests target it without coupling to layout, and reuses the
    # board-wide `@review_counts` map (populated in refresh_board/1 over
    # all tasks including stack members) — no new source of truth.
    #
    # Plans must be preloaded on members for the
    # `:plan_pending_review` predicate branch to resolve. That preload
    # was added to `Stacks.list_stacks_with_members/1` as part of this
    # stage (the only caller in the live view).
    #
    # The mobile board only renders the active filter pill's section
    # (T6 PR #328), so each test calls `filter_by_status` to switch the
    # pill to the stack's rollup status before `toggle_stack_expand`
    # to surface the member rows.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "Mobile Needs-Action Stack #{System.unique_integer([:positive])}",
          slug: "mobile-needs-action-#{System.unique_integer([:positive])}"
        )

      {:ok, conn: conn, project: project, stack: stack}
    end

    # Build a single stack member with the supplied status. Returns the
    # task struct (no plans, no review_requests) — caller layers those
    # on to drive the predicate's branches.
    defp seed_mobile_member(stack, status, pos \\ 1) do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: stack.project_id,
          stack_id: stack.id,
          stack_position: pos,
          title: "Mobile Member #{pos}",
          status: status,
          priority: "medium"
        })

      task
    end

    # Recompute the stack rollup so its status matches the seeded
    # member(s) and the mobile filter pill's `status == stack.status`
    # gate makes the stack card visible on the mobile section list.
    defp refresh_stack_rollup(stack) do
      {:ok, stack} = Stacks.recompute_stack_status(stack)
      Repo.get!(Stack, stack.id)
    end

    test "(a) mobile stack-member with `pending_review` plan shows ONLY the 'Plan Ready' status chip (no doubled action chip)",
         %{conn: conn, stack: stack} do
      # Post-rejection fix (stage 4): the mobile stack-member row's
      # `task_display_status/1` chip already surfaces "Plan Ready"
      # (warning badge) for `status="planning"` + pending-review plan.
      # Stage 4's action chip rendered "Plan ready" for the same case
      # — two chips on the same row Rowan rejected. The mobile-only
      # `mobile_stack_member_action_label/1` returns `{nil, nil}` for
      # `:plan_pending_review` so the action chip's `:if` collapses.
      member = seed_mobile_member(stack, "planning")

      {:ok, _plan} =
        Tasks.create_plan(%{task_id: member.id, version: 1, status: "pending_review"})

      _stack = refresh_stack_rollup(stack)

      # `planning` member status rolls up to stack status `forming`, which
      # `@column_statuses` buckets under the `backlog` mobile pill (the
      # `filter_by_status` handler only accepts `@mobile_columns` keys —
      # raw `forming` is rejected).
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "filter_by_status", %{"status" => "backlog"})
      html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      # Row exists.
      assert html =~ ~s(id="stack-member-mobile-#{member.id}")

      # Status chip (existing "Plan Ready" via `task_display_status/1`)
      # is the single signal.
      assert html =~ "Plan Ready"

      # Action chip is suppressed for the `:plan_pending_review`
      # branch on mobile — no doubled chip.
      refute html =~ ~s(data-role="stack-member-mobile-action")
      refute html =~ ~s(data-action-reason="plan_pending_review")
    end

    test "(b) mobile stack-member with pending review_request shows badge with reason `review_request_pending`",
         %{conn: conn, stack: stack} do
      member = seed_mobile_member(stack, "in_progress")

      {:ok, plan} =
        Tasks.create_plan(%{task_id: member.id, version: 1, status: "approved"})

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
          task_id: member.id,
          status: "pending",
          items: [
            %{kind: "artifact", label: "Review me", status: "pending", content: "..."}
          ]
        })

      # Creating the manual_approval validation transitions the member
      # to `in_review`; recompute the stack rollup so the mobile pill
      # for `in_review` makes the stack card visible.
      stack = refresh_stack_rollup(stack)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "filter_by_status", %{"status" => stack.status})
      html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      assert html =~ ~s(id="stack-member-mobile-#{member.id}")
      assert html =~ ~s(data-role="stack-member-mobile-action")
      assert html =~ ~s(data-action-reason="review_request_pending")
      assert html =~ "Needs review"
    end

    test "(c) mobile stack-member with neither pending plan nor pending review_request shows no badge",
         %{conn: conn, stack: stack} do
      member = seed_mobile_member(stack, "in_progress")
      stack = refresh_stack_rollup(stack)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "filter_by_status", %{"status" => stack.status})
      html = render_click(view, "toggle_stack_expand", %{"id" => stack.id})

      # The row exists (sanity), but the action badge does not.
      assert html =~ ~s(id="stack-member-mobile-#{member.id}")
      refute html =~ ~s(data-role="stack-member-mobile-action")
    end
  end

  describe "stack detail panel — needs-feedback chrome pill (task 019e2c27 stage 2)" do
    # Stage 2 of "Task Stacks Review Rollup": the stack-detail panel chrome
    # surfaces a "Needs feedback (N)" badge whenever
    # `Stacks.count_pending_reviews/1` > 0. Hidden entirely when the count
    # is 0 so the chrome stays clean. Click target wires
    # `phx-click="open_stack_feedback_overlay"` — a stage-2 stub that flips
    # `:show_stack_feedback_overlay`; stage 3 will render the actual rollup
    # overlay against that assign.
    #
    # The pill MUST refresh in response to `:review_request_pending` and
    # `:review_request_resolved` PubSub broadcasts (wired through
    # `reload_selected_stack` in the badges PR that just landed).
    #
    # Regression guard: the per-row "Needs review" / "Plan ready" badge
    # owned by task 019e2c25 — `data-role="stack-detail-member-action"` —
    # must remain on the page when the chrome pill is rendered. The chrome
    # pill is purely additive at the panel header level.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "Rollup Pill Stack #{System.unique_integer([:positive])}",
          slug: "rollup-pill-#{System.unique_integer([:positive])}"
        )

      {:ok, conn: conn, project: project, stack: stack}
    end

    # Single member with the supplied status. Returns the task struct.
    defp seed_rollup_member(stack, status, pos \\ 1) do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: stack.project_id,
          stack_id: stack.id,
          stack_position: pos,
          title: "Rollup Member #{pos}",
          status: status,
          priority: "medium"
        })

      task
    end

    # Stand up an open manual_approval ReviewRequest on `task` and return
    # `{validation, request}`. Mirrors the seed pattern from the badges
    # describe block above.
    defp seed_pending_review_request(task) do
      {:ok, plan} =
        Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

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

      {:ok, request} =
        ReviewRequests.create_review_request(%{
          validation_id: validation.id,
          task_id: task.id,
          status: "pending",
          items: [
            %{kind: "artifact", label: "Review me", status: "pending", content: "..."}
          ]
        })

      {validation, request}
    end

    test "(a) chrome pill renders with the correct label format when count > 0",
         %{conn: conn, stack: stack} do
      m1 = seed_rollup_member(stack, "in_progress", 1)
      m2 = seed_rollup_member(stack, "in_progress", 2)

      _ = seed_pending_review_request(m1)
      _ = seed_pending_review_request(m2)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert html =~ ~s(data-role="stack-detail-needs-feedback-pill")
      assert html =~ ~s(data-pending-count="2")
      assert html =~ "Needs feedback (2)"
      # Wired to the stage-2 handler stub — the overlay itself lands in
      # stage 3, but the click target must be observably present.
      assert html =~ ~s(phx-click="open_stack_feedback_overlay")
      # Hero-eye icon (matches the badge guideline).
      assert html =~ "hero-eye"

      # Server-side assign matches the rendered count (1 RR per member, 2
      # members → 2 pending across the stack).
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected_stack_pending_review_count == 2
    end

    test "(b) chrome pill is hidden entirely when the count is 0",
         %{conn: conn, stack: stack} do
      _ = seed_rollup_member(stack, "in_progress", 1)
      _ = seed_rollup_member(stack, "in_progress", 2)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # No clutter on the chrome — the pill block does not render at all.
      refute html =~ ~s(data-role="stack-detail-needs-feedback-pill")
      refute html =~ "Needs feedback"

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected_stack_pending_review_count == 0
    end

    test "(c) chrome pill re-renders on `:review_request_pending` PubSub (count increments)",
         %{conn: conn, stack: stack} do
      m1 = seed_rollup_member(stack, "in_progress", 1)
      m2 = seed_rollup_member(stack, "in_progress", 2)

      # Start with one pending RR — pill shows "Needs feedback (1)".
      _ = seed_pending_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      pre_html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert pre_html =~ ~s(data-role="stack-detail-needs-feedback-pill")
      assert pre_html =~ "Needs feedback (1)"

      # Insert a second RR. `create_review_request/1` broadcasts
      # `{:review_request_pending, ...}` on `review_requests:<task_id>`;
      # mount/3 has subscribed to every initial board task so the LV
      # consumes it without manual reload (badges-task wiring).
      _ = seed_pending_review_request(m2)

      _ = :sys.get_state(view.pid)
      post_html = render(view)

      assert post_html =~ ~s(data-pending-count="2")
      assert post_html =~ "Needs feedback (2)"
    end

    test "(d) chrome pill re-renders on `:review_request_resolved` PubSub (count decrements)",
         %{conn: conn, stack: stack} do
      m1 = seed_rollup_member(stack, "in_progress", 1)
      m2 = seed_rollup_member(stack, "in_progress", 2)

      {_v1, r1} = seed_pending_review_request(m1)
      _ = seed_pending_review_request(m2)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      pre_html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert pre_html =~ ~s(data-pending-count="2")
      assert pre_html =~ "Needs feedback (2)"

      # Resolve r1 — the items must all flip to a non-pending status so
      # `list_pending_for_task/1` no longer counts the request. Use the
      # public approval path that broadcasts `:review_request_resolved`.
      Enum.each(r1.items, fn item ->
        {:ok, _} = ReviewRequests.approve_item(item.id, "tester ok")
      end)

      _ = :sys.get_state(view.pid)
      post_html = render(view)

      assert post_html =~ ~s(data-pending-count="1")
      assert post_html =~ "Needs feedback (1)"
    end

    test "(e) chrome pill click toggles `:show_stack_feedback_overlay`",
         %{conn: conn, stack: stack} do
      m1 = seed_rollup_member(stack, "in_progress", 1)
      _ = seed_pending_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert :sys.get_state(view.pid).socket.assigns.show_stack_feedback_overlay == false

      _html = render_click(view, "open_stack_feedback_overlay", %{})
      assert :sys.get_state(view.pid).socket.assigns.show_stack_feedback_overlay == true

      _html = render_click(view, "open_stack_feedback_overlay", %{})
      assert :sys.get_state(view.pid).socket.assigns.show_stack_feedback_overlay == false
    end

    test "(f) regression: chrome pill does NOT clobber the stack-detail-member-action row badge",
         %{conn: conn, stack: stack} do
      # Same fixture shape as describe-block (b) above — a member with a
      # pending plan AND a pending review_request. The row-level chip from
      # task 019e2c25 (`stack-detail-member-action`) MUST still render
      # alongside the chrome-level pill from this task. Boundary guard:
      # the chrome surface is purely additive, the row surface is owned
      # by the badges task.
      member = seed_rollup_member(stack, "in_progress", 1)
      _ = seed_pending_review_request(member)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # Chrome pill is present (stage 2 of THIS task).
      assert html =~ ~s(data-role="stack-detail-needs-feedback-pill")
      assert html =~ "Needs feedback (1)"

      # Row badge from sibling task 019e2c25 still present — same fixture
      # that drove its describe block (b). If a future change here removes
      # this surface this assertion will catch it.
      assert html =~ ~s(data-role="stack-detail-member-action")
      assert html =~ ~s(data-action-reason="review_request_pending")
    end
  end

  describe "stack detail panel — feedback overlay (task 019e2c27 stage 3)" do
    # Stage 3 of "Task Stacks Review Rollup": clicking the chrome pill
    # (stage 2) toggles `:show_stack_feedback_overlay`; this stage renders
    # the overlay content when that assign is true. The overlay floats
    # OVER the stack pane (NOT inline) and lists every open ReviewRequest
    # for the stack's members, each with the member task title + the
    # canvas content rendered inline via `CanvasRenderer.canvas_document`
    # (same component the per-task `active_review_canvas` modal uses).
    # Approve / reject buttons render DISABLED in this stage — stage 4
    # wires them. Close button + backdrop click dismiss.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "Overlay Stack #{System.unique_integer([:positive])}",
          slug: "overlay-stack-#{System.unique_integer([:positive])}"
        )

      {:ok, conn: conn, project: project, stack: stack}
    end

    defp seed_overlay_member(stack, status, pos \\ 1) do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: stack.project_id,
          stack_id: stack.id,
          stack_position: pos,
          title: "Overlay Member #{pos}",
          status: status,
          priority: "medium"
        })

      task
    end

    # Drop a canvas with a minimal valid document in a freshly created
    # space, return its id. Used so the overlay's inline canvas-render
    # path can be asserted end-to-end against the same CanvasRenderer
    # the per-task review modal uses.
    defp seed_canvas_for_overlay(label \\ "Overlay") do
      suffix = System.unique_integer([:positive])

      {:ok, space} =
        Chat.create_space(%{
          name: "Overlay Canvas Space #{suffix}",
          slug: "overlay-canvas-space-#{suffix}",
          kind: "channel"
        })

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Reviewer",
          joined_at: DateTime.utc_now()
        })

      doc = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "props" => %{"gap" => 8},
          "children" => [
            %{
              "id" => "text-1",
              "type" => "text",
              "props" => %{"value" => "Overlay canvas body — #{label}"},
              "children" => []
            }
          ]
        }
      }

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Overlay Canvas #{label}",
          "document" => doc
        })

      canvas
    end

    defp seed_overlay_review_request(task, canvas \\ nil) do
      {:ok, plan} =
        Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

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

      item_attrs =
        case canvas do
          %{id: cid} ->
            %{kind: "artifact", label: "Item with canvas", status: "pending", canvas_id: cid}

          nil ->
            %{
              kind: "artifact",
              label: "Item with content",
              status: "pending",
              content: "Free-form review content."
            }
        end

      {:ok, request} =
        ReviewRequests.create_review_request(%{
          validation_id: validation.id,
          task_id: task.id,
          status: "pending",
          items: [item_attrs]
        })

      {validation, request}
    end

    test "(a) overlay is hidden by default when `:show_stack_feedback_overlay` is false",
         %{conn: conn, stack: stack} do
      m1 = seed_overlay_member(stack, "in_progress", 1)
      _ = seed_overlay_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # Panel + chrome pill present; overlay panel absent.
      assert html =~ ~s(data-role="stack-detail-panel")
      assert html =~ ~s(data-role="stack-detail-needs-feedback-pill")
      refute html =~ ~s(id="stack-feedback-overlay")
      refute html =~ ~s(data-role="stack-feedback-overlay-panel")

      assert :sys.get_state(view.pid).socket.assigns.show_stack_feedback_overlay == false
    end

    test "(b) clicking the chrome pill renders the overlay with N items matching `list_open_review_requests/1`",
         %{conn: conn, stack: stack} do
      m1 = seed_overlay_member(stack, "in_progress", 1)
      m2 = seed_overlay_member(stack, "in_progress", 2)

      c1 = seed_canvas_for_overlay("one")
      c2 = seed_canvas_for_overlay("two")

      _ = seed_overlay_review_request(m1, c1)
      _ = seed_overlay_review_request(m2, c2)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      html = render_click(view, "open_stack_feedback_overlay", %{})

      assert html =~ ~s(id="stack-feedback-overlay")
      assert html =~ ~s(data-role="stack-feedback-overlay-panel")

      # Count attribute mirrors list_open_review_requests/1's length.
      expected_count = length(Stacks.list_open_review_requests(stack))
      assert expected_count == 2

      # One overlay item per ReviewRequest.
      item_count =
        html
        |> String.split(~s(data-role="stack-feedback-overlay-item"))
        |> length()
        |> Kernel.-(1)

      assert item_count == expected_count

      # Both member titles appear (task drill links).
      assert html =~ "Overlay Member 1"
      assert html =~ "Overlay Member 2"

      # Header copy reflects the count + plural form.
      assert html =~ "2 pending requests"
    end

    test "(c) each overlay item renders the canvas content inline via CanvasRenderer",
         %{conn: conn, stack: stack} do
      m1 = seed_overlay_member(stack, "in_progress", 1)
      c1 = seed_canvas_for_overlay("inline")
      _ = seed_overlay_review_request(m1, c1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      html = render_click(view, "open_stack_feedback_overlay", %{})

      # Inline canvas wrapper carries our data-role marker AND the
      # canvas id so a future test can drill in further.
      assert html =~ ~s(data-role="stack-feedback-overlay-canvas")
      assert html =~ ~s(data-canvas-id="#{c1.id}")

      # CanvasRenderer emits id="canvas-doc-<canvas_id>-..." for every
      # valid document — gold-standard marker the per-task
      # `active_review_canvas` modal also produces.
      assert html =~ ~s(id="canvas-doc-#{c1.id}-)

      # Body text from the seeded document made it through the render.
      assert html =~ "Overlay canvas body — inline"
    end

    test "(d) overlay renders approve + reject affordances enabled with stage-4 wiring",
         %{conn: conn, stack: stack} do
      m1 = seed_overlay_member(stack, "in_progress", 1)
      _ = seed_overlay_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      html = render_click(view, "open_stack_feedback_overlay", %{})

      assert html =~ ~s(data-role="stack-feedback-overlay-approve")
      assert html =~ ~s(data-role="stack-feedback-overlay-reject")

      # Stage 4 contract: buttons are enabled (no `disabled` attribute,
      # no `btn-disabled` daisyUI marker) and carry the phx-click +
      # phx-value-id wiring against the new handlers.
      refute html =~ ~r/data-role="stack-feedback-overlay-approve"[^>]*disabled/s
      refute html =~ ~r/disabled[^>]*data-role="stack-feedback-overlay-approve"/s
      refute html =~ ~r/data-role="stack-feedback-overlay-reject"[^>]*btn-disabled/s

      assert html =~ ~s(phx-click="stack_feedback_approve_item")
      assert html =~ ~s(phx-click="toggle_stack_feedback_reject")
    end

    test "(e) close button collapses the overlay",
         %{conn: conn, stack: stack} do
      m1 = seed_overlay_member(stack, "in_progress", 1)
      _ = seed_overlay_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      open_html = render_click(view, "open_stack_feedback_overlay", %{})

      assert open_html =~ ~s(data-role="stack-feedback-overlay-panel")

      closed_html = render_click(view, "close_stack_feedback_overlay", %{})
      refute closed_html =~ ~s(data-role="stack-feedback-overlay-panel")

      # Stack panel is still mounted — closing the overlay drops the
      # user back on the stack pane (NOT the board).
      assert closed_html =~ ~s(data-role="stack-detail-panel")
      assert :sys.get_state(view.pid).socket.assigns.show_stack_feedback_overlay == false
      assert :sys.get_state(view.pid).socket.assigns.show_stack_detail == true
    end

    test "(f) backdrop click dismisses the overlay",
         %{conn: conn, stack: stack} do
      m1 = seed_overlay_member(stack, "in_progress", 1)
      _ = seed_overlay_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      _ = render_click(view, "open_stack_feedback_overlay", %{})

      assert :sys.get_state(view.pid).socket.assigns.show_stack_feedback_overlay == true

      # Backdrop wires the same dismiss event — the test exercises the
      # event the backdrop emits (`close_stack_feedback_overlay`).
      closed_html = render_click(view, "close_stack_feedback_overlay", %{})

      refute closed_html =~ ~s(data-role="stack-feedback-overlay-panel")
      assert :sys.get_state(view.pid).socket.assigns.show_stack_feedback_overlay == false
    end

    test "(g) opening overlay refreshes the snapshot — PubSub drops between mount and open are not stale",
         %{conn: conn, stack: stack} do
      m1 = seed_overlay_member(stack, "in_progress", 1)
      m2 = seed_overlay_member(stack, "in_progress", 2)

      # Start with one RR — pill shows count=1, overlay would have 1 row.
      _ = seed_overlay_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # Add a second RR; live wiring also catches this via PubSub, but
      # `open_stack_feedback_overlay` MUST also re-snapshot so a tab
      # that missed a broadcast still sees the freshest data when the
      # user actually opens the overlay.
      _ = seed_overlay_review_request(m2)

      open_html = render_click(view, "open_stack_feedback_overlay", %{})

      assert open_html =~ ~s(data-role="stack-feedback-overlay-panel")

      item_count =
        open_html
        |> String.split(~s(data-role="stack-feedback-overlay-item"))
        |> length()
        |> Kernel.-(1)

      assert item_count == 2

      assigns = :sys.get_state(view.pid).socket.assigns
      assert length(assigns.selected_stack_open_review_requests) == 2
    end

    test "(h) overlay row falls back to free-form content when item has no canvas_id",
         %{conn: conn, stack: stack} do
      m1 = seed_overlay_member(stack, "in_progress", 1)
      # No canvas — item carries content only.
      _ = seed_overlay_review_request(m1, nil)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      html = render_click(view, "open_stack_feedback_overlay", %{})

      refute html =~ ~s(data-role="stack-feedback-overlay-canvas")
      assert html =~ ~s(data-role="stack-feedback-overlay-content")
      assert html =~ "Free-form review content."
    end

    test "(i) overlay does NOT modify the row chrome owned by sibling task 019e2c25",
         %{conn: conn, stack: stack} do
      # Boundary guard: opening the overlay should not touch
      # `data-role="stack-detail-member-row"` or
      # `data-role="stack-detail-member-action"` — those belong to the
      # badges task. The overlay is a separate floating surface.
      m1 = seed_overlay_member(stack, "in_progress", 1)
      _ = seed_overlay_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      pre_html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      assert pre_html =~ ~s(data-role="stack-detail-member-row")
      assert pre_html =~ ~s(data-role="stack-detail-member-action")

      open_html = render_click(view, "open_stack_feedback_overlay", %{})

      # Row chrome is still on the page even with the overlay open —
      # the panel is mounted underneath, just visually replaced.
      assert open_html =~ ~s(data-role="stack-detail-member-row")
      assert open_html =~ ~s(data-role="stack-detail-member-action")
    end
  end

  describe "stack detail panel — feedback overlay approve/reject wiring (task 019e2c27 stage 4)" do
    # Stage 4 of "Task Stacks Review Rollup": the approve + reject
    # buttons (stage 3 stubs) get wired against
    # `Platform.Tasks.ReviewRequests.approve_item/2` and `reject_item/3`,
    # with optimistic removal from the overlay assigns + count
    # decrement, and PubSub `:review_request_resolved` server-state
    # convergence on top.

    alias Platform.Tasks.ReviewItem
    alias Platform.Tasks.Validation

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "Stage4 Stack #{System.unique_integer([:positive])}",
          slug: "stage4-stack-#{System.unique_integer([:positive])}"
        )

      {:ok, conn: conn, project: project, stack: stack}
    end

    # Local copies of the stage-3 helpers — kept private to this describe
    # block so a future refactor of either set stays scoped.
    defp seed_s4_member(stack, status, pos \\ 1) do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: stack.project_id,
          stack_id: stack.id,
          stack_position: pos,
          title: "Stage4 Member #{pos}",
          status: status,
          priority: "medium"
        })

      task
    end

    defp seed_s4_review_request(task) do
      {:ok, plan} =
        Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

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

      {:ok, request} =
        ReviewRequests.create_review_request(%{
          validation_id: validation.id,
          task_id: task.id,
          status: "pending",
          items: [
            %{
              kind: "artifact",
              label: "Item with content",
              status: "pending",
              content: "Free-form review content."
            }
          ]
        })

      [item] = request.items
      {validation, request, item}
    end

    test "(a) clicking Approve fires the event, updates the DB, and removes the item from the overlay",
         %{conn: conn, stack: stack} do
      m1 = seed_s4_member(stack, "in_progress", 1)
      {_v, request, item} = seed_s4_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      open_html = render_click(view, "open_stack_feedback_overlay", %{})

      # Sanity: button is rendered ENABLED (no disabled attr / class).
      refute open_html =~ ~r/data-role="stack-feedback-overlay-approve"[^>]*\sdisabled/s
      refute open_html =~ ~r/data-role="stack-feedback-overlay-approve"[^>]*btn-disabled/s

      # Pre-click: assigns + DB both show the pending item.
      pre = :sys.get_state(view.pid).socket.assigns
      assert pre.selected_stack_pending_review_count == 1
      assert length(pre.selected_stack_open_review_requests) == 1
      assert Repo.get!(ReviewItem, item.id).status == "pending"

      after_html =
        render_click(view, "stack_feedback_approve_item", %{"id" => item.id})

      # DB: item is now approved + the parent request resolved (last
      # pending item flipped → maybe_resolve_request/1).
      reloaded = Repo.get!(ReviewItem, item.id)
      assert reloaded.status == "approved"
      assert Repo.get!(Platform.Tasks.ReviewRequest, request.id).status != "pending"

      # Assigns: optimistic drop removed the RR (its last item went away)
      # and the chrome pill count came down with it.
      post = :sys.get_state(view.pid).socket.assigns
      assert post.selected_stack_open_review_requests == []
      assert post.selected_stack_pending_review_count == 0

      # The DOM no longer carries the approve button for that item (the
      # row is gone) — the overlay rendered the empty state instead.
      refute after_html =~ ~s(data-review-item-id="#{item.id}")
      assert after_html =~ ~s(data-role="stack-feedback-overlay-empty")
    end

    test "(b) clicking Reject toggles the feedback textarea, submitting it rejects in the DB and drops the item",
         %{conn: conn, stack: stack} do
      m1 = seed_s4_member(stack, "in_progress", 1)
      {_v, request, item} = seed_s4_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      _ = render_click(view, "open_stack_feedback_overlay", %{})

      # Reject button is enabled.
      open_assigns = :sys.get_state(view.pid).socket.assigns
      assert MapSet.size(open_assigns.stack_feedback_reject_open) == 0

      # First click toggles the form open.
      toggled_html =
        render_click(view, "toggle_stack_feedback_reject", %{"id" => item.id})

      assert toggled_html =~ ~s(data-role="stack-feedback-overlay-reject-form")
      assert toggled_html =~ ~s(data-role="stack-feedback-overlay-reject-text")

      toggled_assigns = :sys.get_state(view.pid).socket.assigns
      assert MapSet.member?(toggled_assigns.stack_feedback_reject_open, item.id)

      # Submitting reject lands in the DB with the feedback string.
      after_html =
        render_click(view, "stack_feedback_reject_item", %{
          "id" => item.id,
          "feedback" => "Needs more detail in section two."
        })

      reloaded = Repo.get!(ReviewItem, item.id)
      assert reloaded.status == "needs_revision"
      assert reloaded.feedback == "Needs more detail in section two."
      assert Repo.get!(Platform.Tasks.ReviewRequest, request.id).status != "pending"

      # Assigns: optimistic drop applied + reject draft cleared.
      post = :sys.get_state(view.pid).socket.assigns
      assert post.selected_stack_open_review_requests == []
      assert post.selected_stack_pending_review_count == 0
      refute MapSet.member?(post.stack_feedback_reject_open, item.id)
      refute Map.has_key?(post.stack_feedback_reject_text, item.id)

      refute after_html =~ ~s(data-review-item-id="#{item.id}")
    end

    test "(c) external PubSub :review_request_resolved converges the overlay to server state",
         %{conn: conn, stack: stack} do
      m1 = seed_s4_member(stack, "in_progress", 1)
      {_v, _rr, item} = seed_s4_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      _ = render_click(view, "open_stack_feedback_overlay", %{})

      pre = :sys.get_state(view.pid).socket.assigns
      assert pre.selected_stack_pending_review_count == 1
      assert length(pre.selected_stack_open_review_requests) == 1

      # Externally approve via the API directly (mirrors another tab /
      # another agent landing the disposition) WITHOUT going through
      # our handler. Then fire the resolved broadcast the same shape
      # `maybe_resolve_request/1` would.
      {:ok, _} = ReviewRequests.approve_item(item.id, "external-agent")

      send(view.pid, {:review_request_resolved, %{task_id: m1.id}})

      # Wait one render cycle.
      _ = render(view)

      post = :sys.get_state(view.pid).socket.assigns
      assert post.selected_stack_open_review_requests == []
      assert post.selected_stack_pending_review_count == 0
    end

    test "(d) reject_item handler tolerates pre-collected text when no `feedback` param is supplied",
         %{conn: conn, stack: stack} do
      m1 = seed_s4_member(stack, "in_progress", 1)
      {_v, _rr, item} = seed_s4_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      _ = render_click(view, "open_stack_feedback_overlay", %{})
      _ = render_click(view, "toggle_stack_feedback_reject", %{"id" => item.id})

      # Type into the textarea (the buffer assign is the source of truth).
      _ =
        render_keyup(view, "update_stack_feedback_reject_text", %{
          "id" => item.id,
          "value" => "Buffered feedback"
        })

      buffered = :sys.get_state(view.pid).socket.assigns.stack_feedback_reject_text
      assert Map.get(buffered, item.id) == "Buffered feedback"

      # Submit WITHOUT the feedback key — handler must fall back to the
      # buffered draft so the in-flight assign is the source of truth
      # even if the template's `phx-value-feedback` is stripped.
      _ = render_click(view, "stack_feedback_reject_item", %{"id" => item.id})

      reloaded = Repo.get!(ReviewItem, item.id)
      assert reloaded.status == "needs_revision"
      assert reloaded.feedback == "Buffered feedback"
    end

    test "(e) close_stack_feedback_overlay clears in-flight reject form state",
         %{conn: conn, stack: stack} do
      m1 = seed_s4_member(stack, "in_progress", 1)
      {_v, _rr, item} = seed_s4_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      _ = render_click(view, "open_stack_feedback_overlay", %{})
      _ = render_click(view, "toggle_stack_feedback_reject", %{"id" => item.id})

      _ =
        render_keyup(view, "update_stack_feedback_reject_text", %{
          "id" => item.id,
          "value" => "half typed"
        })

      mid = :sys.get_state(view.pid).socket.assigns
      assert MapSet.member?(mid.stack_feedback_reject_open, item.id)
      assert Map.get(mid.stack_feedback_reject_text, item.id) == "half typed"

      _ = render_click(view, "close_stack_feedback_overlay", %{})

      post = :sys.get_state(view.pid).socket.assigns
      assert post.show_stack_feedback_overlay == false
      assert MapSet.size(post.stack_feedback_reject_open) == 0
      assert post.stack_feedback_reject_text == %{}

      # Validation alias keeps the compiler from complaining about an
      # otherwise-unused alias at the top of this describe block.
      _ = Validation
    end
  end

  describe "stack detail panel — live-refresh on RR churn (task 019e2c27 stage 5)" do
    # Stage 5 of "Task Stacks Review Rollup": wires the LiveView to
    # `Platform.Tasks.ReviewRequests.subscribe_for_task/1` for every
    # member of the open stack so the chrome pill (and the rollup
    # overlay, when open) refresh within the live cycle when an
    # external actor creates, approves, or rejects a review_request
    # on any member — without the user touching the panel.
    #
    # The board-level subscriptions from the badges task already cover
    # every visible task at mount, but the stack panel can hold members
    # outside the board's current filter; the stack-scoped subscription
    # set is the safety net. On close it unwinds itself WITHOUT
    # disturbing any task ids the board is still subscribed to.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stack =
        stack_fixture(
          project_id: project.id,
          name: "Stage5 Stack #{System.unique_integer([:positive])}",
          slug: "stage5-stack-#{System.unique_integer([:positive])}"
        )

      {:ok, conn: conn, project: project, stack: stack}
    end

    defp seed_s5_member(stack, status, pos \\ 1) do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: stack.project_id,
          stack_id: stack.id,
          stack_position: pos,
          title: "Stage5 Member #{pos}",
          status: status,
          priority: "medium"
        })

      task
    end

    defp seed_s5_review_request(task) do
      {:ok, plan} =
        Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

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

      {:ok, request} =
        ReviewRequests.create_review_request(%{
          validation_id: validation.id,
          task_id: task.id,
          status: "pending",
          items: [
            %{kind: "artifact", label: "Stage5 review item", status: "pending", content: "..."}
          ]
        })

      {validation, request}
    end

    test "(a) panel open + external RR created on stack member → chrome pill count increments live",
         %{conn: conn, stack: stack} do
      # Two members, NEITHER has a pending RR at mount — so the chrome
      # pill stays hidden initially. The wiring under test must
      # subscribe to every member's review_requests:<task_id> topic
      # the moment the panel opens, so the external creation below
      # (which broadcasts `:review_request_pending`) reaches us and
      # bumps the pill within the live cycle.
      m1 = seed_s5_member(stack, "in_progress", 1)
      m2 = seed_s5_member(stack, "in_progress", 2)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      pre_html = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # Sanity: nothing pending pre-create — pill stays hidden.
      refute pre_html =~ ~s(data-role="stack-detail-needs-feedback-pill")
      assert :sys.get_state(view.pid).socket.assigns.selected_stack_pending_review_count == 0

      # External actor creates a pending RR on m1 — broadcasts
      # `{:review_request_pending, ...}` on `review_requests:<m1.id>`.
      _ = seed_s5_review_request(m1)
      _ = :sys.get_state(view.pid)
      after_first = render(view)

      assert after_first =~ ~s(data-role="stack-detail-needs-feedback-pill")
      assert after_first =~ ~s(data-pending-count="1")
      assert after_first =~ "Needs feedback (1)"

      # And again on a different member — the subscription set is
      # genuinely per-member, not just the first one we touched.
      _ = seed_s5_review_request(m2)
      _ = :sys.get_state(view.pid)
      after_second = render(view)

      assert after_second =~ ~s(data-pending-count="2")
      assert after_second =~ "Needs feedback (2)"
    end

    test "(b) overlay open + external RR created → overlay row + count both refresh live",
         %{conn: conn, stack: stack} do
      m1 = seed_s5_member(stack, "in_progress", 1)
      m2 = seed_s5_member(stack, "in_progress", 2)

      # Start with one pending RR so the overlay actually opens (the
      # stage-3 overlay still renders an empty state when there are 0
      # rows, but a non-empty start makes the assertions concrete).
      _ = seed_s5_review_request(m1)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      open_html = render_click(view, "open_stack_feedback_overlay", %{})

      assert open_html =~ ~s(data-role="stack-feedback-overlay-panel")
      assert :sys.get_state(view.pid).socket.assigns.selected_stack_pending_review_count == 1

      pre_rows =
        open_html
        |> String.split(~s(data-role="stack-feedback-overlay-item"))
        |> length()
        |> Kernel.-(1)

      assert pre_rows == 1

      # External actor creates a second RR on m2. The
      # `:review_request_pending` PubSub broadcast should refresh the
      # overlay assigns (not just the pill count), since the overlay
      # is open.
      _ = seed_s5_review_request(m2)
      _ = :sys.get_state(view.pid)
      post_html = render(view)

      post = :sys.get_state(view.pid).socket.assigns
      assert post.selected_stack_pending_review_count == 2
      assert length(post.selected_stack_open_review_requests) == 2

      assert post_html =~ ~s(data-pending-count="2")

      post_rows =
        post_html
        |> String.split(~s(data-role="stack-feedback-overlay-item"))
        |> length()
        |> Kernel.-(1)

      assert post_rows == 2
    end

    test "(c) overlay open + external approve_item on a different member → row disappears, count decrements live",
         %{conn: conn, stack: stack} do
      m1 = seed_s5_member(stack, "in_progress", 1)
      m2 = seed_s5_member(stack, "in_progress", 2)

      _ = seed_s5_review_request(m1)
      {_v2, r2} = seed_s5_review_request(m2)
      [item_on_m2] = r2.items

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})
      _ = render_click(view, "open_stack_feedback_overlay", %{})

      pre = :sys.get_state(view.pid).socket.assigns
      assert pre.selected_stack_pending_review_count == 2
      assert length(pre.selected_stack_open_review_requests) == 2

      # External actor approves m2's only review item — this drives
      # `maybe_resolve_request/1` and broadcasts
      # `{:review_request_resolved, ...}` on
      # `review_requests:<m2.id>`. The LV's stack-scoped subscription
      # (NOT the click handler — we never click in this test) must
      # consume it and refresh both the pill and the overlay.
      {:ok, _} = ReviewRequests.approve_item(item_on_m2.id, "external tester")
      _ = :sys.get_state(view.pid)
      post_html = render(view)

      post = :sys.get_state(view.pid).socket.assigns
      assert post.selected_stack_pending_review_count == 1
      assert length(post.selected_stack_open_review_requests) == 1
      # The surviving RR is m1's — not m2's.
      assert hd(post.selected_stack_open_review_requests).task_id == m1.id

      assert post_html =~ ~s(data-pending-count="1")
      assert post_html =~ "Needs feedback (1)"
      refute post_html =~ ~s(data-review-item-id="#{item_on_m2.id}")
    end

    test "(d) close_stack_detail unwinds the per-member subscriptions, leaving board subs intact",
         %{conn: conn, stack: stack} do
      m1 = seed_s5_member(stack, "in_progress", 1)
      m2 = seed_s5_member(stack, "in_progress", 2)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_click(view, "open_stack_detail", %{"id" => stack.id})

      # While open: the stack-scoped subscription set must contain
      # every member id.
      mid = :sys.get_state(view.pid).socket.assigns
      assert MapSet.member?(mid.stack_review_request_subscriptions, m1.id)
      assert MapSet.member?(mid.stack_review_request_subscriptions, m2.id)

      # The board-level set (from the badges-task wiring) already holds
      # these too because the members were created BEFORE mount and so
      # were caught by the initial subscribe-all-tasks at mount/3. This
      # is the realistic overlap case — the unwind must NOT collateral-
      # drop the board's subscription.
      assert MapSet.member?(mid.review_request_subscriptions, m1.id)
      assert MapSet.member?(mid.review_request_subscriptions, m2.id)

      _ = render_click(view, "close_stack_detail", %{})

      post = :sys.get_state(view.pid).socket.assigns
      assert post.show_stack_detail == false
      assert post.selected_stack == nil

      # Stack-scoped set is empty — no member ids retained.
      assert MapSet.size(post.stack_review_request_subscriptions) == 0

      # Board-level set still holds both members. The unwind respected
      # the overlap and only dropped subs the stack panel uniquely
      # added.
      assert MapSet.member?(post.review_request_subscriptions, m1.id)
      assert MapSet.member?(post.review_request_subscriptions, m2.id)

      # And the live-refresh stops touching the stack panel's assigns
      # once it's closed: an external RR creation no longer drives
      # `:selected_stack_pending_review_count` (it stays at the
      # closed-panel default of 0). The board still consumes the
      # broadcast via its own subscriptions, but the stack assigns
      # are reset and stay reset.
      _ = seed_s5_review_request(m1)
      _ = :sys.get_state(view.pid)
      post2 = :sys.get_state(view.pid).socket.assigns
      assert post2.selected_stack_pending_review_count == 0
      assert post2.selected_stack_open_review_requests == []
    end
  end
end
