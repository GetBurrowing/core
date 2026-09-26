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
  # RE-PINNED 5,847 -> 5,883 at the merge of main `791ee28e` into the rollup.
  # The KNOWN PENDING EDIT recorded below has now landed: Dalton's `ef499c03`
  # ("Bound active_scope_keys/0 to the canonical scope allowlist", task
  # `019fa209`) added 36 lines to the shell on main. The pin moved exactly as
  # that note predicted it would.
  #
  # ARITHMETIC, so the number is checkable rather than merely asserted:
  #
  #     merge base `bbf4c0c2`  = 5,887
  #     main       `791ee28e`  = 5,923   (+36, ef499c03)
  #     rollup     `492017e7`  = 5,847   (-40, member 5's hoist — see above)
  #     merged                 = 5,883   = 5,887 - 40 + 36
  #
  # The two edits are in different regions of the file and the merge applied
  # both, which is what the identity above demonstrates: if either side's
  # change had been dropped the total would be 5,847 or 5,923, not 5,883.
  #
  # The guard's promise is STILL untouched, and the check is unchanged from
  # the previous re-pin: task `019f9b29-9c47` (ADR-0046 stack member 8) added
  # ZERO lines to `tasks_live.ex`. Member 8's six commits touch only
  # `tasks_live.html.heex`, `platform_web.ex`, and test files — verified with
  # `git show --stat` over each. Both line-count moves this file has seen came
  # from OUTSIDE this task: a sibling member shrank it, then main grew it.
  #
  # RE-PINNED 5,883 -> 5,889 by task `019fb581` stage 3 ("Gate the writes:
  # task_attach_canvas and task_detach_canvas"). THIS ONE IS THE SHELL ITSELF
  # GROWING, not a sibling or main moving underneath it — the first re-pin of
  # that kind, so it is recorded as such rather than folded into the identity
  # above.
  #
  #     merged base       = 5,883
  #     019fb581 stage 3  = 5,889   (+6)
  #
  # The +6 is entirely inside `handle_event("detail_detach_canvas", …)`.
  # `Platform.Tasks.CanvasAttachments.detach_canvas/2` became `/3` with the
  # actor as an explicit first argument and NO defaulting arity, so every
  # caller has to name its principal or fail to compile: one line binding
  # `{:user, current_user_id}`, plus five lines of comment recording what a
  # `:task_forbidden` does to the strip. An authorization change on a
  # `handle_event` is exactly the kind of edit this guard exists to put in
  # front of a reviewer, so it is re-pinned rather than worked around.
  #
  # The guard's promise is untouched: `refute source =~ "planning_step"` still
  # holds, and stage 3 touched no planning-step code.
  #
  # Strictness is deliberately still `==`. Softening to `<=` would let the
  # shell absorb the very accretion this guard exists to make visible; a
  # re-pin that has to be justified in a commit message is the whole point.
  # RE-PINNED (+1) by the viewer-scoped project sidebar stage. The two re-pins
  # below were authored against a 5,883 baseline; merging main moved the
  # baseline to 5,889 first, so the deltas — which are independent of it —
  # compose to 5,889 + 1 + 15 = 5,905. That total is not arithmetic on trust:
  # `grep -c '' apps/platform/lib/platform_web/live/tasks_live.ex` on the
  # merged tree reads 5,905.
  #
  # ARITHMETIC: three call sites changed from
  # `Tasks.list_projects_unscoped(preload: :org)` to
  # `Tasks.list_projects_for_user(socket.assigns[:current_user_record],
  # preload: :org)`. Two fit on one line; the third (inside
  # `handle_event("create_project", ...)`, already two levels of indentation
  # deep) exceeds 98 columns, so `mix format` wraps it onto a second line.
  # +1 line, and only that. No new function, no new branch, no new assign —
  # the shell did not accrete behaviour, an existing expression got longer.
  # RE-PINNED (+15) by the viewer-scoped org
  # SECTION HEADERS — the follow-up defect: scoping the project list alone
  # still rendered a header naming every foreign org at a `0` count).
  # ARITHMETIC, +15 = 26 insertions - 11 deletions:
  #   * `project_sections/1` -> `/2` (takes the viewer) and its body wraps to
  #     three lines under `mix format`: +2.
  #   * the two `assign(:project_sections, ...)` call sites in `mount/3` and
  #     `handle_event("create_project", ...)` exceed 98 columns once the
  #     viewer argument is added, so `mix format` breaks each into a 4-line
  #     `assign(` call: +3 each = +6. The `refresh_containers/1` site still
  #     fits on one line: +0.
  #   * +7 comment lines: a four-line note on `project_sections/2` recording
  #     WHY the org read is scoped (an empty foreign-org header is an
  #     existence leak in its own right), plus reflow of two existing
  #     comments to say "every active org THE VIEWER BELONGS TO".
  # No new function in the shell, no new branch, no new assign — the scoping
  # logic itself lives in `Platform.Tenancy.list_active_tenants_for_user/1`,
  # which is exactly where the guard wants it. The shell only passes a viewer.
  #
  # RE-PINNED (+18) by the viewer-scoped SCOPE RAIL — the third and last
  # unscoped read in this shell. `active_scope_keys/0` built the filter chips
  # from `Tenancy.list_active_tenants_unscoped/0`, so a plain member of one org saw a
  # chip naming every other tenant in the deployment.
  # ARITHMETIC, +18 = 30 insertions - 12 deletions:
  #   * `active_scope_keys/0` -> `/1` (takes the viewer) and its two call
  #     sites in `mount/3` and `refresh_containers/1` gain
  #     `socket.assigns[:current_user_record]`. All three still fit on one
  #     line under `mix format`: +0.
  #   * +18 comment lines, all on the function's existing comment block: a
  #     note naming the viewer-scoped read and why the arity change is
  #     load-bearing (no `/0` shim, no call-site `Enum.filter`), plus an
  #     explicit restatement that the allowlist-first, compare-as-STRINGS
  #     construction is UNCHANGED and must stay — reverting it to
  #     `String.to_existing_atom/1` re-opens the task-019fa209 /tasks outage.
  #     Reflow of two existing comments to name the viewer accounts for the
  #     rest.
  # Still no new function, no new branch, no new assign in the shell: the
  # scoping lives in `Platform.Tenancy.list_active_tenants_for_user/1`.
  #
  # RE-PINNED (+18) by task 019fed1e, the admin-only Tasks settings cog. This
  # is the one shape of growth the guard is not trying to prevent: a header
  # affordance and its open/closed flag, in the same place and the same shape
  # as the create menu beside it.
  # ARITHMETIC, +18 = 19 insertions - 1 deletion:
  #   * `|> assign(:settings_menu_open, false)` in `mount/3`, plus a 4-line
  #     comment saying what it drives and where the gate actually is: +5.
  #   * `handle_event("toggle_settings_menu", ...)` — 6 lines including a
  #     3-line comment — and `toggle_create_menu/2` growing from a one-line
  #     `assign` to a 4-line pipe so the two menus cannot be open at once
  #     (4 insertions - 1 deletion): +13.
  # No new derived state: `@fabrikam_admin?` comes from the `LiveAuth :default`
  # on_mount that was already assigning it, and the destination's access
  # control is `live_session :admin`, not this flag.
  #
  # RE-PINNED (+7) by the freeze-changeset hotfix. `handle_event("plan_approve")`
  # matched `{:error, _}` and flashed a constant string, DISCARDING the reason.
  # A production outage that blocked every plan approval therefore produced a
  # generic toast, no server log line and a clean browser console — the cause
  # was sitting in a variable nobody read. The whole growth is observability
  # for a failure branch that already existed.
  # ARITHMETIC, +7 = 7 insertions, 0 deletions:
  #   * `{:error, _}` -> `{:error, reason}`: +0 (edit in place).
  #   * `Logger.error(...)` naming plan id, task id and `inspect(reason)`,
  #     wrapped by `mix format` to 3 lines: +3.
  #   * a 3-line comment saying why the log exists, so the next person to
  #     read this branch does not delete it as noise: +3.
  #   * one blank line separating the log from the `{:noreply, ...}`: +1.
  # No new function, no new branch, no new assign, no new derived state: the
  # `{:error, ...}` clause was already there and still returns the same flash.
  #
  # RE-PINNED (+39) by task 019ff182, the Merge / Open PR cluster on the task
  # detail panel. The markup and its tone->class mapping are NOT here: they
  # live in `PlatformWeb.Components.TaskMergeControls`, and the eligibility
  # rules (`pr_merge`, `auto_merge: false`, not a stack member, a live
  # `pr_merged` gate) live in `Platform.Tasks.MergeControl`. What is left is
  # the part that cannot live anywhere else — one assign and one event.
  # ARITHMETIC, +39 = 39 insertions, 0 deletions:
  #   * `alias Platform.Tasks.MergeControl`: +1.
  #   * `|> assign(:merge_control, nil)` in `mount/3`: +1.
  #   * the same assign on both `assign_selected_task/2` clauses — `nil` on
  #     deselect, `MergeControl.for_task(task)` on select: +2.
  #   * `handle_event("merge_task_branch", …)`: +35, of which 13 are the
  #     clause itself (delegate to `MergeControl.merge/3`, flash + reload on
  #     success, re-assign the control with the returned band on failure) and
  #     22 are a comment block recording the three refusals that are easy to
  #     re-introduce: it calls `AutoMerger.execute_merge/4` rather than
  #     writing a second merge, it does NOT pass the `pr_merged` validation
  #     from the click (that gate auto-passes on the `pull_request.closed`
  #     webhook, and passing it here would pass it on a merge that might not
  #     have landed), and every failure — including a missing `gh` — lands in
  #     the state band rather than a flash, a crash or a vanishing button.
  # One new assign and one new branch, both irreducible: an event handler
  # cannot live in a function component, and the panel cannot read derived
  # state it was never assigned.
  #
  # RE-PINNED (+21) by task 019fed8d stage 3, the superseded review-request
  # disclosure. Stage 3 first landed +47 here; this pin is what survived the
  # extraction the guard asked for. The markup and both label helpers —
  # `earlier_submissions_label/1` (pluralises a count) and
  # `superseded_timestamps/1` (formats `inserted_at` and the nullable
  # `superseded_at`) — are pure presentation with no socket dependency, so
  # they moved to `PlatformWeb.Components.SupersededReviewSubmissions`,
  # following the `TaskMergeControls` precedent directly above. Rendered
  # output is unchanged: the component emits the same
  # `[data-role="superseded-reviews"]` subtree the human review approved.
  # ARITHMETIC, +21 = 47 stage-3 insertions - 26 extracted:
  #   * `|> assign(:superseded_reviews, ...)` at all SEVEN call sites — the
  #     `mount/3` default, the loaded and both empty branches of the mount
  #     case, the task-deselect reset, and both arms of the refresh: +7.
  #   * `|> assign(:superseded_reviews_expanded, false)` plus a 3-line
  #     comment saying why the disclosure is collapsed by default: +4.
  #   * `superseded_reviews = ReviewRequests.list_superseded_for_task(...)`
  #     in `mount/3`: +1, and the same read in the refresh path as a
  #     two-line `if` with its surrounding blank lines: +4.
  #   * `handle_event("toggle_superseded_reviews", ...)` — 4 lines plus a
  #     separating blank: +5.
  #   * REMOVED: the two label helpers and their 7 lines of comment: -26.
  # One new assign pair and one new event, all three irreducible for the
  # same reason as the merge cluster above: a function component holds no
  # LiveView state and receives no events.
  #
  # RE-PINNED (+20) by task 01a00578, the "Needs review" pill fix — the
  # ticket's ONLY behavioural change. The pill rendered on every `in_review`
  # task because `Tasks.needs_human_action_reason/2`'s `:validation_failed`
  # branch is status-driven, so the pill reported status instead of "your
  # turn". The fix is one new `mobile_stack_member_action_label/1` clause
  # suppressing that branch on the mobile card. It belongs in the shell
  # because this is the shell's own label helper, called from
  # `tasks_live.html.heex`, and the clause IS the fix — a component cannot
  # hold it.
  # ARITHMETIC, +20 = 20 insertions - 0 deletions:
  #   * the new `defp mobile_stack_member_action_label(:validation_failed)`
  #     clause: +1.
  #   * an 18-line comment recording the rejection, the verbatim requirement,
  #     and why the suppression lives at the mobile call site rather than in
  #     `needs_human_action_reason/2` (which other consumers still read): +18.
  #   * one blank line separating the new clause from the catch-all that
  #     `mix format` requires around a commented clause: +1.
  #
  # An earlier pass on this branch also made `status_dot_class/1` an arity-2
  # form and dimmed the `in_review` column header; both were reverted on the
  # sponsor's instruction ("We don't need to dim anything or anything else"),
  # so they contribute 0 here and the pin is 6_008 + 20 = 6_028, not 6_038
  # on this branch's own base.
  #
  # RE-PINNED (-1) by task 01a00122-553c stage 5, "render the agent face
  # everywhere an agent appears". This is the first re-pin that SHRINKS the
  # shell, because the change deleted a helper rather than adding a feature:
  # the board's agent assignee chip was a hand-rolled circle that could never
  # show an image, and both of its call sites now render the shared
  # `AvatarComponents.agent_avatar/1`. ARITHMETIC, -1 = +6 - 7:
  #   * `assignee_identity/3`'s agent clause gains `avatar_url: agent &&
  #     agent.avatar_url` (+1) and a 5-line comment recording that
  #     `agents_by_id` held whole `%Agent{}` rows all along and the avatar was
  #     simply never read, and that `:seed` survives only for shape parity
  #     with the user clause: +6.
  #   * REMOVED: `agent_initials/1`, both clauses and the blank between them
  #     (-11), replaced by a 4-line comment saying where the initial is
  #     derived now: -7.
  # No new assign, no new branch, no new event — the shell lost a private
  # helper and gained one field on a map it already built.
  #
  # MERGE RESOLUTION: both re-pins above are live in this tree, so the pin was
  # the sum of both deltas against the shared 6_008 base: 6_008 - 1 + 20 =
  # 6_027.
  #
  # RE-PIN 2026-08-16 (task 01a008f6 stage 2): 6_027 -> 5_847. The Sidebar /
  # Projects / Epics concern (15 events + its mount assigns + three form
  # helpers) moved to PlatformWeb.TasksLive.SidebarComponent. This guard only
  # ever ratchets DOWN; a later stage lowering it further is the point, and
  # scripts/surface-budgets.txt carries the same number for CI.
  #
  # RE-PIN 2026-08-16 (task 01a008f6 stage 3): 5_847 -> 4_557. The Stacks
  # concern (18 events + its mount assigns + the panel/overlay/modal helpers)
  # moved to PlatformWeb.Tasks.StacksComponent, and the pure graph math
  # (~450 lines) went further out to Platform.Tasks.StackGraph.
  #
  # RE-PIN 2026-08-16 (task 01a008f6 stage 4): 4_560 -> 3_158. Task detail,
  # inline edit and plan approval (21 + 7 events, their mount assigns, the
  # plan_body function component and the deploy-target / dependency /
  # transition helpers) moved to PlatformWeb.Tasks.TaskDetailComponent, and
  # the display helpers shared with the board went to
  # PlatformWeb.Tasks.TaskDisplay.
  #
  # RE-PIN 2026-08-16 (task 01a008f6 stage 5): 3_158 -> 2_705. Execution &
  # steering (with its own allow_upload plumbing and the newly-implemented
  # @-mention pair), the per-phase assignee modal and the merge-control
  # cluster moved to PlatformWeb.Tasks.{Steering,Assignees,MergeControl}Component.
  #
  # RE-PIN 2026-08-16 (task 01a008f6 stage 6): 2_705 -> 2_112. The four
  # remaining self-contained panels moved out together, which is the point of
  # the sweep — a half-emptied shell is the next attractor:
  #   * Reviews & Validation (7 events, 4 assigns, the pending-review panel
  #     and the review-canvas modal) -> PlatformWeb.Tasks.GatePanelComponent.
  #   * Return-to-planning (4 events, 2 assigns) ->
  #     PlatformWeb.Tasks.SupersedeComponent. Its twin, the reopen modal, was
  #     already in TaskDetailComponent from stage 4, so this is the supersede
  #     mode alone rather than the plan's two-mode component.
  #   * New-Task creation (9 events, 12 assigns, the FAB, the bottom-sheet
  #     form AND its allow_upload) -> PlatformWeb.Tasks.TaskCreateComponent.
  #   * Board filtering (5 events, 3 assigns) ->
  #     PlatformWeb.Tasks.FiltersComponent. `:sponsor_filter` stays here
  #     because handle_params/3 is its writer and that callback cannot live
  #     in a component.
  #
  # RE-PIN 2026-08-17 (task 01a008f6 stage 7, the final extraction): 2_112 ->
  # 641. The board itself left last:
  #   * Epics strip + mobile section list + desktop kanban + the per-row
  #     action sheet (4 events) -> PlatformWeb.Tasks.BoardComponent. Filed as
  #     a component, not the hook the inventory named, because "it is the page
  #     body" is a rendering-POSITION fact and ADR 0035's criterion is
  #     contiguity.
  #   * The ten board PubSub clauses and refresh_board/1 ->
  #     PlatformWeb.Tasks.BoardHooks (PubSub delivers to the process, so this
  #     half genuinely cannot be a component).
  #   * Container lifecycle (10 events, 3 assigns) ->
  #     PlatformWeb.Tasks.LifecycleHooks.
  #   * Pin-to-Chat (4 handle_info, 2 assigns) -> PlatformWeb.Tasks.PinHooks.
  #   * Pure bucketing/search -> PlatformWeb.Tasks.BoardData; selected-task
  #     assign plumbing -> PlatformWeb.Tasks.Selection.
  #
  # ── The blocked-explanation feature (task 01a004ad), for the record ────
  #
  # 2026-08-15, task 01a004ad stage 2 — the blocked-explanation READ side.
  # ARITHMETIC: 6_007 + 59 = 6_066. All 59 lines are one new
  # `# ── Blocked-explanation helpers ──` region appended after
  # `dependency_status_icon/1`: `blocked_reason/1`, `blocked_reason_at/1`
  # and the `blocked_explanation/1` dispatcher, each with its fallback
  # clause and the comment recording why (precedence: a stamped escalation
  # sentence outranks unmet dependencies, and any non-`blocked` status
  # explains nothing).
  #
  # STAGE 3 DID NOT MOVE THAT PIN: its block lived entirely in
  # `tasks_live.html.heex`. `main` then re-measured to 6_086 in its own
  # merge resolution.
  #
  # MERGE RESOLUTION, 2026-08-17 (merging `main` into task 01a008f6's branch).
  # The two sides pinned 640 (this branch, after the stage-7 extraction) and
  # 6_086 (`main`, itself a re-measured merge resolution). As in that earlier
  # resolution, the conflict IS the proof the two sides did not share a base,
  # so the deltas must not be summed: `main`'s 6_086 counts a shell that still
  # contains every concern this branch extracted.
  #
  # The pin is therefore RE-MEASURED against the merged tree: `wc -l` on
  # `tasks_live.ex` reports 653.
  #
  # WHY IT ROSE 640 -> 653 (+13). This is NOT extraction regrowth. Task
  # 01a004ad landed on `main` after this branch was cut, so its feature had to
  # be PORTED into the extracted structure rather than merged in place. Its 59
  # shell lines and its 85 template lines both went to
  # `Tasks.TaskDetailComponent`, which is where `dependency_summary/1` and the
  # detail panel now live — the feature reads a task's metadata and paints the
  # detail panel, so under ADR 0035's contiguity criterion it belongs beside
  # them, not in the shell.
  #
  # The +13 that DID land here is the public `defdelegate` surface alone:
  # `blocked_reason/1`, `blocked_reason_at/1`, `blocked_explanation/1` plus the
  # comment recording why the implementation moved. They exist so the
  # pre-extraction call site keeps working —
  # `tasks_live_blocked_explanation_test.exs` calls all three as public
  # functions on `TasksLive` and passes unmodified.
  #
  # So the ratchet's promise still holds: no concern re-entered the shell, and
  # every line of the +13 is a forwarding stub for a feature that did not exist
  # on this branch when the 640 pin was set.
  #
  # MOVED 653 -> 657 (+4), 2026-08-17, task 01a00cf1 stage 2 (rail masking).
  # ARITHMETIC: 653 + 4 = 657. The four lines are ONE hook attachment and its
  # three-line comment:
  #
  #     |> PlatformWeb.Tasks.MaskHooks.attach()
  #
  # NO CONCERN RE-ENTERED THE SHELL — that is what this pin protects and it
  # still holds. The stage text asked for the two mount assigns and the three
  # `toggle_mask_names` / `reveal_rail_item` / `remask_all` handlers to be
  # written HERE, and they were, at which point this guard failed at 718. They
  # were then moved to `PlatformWeb.Tasks.MaskHooks` rather than the pin being
  # moved to 718, because masking is a CONCERN by ADR-0035's criterion (two
  # assigns, three events, one derived map, reachable from each other and from
  # nothing else) and accommodating the first feature that wants shell space is
  # precisely how `chat_live.ex` went 684 -> 4,335.
  #
  # State OWNERSHIP is unchanged by that move: an attached `:handle_event` hook
  # writes the shell's own socket, so `:mask_names?`, `:revealed_rail_ids` and
  # `:mask_labels` are still shell assigns passed to `SidebarComponent` as
  # read-only attrs. Only the source file differs.
  #
  # The +4 is irreducible: `LifecycleHooks.attach/1` and `BoardHooks.attach/1`
  # cost the shell the same one line each. A hook has to be attached from the
  # LiveView that owns the socket.
  # MOVED 657 -> 664 (+7), 2026-08-18, task 01a00cf1 review remediation.
  # ARITHMETIC: 657 + 7 = 664. ONE line of code and its six-line comment:
  #
  #     |> PlatformWeb.Tasks.MaskHooks.assign_mask_labels()
  #
  # appended to `reload_epics/1`. `:epics` became a MASKED ENTITY SET when the
  # breadcrumb's epic name started reading `@mask_labels`, and `reload_epics/1`
  # is the only writer of `:epics` — the same reason
  # `LifecycleHooks.refresh_containers/1` already calls it for
  # `:project_sections`. Recomputing where the source assign is written is what
  # keeps the two from disagreeing; the alternative is a second writer.
  #
  # NO CONCERN RE-ENTERED THE SHELL. The masking concern is still wholly in
  # `MaskHooks`; this is one call into it from the writer of an assign it reads,
  # which is the same shape as the existing `refresh_containers/1` call site.
  #
  # RATCHETED DOWN 664 -> 635 (-29), 2026-08-18, task 01a00cf1 CI remediation.
  # ARITHMETIC: 664 - 29 = 635. The `Check surface line budgets` CI step
  # failed this branch (shell 664 > 653, template 407 > 398, combined 1071 >
  # 1051). The budget was NOT raised; two concerns left the shell instead:
  #
  #   * `reload_epics/1` + `enrich_epics/1` -> `PlatformWeb.Tasks.EpicLoaders`
  #     (-29 here; `reload_epics/1` is now imported, `enrich_epics/1` became
  #     `EpicLoaders.load_epics/1` and the mount call site follows it).
  #   * the admin settings dropdown + its phone sheet ->
  #     `PlatformWeb.Tasks.SettingsMenu` (-83 in the TEMPLATE, not here).
  #
  # `SettingsMenu` is a pair of FUNCTION components, not a LiveComponent, so
  # `toggle_settings_menu` and `:settings_menu_open` stay on the shell and no
  # `phx-target` was introduced — a JS-hook `pushEvent` would have ignored one.
  # REBASED 635 -> 649 (+14), 2026-08-19, task 01a011e9 stage 4 rebased onto
  # `86ea77b0`. ARITHMETIC: 635 + 14 = 649.
  #
  # THE PIN WAS RE-DERIVED, NOT TAKEN FROM EITHER SIDE OF THE MERGE. This line
  # conflicted because both sides moved it from a shared 653: `main` ratcheted
  # DOWN to 635 by extracting `EpicLoaders` and `SettingsMenu`, while this
  # branch rose to 667 by adding stage 4's two call sites. Neither number is
  # true of the merged tree — 667 counts a shell that still contains the two
  # concerns `main` extracted, and 635 counts one without stage 4 — so the
  # deltas must not be summed and neither side's literal may be kept. The
  # value below is measured on the MERGED tree: `tasks_live.ex` reports 649.
  #
  # The +14 over `main` is stage 4's own delta, unchanged by the rebase: two
  # piped calls into `select_project/2` (`clear_detail/1` and
  # `resubscribe_execution_space/2`, both ALREADY in the shell) plus the
  # 12-line comment that explains why the unsubscribe is safe here. No concern
  # re-entered the shell: nothing moved back from a component, no new private
  # function was added, and the two callees are the shell's own
  # subscription/selection state. The comment is not padding —
  # `Phoenix.PubSub.unsubscribe/2` drops every registration a pid holds for a
  # topic, so an unsubscribe site that does not argue its ownership is the
  # defect this task exists to stop repeating.
  #
  # The stage-4 delta and `main`'s extractions are disjoint: stage 4 touches
  # `select_project/2` only, and neither `reload_epics/1` nor the settings
  # dropdown is on that path. That independence is why the two deltas compose
  # to exactly 649 and the CI `Check surface line budgets` step (shell budget
  # 653) still passes at 649.
  #
  # RAISED 649 -> 652 (+3), 2026-09-23, task 01a0cef1 stage 2 (`?sort=`).
  # ARITHMETIC: 649 + 1 + 1 + 1 = 652, and every line is in
  # `handle_params/3`:
  #   +1 `new_sort = BoardData.decode_sort(params["sort"])`
  #   +1 the blank line `mix format` puts before a multi-line assignment
  #   +1 `changed?` now compares a {sponsor, sort} pair and wraps to two lines
  # The sponsor/sort comment above it was rewritten in place (5 lines -> 5),
  # and `{:detail_closed}` swapped `~p"/tasks"` for
  # `BoardData.tasks_path(socket.assigns)` on the same line (+0). The path
  # logic itself lives in `BoardData.tasks_path/2`, not here. 652 is inside
  # the 653 budget in `scripts/surface-budgets.txt`, so the budget is not
  # raised.
  #
  # RAISED 652 -> 653 (+1), 2026-09-26, task 01a0db5f stage 4. ARITHMETIC:
  # 652 + 1 = 653, the single piped `|> PlatformWeb.GameStreamHooks.attach()`
  # in `mount/3`. The task sheet renders canvases (gate panel, stacks,
  # steering), and a `game_stream` node's JS hook pushes `game_stream_*`
  # events to whichever LiveView holds it; without the attach, TasksLive has
  # no clause for them and the process crashes. Every event, message and
  # assign lives in `PlatformWeb.GameStreamHooks`, and the explanation lives
  # here rather than as a comment in the shell. 653 is exactly the budget in
  # `scripts/surface-budgets.txt`, which is not raised.
  @shell_line_count 653

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
      #
      # The call sites left the shell TEMPLATE too in stage 7, when the board
      # markup moved into BoardComponent — so the control follows them there,
      # and the shell template gets its own refutation.
      template = File.read!(@template_path)
      refute template =~ "planning_step"

      board = File.read!("lib/platform_web/live/tasks/board_component.ex")
      assert board =~ "planning_step_extension"
      assert board =~ "PlanningStepExtension.visible?"
    end
  end
end
