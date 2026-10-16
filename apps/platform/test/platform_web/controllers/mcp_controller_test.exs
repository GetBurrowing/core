defmodule PlatformWeb.MCPControllerTest do
  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.AgentRuntime
  alias Platform.Access.RuntimeProfiles
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Stacks
  alias Platform.Tenancy

  defp create_runtime(attrs \\ %{}) do
    user = root_admin!()

    raw_token = AgentRuntime.generate_token()

    modules = Map.get(attrs, :tool_profile, RuntimeProfiles.valid_modules())

    base_attrs = %{
      runtime_id: "mcp-rt-#{System.unique_integer([:positive])}",
      owner_user_id: user.id,
      auth_token_hash: AgentRuntime.hash_token(raw_token),
      status: "active"
    }

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(Map.merge(base_attrs, attrs))
      |> Repo.insert()

    {:ok, _profile} =
      RuntimeProfiles.create_for_runtime(
        runtime,
        modules,
        RuntimeProfiles.translated_permissions(modules)
      )

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

    test "scopes the surface to tool_profile", %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: ["federation"]})
      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      names = Enum.map(tools, & &1["name"])
      assert "federation_status" in names
      refute "task_create" in names
      refute "canvas.create" in names
    end

    test "returns an empty list when no bundles are allowed", %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: []})
      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      assert tools == []
    end

    # Task 01a049de. `_meta["anthropic/maxResultSizeChars"]` is the field a
    # client reads to size a tool's result budget.
    test "every tool declares a result-size ceiling below the client default", %{conn: conn} do
      {_runtime, token} = create_runtime()
      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      assert tools != []

      for tool <- tools do
        declared = get_in(tool, ["_meta", "anthropic/maxResultSizeChars"])

        assert is_integer(declared),
               "#{tool["name"]} declares no anthropic/maxResultSizeChars"

        # The direction of this assertion is the point, and it is the opposite
        # of what the ticket asked for. The field RAISES a client's ceiling
        # (Claude Code truncates at MAX_MCP_OUTPUT_TOKENS, default 25_000
        # tokens, and honours this value instead when a tool sets it). The
        # protocol allows up to 500_000; declaring 500_000 would have raised
        # our ceiling roughly five-fold rather than capping anything. Asserting
        # a strict upper bound is what stops a future edit from "fixing" this
        # by turning it up to the maximum.
        assert declared <= 100_000,
               "#{tool["name"]} declares #{declared}, which RAISES rather than caps the ceiling"
      end
    end
  end

  describe "result size backstop (task 01a049de)" do
    test "a normal small result is a single content block and is not annotated", %{conn: conn} do
      {_runtime, token} = create_runtime()
      {:ok, project} = Tasks.create_project(%{name: "Backstop Small #{unique()}"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "Solo", description: "x"})

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{
            "name" => "task_list",
            "arguments" => %{"project_id" => project.id}
          })
        )

      %{"result" => %{"content" => content, "isError" => false}} = json_response(conn, 200)

      # POSITIVE CONTROL at the transport. Exactly one block, carrying the
      # whole answer. A backstop that fired on everything would add a second
      # block here, and a change that emptied the payload would fail the
      # decode below.
      assert [%{"type" => "text", "text" => json}] = content
      envelope = Jason.decode!(json)
      assert [row] = envelope["tasks"]
      assert row["title"] == "Solo"
      assert row["description"] == "x"
      assert row["description_truncated"] == false

      # The envelope survives the transport intact (task 01a04a7a). One task,
      # one returned, nothing beyond it.
      assert envelope["total"] == 1
      assert envelope["has_more"] == false
    end

    test "an oversized result stays valid JSON and carries a truncation notice", %{conn: conn} do
      {_runtime, token} = create_runtime()
      {:ok, project} = Tasks.create_project(%{name: "Backstop Big #{unique()}"})

      # `detail: "full"` deliberately defeats the per-field snippet so the
      # transport backstop is the only thing left standing. Without this the
      # test would prove the snippet works, not the backstop.
      blob = String.duplicate("q", 20_000)

      for i <- 1..40 do
        {:ok, _} =
          Tasks.create_task(%{project_id: project.id, title: "Big #{i}", description: blob})
      end

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{
            "name" => "task_list",
            "arguments" => %{
              "project_id" => project.id,
              "detail" => "full",
              "limit" => 40
            }
          })
        )

      %{"result" => %{"content" => content, "isError" => false}} = json_response(conn, 200)

      assert [%{"type" => "text", "text" => json}, %{"type" => "text", "text" => note}] = content

      # The assertion the ticket singles out: a cap that cuts mid-structure is
      # worse than no cap. This must parse.
      decoded = Jason.decode!(json)
      assert is_map(decoded)
      assert byte_size(json) <= 100_000

      # And what survived is whole records, not a mangled tail.
      kept = decoded["tasks"]
      assert is_list(kept)
      assert length(kept) > 0
      assert length(kept) < 40
      assert Enum.all?(kept, &is_binary(&1["id"]))
      assert Enum.all?(kept, &(String.length(&1["description"]) == 20_000))

      # Task 01a04a7a: the backstop must still be able to SHRINK the envelope.
      # `ResultBound.items_key/1` finds `:tasks` through its sole-list-valued-key
      # fallback; without that fallback this payload would have been returned
      # whole and `byte_size(json) <= 100_000` above would fail — the envelope
      # would have been a regression against the bare array it replaced.
      #
      # The sibling keys survive the shrink and keep telling the truth about
      # the corpus rather than about the shrunken page.
      assert decoded["total"] == 40
      assert decoded["offset"] == 0

      # The handler computed `has_more: false` — 40 of 40, genuinely the last
      # page. The backstop then dropped records, so `false` would have been a
      # lie: this ticket's exact failure, reintroduced one layer down.
      # `ResultBound.mark_has_more/2` raises it.
      assert decoded["has_more"] == true

      assert note =~ "truncated"
      assert note =~ "offset"
    end

    defp unique, do: System.unique_integer([:positive])
  end

  describe "image content blocks (task 01a0fcfa)" do
    # A real 1x1 RGBA PNG (68 bytes).
    @png Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="
         )

    setup do
      prev_root = Application.get_env(:platform, :chat_attachments_root)
      root = Platform.TestTemp.mkdir!("mcp_controller_image_blocks")
      Application.put_env(:platform, :chat_attachments_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev_root do
          Application.put_env(:platform, :chat_attachments_root, prev_root)
        else
          Application.delete_env(:platform, :chat_attachments_root)
        end
      end)

      u = System.unique_integer([:positive])

      {:ok, space} =
        Platform.Chat.create_space(%{name: "MCP Images", slug: "mcp-img-#{u}", kind: "channel"})

      {:ok, agent} =
        %Platform.Agents.Agent{}
        |> Platform.Agents.Agent.changeset(%{
          slug: "mcp-img-agent-#{u}",
          name: "MCP Image Agent",
          status: "active"
        })
        |> Repo.insert()

      {:ok, _participant} =
        Platform.Chat.add_agent_participant(space.id, agent, display_name: agent.name)

      # `build_context/2` resolves membership from the runtime's `agent_id`.
      {_runtime, token} = create_runtime(%{agent_id: agent.id})

      %{root: root, space: space, token: token}
    end

    defp store_attachment(ctx, bytes, content_type, filename) do
      storage_key = "chat/test/mcp-img-#{Ecto.UUID.generate()}"
      target = Path.join(ctx.root, storage_key)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)

      {:ok, attachment} =
        Platform.Chat.create_attachment(%{
          space_id: ctx.space.id,
          filename: filename,
          content_type: content_type,
          byte_size: byte_size(bytes),
          storage_key: storage_key,
          state: "ready"
        })

      attachment
    end

    defp get_inline(conn, token, attachment) do
      conn
      |> mcp_post(
        token,
        rpc("tools/call", %{
          "name" => "attachment.get_inline",
          "arguments" => %{"attachment_id" => attachment.id}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")
    end

    # The PNG test and the octet-stream control below store IDENTICAL bytes.
    # If the controller ignored the marker, this test fails on block count
    # (one text block, not text + image). If the controller lifted every
    # base64-bearing result, the control fails (it would gain an image block).
    test "a PNG arrives as a text metadata block followed by an image block",
         %{conn: conn} = ctx do
      attachment = store_attachment(ctx, @png, "image/png", "dot.png")

      result = get_inline(conn, ctx.token, attachment)

      assert result["isError"] == false

      assert [%{"type" => "text", "text" => text}, image] = result["content"]
      assert %{"type" => "image", "mimeType" => "image/png", "data" => data} = image
      assert Map.keys(image) |> Enum.sort() == ["data", "mimeType", "type"]
      assert Base.decode64!(data) == @png

      assert Jason.decode!(text) == %{
               "filename" => "dot.png",
               "byte_size" => byte_size(@png),
               "content_type" => "image/png",
               "image_content_block" => true
             }

      # The bytes cross the wire once, in the image block only.
      refute String.contains?(text, Base.encode64(@png))
      refute String.contains?(text, "__mcp_image__")
    end

    test "POSITIVE CONTROL: the same bytes stored as application/octet-stream stay text only",
         %{conn: conn} = ctx do
      attachment = store_attachment(ctx, @png, "application/octet-stream", "dot.bin")

      result = get_inline(conn, ctx.token, attachment)

      assert result["isError"] == false
      assert [%{"type" => "text", "text" => text}] = result["content"]

      decoded = Jason.decode!(text)
      assert Base.decode64!(decoded["data_base64"]) == @png
      refute Map.has_key?(decoded, "image_content_block")
    end

    for {content_type, filename, bytes} <- [
          {"text/plain", "notes.txt", "plain text body\n"},
          {"application/pdf", "doc.pdf", "%PDF-1.4\n%fake pdf body\n"}
        ] do
      test "#{content_type} is one text block with exactly the pre-change keys",
           %{conn: conn} = ctx do
        bytes = unquote(bytes)
        attachment = store_attachment(ctx, bytes, unquote(content_type), unquote(filename))

        result = get_inline(conn, ctx.token, attachment)

        assert result["isError"] == false
        assert [%{"type" => "text", "text" => text}] = result["content"]

        assert Jason.decode!(text) == %{
                 "content_type" => unquote(content_type),
                 "byte_size" => byte_size(bytes),
                 "data_base64" => Base.encode64(bytes),
                 "filename" => unquote(filename)
               }
      end
    end

    test "a PNG over mcp_image_block_max_bytes stays base64 text and says why",
         %{conn: conn} = ctx do
      prev = Application.get_env(:platform, :mcp_image_block_max_bytes)
      Application.put_env(:platform, :mcp_image_block_max_bytes, 32)

      on_exit(fn ->
        if prev do
          Application.put_env(:platform, :mcp_image_block_max_bytes, prev)
        else
          Application.delete_env(:platform, :mcp_image_block_max_bytes)
        end
      end)

      attachment = store_attachment(ctx, @png, "image/png", "dot.png")

      result = get_inline(conn, ctx.token, attachment)

      assert result["isError"] == false
      assert [%{"type" => "text", "text" => text}] = result["content"]

      decoded = Jason.decode!(text)
      assert Base.decode64!(decoded["data_base64"]) == @png
      assert decoded["image_block_skipped"] =~ "32-byte"
      refute Map.has_key?(decoded, "image_content_block")
      refute Map.has_key?(decoded, "__mcp_image__")
    end
  end

  describe "tools/call" do
    test "runs a tool that is in scope", %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: ["federation"]})

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

    test "task kind round-trips through the HTTP MCP transport", %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: ["task"]})

      {:ok, project} =
        Tasks.create_project(%{name: "HTTP kind #{System.unique_integer([:positive])}"})

      create_conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{
            "name" => "task_create",
            "arguments" => %{
              "project_id" => project.id,
              "title" => "HTTP kind",
              "kind" => "research"
            }
          })
        )

      %{"result" => %{"content" => [%{"text" => create_json}], "isError" => false}} =
        json_response(create_conn, 200)

      created = Jason.decode!(create_json)
      assert created["kind"] == "research"

      update_conn =
        build_conn()
        |> mcp_post(
          token,
          rpc("tools/call", %{
            "name" => "task_update",
            "arguments" => %{"task_id" => created["id"], "kind" => "bug"}
          })
        )

      %{"result" => %{"content" => [%{"text" => update_json}], "isError" => false}} =
        json_response(update_conn, 200)

      updated = Jason.decode!(update_json)
      assert updated["kind"] == "bug"
      assert Tasks.get_task_record(created["id"]).kind == "bug"
    end

    test "refuses a tool that is out of scope with -32001", %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: ["federation"]})

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{"name" => "task_create", "arguments" => %{}})
        )

      %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 200)
      assert code == -32001
      assert message =~ "requires permission 'tasks.write'"
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

  # Task 01a089c8: both federation transports used to say
  # `tool '<name>' not in allowed bundles` for two unrelated conditions — a
  # real tool this runtime just lacks the grant for, and a name that does
  # not exist in the catalogue at all (typo, or the dots-vs-underscores
  # mismatch between the HTTP endpoint's `plan_update` and a hypothetical
  # `plan.update`). The second case sent readers to check grant tables for a
  # grant that was never missing. This block pins that the two cases now
  # read differently, without changing `-32001` or authorization itself.
  describe "tools/call denial message distinguishes unknown-tool from missing-grant" do
    test "an undeclared name (separator mismatch) gets the unknown-tool message with a suggestion",
         %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: ["federation"]})

      conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "plan.update", "arguments" => %{}}))

      %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 200)
      assert code == -32001
      assert message =~ "unknown tool 'plan.update'"
      assert message =~ "Closest declared name: 'plan_update'"
      refute message =~ "not in allowed bundles"
    end

    # Load-bearing: without this, rewording every denial to "unknown tool"
    # would also pass the test above.
    test "a real catalogue tool outside this runtime's profile names its permission",
         %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: ["federation"]})

      conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "task_create", "arguments" => %{}}))

      %{"error" => %{"message" => message}} = json_response(conn, 200)

      assert message ==
               "tool 'task_create' requires permission 'tasks.write', which this agent does not hold or is capped at its owner"
    end

    test "the two denial messages differ for the two inputs", %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: ["federation"]})

      unknown_conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "plan.update", "arguments" => %{}}))

      %{"error" => %{"message" => unknown_message}} = json_response(unknown_conn, 200)

      forbidden_conn =
        build_conn()
        |> mcp_post(token, rpc("tools/call", %{"name" => "task_create", "arguments" => %{}}))

      %{"error" => %{"message" => forbidden_message}} = json_response(forbidden_conn, 200)

      # Not just "the strings differ" — that would trivially hold for any two
      # denials naming different tools. Pin that the WORDING differs by
      # reason: one names itself a lookup miss and the other doesn't.
      assert unknown_message =~ "unknown tool"
      refute forbidden_message =~ "unknown tool"
      assert unknown_message != forbidden_message
    end

    # `effective_tools/1` resolves a nil/empty `tool_profile` column to an
    # empty list, so a no-bundles runtime and a narrow-bundles runtime look
    # identical from inside `authorize/2` — this pins that the no-bundles
    # case still gets the grant-denial wording for a real tool, not the
    # unknown-tool one.
    test "a runtime granted NO bundles still gets a denial for a real tool, not an unknown-tool answer",
         %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: []})

      conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "task_create", "arguments" => %{}}))

      %{"error" => %{"message" => message}} = json_response(conn, 200)

      assert message ==
               "tool 'task_create' requires permission 'tasks.write', which this agent does not hold or is capped at its owner"

      refute message =~ "unknown tool"
    end

    test "emits tool_call_denied telemetry with reason :unknown_tool for an undeclared name",
         %{conn: conn} do
      handler_id = "mcp-tool-call-denied-unknown-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :federation, :tool_call_denied],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:tool_call_denied, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {_runtime, token} = create_runtime(%{tool_profile: ["federation"]})

      mcp_post(conn, token, rpc("tools/call", %{"name" => "plan.update", "arguments" => %{}}))

      assert_receive {:tool_call_denied, _measurements, metadata}
      assert metadata.reason == :unknown_tool
      assert metadata.tool == "plan.update"
    end

    test "emits tool_call_denied telemetry with reason :forbidden for a real-but-ungranted tool",
         %{conn: conn} do
      handler_id = "mcp-tool-call-denied-forbidden-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :federation, :tool_call_denied],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:tool_call_denied, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {_runtime, token} = create_runtime(%{tool_profile: ["federation"]})

      mcp_post(conn, token, rpc("tools/call", %{"name" => "task_create", "arguments" => %{}}))

      assert_receive {:tool_call_denied, _measurements, metadata}
      assert metadata.reason == :forbidden
      assert metadata.tool == "task_create"
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
      {_runtime, token} = create_runtime(%{tool_profile: ["task"]})

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
      {_runtime, token} = create_runtime(%{tool_profile: ["task"]})

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
      {_runtime, token} = create_runtime(%{tool_profile: ["task"]})

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
      {_runtime, token} = create_runtime(%{tool_profile: ["federation", "task"]})

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
      {_runtime, token} = create_runtime(%{tool_profile: ["plan"]})

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
      {_runtime, token} = create_runtime(%{tool_profile: ["plan"]})

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
      {_runtime, token} = create_runtime(%{tool_profile: ["context_read"]})

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
      {_runtime, token} = create_runtime(%{tool_profile: ["task"]})

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

    test "task_list advertises assignee_id and assignee_type in its inputSchema (task 01a0acc3)",
         %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: ["task"]})
      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      schema = tools |> Enum.find(&(&1["name"] == "task_list")) |> Map.fetch!("inputSchema")
      props = schema["properties"]

      # Positive control: a pre-existing declared filter is present, so an
      # absence below cannot be a schema that renders no properties at all.
      assert Map.has_key?(props, "project_id")
      assert props["assignee_id"]["type"] == "string"
      assert props["assignee_type"]["type"] == "string"
      refute "assignee_id" in schema["required"]
      refute "assignee_type" in schema["required"]
    end

    test "task_list refuses an undeclared key instead of answering unfiltered (task 01a0acc3)",
         %{conn: conn} do
      {_runtime, token} = create_runtime(%{tool_profile: ["task"]})

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{
            "name" => "task_list",
            "arguments" => %{"assignee" => Ecto.UUID.generate()}
          })
        )

      %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
        json_response(conn, 200)

      envelope = Jason.decode!(text)

      # The atom code reaches the wire as its string form.
      assert envelope["code"] == "unknown_parameter"
      assert envelope["error"] =~ "assignee"
      assert envelope["unknown_parameters"] == ["assignee"]
      assert envelope["recoverable"] == true
    end
  end

  describe "external-principal tool scoping (M11)" do
    @broad_bundles ~w(messaging space context_read task canvas)
    @chat_names ~w(send_media react space_list space_get_context space_get_messages space_search_messages)

    defp mark_owner_external(runtime) do
      {:ok, _} =
        Tenancy.mark_membership_external(%{
          user_id: runtime.owner_user_id,
          org_id: acme_org_id()
        })

      runtime
    end

    test "external owner with broad bundles sees ONLY the six chat tools", %{conn: conn} do
      {runtime, token} = create_runtime(%{tool_profile: @broad_bundles})
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
      {runtime, token} = create_runtime(%{tool_profile: @broad_bundles})
      mark_owner_external(runtime)

      conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "task_create", "arguments" => %{}}))

      %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 200)
      assert code == -32001
      assert message =~ "requires permission 'tasks.write'"
    end

    test "external owner: react is NOT gated (chat tool reaches execution)", %{conn: conn} do
      {runtime, token} = create_runtime(%{tool_profile: @broad_bundles})
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
      {runtime, token} = create_runtime(%{tool_profile: ["task"]})
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
      {_runtime, token} = create_runtime(%{tool_profile: @broad_bundles})

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
