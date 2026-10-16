defmodule Platform.Federation.ToolAuthorizationTest do
  @moduledoc """
  Unit coverage for the shared capability gate both federation transports
  resolve through.

  Every assertion is written against a LITERAL `allowed_bundles` list, never
  against `AgentRuntime.valid_bundles/0` — that list and `ToolSurface`'s
  bundle list are known to disagree (`files`), and that mismatch is tracked
  separately. This suite must not depend on them matching.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.AgentRuntime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface
  alias Platform.Tenancy

  @chat_names ~w(send_media react space_list space_get_context space_get_messages space_search_messages)

  setup do
    org = Tenancy.get_org_by_slug!("sxi")

    internal = World.create_user!()
    World.plain_member!(internal, org)

    external = World.create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: external.id, org_id: org.id})

    %{internal_id: internal.id, external_id: external.id}
  end

  # ── Bundle scoping ─────────────────────────────────────────────────────

  describe "effective_tools/1 bundle scoping (internal principal)" do
    test "returns exactly the tools of the granted bundles", ctx do
      runtime = runtime(ctx.internal_id, ["federation"])

      assert ToolAuthorization.tool_names(runtime) == [
               "federation_status",
               "vault_fetch",
               "vault_list"
             ]
    end

    test "is a strict subset of the full surface for a narrow grant", ctx do
      runtime = runtime(ctx.internal_id, ~w(federation messaging space))
      names = ToolAuthorization.tool_names(runtime)

      assert length(names) < length(ToolSurface.tool_definitions())
      assert "federation_status" in names
      refute "task_create" in names
      refute "canvas.create" in names
    end

    test "empty allowed_bundles yields an empty list", ctx do
      assert ToolAuthorization.effective_tools(runtime(ctx.internal_id, [])) == []
    end

    test "a nil allowed_bundles column fails closed rather than raising" do
      assert ToolAuthorization.effective_tools(%AgentRuntime{allowed_bundles: nil}) == []
    end

    test "unknown bundle names are skipped silently", ctx do
      runtime = runtime(ctx.internal_id, ["federation", "not_a_bundle"])

      assert ToolAuthorization.tool_names(runtime) == [
               "federation_status",
               "vault_fetch",
               "vault_list"
             ]
    end

    test "duplicate bundle names do not duplicate tools", ctx do
      runtime = runtime(ctx.internal_id, ["federation", "federation"])

      assert ToolAuthorization.tool_names(runtime) == [
               "federation_status",
               "vault_fetch",
               "vault_list"
             ]
    end
  end

  # ── External principal intersection ────────────────────────────────────

  describe "effective_tools/1 external-principal intersection" do
    test "broad bundles are reduced to exactly the six chat tools", ctx do
      runtime = runtime(ctx.external_id, ~w(messaging space context_read task canvas))

      assert Enum.sort(ToolAuthorization.tool_names(runtime)) == Enum.sort(@chat_names)
    end

    test "fail-closed: external + [task] grants nothing", ctx do
      runtime = runtime(ctx.external_id, ["task"])

      assert ToolAuthorization.effective_tools(runtime) == []
    end

    test "the same broad bundles are unfiltered for an internal owner", ctx do
      names =
        ToolAuthorization.tool_names(runtime(ctx.internal_id, ~w(messaging space task canvas)))

      assert "task_create" in names
      assert "canvas.create" in names
      assert "space_leave" in names
    end

    test "external_principal?/1 distinguishes the two owners", ctx do
      assert ToolAuthorization.external_principal?(runtime(ctx.external_id, []))
      refute ToolAuthorization.external_principal?(runtime(ctx.internal_id, []))
      refute ToolAuthorization.external_principal?(%AgentRuntime{owner_user_id: nil})
    end
  end

  # ── authorize/2 ────────────────────────────────────────────────────────

  describe "authorize/2" do
    test ":ok for a tool inside the granted bundles", ctx do
      assert :ok = ToolAuthorization.authorize("task_create", runtime(ctx.internal_id, ["task"]))
    end

    test "{:error, :forbidden} for a tool outside them", ctx do
      runtime = runtime(ctx.internal_id, ["federation"])

      assert {:error, :forbidden} = ToolAuthorization.authorize("task_create", runtime)
    end

    test "{:error, :forbidden} for an unknown tool name", ctx do
      runtime = runtime(ctx.internal_id, ["task"])

      assert {:error, :forbidden} = ToolAuthorization.authorize("no_such_tool", runtime)
    end

    test "{:error, :forbidden} for a non-binary name", ctx do
      runtime = runtime(ctx.internal_id, ["task"])

      assert {:error, :forbidden} = ToolAuthorization.authorize(nil, runtime)
      assert {:error, :forbidden} = ToolAuthorization.authorize(%{"name" => "x"}, runtime)
    end

    test "the verdict matches membership in effective_tools/1 for every granted name", ctx do
      runtime = runtime(ctx.internal_id, ~w(federation task))

      for name <- ToolAuthorization.tool_names(runtime) do
        assert :ok = ToolAuthorization.authorize(name, runtime)
      end
    end
  end

  # ── Undeclared names are denied (legacy canvas aliases included) ───────

  describe "executable-but-undeclared tool names" do
    test "canvas_create / canvas_update really are executable and unlisted" do
      listed = Enum.map(ToolSurface.tool_definitions(), & &1.name)

      refute "canvas_create" in listed
      refute "canvas_update" in listed
      assert "canvas.create" in listed
      assert "canvas.patch" in listed
    end

    test "they are denied even when the canvas bundle is granted", ctx do
      runtime = runtime(ctx.internal_id, ["canvas"])

      assert {:error, :forbidden} = ToolAuthorization.authorize("canvas_create", runtime)
      assert {:error, :forbidden} = ToolAuthorization.authorize("canvas_update", runtime)

      assert :ok = ToolAuthorization.authorize("canvas.create", runtime)
      assert :ok = ToolAuthorization.authorize("canvas.patch", runtime)
    end

    test "they are denied for an external principal holding canvas", ctx do
      runtime = runtime(ctx.external_id, ~w(canvas messaging))

      assert {:error, :forbidden} = ToolAuthorization.authorize("canvas_create", runtime)
      assert {:error, :forbidden} = ToolAuthorization.authorize("canvas.create", runtime)
      assert :ok = ToolAuthorization.authorize("send_media", runtime)
    end

    test "no undeclared name can ever be authorized, for any grant", ctx do
      # Literal, not `AgentRuntime.valid_bundles/0` or `ToolSurface.all_bundles/0`.
      runtime =
        runtime(
          ctx.internal_id,
          ~w(canvas messaging task plan review space context_read federation memory skill attachment)
        )

      listed = MapSet.new(ToolSurface.tool_definitions(), & &1.name)

      for name <- ~w(canvas_create canvas_update no_such_tool) do
        refute MapSet.member?(listed, name)
        assert {:error, :forbidden} = ToolAuthorization.authorize(name, runtime)
      end
    end
  end

  # ── deny_reason/1 ────────────────────────────────────────────────────────

  describe "deny_reason/1" do
    test "a real catalogue tool name is :forbidden" do
      assert ToolAuthorization.deny_reason("plan_update") == :forbidden
    end

    test "a dots-vs-underscores miss suggests the real catalogue name" do
      assert ToolAuthorization.deny_reason("plan.update") == {:unknown_tool, "plan_update"}
    end

    test "a name with no plausible match suggests nothing" do
      assert ToolAuthorization.deny_reason("totally_made_up_tool") == {:unknown_tool, nil}
    end

    test "authorize/2 still denies both an undeclared name and a real-but-ungranted name, on a narrow-bundle runtime",
         ctx do
      runtime = runtime(ctx.internal_id, ["federation"])

      # Undeclared name entirely (separator mismatch on a catalogue tool).
      assert {:error, :forbidden} = ToolAuthorization.authorize("plan.update", runtime)
      # Real catalogue tool, just outside this runtime's granted bundles.
      assert {:error, :forbidden} = ToolAuthorization.authorize("plan_update", runtime)

      # Splitting the diagnostic in deny_reason/1 must never leak into
      # authorize/2 itself — a later refactor could otherwise turn this
      # diagnostic split into an authorization bypass.
      assert ToolAuthorization.deny_reason("plan.update") == {:unknown_tool, "plan_update"}
      assert ToolAuthorization.deny_reason("plan_update") == :forbidden
    end
  end

  # ── deny_message/1 ───────────────────────────────────────────────────────

  describe "deny_message/1" do
    test "a real catalogue tool names the required permission" do
      assert ToolAuthorization.deny_message("plan_update") ==
               "tool 'plan_update' requires permission 'tasks.write', which this agent does not hold or is capped at its owner"
    end

    test "an undeclared name with a suggestion names the closest declared tool" do
      assert ToolAuthorization.deny_message("plan.update") ==
               "unknown tool 'plan.update' (no such tool in the catalogue — this is a name lookup miss, not a permissions problem). Closest declared name: 'plan_update'."
    end

    test "an undeclared name with no suggestion has no trailing clause and no empty quotes" do
      message = ToolAuthorization.deny_message("totally_made_up_tool")

      assert message ==
               "unknown tool 'totally_made_up_tool' (no such tool in the catalogue — this is a name lookup miss, not a permissions problem)."

      refute message =~ "Closest declared name"
      refute message =~ "''"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp runtime(owner_user_id, allowed_bundles) do
    %AgentRuntime{owner_user_id: owner_user_id, allowed_bundles: allowed_bundles}
  end
end
