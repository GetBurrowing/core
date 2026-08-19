defmodule PlatformWeb.MCPControllerTest do
  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Stacks
  alias Platform.Tenancy

  defp create_runtime(attrs \\ %{}) do
    user =
      Repo.insert!(%User{
        email: "mcp_test_#{System.unique_integer([:positive])}@example.com",
        name: "MCP Test User",
        oidc_sub: "oidc-mcp-test-#{System.unique_integer([:positive])}"
      })

    raw_token = AgentRuntime.generate_token()

    base_attrs = %{
      runtime_id: "mcp-rt-#{System.unique_integer([:positive])}",
      owner_user_id: user.id,
      auth_token_hash: AgentRuntime.hash_token(raw_token),
      status: "active",
      allowed_bundles: AgentRuntime.valid_bundles()
    }

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(Map.merge(base_attrs, attrs))
      |> Repo.insert()

    {runtime, raw_token}
  end

  defp mcp_post(conn, token, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end

  defp rpc(method, params \\ %{}, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  describe "authentication" do
    test "rejects requests with no authorization header", %{conn: conn} do
      conn = post(conn, "/mcp", rpc("initialize"))
      assert conn.status == 401
    end

    test "rejects requests with a bogus token", %{conn: conn} do
      conn = mcp_post(conn, "not-a-real-token", rpc("initialize"))
      assert conn.status == 401
    end

    test "rejects non-active runtimes", %{conn: conn} do
      {_runtime, token} = create_runtime(%{status: "suspended"})
      conn = mcp_post(conn, token, rpc("initialize"))
      assert conn.status == 401
    end

    test "accepts a valid bearer token for an active runtime", %{conn: conn} do
      {_runtime, token} = create_runtime()
      conn = mcp_post(conn, token, rpc("initialize"))
      assert conn.status == 200
    end
  end

  describe "initialize" do
    test "returns serverInfo and protocol version", %{conn: conn} do
      {_runtime, token} = create_runtime()
      conn = mcp_post(conn, token, rpc("initialize"))
      body = json_response(conn, 200)

      assert body["jsonrpc"] == "2.0"
      assert body["id"] == 1
      assert body["result"]["serverInfo"]["name"] == "startup-suite"
      assert is_binary(body["result"]["protocolVersion"])
      assert body["result"]["capabilities"]["tools"]
    end
  end

  describe "tools/list" do
    test "returns the full surface when all bundles are allowed", %{conn: conn} do
      {_runtime, token} = create_runtime()
      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      names = Enum.map(tools, & &1["name"])
      assert "federation_status" in names
      assert "task_create" in names
      assert "canvas.create" in names
      assert "canvas.patch" in names
      assert "canvas.describe" in names
      assert Enum.all?(tools, &Map.has_key?(&1, "inputSchema"))
    end

    test "scopes the surface to allowed_bundles", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["federation"]})
      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      names = Enum.map(tools, & &1["name"])
      assert "federation_status" in names
      refute "task_create" in names
      refute "canvas.create" in names
    end

    test "returns an empty list when no bundles are allowed", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: []})
      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      assert tools == []
    end
  end

  describe "tools/call" do
    test "runs a tool that is in scope", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["federation"]})

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{"name" => "federation_status", "arguments" => %{}})
        )

      %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == false
      [%{"type" => "text", "text" => text}] = result["content"]
      assert is_binary(text)
      assert String.contains?(text, "runtimes")
    end

    test "refuses a tool that is out of scope with -32001", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["federation"]})

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{"name" => "task_create", "arguments" => %{}})
        )

      %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 200)
      assert code == -32001
      assert message =~ "not in allowed bundles"
    end

    test "returns -32602 when arguments are missing", %{conn: conn} do
      {_runtime, token} = create_runtime()

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{"name" => "federation_status"})
        )

      %{"error" => %{"code" => code}} = json_response(conn, 200)
      assert code == -32602
    end
  end

  # Before this block existed, the ONLY error-adjacent assertion in this file
  # was `isError == false` above — the error branch of the controller was
  # entirely uncovered, so nothing pinned the response shape in either
  # direction. `error_content/1` flattened every structured refusal
  # `ToolSurface.execute/3` returns down to its `error` sentence, discarding
  # `code`, `recoverable` and `suggestion`, while `RuntimeChannel` pushed the
  # same map intact. Two federation transports, two contracts.
  describe "tools/call error envelope" do
    # `task_design_decline` documents a CLOSED `code` taxonomy in its
    # `limitations` prose and tells remote runtimes to branch on it
    # (`missing_task_id` / `missing_reason` / `task_not_found` /
    # `step_not_open` / `decline_failed`). `tool_surface_design_decline_test`
    # guards that taxonomy at the `execute/3` layer — one level ABOVE where
    # the transport dropped it. This asserts it AT THE WIRE.
    test "a structured refusal reaches an HTTP caller with code, recoverable and suggestion",
         %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["task"]})

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{
            "name" => "task_design_decline",
            # `"short"`, not `"   "`. The argument gate treats a whitespace-only
            # string as absent and would refuse this call before the handler
            # ran, so a blank reason would silently turn this into a test of
            # the gate. A present-but-too-short reason is refused by
            # `task_design_decline` itself, which is the envelope this test
            # exists to follow to the wire. Same `missing_reason` code either
            # way — two producers, one taxonomy.
            "arguments" => %{"task_id" => Ecto.UUID.generate(), "reason" => "short"}
          })
        )

      %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == true

      [%{"type" => "text", "text" => text}] = result["content"]
      envelope = Jason.decode!(text)

      # Atom codes serialize as JSON strings; `:missing_reason` is
      # `"missing_reason"` on the wire, and that IS the wire form.
      assert envelope["code"] == "missing_reason"
      assert envelope["recoverable"] == true
      assert is_binary(envelope["suggestion"])
      assert String.trim(envelope["suggestion"]) != ""
      assert envelope["error"] =~ "reason is required"
    end

    # A whitelist of four keys is the same flattening one width narrower: the
    # keys a handler attaches to explain ITSELF were dropped. `stack_complete`
    # documents `pending: [%{id, title, status}]` in its `returns` prose and
    # names the member blocking the close; without it the caller is told "some
    # member is not done" and has no way to learn which, which is precisely how
    # a real stack stranded in `deploying` with no recovery path.
    test "a handler's structured payload survives to the wire", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["task"]})

      {:ok, project} =
        Tasks.create_project(%{name: "Envelope #{System.unique_integer([:positive])}"})

      slug = "envelope-#{System.unique_integer([:positive])}"

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          name: "Envelope stack",
          slug: slug,
          rollup_branch: Stacks.rollup_branch_name(slug)
        })

      {:ok, blocker} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Still in flight",
          status: "in_progress"
        })

      {:ok, blocker} = Tasks.update_task(blocker, %{stack_id: stack.id, stack_position: 1})

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{
            "name" => "stack_complete",
            "arguments" => %{"stack_id" => stack.id}
          })
        )

      %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == true

      [%{"text" => text}] = result["content"]
      envelope = Jason.decode!(text)

      assert envelope["code"] == "members_not_done"

      # The point of the test: the list, its shape, and enough of it to act on.
      assert [pending] = envelope["pending"]
      assert pending["id"] == blocker.id
      assert pending["title"] == "Still in flight"
      assert pending["status"] == "in_progress"
    end

    test "nil-valued keys are dropped but a false recoverable survives", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["task"]})

      # `task_start` on an unknown task refuses with `error`, `recoverable`
      # and `suggestion` but NO `code` — the envelope must not invent one,
      # and must not confuse "absent" with "false".
      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{
            "name" => "task_start",
            "arguments" => %{"task_id" => Ecto.UUID.generate()}
          })
        )

      %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == true

      [%{"text" => text}] = result["content"]
      envelope = Jason.decode!(text)

      refute Map.has_key?(envelope, "code")
      assert envelope["recoverable"] == false
      assert envelope["error"] =~ "Task not found"
      assert is_binary(envelope["suggestion"])
    end

    test "the error payload is JSON, symmetric with the success payload", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["federation", "task"]})

      ok_conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{"name" => "federation_status", "arguments" => %{}})
        )

      %{"result" => %{"isError" => false, "content" => [%{"text" => ok_text}]}} =
        json_response(ok_conn, 200)

      err_conn =
        build_conn()
        |> mcp_post(
          token,
          rpc("tools/call", %{
            "name" => "task_start",
            "arguments" => %{"task_id" => Ecto.UUID.generate()}
          })
        )

      %{"result" => %{"isError" => true, "content" => [%{"text" => err_text}]}} =
        json_response(err_conn, 200)

      # The argument for the breaking shape change: a client that can read the
      # success payload can already read the error payload.
      assert {:ok, %{}} = Jason.decode(ok_text)
      assert {:ok, %{}} = Jason.decode(err_text)
    end
  end

  describe "the argument gate is mounted on this transport" do
    # These assert the WIRING, not the gate's logic — `ToolArgumentsDispatchTest`
    # owns the logic. What can only be checked here is that `tools/call` routes
    # through `ToolArguments.dispatch/3` rather than straight to
    # `ToolSurface.execute/3`, because that is a one-line change nothing else
    # would notice.
    test "a missing required argument is refused instead of raising through the endpoint",
         %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["plan"]})

      # Before the gate, `validation_evaluate` without a validation_id raised
      # `Ecto.NoResultsError` from inside a `Repo.transaction` — a 500 that
      # named nothing. There is no application-level error to assert against
      # an exception, which is exactly the caller's problem.
      #
      # This used to drive `stage_list`, which stage 5 took out of the gate's
      # scope by giving it a conditional `plan_id` XOR `task_id` rule. Left
      # pointed there, this test would still pass — off the handler's own
      # refusal — while no longer testing the wiring it is named for.
      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{
            "name" => "validation_evaluate",
            "arguments" => %{"status" => "passed"}
          })
        )

      %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == true

      [%{"text" => text}] = result["content"]
      envelope = Jason.decode!(text)

      assert envelope["code"] == "missing_validation_id"
      assert envelope["error"] =~ "validation_id is required"
      assert envelope["recoverable"] == true
      assert envelope["suggestion"] =~ "validation_id"
    end

    test "stage_list's conditional rule reaches the wire with its own code", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["plan"]})

      # The tool that motivated the ticket. It is NOT covered by the gate —
      # `plan_id` XOR `task_id` is conditional — so this asserts the handler's
      # refusal survives the transport intact, naming both acceptable
      # arguments instead of raising through the endpoint.
      conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "stage_list", "arguments" => %{}}))

      %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
        json_response(conn, 200)

      envelope = Jason.decode!(text)

      assert envelope["code"] == "missing_plan_reference"
      assert envelope["error"] =~ "plan_id"
      assert envelope["error"] =~ "task_id"
      assert envelope["recoverable"] == true
    end

    test "the refusal replaces a misattributed 'not found', and says the call is retryable",
         %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["context_read"]})

      # `canvas_get` with no canvas_id used to answer `"Canvas not found: "`
      # with `recoverable: false` — a caller told that a canvas it never named
      # does not exist, and told not to try again.
      conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "canvas_get", "arguments" => %{}}))

      %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
        json_response(conn, 200)

      envelope = Jason.decode!(text)

      assert envelope["code"] == "missing_canvas_id"
      assert envelope["error"] =~ "canvas_id is required"
      refute envelope["error"] =~ "not found"
      assert envelope["recoverable"] == true
    end

    test "an alias-only call is not refused — live runtimes send `id` for `task_id`",
         %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["task"]})

      # The breaking-change guard at the wire. `task_get` declares `task_id`
      # required and its handler reads `task_id || id`; a gate built on the
      # declaration alone would reject this call, which works in production.
      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{
            "name" => "task_get",
            "arguments" => %{"id" => Ecto.UUID.generate()}
          })
        )

      %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
        json_response(conn, 200)

      envelope = Jason.decode!(text)

      # A real not-found, reached because the gate let the alias through —
      # NOT a `missing_task_id` refusal.
      refute envelope["code"] == "missing_task_id"
      assert envelope["error"] =~ "not found"
    end
  end

  describe "external-principal tool scoping (M11)" do
    @broad_bundles ~w(messaging space context_read task canvas)
    @chat_names ~w(send_media react space_list space_get_context space_get_messages space_search_messages)

    defp mark_owner_external(runtime) do
      {:ok, _} =
        Tenancy.mark_membership_external(%{
          user_id: runtime.owner_user_id,
          org_id: fabrikam_org_id()
        })

      runtime
    end

    test "external owner with broad bundles sees ONLY the six chat tools", %{conn: conn} do
      {runtime, token} = create_runtime(%{allowed_bundles: @broad_bundles})
      mark_owner_external(runtime)

      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      names = tools |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == Enum.sort(@chat_names)
      refute "task_create" in names
      refute "canvas.create" in names
      refute "space_leave" in names
    end

    test "external owner: tools/call task_create is forbidden with -32001", %{conn: conn} do
      {runtime, token} = create_runtime(%{allowed_bundles: @broad_bundles})
      mark_owner_external(runtime)

      conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "task_create", "arguments" => %{}}))

      %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 200)
      assert code == -32001
      assert message =~ "not in allowed bundles"
    end

    test "external owner: react is NOT gated (chat tool reaches execution)", %{conn: conn} do
      {runtime, token} = create_runtime(%{allowed_bundles: @broad_bundles})
      mark_owner_external(runtime)

      conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "react", "arguments" => %{}}))

      resp = json_response(conn, 200)
      # The external-scope gate must not reject react; it passes authorize
      # and reaches ToolSurface.execute (which may then return its own
      # arg-level result, but never the -32001 forbidden error).
      refute get_in(resp, ["error", "code"]) == -32001
    end

    test "external owner with only [task] bundle sees an EMPTY surface (fail-closed)", %{
      conn: conn
    } do
      {runtime, token} = create_runtime(%{allowed_bundles: ["task"]})
      mark_owner_external(runtime)

      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      assert tools == []

      # send_media is a chat tool but was never granted → still -32001.
      conn2 =
        build_conn()
        |> mcp_post(token, rpc("tools/call", %{"name" => "send_media", "arguments" => %{}}))

      %{"error" => %{"code" => code}} = json_response(conn2, 200)
      assert code == -32001
    end

    test "internal owner with the same bundles is UNAFFECTED", %{conn: conn} do
      # Default create_runtime owner has no external membership → internal.
      {_runtime, token} = create_runtime(%{allowed_bundles: @broad_bundles})

      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      names = Enum.map(tools, & &1["name"])
      assert "task_create" in names
      assert "canvas.create" in names

      conn2 =
        build_conn()
        |> mcp_post(token, rpc("tools/call", %{"name" => "task_create", "arguments" => %{}}))

      resp = json_response(conn2, 200)
      # Not blocked by the external gate (may fail its own arg validation).
      refute get_in(resp, ["error", "code"]) == -32001
    end
  end

  describe "unknown methods" do
    test "returns -32601 method not found", %{conn: conn} do
      {_runtime, token} = create_runtime()

      conn = mcp_post(conn, token, rpc("does/not/exist"))
      %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 200)

      assert code == -32601
      assert message =~ "does/not/exist"
    end
  end

  describe "GET /mcp" do
    test "returns 405 Method Not Allowed (no server-initiated notifications yet)",
         %{conn: conn} do
      {_runtime, token} = create_runtime()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/mcp")

      assert conn.status == 405
    end
  end
end
