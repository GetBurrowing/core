defmodule Platform.Federation.ToolDocWireTest do
  @moduledoc """
  Task 01a08a0c stage 1 — the prose reaches a hosted runtime, for EVERY tool.

  `PlatformWeb.MCPController.to_mcp_tool/1` used to emit `tool.description`
  verbatim, so the `returns` / `limitations` / `when_to_use` prose authored for
  all 104 tools was written, reviewed, and then dropped by the transport. The
  WebSocket runtime channel pushed the definition map whole; `POST /mcp` shipped
  one field of four. This file drives the REAL endpoint and asserts the fix
  holds across the whole surface.

  ## Why the quantification is universal

  Three weaker shapes were considered and rejected, and naming them is the
  point of this moduledoc:

    * `refute served == ""` / `assert served =~ "Limitations"` — non-blank
      assertions PASS TODAY, against the broken serializer, because the
      original description is non-blank.
    * one hand-picked tool — passes on a special case. `canvas.create` already
      hand-duplicated its boundary sentence INTO `description`, so a test
      pointed at it proves nothing about the other 103.
    * counting sections (`count == 4`) — passes on four EMPTY headings, which
      is the exact vacuity `tool_doc_test.exs` exists to catch.

  So: for every definition with a non-blank field, a LONG slice of THAT TOOL'S
  OWN text must appear in THAT TOOL'S served payload. A slice rather than a
  word because `runtime_event_list` and `execution_lease_list` carry
  near-identical `limitations` prose about empty results — a generic word
  would let one tool's text vouch for its neighbour's.

  The counts are reported as parts and total so the arithmetic is visible: a
  sweep that silently examined three tools and passed is the failure mode this
  file is built against.
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.ToolDoc
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  # Long enough that no two tools could share it by accident, short enough to
  # survive a tool whose prose is on the terse side.
  @slice_len 120

  # Task 01a08a0c stage 3. Hardcoded on purpose: deriving these from
  # `ToolSurface.tool_definitions()` would make the test agree with whatever
  # the prose currently says, including the contradiction it exists to pin.
  @inference_blocker "an empty result here does NOT mean no safety-net timer is armed"
  @empty_list_limitation "AN EMPTY LIST IS A LEGITIMATE ANSWER FOR A LIVE, HEALTHY TASK"
  @neighbour_limitation "A TASK WITH RUNTIME EVENTS AND ZERO EXECUTION LEASES IS NORMAL"

  describe "tools/list carries every authored prose field" do
    test "every non-blank returns/limitations/when_to_use reaches the wire", %{conn: conn} do
      tools = list_tools!(conn)
      definitions = servable_definitions()

      # The sweep is only as strong as its denominator. Pin it: an internal
      # runtime holding every bundle is served the whole catalogue, so a
      # regression that starts hiding tools shows up HERE rather than as a
      # quietly smaller loop below.
      assert length(tools) == length(definitions),
             "served #{length(tools)} tools, catalogue has #{length(definitions)}"

      served = Map.new(tools, &{&1["name"], &1})

      counts =
        for field <- [:returns, :limitations, :when_to_use], into: %{} do
          checked =
            for definition <- definitions,
                text = present(Map.get(definition, field)),
                reduce: 0 do
              acc ->
                wire = served[definition.name]
                assert wire, "#{definition.name} missing from tools/list"

                needle = distinctive_slice(text)

                assert String.contains?(wire["description"], needle),
                       """
                       #{definition.name}: its own #{field} prose is not on the wire.

                       looked for: #{inspect(needle)}
                       served description: #{inspect(String.slice(wire["description"], 0, 400))}
                       """

                acc + 1
            end

          with_field = Enum.count(definitions, &present(Map.get(&1, field)))
          without_field = length(definitions) - with_field

          assert checked == with_field
          assert with_field + without_field == length(definitions)

          {field, {with_field, without_field}}
        end

      # Visible arithmetic, per the validation's "report the counts as parts
      # and total" — printed rather than asserted-and-discarded so a shrinking
      # denominator is readable in CI output.
      IO.puts("""

      tools/list prose sweep — #{length(definitions)} tool definitions
        returns:      #{elem(counts.returns, 0)} with + #{elem(counts.returns, 1)} without
        limitations:  #{elem(counts.limitations, 0)} with + #{elem(counts.limitations, 1)} without
        when_to_use:  #{elem(counts.when_to_use, 0)} with + #{elem(counts.when_to_use, 1)} without
      """)
    end

    # THE COMPATIBILITY GUARD. This fix is additive or it is a breaking change
    # to an interface other agents already read; there is no third option.
    test "every served description still starts with the original description", %{conn: conn} do
      tools = list_tools!(conn)
      served = Map.new(tools, &{&1["name"], &1})

      for definition <- servable_definitions() do
        wire = served[definition.name]
        assert wire, "#{definition.name} missing from tools/list"

        assert String.starts_with?(wire["description"], definition.description),
               "#{definition.name}: served description no longer opens with the authored one"
      end
    end

    test "no tool gained an empty or dangling heading", %{conn: conn} do
      for wire <- list_tools!(conn) do
        description = wire["description"]

        for heading <- ToolDoc.headings() do
          # A heading with nothing after it but whitespace — the shape that
          # makes "four sections present" a vacuous check.
          refute description =~ ~r/#{Regex.escape(heading)}\s*$/,
                 "#{wire["name"]}: #{heading} heading with no body"

          refute description =~ heading <> "\n",
                 "#{wire["name"]}: #{heading} heading followed by a line break"
        end

        refute String.ends_with?(description, "\n"),
               "#{wire["name"]}: served description ends with a dangling separator"
      end
    end

    # The fix must not widen the MCP tool object. Sibling keys were explicitly
    # rejected — a client may drop unknown keys, which would make the whole
    # change a no-op that reads as fixed in the diff.
    test "the served key set is unchanged", %{conn: conn} do
      for wire <- list_tools!(conn) do
        assert Map.keys(wire) |> Enum.sort() == ["_meta", "description", "inputSchema", "name"],
               "#{wire["name"]} changed the MCP tool object's key set"

        for internal <- ~w(limitations returns when_to_use bundle parameters) do
          refute Map.has_key?(wire, internal),
                 "#{wire["name"]} emitted #{internal} as a sibling key"
        end
      end
    end
  end

  # ── task 01a08a0c stage 3 ─────────────────────────────────────────────────

  describe "execution_lease_list's two halves are readable together" do
    # THE DEFECT THIS PINS. The old one-line description called these rows "the
    # lifecycle/liveness records the safety-net timer reasons over", while the
    # `limitations` opened "AN EMPTY LIST IS A LEGITIMATE ANSWER FOR A LIVE,
    # HEALTHY TASK". A reader holding only the description — i.e. every MCP
    # agent before stage 1 — reasons to "no lease, so nothing to lapse, so the
    # safety-net promise is empty". Two agents actually reached that. Both
    # sentences were true, of DIFFERENT objects: the description described the
    # ephemeral ETS `LeaseManager` store, the tool returns the durable
    # `execution_leases` rows. The fix is only real if BOTH halves reach one
    # reader in one payload, so that is what this asserts.
    test "the served payload carries the durable-store clause AND the empty-list limitation",
         %{conn: conn} do
      served = Map.new(list_tools!(conn), &{&1["name"], &1})

      wire = served["execution_lease_list"]
      assert wire, "execution_lease_list missing from tools/list"
      description = wire["description"]

      assert String.contains?(description, @inference_blocker),
             """
             execution_lease_list: the description no longer blocks the inference
             "no lease, therefore no safety net".

             looked for: #{inspect(@inference_blocker)}
             served: #{inspect(description)}
             """

      assert String.contains?(description, @empty_list_limitation),
             """
             execution_lease_list: the limitations half is not on the wire.

             looked for: #{inspect(@empty_list_limitation)}
             served: #{inspect(description)}
             """

      # The two halves in ORDER, in ONE string: the corrected description
      # first, the limitation it used to contradict after it. Presence alone
      # would pass if the clause had been appended into `limitations` instead,
      # which would leave the description — the field a terse client renders —
      # still saying the wrong thing.
      assert index_of(description, @inference_blocker) <
               index_of(description, @empty_list_limitation),
             "the corrected clause must sit in the description half, ahead of limitations"
    end

    # THE ADJACENCY TRAP, as an assertion rather than a comment.
    # `runtime_event_list` sits directly above `execution_lease_list` in
    # tool_surface.ex with near-identical limitations prose about zero leases;
    # a `grep -A12` from either lands inside the other, and that is how a
    # neighbour's field already got quoted as this tool's. Resolving by the
    # served `name` key is the fix, and this pins that the clause is genuinely
    # distinctive rather than boilerplate shared by both.
    test "the neighbour runtime_event_list does not carry execution_lease_list's clause",
         %{conn: conn} do
      served = Map.new(list_tools!(conn), &{&1["name"], &1})

      neighbour = served["runtime_event_list"]
      assert neighbour, "runtime_event_list missing from tools/list"

      # Positive control FIRST: prove this payload is real and populated, so
      # the refute below cannot pass on an empty or missing description.
      assert String.contains?(neighbour["description"], @neighbour_limitation),
             "runtime_event_list's own limitations prose is missing — the refute would be vacuous"

      refute String.contains?(neighbour["description"], @inference_blocker),
             "runtime_event_list carries execution_lease_list's clause; the slice is not distinctive"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp list_tools!(conn) do
    token = full_surface_token!()

    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}

    %{"result" => %{"tools" => tools}} =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", body)
      |> json_response(200)

    tools
  end

  # Inserted DIRECTLY rather than through `AgentRuntime.changeset/2`:
  # `valid_bundles/0` omits `files`, so the changeset refuses a grant set that
  # covers the whole surface. Prod carries such rows anyway. Going through the
  # changeset here would silently shrink this file's denominator to 96 tools.
  # Rowan accepted the temporary Play C/K/N owner-cap exception.
  defp servable_definitions do
    Enum.reject(ToolSurface.tool_definitions(), &String.starts_with?(&1.name, "play_session_"))
  end

  defp full_surface_token! do
    n = System.unique_integer([:positive])

    user = root_admin!()

    agent =
      Repo.insert!(%Agent{
        slug: "tool-doc-wire-#{n}",
        name: "ToolDoc Wire Agent #{n}",
        status: "active"
      })

    raw = AgentRuntime.generate_token()

    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "tool-doc-wire-rt-#{n}",
        owner_user_id: user.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw),
        status: "active",
        transport: "http",
        trust_level: "participant",
        metadata: %{}
      })

    Repo.insert!(%Platform.Access.RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: ToolSurface.all_bundles(),
      restricted_permissions:
        Platform.Access.RuntimeProfiles.translated_permissions(ToolSurface.all_bundles())
    })

    raw
  end

  defp index_of(haystack, needle) do
    [prefix, _rest] = String.split(haystack, needle, parts: 2)
    String.length(prefix)
  end

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_), do: nil

  # A slice from the MIDDLE of the text. The opening sentence of several tools'
  # `limitations` is boilerplate ("Pure read; …"); the middle is where the
  # tool-specific wording lives.
  defp distinctive_slice(text) do
    length = String.length(text)

    if length <= @slice_len do
      text
    else
      start = min(div(length, 4), length - @slice_len)
      String.slice(text, start, @slice_len)
    end
  end
end
