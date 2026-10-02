defmodule PlatformWeb.ChatLiveMembersTest do
  @moduledoc """
  Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 3: the channel members panel
  (`PlatformWeb.ChatLive.MembersComponent`) and the deletion of the orphaned
  `PlatformWeb.Components.Chat.AddParticipantSheet`.

  The forged-event tests are the load-bearing ones: the panel hides its
  controls from members, but hiding is affordance only, so each forged event
  is pushed straight at the component and the DB is read afterwards. Every
  refute of a control sits beside an assert that the panel itself rendered,
  so an empty page cannot pass it.

  The bracketed tokens are fixtures exercising the mention parser.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo

  @panel "[data-role=members-panel]"
  @open_button "[data-role=members-open]"
  @add_form "[data-role=members-add-agent]"
  @remove_button "[data-role=members-remove-agent]"

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "members-#{tag}-#{n}@example.com",
      name: "Members #{tag} #{n}",
      oidc_sub: "oidc-members-#{tag}-#{n}"
    })
  end

  defp agent!(name) do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "members-agent-#{n}", name: "#{name}#{n}", status: "active"})
  end

  # Stage 1 seats `created_by` as the channel's admin.
  defp owned_channel!(admin) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_channel(%{name: "Members #{n}", slug: "members-#{n}", created_by: admin.id})

    space
  end

  defp live_as(conn, user, path) do
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, path)
    view
  end

  defp agent_rows(space_id, agent_id) do
    Repo.all(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      )
    )
  end

  defp agent_row_selector(agent), do: "[data-role=members-agent-row][data-agent-id='#{agent.id}']"

  test "an admin adds an agent and sees its row, then removes it and the row disappears",
       %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    agent = agent!("Helper")
    view = live_as(conn, admin, ~p"/chat/#{space.slug}")

    view |> element(@open_button) |> render_click()
    assert has_element?(view, @panel)
    assert has_element?(view, "[data-role=members-no-agents]")
    refute has_element?(view, agent_row_selector(agent))

    view |> form(@add_form, %{"agent_id" => agent.id}) |> render_submit()

    assert has_element?(view, agent_row_selector(agent))
    assert [row] = agent_rows(space.id, agent.id)
    assert %DateTime{} = row.history_visible_from

    view
    |> element("#{agent_row_selector(agent)} #{@remove_button}")
    |> render_click()

    refute has_element?(view, agent_row_selector(agent))
    assert agent_rows(space.id, agent.id) == []
  end

  test "a member sees the lists but no add or remove controls", %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    agent = agent!("Present")
    {:ok, _} = Chat.admin_add_agent(space, admin.id, agent.id)

    member = user!("member")
    view = live_as(conn, member, ~p"/chat/#{space.slug}")

    view |> element(@open_button) |> render_click()

    assert has_element?(view, @panel)
    assert has_element?(view, agent_row_selector(agent))
    assert render(view) =~ admin.name
    refute has_element?(view, @add_form)
    refute has_element?(view, @remove_button)
  end

  test "a member forging members_add_agent gets a flash and the DB is unchanged",
       %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    agent = agent!("Forged")
    member = user!("member")
    view = live_as(conn, member, ~p"/chat/#{space.slug}")

    view
    |> with_target("#chat-members")
    |> render_hook("members_add_agent", %{"agent_id" => agent.id})

    assert render(view) =~ "Only a channel admin can bring agents into this channel."
    assert agent_rows(space.id, agent.id) == []
  end

  test "a member forging members_remove_agent gets a flash and the row stays",
       %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    agent = agent!("Kept")
    {:ok, row} = Chat.admin_add_agent(space, admin.id, agent.id)
    member = user!("member")
    view = live_as(conn, member, ~p"/chat/#{space.slug}")

    view |> element(@open_button) |> render_click()
    assert has_element?(view, agent_row_selector(agent))
    refute has_element?(view, @remove_button)

    view
    |> with_target("#chat-members")
    |> render_hook("members_remove_agent", %{"participant_id" => row.id})

    assert render(view) =~ "Only a channel admin can remove agents from this channel."
    assert [_] = agent_rows(space.id, agent.id)
    assert has_element?(view, agent_row_selector(agent))
  end

  test "the members button renders in a channel and not in a DM or a group", %{conn: conn} do
    a = user!("a")
    b = user!("b")
    c = user!("c")

    channel = owned_channel!(a)
    {:ok, dm} = Chat.find_or_create_dm(a.id, "user", b.id)

    {:ok, group} =
      Chat.create_group_conversation(a.id, [%{type: "user", id: b.id}, %{type: "user", id: c.id}])

    # Positive control: the selector does match the button where it belongs.
    channel_view = live_as(conn, a, ~p"/chat/#{channel.slug}")
    assert has_element?(channel_view, @open_button)

    dm_view = live_as(Phoenix.ConnTest.build_conn(), a, "/chat/#{Chat.space_path_segment(dm)}")
    assert has_element?(dm_view, "#compose-form")
    refute has_element?(dm_view, @open_button)

    group_view =
      live_as(Phoenix.ConnTest.build_conn(), a, "/chat/#{Chat.space_path_segment(group)}")

    assert has_element?(group_view, "#compose-form")
    refute has_element?(group_view, @open_button)
  end

  test "the refused-summon notice's View members opens the panel", %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    agent = agent!("Refused")
    member = user!("member")
    view = live_as(conn, member, ~p"/chat/#{space.slug}")

    view
    |> form("#compose-form", compose: %{text: "@[#{agent.slug}] hi"})
    |> render_submit()

    assert has_element?(view, "[data-role=refused-summon-notice]")
    refute has_element?(view, @panel)

    view |> element("[data-role=refused-summon-view-members]") |> render_click()

    assert has_element?(view, @panel)
    refute has_element?(view, @add_form)
  end

  test "an agent added in another session appears in the open panel without a reload",
       %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    agent = agent!("Live")
    view = live_as(conn, admin, ~p"/chat/#{space.slug}")

    view |> element(@open_button) |> render_click()
    refute has_element?(view, agent_row_selector(agent))

    {:ok, _} = Chat.admin_add_agent(space, admin.id, agent.id)

    # Two mailbox barriers: the first lets the LiveView handle the
    # {:participant_joined} broadcast, which queues a send_update to the
    # panel; the second lands after that update.
    _ = render(view)
    _ = render(view)
    assert has_element?(view, agent_row_selector(agent))
  end

  test "the orphaned add-participant sheet module is gone" do
    refute Code.ensure_loaded?(PlatformWeb.Components.Chat.AddParticipantSheet)
    # Positive control: the check can say yes for a module that exists.
    assert Code.ensure_loaded?(PlatformWeb.ChatLive.MembersComponent)
  end
end
