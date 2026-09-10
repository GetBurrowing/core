defmodule Platform.Federation.ToolSurfaceCanvasViewUrlTest do
  @moduledoc """
  Task 019e2c4b stage 5 — the federation surface hands agents a link, and
  describes the boundary that link respects.

  Two separate failures are covered here:

    * a result with an id and no URL, which forces the agent to invent one or
      cite nothing; and
    * a description that promises "shareable" without saying to whom, which
      is how a canvas link ends up pasted where its reader gets a 403.
  """
  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Canvas.Links
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.Tools
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  defp setup_agent_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Canvas view_url",
        slug: "cvu-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    agent_id = Ecto.UUID.generate()

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent_id,
        display_name: "View URL Tester",
        joined_at: DateTime.utc_now()
      })

    %{
      space: space,
      # `agent_participant_id` is what the create handler writes attribution
      # from; `agent_id` is what the read gate resolves participation with.
      context: %{agent_participant_id: participant.id, agent_id: agent_id}
    }
  end

  defp valid_document do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{},
        "children" => [
          %{
            "id" => "h",
            "type" => "heading",
            "props" => %{"value" => "Shareable", "level" => 2},
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  describe "canvas_create" do
    test "returns a view_url alongside the id" do
      %{space: space, context: context} = setup_agent_space()

      assert {:ok, result} =
               ToolSurface.execute(
                 "canvas_create",
                 %{"space_id" => space.id, "title" => "Cite me", "document" => valid_document()},
                 context
               )

      on_exit(fn -> CanvasServer.stop(result.id) end)

      assert result.view_url == Links.view_url(result.id)
      assert result.view_url == PlatformWeb.Endpoint.url() <> "/canvases/" <> result.id
    end
  end

  describe "canvas_get" do
    test "returns the same view_url for a canvas the agent did not create" do
      %{space: space, context: context} = setup_agent_space()

      {:ok, created} =
        ToolSurface.execute(
          "canvas_create",
          %{"space_id" => space.id, "document" => valid_document()},
          context
        )

      on_exit(fn -> CanvasServer.stop(created.id) end)

      assert {:ok, fetched} =
               ToolSurface.execute("canvas_get", %{"canvas_id" => created.id}, context)

      assert fetched.view_url == created.view_url
      assert fetched.view_url == Links.view_url(created.id)
    end

    test "carries the view_url in full mode too" do
      %{space: space, context: context} = setup_agent_space()

      {:ok, created} =
        ToolSurface.execute(
          "canvas_create",
          %{"space_id" => space.id, "document" => valid_document()},
          context
        )

      on_exit(fn -> CanvasServer.stop(created.id) end)

      assert {:ok, fetched} =
               ToolSurface.execute(
                 "canvas_get",
                 %{"canvas_id" => created.id, "mode" => "full"},
                 context
               )

      assert fetched.view_url == Links.view_url(created.id)
      assert fetched.document["root"]["type"] == "stack"
    end
  end

  describe "tool_definitions/0" do
    test "the canvas tools that hand out a URL state the sharing boundary" do
      boundary = Tools.sharing_boundary()
      defs = ToolSurface.tool_definitions()

      for name <- ["canvas.create", "canvas.describe", "canvas.versions", "canvas_get"] do
        defn = Enum.find(defs, &(&1.name == name))
        assert defn, "#{name} missing from the federation tool surface"

        assert defn.description =~ boundary,
               "#{name} does not state the sharing boundary in its description"
      end
    end

    test "the documented return shapes include view_url" do
      defs = ToolSurface.tool_definitions()

      assert Enum.find(defs, &(&1.name == "canvas.create")).returns =~ "view_url"
      assert Enum.find(defs, &(&1.name == "canvas.describe")).returns =~ "view_url"
      assert Enum.find(defs, &(&1.name == "canvas_get")).returns =~ "view_url"
      assert Enum.find(defs, &(&1.name == "canvas_list")).returns =~ "view_url"
    end

    # Inverted by task 019fb01b stage 3, which gated the read. Between 019e2c4b
    # and this stage the string honestly advertised the hole; leaving it in
    # place now would be the same defect pointing the other way.
    test "canvas.describe states the gate it now actually has" do
      describe = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "canvas.describe"))

      refute describe.limitations =~ "not gated on space participation"
      assert describe.limitations =~ "participant"
      assert describe.limitations =~ "task"
    end

    # Task 019fb01b stage 4 WIDENED this tool: it used to answer "are you in
    # this canvas's space", and now also resolves an agent bound to a live task
    # the canvas is attached to. The old string named only the space clause, so
    # after the widening it described a narrower tool than the one that ships.
    test "canvas_get states the task grant its limitations used to omit" do
      canvas_get = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "canvas_get"))

      assert canvas_get.limitations =~ "participant"
      assert canvas_get.limitations =~ "task"
    end

    # The gate has to be in `description`, not only in `limitations`.
    #
    # It used to be that `MCPController.to_mcp_tool/1` forwarded name,
    # description and inputSchema and nothing else, so a gate stated only in
    # `limitations` was read by maintainers and by no caller. Task 01a08a0c
    # fixed that — `ToolDoc.render_description/1` now appends the other three
    # fields — but this assertion stands on its own footing: `description` is
    # what a client shows first and what a truncating reader keeps. A denied
    # agent needs to know from the opening paragraph whether to ask for roster
    # or to drop a stale attachment, not from a block three headings down.
    test "every gated read carries the read gate in its description" do
      gate = Tools.read_gate()
      defs = ToolSurface.tool_definitions()

      for name <- ["canvas.describe", "canvas.versions", "canvas_get"] do
        defn = Enum.find(defs, &(&1.name == name))
        assert defn, "#{name} missing from the federation tool surface"

        assert defn.description =~ gate,
               "#{name} does not state the read gate in its description"
      end
    end

    # `:task_agent` (task 019fb01b stage 2) is a grant path a human-only
    # sentence would omit, and the omission would read as "an agent cannot get
    # in", which is now false.
    test "the sharing boundary names the agent task path" do
      boundary = Tools.sharing_boundary()

      assert boundary =~ "AGENT"
      assert boundary =~ "task"
    end
  end

  # The hosted transport is where the sentence has to survive. `tools/list`
  # projects each tool through `MCPController.to_mcp_tool/1`. As of task
  # 01a08a0c that projection runs `ToolDoc.render_description/1` and the
  # `limitations` / `returns` / `when_to_use` prose DOES reach an agent, folded
  # into `description` under headings — before that it reached no one. The
  # assertion below is therefore checked twice on purpose: once against the
  # definition's OWN `description` (so the folding cannot be what makes it
  # pass, which would quietly relax the requirement this file exists for) and
  # once at the wire. Driving the real endpoint still matters, because the
  # definition map is not what ships.
  describe "the hosted /mcp transport" do
    test "tools/list carries the sharing boundary to a real MCP client", %{conn: conn} do
      {:ok, space} =
        Chat.create_space(%{
          name: "MCP boundary",
          slug: "mcpb-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      token = canvas_runtime_token!(space)

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      }

      resp =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)
        |> json_response(200)

      tools = resp["result"]["tools"]
      boundary = Tools.sharing_boundary()

      for name <- ["canvas.create", "canvas.describe"] do
        tool = Enum.find(tools, &(&1["name"] == name))
        assert tool, "#{name} missing from tools/list"

        defn = Enum.find(ToolSurface.tool_definitions(), &(&1.name == name))
        assert defn, "#{name} missing from the federation tool surface"

        assert defn.description =~ boundary,
               "#{name} states the boundary only outside `description`, so the " <>
                 "opening paragraph a client shows first no longer carries it"

        assert tool["description"] =~ boundary,
               "#{name} loses the boundary on the hosted transport"
      end
    end
  end

  defp canvas_runtime_token!(space) do
    user =
      Repo.insert!(%User{
        email: "canvas_view_url_#{System.unique_integer([:positive])}@example.com",
        name: "Canvas view_url runtime owner",
        oidc_sub: "oidc-canvas-view-url-#{System.unique_integer([:positive])}"
      })

    agent =
      Repo.insert!(%Agent{
        slug: "canvas-view-url-#{System.unique_integer([:positive])}",
        name: "Canvas view_url Agent",
        status: "active"
      })

    {:ok, _participant} = Chat.add_agent_participant(space.id, agent)

    raw_token = AgentRuntime.generate_token()

    {:ok, _runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "rt-canvas-view-url-#{System.unique_integer([:positive])}",
        owner_user_id: user.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw_token),
        status: "active",
        allowed_bundles: ["canvas"]
      })
      |> Repo.insert()

    raw_token
  end
end
