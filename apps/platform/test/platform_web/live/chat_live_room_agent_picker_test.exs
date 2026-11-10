defmodule PlatformWeb.ChatLiveRoomAgentPickerTest do
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant}
  alias Platform.Repo

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "room-picker-#{n}@example.test",
      name: "Picker #{n}",
      oidc_sub: "room-picker-#{n}",
      preferences: %{"first_run_goal" => "existing"}
    })
  end

  defp agent!(name, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        Agent,
        Map.merge(%{slug: "picker-agent-#{n}", name: "#{name} #{n}", status: "active"}, attrs)
      )
    )
  end

  defp room!(owner) do
    n = System.unique_integer([:positive])

    {:ok, room} =
      Chat.create_channel(%{
        name: "Picker room #{n}",
        slug: "picker-room-#{n}",
        created_by: owner.id
      })

    room
  end

  defp mount_room(conn, user, room) do
    {:ok, view, _} =
      conn |> init_test_session(current_user_id: user.id) |> live(~p"/chat/#{room.slug}")

    view
  end

  defp rows(room, agent),
    do:
      Repo.all(
        from(p in Participant,
          where:
            p.space_id == ^room.id and p.participant_type == "agent" and
              p.participant_id == ^agent.id
        )
      )

  defp option(agent), do: "#room-agent-list button[data-principal-id='#{agent.id}']"

  defp open(view),
    do: view |> element("button[phx-click*='open_room_agent_picker']") |> render_click()

  test "empty room opens the tagging list and one pick joins without navigation or a message", %{
    conn: conn
  } do
    owner = user!()
    room = room!(owner)
    agent = agent!("Helper")
    view = mount_room(conn, owner, room)
    before_count = Repo.aggregate(Message, :count)

    open(view)
    assert has_element?(view, "#empty-room-agents > #room-agent-picker")
    assert has_element?(view, "#room-agent-list-wrap[data-role='mention-list']")
    assert has_element?(view, option(agent), agent.name)
    refute has_element?(view, "#room-agent-list [data-kind='user']")
    refute has_element?(view, "#room-agent-list [data-kind='broadcast']")
    view |> element(option(agent)) |> render_click()

    assert [%{attention_mode: "mention", history_visible_from: history}] = rows(room, agent)
    assert history != nil
    assert has_element?(view, "#compose-form")
    refute has_element?(view, "#room-agent-picker")
    assert Repo.aggregate(Message, :count) == before_count
    refute_redirected(view)

    render_click(view, "room_add_agent", %{"agent_id" => agent.id})
    assert length(rows(room, agent)) == 1
  end

  test "search, cancel, and already-present or archived agents use the existing eligibility set",
       %{conn: conn} do
    owner = user!()
    room = room!(owner)
    wanted = agent!("ZebraUnique")
    other = agent!("Albatross")
    archived = agent!("Archived", %{status: "archived"})
    present = agent!("Present")
    {:ok, _} = Chat.admin_add_agent(room, owner.id, present.id)
    view = mount_room(conn, owner, room)
    open(view)
    assert has_element?(view, option(wanted))
    assert has_element?(view, option(other))
    refute has_element?(view, option(archived))
    refute has_element?(view, option(present))

    view |> form("#room-agent-search-form", query: "ZebraUnique") |> render_change()
    assert has_element?(view, option(wanted))
    refute has_element?(view, option(other))

    view
    |> element("#room-agent-picker button[aria-label='Close agent picker']")
    |> render_click()

    refute has_element?(view, "#room-agent-picker")
    assert rows(room, wanted) == []
  end

  test "a member cannot open or forge an add", %{conn: conn} do
    owner = user!()
    member = user!()
    room = room!(owner)
    agent = agent!("Protected")

    {:ok, _} =
      Chat.add_participant(room.id, %{
        participant_type: "user",
        participant_id: member.id,
        display_name: member.name,
        joined_at: DateTime.utc_now()
      })

    view = mount_room(conn, member, room)
    assert has_element?(view, "#compose-form")
    refute has_element?(view, "button[phx-click*='open_room_agent_picker']")
    render_click(view, "open_room_agent_picker", %{})
    refute has_element?(view, "#room-agent-picker")
    render_click(view, "room_add_agent", %{"agent_id" => agent.id})
    assert rows(room, agent) == []
  end

  test "revoking authority while the list is open refuses the pick", %{conn: conn} do
    owner = user!()
    room = room!(owner)
    agent = agent!("Protected")
    view = mount_room(conn, owner, room)
    open(view)
    assert has_element?(view, option(agent))
    participant = Chat.list_participants(room.id) |> Enum.find(&(&1.participant_id == owner.id))
    participant |> Ecto.Changeset.change(role: "member") |> Repo.update!()
    view |> element(option(agent)) |> render_click()
    assert rows(room, agent) == []
  end

  test "room switch clears the picker and an old selection cannot add to the new room", %{
    conn: conn
  } do
    owner = user!()
    first = room!(owner)
    second = room!(owner)
    agent = agent!("Traveller")
    view = mount_room(conn, owner, first)
    open(view)
    assert has_element?(view, option(agent))
    render_patch(view, ~p"/chat/#{second.slug}")
    refute has_element?(view, "#room-agent-picker")
    render_click(view, "room_add_agent", %{"agent_id" => agent.id, "space_id" => first.id})
    assert rows(first, agent) == []
    assert rows(second, agent) == []
    open(view)
    view |> element(option(agent)) |> render_click()
    assert length(rows(second, agent)) == 1
    assert rows(first, agent) == []
  end

  test "a forged ineligible agent is refused by the same scoped writer", %{conn: conn} do
    owner = user!()
    room = room!(owner)
    room = room |> Ecto.Changeset.change(workspace_id: Ecto.UUID.generate()) |> Repo.update!()
    eligible = agent!("In scope", %{workspace_id: room.workspace_id})
    outside = agent!("Other workspace", %{workspace_id: Ecto.UUID.generate()})
    view = mount_room(conn, owner, room)
    open(view)
    assert has_element?(view, option(eligible))
    refute has_element?(view, option(outside))
    render_click(view, "room_add_agent", %{"agent_id" => outside.id})
    assert rows(room, outside) == []
    view |> element(option(eligible)) |> render_click()
    assert length(rows(room, eligible)) == 1
  end

  for authority <- [:org_admin, :root_admin] do
    test "#{authority} picks without promotion and rechecks revoked authority", %{conn: conn} do
      actor = user!()
      room = room!(user!())

      room =
        room
        |> Ecto.Changeset.change(org_id: Platform.Tenancy.get_org_by_slug!("initech").id)
        |> Repo.update!()

      org_id =
        if unquote(authority) == :root_admin,
          do: Platform.Tenancy.get_root_org().id,
          else: room.org_id

      if unquote(authority) == :root_admin do
        %Platform.Tenancy.OrgMembership{}
        |> Platform.Tenancy.OrgMembership.changeset(%{
          user_id: actor.id,
          org_id: room.org_id,
          role: "member",
          external: false
        })
        |> Repo.insert!()
      end

      membership =
        %Platform.Tenancy.OrgMembership{}
        |> Platform.Tenancy.OrgMembership.changeset(%{
          user_id: actor.id,
          org_id: org_id,
          role: "admin",
          external: false
        })
        |> Repo.insert!()

      agent = agent!("Admin helper")
      view = mount_room(conn, actor, room)
      open(view)
      assert has_element?(view, option(agent))
      view |> element(option(agent)) |> render_click()
      assert [%{history_visible_from: history}] = rows(room, agent)
      assert history != nil

      assert Enum.find(Chat.list_participants(room.id), &(&1.participant_id == actor.id)).role ==
               "member"

      other = agent!("Revoked helper")
      open(view)
      assert has_element?(view, option(other))
      membership |> Ecto.Changeset.change(role: "member") |> Repo.update!()
      render_click(view, "room_add_agent", %{"agent_id" => other.id})
      assert rows(room, other) == []
    end
  end
end
