defmodule PlatformWeb.ChatLiveMembersTest do
  @moduledoc """
  The Members sheet (`PlatformWeb.ChatLive.MembersComponent`): introduced as a
  centred channel panel by task 01a0fd62 stage 3, reshaped into a phone sheet
  and a desktop popover by task 01a1557a-8f80 stage 3, which added the online
  and away words from presence and opened it to every space but a DM.

  The forged-event tests are the load-bearing ones for the admin controls:
  hiding them is affordance only, so each forged event is pushed straight at
  the component and the DB is read afterwards. Every refute of a control sits
  beside an assert that the sheet itself rendered, so an empty page cannot
  pass it.

  The component renders twice (sheet and popover), so element selectors are
  scoped to one surface.

  The bracketed tokens are fixtures exercising the mention parser.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @popover "#members-popover"
  @sheet "#members-sheet [data-role=members-sheet-body]"
  # The desktop entry is the details panel's Members row (Burrow redesign 22
  # stage 4 deleted the header button); `live_as/3` opens the panel.
  @open_button "#details-panel [data-role=details-members]"
  @add_form "#members-popover [data-role=members-add-agent]"
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
  defp owned_channel!(admin, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_channel(
        Map.merge(%{name: "Members #{n}", slug: "members-#{n}", created_by: admin.id}, attrs)
      )

    space
  end

  defp join!(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp org_member!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp live_as(conn, user, path) do
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, path)
    render_click(view, "details_open", %{"page" => "space"})
    view
  end

  defp open_members(view) do
    view |> element(@open_button) |> render_click()
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

  defp agent_row_selector(agent),
    do: "#{@popover} [data-role=members-agent-row][data-agent-id='#{agent.id}']"

  # `[{user_id, presence word}]` in rendered order, read from one surface.
  defp people(view, scope \\ @popover) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{scope} [data-role=members-person-row]")
    |> Enum.map(fn node ->
      {node |> LazyHTML.attribute("data-user-id") |> List.first(),
       node |> LazyHTML.attribute("data-presence") |> List.first()}
    end)
  end

  # Two mailbox barriers: the first lets the LiveView handle the broadcast,
  # which queues a send_update to the sheet; the second lands after it.
  defp settle(view) do
    _ = render(view)
    _ = render(view)
    view
  end

  describe "people: online and away from presence" do
    setup do
      org = Tenancy.get_org_by_slug!("globex")

      viewer = user!("viewer")
      online = user!("online")
      elsewhere = user!("elsewhere")
      away = user!("away")
      for u <- [viewer, online, elsewhere, away], do: org_member!(u, org)

      space = owned_channel!(viewer, %{org_id: org.id, name: "members-test"})
      for u <- [online, elsewhere, away], do: join!(space, u)

      # A second channel the viewer shares with `elsewhere` only.
      second = owned_channel!(viewer, %{org_id: org.id})
      join!(second, elsewhere)

      %{
        viewer: viewer,
        online: online,
        elsewhere: elsewhere,
        away: away,
        space: space,
        second: second
      }
    end

    test "online first with the viewer leading, then away; each row says its word", ctx do
      {:ok, _} =
        ChatPresence.track_in_space(self(), ctx.space.id, ctx.online.id, %{
          participant_type: "user",
          display_name: ctx.online.name
        })

      {:ok, _} =
        ChatPresence.track_in_space(self(), ctx.second.id, ctx.elsewhere.id, %{
          participant_type: "user",
          display_name: ctx.elsewhere.name
        })

      view = build_conn() |> live_as(ctx.viewer, ~p"/chat/#{ctx.space.slug}") |> open_members()

      assert has_element?(view, @popover, "Members · members-test")

      online_sorted =
        Enum.sort_by([ctx.online, ctx.elsewhere], &String.downcase(&1.name))
        |> Enum.map(&{&1.id, "online"})

      # The viewer leads; the member online only in ANOTHER shared space is
      # online; the untracked member is away.
      assert people(view) ==
               [{ctx.viewer.id, "online"}] ++ online_sorted ++ [{ctx.away.id, "away"}]

      assert has_element?(
               view,
               "#{@popover} [data-user-id='#{ctx.viewer.id}'] [data-role=members-you]"
             )

      refute has_element?(
               view,
               "#{@popover} [data-user-id='#{ctx.away.id}'] [data-role=members-you]"
             )

      assert has_element?(view, "#{@popover} [data-user-id='#{ctx.away.id}']", "away")

      # The phone sheet carries the same rows.
      assert people(view, @sheet) == people(view)
    end

    test "a presence join and leave re-render the row without a reload", ctx do
      view = build_conn() |> live_as(ctx.viewer, ~p"/chat/#{ctx.space.slug}") |> open_members()

      assert {ctx.elsewhere.id, "away"} in people(view)

      # Comes online in the OTHER shared channel: online anywhere the viewer
      # can see.
      {:ok, _} =
        ChatPresence.track_in_space(self(), ctx.second.id, ctx.elsewhere.id, %{
          participant_type: "user",
          display_name: ctx.elsewhere.name
        })

      settle(view)
      assert {ctx.elsewhere.id, "online"} in people(view)

      :ok = ChatPresence.untrack_in_space(self(), ctx.second.id, ctx.elsewhere.id)

      settle(view)
      assert {ctx.elsewhere.id, "away"} in people(view)
    end

    test "agents are listed under Agents, never under People", ctx do
      agent = agent!("Lead")
      {:ok, _} = Chat.admin_add_agent(ctx.space, ctx.viewer.id, agent.id)

      view = build_conn() |> live_as(ctx.viewer, ~p"/chat/#{ctx.space.slug}") |> open_members()

      assert has_element?(view, agent_row_selector(agent), "awake")

      refute has_element?(
               view,
               "#{@popover} [data-role=members-people] [data-user-id='#{agent.id}']"
             )

      refute agent.id in Enum.map(people(view), &elem(&1, 0))
      # Positive control: People is populated.
      assert {ctx.viewer.id, "online"} in people(view)
    end
  end

  test "an agent row reads silenced, without its accent, when the agent is silenced",
       %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    awake = agent!("Awake")
    quiet = agent!("Quiet")
    {:ok, _} = Chat.admin_add_agent(space, admin.id, awake.id)
    {:ok, quiet_row} = Chat.admin_add_agent(space, admin.id, quiet.id)
    {:ok, _} = Chat.set_agent_silenced({:user, admin.id}, space.id, quiet_row.id, true)

    view = conn |> live_as(admin, ~p"/chat/#{space.slug}") |> open_members()

    assert has_element?(view, "#{agent_row_selector(awake)}[data-agent-slot]", "awake")
    assert has_element?(view, "#{agent_row_selector(quiet)}[data-state=silenced]", "silenced")
    refute has_element?(view, "#{agent_row_selector(quiet)}[data-agent-slot]")
  end

  test "an admin adds an agent and sees its row, then removes it and the row disappears",
       %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    agent = agent!("Helper")
    view = conn |> live_as(admin, ~p"/chat/#{space.slug}") |> open_members()

    assert has_element?(view, @popover)
    assert has_element?(view, "#{@popover} [data-role=members-no-agents]")
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
    view = conn |> live_as(member, ~p"/chat/#{space.slug}") |> open_members()

    assert has_element?(view, @popover)
    assert has_element?(view, agent_row_selector(agent))
    assert has_element?(view, @popover, admin.name)
    refute has_element?(view, "[data-role=members-add-agent]")
    refute has_element?(view, @remove_button)
  end

  test "an admin sees Add agent", %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    view = conn |> live_as(admin, ~p"/chat/#{space.slug}") |> open_members()

    assert has_element?(view, @add_form)
    assert has_element?(view, "#{@add_form} button", "Add agent")
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
    view = conn |> live_as(member, ~p"/chat/#{space.slug}") |> open_members()

    assert has_element?(view, agent_row_selector(agent))
    refute has_element?(view, @remove_button)

    view
    |> with_target("#chat-members")
    |> render_hook("members_remove_agent", %{"participant_id" => row.id})

    assert render(view) =~ "Only a channel admin can remove agents from this channel."
    assert [_] = agent_rows(space.id, agent.id)
    assert has_element?(view, agent_row_selector(agent))
  end

  test "the members button renders in a channel and a group, not in a DM", %{conn: conn} do
    a = user!("a")
    b = user!("b")
    c = user!("c")

    channel = owned_channel!(a)
    {:ok, dm} = Chat.find_or_create_dm(a.id, "user", b.id)

    {:ok, group} =
      Chat.create_group_conversation(a.id, [%{type: "user", id: b.id}, %{type: "user", id: c.id}])

    channel_view = live_as(conn, a, ~p"/chat/#{channel.slug}")
    assert has_element?(channel_view, @open_button)
    assert has_element?(channel_view, @open_button, "1 person")

    group_view =
      live_as(Phoenix.ConnTest.build_conn(), a, "/chat/#{Chat.space_path_segment(group)}")

    assert has_element?(group_view, @open_button, "3 people")
    group_view |> element(@open_button) |> render_click()
    assert has_element?(group_view, @popover)

    dm_view = live_as(Phoenix.ConnTest.build_conn(), a, "/chat/#{Chat.space_path_segment(dm)}")
    assert has_element?(dm_view, "#compose-form")
    refute has_element?(dm_view, @open_button)

    # A forged open in a DM opens nothing.
    render_click(dm_view, "members_open", %{})
    refute has_element?(dm_view, @popover)
  end

  test "Esc and the sheet's close shut it", %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    view = conn |> live_as(admin, ~p"/chat/#{space.slug}") |> open_members()
    assert has_element?(view, @popover)

    view |> element(@popover) |> render_keydown(%{"key" => "Escape"})
    settle(view)
    refute has_element?(view, @popover)

    open_members(view)
    assert has_element?(view, "#members-sheet[data-swipe-dismiss]")
    view |> element("#members-sheet .sheet-handle-button") |> render_click()
    settle(view)
    refute has_element?(view, @popover)
  end

  test "the refused-summon notice's View members opens the sheet", %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    agent = agent!("Refused")
    member = user!("member")
    view = live_as(conn, member, ~p"/chat/#{space.slug}")

    view
    |> form("#compose-form", compose: %{text: "@[#{agent.slug}] hi"})
    |> render_submit()

    assert has_element?(view, "[data-role=refused-summon-notice]")
    refute has_element?(view, @popover)

    view |> element("[data-role=refused-summon-view-members]") |> render_click()

    assert has_element?(view, @popover)
    refute has_element?(view, "[data-role=members-add-agent]")
  end

  test "an agent added in another session appears in the open sheet without a reload",
       %{conn: conn} do
    admin = user!("admin")
    space = owned_channel!(admin)
    agent = agent!("Live")
    view = conn |> live_as(admin, ~p"/chat/#{space.slug}") |> open_members()

    refute has_element?(view, agent_row_selector(agent))

    {:ok, _} = Chat.admin_add_agent(space, admin.id, agent.id)

    settle(view)
    assert has_element?(view, agent_row_selector(agent))
  end

  test "the orphaned add-participant sheet module is gone" do
    refute Code.ensure_loaded?(PlatformWeb.Components.Chat.AddParticipantSheet)
    # Positive control: the check can say yes for a module that exists.
    assert Code.ensure_loaded?(PlatformWeb.ChatLive.MembersComponent)
  end

  describe "channel admins: Make admin / Remove admin (task 01a19355 stage 3)" do
    defp person_row(user, scope \\ @popover),
      do: "#{scope} [data-role=members-person-row][data-user-id='#{user.id}']"

    defp toggle(user, scope \\ @popover),
      do: "#{person_row(user, scope)} [data-role=members-role-toggle]"

    defp role_in_db(space, user) do
      Repo.one!(
        from(p in Participant,
          where:
            p.space_id == ^space.id and p.participant_type == "user" and
              p.participant_id == ^user.id,
          select: p.role
        )
      )
    end

    defp make_admin!(space, user) do
      row = Repo.get_by!(Participant, space_id: space.id, participant_id: user.id)
      {:ok, _} = Chat.update_participant(row, %{role: "admin"})
    end

    defp participant_id(space, user),
      do: Repo.get_by!(Participant, space_id: space.id, participant_id: user.id).id

    test "a channel admin sees Make admin on a member, Remove admin on a co-admin, none on agents",
         %{conn: conn} do
      admin = user!("admin")
      space = owned_channel!(admin)
      co = user!("co")
      member = user!("member")
      join!(space, co)
      join!(space, member)
      make_admin!(space, co)
      agent = agent!("Bot")
      {:ok, _} = Chat.admin_add_agent(space, admin.id, agent.id)

      view = conn |> live_as(admin, ~p"/chat/#{space.slug}") |> open_members()

      assert has_element?(view, toggle(member), "Make admin")
      assert has_element?(view, toggle(co), "Remove admin")
      assert has_element?(view, "#{person_row(co)} [data-role=members-admin-badge]", "admin")
      refute has_element?(view, "#{person_row(member)} [data-role=members-admin-badge]")
      # Two admins: neither is the last, so nothing is disabled.
      refute has_element?(view, "#{toggle(co)}[disabled]")
      refute has_element?(view, "#{@popover} [data-role=members-last-admin]")

      # Agents never get the control; the agent row itself is there.
      assert has_element?(view, agent_row_selector(agent))
      refute has_element?(view, "#{agent_row_selector(agent)} [data-role=members-role-toggle]")

      # The phone sheet carries the same control.
      assert has_element?(view, toggle(member, @sheet), "Make admin")

      view |> element(toggle(member)) |> render_click()

      assert role_in_db(space, member) == "admin"
      assert render(view) =~ "#{member.name} is now an admin."
      assert has_element?(view, toggle(member), "Remove admin")

      view |> element(toggle(co)) |> render_click()

      assert role_in_db(space, co) == "member"
      assert render(view) =~ "#{co.name} is no longer an admin."
    end

    test "a plain member sees no toggle, and a forged members_set_role is refused",
         %{conn: conn} do
      admin = user!("admin")
      space = owned_channel!(admin)
      other = user!("other")
      join!(space, other)
      member = user!("member")

      view = conn |> live_as(member, ~p"/chat/#{space.slug}") |> open_members()

      assert has_element?(view, person_row(other))
      assert has_element?(view, "#{person_row(admin)} [data-role=members-admin-badge]")
      refute has_element?(view, "#{@popover} [data-role=members-role-toggle]")
      refute has_element?(view, "#{@sheet} [data-role=members-role-toggle]")

      for target <- [other, member] do
        view
        |> with_target("#chat-members")
        |> render_hook("members_set_role", %{
          "participant_id" => participant_id(space, target),
          "role" => "admin"
        })

        assert render(view) =~ "Only a channel admin or org admin can change admins."
        assert role_in_db(space, target) == "member"
      end
    end

    test "an org admin of the space's org sees and uses the toggle", %{conn: conn} do
      org = Tenancy.get_org_by_slug!("globex")
      admin = user!("admin")
      member = user!("member")
      org_admin = user!("orgadmin")
      for u <- [admin, member], do: org_member!(u, org)

      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: org_admin.id,
        org_id: org.id,
        role: "admin",
        external: false
      })
      |> Repo.insert!()

      space = owned_channel!(admin, %{org_id: org.id})
      join!(space, member)

      view = conn |> live_as(org_admin, ~p"/chat/#{space.slug}") |> open_members()

      # Opening the channel seated the org admin as a plain member.
      assert role_in_db(space, org_admin) == "member"
      assert has_element?(view, toggle(member), "Make admin")

      view |> element(toggle(member)) |> render_click()

      assert role_in_db(space, member) == "admin"
      assert render(view) =~ "#{member.name} is now an admin."
    end

    test "the sole admin's Remove admin is disabled, and a forged demote is refused",
         %{conn: conn} do
      admin = user!("admin")
      space = owned_channel!(admin)
      member = user!("member")
      join!(space, member)

      view = conn |> live_as(admin, ~p"/chat/#{space.slug}") |> open_members()

      assert has_element?(view, "#{toggle(admin)}[disabled]", "Remove admin")

      assert has_element?(
               view,
               "#{person_row(admin)} [data-role=members-last-admin]",
               "Last admin"
             )

      # The member's toggle is live.
      refute has_element?(view, "#{toggle(member)}[disabled]")

      view
      |> with_target("#chat-members")
      |> render_hook("members_set_role", %{
        "participant_id" => participant_id(space, admin),
        "role" => "member"
      })

      assert render(view) =~ "A channel needs at least one admin."
      assert role_in_db(space, admin) == "admin"
    end

    test "a promotion in one session updates another open panel, and the promoted viewer gains the controls",
         %{conn: conn} do
      admin = user!("admin")
      space = owned_channel!(admin)
      member = user!("member")
      join!(space, member)

      admin_view = conn |> live_as(admin, ~p"/chat/#{space.slug}") |> open_members()

      member_view =
        Phoenix.ConnTest.build_conn()
        |> live_as(member, ~p"/chat/#{space.slug}")
        |> open_members()

      assert has_element?(member_view, person_row(member))
      refute has_element?(member_view, "#{person_row(member)} [data-role=members-admin-badge]")
      refute has_element?(member_view, "#{@popover} [data-role=members-role-toggle]")
      refute has_element?(member_view, "[data-role=members-add-agent]")

      admin_view |> element(toggle(member)) |> render_click()
      assert role_in_db(space, member) == "admin"

      settle(member_view)

      assert has_element?(member_view, "#{person_row(member)} [data-role=members-admin-badge]")
      assert has_element?(member_view, toggle(admin), "Remove admin")
      assert has_element?(member_view, @add_form)
    end
  end

  describe "channel admins: Add people (task 01a199e4 stage 2)" do
    @person_form "#members-popover [data-role=members-add-person]"

    defp globex, do: Tenancy.get_org_by_slug!("globex")

    defp membership!(user, org, role, external \\ false) do
      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: org.id,
        role: role,
        external: external
      })
      |> Repo.insert!()

      user
    end

    defp globex_user!(tag, role \\ "member"), do: membership!(user!(tag), globex(), role)

    defp person_selector(user),
      do: "#{@popover} [data-role=members-person-row][data-user-id='#{user.id}']"

    # The non-empty option values of one surface's Add people select.
    defp person_options(view, scope \\ @popover) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#{scope} [data-role=members-add-person] option")
      |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))
      |> Enum.reject(&(&1 == ""))
    end

    defp user_rows(space, user) do
      Repo.all(
        from(p in Participant,
          where:
            p.space_id == ^space.id and p.participant_type == "user" and
              p.participant_id == ^user.id
        )
      )
    end

    defp globex_channel!(admin), do: owned_channel!(admin, %{org_id: globex().id})

    test "a channel admin adds an org member, whose row appears, and who then posts",
         %{conn: conn} do
      ada = globex_user!("ada")
      ben = globex_user!("ben")
      space = globex_channel!(ada)

      view = conn |> live_as(ada, ~p"/chat/#{space.slug}") |> open_members()

      assert has_element?(view, @person_form)
      assert has_element?(view, "#{@person_form} button", "Add")
      assert ben.id in person_options(view)
      # The phone sheet carries the same picker.
      assert ben.id in person_options(view, @sheet)
      refute has_element?(view, person_selector(ben))

      view |> form(@person_form, %{"user_id" => ben.id}) |> render_submit()

      assert render(view) =~ "#{ben.name} added."
      assert has_element?(view, person_selector(ben))
      refute ben.id in person_options(view)

      assert [row] = user_rows(space, ben)
      assert row.role == "member"
      assert row.display_name == ben.name
      assert %DateTime{} = row.joined_at
      assert row.history_visible_from == nil

      ben_view = live_as(Phoenix.ConnTest.build_conn(), ben, ~p"/chat/#{space.slug}")

      ben_view
      |> form("#compose-form", compose: %{text: "hello from Ben"})
      |> render_submit()

      assert render(ben_view) =~ "hello from Ben"
      assert [_] = user_rows(space, ben)
    end

    test "a plain member sees no picker, and a forged members_add_person is refused",
         %{conn: conn} do
      ada = globex_user!("ada")
      dee = globex_user!("dee")
      eve = globex_user!("eve")
      space = globex_channel!(ada)

      view = conn |> live_as(dee, ~p"/chat/#{space.slug}") |> open_members()

      assert has_element?(view, @popover)
      assert has_element?(view, person_selector(ada))
      refute has_element?(view, "[data-role=members-add-person]")

      view
      |> with_target("#chat-members")
      |> render_hook("members_add_person", %{"user_id" => eve.id})

      assert render(view) =~ "Only a channel admin can add people to this channel."
      assert user_rows(space, eve) == []
    end

    test "an org admin of the space's org sees and uses the picker", %{conn: conn} do
      ada = globex_user!("ada")
      org_admin = globex_user!("orgadmin", "admin")
      ben = globex_user!("ben")
      space = globex_channel!(ada)

      view = conn |> live_as(org_admin, ~p"/chat/#{space.slug}") |> open_members()

      # Opening the channel seated the org admin as a plain member: the
      # picker comes from the org-admin ground, not a channel role.
      assert [%{role: "member"}] = user_rows(space, org_admin)
      assert has_element?(view, @person_form)

      view |> form(@person_form, %{"user_id" => ben.id}) |> render_submit()

      assert has_element?(view, person_selector(ben))
      assert [_] = user_rows(space, ben)
    end

    test "existing participants are never options, and a forged add of one is already_member",
         %{conn: conn} do
      ada = globex_user!("ada")
      fay = globex_user!("fay")
      gus = globex_user!("gus")
      hal = globex_user!("hal")
      space = globex_channel!(ada)
      join!(space, fay)
      join!(space, gus)
      make_admin!(space, fay)

      view = conn |> live_as(ada, ~p"/chat/#{space.slug}") |> open_members()
      options = person_options(view)

      assert hal.id in options
      for seated <- [ada, fay, gus], do: refute(seated.id in options)

      view
      |> with_target("#chat-members")
      |> render_hook("members_add_person", %{"user_id" => gus.id})

      assert render(view) =~ "#{gus.name} is already in this channel."
      assert [_] = user_rows(space, gus)
    end

    test "an external user is never an option, and a forged add renders the external flash",
         %{conn: conn} do
      ada = globex_user!("ada")
      xan = membership!(user!("xan"), globex(), "member", true)
      ben = globex_user!("ben")
      space = globex_channel!(ada)

      view = conn |> live_as(ada, ~p"/chat/#{space.slug}") |> open_members()
      options = person_options(view)

      # Positive control: the select lists someone, so the refute reads a list.
      assert ben.id in options
      refute xan.id in options

      view
      |> with_target("#chat-members")
      |> render_hook("members_add_person", %{"user_id" => xan.id})

      assert render(view) =~ "External people are added by a root admin."
      assert user_rows(space, xan) == []
    end

    test "a group, a DM and an execution space render no picker, even for a root admin",
         %{conn: conn} do
      rae = membership!(user!("rae"), Tenancy.get_org_by_slug!("acme"), "admin")
      sam = globex_user!("sam")
      b = globex_user!("b")
      c = globex_user!("c")

      {:ok, group} =
        Chat.create_group_conversation(rae.id, [
          %{type: "user", id: b.id},
          %{type: "user", id: c.id}
        ])

      group_view = live_as(conn, rae, "/chat/#{Chat.space_path_segment(group)}")
      group_view |> element(@open_button) |> render_click()
      assert has_element?(group_view, @popover)
      refute has_element?(group_view, "[data-role=members-add-person]")

      group_view
      |> with_target("#chat-members")
      |> render_hook("members_add_person", %{"user_id" => sam.id})

      assert render(group_view) =~ "People can only be added to channels."
      assert user_rows(group, sam) == []

      {:ok, dm} = Chat.find_or_create_dm(rae.id, "user", b.id)

      dm_view =
        live_as(Phoenix.ConnTest.build_conn(), rae, "/chat/#{Chat.space_path_segment(dm)}")

      assert has_element?(dm_view, "#compose-form")
      refute has_element?(dm_view, "[data-role=members-add-person]")

      {:ok, project} =
        Platform.Tasks.create_project(%{name: "People #{System.unique_integer([:positive])}"})

      {:ok, task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsored people",
          sponsor_user_id: rae.id
        })

      {:ok, exec} =
        Chat.create_space(%{kind: "execution", name: "exec", metadata: %{"task_id" => task.id}})

      join!(exec, rae)

      exec_view =
        Phoenix.ConnTest.build_conn()
        |> live_as(rae, "/chat/#{exec.id}")
        |> open_members()

      # The sponsor gets Add agent here; Add people stays channel-only.
      assert has_element?(exec_view, @add_form)
      refute has_element?(exec_view, "[data-role=members-add-person]")

      exec_view
      |> with_target("#chat-members")
      |> render_hook("members_add_person", %{"user_id" => sam.id})

      assert render(exec_view) =~ "People can only be added to channels."
      assert user_rows(exec, sam) == []
    end

    test "a space_id in the event params is ignored: the add lands in the open channel",
         %{conn: conn} do
      ada = globex_user!("ada")
      ben = globex_user!("ben")
      here = globex_channel!(ada)
      # Ada administers this one too, so only the source of the space id decides.
      elsewhere = globex_channel!(ada)

      view = conn |> live_as(ada, ~p"/chat/#{here.slug}") |> open_members()

      view
      |> with_target("#chat-members")
      |> render_hook("members_add_person", %{"user_id" => ben.id, "space_id" => elsewhere.id})

      assert [_] = user_rows(here, ben)
      assert user_rows(elsewhere, ben) == []
    end

    test "an add in one session drops the person from another open panel's select",
         %{conn: conn} do
      ada = globex_user!("ada")
      fay = globex_user!("fay")
      hal = globex_user!("hal")
      space = globex_channel!(ada)
      join!(space, fay)
      make_admin!(space, fay)

      view_a = conn |> live_as(ada, ~p"/chat/#{space.slug}") |> open_members()

      view_b =
        Phoenix.ConnTest.build_conn()
        |> live_as(fay, ~p"/chat/#{space.slug}")
        |> open_members()

      assert hal.id in person_options(view_b)
      refute has_element?(view_b, person_selector(hal))

      view_a |> form(@person_form, %{"user_id" => hal.id}) |> render_submit()
      assert [_] = user_rows(space, hal)

      settle(view_b)

      assert has_element?(view_b, person_selector(hal))
      refute hal.id in person_options(view_b)
    end
  end
end
