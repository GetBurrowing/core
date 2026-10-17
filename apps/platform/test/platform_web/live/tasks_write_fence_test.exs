defmodule PlatformWeb.TasksWriteFenceTest do
  @moduledoc """
  Tasks write handlers re-check their target against the actor's fenced
  scope (task 01a1472d stage 1, `Platform.Access.task_target/3`).

  The world: the root org R and a sub-org S, each with a project, an epic, a
  stack with one member task, a task with a `pending_review` plan, a stage,
  a validation and a pending review request with one item. Actors:

    * M, an internal member of S only (fenced to S);
    * RM, an internal member of R (unfenced);
    * RA, an admin of R (unfenced);
    * X, a member of S AND R who opens an R record and is then fenced by a
      live scope change (`{:access_changed, _}`), for the handlers that act
      on a server-held selection rather than a client id.

  For every client-id handler M pushes the event with the R-side id, the way
  a forged `pushEvent` arrives, and the test asserts that the flash equals
  the flash for a fresh random UUID and that a FULL snapshot of every row the
  handler could write (plus row counts for the create paths) is identical
  before and after. Each refusal sits beside its POSITIVE CONTROLS on the
  same fixture shape: M's event on the S-side id writes, and RM and RA write
  on both R and S ids. A refusal without its control is not evidence.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.Grants
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat.Message
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Skills
  alias Platform.Skills.SkillAttachment

  alias Platform.Tasks.{
    CanvasAttachment,
    ChatPin,
    Epic,
    Plan,
    Project,
    ReviewItem,
    ReviewRequest,
    Stack,
    Stage,
    Task,
    Validation
  }

  alias Platform.Tenancy.OrgMembership

  # ── fixtures ────────────────────────────────────────────────────────────

  defp n, do: System.unique_integer([:positive])

  defp user!(tag) do
    i = n()

    Repo.insert!(%User{
      email: "wfence-#{tag}-#{i}@example.com",
      name: "Write fence #{tag} #{i}",
      oidc_sub: "wfence-#{tag}-#{i}"
    })
  end

  defp membership!(user, org, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org, role: role})
    |> Repo.insert!()
  end

  defp world!(org, tag) do
    i = n()

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "wfence-#{tag}-#{i}", org_id: org})

    epic = Repo.insert!(%Epic{project_id: project.id, name: "#{tag} epic #{i}"})

    stack =
      Repo.insert!(%Stack{
        project_id: project.id,
        slug: "wfence-#{String.downcase(tag)}-#{i}",
        name: "#{tag} stack #{i}",
        rollup_branch: "stack/wfence-#{i}"
      })

    task =
      Repo.insert!(%Task{
        project_id: project.id,
        title: "#{tag} task #{i}",
        status: "planning",
        priority: "high",
        needs_promotion: true
      })

    member =
      Repo.insert!(%Task{
        project_id: project.id,
        stack_id: stack.id,
        stack_position: 1,
        title: "#{tag} member #{i}",
        status: "backlog",
        metadata: %{"assignee_override" => true},
        phase_assignees: %{
          "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      })

    plan = Repo.insert!(%Plan{task_id: task.id, status: "pending_review", version: 1})
    stage = Repo.insert!(%Stage{plan_id: plan.id, position: 1, name: "#{tag} stage"})
    validation = Repo.insert!(%Validation{stage_id: stage.id, kind: "manual_approval"})

    request =
      Repo.insert!(%ReviewRequest{
        validation_id: validation.id,
        task_id: task.id,
        status: "pending",
        submitted_by: "wfence"
      })

    item = Repo.insert!(%ReviewItem{review_request_id: request.id, label: "#{tag} item #{i}"})

    %{
      org: org,
      project: project,
      epic: epic,
      stack: stack,
      task: task,
      member: member,
      plan: plan,
      stage: stage,
      validation: validation,
      request: request,
      item: item
    }
  end

  # The ids a handler is fed, from one world or from nowhere.
  defp ids(w),
    do: %{
      org: w.org,
      project: w.project.id,
      epic: w.epic.id,
      stack: w.stack.id,
      task: w.task.id,
      member: w.member.id,
      plan: w.plan.id,
      item: w.item.id
    }

  defp random_ids,
    do: Map.new(~w(org project epic stack task member plan item)a, &{&1, Ecto.UUID.generate()})

  # ── snapshots ───────────────────────────────────────────────────────────

  @counted [
    Task,
    Epic,
    Project,
    Plan,
    Stack,
    ReviewItem,
    ChatPin,
    SkillAttachment,
    Message,
    CanvasAttachment
  ]

  defp row(schema, id) do
    case Repo.get(schema, id) do
      nil ->
        nil

      row ->
        row
        |> Map.from_struct()
        |> Map.drop([:__meta__])
        |> Map.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    end
  end

  defp snapshot(w) do
    %{
      rows: [
        row(Project, w.project.id),
        row(Epic, w.epic.id),
        row(Stack, w.stack.id),
        row(Task, w.task.id),
        row(Task, w.member.id),
        row(Plan, w.plan.id),
        row(Stage, w.stage.id),
        row(Validation, w.validation.id),
        row(ReviewRequest, w.request.id),
        row(ReviewItem, w.item.id)
      ],
      counts: Enum.map(@counted, &{&1, Repo.aggregate(&1, :count)})
    }
  end

  # ── driving the socket ──────────────────────────────────────────────────

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)
  defp shell(view), do: :sys.get_state(view.pid).socket.assigns

  defp open(user, path) do
    {:ok, view, _html} = live(authed(user), path)
    view
  end

  # Pre-events (edit mode, a feedback buffer) then the event under test, at
  # the component the browser would address. Returns the shell flash after
  # the component's `send(self(), ...)` report has been processed.
  defp push(view, target, pre, event, params) do
    for {e, p} <- pre, do: render_hook(at(view, target), e, p)
    html = render_hook(at(view, target), event, params)
    _ = render(view)
    {Map.drop(shell(view).flash, ["__phoenix_flash__"]), html}
  end

  defp at(view, nil), do: view
  defp at(view, target), do: with_target(view, target)

  # Fence X the way production does: drop the root membership, then deliver
  # the invalidation the ShellLive hook rebuilds `:access_scope` from.
  defp fence!(view, x, root) do
    Repo.delete_all(from(m in OrgMembership, where: m.user_id == ^x.id and m.org_id == ^root))

    send(view.pid, {:access_changed, Ecto.UUID.generate()})
    _ = render(view)
    assert Platform.Access.org_fence(shell(view).access_scope) != :unfenced
    view
  end

  setup do
    root = acme_org_id()
    s = tenant_org_id("wfence_s_#{n()}")

    m = user!("m")
    membership!(m, s)
    rm = user!("rm")
    membership!(rm, root)
    ra = user!("ra")
    membership!(ra, root, "admin")

    %{root: root, s: s, m: m, rm: rm, ra: ra}
  end

  # ── the client-id handlers (class A) ────────────────────────────────────

  # {event, target, opener, pre, params}. `opener` is :board ("/tasks") or
  # :own_task ("/tasks/<the opener's task>", for the gate panel, which only
  # renders inside an open task).
  @cases [
    {"detail_update_task_title", "#tasks-detail", :board, [{"detail_toggle_edit_mode", %{}}],
     &__MODULE__.p_title/1},
    {"detail_update_task_field", "#tasks-detail", :board, [{"detail_toggle_edit_mode", %{}}],
     &__MODULE__.p_field/1},
    {"detail_transition", "#tasks-detail", :board, [], &__MODULE__.p_transition/1},
    {"plan_approve", "#tasks-detail", :board, [], &__MODULE__.p_plan/1},
    {"plan_reject", "#tasks-detail", :board, [], &__MODULE__.p_plan/1},
    {"plan_submit_reject_with_feedback", "#tasks-detail", :board,
     [{"plan_update_reject_feedback_text", %{"value" => "needs work"}}], &__MODULE__.p_plan/1},
    {"gate_approve_item", "#tasks-gate-panel", :own_task, [], &__MODULE__.p_item/1},
    {"gate_submit_feedback", "#tasks-gate-panel", :own_task, [], &__MODULE__.p_item_feedback/1},
    {"board_promote_task", "#tasks-board", :board, [], &__MODULE__.p_id_task/1},
    {"board_drop", "#tasks-board", :board, [], &__MODULE__.p_drop/1},
    {"stack_feedback_approve_item", "#tasks-stacks", :board, [], &__MODULE__.p_id_item/1},
    {"stack_feedback_reject_item", "#tasks-stacks", :board, [], &__MODULE__.p_item_feedback/1},
    {"stack_clear_member_override", "#tasks-stacks", :board, [], &__MODULE__.p_id_member/1},
    {"sidebar_create_project", "#tasks-sidebar", :board, [], &__MODULE__.p_project/1},
    {"sidebar_create_epic", "#tasks-sidebar", :board, [], &__MODULE__.p_epic/1},
    {"taskcreate_submit", "#tasks-create", :board, [], &__MODULE__.p_create/1}
  ]

  def p_title(ids), do: %{"value" => "Renamed #{n()}", "task-id" => ids.task}
  def p_field(ids), do: %{"field" => "priority", "value" => "low", "task-id" => ids.task}
  def p_transition(ids), do: %{"id" => ids.task, "status" => "backlog"}
  def p_plan(ids), do: %{"plan-id" => ids.plan}
  def p_item(ids), do: %{"item-id" => ids.item}
  def p_item_feedback(ids), do: %{"item-id" => ids.item, "feedback" => "not yet"}
  def p_id_task(ids), do: %{"id" => ids.task}
  def p_id_item(ids), do: %{"id" => ids.item}
  def p_id_member(ids), do: %{"id" => ids.member}
  def p_drop(ids), do: %{"task_id" => ids.task, "column" => "backlog"}
  def p_project(ids), do: %{"project" => %{"name" => "Fence new #{n()}", "org_id" => ids.org}}
  def p_epic(ids), do: %{"epic" => %{"name" => "Fence epic #{n()}", "project_id" => ids.project}}

  def p_create(ids),
    do: %{
      "task" => %{
        "title" => "Fence created #{n()}",
        "project_id" => ids.project,
        "wrong" => "w",
        "what" => "x",
        "why" => "y"
      }
    }

  defp route(:board, _w), do: "/tasks"
  defp route(:own_task, w), do: "/tasks/#{w.task.id}"

  for {event, target, opener, pre, params_fun} <- @cases do
    describe "#{event}" do
      @event event
      @target target
      @opener opener
      @pre pre
      @params_fun params_fun

      test "M with the R-side id: random-UUID flash, every R row unchanged", ctx do
        r = world!(ctx.root, "R")
        own = world!(ctx.s, "S")
        before = snapshot(r)

        {fenced, _} =
          ctx.m
          |> open(route(@opener, own))
          |> push(@target, @pre, @event, @params_fun.(ids(r)))

        assert snapshot(r) == before

        {missing, _} =
          ctx.m
          |> open(route(@opener, own))
          |> push(@target, @pre, @event, @params_fun.(random_ids()))

        assert fenced == missing
        refute inspect(fenced) =~ r.task.title
      end

      test "positive control: M writes on the S-side id", ctx do
        own = world!(ctx.s, "S")
        before = snapshot(own)

        _ =
          ctx.m
          |> open(route(@opener, own))
          |> push(@target, @pre, @event, @params_fun.(ids(own)))

        assert snapshot(own) != before
      end

      test "positive control: RM and RA write on both R and S ids", ctx do
        for actor <- [ctx.rm, ctx.ra], org <- [ctx.root, ctx.s] do
          w = world!(org, "W")
          before = snapshot(w)

          _ =
            actor |> open(route(@opener, w)) |> push(@target, @pre, @event, @params_fun.(ids(w)))

          assert snapshot(w) != before, "#{@event} wrote nothing for #{actor.email} on #{org}"
        end
      end
    end
  end

  # ── create paths: every castable id is checked ──────────────────────────

  describe "taskcreate_submit epic_id / stack_id" do
    test "an R epic or R stack beside M's own project is refused like a random id", ctx do
      r = world!(ctx.root, "R")
      own = world!(ctx.s, "S")

      for {key, r_id} <- [{"epic_id", r.epic.id}, {"stack_id", r.stack.id}] do
        before = snapshot(r)
        base = p_create(ids(own))

        {fenced, _} =
          ctx.m
          |> open("/tasks")
          |> push("#tasks-create", [], "taskcreate_submit", put_in(base, ["task", key], r_id))

        assert snapshot(r) == before

        {missing, _} =
          ctx.m
          |> open("/tasks")
          |> push(
            "#tasks-create",
            [],
            "taskcreate_submit",
            put_in(base, ["task", key], Ecto.UUID.generate())
          )

        assert fenced == missing
      end
    end
  end

  describe "sidebar_create_project with no org_id" do
    test "is refused for M (it would default to the root org) and writes nothing", ctx do
      before = Repo.aggregate(Project, :count)

      {fenced, _} =
        ctx.m
        |> open("/tasks")
        |> push("#tasks-sidebar", [], "sidebar_create_project", %{
          "project" => %{"name" => "No org #{n()}"}
        })

      assert Repo.aggregate(Project, :count) == before

      {missing, _} =
        ctx.m
        |> open("/tasks")
        |> push("#tasks-sidebar", [], "sidebar_create_project", %{
          "project" => %{"name" => "Random org #{n()}", "org_id" => Ecto.UUID.generate()}
        })

      assert fenced == missing
    end

    # Not "with no org_id": on main a string-keyed submit with no org_id
    # raises in `Tasks.create_project/1` (`default_org_id/1` adds an ATOM key
    # to a string-keyed map, Ecto.CastError) and the LiveView crashes. The
    # unfenced path is left exactly as it is; this control names the org.
    test "positive control: RM creates a project in the root org", ctx do
      name = "Root project #{n()}"

      _ =
        ctx.rm
        |> open("/tasks")
        |> push("#tasks-sidebar", [], "sidebar_create_project", %{
          "project" => %{"name" => name, "org_id" => ctx.root}
        })

      assert %Project{org_id: org} = Repo.get_by(Project, name: name)
      assert org == ctx.root
    end
  end

  # ── by-id READS that put a foreign record on screen ─────────────────────

  describe "stack_open_detail (tasks.read)" do
    test "M never opens an R stack; the panel reads as for a random id", ctx do
      r = world!(ctx.root, "R")
      view = open(ctx.m, "/tasks")
      html = render_hook(at(view, "#tasks-stacks"), "stack_open_detail", %{"id" => r.stack.id})
      refute html =~ r.stack.name
      refute html =~ r.member.title

      missing =
        ctx.m
        |> open("/tasks")
        |> at("#tasks-stacks")
        |> render_hook("stack_open_detail", %{"id" => Ecto.UUID.generate()})

      assert strip_ids(html) == strip_ids(missing)
    end

    test "positive control: M opens an S stack; RM opens the R stack", ctx do
      own = world!(ctx.s, "S")
      r = world!(ctx.root, "R")

      assert ctx.m
             |> open("/tasks")
             |> at("#tasks-stacks")
             |> render_hook("stack_open_detail", %{"id" => own.stack.id}) =~ own.stack.name

      assert ctx.rm
             |> open("/tasks")
             |> at("#tasks-stacks")
             |> render_hook("stack_open_detail", %{"id" => r.stack.id}) =~ r.stack.name
    end
  end

  describe "sidebar_select_project (tasks.read)" do
    test "an R project id falls back to All Projects for M, as a random id does", ctx do
      r = world!(ctx.root, "R")
      view = open(ctx.m, "/tasks")
      render_hook(at(view, "#tasks-sidebar"), "sidebar_select_project", %{"id" => r.project.id})
      _ = render(view)
      assert shell(view).selected_project_id == nil

      own = world!(ctx.s, "S")
      render_hook(at(view, "#tasks-sidebar"), "sidebar_select_project", %{"id" => own.project.id})
      _ = render(view)
      assert shell(view).selected_project_id == own.project.id

      root_view = open(ctx.rm, "/tasks")

      render_hook(at(root_view, "#tasks-sidebar"), "sidebar_select_project", %{
        "id" => r.project.id
      })

      _ = render(root_view)
      assert shell(root_view).selected_project_id == r.project.id
    end
  end

  # Rendered markup for a stale-id no-op and a refusal is the same page; only
  # LiveView's per-mount ids and the per-socket CSRF token differ.
  defp strip_ids(html) do
    html
    |> String.replace(~r/phx-[A-Za-z0-9_-]{8,}/, "phx-ID")
    |> String.replace(~r/csrf[-_]token"? content="[^"]*"/, "csrf")
  end

  # ── server-held selection (class C) ─────────────────────────────────────

  defp agent! do
    i = n()

    %Agent{}
    |> Agent.changeset(%{slug: "wfence-agent-#{i}", name: "Fence agent #{i}", status: "active"})
    |> Repo.insert!()
  end

  # A canvas in a channel of the task's org, attached to the task.
  defp canvas!(w) do
    i = n()

    space =
      %Platform.Chat.Space{}
      |> Platform.Chat.Space.changeset(%{
        kind: "channel",
        name: "wfence-canvas-#{i}",
        slug: "wfence-canvas-#{i}",
        org_id: w.org
      })
      |> Repo.insert!()

    canvas = Repo.insert!(%Platform.Chat.Canvas{space_id: space.id, title: "wfence #{i}"})

    Repo.insert!(%CanvasAttachment{
      task_id: w.task.id,
      canvas_id: canvas.id,
      attached_by_kind: "user",
      attached_by_id: Ecto.UUID.generate()
    })

    canvas.id
  end

  defp skill! do
    {:ok, skill} = Skills.create_skill(%{name: "wfence skill #{n()}", content: "x"})
    skill
  end

  # {event, target, prep, pre, params}. `prep` puts the R task into the
  # state the handler acts on; the positive control proves the same event
  # writes for X while X is still unfenced.
  defp selection_cases(x) do
    [
      {"assign_agent", nil, fn _w -> :ok end, [], fn _w -> %{"agent_id" => agent!().id} end},
      {"save_assignees", "#tasks-assignees", fn _w -> :ok end, [],
       fn _w -> %{"assignees" => %{"all" => agent!().id}} end},
      {"detail_detach_canvas", "#tasks-detail",
       fn w -> Process.put(:wfence_canvas, canvas!(w)) end, [],
       fn _w -> %{"canvas-id" => Process.get(:wfence_canvas)} end},
      {"detail_save_description", "#tasks-detail", fn _w -> :ok end,
       [{"detail_toggle_edit_mode", %{}}], fn _w -> %{"description" => "new #{n()}"} end},
      {"detail_confirm_delete", "#tasks-detail", fn w -> set_status(w.task, "backlog") end, [],
       fn _w -> %{} end},
      {"detail_submit_reopen", "#tasks-detail",
       fn w ->
         set_status(w.task, "done")
         w.plan |> Ecto.Changeset.change(status: "approved") |> Repo.update!()
       end, [], fn _w -> %{"reason" => "again"} end},
      {"detail_attach_skill", "#tasks-detail", fn _w -> :ok end, [],
       fn _w -> %{"skill_id" => skill!().id} end},
      {"detail_detach_skill", "#tasks-detail",
       fn w ->
         skill = skill!()
         Skills.attach_skill(skill.id, "task", w.task.id)
         Process.put(:wfence_skill, skill.id)
       end, [], fn _w -> %{"skill_id" => Process.get(:wfence_skill)} end},
      {"detail_toggle_chat_pin", "#tasks-detail",
       fn w -> w.task |> Ecto.Changeset.change(sponsor_user_id: x.id) |> Repo.update!() end, [],
       fn _w -> %{} end},
      {"supersede_submit", "#tasks-supersede",
       fn w ->
         set_status(w.task, "in_progress")
         w.plan |> Ecto.Changeset.change(status: "approved") |> Repo.update!()
       end, [], fn _w -> %{"reason" => "back to planning"} end},
      {"send_steering_message", "#tasks-steering",
       fn w -> {:ok, _} = ExecutionSpace.find_or_create(w.task.id) end, [],
       fn _w -> %{"steering" => %{"text" => "steer #{n()}"}} end}
    ]
  end

  defp set_status(task, status),
    do: task |> Ecto.Changeset.change(status: status) |> Repo.update!()

  defp x!(ctx) do
    x = user!("x")
    membership!(x, ctx.s)
    membership!(x, ctx.root)
    x
  end

  describe "server-held selection" do
    test "a live scope change refuses every selection write, as with nothing selected", ctx do
      x = x!(ctx)

      # Every event is driven and every defect collected, so one broken
      # site cannot hide the next (a mutation probe names each one).
      defects =
        for {event, target, prep, pre, params} <- selection_cases(x),
            defect <- selection_refusal(ctx, x, event, target, prep, pre, params),
            do: defect

      assert defects == []
    end

    test "positive control: the same events write while X is unfenced", ctx do
      x = x!(ctx)

      silent =
        for {event, target, prep, pre, params} <- selection_cases(x),
            not selection_writes?(ctx, x, target, prep, pre, event, params),
            do: event

      assert silent == [], "wrote nothing for unfenced X: #{inspect(silent)}"
    end
  end

  defp selection_writes?(ctx, x, target, prep, pre, event, params) do
    r = world!(ctx.root, "R")
    prep.(r)
    view = open(x, "/tasks/#{r.task.id}")
    before = snapshot(r)
    _ = push(view, target, pre, event, params.(r))
    snapshot(r) != before
  end

  defp selection_refusal(ctx, x, event, target, prep, pre, params) do
    r = world!(ctx.root, "R")
    prep.(r)
    view = open(x, "/tasks/#{r.task.id}")
    true = shell(view).selected_task.id == r.task.id

    view = fence!(view, x, ctx.root)
    before = snapshot(r)
    {fenced, html} = push(view, target, pre, event, params.(r))
    wrote = if snapshot(r) == before, do: [], else: [{event, :wrote_after_fence}]

    answer =
      if event == "send_steering_message" do
        if html =~ "Task not found.", do: [], else: [{event, :no_refusal_feedback}]
      else
        # Same event with nothing selected: the branch a refusal reuses.
        {nothing, _} = ctx.m |> open("/tasks") |> push(target, pre, event, params.(r))
        if fenced == nothing, do: [], else: [{event, {:flash, fenced, nothing}}]
      end

    membership!(x, ctx.root)
    wrote ++ answer
  end

  describe "stack panel writes on @selected_stack" do
    test "a live scope change refuses abandon, start planning and save assignees", ctx do
      x = x!(ctx)

      defects =
        for {event, params} <- [
              {"stack_abandon", %{}},
              {"stack_start_planning", %{}},
              {"stack_save_assignees", %{"assignees" => %{"all" => agent!().id}}}
            ],
            defect <- stack_refusal(ctx, x, event, params),
            do: defect

      assert defects == []
    end
  end

  defp stack_refusal(ctx, x, event, params) do
    r = world!(ctx.root, "R")
    view = open(x, "/tasks")

    assert render_hook(at(view, "#tasks-stacks"), "stack_open_detail", %{"id" => r.stack.id}) =~
             r.stack.name

    view = fence!(view, x, ctx.root)
    before = snapshot(r)
    {fenced, _} = push(view, "#tasks-stacks", [], event, params)
    wrote = if snapshot(r) == before, do: [], else: [{event, :wrote_after_fence}]

    {nothing, _} = ctx.m |> open("/tasks") |> push("#tasks-stacks", [], event, params)
    answer = if fenced == nothing, do: [], else: [{event, {:flash, fenced, nothing}}]

    # Positive control on the same fixture shape: unfenced X writes.
    membership!(x, ctx.root)
    w = world!(ctx.root, "W")
    unfenced = open(x, "/tasks")
    render_hook(at(unfenced, "#tasks-stacks"), "stack_open_detail", %{"id" => w.stack.id})
    before_w = snapshot(w)
    _ = push(unfenced, "#tasks-stacks", [], event, params)
    control = if snapshot(w) != before_w, do: [], else: [{event, :control_wrote_nothing}]

    wrote ++ answer ++ control
  end

  # ── a root member's own deny is honoured (bounded, not an exception) ────

  describe "a root member holding a tasks.write deny on the target" do
    test "is refused after this change, the root admin beside them is not", ctx do
      r = world!(ctx.root, "R")

      {:ok, _} = Grants.deny(%{principal: ctx.rm, permission: "tasks.write", resource: r.project})

      before = snapshot(r)
      _ = ctx.rm |> open("/tasks") |> push("#tasks-board", [], "board_drop", p_drop(ids(r)))
      assert snapshot(r) == before

      _ = ctx.ra |> open("/tasks") |> push("#tasks-board", [], "board_drop", p_drop(ids(r)))
      assert snapshot(r) != before
    end
  end

  # ── class B: already gated, one refusal test each ───────────────────────

  describe "already-gated handlers refuse M" do
    test "detail_promote_from_quarantine on an R quarantined task", ctx do
      r = world!(ctx.root, "R")

      task =
        r.task
        |> Ecto.Changeset.change(
          origin: "external_feedback",
          trust: "quarantined",
          external_repository_identity: "Startup-Suite/feedback",
          external_issue_number: n()
        )
        |> Repo.update!()

      before = row(Task, task.id)

      {flash, _} =
        ctx.m
        |> open("/tasks")
        |> push("#tasks-detail", [], "detail_promote_from_quarantine", %{"id" => task.id})

      assert row(Task, task.id) == before
      assert flash["error"] == "Task not found."
    end

    test "archive_container on the R project", ctx do
      r = world!(ctx.root, "R")
      before = row(Project, r.project.id)

      _ =
        ctx.m
        |> open("/tasks")
        |> push(nil, [], "archive_container", %{"type" => "project", "id" => r.project.id})

      assert row(Project, r.project.id) == before
    end

    test "confirm_schedule_deletion on the R project", ctx do
      r = world!(ctx.root, "R")
      before = row(Project, r.project.id)

      _ =
        ctx.m
        |> open("/tasks")
        |> push(
          nil,
          [
            {"open_delete_modal",
             %{"type" => "project", "id" => r.project.id, "name" => r.project.name}}
          ],
          "confirm_schedule_deletion",
          %{}
        )

      assert row(Project, r.project.id) == before
    end

    test "undo_archive with nothing archived is a no-op for M", ctx do
      r = world!(ctx.root, "R")
      before = snapshot(r)
      _ = ctx.m |> open("/tasks") |> push(nil, [], "undo_archive", %{})
      assert snapshot(r) == before
    end
  end

  describe "guests" do
    # The HTTP request is refused by the plug with a 403 page; the in-session
    # live_redirect is ModuleGate's redirect, pinned by
    # PlatformWeb.GuestLiveRedirectTasksTest. Both are unchanged here.
    test "/tasks is still refused to a guest", ctx do
      r = world!(ctx.s, "S")
      g = user!("guest")
      {:ok, _} = Platform.Tenancy.mark_membership_external(%{user_id: g.id, org_id: ctx.s})

      conn = get(authed(g), "/tasks")
      assert conn.status == 403
      refute conn.resp_body =~ r.task.title
    end
  end
end
