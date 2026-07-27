defmodule PlatformWeb.TasksLiveBoardInvarianceTest do
  @moduledoc """
  The two promises stages 1–3 make and cannot themselves keep (task
  `019f9b29-9c47`, ADR-0046 stack member 8, stage 4).

  Stages 1–3 each assert that the extension RENDERS. Nothing in them asserts
  what happens to the board of an org that recorded no planning steps at all,
  or to the drag path that now has a new element between a card and its
  column. Both are properties of the ABSENCE of the change, which is the shape
  no positive test can reach.

  ## GUARD 1 — board invariance under zero ADR-0046 data

  Five tasks spread across five desktop columns, every one at the schema
  defaults member 4's migration backfills every pre-existing row to
  (`planning_step: "planning"`, `planning_step_outcomes: %{}`). Neither
  `planning-step` nor `rounded-t-none` may appear anywhere in the document.

  Scope of the claim, stated precisely because the honest version is narrower
  than "byte-identical": stage 2 wraps each card in a zero-gap
  `<div class="flex flex-col" data-role="task-card-group">`, which renders
  unconditionally. That wrapper is the one deliberate structural addition, it
  is invisible (`flex flex-col` around a single child changes no pixel), and
  GUARD 2 below is what constrains it. Everything else — every class, every
  attribute, every text node — is unchanged, which is what these two
  refutations measure.

  ## GUARD 2 — drag source resolution

  `kanban_drag_drop.js:11` resolves the drag source with
  `e.target.closest("[data-task-id]")` and the source column with
  `card.closest("[data-column]")`. Stage 2 introduced the first element that
  sits between a card and its column, so `closest` is now walking through
  something new. Encoded as descendant queries, which is the same ancestor
  relation inverted and the thing LazyHTML can actually express.

  ## GUARD 3 / GUARD 4

  Live in the two sibling modules at the bottom of this file. Both are
  `use ExUnit.Case, async: true` with no `DataCase`: guard 3's whole content is
  that no database is involved, and guard 4 reads a file. Keeping them here
  rather than in a third file keeps every "what must NOT have changed" guard
  for this task in one place.

  ## Vacuity

  Every assertion in this file is an absence, which is the shape that has
  failed four times in this stack — `Enum.all?/2` and `Enum.empty?/1` are both
  `true` on `[]`, and `refute html =~ "planning-step"` passes against a typo'd
  selector, an unwired component, a template branch that never renders and a
  board that rendered nothing at all. So every query is PINNED NON-EMPTY with a
  measured count before anything is asserted over it, and each guard carries
  its positive control in the SAME test.

  ## MEASURED DETONATIONS (2026-07-27, branch `task/019f9b29-9c47…`)

  Every guard below was detonated against a deliberately broken tree and the
  firing assertion recorded. A guard that has never been observed to fail is a
  comment.

  | injected defect | assertion that fired |
  | --- | --- |
  | desktop column renders no items (the vacuity case) | GUARD 1 `count_elements("[data-task-id][draggable='true']") == 5` (left 0) and GUARD 2's `draggable == 5` pin |
  | both solo-card call sites deleted, fusion disabled | GUARD 1 control `assert refreshed_html =~ "planning-step"`; GUARD 2 `count_elements("[data-role='planning-step-extension']") == 1`; GUARD 4 control `assert template =~ "PlanningStepExtension.visible?"` |
  | `outcome_entry/2` returns a `failed` chip for every step of every task | GUARD 1 `refute html =~ "planning-step"` |
  | `data-task-id` added to the card-group wrapper | GUARD 2 `count_elements("[data-role='task-card-group'][data-task-id]") == 0` |
  | extension nested INSIDE the card body | GUARD 2 `count_elements("[data-task-id] [data-role='planning-step-extension']") == 0` |
  | `@valid_drop_transitions` emptied (every drop rejected) | the behavioural half in `tasks_live_planning_step_test.exs`: `Repo.get!(Task, id).status == "backlog"` (left `"in_progress"`) |
  | real `Repo.aggregate/2` inside `entries/2` | GUARD 3 raises `DBConnection.OwnershipError` at the matrix pin |
  | synthetic query telemetry inside `entries/2` (the shared-sandbox case a raise would NOT catch) | GUARD 3 `refute_received {:repo_query, …}`, both purity tests |
  | `@query_event` misspelt | GUARD 3 `Platform.Repo.config()[:telemetry_prefix] ++ [:query] == @query_event` |
  | one line added to `tasks_live.ex` | GUARD 4 `line_count(source) == @shell_line_count` (5888 vs 5887) |
  | `planning_step` inserted into `tasks_live.ex`, line-count-neutral | GUARD 4 `refute source =~ "planning_step"` |
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks

  # One task per desktop column key that maps 1:1 onto a task status
  # (`@desktop_column_statuses` in `tasks_live.ex`). Five is enough to spread
  # the board across the reading order without seeding a stack — stack members
  # are stage 3's surface and are covered in `tasks_live_planning_step_test.exs`.
  @spread_statuses ~w(backlog planning in_progress in_review done)

  # The status that renders on BOTH board branches: a desktop column of its own
  # AND the mobile board's default `:active_status_filter`. The paired positive
  # control flips this one, so the control measures both branches.
  @dual_branch_status "in_progress"

  @desktop_role "planning-step-extension"
  @mobile_role "mobile-planning-step-extension"

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "board_invariance_#{System.unique_integer([:positive])}@example.com",
        name: "Board Invariance Test User",
        oidc_sub: "oidc-board-invariance-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Board Invariance Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/board-invariance.git"
      })

    project
  end

  defp create_task(project, status) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Board invariance task #{status} #{System.unique_integer([:positive])}",
        status: status,
        priority: "medium"
      })

    task
  end

  # `planning_step_outcomes` is deliberately absent from `Task.changeset/2`'s
  # cast list (member 4); the narrow changeset is the only door.
  defp set_outcomes(task, outcomes) do
    task
    |> Platform.Tasks.Task.planning_step_changeset(%{planning_step_outcomes: outcomes})
    |> Repo.update!()
  end

  defp failed_architecture do
    %{
      "architecture" => %{
        "outcome" => "failed",
        "recorded_at" => "2026-07-27T00:00:00Z",
        "detail" => "econnrefused"
      }
    }
  end

  # `LazyHTML`, not `Floki`: LiveView 1.1 dropped the Floki dependency and this
  # umbrella does not carry it. The plan's guard 2 says "Floki over the rendered
  # board"; this is the same thing through the library that is actually here.
  defp query(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
  end

  defp count_elements(view, selector), do: view |> query(selector) |> Enum.count()

  describe "GUARD 1 — board invariance under zero ADR-0046 data" do
    test "a board of defaults renders today's board, and one recorded outcome changes that",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      tasks = Enum.map(@spread_statuses, &create_task(project, &1))

      # PRECONDITION, not decoration: assert the rows really are at the
      # defaults member 4's migration backfills. A schema default change
      # surfaces here rather than as a mystery in the refutations below.
      for task <- tasks do
        assert task.planning_step == "planning"
        assert task.planning_step_outcomes == %{}
      end

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render(view)

      # PIN THE BOARD NON-EMPTY FIRST. Both assertions below are `refute
      # html =~ _`, and an empty board satisfies them perfectly — which is
      # exactly the state where the feature has been deleted.
      assert count_elements(view, "[data-task-id][draggable='true']") ==
               length(@spread_statuses)

      for task <- tasks do
        assert has_element?(view, "[data-task-id='#{task.id}']")
      end

      # THE PROMISE. `planning-step` covers both `data-role`s AND the chips'
      # `data-planning-step-key`; `rounded-t-none` is the fusion class, and
      # its absence is what makes every card byte-identical to the card that
      # shipped before this task.
      refute html =~ "planning-step"
      refute html =~ "rounded-t-none"

      # ── PAIRED POSITIVE CONTROL, SAME TEST ──────────────────────────────
      #
      # Without this half both refutations pass against a component that was
      # never wired up, against a typo'd `data-role`, and against a template
      # branch that never renders.
      flipped = Enum.find(tasks, &(&1.status == @dual_branch_status))
      set_outcomes(flipped, failed_architecture())

      # A fresh mount rather than the broadcast wire: the broadcast path is
      # stage 2's own test, and re-mounting keeps this guard a comparison of
      # two renders of the same board rather than a test of PubSub.
      {:ok, refreshed, _html} = live(conn, ~p"/tasks")
      refreshed_html = render(refreshed)

      assert refreshed_html =~ "planning-step"
      assert refreshed_html =~ "rounded-t-none"

      # The plan says "exactly once each". MEASURED, that is wrong by
      # construction and the count is 4 / 2: desktop and mobile share ONE
      # document (`lg:hidden` / `hidden lg:grid` is CSS visibility, not
      # presence), so both branches render, and each strip contributes a root
      # `data-role` plus a chip `data-planning-step-key`. The precise form of
      # "exactly once" is therefore per-branch and structural, below — a raw
      # substring count would pin an implementation detail of the chip
      # attributes rather than the property.
      assert count_elements(refreshed, "[data-role='#{@desktop_role}']") == 1
      assert count_elements(refreshed, "[data-role='#{@mobile_role}']") == 1

      # EXACTLY ONE of the five tasks fused, on exactly its two branches. This
      # is the assertion that fails both ways: a component that renders for
      # everyone makes it 10, one that renders for nobody makes it 0.
      assert count_elements(refreshed, ".rounded-t-none") == 2
      assert count_elements(refreshed, "[data-task-id='#{flipped.id}'].rounded-t-none") == 2

      # And the other four are untouched — the invariance claim survives the
      # arrival of data for one of them.
      for task <- tasks, task.id != flipped.id do
        assert count_elements(refreshed, "[data-task-id='#{task.id}'].rounded-t-none") == 0
      end

      assert count_elements(refreshed, "[data-task-id][draggable='true']") ==
               length(@spread_statuses)
    end
  end

  describe "GUARD 2 — drag source resolution through the new wrapper" do
    test "closest([data-task-id]) still resolves to the card and never to the wrapper",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      tasks = Enum.map(@spread_statuses, &create_task(project, &1))
      dragged = Enum.find(tasks, &(&1.status == @dual_branch_status))
      set_outcomes(dragged, failed_architecture())

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # PIN EVERY QUERY NON-EMPTY BEFORE ASSERTING OVER IT. `Enum.all?/2` and
      # `Enum.empty?/1` are both `true` on `[]`, so "every draggable card is
      # inside a column" is satisfied by a board with no cards.
      draggable = count_elements(view, "[data-task-id][draggable='true']")
      assert draggable == length(@spread_statuses)

      # (a) every draggable card is still a descendant of a `[data-column]`.
      assert count_elements(view, "[data-column] [data-task-id][draggable='true']") == draggable

      # (b) no card-group wrapper carries `data-task-id`. Pinned against the
      # count of wrappers, so "no wrapper has it" cannot pass by there being
      # no wrappers.
      assert count_elements(view, "[data-role='task-card-group']") == draggable
      assert count_elements(view, "[data-role='task-card-group'][data-task-id]") == 0
      assert count_elements(view, "[data-role='mobile-task-card-group'][data-task-id]") == 0

      # (c) `closest("[data-task-id]")` from the extension cannot reach a
      # card: the extension has NO `[data-task-id]` ancestor ANYWHERE in the
      # document, which is strictly stronger than "none below the column".
      # Pinned against the extension existing at all.
      assert count_elements(view, "[data-role='#{@desktop_role}']") == 1
      assert count_elements(view, "[data-role='#{@mobile_role}']") == 1
      assert count_elements(view, "[data-task-id] [data-role='#{@desktop_role}']") == 0
      assert count_elements(view, "[data-task-id] [data-role='#{@mobile_role}']") == 0

      # (d) POSITIVE CONTROL — the card itself DOES resolve, from inside the
      # same group the extension sits in. Without this, (c) passes against an
      # extension that is not on the board at all.
      assert count_elements(
               view,
               "[data-role='task-card-group'] [data-task-id][draggable='true']"
             ) == draggable

      assert count_elements(
               view,
               "[data-column] [data-role='task-card-group'] [data-role='#{@desktop_role}']"
             ) == 1

      # (e) And the source column `kanban_drag_drop.js` reads off the card is
      # the one the task's status buckets into — the wrapper did not move the
      # card out of its column.
      resolved =
        view
        |> query("[data-column='#{@dual_branch_status}'] [data-task-id][draggable='true']")
        |> LazyHTML.attribute("data-task-id")

      assert resolved == [dragged.id]
    end
  end
end

defmodule PlatformWeb.TasksLiveBoardQueryPurityTest do
  @moduledoc """
  GUARD 3 — the board stays one query (task `019f9b29-9c47`, ADR-0046 stack
  member 8, stage 4).

  The kanban board is the hottest query in the app. `PlanningStepExtension` is
  rendered once per card per column per branch, so a `Repo` call inside it is
  a per-card query on every board refresh — which is the mechanical reason the
  ADR-0046 bounded-reject-loop counter is NOT rendered there (the iteration
  count lives across `plans.version` rows).

  ## Why this is telemetry and not "there is no checked-out connection"

  `planning_step_extension_test.exs` already claims purity by being
  `use ExUnit.Case, async: true` with no `DataCase`, on the reasoning that a
  `Repo` call would raise `DBConnection.OwnershipError`. That reasoning is
  **not sound on its own**: `conn_case.ex:41` and `data_case.ex:27` put the
  sandbox into `{:shared, self()}` for every non-async case, and while any such
  test is running a `Repo` call from ANY process succeeds. So the claim holds
  or fails depending on what else the suite happens to be running, and an
  `assert_raise DBConnection.OwnershipError` here would be a flake generator.

  What this module does instead is measure directly: attach to Ecto's query
  telemetry, run the component, assert nothing fired. `:telemetry` handlers run
  in the process that emitted the event, so `self() == test_pid` inside the
  handler filters out every query the rest of the concurrently-running suite is
  issuing — this measures THIS process and nothing else.

  Both halves of the vacuity trap are closed in-test: the event name is pinned
  against `Platform.Repo.config()[:telemetry_prefix]` (a wrong name makes the
  refutation vacuous), and a synthetic emit proves the handler is attached and
  forwarding before the measurement is taken.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Platform.Design.PreplanStep
  alias Platform.Tasks.Task
  alias PlatformWeb.Components.PlanningStepExtension

  @query_event [:platform, :repo, :query]

  setup do
    test_pid = self()
    handler_id = "planning-step-purity-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      @query_event,
      fn event, measurements, metadata, _config ->
        # The handler runs in the EMITTING process. Everything from the rest of
        # the suite is discarded here, which is what makes this safe under
        # `async: true`.
        if self() == test_pid do
          send(test_pid, {:repo_query, event, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  # A spread of in-memory structs covering every branch of `entries/2`: a
  # failure, member 7's contradicted `not_applicable`, a success at a status
  # that renders it, an active cursor, and the all-defaults row.
  defp purity_matrix do
    [
      %Task{
        id: "019f9b29-9c47-7b66-b863-641b50d09eff",
        status: "done",
        planning_step: "planning",
        planning_step_outcomes: %{"architecture" => %{"outcome" => "failed"}}
      },
      %Task{
        id: "019f9b29-9c47-7b66-b863-641b50d09ef0",
        status: "in_review",
        planning_step: "planning",
        planning_step_outcomes: %{
          "design" => %{
            "outcome" => "not_applicable",
            "reason" => PreplanStep.reasons().contradicted
          }
        }
      },
      %Task{
        id: "019f9b29-9c47-7b66-b863-641b50d09ef1",
        status: "planning",
        planning_step: "designing",
        planning_step_outcomes: %{"design" => %{"outcome" => "complete"}}
      },
      %Task{
        id: "019f9b29-9c47-7b66-b863-641b50d09ef2",
        status: "backlog",
        planning_step: "planning",
        planning_step_outcomes: %{}
      }
    ]
  end

  defp render_extension(task, variant, role) do
    assigns = %{task: task, variant: variant, role: role}

    rendered_to_string(~H"""
    <PlanningStepExtension.planning_step_extension
      task={@task}
      variant={@variant}
      data_role={@role}
    />
    """)
  end

  describe "GUARD 3 — no new queries per card" do
    test "the telemetry event this guard listens on is the one Ecto actually emits" do
      # Without this, a wrong event name makes every `refute_received` below
      # pass no matter what the component does.
      assert Platform.Repo.config()[:telemetry_prefix] ++ [:query] == @query_event
    end

    test "entries/1, entries/2, visible?/1 and visible?/2 issue no repo query" do
      # POSITIVE CONTROL FIRST: the handler is attached, matches this event
      # name, and forwards to this process. If this fails, everything below is
      # meaningless rather than green.
      :telemetry.execute(@query_event, %{total_time: 0}, %{source: "synthetic-control"})
      assert_received {:repo_query, @query_event, _measurements, %{source: "synthetic-control"}}

      matrix = purity_matrix()

      # And the matrix is not vacuous: at least one of these structs produces
      # real work. "No query" is trivially true of a function that returns [].
      assert Enum.any?(matrix, &(PlanningStepExtension.entries(&1) != []))
      assert Enum.any?(matrix, &PlanningStepExtension.visible?/1)

      for task <- matrix do
        # DECLARED TRIVIAL as assertions — `is_list`/`is_boolean` hold for any
        # implementation. Their job is to EXECUTE all four arities under the
        # attached handler; the measurement is the `refute_received` below.
        # (MEASURED: the module exports entries/1, entries/2, visible?/1 and
        # visible?/2 — one `\\ :extension` default generates both heads, so the
        # plan's `entries/1` citation resolves and both arities are covered.)
        assert is_list(PlanningStepExtension.entries(task))
        assert is_list(PlanningStepExtension.entries(task, :compact))
        assert is_boolean(PlanningStepExtension.visible?(task))
        assert is_boolean(PlanningStepExtension.visible?(task, :compact))
      end

      refute_received {:repo_query, _event, _measurements, _metadata}
    end

    test "rendering the component issues no repo query either" do
      :telemetry.execute(@query_event, %{total_time: 0}, %{source: "synthetic-control"})
      assert_received {:repo_query, @query_event, _measurements, %{source: "synthetic-control"}}

      rendered =
        for task <- purity_matrix(), variant <- [:extension, :compact] do
          render_extension(task, variant, "planning-step-extension")
        end

      # Pinned non-empty: a template that rendered nothing everywhere would
      # satisfy the refutation below without proving anything about the
      # component that ships.
      assert Enum.any?(rendered, &(String.trim(&1) != ""))

      refute_received {:repo_query, _event, _measurements, _metadata}
    end
  end
end

defmodule PlatformWeb.TasksLiveShellNonAccretionTest do
  @moduledoc """
  GUARD 4 — the board shell does not grow (task `019f9b29-9c47`, ADR-0046 stack
  member 8, stage 4).

  A blunt instrument, deliberately. The task's whole framing is that
  `tasks_live.ex` must not grow, and a prose instruction to that effect has
  already failed here: `lib/platform_web/live/tasks/` has held only a
  `.gitkeep` since 2026-03-13, so the decomposition was scaffolded and never
  attempted. A test that pins the file's size is worth more than the component
  it guards.
  """

  use ExUnit.Case, async: true

  # `apps/platform` — this file lives at `test/platform_web/live/`.
  @app_root Path.expand("../../..", __DIR__)
  @shell_path Path.join(@app_root, "lib/platform_web/live/tasks_live.ex")
  @template_path Path.join(@app_root, "lib/platform_web/live/tasks_live.html.heex")

  # MEASURED on this branch, `wc -l` semantics (newline count), 2026-07-27.
  #
  # RE-PINNED 5,887 -> 5,847 at the rebase onto rollup `65f768e4`. The pin was
  # measured against this branch's ORIGINAL base `41bc5573`, where the file was
  # 5,887 lines. Sibling member 5 (`019f9b29-251e` stage 2, commit `05ae0d7e`,
  # "Hoist the plan-rejection feedback post into Platform.Tasks.PlanRejection")
  # moved `post_rejection_feedback_to_execution_space/3` and
  # `compose_rejection_message/3` OUT of the shell, so the file SHRANK by 40
  # lines. Measured: 41bc5573 = 5,887; 65f768e4 = 5,847; this branch = 5,847.
  #
  # The guard's promise is untouched by the re-pin. Task `019f9b29-9c47`
  # (ADR-0046 stack member 8) added ZERO lines to this file: the extension is a
  # component with three lines of call site in the TEMPLATE, and nothing at all
  # in the LiveView module — this branch's diff against `65f768e4` does not name
  # `tasks_live.ex` at all. The shell did not grow; a sibling shrank it.
  #
  # HOW TO CHANGE THIS NUMBER: update it in the SAME commit as the edit, with
  # the reason in the commit message. That makes growth a deliberate, reviewed
  # act rather than a silent one. Do NOT delete the guard to make a diff pass.
  #
  # KNOWN PENDING EDIT: `active_scope_keys/0` at `tasks_live.ex:5431` uses
  # `String.to_existing_atom` and is filed to Dalton as task `019fa209-12b0`.
  # Fixing it will move this number — that is expected, and the fix carries the
  # new pin.
  @shell_line_count 5_847

  defp line_count(source), do: source |> :binary.matches("\n") |> length()

  describe "GUARD 4 — shell non-accretion" do
    test "tasks_live.ex contains no planning_step reference and has not grown" do
      source = File.read!(@shell_path)

      # PIN NON-EMPTY. `File.read!/1` raises on a missing path, but a wrong
      # path that happens to exist, or a truncated read, would make the
      # refutation below vacuous.
      assert line_count(source) == @shell_line_count
      assert source =~ "defmodule PlatformWeb.TasksLive"

      # THE PROMISE: zero lines of this task landed in the shell.
      refute source =~ "planning_step"

      # PAIRED POSITIVE CONTROL — the same substring check, run against the
      # file that DOES carry the call sites. Without this, `refute source =~
      # "planning_step"` passes against a misspelt needle just as happily as
      # against a clean file.
      template = File.read!(@template_path)
      assert template =~ "planning_step_extension"
      assert template =~ "PlanningStepExtension.visible?"
    end
  end
end
