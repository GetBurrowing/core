defmodule Platform.Agents.SlugCollisionRegressionTest do
  @moduledoc """
  One regression test per request-path `Repo.get_by(Agent, slug: ...)` site
  (task 01a0e77c stage 2), each driven through the site's PUBLIC entry point.

  The collision fixture is two agents sharing one slug in two DISTINCT
  NON-NIL workspaces. Against the old code every site below raised
  `Ecto.MultipleResultsError` (DispatchMembership's own `rescue` turned it
  into `{:skip, {:raised, msg}}`, and ReviewRequests' outer `rescue` swallowed
  the inbox row). Each test asserts the site's fail-closed shape instead, and
  a sibling test pins the single-agent happy path so the fix is not "never
  resolve anything".

  Non-nil workspaces on purpose: once `agents_unique_slug` is NULLS NOT
  DISTINCT (stage 4), two NULL-workspace rows with one slug are uninsertable.
  The NULL-workspace ambiguity arms live in
  `Platform.Agents.SlugCollisionNullWorkspaceTest` below.

  async: false because AgentServer registers runtimes by slug and the
  WorkspaceBootstrap/Orchestration paths start supervised processes.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.{
    Agent,
    AgentServer,
    Config,
    Orchestration,
    Router,
    WorkspaceBootstrap
  }

  alias Platform.Chat
  alias Platform.Chat.DispatchMembership
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequests}

  defp uniq, do: System.unique_integer([:positive, :monotonic])

  defp insert_agent!(attrs) do
    %Agent{}
    |> Agent.changeset(
      Map.merge(
        %{
          name: "Agent #{uniq()}",
          status: "active",
          model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  # Two agents, one slug, two distinct non-nil workspaces. Lower-case so the
  # chat mention path (which downcases tokens) sees the same string.
  defp collide! do
    slug = "collide-#{uniq()}"
    a = insert_agent!(%{slug: slug, workspace_id: Ecto.UUID.generate(), name: "Collide A"})
    b = insert_agent!(%{slug: slug, workspace_id: Ecto.UUID.generate(), name: "Collide B"})
    %{slug: slug, a: a, b: b}
  end

  defp solo! do
    insert_agent!(%{slug: "solo-#{uniq()}", name: "Solo Agent"})
  end

  defp insert_user!(attrs \\ %{}) do
    n = uniq()

    Repo.insert!(
      struct(
        Platform.Accounts.User,
        Map.merge(
          %{name: "User #{n}", email: "user-#{n}@example.com", oidc_sub: "sub-#{n}"},
          attrs
        )
      )
    )
  end

  # Runs `fun` and returns {result, captured_warning_log}.
  defp with_warning_log(fun) do
    ref = make_ref()
    log = capture_log([level: :warning], fn -> send(self(), {ref, fun.()}) end)

    receive do
      {^ref, result} -> {result, log}
    after
      0 -> flunk("function did not return")
    end
  end

  describe "premise" do
    test "the collision fixture makes a bare Repo.get_by(Agent, slug:) raise" do
      %{slug: slug} = collide!()
      assert_raise Ecto.MultipleResultsError, fn -> Repo.get_by(Agent, slug: slug) end
    end
  end

  # ── 1. Chat.resolve_agent/1 via find_or_create_agent_dm/2 ─────────────────

  describe "Chat.find_or_create_agent_dm/2 (resolve_agent/1)" do
    test "an ambiguous slug is :agent_not_found, not a raise" do
      %{slug: slug} = collide!()
      user = insert_user!()

      {result, log} = with_warning_log(fn -> Chat.find_or_create_agent_dm(slug, user.id) end)

      assert result == {:error, :agent_not_found}
      assert log =~ slug
    end

    test "a unique slug still resolves" do
      agent = solo!()
      user = insert_user!()

      assert {:ok, space} = Chat.find_or_create_agent_dm(agent.slug, user.id)
      assert space.kind == "dm"
    end
  end

  # ── 2. Chat.resolve_pin_target/1 via a sponsor @-mention ──────────────────

  describe "Chat.post_message/1 sponsor mention (resolve_pin_target/1)" do
    setup do
      alias Platform.Tasks.ChatPins

      {:ok, project} = Tasks.create_project(%{name: "Pin #{uniq()}"})
      sponsor = insert_user!()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Pin task",
          sponsor_user_id: sponsor.id
        })

      {:ok, %{space: exec_space}} =
        ChatPins.pin(task.id, %{kind: "user", id: sponsor.email}, sponsor.email)

      {:ok, sponsor_p} =
        Chat.add_participant(exec_space.id, %{
          participant_type: "user",
          participant_id: sponsor.id,
          display_name: sponsor.name,
          joined_at: DateTime.utc_now()
        })

      %{task: task, exec_space: exec_space, sponsor_p: sponsor_p}
    end

    defp agent_pin_count(task_id, slug) do
      import Ecto.Query

      Repo.aggregate(
        from(p in Platform.Tasks.ChatPin,
          where:
            p.task_id == ^task_id and p.participant_kind == "agent" and
              p.participant_id == ^slug
        ),
        :count
      )
    end

    test "mentioning an ambiguous slug posts the message and pins no agent", ctx do
      %{slug: slug} = collide!()

      {result, log} =
        with_warning_log(fn ->
          Chat.post_message(%{
            space_id: ctx.exec_space.id,
            participant_id: ctx.sponsor_p.id,
            content_type: "text",
            content: "over to @[#{slug}]"
          })
        end)

      assert {:ok, _msg} = result
      assert agent_pin_count(ctx.task.id, slug) == 0
      assert log =~ slug
    end

    test "mentioning a unique slug still pins the agent", ctx do
      agent = solo!()

      assert {:ok, _msg} =
               Chat.post_message(%{
                 space_id: ctx.exec_space.id,
                 participant_id: ctx.sponsor_p.id,
                 content_type: "text",
                 content: "over to @[#{agent.slug}]"
               })

      assert agent_pin_count(ctx.task.id, agent.slug) == 1
    end
  end

  # ── 3. Orchestration.fetch_agent/1 and find_agent_by_workspace_slug/2 ─────

  describe "Orchestration (fetch_agent/1, find_agent_by_workspace_slug/2)" do
    defp start_agent!(agent) do
      {:ok, pid} = AgentServer.start_agent(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      on_exit(fn -> AgentServer.stop_agent(agent) end)
      pid
    end

    test "complete_child/5 with an ambiguous parent slug is {:error, :ambiguous_slug}" do
      %{slug: slug} = collide!()

      {result, log} =
        with_warning_log(fn ->
          Orchestration.complete_child(slug, Ecto.UUID.generate(), slug, Ecto.UUID.generate())
        end)

      assert result == {:error, :ambiguous_slug}
      assert log =~ slug
    end

    test "spawn_child/4 with an ambiguous parent slug is {:error, :ambiguous_slug}" do
      %{slug: slug} = collide!()

      {result, _log} =
        with_warning_log(fn ->
          Orchestration.spawn_child(slug, Ecto.UUID.generate(), %{slug: "child-#{uniq()}"})
        end)

      assert result == {:error, :ambiguous_slug}
    end

    test "a NULL-workspace parent reusing a child slug only looks in the NULL workspace" do
      # The child slug collides across two OTHER (non-nil) workspaces. The old
      # nil head of find_agent_by_workspace_slug/2 was an UNSCOPED get_by and
      # raised here; the parent's own workspace (NULL) has no such agent, so a
      # fresh child is created there.
      %{slug: child_slug, a: a, b: b} = collide!()
      parent = insert_agent!(%{slug: "parent-#{uniq()}", max_concurrent: 2})
      start_agent!(parent)

      {:ok, parent_session, _} = AgentServer.start_session(parent.id, [])

      assert {:ok, result} =
               Orchestration.spawn_child(parent.id, parent_session.id, %{
                 slug: child_slug,
                 name: "Child"
               })

      on_exit(fn -> AgentServer.stop_agent(result.agent) end)

      assert result.created?
      assert result.agent.slug == child_slug
      assert is_nil(result.agent.workspace_id)
      refute result.agent.id in [a.id, b.id]
    end

    test "a NULL-workspace parent reuses an existing NULL-workspace child by slug" do
      parent = insert_agent!(%{slug: "parent-#{uniq()}", max_concurrent: 2})
      existing = insert_agent!(%{slug: "reuse-#{uniq()}"})
      start_agent!(parent)

      {:ok, parent_session, _} = AgentServer.start_session(parent.id, [])

      assert {:ok, result} =
               Orchestration.spawn_child(parent.id, parent_session.id, %{slug: existing.slug})

      on_exit(fn -> AgentServer.stop_agent(result.agent) end)

      refute result.created?
      assert result.agent.id == existing.id
    end
  end

  # ── 4. Router.fetch_agent/1 ───────────────────────────────────────────────

  describe "Router.model_chain/2 (fetch_agent/1)" do
    test "an ambiguous slug is {:error, :ambiguous_slug}" do
      %{slug: slug} = collide!()

      {result, log} = with_warning_log(fn -> Router.model_chain(slug) end)

      assert result == {:error, :ambiguous_slug}
      assert log =~ slug
    end

    test "a unique slug still resolves" do
      agent = solo!()
      assert {:ok, [_ | _]} = Router.model_chain(agent.slug)
    end
  end

  # ── 5. AgentServer.fetch_agent/1 ──────────────────────────────────────────

  describe "AgentServer.start_agent/2 (fetch_agent/1)" do
    test "an ambiguous slug is {:error, :ambiguous_slug}" do
      %{slug: slug} = collide!()

      {result, log} = with_warning_log(fn -> AgentServer.start_agent(slug) end)

      assert result == {:error, :ambiguous_slug}
      assert log =~ slug
    end

    test "a unique slug still starts the runtime" do
      agent = solo!()
      assert {:ok, pid} = AgentServer.start_agent(agent.slug)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      on_exit(fn -> AgentServer.stop_agent(agent) end)
      assert AgentServer.whereis(agent.id) == pid
    end
  end

  # ── 6. Config.fetch_agent/1 ───────────────────────────────────────────────

  describe "Config.export_config/2 (fetch_agent/1)" do
    test "an ambiguous slug is {:error, :ambiguous_slug}" do
      %{slug: slug} = collide!()

      {result, log} = with_warning_log(fn -> Config.export_config(slug) end)

      assert result == {:error, :ambiguous_slug}
      assert log =~ slug
    end

    test "a unique slug still exports" do
      agent = solo!()
      assert {:ok, %{} = config} = Config.export_config(agent.slug)
      assert inspect(config) =~ agent.slug
    end
  end

  # ── 7. DispatchMembership.resolve_agent/1 ─────────────────────────────────

  describe "DispatchMembership.ensure_writable/3 (resolve_agent/1)" do
    defp channel! do
      n = uniq()

      {:ok, space} =
        Chat.create_space(%{name: "Collide #{n}", slug: "collide-#{n}", kind: "channel"})

      space
    end

    test "an ambiguous slug is {:skip, :ambiguous_agent_slug}" do
      %{slug: slug} = collide!()
      space = channel!()

      {result, log} =
        with_warning_log(fn -> DispatchMembership.ensure_writable(space.id, slug) end)

      assert result == {:skip, :ambiguous_agent_slug}
      assert log =~ slug
    end

    test "a unique slug is still invited" do
      agent = solo!()
      space = channel!()
      assert {:ok, :invited} = DispatchMembership.ensure_writable(space.id, agent.slug)
    end
  end

  # ── 8. ReviewRequests.fetch_agent_for_display/1 ───────────────────────────

  describe "ReviewRequests requester display (fetch_agent_for_display/1)" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Review #{uniq()}"})
      sponsor = insert_user!()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Review task",
          sponsor_user_id: sponsor.id
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      %{sponsor: sponsor, task: task, plan: plan}
    end

    defp requested_by(ctx, submitted_by) do
      {:ok, stage} =
        Tasks.create_stage(%{plan_id: ctx.plan.id, position: uniq(), name: "UI #{uniq()}"})

      {:ok, _} = PlanEngine.start_stage(stage.id)
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, _request} =
        ReviewRequests.create_review_request(%{
          validation_id: validation.id,
          task_id: ctx.task.id,
          submitted_by: submitted_by,
          items: [%{label: "Evidence"}]
        })

      case Platform.Inbox.list_unread_for_user(ctx.sponsor.id, kind: "review_request_pending") do
        [row | _] ->
          Platform.Inbox.mark_dismissed(row.id, ctx.sponsor.id)
          "Requested by " <> requester = row.body
          requester

        [] ->
          flunk("no review_request_pending inbox row for submitted_by=#{inspect(submitted_by)}")
      end
    end

    test "an ambiguous slug falls through to the raw id", ctx do
      %{slug: slug} = collide!()

      {result, log} = with_warning_log(fn -> requested_by(ctx, slug) end)

      assert result == slug
      refute log =~ "failed to emit sponsor inbox row"
    end

    test "a unique slug still renders the agent's name", ctx do
      agent = solo!()
      assert requested_by(ctx, agent.slug) == "Solo Agent"
    end
  end

  # ── 9. Meetings.resolve_agent/1 ───────────────────────────────────────────

  describe "Meetings.generate_agent_token/3 (resolve_agent/1)" do
    test "an ambiguous slug is {:error, :agent_not_found}" do
      %{slug: slug} = collide!()

      {result, log} =
        with_warning_log(fn -> Meetings.generate_agent_token(slug, "room-#{uniq()}", []) end)

      assert result == {:error, :agent_not_found}
      assert log =~ slug
    end

    test "a unique slug resolves past the lookup" do
      agent = solo!()
      result = Meetings.generate_agent_token(agent.slug, "room-#{uniq()}", [])
      assert match?({:ok, _}, result) or result == {:error, :livekit_not_configured}
    end
  end

  # ── 10. WorkspaceBootstrap.status/1 and upsert_agent!/2 ───────────────────

  describe "WorkspaceBootstrap (status/1, upsert_agent!/2)" do
    test "a slug colliding in OTHER workspaces does not break status/1 or ensure_agent/1" do
      %{slug: slug, a: a, b: b} = collide!()
      workspace = write_workspace!(slug)

      status = WorkspaceBootstrap.status(workspace_path: workspace)
      assert status.configured?
      assert status.agent == nil
      assert status.error == nil

      assert {:ok, %Agent{} = agent} = WorkspaceBootstrap.ensure_agent(workspace_path: workspace)
      assert agent.slug == slug
      assert is_nil(agent.workspace_id)
      refute agent.id in [a.id, b.id]

      assert WorkspaceBootstrap.status(workspace_path: workspace).agent.id == agent.id
    end
  end

  @doc false
  def write_workspace!(slug) do
    path = Platform.TestTemp.path("slug-collision-ws-#{uniq()}")
    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)

    openclaw = %{
      "agents" => %{
        "list" => [
          %{
            "id" => slug,
            "name" => "Zip",
            "model" => %{"primary" => "anthropic/claude-sonnet-4-6"},
            "tools" => %{"profile" => "minimal"}
          }
        ]
      }
    }

    File.write!(Path.join(path, "openclaw.json"), Jason.encode!(openclaw))
    File.write!(Path.join(path, "SOUL.md"), "steady")
    path
  end
end

defmodule Platform.Agents.SlugCollisionNullWorkspaceTest do
  @moduledoc """
  The NULL-workspace ambiguity arms of `Platform.Agents.WorkspaceBootstrap`
  (task 01a0e77c stage 2).

  WorkspaceBootstrap scopes its lookup to the parsed agent's own workspace,
  which for an `openclaw.json` import is always NULL. Two NULL-workspace rows
  with one slug are exactly what `agents_unique_slug` failed to prevent while
  it was NULLS DISTINCT, and what it forbids once it is NULLS NOT DISTINCT. To
  reach the ambiguity arm regardless of which index is live, each test drops
  the index INSIDE its sandbox transaction; the drop is rolled back with the
  test. async: false so no concurrent test waits on the table lock.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.{Agent, WorkspaceBootstrap}
  alias Platform.Agents.SlugCollisionRegressionTest, as: Helpers
  alias Platform.Repo

  setup do
    Repo.query!("DROP INDEX agents_unique_slug")
    slug = "nullcollide-#{System.unique_integer([:positive, :monotonic])}"

    for name <- ["Null A", "Null B"] do
      %Agent{} |> Agent.changeset(%{slug: slug, name: name, status: "active"}) |> Repo.insert!()
    end

    %{slug: slug, workspace: Helpers.write_workspace!(slug)}
  end

  test "status/1 reports the ambiguity instead of raising", %{slug: slug, workspace: workspace} do
    log =
      capture_log([level: :warning], fn ->
        status = WorkspaceBootstrap.status(workspace_path: workspace)
        send(self(), {:status, status})
      end)

    assert_received {:status, status}
    assert status.agent == nil
    assert status.error == {:ambiguous_slug, slug}
    assert log =~ slug
  end

  test "ensure_agent/1 raises an ArgumentError naming the slug, updating neither row", %{
    slug: slug,
    workspace: workspace
  } do
    capture_log([level: :warning], fn ->
      error =
        assert_raise ArgumentError, fn ->
          WorkspaceBootstrap.ensure_agent(workspace_path: workspace)
        end

      assert Exception.message(error) =~ slug
    end)

    import Ecto.Query
    names = Repo.all(from(a in Agent, where: a.slug == ^slug, select: a.name, order_by: a.name))
    assert names == ["Null A", "Null B"]
  end
end
