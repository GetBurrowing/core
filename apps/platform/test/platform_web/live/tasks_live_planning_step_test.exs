defmodule PlatformWeb.TasksLivePlanningStepTest do
  @moduledoc """
  Call-site guards for the ADR-0046 planning-step extension on the kanban
  board (task `019f9b29-9c47`, stack member 8, stages 2 and 3).

  Stage 1 owns the component's own behaviour (`planning_step_extension_test.exs`,
  `async: true`, no DB). THIS file owns the CALL SITES.

  Stage 2: the component is mounted above the desktop solo card AND the mobile
  solo card, with DISTINCT `data-role`s; the card fuses via `rounded-t-none`
  exactly when the strip renders; a task with ADR-0046 at its defaults produces
  no new DOM at all; and the existing `{:task_updated, _}` wire refreshes the
  strip without a remount.

  Stage 3: the `variant={:compact}` marker on EXPANDED STACK-MEMBER ROWS.
  Stack members never render as solo cards — `board_items/1` strips them — so
  without this call site every member of every stack, including this task's own
  stack, has no board-level gate signal at all. The compact marker is
  failure-only by design (`failed` and member 7's `no_ui_surface_contradicted`);
  `complete` and the active cursor are suppressed because a member row is a
  ~44px line already carrying a position glyph, a truncated title, an action
  badge, a status badge and a dependency annotation.

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
  alias Platform.Tasks.Stack
  alias Platform.Tasks.Stacks
  alias PlatformWeb.Components.PlanningStepExtension

  # The two `data-role` values stage 2 introduces. Named once so a rename
  # shows up as one edit and so the "these must differ" guard below has
  # something to compare.
  @desktop_role "planning-step-extension"
  @mobile_role "mobile-planning-step-extension"

  # Stage 3's compact-variant roles, on stack-member rows. Split desktop/mobile
  # for the same shared-DOM reason as above.
  @desktop_member_role "stack-member-planning-step"
  @mobile_member_role "mobile-stack-member-planning-step"

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

  # ── stack fixtures (stage 3) ──────────────────────────────────────────────
  #
  # Stack members do NOT render as solo cards — `board_items/1` strips them —
  # so every stage 3 assertion needs a real stack, expanded. Mirrors
  # `tasks_live_test.exs`'s `stack_fixture/1` + `seed_stack_members/2` rather
  # than reaching into that module: it is 11.4 kloc of private helpers and this
  # file's whole reason to exist is not appending to it.
  defp create_stack(project) do
    slug = "planning-step-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Planning Step Stack #{System.unique_integer([:positive])}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  # Members are created at `in_review` (the same status `tasks_live_test.exs`
  # seeds) so the rollup lands somewhere the mobile filter pill can reach.
  defp create_members(stack, count) do
    members =
      for pos <- 1..count do
        {:ok, member} =
          Tasks.create_task(%{
            project_id: stack.project_id,
            stack_id: stack.id,
            stack_position: pos,
            title: "Planning step member #{pos}",
            status: "in_review",
            priority: "medium"
          })

        member
      end

    {:ok, stack} = Stacks.recompute_stack_status(stack)

    {Repo.get!(Stack, stack.id), members}
  end

  # The DESKTOP expansion only. `stack_toggle_expand` is one MapSet for both
  # branches, so this also expands the mobile list — but the mobile list only
  # renders the ACTIVE filter pill's section, so the mobile assertions below
  # additionally drive `filter_by_status`.
  defp expand(view, stack) do
    stacks_click(view, "stack_toggle_expand", %{"id" => stack.id})
    view
  end

  defp not_applicable(reason) do
    %{
      "design" => %{
        "outcome" => "not_applicable",
        "recorded_at" => "2026-07-26T00:00:00Z",
        "reason" => reason
      }
    }
  end

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
    # responsibility. The rule in
    # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome` is that it must never collapse into
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

  # ── stage 4: the behavioural half of the drag guard ───────────────────────

  describe "the drag path survives the wrapper" do
    # `tasks_live_board_invariance_test.exs` holds the STRUCTURAL half — the
    # wrapper carries no `data-task-id`, every draggable card is still inside a
    # `[data-column]`, and `closest("[data-task-id]")` from the extension
    # reaches nothing. That guard fails in seconds in CI. THIS is the
    # behavioural half, and it is the only one that proves the resolved values
    # actually drive a move: a structurally perfect board whose drop handler
    # rejects the payload passes every selector assertion.
    #
    # Not a real HTML5 drag — there is no browser here. What it does is resolve
    # the two values `kanban_drag_drop.js` computes (`card.dataset.taskId` and
    # `card.closest("[data-column]").dataset.column`) OFF THE RENDERED DOM
    # rather than from a literal, then push the same `board_drop` event the
    # hook pushes with exactly those values. A wrapper that captured the drag
    # source would change what those queries return, and the drop would carry
    # the wrong id.
    test "a drop resolved off the DOM moves the card, and the strip follows it",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      task =
        project
        |> create_task()
        |> set_outcomes(failed_architecture())

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # The strip is on the board, so this is not a drag across an unchanged
      # DOM — the element the guard is about is present.
      assert has_element?(view, "[data-role='#{@desktop_role}']")

      # RESOLVE, don't assume. `[data-column='X'] [data-task-id][draggable]` is
      # `closest` inverted: the same ancestor relation the hook walks.
      resolved_ids =
        view
        |> query("[data-column='#{@dual_branch_status}'] [data-task-id][draggable='true']")
        |> LazyHTML.attribute("data-task-id")

      assert resolved_ids == [task.id]

      # `in_progress -> backlog` is a legal drop (`@valid_drop_transitions`) and
      # `backlog` is not an execution-phase status, so it needs no approved
      # plan — the move is about the drag path, not the plan gate.
      render_hook(
        Phoenix.LiveViewTest.with_target(view, "#tasks-board"),
        "board_drop",
        %{"task_id" => task.id, "column" => "backlog"}
      )

      assert Repo.get!(Platform.Tasks.Task, task.id).status == "backlog"

      # The card really moved columns in the rendered board...
      assert has_element?(
               view,
               "[data-column='backlog'] [data-task-id='#{task.id}'][draggable='true']"
             )

      refute has_element?(
               view,
               "[data-column='#{@dual_branch_status}'] [data-task-id='#{task.id}']"
             )

      # ...and the strip travelled with it rather than being stranded in the
      # old column or dropped entirely. `failed` renders at every status, so
      # this also exercises the persistence rule at a status change.
      assert has_element?(view, "[data-column='backlog'] [data-role='#{@desktop_role}']")
      assert count_elements(view, "[data-role='#{@desktop_role}']") == 1
      assert has_element?(view, "#task-card-#{task.id}.rounded-t-none")
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

  # ── stage 3: the compact marker on stack-member rows ──────────────────────

  describe "compact marker on expanded stack-member rows" do
    # THE PAIRED ABSENCE GUARD. One mount, two members: the positive control
    # and the absence assertion are the SAME render, so neither half can pass
    # vacuously. An implementation that renders a chip on every member row
    # fails the count; one that renders none fails the containment.
    test "exactly one chip renders, inside the failed member's row and no other",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      stack = create_stack(project)
      {stack, [clean, failing]} = create_members(stack, 2)

      set_outcomes(failing, failed_architecture())

      {:ok, view, _html} = live(conn, ~p"/tasks")
      view = expand(view, stack)

      # Precondition: BOTH rows are on the board. Without this the absence
      # half could pass on a collapsed stack.
      assert has_element?(view, "#stack-member-#{clean.id}")
      assert has_element?(view, "#stack-member-#{failing.id}")

      assert count_elements(view, "[data-role='#{@desktop_member_role}']") == 1

      assert has_element?(
               view,
               "#stack-member-#{failing.id} [data-role='#{@desktop_member_role}'][data-planning-outcome='failed']"
             )

      refute has_element?(view, "#stack-member-#{clean.id} [data-role='#{@desktop_member_role}']")

      # The copy a human hovers is member 4's PR-body sentence, and the detail
      # is appended rather than dropped.
      assert render(view) =~ "Architecture gate did not run — econnrefused"
    end

    # THE SUPPRESSION RULE, directly paired. `complete` is deliberately given a
    # status at which the EXTENSION variant would render it, so this measures
    # the compact branch rather than the status rule — `visible?/2` asserts
    # that precondition rather than assuming it.
    test "complete renders no chip on a member row while failed does", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      stack = create_stack(project)
      {stack, [completed, failing]} = create_members(stack, 2)

      {:ok, completed} = Tasks.update_task(completed, %{status: "planning"})

      completed =
        set_outcomes(completed, %{
          "design" => %{"outcome" => "complete", "recorded_at" => "2026-07-26T00:00:00Z"}
        })

      set_outcomes(failing, failed_architecture())

      # PRECONDITION, not decoration: this member WOULD render a chip through
      # the extension variant at this status. So the absence below is the
      # compact rule and nothing else.
      assert PlanningStepExtension.visible?(completed, :extension)
      refute PlanningStepExtension.visible?(completed, :compact)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      view = expand(view, stack)

      refute has_element?(
               view,
               "#stack-member-#{completed.id} [data-role='#{@desktop_member_role}']"
             )

      assert has_element?(
               view,
               "#stack-member-#{failing.id} [data-role='#{@desktop_member_role}']"
             )

      # And no muted success chip leaked in by another route.
      refute render(view) =~ "hero-check-badge"
    end

    # Member 7's false-negative annotation is the ONE `not_applicable` that
    # reaches a member row, and it is warning-toned rather than error-toned so
    # it is distinguishable from a real gate failure at a glance.
    test "a plain not_applicable stays silent; the contradicted one renders warning-toned",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      stack = create_stack(project)
      {stack, [silent, contradicted]} = create_members(stack, 2)

      set_outcomes(silent, not_applicable(PreplanStep.reasons().no_ui_surface))
      set_outcomes(contradicted, not_applicable(PreplanStep.reasons().contradicted))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      view = expand(view, stack)

      refute has_element?(
               view,
               "#stack-member-#{silent.id} [data-role='#{@desktop_member_role}']"
             )

      assert has_element?(
               view,
               "#stack-member-#{contradicted.id} [data-role='#{@desktop_member_role}'] " <>
                 "[data-planning-reason='#{PreplanStep.reasons().contradicted}']"
             )

      # Warning, not error: the two must not collapse into one treatment any
      # more than `not_applicable` and `failed` may
      # (`0046-design-and-architecture-phases-in-planning.md § Per-step outcome`).
      assert has_element?(
               view,
               "#stack-member-#{contradicted.id} [data-role='#{@desktop_member_role}'] .text-warning"
             )

      refute has_element?(
               view,
               "#stack-member-#{contradicted.id} [data-role='#{@desktop_member_role}'] .text-error"
             )
    end

    # THE SHARED-DOM TRIP-WIRE. Desktop and mobile member rows are both in the
    # one document; a copy-pasted `data_role` would double-match every selector
    # in this block and an emitted `id` would be a duplicate DOM id.
    test "desktop and mobile member rows carry distinct roles and no ids, in one mount",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      stack = create_stack(project)
      {stack, [_clean, failing]} = create_members(stack, 2)

      set_outcomes(failing, failed_architecture())

      # A mount that raised on duplicate ids fails here, not in an assertion.
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # The mobile list renders only the active filter pill's section, so the
      # mobile half needs the pill moved to the stack's rollup status first.
      render_click(filters(view), "filter_by_status", %{"status" => stack.status})
      view = expand(view, stack)

      assert count_elements(view, "[data-role='#{@desktop_member_role}']") == 1
      assert count_elements(view, "[data-role='#{@mobile_member_role}']") == 1

      assert has_element?(
               view,
               "#stack-member-mobile-#{failing.id} [data-role='#{@mobile_member_role}']"
             )

      # DECLARED TRIVIAL: both operands are module attributes inlined at
      # compile time, so this documents the invariant but cannot measure it.
      # The two `count_elements/2` assertions above are what actually detect a
      # copy-pasted role — a shared value makes both counts 2.
      refute @desktop_member_role == @mobile_member_role

      for role <- [@desktop_member_role, @mobile_member_role] do
        assert view |> query("[data-role='#{role}']") |> LazyHTML.attribute("id") == []
      end

      # Not vacuous: the desktop member row itself DOES carry an id, found by
      # the same mechanism.
      assert view |> query("#stack-member-#{failing.id}") |> LazyHTML.attribute("id") != []
    end

    # `frontend/ui-ux.md`: "the last thing allowed to truncate" is structural,
    # not a review note — `shrink-0 whitespace-nowrap` on the protected
    # fragment, `min-w-0 truncate` on the expendable one. The chip is the
    # marker; the TITLE is what must yield.
    test "the chip is shrink-0 and leaves the row's tap target and title truncation intact",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      stack = create_stack(project)
      {stack, [clean, failing]} = create_members(stack, 2)

      failing =
        set_outcomes(
          failing,
          Map.put(failed_architecture(), "design", %{
            "outcome" => "not_applicable",
            "recorded_at" => "2026-07-26T00:00:00Z",
            "reason" => PreplanStep.reasons().contradicted
          })
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_click(filters(view), "filter_by_status", %{"status" => stack.status})
      view = expand(view, stack)

      # Two chips in one root — the widest the marker ever gets — and the root
      # still refuses to shrink. `Enum.all?/2` on an EMPTY list is `true`, so
      # the class list is pinned non-empty first: without that, deleting the
      # call site outright would satisfy this assertion.
      root_classes =
        view
        |> query("#stack-member-#{failing.id} [data-role='#{@desktop_member_role}']")
        |> LazyHTML.attribute("class")

      assert root_classes != []
      assert Enum.all?(root_classes, &(&1 =~ "shrink-0"))

      assert count_elements(
               view,
               "#stack-member-#{failing.id} [data-role='#{@desktop_member_role}'] [data-planning-step-key]"
             ) == 2

      html = render(view)

      # The row keeps its 44px tap target and the title keeps `min-w-0
      # truncate` — the chip changed neither. Asserted on the row that HAS the
      # chip and the row that does not, so a rule that only holds for the empty
      # case cannot pass.
      for id <- ["stack-member-#{failing.id}", "stack-member-#{clean.id}"] do
        assert html =~ ~r/id="#{id}"[^>]*min-h-\[44px\]/
      end

      assert html =~
               ~r/id="stack-member-#{failing.id}".*?flex-1 min-w-0 text-xs leading-snug truncate/s

      # The marker is a `<span>` on the mobile row, which is itself a
      # `<button>`: a nested button is invalid HTML and browsers reparent it.
      # Same vacuity trap as above — an absent marker has no nested button
      # either, so the marker is pinned present first.
      mobile_marker = query(view, "[data-role='#{@mobile_member_role}']")

      assert Enum.count(mobile_marker) == 1
      assert mobile_marker |> LazyHTML.query("button") |> Enum.empty?()
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

  # Stacks events live on `PlatformWeb.Tasks.StacksComponent` (task
  # 01a008f6 stage 3). Dispatch to the component, then re-render the whole
  # view so board markup and post-notify shell state are both visible.
  defp stacks_click(view, event, params \\ %{}) do
    _ = render_click(with_target(view, "#tasks-stacks"), event, params)
    render(view)
  end

  # Task 01a008f6 stage 6: board filtering is a LiveComponent.
  defp filters(view), do: Phoenix.LiveViewTest.with_target(view, "#tasks-filters")
end
