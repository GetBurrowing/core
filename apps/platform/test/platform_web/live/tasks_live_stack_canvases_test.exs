defmodule PlatformWeb.TasksLiveStackCanvasesTest do
  @moduledoc """
  The stack view's canvases section (task 01a1559a stage 4; design direction
  canvas 01a1559b, inventory rows 8-12): per-canvas coverage rows, the
  '+ Attach canvas to all tasks' row, the count-stating confirm line, and the
  stack-wide detach confirm.

  The cross-org (fenced) refusal of the same events lives beside the other
  fence sweeps in `PlatformWeb.TasksWriteFenceTest`.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.{CanvasAttachment, Stacks, Task}
  alias PlatformWeb.Tasks.StacksComponent

  # ── fixtures ──────────────────────────────────────────────────────────

  defp n, do: System.unique_integer([:positive])

  defp user_conn(conn \\ build_conn()) do
    user =
      Repo.insert!(%User{
        email: "stack_canvases_#{n()}@example.com",
        name: "Stack Canvases User",
        oidc_sub: "oidc-stack-canvases-#{n()}"
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp project! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Stack canvases #{n()}",
        repo_url: "git@github.com:test/repo.git"
      })

    project
  end

  # A stack with `count` members in mixed statuses, each with an assignee and
  # phase_assignees, so "nothing about a member changed" is a real check.
  defp stack_with_members!(project, count) do
    slug = "stack-canvases-#{n()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Canvas stack #{n()}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    statuses = ~w(backlog planning in_progress in_review backlog planning)
    agent_id = Ecto.UUID.generate()

    members =
      for pos <- 1..count do
        {:ok, task} =
          Tasks.create_task(%{
            project_id: project.id,
            stack_id: stack.id,
            stack_position: pos,
            title: "Member #{pos}",
            status: Enum.at(statuses, rem(pos - 1, length(statuses))),
            priority: "medium",
            assignee_type: "agent",
            assignee_id: agent_id,
            phase_assignees: %{
              "planning" => %{"assignee_id" => agent_id, "assignee_type" => "agent"}
            }
          })

        task
      end

    {stack, members}
  end

  # A channel the viewer participates in, so the picker lists its canvases
  # and `CanvasAccess` lets the viewer read them.
  defp readable_canvas!(user, title) do
    i = n()

    {:ok, space} =
      Chat.create_space(%{name: "stack-pick-#{i}", slug: "stack-pick-#{i}", kind: "channel"})

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    Repo.insert!(%Canvas{space_id: space.id, created_by: participant.id, title: title})
  end

  # A pre-existing attachment with its own note and attacher, inserted
  # directly so nothing else (the ADR-0046 settle hook) runs.
  defp pre_attach!(task, canvas) do
    Repo.insert!(%CanvasAttachment{
      task_id: task.id,
      canvas_id: canvas.id,
      note: "pre-existing note #{n()}",
      attached_by_kind: "agent",
      attached_by_id: Ecto.UUID.generate()
    })
  end

  defp rows(canvas) do
    Repo.all(from(a in CanvasAttachment, where: a.canvas_id == ^canvas.id, order_by: a.task_id))
  end

  defp member_state(members) do
    ids = Enum.map(members, & &1.id)

    Repo.all(
      from(t in Task,
        where: t.id in ^ids,
        order_by: t.id,
        select:
          {t.id, t.status, t.assignee_type, t.assignee_id, t.phase_assignees, t.planning_step}
      )
    )
  end

  defp stacks(view), do: with_target(view, "#tasks-stacks")

  defp open_stack(conn, stack) do
    {:ok, view, _html} = live(conn, ~p"/tasks")
    render_hook(stacks(view), "stack_open_detail", %{"id" => stack.id})
    assert has_element?(view, ~s|[data-role="stack-detail-canvases"]|)
    view
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.replace("&quot;", "\"")
  end

  defp coverage(view, canvas),
    do:
      text(
        view,
        ~s|[data-role="stack-detail-canvas-row"][data-canvas-id="#{canvas.id}"] [data-role="stack-detail-canvas-coverage"]|
      )

  defp flash(view, kind) do
    _ = render(view)
    Phoenix.Flash.get(:sys.get_state(view.pid).socket.assigns.flash, kind)
  end

  # ── attach ────────────────────────────────────────────────────────────

  describe "attach to all tasks" do
    test "6 members, 2 pre-attached: the confirm line states 4 and 2, Attach writes 4, the 2 rows are untouched",
         %{conn: conn} do
      {conn, user} = user_conn(conn)
      {stack, members} = stack_with_members!(project!(), 6)
      m = readable_canvas!(user, "Design direction: tokens")
      [a, b | _] = members
      pre_attach!(a, m)
      pre_attach!(b, m)
      pre_rows = rows(m)
      before = member_state(members)

      view = open_stack(conn, stack)

      # Partial coverage shows its true N, with a plain (not error-toned) Detach.
      assert coverage(view, m) == "on 2 of 6 tasks"

      detach_btn =
        view
        |> element(
          ~s|[data-role="stack-detail-canvas-row"][data-canvas-id="#{m.id}"] [data-role="stack-detail-canvas-detach"]|
        )
        |> render()

      assert detach_btn =~ "btn-ghost"
      refute detach_btn =~ "btn-error"

      # The attach row is a full-width row, like the task-detail one.
      trigger = view |> element(~s|[data-role="canvas-picker-trigger-stack"]|) |> render()
      assert trigger =~ "Attach canvas to all tasks"
      assert trigger =~ "w-full"
      refute trigger =~ "badge"

      # Stack-mode picker: partially covered stays selectable and says so.
      view |> element(~s|[data-role="canvas-picker-trigger-stack"]|) |> render_click()

      meta =
        text(
          view,
          ~s|[data-role="canvas-picker-row"][data-canvas-id="#{m.id}"] [data-role="canvas-picker-row-meta"]|
        )

      assert meta =~ "· on 2 of 6 tasks"

      view
      |> element(~s|[data-role="canvas-picker-row"][data-canvas-id="#{m.id}"]|)
      |> render_click()

      # Picking wrote nothing; it stated what Attach will write.
      assert rows(m) == pre_rows

      assert text(view, ~s|[data-role="stack-canvas-confirm-text"]|) ==
               ~s(Attach "Design direction: tokens" to 4 tasks. 2 already have it.)

      confirm = view |> element(~s|[data-role="stack-canvas-confirm"]|) |> render()
      refute confirm =~ ~s|type="checkbox"|
      assert length(Regex.scan(~r/btn-primary/, confirm)) == 1

      assert view |> element(~s|[data-role="stack-canvas-confirm-submit"]|) |> render() =~
               "btn-primary"

      assert view |> element(~s|[data-role="stack-canvas-confirm-cancel"]|) |> render() =~
               "btn-ghost"

      refute render(view) =~ ~s|type="checkbox"|

      view |> element(~s|[data-role="stack-canvas-confirm-submit"]|) |> render_click()

      after_rows = rows(m)
      assert length(after_rows) == 6
      assert MapSet.new(after_rows, & &1.task_id) == MapSet.new(members, & &1.id)

      # The 2 pre-existing rows are byte-equal: note, attacher, timestamps.
      for row <- pre_rows do
        assert Enum.find(after_rows, &(&1.id == row.id)) == row
      end

      new_rows = Enum.reject(after_rows, &(&1.id in Enum.map(pre_rows, fn r -> r.id end)))
      assert length(new_rows) == 4

      assert Enum.all?(
               new_rows,
               &(&1.attached_by_kind == "user" and &1.attached_by_id == user.id)
             )

      assert flash(view, "info") ==
               ~s(Attached "Design direction: tokens" to 4 tasks. 2 already had it.)

      assert coverage(view, m) == "on 6 of 6 tasks"
      refute has_element?(view, ~s|[data-role="stack-canvas-confirm"]|)

      # Fully covered now: checked and disabled in the stack picker.
      view |> element(~s|[data-role="canvas-picker-trigger-stack"]|) |> render_click()

      attached_row =
        view
        |> element(~s|[data-role="canvas-picker-row-attached"][data-canvas-id="#{m.id}"]|)
        |> render()

      assert attached_row =~ ~s|aria-disabled="true"|
      assert attached_row =~ "hero-check"
      refute attached_row =~ "phx-click"

      # No member status, assignee, phase_assignees or planning_step changed.
      assert member_state(members) == before
    end

    test "copy variants: K = 0 drops the second sentence; N = 1 reads '1 task'; K = 1 reads '1 already has it'",
         %{conn: conn} do
      {conn, user} = user_conn(conn)

      {fresh, _} = stack_with_members!(project!(), 3)
      c = readable_canvas!(user, "Burrow redesign masters")
      view = open_stack(conn, fresh)
      render_hook(stacks(view), "stack_canvas_pick", %{"canvas-id" => c.id})

      assert text(view, ~s|[data-role="stack-canvas-confirm-text"]|) ==
               ~s(Attach "Burrow redesign masters" to 3 tasks.)

      {pair, [first, _]} = stack_with_members!(project!(), 2)
      pre_attach!(first, c)
      view = open_stack(conn, pair)
      render_hook(stacks(view), "stack_canvas_pick", %{"canvas-id" => c.id})

      assert text(view, ~s|[data-role="stack-canvas-confirm-text"]|) ==
               ~s(Attach "Burrow redesign masters" to 1 task. 1 already has it.)

      view |> element(~s|[data-role="stack-canvas-confirm-submit"]|) |> render_click()

      assert flash(view, "info") ==
               ~s(Attached "Burrow redesign masters" to 1 task. 1 already had it.)

      # The copy function's remaining arms.
      assert StacksComponent.attach_confirm_text("T", 1, 0) == ~s(Attach "T" to 1 task.)

      assert StacksComponent.attach_confirm_text("T", 25, 3) ==
               ~s(Attach "T" to 25 tasks. 3 already have it.)

      assert StacksComponent.detach_confirm_text(1) == "Remove from 1 task."
    end

    test "Cancel closes the confirm line and writes nothing", %{conn: conn} do
      {conn, user} = user_conn(conn)
      {stack, _members} = stack_with_members!(project!(), 3)
      c = readable_canvas!(user, "Cancelled")
      view = open_stack(conn, stack)

      render_hook(stacks(view), "stack_canvas_pick", %{"canvas-id" => c.id})
      assert has_element?(view, ~s|[data-role="stack-canvas-confirm"]|)

      view |> element(~s|[data-role="stack-canvas-confirm-cancel"]|) |> render_click()
      refute has_element?(view, ~s|[data-role="stack-canvas-confirm"]|)

      # A stray Attach after Cancel has nothing parked to act on.
      render_hook(stacks(view), "stack_canvas_attach", %{})
      assert rows(c) == []
    end

    test "a forged pick of a canvas the viewer cannot read states nothing and writes nothing",
         %{conn: conn} do
      {conn, user} = user_conn(conn)
      {stack, _members} = stack_with_members!(project!(), 2)

      {:ok, foreign_space} =
        Chat.create_space(%{name: "elsewhere", slug: "elsewhere-#{n()}", kind: "channel"})

      {:ok, author} =
        Chat.add_participant(foreign_space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Someone else",
          joined_at: DateTime.utc_now()
        })

      foreign =
        Repo.insert!(%Canvas{
          space_id: foreign_space.id,
          created_by: author.id,
          title: "Secret title"
        })

      readable = readable_canvas!(user, "Readable")

      view = open_stack(conn, stack)
      render_hook(stacks(view), "stack_canvas_pick", %{"canvas-id" => foreign.id})

      refute has_element?(view, ~s|[data-role="stack-canvas-confirm"]|)
      refute render(view) =~ "Secret title"
      assert flash(view, "error") =~ "can't be attached"

      render_hook(stacks(view), "stack_canvas_pick", %{"canvas-id" => "not-a-uuid"})
      render_hook(stacks(view), "stack_canvas_attach", %{})
      assert rows(foreign) == []

      # POSITIVE CONTROL: the same forged pick of a readable canvas parks it.
      render_hook(stacks(view), "stack_canvas_pick", %{"canvas-id" => readable.id})
      assert has_element?(view, ~s|[data-role="stack-canvas-confirm"]|)
      render_hook(stacks(view), "stack_canvas_attach", %{})
      assert length(rows(readable)) == 2
    end

    test "attach broadcasts each changed member: another stack session and an open task strip refresh",
         %{conn: conn} do
      {conn, user} = user_conn(conn)
      {stack, [m1 | _] = _members} = stack_with_members!(project!(), 3)
      c = readable_canvas!(user, "Broadcast me")

      watcher = open_stack(conn, stack)

      refute has_element?(
               watcher,
               ~s|[data-role="stack-detail-canvas-row"][data-canvas-id="#{c.id}"]|
             )

      {:ok, strip, _html} = live(conn, ~p"/tasks?task_id=#{m1.id}")
      refute has_element?(strip, ~s|[data-role="linked-canvas-chip"][data-canvas-id="#{c.id}"]|)

      actor = open_stack(conn, stack)
      render_hook(stacks(actor), "stack_canvas_pick", %{"canvas-id" => c.id})
      actor |> element(~s|[data-role="stack-canvas-confirm-submit"]|) |> render_click()

      # Two renders, deliberately. The watcher handles each `{:task_updated, _}`
      # by asking its StacksComponent to reload with `send_update/3`, which is
      # a message to ITSELF, queued behind a render request this test already
      # sent. The first render drains the broadcasts; the second runs after
      # the reloads they queued. (Red once in a loaded full-suite run with a
      # single render.)
      _ = render(watcher)
      assert coverage(watcher, c) == "on 3 of 3 tasks"
      _ = render(strip)
      assert has_element?(strip, ~s|[data-role="linked-canvas-chip"][data-canvas-id="#{c.id}"]|)
    end
  end

  # ── detach ────────────────────────────────────────────────────────────

  describe "stack-wide detach" do
    test "Detach states 'Remove from 6 tasks.', Remove is the only error-toned button, and clears every member",
         %{conn: conn} do
      {conn, user} = user_conn(conn)
      {stack, members} = stack_with_members!(project!(), 6)
      m = readable_canvas!(user, "Remove me")
      keep = readable_canvas!(user, "Keep me")
      Enum.each(members, &pre_attach!(&1, m))
      pre_attach!(hd(members), keep)
      before = member_state(members)

      view = open_stack(conn, stack)
      assert coverage(view, m) == "on 6 of 6 tasks"
      assert coverage(view, keep) == "on 1 of 6 tasks"

      view
      |> element(
        ~s|[data-role="stack-detail-canvas-row"][data-canvas-id="#{m.id}"] [data-role="stack-detail-canvas-detach"]|
      )
      |> render_click()

      # Prompting wrote nothing.
      assert length(rows(m)) == 6
      assert text(view, ~s|[data-role="stack-canvas-confirm-text"]|) == "Remove from 6 tasks."

      section = view |> element(~s|[data-role="stack-detail-canvases"]|) |> render()
      assert length(Regex.scan(~r/btn-error/, section)) == 1

      assert view |> element(~s|[data-role="stack-canvas-confirm-submit"]|) |> render() =~
               "btn-error"

      assert text(view, ~s|[data-role="stack-canvas-confirm-submit"]|) == "Remove"

      view |> element(~s|[data-role="stack-canvas-confirm-submit"]|) |> render_click()

      assert rows(m) == []

      refute has_element?(
               view,
               ~s|[data-role="stack-detail-canvas-row"][data-canvas-id="#{m.id}"]|
             )

      assert flash(view, "info") == ~s(Removed "Remove me" from 6 tasks.)

      # The other canvas is untouched.
      assert length(rows(keep)) == 1
      assert coverage(view, keep) == "on 1 of 6 tasks"
      assert member_state(members) == before

      # Detaching the last one leaves no canvas rows at all.
      view
      |> element(
        ~s|[data-role="stack-detail-canvas-row"][data-canvas-id="#{keep.id}"] [data-role="stack-detail-canvas-detach"]|
      )
      |> render_click()

      assert text(view, ~s|[data-role="stack-canvas-confirm-text"]|) == "Remove from 1 task."
      view |> element(~s|[data-role="stack-canvas-confirm-submit"]|) |> render_click()
      refute has_element?(view, ~s|[data-role="stack-detail-canvas-row"]|)
    end
  end

  # ── a viewer without tasks.write ─────────────────────────────────────

  describe "a viewer without tasks.write" do
    test "sees the coverage but no controls, and forged events write nothing", %{conn: conn} do
      {reader_conn, reader} = user_conn(conn)
      project = project!()
      {stack, members} = stack_with_members!(project, 3)
      on_stack = readable_canvas!(reader, "Already on the stack")
      Enum.each(members, &pre_attach!(&1, on_stack))
      fresh = readable_canvas!(reader, "Not on the stack")

      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: reader,
          permission: "tasks.write",
          resource: project
        })

      view = open_stack(reader_conn, stack)
      assert coverage(view, on_stack) == "on 3 of 3 tasks"
      refute has_element?(view, ~s|[data-role="stack-detail-canvas-detach"]|)
      refute has_element?(view, ~s|[data-role="stack-detail-canvas-attach-row"]|)
      refute has_element?(view, ~s|[data-role="canvas-picker-trigger-stack"]|)

      render_hook(stacks(view), "stack_canvas_pick", %{"canvas-id" => fresh.id})
      refute has_element?(view, ~s|[data-role="stack-canvas-confirm"]|)
      render_hook(stacks(view), "stack_canvas_attach", %{})
      assert rows(fresh) == []

      render_hook(stacks(view), "stack_canvas_detach_prompt", %{"canvas-id" => on_stack.id})
      refute has_element?(view, ~s|[data-role="stack-canvas-confirm"]|)
      render_hook(stacks(view), "stack_canvas_detach", %{})
      assert length(rows(on_stack)) == 3

      # POSITIVE CONTROL: the identical forged sequence from a writer writes.
      {writer_conn, writer} = user_conn()
      shared = readable_canvas!(writer, "Writer canvas")
      writer_view = open_stack(writer_conn, stack)
      assert has_element?(writer_view, ~s|[data-role="stack-detail-canvas-attach-row"]|)

      render_hook(stacks(writer_view), "stack_canvas_pick", %{"canvas-id" => shared.id})
      render_hook(stacks(writer_view), "stack_canvas_attach", %{})
      assert length(rows(shared)) == 3

      render_hook(stacks(writer_view), "stack_canvas_detach_prompt", %{"canvas-id" => on_stack.id})

      render_hook(stacks(writer_view), "stack_canvas_detach", %{})
      assert rows(on_stack) == []
    end
  end
end
