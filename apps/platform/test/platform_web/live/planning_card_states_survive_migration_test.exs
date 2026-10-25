defmodule PlatformWeb.PlanningCardStatesSurviveMigrationTest do
  @moduledoc """
  Part A of task 019fe1b7 stage 4 — the no-observable-change contract, asserted
  at the RENDERED SURFACE through the board's public entry point (`live/2` on
  `~p"/tasks"`), never through the lifecycle internals the migration added.

  A migration tested only through its own new modules has proved that the new
  modules work. It has not proved that the old behaviour survived. So nothing
  in this file mentions `Platform.Lifecycle`, `Executor`, `Edges` or either
  lifecycle step module: every fixture is a persisted task row and every
  assertion is a DOM node.

  ## The enumerated set, read from the module rather than from prose

  The stage description said "FOUR outcome treatments" and then listed three.
  The code at the base commit is the arbiter and it says THREE:
  `PlanningStepExtension`'s `@treatments` map has exactly `:complete`,
  `:failed` and `:contradicted`. The fourth thing is `:active`, which is a
  KIND (it appears in `@severity` alongside those three) but not an outcome
  treatment — it comes from the separate `@cursor_treatments` table, keyed by
  `task.planning_step`, with exactly `"designing"` and `"architecting"`.

  So the full state set this file pins is SIX rendering decisions:

  | state                                     | renders |
  | ----------------------------------------- | ------- |
  | outcome `complete`                        | yes, at `complete_statuses/0` |
  | outcome `failed`                          | yes, at every status |
  | outcome `not_applicable` + contradicted   | yes, at every status |
  | outcome `not_applicable`, any other reason| **no** |
  | cursor `"designing"` / `"architecting"`   | yes, at `active_statuses/0` |
  | cursor `"planning"`                       | **no** |

  The two "no" rows are what make the four "yes" rows discriminating: an
  implementation that renders a chip for anything recorded passes every
  positive case and fails both negatives.

  ## Coverage is asserted, not assumed

  A hand-written state list agrees with itself forever. `covers the whole
  vocabulary` below pins the fixture set against `Task.planning_step_outcomes/0`,
  `Task.planning_steps/0` and `Task.planning_step_keys/0` — the upstream lists
  the two treatment tables are derived from — so a seventh state added
  upstream fails HERE instead of silently going unrendered and untested.

  ## The contradicted case is driven, not hand-written

  `@reason_contradicted` is bound at compile time from
  `PreplanStep.reasons().contradicted`, so a hand-written fixture using that
  same accessor agrees with the renderer BY CONSTRUCTION and cannot detect the
  failure the stage brief names: the migration persisting a different reason
  string. The only fixture that discriminates is one where the reason is
  written by the real persistence path. So the contradicted case runs
  `PreplanStep.start/1` on a genuinely non-UI task and then
  `PreplanStep.audit_ui_prediction/2` — the writer — and renders whatever row
  that left behind.

  ## LazyHTML, not Floki

  LiveView 1.1 dropped Floki and this umbrella does not carry it; a
  Floki-based test compiles and then fails en masse at runtime, which reads
  like a regression. Selectors are `data-role` / `data-planning-outcome` /
  `data-planning-reason` — the attributes this component controls — never
  `html =~ some_string`, which this repo has a recorded case of passing off a
  raw placeholder.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Design.PreplanStep
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Stacks
  alias Platform.Tasks.Task
  alias PlatformWeb.Components.PlanningStepExtension

  @desktop_role "planning-step-extension"
  @member_role "stack-member-planning-step"

  @recorded_at "2026-08-09T00:00:00Z"

  # A status OUTSIDE `complete_statuses/0` and `active_statuses/0`, used to pin
  # the persistence promise: failures stay visible after work has started.
  @post_planning_status "in_progress"

  defp u, do: System.unique_integer([:positive])

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "planning_states_#{u()}@example.com",
        name: "Planning States Test User",
        oidc_sub: "oidc-planning-states-#{u()}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} = Tasks.create_project(%{name: "Planning States #{u()}"})
    project
  end

  defp create_task(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Planning states task #{u()}",
            status: "planning",
            priority: "medium"
          },
          attrs
        )
      )

    task
  end

  # `planning_step` / `planning_step_outcomes` are deliberately absent from
  # `Task.changeset/2`'s cast list; the narrow changeset is the only door.
  defp set_planning(task, attrs) do
    task
    |> Task.planning_step_changeset(attrs)
    |> Repo.update!()
  end

  defp outcome(step_key, outcome, extra \\ %{}) do
    %{
      step_key => Map.merge(%{"outcome" => outcome, "recorded_at" => @recorded_at}, extra)
    }
  end

  defp mount_board(conn) do
    {:ok, view, _html} = live(conn, ~p"/tasks")
    view
  end

  defp query(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
  end

  defp count(view, selector), do: view |> query(selector) |> Enum.count()

  # ANTI-VACUITY PRECONDITION, applied in every case below. A fixture in the
  # wrong status renders no card at all, and a test built on it asserts
  # nothing — `refute has_element?` would pass for the wrong reason. So every
  # case first proves the card itself is on the board.
  defp assert_card_on_board!(view, task) do
    assert count(view, "[data-task-id='#{task.id}']") >= 1,
           "the fixture task is not on the board at all — every render assertion " <>
             "in this case would be vacuous (status=#{task.status})"

    view
  end

  describe "the enumerated state set covers the whole vocabulary" do
    # Without this, the six cases below are a list that agrees with itself.
    # These three accessors are what the two treatment tables are derived
    # from, so a value added to any of them and not rendered fails here.
    test "every outcome, every cursor and every step key is exercised by this file" do
      assert Enum.sort(Task.planning_step_outcomes()) ==
               Enum.sort(~w(complete not_applicable failed)),
             "the outcome vocabulary changed; this file's state matrix must grow to match"

      assert Enum.sort(Task.planning_steps()) ==
               Enum.sort(~w(designing planning architecting)),
             "the cursor vocabulary changed; this file's cursor cases must grow to match"

      assert Enum.sort(Task.planning_step_keys()) == Enum.sort(~w(design architecture)),
             "the step-key vocabulary changed; both keys must be rendered below"
    end

    test "the two status gates are the ones the render cases assume" do
      # Read, not restated: a case below that used `"planning"` for a
      # `complete` chip would go silently vacuous if this gate narrowed.
      assert "planning" in PlanningStepExtension.complete_statuses()
      assert "planning" in PlanningStepExtension.active_statuses()
      refute @post_planning_status in PlanningStepExtension.complete_statuses()
      refute @post_planning_status in PlanningStepExtension.active_statuses()
    end
  end

  describe "outcome states still render on the board after the migration" do
    test "complete renders for BOTH step keys while the task is pre-execution", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      for step_key <- Task.planning_step_keys() do
        task =
          project
          |> create_task()
          |> set_planning(%{planning_step_outcomes: outcome(step_key, "complete")})

        view = conn |> mount_board() |> assert_card_on_board!(task)

        assert count(
                 view,
                 "[data-role='#{@desktop_role}'][data-planning-outcome='complete']"
               ) >= 1,
               "the complete chip for step #{step_key} stopped rendering"

        assert count(
                 view,
                 "[data-role='#{@desktop_role}'] [data-planning-step-key='#{step_key}']"
               ) >= 1
      end
    end

    # ABSENCE HALF for the case above, and it is the persistence rule rather
    # than a mere negative: a `complete` chip is traded for density once work
    # has started. Paired with the failure case below at the SAME status,
    # which is where the two rules disagree.
    test "complete stops rendering after work starts, while failed does not", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      completed =
        project
        |> create_task(%{status: @post_planning_status})
        |> set_planning(%{planning_step_outcomes: outcome("design", "complete")})

      failed =
        project
        |> create_task(%{status: @post_planning_status})
        |> set_planning(%{
          planning_step_outcomes: outcome("architecture", "failed", %{"detail" => "econnrefused"})
        })

      view = conn |> mount_board() |> assert_card_on_board!(completed)
      assert_card_on_board!(view, failed)

      # POSITIVE CONTROL in the SAME run: the strip machinery fired at all.
      # Without it, "no complete chip" is satisfied by a board that rendered
      # no strips whatsoever.
      assert count(view, "[data-role='#{@desktop_role}'][data-planning-outcome='failed']") == 1

      assert count(view, "[data-role='#{@desktop_role}'][data-planning-outcome='complete']") == 0,
             "a complete chip is still rendering at #{@post_planning_status}"
    end

    test "failed renders, and carries member 4's PR-body sentence verbatim", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      task =
        project
        |> create_task()
        |> set_planning(%{
          planning_step_outcomes: outcome("architecture", "failed", %{"detail" => "econnrefused"})
        })

      view = conn |> mount_board() |> assert_card_on_board!(task)

      chip =
        query(
          view,
          "[data-role='#{@desktop_role}'] [data-planning-outcome='failed']"
        )

      assert Enum.count(chip) == 1
      assert LazyHTML.attribute(chip, "data-planning-step-key") == ["architecture"]

      # The element this component feeds, not a substring of the page: the
      # composed title lives on the chip's own `title` attribute.
      assert LazyHTML.attribute(chip, "title") == [
               "Architecture gate did not run — econnrefused"
             ]
    end

    test "a plain not_applicable renders NOTHING, with a contradicted sibling as the control",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      # The negative. This fixture discriminates because the two candidate
      # rules — "render any recorded outcome" and the real one — give
      # DIFFERENT answers here; a `failed` fixture would not separate them.
      plain =
        project
        |> create_task()
        |> set_planning(%{
          planning_step_outcomes:
            outcome("design", "not_applicable", %{"reason" => PreplanStep.reasons().no_designer})
        })

      # The control, same run: the SAME outcome value with the ONE reason
      # that renders. So the difference in DOM is attributable to the reason
      # and to nothing else.
      control =
        project
        |> create_task()
        |> set_planning(%{
          planning_step_outcomes:
            outcome("design", "not_applicable", %{
              "reason" => PlanningStepExtension.contradicted_reason()
            })
        })

      view = conn |> mount_board() |> assert_card_on_board!(plain)
      assert_card_on_board!(view, control)

      assert count(view, "[data-role='#{@desktop_role}']") == 1,
             "exactly one of the two not_applicable tasks may render a strip"

      assert count(
               view,
               "[data-planning-reason='#{PreplanStep.reasons().no_designer}']"
             ) == 0

      # Page-wide, so 2: with no `?status=` the phone board renders the
      # Backlog section too (task 01a15746 stage 1), and these planning-status
      # tasks render there as well as on the desktop kanban.
      assert count(
               view,
               "[data-planning-reason='#{PlanningStepExtension.contradicted_reason()}']"
             ) == 2
    end
  end

  describe "the contradicted chip, driven through the real writer" do
    # THE CASE THAT FAILS SILENTLY. `@reason_contradicted` is compile-time
    # bound from `PreplanStep.reasons/0`, so a fixture spelled with that same
    # accessor matches the renderer by construction whatever the migration
    # persists. Only a row written by the real path can detect a drift
    # between what is WRITTEN and what is RENDERED.
    test "a real no-UI skip that the plan contradicts renders the warning chip", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      task =
        create_task(project, %{
          title: "Add Providers.Architecture shim",
          description: "Add Providers.Architecture shim"
        })

      # Step 1: the real heuristic records the skip.
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :not_applicable} = PreplanStep.start(task)
      end)

      skipped = Repo.get!(Task, task.id)

      assert PreplanStep.persisted_outcome(skipped) == :not_applicable,
             "the fixture did not actually take the no-UI path — the audit below " <>
               "would no-op and this test would assert nothing"

      # Step 2: the real detector annotates the contradiction. THIS is the
      # writer of the reason string the renderer keys on.
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :contradicted} =
                 PreplanStep.audit_ui_prediction(skipped, [
                   %{
                     "name" => "Render the design column",
                     # A token `PlanEngine.ui_touching?/1` actually matches. A
                     # prose description of UI work that contains no token is
                     # classified CONSISTENT, and this case would then assert
                     # nothing — the first fixture tried here did exactly that
                     # and the `{:ok, :contradicted}` match caught it.
                     "description" =>
                       "Edit lib/platform_web/live/tasks_live.html.heex to add the column."
                   }
                 ])
      end)

      contradicted = Repo.get!(Task, task.id)
      persisted = contradicted.planning_step_outcomes["design"]["reason"]

      view = conn |> mount_board() |> assert_card_on_board!(contradicted)

      chip = query(view, "[data-role='#{@desktop_role}'] [data-planning-reason]")

      assert Enum.count(chip) == 1,
             "the contradicted chip stopped rendering — the reason the writer " <>
               "persisted (#{inspect(persisted)}) no longer matches the reason the " <>
               "renderer keys on (#{inspect(PlanningStepExtension.contradicted_reason())})"

      # Asserted on the RENDERED attribute against the PERSISTED value, so the
      # two are pinned to each other rather than both to the same accessor.
      assert LazyHTML.attribute(chip, "data-planning-reason") == [persisted]
      assert LazyHTML.attribute(chip, "data-planning-outcome") == ["not_applicable"]
    end
  end

  describe "the active-cursor states still render" do
    test "both cursors render while the task is in planning", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      for cursor <- ["designing", "architecting"] do
        task =
          project
          |> create_task()
          |> set_planning(%{planning_step: cursor})

        view = conn |> mount_board() |> assert_card_on_board!(task)

        assert count(view, "[data-role='#{@desktop_role}'] [data-planning-cursor='#{cursor}']") ==
                 1,
               "the #{cursor} cursor chip stopped rendering"
      end
    end

    # ABSENCE HALF, with the presence half in the SAME run. `"planning"` is
    # the third member of `Task.planning_steps/0` and is deliberately absent
    # from `@cursor_treatments`.
    test "the plain planning cursor renders nothing, with a designing sibling as control",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      plain = create_task(project)
      assert plain.planning_step == "planning", "schema default changed; fixture is stale"

      control = project |> create_task() |> set_planning(%{planning_step: "designing"})

      view = conn |> mount_board() |> assert_card_on_board!(plain)
      assert_card_on_board!(view, control)

      # Page-wide, so 2: with no `?status=` the phone board renders the
      # Backlog section too (task 01a15746 stage 1), and these planning-status
      # tasks render there as well as on the desktop kanban.
      assert count(view, "[data-planning-cursor='designing']") == 2
      assert count(view, "[data-planning-cursor='planning']") == 0
    end

    # The cursor is a statement about NOW. A stale one on an executing task is
    # a bug in expiry, not something the board papers over.
    test "a stale cursor after work starts renders nothing, controlled by a planning sibling",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      stale =
        project
        |> create_task(%{status: @post_planning_status})
        |> set_planning(%{planning_step: "designing"})

      control = project |> create_task() |> set_planning(%{planning_step: "designing"})

      view = conn |> mount_board() |> assert_card_on_board!(stale)
      assert_card_on_board!(view, control)

      # The control proves cursor rendering works at all in this run; the
      # count of exactly two (the control's desktop card and its phone-board
      # Backlog card, task 01a15746 stage 1) proves the stale task is
      # suppressed on both surfaces.
      assert count(view, "[data-planning-cursor='designing']") == 2
    end
  end

  describe "variant :compact on stack-member rows" do
    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      slug = "planning-states-#{u()}"

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Planning States Stack #{u()}",
          rollup_branch: Stacks.rollup_branch_name(slug)
        })

      members =
        for pos <- 1..4 do
          {:ok, member} =
            Tasks.create_task(%{
              project_id: project.id,
              stack_id: stack.id,
              stack_position: pos,
              title: "Planning states member #{pos}",
              status: "planning",
              priority: "medium"
            })

          member
        end

      {:ok, _stack} = Stacks.recompute_stack_status(stack)

      %{conn: conn, project: project, stack: stack, members: members}
    end

    # The whole compact contract in ONE run: the two failure states render,
    # the two benign states do not, and every count is exact. Split across
    # four tests, the two zeroes would each be satisfiable by a row that
    # rendered no marker at all.
    test "failure states render and benign states are suppressed, in one run",
         %{conn: conn, stack: stack, members: [failed, contradicted, complete, cursor]} do
      set_planning(failed, %{
        planning_step_outcomes: outcome("architecture", "failed", %{"detail" => "boom"})
      })

      set_planning(contradicted, %{
        planning_step_outcomes:
          outcome("design", "not_applicable", %{
            "reason" => PlanningStepExtension.contradicted_reason()
          })
      })

      set_planning(complete, %{planning_step_outcomes: outcome("design", "complete")})
      set_planning(cursor, %{planning_step: "designing"})

      view = mount_board(conn)
      stacks_click(view, "stack_toggle_expand", %{"id" => stack.id})

      # PRECONDITION: the rows exist. Members are stripped from the solo-card
      # board, so an unexpanded stack renders none of them and every
      # assertion below would be vacuous.
      assert count(view, "[data-role='#{@member_role}']") == 2,
             "expected exactly the two FAILURE members to carry a compact marker"

      assert count(view, "[data-role='#{@member_role}'][data-planning-outcome='failed']") == 1

      assert count(view, "[data-role='#{@member_role}'][data-planning-outcome='not_applicable']") ==
               1

      # The benign pair. These zeroes are meaningful only because the two
      # assertions above are non-zero in the SAME render.
      assert count(view, "[data-role='#{@member_role}'][data-planning-outcome='complete']") == 0
      assert count(view, "[data-role='#{@member_role}'] [data-planning-cursor]") == 0
    end
  end

  # Stacks events live on `PlatformWeb.Tasks.StacksComponent` (task
  # 01a008f6 stage 3). Dispatch to the component, then re-render the whole
  # view so board markup and post-notify shell state are both visible.
  defp stacks_click(view, event, params \\ %{}) do
    _ = render_click(with_target(view, "#tasks-stacks"), event, params)
    render(view)
  end
end
