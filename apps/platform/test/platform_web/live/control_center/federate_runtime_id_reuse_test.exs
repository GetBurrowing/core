defmodule PlatformWeb.ControlCenter.FederateRuntimeIdReuseTest do
  @moduledoc """
  Task 01a1b34b stage 3, through the onboarding federate form: an id whose
  runtime is revoked federates again onto the same row, and an id held by a
  runtime that is not revoked gets a flash saying it is in use and must be
  revoked first.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation
  alias Platform.Repo
  alias PlatformWeb.ControlCenter.AgentData

  defp create_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "federate-reuse-#{n}@example.com",
      name: "Federate Reuse #{n}",
      oidc_sub: "oidc-federate-reuse-#{n}"
    })
  end

  defp provision!(owner, runtime_id) do
    n = System.unique_integer([:positive])

    {:ok, agent, runtime, token} =
      Federation.provision_agent_runtime(
        owner.id,
        %{slug: "held-#{n}", name: "Held #{n}", status: "active"},
        %{runtime_id: runtime_id, tool_profile: AgentRuntime.default_tool_profile()}
      )

    {agent, runtime, token}
  end

  defp submit_federate(conn, user, runtime_id, agent_name) do
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/control")
    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "federate"})

    view
    |> form("#federate-form",
      federate: %{runtime_id: runtime_id, display_name: "", agent_name: agent_name}
    )
    |> render_submit()
  end

  defp rows(runtime_id),
    do: Repo.all(from(r in AgentRuntime, where: r.runtime_id == ^runtime_id))

  test "an id held by an active runtime: the flash says it is in use and must be revoked first",
       %{conn: conn} do
    rid = "form-held-#{System.unique_integer([:positive])}"
    {_agent, runtime, token} = provision!(create_user(), rid)
    n = System.unique_integer([:positive])

    html = submit_federate(conn, create_user(), rid, "Intruder #{n}")

    assert html =~ "is in use by an active runtime"
    assert html =~ "Revoke that runtime first"
    refute html =~ "runtime_id has already been taken"

    assert [row] = rows(rid)
    assert row.id == runtime.id
    assert row.auth_token_hash == AgentRuntime.hash_token(token)
    assert Repo.get_by(Agent, slug: "intruder-#{n}") == nil
  end

  test "an id whose runtime was revoked federates again onto the same row", %{conn: conn} do
    rid = "form-reuse-#{System.unique_integer([:positive])}"
    {agent, runtime, _token} = provision!(create_user(), rid)
    :ok = AgentData.delete_agent(agent)

    user = create_user()
    n = System.unique_integer([:positive])
    html = submit_federate(conn, user, rid, "Again #{n}")

    assert html =~ "Federated agent Again #{n} created."
    assert [row] = rows(rid)
    assert row.id == runtime.id
    assert row.status == "active"
    assert row.owner_user_id == user.id
    assert row.agent_id == Repo.get_by!(Agent, slug: "again-#{n}").id
  end
end
