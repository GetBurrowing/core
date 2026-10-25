defmodule PlatformWeb.Tasks.BoardDefaultListingGuardTest do
  @moduledoc """
  Task 01a06df3 stage 4 — the DEFAULT board listing is deliberately unchanged.

  The ticket ("a task added to a stack disappears from the board") offered
  three remedies. The planner ruled for remedy 3 — *search* ignores status,
  which is what stages 1–3 built — and ruled the other two OUT OF SCOPE:
  changing the default board status filter, adding `stack_pending` to the
  default listing, and adding a `stack_pending` board column. Those are a
  genuine product call nobody has made. This module is that ruling in
  executable form, so a future change to the default listing trips over it
  instead of sliding in as an obvious-looking fix.

  ## The deliberate asymmetry — read this before "fixing" either side

  Two assertions on this branch look like direct contradictions, and neither
  is wrong:

    * HERE: with the search box EMPTY, a `stack_pending` task is absent from
      `Platform.Tasks.list_by_status/1`, absent from
      `PlatformWeb.Tasks.BoardData.kanban_columns/0`, and renders as no loose
      card in any column.
    * `PlatformWeb.TasksLiveSearchTest` (stages 1–2): with a query ACTIVE,
      that same `stack_pending` task IS findable and IS visible without a
      further click.

  Both must be green at once. "Findable when searched for" and "not in the
  default listing" are the two halves of the ruling, not a conflict — the
  ticket's actual harm was that two people searched for a real ticket and
  concluded it did not exist, and the remedy was scoped to search on purpose.
  Deleting either assertion silently re-opens a product decision. If you
  genuinely need `stack_pending` on the default board, that is a product call
  to make explicitly, and this module is where you record it.

  ## Every assertion here is positive about what it observed

  "The `stack_pending` task is in none of the seven buckets" is also true of
  an empty result, a broken query, and a fixture that never inserted the
  task. So each test carries a `backlog` control that MUST surface through the
  same code path, the seeded status is re-read from the DB before it is relied
  on (`Tasks.create_task/2` is not obliged to honour the status asked for),
  and the column assertion is full-list equality rather than a ban-list — a
  ban-list cannot tell "fixed" from "columns deleted", since both give zero
  hits.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Tasks.{Stacks, Task}
  alias Platform.{Repo, Tasks}
  alias PlatformWeb.Tasks.BoardData

  # Duplicated from `BoardData`'s @kanban_columns ON PURPOSE. A test that
  # read the constant it is guarding would pass for any value of it.
  @expected_columns [
    {"backlog", "Backlog"},
    {"planning", "Planning"},
    {"in_progress", "In Progress"},
    {"blocked", "Blocked"},
    {"in_review", "In Review"},
    {"deploying", "Deploying"},
    {"done", "Done"}
  ]

  @expected_bucket_keys [
    :backlog,
    :planning,
    :in_progress,
    :blocked,
    :in_review,
    :deploying,
    :done
  ]

  describe "default board listing excludes stack_pending (planner ruling, task 01a06df3)" do
    test "Platform.Tasks.list_by_status/1 surfaces the backlog control and no stack_pending task" do
      project = create_project()

      control = create_task(project, %{title: "Guard backlog control", status: "backlog"})
      parked = create_task(project, %{title: "Guard parked member", status: "stack_pending"})

      # FIXTURE CHECK, load-bearing. If the seed did not actually park the
      # task at `stack_pending` then its absence below says nothing about
      # the status exclusion.
      assert Repo.get!(Task, parked.id).status == "stack_pending"
      assert Repo.get!(Task, control.id).status == "backlog"

      buckets = Tasks.list_by_status(project_id: project.id)

      # The shape is the seven kanban buckets and nothing else — no eighth
      # `:stack_pending` bucket has been added alongside them.
      assert Enum.sort(Map.keys(buckets)) == Enum.sort(@expected_bucket_keys)
      assert Enum.sort(Map.keys(buckets)) == Enum.sort(Tasks.kanban_status_keys())

      # POSITIVE CONTROL: the same call, the same project, the same fixture
      # DOES surface a `backlog` task. This is the half that makes the
      # absence below meaningful rather than vacuous.
      assert Enum.map(buckets.backlog, & &1.id) == [control.id]

      # And positively: across all seven buckets the listing contains
      # EXACTLY the control. Stated as an equality rather than a `refute`,
      # so an empty or broken listing fails here too.
      listed_ids =
        buckets
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1.id)

      assert listed_ids == [control.id]
      refute parked.id in listed_ids
    end

    test "BoardData.kanban_columns/0 is exactly the seven product columns, in order" do
      # Full-list equality, not `refute {"stack_pending", _} in columns`. A
      # ban-list is satisfied by deleting columns; this is not.
      assert BoardData.kanban_columns() == @expected_columns

      keys = Enum.map(BoardData.kanban_columns(), &elem(&1, 0))
      assert keys == ~w(backlog planning in_progress blocked in_review deploying done)
      assert length(BoardData.kanban_columns()) == 7
    end

    test "on /tasks with no query, a stack_pending task is no loose card in any column",
         %{conn: conn} do
      project = create_project()

      control = create_task(project, %{title: "Guard backlog control", status: "backlog"})

      # Two shapes of parked task, because they are suppressed by DIFFERENT
      # mechanisms and a fix to one would not move the other:
      #
      #   * `orphan` carries NO `stack_id`, so only its STATUS keeps it off
      #     the board. This is the discriminating fixture — adding
      #     `stack_pending` to the column-status maps would surface it, and
      #     `stack_abandon`/`stack_eject` really do strand members here.
      #   * `member` is the ticket's own shape: parked AND inside a stack, so
      #     `group_board_items/2`'s `stack_id != nil` suppression also
      #     applies. It renders only inside its (collapsed) stack card.
      orphan =
        create_task(project, %{title: "Guard orphan parked ticket", status: "stack_pending"})

      stack = create_stack(project)

      member =
        create_task(project, %{
          title: "Guard stacked parked ticket",
          status: "stack_pending",
          stack_id: stack.id,
          stack_position: 1
        })

      # A lone `stack_pending` member rolls the stack up to a status that IS
      # a real column, so the stack card has somewhere to land. Without this
      # the card would be missing for an unrelated reason.
      {:ok, _stack} = Stacks.recompute_stack_status(stack)

      assert Repo.get!(Task, orphan.id).status == "stack_pending"
      assert Repo.get!(Task, member.id).status == "stack_pending"
      assert Repo.get!(Task, control.id).status == "backlog"

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks")

      # No query is active — assert that rather than assume it.
      refute has_element?(view, ~s([data-role="search-empty-state"]))

      # POSITIVE CONTROL 1: the board rendered and the control task IS a
      # loose card, in the Backlog column specifically. A page that rendered
      # nothing cannot reach the refutes below.
      assert has_element?(view, ~s([data-column="backlog"] [data-task-id="#{control.id}"]))
      assert html =~ "Guard backlog control"

      # POSITIVE CONTROL 2: the stack path rendered too, so `member`'s
      # absence as a loose card is attributable to the suppression and not
      # to the stacks section being empty.
      assert has_element?(view, ~s([data-stack-card="true"][data-stack-id="#{stack.id}"]))

      # The rendered desktop columns are EXACTLY the seven, in order — this
      # is the render-level twin of the `kanban_columns/0` assertion, and it
      # is what catches an eighth column being added to the template.
      rendered_columns =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#kanban-board [data-column]")
        |> LazyHTML.attribute("data-column")

      assert rendered_columns == ~w(backlog planning in_progress blocked in_review deploying done)

      # Neither parked task is a loose card in ANY column.
      for col_key <- Enum.map(@expected_columns, &elem(&1, 0)) do
        refute has_element?(view, ~s([data-column="#{col_key}"] [data-task-id="#{orphan.id}"])),
               "orphan stack_pending task rendered as a loose card in column #{col_key}"

        refute has_element?(view, ~s([data-column="#{col_key}"] [data-task-id="#{member.id}"])),
               "stacked stack_pending member rendered as a loose card in column #{col_key}"
      end

      # Page-wide. Mobile and desktop share ONE document (`lg:hidden` /
      # `hidden lg:flex` — CSS visibility, not presence), so this also covers
      # every mobile section, which all render with no `?status=` set.
      refute has_element?(view, ~s([data-task-id="#{orphan.id}"]))
      refute has_element?(view, ~s([data-task-id="#{member.id}"]))
      # The board region only (task 01a161fd stage 3): the phone list beside
      # it shows every status by default, so a parked task is a 'Waiting' row
      # there, which is not a board card.
      refute view |> element("#tasks-main") |> render() =~ "Guard orphan parked ticket"
    end

    test "in the mobile Backlog section with no query, a stack_pending task is no card there",
         %{conn: conn} do
      project = create_project()

      control = create_task(project, %{title: "Guard backlog control", status: "backlog"})

      orphan =
        create_task(project, %{title: "Guard orphan parked ticket", status: "stack_pending"})

      assert Repo.get!(Task, control.id).status == "backlog"
      assert Repo.get!(Task, orphan.id).status == "stack_pending"

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # With no `?status=` every mobile section renders, Backlog included,
      # so a leak into `@mobile_column_statuses["backlog"]` would surface here.
      _ = :sys.get_state(view.pid)
      html = render(view)

      refute has_element?(view, ~s([data-role="search-empty-state"]))

      # POSITIVE CONTROL: the mobile Backlog section rendered and the
      # `backlog` task IS a card in it.
      assert has_element?(
               view,
               ~s([data-role="mobile-task-card-group"] [data-task-id="#{control.id}"])
             )

      assert html =~ "Guard backlog control"

      # The parked task is not a card in the mobile Backlog section, nor
      # anywhere else in the document.
      refute has_element?(
               view,
               ~s([data-role="mobile-task-card-group"] [data-task-id="#{orphan.id}"])
             )

      refute has_element?(view, ~s([data-task-id="#{orphan.id}"]))
      # The board region only (task 01a161fd stage 3), as above.
      refute view |> element("#tasks-main") |> render() =~ "Guard orphan parked ticket"
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "board_guard_#{System.unique_integer([:positive])}@example.com",
        name: "Board Guard User",
        oidc_sub: "oidc-board-guard-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Guard Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    project
  end

  defp create_task(project, attrs) do
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

  defp create_stack(project) do
    slug = "guard-stack-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Guard Stack #{System.unique_integer([:positive])}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end
end
