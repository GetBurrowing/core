defmodule PlatformWeb.ControlCenter.DeleteRuntimeWarningTest do
  @moduledoc """
  Task 01a1b34b stage 2: the Control Center delete confirmation lists the
  runtimes the delete will revoke.

  The list comes from `Federation.list_runtimes_to_revoke/1`, which reads the
  same query `Federation.revoke_runtimes_for_agent_multi/2` revokes from: a
  runtime is bound when its `agent_id` is the agent's id or it is the row
  `agents.runtime_id` points at. Already revoked runtimes are left out.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Repo

  @warning "#delete-agent-runtime-warning"

  defp uniq, do: System.unique_integer([:positive])

  defp agent!(attrs \\ %{}) do
    %Agent{}
    |> Agent.changeset(
      Map.merge(
        %{
          slug: "delete-warn-#{uniq()}",
          name: "Delete Warn Agent",
          status: "active",
          max_concurrent: 1,
          sandbox_mode: "off",
          runtime_type: "external",
          model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp runtime!(owner, agent_id, status \\ "active") do
    %AgentRuntime{}
    |> AgentRuntime.changeset(%{
      runtime_id: "delete-warn-rt-#{uniq()}",
      owner_user_id: owner.id,
      agent_id: agent_id,
      auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
      status: status
    })
    |> Repo.insert!()
  end

  defp point_at!(agent, runtime) do
    agent |> Agent.changeset(%{runtime_id: runtime.id}) |> Repo.update!()
  end

  defp open!(conn, owner, agent) do
    conn = init_test_session(conn, current_user_id: owner.id)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")
    view
  end

  defp request_delete!(view) do
    view |> element("#delete-agent", "Delete agent") |> render_click()
  end

  defp warning_text(view), do: view |> element(@warning) |> render()

  setup do
    owner = Platform.TenancyFixtures.root_admin!()
    agent = agent!()

    # Bound through agent_id.
    by_agent_id = runtime!(owner, agent.id)
    # Bound only through agents.runtime_id: agent_id is NULL.
    by_pointer = runtime!(owner, nil)
    agent = point_at!(agent, by_pointer)

    revoked = runtime!(owner, agent.id, "revoked")

    other_agent = agent!()
    other = runtime!(owner, other_agent.id)

    %{
      owner: owner,
      agent: agent,
      by_agent_id: by_agent_id,
      by_pointer: by_pointer,
      revoked: revoked,
      other: other
    }
  end

  test "names both bound runtimes, with status, once delete is requested", ctx do
    view = open!(ctx.conn, ctx.owner, ctx.agent)
    refute has_element?(view, @warning)

    request_delete!(view)

    text = warning_text(view)
    assert text =~ ctx.by_agent_id.runtime_id
    assert text =~ ctx.by_pointer.runtime_id
    assert text =~ "active"
    assert text =~ "Deleting this agent revokes these runtimes"
    assert text =~ "tokens stop working immediately"
    assert text =~ "connected gateways are disconnected"

    assert has_element?(view, "#delete-agent-runtime-#{ctx.by_agent_id.id}")
    assert has_element?(view, "#delete-agent-runtime-#{ctx.by_pointer.id}")
  end

  test "an already revoked runtime is not listed", ctx do
    view = open!(ctx.conn, ctx.owner, ctx.agent)
    request_delete!(view)

    refute warning_text(view) =~ ctx.revoked.runtime_id
    refute has_element?(view, "#delete-agent-runtime-#{ctx.revoked.id}")
  end

  test "another agent's runtime is not listed", ctx do
    view = open!(ctx.conn, ctx.owner, ctx.agent)
    request_delete!(view)

    refute warning_text(view) =~ ctx.other.runtime_id
    refute has_element?(view, "#delete-agent-runtime-#{ctx.other.id}")
  end

  test "cancel removes the warning", ctx do
    view = open!(ctx.conn, ctx.owner, ctx.agent)
    request_delete!(view)
    assert has_element?(view, @warning)

    view |> element("button", "Cancel delete") |> render_click()

    refute has_element?(view, @warning)
    assert has_element?(view, "#delete-agent", "Delete agent")
  end

  test "an agent with no runtimes shows no warning element", ctx do
    lonely = agent!()

    view = open!(ctx.conn, ctx.owner, lonely)
    request_delete!(view)

    assert has_element?(view, "#delete-agent", "Confirm delete")
    refute has_element?(view, @warning)
  end

  test "an agent whose only runtime is already revoked shows no warning element", ctx do
    lonely = agent!()
    runtime!(ctx.owner, lonely.id, "revoked")

    view = open!(ctx.conn, ctx.owner, lonely)
    request_delete!(view)

    assert has_element?(view, "#delete-agent", "Confirm delete")
    refute has_element?(view, @warning)
  end

  test "the list matches the runtimes the delete actually revokes", ctx do
    view = open!(ctx.conn, ctx.owner, ctx.agent)
    request_delete!(view)

    listed =
      for rt <- [ctx.by_agent_id, ctx.by_pointer, ctx.revoked, ctx.other],
          has_element?(view, "#delete-agent-runtime-#{rt.id}"),
          do: rt.id

    view |> element("#delete-agent", "Confirm delete") |> render_click()

    newly_revoked =
      for rt <- [ctx.by_agent_id, ctx.by_pointer, ctx.revoked, ctx.other],
          rt.status != "revoked",
          Repo.get!(AgentRuntime, rt.id).status == "revoked",
          do: rt.id

    assert Enum.sort(listed) == Enum.sort(newly_revoked)
    assert Enum.sort(listed) == Enum.sort([ctx.by_agent_id.id, ctx.by_pointer.id])
  end
end
