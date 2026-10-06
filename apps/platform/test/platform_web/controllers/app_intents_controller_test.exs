defmodule PlatformWeb.AppIntentsControllerTest do
  @moduledoc """
  Task 01a10db6 stage 1: the App Intents JSON surface under `/api/app`.
  """
  # async: false: Inbox.emit fans out to push delivery processes.
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.ExternalUserFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Meetings.Meeting
  alias Platform.Mobile
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.ReviewItem
  alias Platform.Tasks.ReviewRequests

  # Every route this stage adds, each with a request that would otherwise be
  # well-formed. `:space_id` / `:id` are substituted per test.
  @protected_routes [
    {:get, "/api/app/approvals", %{}},
    {:post, "/api/app/approvals/:id/approve", %{}},
    {:post, "/api/app/approvals/:id/reject", %{"feedback" => "no"}},
    {:get, "/api/app/tasks", %{}},
    {:get, "/api/app/meetings", %{}},
    {:post, "/api/app/meetings", %{}},
    {:get, "/api/app/agents", %{}},
    {:post, "/api/app/agents/:id/dm", %{}},
    {:get, "/api/app/spaces/:space_id/messages", %{}}
  ]

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp app_session!(user) do
    {verifier, challenge} = pkce()
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, result} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})
    result
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp agent!(name) do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "intent-agent-#{n}", name: "#{name} #{n}", status: "active"})
  end

  defp project! do
    {:ok, project} =
      Tasks.create_project(%{name: "Intents #{System.unique_integer([:positive])}"})

    project
  end

  defp sponsored_task!(user, title \\ "Intent task") do
    {:ok, task} =
      Tasks.create_task(%{project_id: project!().id, title: title, sponsor_user_id: user.id})

    task
  end

  defp pending_plan!(task) do
    %Plan{}
    |> Plan.changeset(%{task_id: task.id, version: 1, status: "pending_review"})
    |> Repo.insert!()
  end

  defp plan_item!(user, task) do
    {:ok, item} =
      Inbox.emit(%{
        user_id: user.id,
        kind: "task_plan_review",
        source_type: "task",
        source_id: task.id,
        title: "Plan ready for review: #{task.title}",
        body: "Planner: P · Stages: 1 · Validations: 2",
        url: "/tasks/#{task.id}"
      })

    item
  end

  defp review_request!(task, labels) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI"})
    {:ok, _} = Tasks.PlanEngine.start_stage(stage.id)

    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    {:ok, request} =
      ReviewRequests.create_review_request(%{
        validation_id: validation.id,
        task_id: task.id,
        items: Enum.map(labels, &%{label: &1})
      })

    request
  end

  # `create_review_request/1` already emits the sponsor's rollup row; reuse
  # it, and emit one only when the task has no request behind it.
  defp review_item!(user, task) do
    existing =
      Repo.one(
        from(i in Item,
          where:
            i.user_id == ^user.id and i.source_type == "task_review" and
              i.source_id == ^task.id and is_nil(i.dismissed_at)
        )
      )

    existing || emit_review_item!(user, task)
  end

  defp emit_review_item!(user, task) do
    {:ok, item} =
      Inbox.emit(%{
        user_id: user.id,
        kind: "review_request_pending",
        source_type: "task_review",
        source_id: task.id,
        title: "Review awaiting you: #{task.title}",
        body: "Requested by someone",
        url: "/tasks/#{task.id}"
      })

    item
  end

  defp request(conn, {method, path, params}, ids) do
    path =
      path
      |> String.replace(":space_id", ids.space_id)
      |> String.replace(":id", ids.id)

    dispatch(conn, @endpoint, method, path, params)
  end

  setup %{conn: conn} do
    user = create_user!()
    space = channel!()
    add_user!(space.id, user.id)
    %{token: token} = app_session!(user)
    %{conn: conn, user: user, space: space, token: token}
  end

  describe "401 on every route this stage adds" do
    test "with no bearer, and with a garbage bearer", %{conn: conn, space: space} do
      ids = %{space_id: space.id, id: Ecto.UUID.generate()}

      for route <- @protected_routes, auth <- [nil, "not-a-real-token"] do
        conn = if auth, do: bearer(conn, auth), else: conn
        conn = request(conn, route, ids)
        assert json_response(conn, 401) == %{"error" => "unauthorized"}, inspect({route, auth})
      end
    end
  end

  describe "GET /api/app/approvals" do
    test "lists exactly what the widget counts", %{conn: conn, token: token, user: user} do
      plan_task = sponsored_task!(user, "Plan me")
      pending_plan!(plan_task)
      plan_item = plan_item!(user, plan_task)

      review_task = sponsored_task!(user, "Review me")
      review_item = review_item!(user, review_task)

      # Not an approval kind, and another user's approval: neither counts.
      {:ok, _} =
        Inbox.emit(%{
          user_id: user.id,
          kind: "chat_mention",
          source_type: "chat_message",
          source_id: Ecto.UUID.generate(),
          title: "mention"
        })

      other = create_user!()
      plan_item!(other, sponsored_task!(other))

      approvals =
        conn
        |> bearer(token)
        |> get("/api/app/approvals")
        |> json_response(200)
        |> Map.fetch!("approvals")

      %{approvals: count} = Mobile.counts_for_user(user)
      assert length(approvals) == count
      assert count == 2

      by_id = Map.new(approvals, &{&1["id"], &1})
      assert %{"kind" => "plan", "title" => "Plan me"} = plan = by_id[plan_item.id]
      assert plan["task_id"] == plan_task.id
      assert plan["summary"] == "Planner: P · Stages: 1 · Validations: 2"
      assert Map.has_key?(plan, "space_name")
      assert Map.has_key?(plan, "space_path_segment")
      assert %{"kind" => "review", "summary" => nil} = by_id[review_item.id]
    end
  end

  describe "POST /api/app/approvals/:id/approve" do
    test "approves a plan, clears the inbox row, and a second call is 409", %{
      conn: conn,
      token: token,
      user: user
    } do
      task = sponsored_task!(user)
      plan = pending_plan!(task)
      item = plan_item!(user, task)

      conn1 = conn |> bearer(token) |> post("/api/app/approvals/#{item.id}/approve")
      assert json_response(conn1, 200) == %{"status" => "approved"}

      assert %Plan{status: "approved", approved_by: approved_by} = Repo.get!(Plan, plan.id)
      assert approved_by == user.id
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, item.id)
      assert Mobile.counts_for_user(user).approvals == 0

      conn2 = conn |> bearer(token) |> post("/api/app/approvals/#{item.id}/approve")
      assert json_response(conn2, 409) == %{"error" => "already_handled", "by" => user.name}
    end

    test "another user's item is 404 and changes nothing", %{conn: conn, token: token} do
      other = create_user!()
      task = sponsored_task!(other)
      plan = pending_plan!(task)
      item = plan_item!(other, task)

      for action <- ~w(approve reject) do
        conn =
          conn
          |> bearer(token)
          |> post("/api/app/approvals/#{item.id}/#{action}", %{"feedback" => "no"})

        assert json_response(conn, 404) == %{"error" => "not_found"}
      end

      assert Repo.get!(Plan, plan.id).status == "pending_review"
      assert %Item{dismissed_at: nil} = Repo.get!(Item, item.id)
    end

    test "an unknown or malformed id is 404", %{conn: conn, token: token} do
      for id <- [Ecto.UUID.generate(), "nope"] do
        conn = conn |> bearer(token) |> post("/api/app/approvals/#{id}/approve")
        assert json_response(conn, 404) == %{"error" => "not_found"}
      end
    end

    test "approves every pending item of a review, then 409", %{
      conn: conn,
      token: token,
      user: user
    } do
      task = sponsored_task!(user)
      request = review_request!(task, ["Desktop", "Mobile"])
      item = review_item!(user, task)

      conn1 = conn |> bearer(token) |> post("/api/app/approvals/#{item.id}/approve")
      assert json_response(conn1, 200) == %{"status" => "approved"}

      statuses =
        Repo.all(
          from(ri in ReviewItem,
            where: ri.review_request_id == ^request.id,
            select: {ri.status, ri.reviewed_by}
          )
        )

      assert statuses == [{"approved", user.id}, {"approved", user.id}]
      refute ReviewRequests.task_has_pending_reviews?(task.id)

      conn2 = conn |> bearer(token) |> post("/api/app/approvals/#{item.id}/approve")
      assert %{"error" => "already_handled"} = json_response(conn2, 409)
    end
  end

  describe "POST /api/app/approvals/:id/reject" do
    test "a review reject with blank feedback is 422 and changes nothing", %{
      conn: conn,
      token: token,
      user: user
    } do
      task = sponsored_task!(user)
      request = review_request!(task, ["Desktop"])
      item = review_item!(user, task)

      for params <- [%{}, %{"feedback" => "   "}] do
        conn = conn |> bearer(token) |> post("/api/app/approvals/#{item.id}/reject", params)
        assert json_response(conn, 422) == %{"error" => "feedback_required"}
      end

      assert [%ReviewItem{status: "pending"}] =
               Repo.all(from(ri in ReviewItem, where: ri.review_request_id == ^request.id))
    end

    test "a review reject with feedback marks items needs_revision", %{
      conn: conn,
      token: token,
      user: user
    } do
      task = sponsored_task!(user)
      request = review_request!(task, ["Desktop", "Mobile"])
      item = review_item!(user, task)

      conn =
        conn
        |> bearer(token)
        |> post("/api/app/approvals/#{item.id}/reject", %{"feedback" => "Header overlaps"})

      assert json_response(conn, 200) == %{"status" => "rejected"}

      items = Repo.all(from(ri in ReviewItem, where: ri.review_request_id == ^request.id))
      assert Enum.map(items, & &1.status) == ["needs_revision", "needs_revision"]
      assert Enum.all?(items, &(&1.feedback == "Header overlaps"))
    end

    test "a plan reject records the feedback; a second call is 409", %{
      conn: conn,
      token: token,
      user: user
    } do
      task = sponsored_task!(user)
      plan = pending_plan!(task)
      item = plan_item!(user, task)

      conn1 =
        conn
        |> bearer(token)
        |> post("/api/app/approvals/#{item.id}/reject", %{"feedback" => "Split stage 2"})

      assert json_response(conn1, 200) == %{"status" => "rejected"}

      assert %Plan{status: "rejected", rejection_reason: "Split stage 2"} =
               Repo.get!(Plan, plan.id)

      conn2 = conn |> bearer(token) |> post("/api/app/approvals/#{item.id}/reject")
      assert json_response(conn2, 409) == %{"error" => "already_handled", "by" => nil}
    end
  end

  describe "GET /api/app/tasks" do
    test "open tasks assigned to the user, filtered and limited", %{
      conn: conn,
      token: token,
      user: user
    } do
      project = project!()

      for {title, status, assignee} <- [
            {"Ship widgets", "in_progress", user},
            {"Ship intents", "backlog", user},
            {"Old widgets", "done", user},
            {"Their widgets", "in_progress", create_user!()}
          ] do
        {:ok, _} =
          Tasks.create_task(%{
            project_id: project.id,
            title: title,
            status: status,
            assignee_type: "user",
            assignee_id: assignee.id
          })
      end

      all = conn |> bearer(token) |> get("/api/app/tasks") |> json_response(200)

      assert all["tasks"] |> Enum.map(& &1["title"]) |> Enum.sort() == [
               "Ship intents",
               "Ship widgets"
             ]

      assert length(all["tasks"]) == Mobile.counts_for_user(user).tasks
      assert Enum.all?(all["tasks"], &(&1["project_name"] == project.name))

      filtered =
        conn |> bearer(token) |> get("/api/app/tasks", %{"q" => "WIDGET"}) |> json_response(200)

      assert [%{"title" => "Ship widgets", "status" => "in_progress"}] = filtered["tasks"]

      limited =
        conn |> bearer(token) |> get("/api/app/tasks", %{"limit" => "1"}) |> json_response(200)

      assert length(limited["tasks"]) == 1
    end
  end

  describe "meetings" do
    test "POST creates a meeting the user then sees in GET", %{
      conn: conn,
      token: token,
      user: user,
      space: space
    } do
      org = Platform.Tenancy.get_org_by_slug!("sxi")
      plain_member!(user, org)

      {:ok, project} =
        Tasks.create_project(%{
          name: "Meet #{System.unique_integer([:positive])}",
          org_id: org.id
        })

      Repo.update_all(from(s in Chat.Space, where: s.id == ^space.id), set: [org_id: org.id])

      conn1 =
        conn |> bearer(token) |> post("/api/app/meetings", %{"space_id" => space.id})

      assert %{"id" => id, "slug" => slug, "path" => path} = json_response(conn1, 201)
      assert path == "/meetings/#{slug}"
      # The space's org picks the project. Seeded projects can share the
      # org, so assert the org rather than one project id.
      assert %Meeting{project_id: project_id} = Repo.get!(Meeting, id)
      assert Repo.get!(Tasks.Project, project_id).org_id == project.org_id

      listed = conn |> bearer(token) |> get("/api/app/meetings") |> json_response(200)
      assert Enum.any?(listed["meetings"], &(&1["id"] == id and &1["slug"] == slug))
    end

    test "POST into a space the user is not in is 403", %{conn: conn, token: token} do
      other = channel!()
      conn = conn |> bearer(token) |> post("/api/app/meetings", %{"space_id" => other.id})
      assert json_response(conn, 403) == %{"error" => "forbidden"}
    end
  end

  describe "agents" do
    test "lists agents on the user's spaces, deduped", %{
      conn: conn,
      token: token,
      user: user,
      space: space
    } do
      agent = agent!("Rostered")
      add_agent!(space.id, agent.id)
      second = channel!()
      add_user!(second.id, create_user!().id)
      add_agent!(second.id, agent!("Elsewhere").id)

      # Same agent on a second space the user is in: listed once.
      shared = channel!()
      add_user!(shared.id, user.id)
      add_agent!(shared.id, agent.id)

      agents = conn |> bearer(token) |> get("/api/app/agents") |> json_response(200)
      assert [%{"id" => id, "name" => name, "slug" => slug, "role" => nil}] = agents["agents"]
      assert {id, name, slug} == {agent.id, agent.name, agent.slug}
    end

    test "an external user sees no agent from an out-of-scope space", %{conn: conn} do
      world = external_world()
      in_scope = agent!("InScope")
      out_of_scope = agent!("OutOfScope")
      add_agent!(world.a.id, in_scope.id)
      add_agent!(world.b.id, out_of_scope.id)
      %{token: token} = app_session!(world.ext)

      ids =
        conn
        |> bearer(token)
        |> get("/api/app/agents")
        |> json_response(200)
        |> Map.fetch!("agents")
        |> Enum.map(& &1["id"])

      assert in_scope.id in ids
      refute out_of_scope.id in ids
    end

    test "DM with an agent returns the space id as its path_segment", %{
      conn: conn,
      token: token,
      user: user
    } do
      agent = agent!("Dm")

      body =
        conn |> bearer(token) |> post("/api/app/agents/#{agent.id}/dm") |> json_response(200)

      assert %{"space_id" => space_id, "path_segment" => segment} = body
      assert segment == space_id
      assert %Chat.Space{kind: "dm"} = Chat.get_space(space_id)
      assert Chat.participant?(space_id, user.id)

      again =
        conn |> bearer(token) |> post("/api/app/agents/#{agent.id}/dm") |> json_response(200)

      assert again["space_id"] == space_id
    end

    test "DM is 403 for an external user and 404 for an unknown agent", %{
      conn: conn,
      token: token
    } do
      world = external_world()
      %{token: ext_token} = app_session!(world.ext)
      agent = agent!("Nope")

      conn1 = conn |> bearer(ext_token) |> post("/api/app/agents/#{agent.id}/dm")
      assert json_response(conn1, 403) == %{"error" => "forbidden"}

      conn2 = conn |> bearer(token) |> post("/api/app/agents/#{Ecto.UUID.generate()}/dm")
      assert json_response(conn2, 404) == %{"error" => "not_found"}
    end
  end

  describe "GET /api/app/spaces/:space_id/messages" do
    test "returns only rows after the cursor, oldest first", %{
      conn: conn,
      token: token,
      user: user,
      space: space
    } do
      participant =
        Repo.one!(
          from(p in Chat.Participant,
            where: p.space_id == ^space.id and p.participant_id == ^user.id
          )
        )

      [m1, m2, m3] = for text <- ~w(one two three), do: post!(space.id, participant.id, text)

      body =
        conn
        |> bearer(token)
        |> get("/api/app/spaces/#{space.id}/messages", %{"after" => m1.id})
        |> json_response(200)

      assert Enum.map(body["messages"], & &1["id"]) == [m2.id, m3.id]
      assert [%{"content" => "two", "author_type" => "user"} = first, _] = body["messages"]
      assert first["author_id"] == user.id

      limited =
        conn
        |> bearer(token)
        |> get("/api/app/spaces/#{space.id}/messages", %{"limit" => "1"})
        |> json_response(200)

      assert Enum.map(limited["messages"], & &1["id"]) == [m1.id]
    end

    test "404 for a space the user is not in; 422 for a malformed cursor", %{
      conn: conn,
      token: token,
      space: space
    } do
      other = channel!()
      conn1 = conn |> bearer(token) |> get("/api/app/spaces/#{other.id}/messages")
      assert json_response(conn1, 404) == %{"error" => "not_found"}

      conn2 =
        conn |> bearer(token) |> get("/api/app/spaces/#{space.id}/messages", %{"after" => "x"})

      assert json_response(conn2, 422) == %{"error" => "invalid_cursor"}
    end
  end
end
