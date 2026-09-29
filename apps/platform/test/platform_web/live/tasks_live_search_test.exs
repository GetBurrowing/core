defmodule PlatformWeb.TasksLiveSearchTest do
  @moduledoc """
  Re-skin Phase 2 stage 2 (task 019f51ca): the page-header search input
  narrows the board in-memory via the `search_tasks` event across task
  id, title, sponsor name, assignee display and epic name. Escape (or an
  empty query) restores the unfiltered board.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Tasks.{Stacks, Task}
  alias Platform.{Repo, Tasks}

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "tasks_search_#{System.unique_integer([:positive])}@example.com",
        name: "Search Test User",
        oidc_sub: "oidc-tasks-search-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Search Project #{System.unique_integer([:positive])}",
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
    slug = "search-stack-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Search Stack #{System.unique_integer([:positive])}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  # Task 01a06df3 stage 2. Two people independently searched the board for a
  # real ticket, found nothing, and concluded it did not exist. The ticket was
  # a stack member: `group_board_items/2` suppresses any task with a
  # `stack_id` from the flat column list, and a `stack_pending` member's
  # status is in NEITHER `@desktop_column_statuses` NOR
  # `@mobile_column_statuses`, so the parent stack card is the only place it
  # can render at all. Stage 1 taught the matcher to see member titles; this
  # stage makes the found member actually visible, because
  # `refresh_board/1` empties `:expanded_stacks` right before re-applying the
  # search and `BoardComponent` gates the member rows on that MapSet.
  describe "board search reaches a task parked inside a stack" do
    test "a stack_pending member matched by title renders in its auto-expanded stack card",
         %{conn: conn} do
      project = create_project()

      # One shared term, and nothing else on the board carries it.
      solo = create_task(project, %{title: "Periscope standalone ticket"})

      stack = create_stack(project)

      member =
        create_task(project, %{
          title: "Periscope stacked ticket",
          status: "stack_pending",
          stack_id: stack.id,
          stack_position: 1
        })

      # NEGATIVE CONTROL. A build that ignores the query and lists everything
      # passes both assertions above and fails this one.
      control = create_task(project, %{title: "Unrelated widget ticket"})

      # A lone `stack_pending` member rolls the stack up to `in_progress`
      # (`rollup_status_for/1`), which is a real desktop AND mobile column —
      # so the card has somewhere to land.
      {:ok, _stack} = Stacks.recompute_stack_status(stack)

      # Load-bearing: `create_task/2` is not obliged to honour the status we
      # asked for (an assignee can force `planning`, for one). If the seed
      # does not actually park the member at `stack_pending` then the member
      # has an ordinary column to render in and this test proves nothing
      # about the stack path.
      assert Repo.get!(Task, member.id).status == "stack_pending"

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      member_row =
        ~s([data-stack-card="true"] [data-stack-member="true"][data-member-id="#{member.id}"])

      # Preconditions with NO query, so each later assertion is attributable
      # to the filter rather than to something never having rendered:
      #   * the control renders, so its absence under the query is the filter
      #   * the member row does NOT render, because the stack card starts
      #     collapsed — which is exactly what stage 2 has to overcome
      assert has_element?(view, ~s([data-task-id="#{control.id}"]))
      assert has_element?(view, ~s([data-task-id="#{solo.id}"]))
      refute has_element?(view, member_row)

      _ = render_change(filters(view), "filter_search", %{"q" => "periscope"})
      _ = after_filter(view)

      # The standalone task: an ordinary card.
      assert has_element?(view, ~s([data-task-id="#{solo.id}"]))

      # The stacked task: visible with no further click, and still legible AS
      # a stack member — the row is inside a stack card and carries its own
      # member id.
      assert has_element?(view, member_row)
      assert has_element?(view, ~s([data-stack-card="true"][data-stack-id="#{stack.id}"]))

      # Visible means the card is genuinely expanded, not that the row leaked
      # out of a collapsed card.
      assert has_element?(
               view,
               ~s([data-stack-card="true"][data-stack-id="#{stack.id}"][data-expanded="true"])
             )

      # Negative control.
      refute has_element?(view, ~s([data-task-id="#{control.id}"]))
      refute render(view) =~ "Unrelated widget ticket"
    end

    test "a search does not collapse a stack the user expanded by hand", %{conn: conn} do
      project = create_project()
      stack = create_stack(project)

      member =
        create_task(project, %{
          title: "Periscope stacked ticket",
          status: "stack_pending",
          stack_id: stack.id,
          stack_position: 1
        })

      {:ok, _stack} = Stacks.recompute_stack_status(stack)
      assert Repo.get!(Task, member.id).status == "stack_pending"

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      member_row =
        ~s([data-stack-card="true"] [data-stack-member="true"][data-member-id="#{member.id}"])

      # The user opens the card themselves.
      refute has_element?(view, member_row)

      _ =
        view
        |> Phoenix.LiveViewTest.with_target("#tasks-stacks")
        |> render_click("stack_toggle_expand", %{"id" => stack.id})

      _ = after_filter(view)
      assert has_element?(view, member_row)

      # Now a query that hits the stack's OWN NAME and no member title. The
      # auto-expand set for this query is therefore empty, so a write that
      # REPLACED `:expanded_stacks` instead of unioning into it would slam
      # the card shut under the user. This assertion is the difference
      # between the two, and it is why the hook unions.
      _ = render_change(filters(view), "filter_search", %{"q" => stack.name})
      _ = after_filter(view)

      assert has_element?(view, ~s([data-stack-card="true"][data-stack-id="#{stack.id}"]))
      assert has_element?(view, member_row)
    end
  end

  describe "board search" do
    test "renders the search input in the page header", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ ~s(id="task-search-form")
      assert html =~ ~s(phx-change="filter_search")
      assert html =~ ~s(aria-label="Search tasks")
    end

    test "filters board items by title, case-insensitively", %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Alpha Rocket"})
      create_task(project, %{title: "Beta Boat"})

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks")

      assert html =~ "Alpha Rocket"
      assert html =~ "Beta Boat"

      _ =
        view
        |> element("#task-search-form")
        |> render_change(%{"q" => "rocket"})

      html = after_filter(view)
      assert html =~ "Alpha Rocket"
      refute html =~ "Beta Boat"
    end

    test "matches on task id substring and epic name", %{conn: conn} do
      project = create_project()

      {:ok, epic} =
        Tasks.create_epic(%{name: "Skyhook Epic", project_id: project.id})

      task = create_task(project, %{title: "Id Target"})
      create_task(project, %{title: "Epic Member", epic_id: epic.id})
      create_task(project, %{title: "Unrelated"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # UUIDv7 ids share a timestamp prefix across same-test inserts —
      # the random tail is the only discriminating substring.
      id_fragment = String.slice(task.id, -12, 12)
      _ = view |> element("#task-search-form") |> render_change(%{"q" => id_fragment})
      html = after_filter(view)
      assert html =~ "Id Target"
      refute html =~ "Unrelated"

      _ = view |> element("#task-search-form") |> render_change(%{"q" => "skyhook"})

      html = after_filter(view)
      assert html =~ "Epic Member"
      refute html =~ "Unrelated"
    end

    test "shows the empty banner when nothing matches and Escape clears", %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Only Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ =
        view
        |> element("#task-search-form")
        |> render_change(%{"q" => "zzz-no-such-task"})

      html = after_filter(view)
      refute html =~ "Only Task"
      assert html =~ ~s(data-role="search-empty-state")
      assert html =~ "No matching tasks"

      # Escape keydown on the input clears the query and restores the board.
      _ = render_keydown(filters(view), "filter_search", %{"key" => "Escape", "value" => "zzz"})
      html = after_filter(view)
      assert html =~ "Only Task"
      refute html =~ ~s(data-role="search-empty-state")
    end

    # Task 01a08df0 stage 2: a "Clear search" control on the board's
    # EXISTING zero-match empty states (design canvas 01a0ea77-4bef — no new
    # empty-state design, no copy-link/share button anywhere in this UI).
    test "the desktop empty state offers Clear search, wired through the same path as Escape",
         %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Only Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ =
        view
        |> element("#task-search-form")
        |> render_change(%{"q" => "zzz-no-such-task"})

      html = after_filter(view)
      refute html =~ "Only Task"
      assert html =~ ~s(data-role="search-empty-state")

      desktop_clear = ~s([data-role="search-empty-state"] [data-role="clear-search"])
      assert has_element?(view, desktop_clear, "Clear search")

      # The button's own attributes prove it is wired through
      # FiltersComponent's `filter_search` handler — the SAME clause the
      # search input's Escape keydown fires — and not a second, parallel
      # clearing mechanism.
      [button_attrs] = attrs(html, desktop_clear)
      assert button_attrs["phx-click"] == "filter_search"
      assert button_attrs["phx-value-key"] == "Escape"
      assert button_attrs["phx-target"] == "#tasks-filters"

      # No share/copy-link control anywhere near the empty state — the
      # canvas explicitly cut one; the address bar is the whole mechanism.
      refute html =~ "Copy link"
      refute html =~ "copy_link"

      # Firing the real DOM button reaches the exact same code path Escape
      # does: the query clears and the board (and its ?q= URL param, proven
      # separately by stage 1's own tests) resets.
      _ = view |> element(desktop_clear) |> render_click()
      html = after_filter(view)
      assert html =~ "Only Task"
      refute html =~ ~s(data-role="search-empty-state")
    end

    test "the mobile empty state offers Clear search, wired through the same path as Escape",
         %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Only Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ =
        view
        |> element("#task-search-form")
        |> render_change(%{"q" => "zzz-no-such-task"})

      html = after_filter(view)
      assert html =~ ~s(data-role="search-empty-state-mobile")

      mobile_clear = ~s([data-role="search-empty-state-mobile"] [data-role="clear-search"])
      assert has_element?(view, mobile_clear, "Clear search")

      [button_attrs] = attrs(html, mobile_clear)
      assert button_attrs["phx-click"] == "filter_search"
      assert button_attrs["phx-value-key"] == "Escape"
      assert button_attrs["phx-target"] == "#tasks-filters"

      _ = view |> element(mobile_clear) |> render_click()
      html = after_filter(view)
      assert html =~ "Only Task"
      refute html =~ ~s(data-role="search-empty-state-mobile")
    end

    # Task 01a08df0 stage 2 (confirm, don't re-derive): a fresh mount at a
    # shared `/tasks?q=...` link must arrive with the search box already
    # prefilled, via the existing `value={@task_search_query}` binding —
    # this depends on stage 1's `handle_params/3` decode, not on anything
    # this stage adds, so it is asserted directly rather than assumed.
    test "mounting a shared search URL prefills the search input", %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Alpha Rocket"})

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks?q=alpha")

      assert [%{"value" => "alpha"}] = attrs(html, "#task-search")
    end

    test "an active search survives a board refresh (PubSub)", %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Kept Match"})
      nonmatch = create_task(project, %{title: "Filtered Away"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ = view |> element("#task-search-form") |> render_change(%{"q" => "kept"})

      html = after_filter(view)
      assert html =~ "Kept Match"
      refute html =~ "Filtered Away"

      # update_task broadcasts {:task_updated, _} on the board topic →
      # refresh_board/1 refetches. The query must still narrow the
      # refreshed board (maybe_reapply_search/1).
      {:ok, _} = Tasks.update_task(nonmatch, %{priority: "high"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Kept Match"
      refute html =~ "Filtered Away"
    end
  end

  test "scope-rail counts and header total narrow with an active search and restore on clear",
       %{conn: conn} do
    project = create_project()
    create_task(project, %{title: "Composer dock retrofit"})
    create_task(project, %{title: "Unrelated widget"})

    {:ok, view, _html} = conn |> authenticated_conn() |> live("/tasks")

    # Marlowe 2026-07-12: every on-screen count describes the filtered board.
    _ = render_change(filters(view), "filter_search", %{"q" => "composer"})
    html = after_filter(view)
    assert html =~ "Composer dock retrofit"
    refute html =~ "Unrelated widget"
    # header badge + fabrikam scope chip both show exactly one visible task
    assert view |> element("#tasks-page-header") |> render() =~ ">1<"

    # clearing restores the unfiltered totals everywhere
    _ = render_change(filters(view), "filter_search", %{"q" => ""})
    html = after_filter(view)
    assert html =~ "Unrelated widget"
    refute view |> element("#tasks-page-header") |> render() =~ ">1<"
  end

  # Task 01a08df0 stage 3: anti-vacuity, blank-case and history coverage for
  # the URL-backed search/scope stage 1 shipped. Every presence assertion
  # below is paired with a no-param positive control, and every absence
  # assertion is paired with a title that WOULD appear if the filter were a
  # no-op — per the stage's own binding instruction.
  describe "URL-backed search is linkable and shareable (stage 3)" do
    test "?q= narrows a fresh mount; a no-op build that ignores it fails the absence half",
         %{conn: conn} do
      project = create_project()
      matching = create_task(project, %{title: "Zephyr onboarding flow polish"})
      other = create_task(project, %{title: "Unrelated billing export bug"})

      conn = authenticated_conn(conn)

      # POSITIVE CONTROL, no query param at all: both tasks render. Without
      # this, the absence assertion below would be unattributable — a
      # build that renders NOTHING regardless of `q` would also pass it.
      {:ok, _view, html} = live(conn, ~p"/tasks")
      assert html =~ ~s(data-task-id="#{matching.id}")
      assert html =~ ~s(data-task-id="#{other.id}")

      # Fresh, independent mount straight at the `?q=` URL — no prior
      # interaction. A build that decodes `q` but never applies it (or
      # ignores it outright) passes the line above and fails here.
      {:ok, _view2, html2} = live(conn, ~p"/tasks?q=Zephyr")
      assert html2 =~ ~s(data-task-id="#{matching.id}")
      refute html2 =~ ~s(data-task-id="#{other.id}")
    end

    test "a blank-query patch does not stamp over manual stack expansion, and leaves no bare ?q=",
         %{conn: conn} do
      project = create_project()
      stack = create_stack(project)

      member =
        create_task(project, %{
          title: "Blank case stacked ticket",
          status: "stack_pending",
          stack_id: stack.id,
          stack_position: 1
        })

      {:ok, _stack} = Stacks.recompute_stack_status(stack)
      assert Repo.get!(Task, member.id).status == "stack_pending"

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # A known NON-EMPTY expanded-stack state, set by a real user action
      # (a manual click, not the filter under test) BEFORE the patch this
      # test exercises.
      _ =
        view
        |> Phoenix.LiveViewTest.with_target("#tasks-stacks")
        |> render_click("stack_toggle_expand", %{"id" => stack.id})

      _ = after_filter(view)
      before_expanded = :sys.get_state(view.pid).socket.assigns.expanded_stacks
      assert MapSet.member?(before_expanded, stack.id)

      # Re-run `handle_params/3` at a bare `/tasks` — no `q`, no
      # sponsor/sort change, exactly the "blank case" a naive URL-decode
      # could stamp over by resetting `:expanded_stacks` unconditionally.
      # `render_patch/2` drives ONLY `handle_params/3` (not `mount/3`), the
      # same seam a browser back-navigation or re-visit to `/tasks` hits on
      # an already-connected view.
      html = render_patch(view, ~p"/tasks")

      # (a) the rendered search box is empty / :task_search_query is "".
      assert [%{"value" => ""}] = attrs(html, "#task-search")
      assert :sys.get_state(view.pid).socket.assigns.task_search_query == ""

      # (b) manual expansion survived the blank-query pass untouched.
      # `MapSet.new()` here would be the regression.
      assert :sys.get_state(view.pid).socket.assigns.expanded_stacks == before_expanded

      # (c) no bare `?q=` fragment anywhere in the rendered self-links
      # (the sort control's two options are built from `BoardData.tasks_path/1`
      # and would carry a stray `?q=` if a blank query were ever treated as
      # "active").
      refute html =~ "?q="
    end

    test "typing a query then sharing the resulting URL reproduces the same filtered board",
         %{conn: conn} do
      project = create_project()
      matching = create_task(project, %{title: "Lantern rollout notes"})
      other = create_task(project, %{title: "Unrelated ticket"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ = view |> element("#task-search-form") |> render_change(%{"q" => "lantern"})
      captured_path = assert_patch(view)
      assert captured_path == "/tasks?q=lantern"

      # SECOND, independent fresh mount at the captured URL — no prior
      # interaction with this view at all. The URL alone must reproduce the
      # filtered board the first view arrived at by typing.
      {:ok, _view2, html2} = live(conn, captured_path)
      assert html2 =~ ~s(data-task-id="#{matching.id}")
      refute html2 =~ ~s(data-task-id="#{other.id}")
    end

    test "the first keystroke (blank -> non-blank) pushes; later keystrokes replace",
         %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Zephyr onboarding flow"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Task 01a08df0 remediation (validation 01a0ea7b-afaa-7002): the query
      # starts blank, so THIS keystroke must PUSH a new history entry —
      # replacing here would overwrite the pre-search `/tasks` entry via
      # `history.replaceState`, and that entry's content cannot be recovered
      # by a later Back (HTML History API semantics). Without this fix, this
      # assertion sees :replace instead.
      _ = view |> element("#task-search-form") |> render_change(%{"q" => "Z"})
      assert assert_patch_kind(view) == :push

      # Subsequent keystrokes, all non-blank -> non-blank, collapse onto the
      # entry the first keystroke just pushed — same "one entry, not three"
      # behavior as before the fix.
      for q <- ["Ze", "Zep"] do
        _ = view |> element("#task-search-form") |> render_change(%{"q" => q})
        assert assert_patch_kind(view) == :replace
      end
    end

    test "toggling the scope chip push_patches WITHOUT replace: true (a new history entry)",
         %{conn: conn} do
      # `filter_scope` for a real sub-org slug only succeeds when the
      # viewer belongs to that org (`parse_scope/2` checks `@active_scopes`)
      # — `member_of_all_orgs!/1` is the same fixture
      # `tasks_live_test.exs`'s scope-rail tests use for the "fabrikam" chip.
      user =
        Repo.insert!(%User{
          email: "tasks_search_scope_#{System.unique_integer([:positive])}@example.com",
          name: "Search Scope Test User",
          oidc_sub: "oidc-tasks-search-scope-#{System.unique_integer([:positive])}"
        })
        |> Platform.TenancyFixtures.member_of_all_orgs!()

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ = render_click(filters(view), "filter_scope", %{"scope" => "fabrikam"})
      assert assert_patch_kind(view) == :push

      # Negative control: the search box's own patches, on the same view, DO
      # replace — so this isn't "every patch on this page is :push". The
      # query is still blank at this point (only the scope chip has been
      # touched), so the FIRST search keystroke correctly pushes too (task
      # 01a08df0 remediation) — the meaningful negative control is the
      # SECOND keystroke, once the query is already non-blank.
      _ = view |> element("#task-search-form") |> render_change(%{"q" => "a"})
      assert assert_patch_kind(view) == :push

      _ = view |> element("#task-search-form") |> render_change(%{"q" => "an"})
      assert assert_patch_kind(view) == :replace
    end
  end

  # Task 01a008f6 stage 6: board filtering is a LiveComponent.
  defp filters(view), do: Phoenix.LiveViewTest.with_target(view, "#tasks-filters")

  # Task 01a008f6 stage 6: FiltersComponent writes the filter value and hands
  # it to the shell as `{:tasks_filters_changed, _}`. The shell's board work
  # therefore lands in the render AFTER the event reply, so a test that reads
  # the reply html directly is reading the pre-mediation board.
  defp after_filter(view) do
    _ = :sys.get_state(view.pid)
    Phoenix.LiveViewTest.render(view)
  end

  # Task 01a08df0 stage 3: `assert_patch/1,2` (from `Phoenix.LiveViewTest`)
  # exposes only the patched PATH, not whether it replaced history or
  # pushed a new entry. The `kind` (`:push` | `:replace`) rides in the same
  # `{ref, {:patch, topic, opts}}` message `assert_patch/2`'s own
  # `assert_navigation/4` receives on (phoenix_live_view's
  # `lib/phoenix_live_view/test/live_view_test.ex`) — receive it directly
  # to read `opts.kind` instead of just `opts.to`.
  defp assert_patch_kind(view, timeout \\ 200) do
    %{proxy: {ref, topic, _}} = view

    receive do
      {^ref, {:patch, ^topic, %{kind: kind}}} -> kind
    after
      timeout -> flunk("expected a live patch, got none")
    end
  end

  defp query(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
  end

  defp attrs(html, selector) do
    html
    |> query(selector)
    |> LazyHTML.attributes()
    |> Enum.map(&Map.new/1)
  end
end
