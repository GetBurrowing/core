defmodule PlatformWeb.TasksMyTasksListTest do
  @moduledoc """
  The phone my-tasks list at /tasks (task 01a1557a-b20a stage 2),
  `PlatformWeb.Tasks.MyTasksList`.

  Every absence is preceded on the same render by a positive control showing
  the same query can find something.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Inbox, Repo, Tasks}
  alias Platform.Inbox.Item
  alias Platform.Tasks.{ReviewRequests, Task}

  defp u, do: System.unique_integer([:positive])

  defp user! do
    n = u()

    Repo.insert!(%User{
      email: "my-list-#{n}@example.com",
      name: "My List #{n}",
      oidc_sub: "my-list-#{n}"
    })
    |> Platform.TenancyFixtures.member_of_all_orgs!()
  end

  defp project!(name) do
    {:ok, p} = Tasks.create_project(%{name: name, repo_url: "git@github.com:test/repo.git"})
    p
  end

  defp task!(project, title, set) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: title})
    {1, _} = Repo.update_all(from(t in Task, where: t.id == ^task.id), set: set)
    Repo.get!(Task, task.id)
  end

  defp mount(conn, user, path \\ "/tasks") do
    {:ok, view, html} = live(init_test_session(conn, current_user_id: user.id), path)
    {view, html}
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp q(doc, sel), do: doc |> LazyHTML.query(sel) |> Enum.to_list()
  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  # Whitespace-normalised text. The meta line's parts are flex siblings with no
  # whitespace between them in the rendered HTML, so the decorative separator
  # is normalised to " · " here.
  defp text(node) do
    node
    |> LazyHTML.text()
    |> String.replace(~r/\s*·\s*/, " · ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp list_html(view), do: view |> element("#tasks-my-list") |> render()

  defp classes(nodes),
    do: Enum.flat_map(nodes, &String.split(attr(&1, "class") || "", ~r/\s+/, trim: true))

  setup do
    me = user!()
    p = project!("My List Project #{u()}")

    high =
      task!(p, "High priority in progress",
        sponsor_user_id: me.id,
        status: "in_progress",
        priority: "high"
      )

    low =
      task!(p, "Low priority in review",
        sponsor_user_id: me.id,
        status: "in_review",
        priority: "low"
      )

    done = task!(p, "Done already", sponsor_user_id: me.id, status: "done")
    theirs = task!(p, "Not mine", sponsor_user_id: user!().id, status: "backlog")

    %{me: me, p: p, high: high, low: low, done: done, theirs: theirs}
  end

  # Task 01a161fd stage 3: the list renders `@filtered_tasks`, so "mine" is a
  # FILTER (`?mine=1`), not the list's definition. The default is every task in
  # every status, as in the prototype's initial view; the 'Tasks' h1 and the
  # 'mine · N open' subtitle are replaced by the project title picker.
  test "renders the narrowed list in board-sort order with status, project and priority",
       ctx do
    {_view, html} = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")
    d = doc(html)

    rows = q(d, "#tasks-my-list [data-role=tasks-my-row]")

    # Priority, ties newest-created first: high, then the two medium rows
    # (theirs was created after done), then low.
    assert Enum.map(rows, &attr(&1, "data-row-task-id")) == [
             ctx.high.id,
             ctx.theirs.id,
             ctx.done.id,
             ctx.low.id
           ]

    assert q(d, "[data-role=tasks-my-subtitle]") == []
    assert d |> q("[data-role=tasks-title-project]") |> hd() |> text() == ctx.p.name

    [high_row, _theirs_row, _done_row, low_row] = rows
    assert text(high_row) =~ "No activity · last activity unknown · #{ctx.p.name}"
    assert text(low_row) =~ "In review · #{ctx.p.name}"
    assert high_row |> LazyHTML.query("[data-role=tasks-my-priority]") |> text() == "High"
    assert low_row |> LazyHTML.query("[data-role=tasks-my-priority]") |> text() == "Low"

    # StatusLabels.dot_class/1, the binding palette (canvas 01a15db1 `dots`).
    assert high_row
           |> LazyHTML.query("[data-role=execution-status][data-state=unknown]")
           |> Enum.any?()

    assert high_row |> LazyHTML.query("[data-role=tasks-my-dot]") == []

    assert low_row
           |> LazyHTML.query("[data-role=tasks-my-dot]")
           |> classes()
           |> Enum.member?("bg-edge")

    for dot <- q(d, "#tasks-my-list [data-role=tasks-my-dot]"),
        do: assert(attr(dot, "aria-hidden") == "true")

    list = d |> q("#tasks-my-list") |> hd() |> text()
    assert list =~ "Done already"
    assert list =~ "Not mine"
  end

  test "?mine=1 narrows the list to the viewer's tasks, done included", ctx do
    {_view, html} = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&mine=1")
    rows = html |> doc() |> q("#tasks-my-list [data-role=tasks-my-row]")

    assert Enum.map(rows, &attr(&1, "data-row-task-id")) == [ctx.high.id, ctx.done.id, ctx.low.id]
    refute html |> doc() |> q("#tasks-my-list") |> hd() |> text() =~ "Not mine"
  end

  test "every row is a plain patch link to its task, and no live link carries phx-click", ctx do
    {_view, html} = mount(ctx.conn, ctx.me)
    d = doc(html)

    rows = q(d, "#tasks-my-list [data-role=tasks-my-row]")
    links = q(d, "#tasks-my-list [data-phx-link]")
    # Positive control: the scan sees the rows.
    assert length(rows) > 0
    assert length(links) == length(rows)

    for row <- rows do
      assert LazyHTML.tag(row) == ["a"]
      assert attr(row, "data-phx-link") == "patch"
      assert attr(row, "href") == "/tasks/#{attr(row, "data-row-task-id")}"
    end

    assert Enum.filter(links, &(attr(&1, "phx-click") != nil)) == []
  end

  test "following a row opens the detail panel and dismisses the sponsor inbox row", ctx do
    {:ok, row} =
      Inbox.emit(%{
        user_id: ctx.me.id,
        kind: "task_sponsor_assigned",
        source_type: "task",
        source_id: ctx.high.id,
        title: "Sponsor row",
        url: "/tasks/#{ctx.high.id}"
      })

    {view, _html} = mount(ctx.conn, ctx.me)
    refute has_element?(view, "[data-role=task-detail-panel]")
    assert Repo.get!(Item, row.id).dismissed_at == nil

    view
    |> element(~s(#tasks-my-list [data-role=tasks-my-row][data-row-task-id="#{ctx.high.id}"]))
    |> render_click()

    assert_patch(view, "/tasks/#{ctx.high.id}")
    assert has_element?(view, "[data-role=task-detail-panel]")
    assert Repo.get!(Item, row.id).dismissed_at != nil
  end

  test "the Needs you pill renders only on a task with a pending ReviewRequest", ctx do
    {view, _html} = mount(ctx.conn, ctx.me)
    refute has_element?(view, "#tasks-my-list [data-role=tasks-needs-you]")

    {:ok, plan} = Tasks.create_plan(%{task_id: ctx.low.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI"})
    {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    {:ok, _} =
      ReviewRequests.create_review_request(%{
        validation_id: validation.id,
        task_id: ctx.low.id,
        items: [%{label: "Phone"}]
      })

    send(view.pid, {:task_updated, Repo.get!(Task, ctx.low.id)})
    d = doc(list_html(view))

    pills = q(d, "[data-role=tasks-needs-you]")
    assert length(pills) == 1

    assert q(d, ~s([data-row-task-id="#{ctx.low.id}"] [data-role=tasks-needs-you])) |> length() ==
             1

    assert q(d, ~s([data-row-task-id="#{ctx.high.id}"] [data-role=tasks-needs-you])) == []
  end

  test "a filter that matches nothing shows the empty state with Clear all", ctx do
    {view, _html} = mount(ctx.conn, user!(), "/tasks?project=#{ctx.p.id}&mine=1")

    assert view |> element("[data-role=tasks-my-empty]") |> render() =~
             "No tasks match these filters"

    assert has_element?(view, "[data-role=tasks-my-empty] [data-role=tasks-empty-clear]")
    refute has_element?(view, "[data-role=tasks-my-row]")

    {mine, _} = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&mine=1")
    refute has_element?(mine, "[data-role=tasks-my-empty]"), "positive control"
  end

  test "masking hides the real project name everywhere in the list", ctx do
    {view, _html} = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")
    assert list_html(view) =~ ctx.p.name, "positive control: unmasked shows the name"

    render_click(view, "toggle_mask_names", %{"masked" => "true"})
    masked = list_html(view)
    assert masked =~ "tasks-my-project", "positive control: the project slot still renders"
    refute masked =~ ctx.p.name
  end

  test "the list and the board swap by class ops; the FAB hides with the board", ctx do
    {_view, html} = mount(ctx.conn, ctx.me)
    d = doc(html)

    [main] = q(d, "#tasks-main")
    assert "max-lg:hidden" in classes([main])

    [list] = q(d, "#tasks-my-list")
    assert "lg:hidden" in classes([list])
    # A flex item defaults to min-width: auto; without min-w-0 a 60-character
    # project name widened the list to 547px at a 375px viewport (measured on a dev server).
    assert "min-w-0" in classes([list])
    refute "max-lg:hidden" in classes([list])

    [fab] = q(d, "#tasks-create-fab")
    assert "max-lg:hidden" in classes([fab])

    [board_btn] = q(d, "[data-role=tasks-show-board]")
    [mine_btn] = q(d, "[data-role=tasks-show-mine]")
    assert attr(board_btn, "type") == "button" and attr(mine_btn, "type") == "button"

    board_ops = Jason.decode!(attr(board_btn, "phx-click"))
    mine_ops = Jason.decode!(attr(mine_btn, "phx-click"))

    assert ops_summary(board_ops) == [
             {"add_class", "#tasks-my-list"},
             {"remove_class", "#tasks-main, #tasks-create-fab"}
           ]

    assert ops_summary(mine_ops) == [
             {"add_class", "#tasks-main, #tasks-create-fab"},
             {"remove_class", "#tasks-my-list"}
           ]
  end

  test "no text-base-content/ class and nothing under 12px in the list", ctx do
    {_view, html} = mount(ctx.conn, ctx.me)
    all = html |> doc() |> q("#tasks-my-list, #tasks-my-list *") |> classes()

    # Positive control: the scan sees the list's own classes.
    assert "text-subtle" in all
    assert "text-[15px]" in all

    refute Enum.any?(all, &String.starts_with?(&1, "text-base-content/"))

    # The title clamps at two lines. `.block` is emitted after
    # `.line-clamp-2` in the built CSS, so the two together render unclamped
    # (measured on a dev server: a 185-character title painted 4 lines).
    titles = q(html |> doc(), "#tasks-my-list [data-role=tasks-my-title]")
    assert length(titles) >= 2

    for title <- titles do
      assert "line-clamp-2" in classes([title])
      refute "block" in classes([title])
    end

    small =
      for c <- all,
          [_, n] <- [Regex.run(~r/^text-\[(\d+)px\]$/, c)],
          String.to_integer(n) < 12,
          do: c

    assert small == []
  end

  test "no hover: utility in the list or on either switch button", ctx do
    {_view, html} = mount(ctx.conn, ctx.me)
    d = doc(html)

    scanned =
      classes(q(d, "#tasks-my-list, #tasks-my-list *") ++ q(d, "[data-role=tasks-show-mine]"))

    # Positive control: the same scan finds the pressed-state utility on the
    # rows and the switches, so a hover: class would be seen if present.
    assert "active:bg-base-100" in scanned
    assert "active:bg-base-100" in classes(q(d, "[data-role=tasks-show-board]"))
    assert "active:bg-base-100" in classes(q(d, "[data-role=tasks-show-mine]"))

    assert Enum.filter(scanned, &String.contains?(&1, "hover:")) == []
  end

  # Each op as {kind, target}, after asserting it moves only `max-lg:hidden`.
  defp ops_summary(ops) do
    Enum.map(ops, fn [kind, %{"to" => to, "names" => names}] ->
      assert names == ["max-lg:hidden"]
      {kind, to}
    end)
  end
end
