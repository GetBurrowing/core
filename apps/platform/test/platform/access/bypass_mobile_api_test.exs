defmodule Platform.Access.BypassMobileApiTest do
  use PlatformWeb.ConnCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Access.Grants
  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Mobile
  alias Platform.Mobile.AppEntities
  alias Platform.Repo
  alias Platform.Tasks

  defp bearer!(user) do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, %{token: token}} = Mobile.exchange_code(code, verifier, %{app_install_id: "bypass"})
    token
  end

  defp agent! do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "bma-agent-#{n}", name: "BMA Agent #{n}", status: "active"})
  end

  test "mobile and App API space reads disappear after a chat deny", %{conn: conn} do
    world = external_world()
    user = world.int
    space = world.a
    agent = agent!()
    add_agent!(space.id, agent.id)
    token = bearer!(user)

    # Positive controls on the exact space and user used below.
    assert {:ok, _, _} = AppEntities.authorize_space(user, space.id)
    assert {:ok, []} = AppEntities.poll_messages(user, space.id)
    assert Enum.any?(AppEntities.list_agents(user), &(&1.id == agent.id))

    before_ids =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/app/spaces")
      |> json_response(200)
      |> Map.fetch!("spaces")
      |> Enum.map(& &1["id"])

    assert space.id in before_ids

    assert {:ok, _} =
             Grants.deny(%{
               principal: {:user, user.id},
               permission: "chat.read",
               resource: {:space, space.id}
             })

    assert AppEntities.authorize_space(user, space.id) == {:error, :forbidden}
    assert AppEntities.poll_messages(user, space.id) == {:error, :forbidden}
    refute Enum.any?(AppEntities.list_agents(user), &(&1.id == agent.id))

    after_ids =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/app/spaces")
      |> json_response(200)
      |> Map.fetch!("spaces")
      |> Enum.map(& &1["id"])

    refute space.id in after_ids

    assert build_conn()
           |> put_req_header("authorization", "Bearer " <> token)
           |> post("/api/app/spaces/#{space.id}/messages", %{"text" => "denied"})
           |> json_response(403) == %{"error" => "forbidden"}
  end

  test "meeting detail resolves as not found after its chat space is denied" do
    world = external_world()
    user = world.int

    {:ok, project} =
      Tasks.create_project(%{
        name: "BMA #{System.unique_integer([:positive])}",
        org_id: world.org_a.id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "BMA meeting #{System.unique_integer([:positive])}"
      })

    assert {:ok, %{id: id}} = Meetings.fetch_meeting_for_user(user, meeting.slug)
    assert id == meeting.id

    assert {:ok, _} =
             Grants.deny(%{
               principal: {:user, user.id},
               permission: "chat.read",
               resource: {:space, meeting.chat_space_id}
             })

    assert Meetings.fetch_meeting_for_user(user, meeting.slug) == {:error, :not_found}
  end
end
