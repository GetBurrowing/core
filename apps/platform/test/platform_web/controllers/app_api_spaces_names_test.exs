defmodule PlatformWeb.AppApiSpacesNamesTest do
  @moduledoc """
  `GET /api/app/spaces` never emits a null `name`.

  Burrow iOS decodes `name` as a non-optional `String`; a DM or unnamed group
  (`chat_spaces.name` NULL) failed the whole list decode, and the share sheet
  showed "Couldn't load your spaces".
  """
  use PlatformWeb.ConnCase, async: true

  import Platform.ExternalUserFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Mobile
  alias Platform.Repo

  defp bearer_token!(user) do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, %{token: token}} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})
    token
  end

  defp agent!(name) do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "names-agent-#{n}", name: "#{name} #{n}", status: "active"})
  end

  defp list_spaces(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/api/app/spaces")
    |> json_response(200)
    |> Map.fetch!("spaces")
    |> Map.new(&{&1["id"], &1})
  end

  test "DMs and unnamed groups get non-null names; a named channel keeps its name",
       %{conn: conn} do
    me = create_user!(%{name: "Alex Self"})
    other = create_user!(%{name: "Dana Other"})
    agent = agent!("Higgins")

    channel = channel!(%{name: "General Chat"})
    add_user!(channel.id, me.id)

    {:ok, user_dm} = Chat.find_or_create_dm(me.id, "user", other.id)
    {:ok, agent_dm} = Chat.find_or_create_dm(me.id, "agent", agent.id)

    {:ok, group} =
      Chat.create_group_conversation(me.id, [
        %{type: "user", id: other.id},
        %{type: "agent", id: agent.id}
      ])

    # The prod shape this guards: no name, no slug.
    for space <- [user_dm, agent_dm, group] do
      assert is_nil(space.name)
      assert is_nil(space.slug)
    end

    spaces = list_spaces(conn, bearer_token!(me))

    for {_id, space} <- spaces do
      assert is_binary(space["name"]) and space["name"] != "", inspect(space)
    end

    assert spaces[channel.id]["name"] == "General Chat"
    assert spaces[user_dm.id]["name"] == "Dana Other"
    assert spaces[agent_dm.id]["name"] == agent.name
    assert spaces[group.id]["name"] =~ "Dana Other"
    refute spaces[group.id]["name"] =~ "Alex Self"

    # DMs have no slug, so the app routes by `path_segment`.
    for {_id, space} <- spaces do
      assert is_binary(space["path_segment"]) and space["path_segment"] != "", inspect(space)
    end

    assert spaces[user_dm.id]["path_segment"] == Chat.space_path_segment(user_dm)
    assert spaces[channel.id]["path_segment"] == Chat.space_path_segment(channel)
  end

  # Task 01a111bb: "general" in two orgs must be told apart, by the SPACE's
  # own org, never the user's.
  test "each space carries its own org; DMs and org-less spaces carry null", %{conn: conn} do
    me = create_user!(%{name: "Two Orgs"})
    other = create_user!()
    legacy = Platform.Tenancy.get_org_by_slug!("globex")
    red_star = Platform.Tenancy.get_org_by_slug!("initech")
    plain_member!(me, legacy)
    plain_member!(me, red_star)

    n = System.unique_integer([:positive])
    general_a = channel!(%{name: "general", slug: "general-a-#{n}", org_id: legacy.id})
    general_b = channel!(%{name: "general", slug: "general-b-#{n}", org_id: red_star.id})
    orgless = channel!(%{name: "No Org #{n}"})
    for space <- [general_a, general_b, orgless], do: add_user!(space.id, me.id)
    {:ok, dm} = Chat.find_or_create_dm(me.id, "user", other.id)

    spaces = list_spaces(conn, bearer_token!(me))

    assert spaces[general_a.id]["org"] == %{"id" => legacy.id, "name" => legacy.name}
    assert spaces[general_b.id]["org"] == %{"id" => red_star.id, "name" => red_star.name}
    assert spaces[general_a.id]["org"]["name"] != spaces[general_b.id]["org"]["name"]
    assert spaces[orgless.id]["org"] == nil
    assert Map.has_key?(spaces[dm.id], "org")
    assert spaces[dm.id]["org"] == nil
  end
end
