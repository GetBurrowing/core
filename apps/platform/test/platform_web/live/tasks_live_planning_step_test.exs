defmodule PlatformWeb.TasksLivePlanningStepTest do
  @moduledoc """
  Call-site guards for the ADR-0046 planning-step extension on the kanban
  board (task `019f9b29-9c47`, stack member 8, stage 2).

  Stage 1 owns the component's own behaviour (`planning_step_extension_test.exs`,
  `async: true`, no DB). THIS file owns only what stage 2 added: that the
  component is mounted above the desktop solo card AND the mobile solo card,
  with DISTINCT `data-role`s, that the card fuses via `rounded-t-none` exactly
  when the strip renders, that a task with ADR-0046 at its defaults produces no
  new DOM at all, and that the existing `{:task_updated, _}` wire refreshes the
  strip without a remount.

  New file rather than an append to `tasks_live_test.exs` (11.4 kloc, 342 full
  mounts): the umbrella file is the accretion this task exists to avoid.

  ## Assertion style

  `has_element?/2` against the `data-*` seam, not `html =~`. `html =~` cannot
  distinguish "the desktop strip rendered" from "the mobile strip rendered"
  when the two share one DOM, and it cannot count. Every positive control is
  paired with its absence half in the same `describe` block, because a
  constant-`true` implementation satisfies only one of the pair.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Design.PreplanStep
  alias Platform.Repo
  alias Platform.Tasks
  alias PlatformWeb.Components.PlanningStepExtension

  # The two `data-role` values stage 2 introduces. Named once so a rename
  # shows up as one edit and so the "these must differ" guard below has
  # something to compare.
  @desktop_role "planning-step-extension"
  @mobile_role "mobile-planning-step-extension"

  # `in_progress` is the mobile board's default status filter
  # (`tasks_live.ex` mount, `:active_status_filter`) AND a desktop column, so
  # a task in this status is the only one that renders on BOTH branches
  # without driving the filter pills. `failed` renders at every status, which
  # is what makes that possible.
  @dual_branch_status "in_progress"

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "planning_step_#{System.unique_integer([:positive])}@example.com",
        name: "Planning Step Test User",
        oidc_sub: "oidc-planning-step-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Planning Step Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/planning-step.git"
      })

    project
  end

  defp create_task(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Planning step task #{System.unique_integer([:positive])}",
            status: @dual_branch_status,
            priority: "medium"
          },
          attrs
        )
      )

    task
  end

  # `planning_step` / `planning_step_outcomes` are DELIBERATELY absent from
  # `Task.changeset/2`'s cast list (member 4), so they cannot be set at
  # creation. The narrow changeset is the only door.
  defp set_outcomes(task, outcomes) do
    task
    |> Platform.Tasks.Task.planning_step_changeset(%{planning_step_outcomes: outcomes})
    |> Repo.update!()
  end

  defp failed_architecture do
    %{
      "architecture" => %{
        "outcome" => "failed",
        "recorded_at" => "2026-07-26T00:00:00Z",
        "detail" => "econnrefused"
      }
    }
  end

  # `LazyHTML`, not `Floki`: LiveView 1.1 dropped the Floki dependency and this
  # umbrella does not carry it. `has_element?/2` cannot count, and counting is
  # the whole point of the DOM-safety guard below.
  defp query(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
  end

  defp count_elements(view, selector), do: view |> query(selector) |> Enum.count()

  describe "failed outcome renders on both board branches" do
    test "the failed strip renders above the desktop AND the mobile card", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      project
      |> create_task()
      |> set_outcomes(failed_architecture())

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # The summary `data-planning-outcome` lives on the ROOT (stage 1 added
      # it for exactly this selector). The plan as written put
      # `data-planning-*` on the chips only, which would have made this
      # compound selector match zero elements.
      assert has_element?(view, "[data-role='#{@desktop_role}'][data-planning-outcome='failed']")
      assert has_element?(view, "[data-role='#{@mobile_role}'][data-planning-outcome='failed']")

      # The copy is member 4's PR-body sentence, word for word.
      assert render(view) =~ "Architecture gate did not run"
    end

    # ABSENCE HALF. Without this, a component that rendered a failed strip
    # unconditionally would pass the test above.
    test "a task with ADR-0046 at its defaults adds no DOM on either branch", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      task = create_task(project)

      # Defaults, not merely "no outcomes recorded" — assert the precondition
      # so a schema default change surfaces here rather than as a mystery.
      assert task.planning_step == "planning"
      assert task.planning_step_outcomes == %{}

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # The task itself is on the board, so this is not passing by an empty
      # board.
      assert has_element?(view, "[data-task-id='#{task.id}']")

      refute has_element?(view, "[data-role^='planning-step']")
      refute has_element?(view, "[data-role^='mobile-planning-step']")
      refute has_element?(view, "[data-planning-outcome]")
    end

    # `not_applicable` is the progressive-enhancement path: nobody holds the
    # responsibility. ADR-0046:83 is that it must never collapse into
    # `failed`, and the presentation half of that promise is that it renders
    # NOTHING. Paired with the `failed` test above, this is the guard that a
    # constant "render a chip for any recorded outcome" implementation fails.
    test "a plain not_applicable outcome renders nothing", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      project
      |> create_task()
      |> set_outcomes(%{
        "design" => %{
          "outcome" => "not_applicable",
          "recorded_at" => "2026-07-26T00:00:00Z",
          "reason" => PreplanStep.reasons().no_designer
        }
      })

      {:ok, view, _html} = live(conn, ~p"/tasks")

      refute has_element?(view, "[data-role='#{@desktop_role}']")
      refute has_element?(view, "[data-role='#{@mobile_role}']")
    end

    # ...but member 7's own false-negative annotation DOES render, warning
    # toned. Bound to `PreplanStep.reasons/0` rather than the literal, per
    # stage 1's pattern.
    test "the contradicted not_applicable renders on both branches", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      project
      |> create_task()
      |> set_outcomes(%{
        "design" => %{
          "outcome" => "not_applicable",
          "recorded_at" => "2026-07-26T00:00:00Z",
          "reason" => PreplanStep.reasons().contradicted
        }
      })

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "[data-role='#{@desktop_role}']")
      assert has_element?(view, "[data-role='#{@mobile_role}']")

      assert has_element?(
               view,
               "[data-role='#{@desktop_role}'] [data-planning-reason='#{PreplanStep.reasons().contradicted}']"
             )
    end
  end

  describe "DOM safety across the shared desktop/mobile document" do
    # The trip-wire. Desktop and mobile are CSS visibility, not presence, so
    # both branches are in one document. A component that emitted an `id`
    # would produce duplicate ids (LiveView undefined behaviour) and a shared
    # `data-role` would double-match every selector in this file.
    test "each data-role appears exactly once per task and no id is emitted", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      project
      |> create_task()
      |> set_outcomes(failed_architecture())

      # A mount that raised would fail here rather than in an assertion.
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert count_elements(view, "[data-role='#{@desktop_role}']") == 1
      assert count_elements(view, "[data-role='#{@mobile_role}']") == 1
      assert count_elements(view, "[data-role='task-card-group']") == 1
      assert count_elements(view, "[data-role='mobile-task-card-group']") == 1

      # The roles genuinely differ. Cheap, but this is the property the whole
      # file's selector strategy rests on, and a copy-paste of the desktop
      # invocation into the mobile branch is the obvious way to break it.
      refute @desktop_role == @mobile_role

      # No `id` anywhere on either strip. `LazyHTML.attribute/2` collects the
      # attribute across every matched node, so `[]` is "none of them carries
      # one" rather than "the first one doesn't".
      for role <- [@desktop_role, @mobile_role] do
        assert view |> query("[data-role='#{role}']") |> LazyHTML.attribute("id") == []
      end

      # And the sanity check that the query above is not vacuous: the card,
      # which DOES carry an id, is found by the same mechanism.
      assert view |> query("[data-role='task-card-group'] > div") |> LazyHTML.attribute("id") !=
               []
    end

    # The drag-source regression the wrapper is designed around.
    # `kanban_drag_drop.js` resolves `e.target.closest("[data-task-id]")`; if
    # the wrapper carried the attribute, the wrapper would become the drag
    # source and `kanban-dragging` would fade the wrong element.
    test "the wrapper carries no data-task-id and the card keeps it", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      task =
        project
        |> create_task()
        |> set_outcomes(failed_architecture())

      {:ok, view, _html} = live(conn, ~p"/tasks")

      refute has_element?(view, "[data-role='task-card-group'][data-task-id]")
      refute has_element?(view, "[data-role='mobile-task-card-group'][data-task-id]")
      refute has_element?(view, "[data-role='#{@desktop_role}'][data-task-id]")
      refute has_element?(view, "[data-role='#{@mobile_role}'][data-task-id]")

      # The card — the element that actually is the drag source — still has
      # it, and still draggable.
      assert has_element?(
               view,
               "#task-card-#{task.id}[data-task-id='#{task.id}'][draggable='true']"
             )

      # And the strip is a SIBLING of the card, not inside it: a `<button>`
      # nested in the mobile card `<button>` is invalid HTML.
      refute has_element?(view, "#task-card-#{task.id} [data-role='#{@desktop_role}']")
    end
  end

  describe "fusion: rounded-t-none tracks visible?/1" do
    test "the card gains rounded-t-none exactly when the strip renders", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      visible =
        project
        |> create_task()
        |> set_outcomes(failed_architecture())

      invisible = create_task(project)

      assert PlanningStepExtension.visible?(visible)
      refute PlanningStepExtension.visible?(invisible)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Presence half.
      assert has_element?(view, "#task-card-#{visible.id}.rounded-t-none")

      # ABSENCE half, in the same block: a task with nothing to show must
      # render a byte-identical card to before ADR-0046.
      refute has_element?(view, "#task-card-#{invisible.id}.rounded-t-none")
    end
  end

  describe "live refresh through the existing task_updated wire" do
    # Member 4's `write_planning_step/2` broadcasts `{:task_updated, task}`
    # specifically so this card refreshes without polling, and
    # `tasks_live.ex` already routes that to `refresh_board/1`. This test
    # proves an EXISTING wire — if it fails, the bug is upstream of stage 2.
    test "recording a failed step surfaces the chip without a remount", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      task = create_task(project)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      refute has_element?(view, "[data-role='#{@desktop_role}']")

      {:ok, _updated} = Tasks.record_planning_step(task, :architecture, {:error, :econnrefused})

      # No re-`live/2`: the same view instance must show it.
      assert eventually(view, "[data-role='#{@desktop_role}']")
      assert has_element?(view, "[data-role='#{@mobile_role}'][data-planning-outcome='failed']")
      assert has_element?(view, "#task-card-#{task.id}.rounded-t-none")
    end
  end

  # The board broadcast is a plain PubSub message; `render/1` on the same view
  # process flushes the mailbox first, so one render is normally enough. Retry
  # a bounded number of times rather than sleeping a fixed amount — the box
  # this runs on is routinely loaded, and a fixed sleep is either a flake or
  # wasted wall clock.
  defp eventually(view, selector, attempts \\ 20) do
    cond do
      has_element?(view, selector) ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(25)
        eventually(view, selector, attempts - 1)
    end
  end
end
