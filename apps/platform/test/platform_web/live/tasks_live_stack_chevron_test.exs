defmodule PlatformWeb.TasksLiveStackChevronTest do
  @moduledoc """
  Regression guard for the stack-card expand chevron (task 019fa298).

  ## Why this file exists at all

  `[data-role="stack-chevron"]` shipped carrying BOTH
  `phx-click="stack_toggle_expand"` and an inline
  `onclick="event.stopPropagation()"`. Those two are mutually exclusive
  on one element: `phoenix_live_view` binds its click handler with
  `window.addEventListener(eventName, handler, false)` — the BUBBLE
  phase, on `window`
  (`deps/phoenix_live_view/assets/js/phoenix_live_view/live_socket.js`,
  `bindClick/2`). An inline `onclick` runs at TARGET phase and stops the
  event before it ever reaches `window`, so the `phx-click` can never
  dispatch. The desktop chevron was dead: real clicks produced zero
  `stack_toggle_expand` on the server.

  ## Why the obvious test would have caught nothing

  `Phoenix.LiveViewTest.render_click/3` pushes the event straight to the
  server over the test channel. It never runs browser DOM propagation
  and never reads an inline `onclick`. `tasks_live_test.exs` already
  contains ~15 `stacks_click(view, "stack_toggle_expand", ...)` calls
  plus a wiring assertion — all green for months, and not one of them
  could see this bug. Adding a sixteenth would have proved nothing.

  So the discriminating assertions here are on the rendered MARKUP. The
  one `render_click/3` assertion below is explicitly labelled as
  server-handler coverage so no future reader mistakes it for the
  regression guard.

  A separate corpus-wide ratchet lives in
  `test/platform_web/inline_onclick_guard_test.exs`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.{Stack, Stacks}

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "tasks-stack-chevron-#{n}@example.com",
        name: "Chevron Test User #{n}",
        oidc_sub: "oidc-tasks-stack-chevron-#{n}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Chevron Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    project
  end

  # Mirrors the stack_fixture/1 shape in tasks_live_test.exs. Copied
  # rather than imported: the ADR-0046 stack has ~60 unmerged commits
  # editing that file, and a new self-contained file is conflict-free
  # against it.
  defp stack_fixture(project) do
    slug = "chevron-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Chevron Stack",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  defp chevron_nodes(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="stack-chevron"]))
    |> LazyHTML.attributes()
    |> Enum.map(&Map.new/1)
  end

  defp seed(conn) do
    conn = authenticated_conn(conn)
    project = create_project()
    stack = stack_fixture(project)

    # The mobile list renders only the column matching
    # `:active_status_filter`, which mounts as "in_progress". Park the
    # stack there so BOTH surfaces render it and the count assertion
    # below is meaningful rather than accidentally desktop-only.
    stack =
      stack
      |> Stack.changeset(%{status: "in_progress"})
      |> Repo.update!()

    {conn, stack}
  end

  describe "stack chevron markup" do
    test "renders on both surfaces — the count assertion that stops vacuous passes",
         %{conn: conn} do
      {conn, _stack} = seed(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # Desktop kanban (`hidden lg:flex`) and mobile list (`lg:hidden`)
      # BOTH render server-side; CSS decides which is visible, not the
      # server. Asserting the exact count means a markup refactor that
      # drops a surface fails loudly here instead of letting the
      # per-node assertions pass over an empty list.
      assert length(chevron_nodes(html)) == 2
    end

    test "no chevron carries an inline onclick — phx-click cannot survive one",
         %{conn: conn} do
      {conn, _stack} = seed(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      nodes = chevron_nodes(html)
      assert length(nodes) == 2

      for {node, index} <- Enum.with_index(nodes) do
        assert Map.get(node, "onclick") == nil,
               """
               [data-role="stack-chevron"] node #{index} carries an inline onclick:

                   #{inspect(Map.get(node, "onclick"))}

               An inline onclick fires at TARGET phase. LiveView binds its
               click handler in the BUBBLE phase on `window` (live_socket.js
               bindClick/2 -> window.addEventListener(name, handler, false)),
               so the event is stopped before LiveView ever sees it and the
               phx-click on this element can never dispatch.

               phx-click and inline onclick are mutually exclusive on one
               element. Remove the onclick.
               """
      end
    end

    test "every chevron still carries the stack_toggle_expand wiring", %{conn: conn} do
      {conn, stack} = seed(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      nodes = chevron_nodes(html)
      assert length(nodes) == 2

      for node <- nodes do
        assert Map.get(node, "phx-click") == "stack_toggle_expand"
        assert Map.get(node, "phx-value-id") == stack.id
      end
    end

    test "SERVER HANDLER ONLY — render_click cannot see the propagation bug",
         %{conn: conn} do
      # Deliberately labelled. render_click/3 bypasses DOM propagation
      # entirely, so this passes with the inline onclick fully present.
      # It covers tasks_live.ex's stack_toggle_expand handler and
      # NOTHING about whether a real click can reach it. The markup
      # assertions above are the actual regression guard.
      {conn, stack} = seed(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _html = stacks_click(view, "stack_toggle_expand", %{"id" => stack.id})
      assert MapSet.member?(:sys.get_state(view.pid).socket.assigns.expanded_stacks, stack.id)

      _html = stacks_click(view, "stack_toggle_expand", %{"id" => stack.id})
      refute MapSet.member?(:sys.get_state(view.pid).socket.assigns.expanded_stacks, stack.id)
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
