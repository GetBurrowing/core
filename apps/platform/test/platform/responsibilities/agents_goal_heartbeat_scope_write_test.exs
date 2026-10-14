defmodule Platform.Responsibilities.AgentsGoalHeartbeatScopeWriteTest do
  @moduledoc """
  Task `01a0cef1` stage 1: the goal-scope WRITE path.

  `AgentsGoalHeartbeat.goal_scope_projects/1` lists the projects a
  channel's org can see, `put_goal_scope/2` resolves a submitted scope
  against that list, and `Sidebar.save_goal/3` writes goal text and scope
  in one update onto a freshly re-read space.

  Fixture (seeded orgs: R = "acme" root, A = "soylent", B = "wayne_tech"):
  P1 (A: 2 open + 1 done + 1 cancelled), P2 (A: 5 open), PF (B: 3 open),
  PR (R: 1 open), P_arch (A, archived, 4 open). No migration seeds
  projects or tasks, so the sandbox holds exactly these and the
  install-wide open count is 2 + 5 + 3 + 1 + 4 = 15.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat, as: Handler
  alias Platform.Tasks
  alias Platform.Tenancy

  @goal "Close backlog items"

  setup do
    r = Tenancy.get_org_by_slug!("acme")
    a = Tenancy.get_org_by_slug!("soylent")
    b = Tenancy.get_org_by_slug!("wayne_tech")
    n = System.unique_integer([:positive])

    p1 = project!("P1 #{n}", a)
    p2 = project!("P2 #{n}", a)
    pf = project!("PF #{n}", b)
    pr = project!("PR #{n}", r)
    p_arch = project!("P_arch #{n}", a)

    for _ <- 1..2, do: task!(p1, "backlog")
    task!(p1, "done")
    task!(p1, "cancelled")
    for _ <- 1..5, do: task!(p2, "in_progress")
    for _ <- 1..3, do: task!(pf, "backlog")
    task!(pr, "backlog")
    for _ <- 1..4, do: task!(p_arch, "backlog")

    {:ok, p_arch} = Tasks.update_project(p_arch, %{archived_at: DateTime.utc_now()})

    %{r: r, a: a, b: b, p1: p1, p2: p2, pf: pf, pr: pr, p_arch: p_arch}
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp project!(name, org) do
    {:ok, project} = Tasks.create_project(%{name: name, org_id: org.id})
    project
  end

  defp task!(project, status) do
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "t #{status}", status: status})

    task
  end

  defp space!(org_id, metadata \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Goal scope #{n}",
        slug: "goal-scope-#{n}",
        kind: "channel",
        goal: @goal,
        org_id: org_id,
        metadata: metadata
      })

    space
  end

  defp reload!(space), do: Repo.get!(Space, space.id)

  defp ids(projects), do: Enum.map(projects, & &1.id)

  # ── (a) options ──────────────────────────────────────────────────────

  test "(a) the options are the live projects the channel's org can see", ctx do
    assert ids(Handler.goal_scope_projects(space!(ctx.a.id))) == [ctx.p1.id, ctx.p2.id]

    assert ids(Handler.goal_scope_projects(space!(ctx.r.id))) ==
             [ctx.p1.id, ctx.p2.id, ctx.pf.id, ctx.pr.id]

    assert Handler.goal_scope_projects(space!(nil)) == []
  end

  # ── (b) a saved scope is what measure/2 counts ───────────────────────

  test "(b) saving P1 then P2 writes the id and measure/2 counts that project", ctx do
    space = space!(ctx.a.id)

    assert {:ok, saved} = Sidebar.save_goal(space, @goal, ctx.p1.id)
    assert reload!(space).metadata["goal_project_id"] == ctx.p1.id
    slot = Handler.measure(reload!(space), @goal)
    assert slot.value == 2
    assert slot.unit == "open tasks in #{ctx.p1.name}"

    assert {:ok, _} = Sidebar.save_goal(saved, @goal, ctx.p2.id)
    assert reload!(space).metadata["goal_project_id"] == ctx.p2.id
    assert Handler.measure(reload!(space), @goal).value == 5
  end

  # ── (c) clearing returns to install-wide ─────────────────────────────

  test "(c) clearing removes the key and the count is install-wide", ctx do
    space = space!(ctx.a.id, %{"goal_project_id" => ctx.p1.id})

    assert {:ok, _} = Sidebar.save_goal(space, @goal, "")
    refute Map.has_key?(reload!(space).metadata, "goal_project_id")

    slot = Handler.measure(reload!(space), @goal)
    assert slot.value == 15
    assert slot.unit == "open tasks"
  end

  # ── (d) refusals write nothing ───────────────────────────────────────

  test "(d) a foreign, unknown, malformed or archived id is refused and nothing is written",
       ctx do
    space = space!(ctx.a.id)
    before = reload!(space)

    for raw <- [ctx.pf.id, "not-a-uuid", Ecto.UUID.generate(), ctx.p_arch.id] do
      assert {:error, :unknown_project} = Sidebar.save_goal(space, "Changed goal", raw)
      after_refusal = reload!(space)
      assert after_refusal.goal == @goal
      assert after_refusal.metadata == before.metadata
    end

    # Positive control: the same space accepts an in-org project.
    assert {:ok, saved} = Sidebar.save_goal(space, "Changed goal", ctx.p1.id)
    assert saved.goal == "Changed goal"
    assert reload!(space).metadata["goal_project_id"] == ctx.p1.id
  end

  # ── (e) a scope change is a first measurement ────────────────────────

  test "(e) a saved scope change resets the delta to a first measurement", ctx do
    space = space!(ctx.a.id)
    {:ok, _} = Sidebar.save_goal(space, @goal, ctx.p1.id)

    first = Handler.gather_context(%{}).measurement
    assert first.value == 2

    {:ok, _} = Sidebar.save_goal(space, @goal, ctx.p2.id)
    second = Handler.gather_context(%{}).measurement
    assert second.value == 5
    assert second.delta == nil
    assert Handler.format_measurement(second) =~ "first measurement"
  end

  test "(e control) the same scope gathered twice carries an integer delta", ctx do
    space = space!(ctx.a.id)
    {:ok, _} = Sidebar.save_goal(space, @goal, ctx.p1.id)

    _ = Handler.gather_context(%{})
    again = Handler.gather_context(%{}).measurement
    assert is_integer(again.delta)
    assert again.delta == 0
  end

  # ── (f) an unchanged legacy value round-trips ────────────────────────

  test "(f) an unchanged server-set scope outside the options is preserved", ctx do
    space = space!(ctx.a.id)

    {:ok, space} =
      Chat.update_space(space, %{metadata: %{"goal_project_id" => ctx.pf.id}})

    refute ctx.pf.id in ids(Handler.goal_scope_projects(space))

    assert {:ok, saved} = Sidebar.save_goal(space, "Close backlog items in Suite", ctx.pf.id)
    assert saved.goal == "Close backlog items in Suite"
    assert reload!(space).metadata["goal_project_id"] == ctx.pf.id
  end

  # ── (g) a stale struct does not clobber the baseline ─────────────────

  test "(g) saving from a pre-baseline struct keeps the recorded baseline", ctx do
    space = space!(ctx.a.id)
    {:ok, pre_baseline} = Sidebar.save_goal(space, @goal, ctx.p1.id)
    refute Map.has_key?(pre_baseline.metadata, "goal_heartbeat")

    _ = Handler.gather_context(%{})
    recorded = reload!(space).metadata["goal_heartbeat"]
    assert recorded["measurement"] == 2

    assert {:ok, _} = Sidebar.save_goal(pre_baseline, @goal, ctx.p2.id)
    assert reload!(space).metadata["goal_heartbeat"] == recorded
    assert reload!(space).metadata["goal_project_id"] == ctx.p2.id
  end
end
