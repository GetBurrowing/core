defmodule PlatformWeb.ChatLiveAgentsOrgListTest do
  @moduledoc """
  The agents space renders ONCE in the chat rail (task
  `01a0ca8b-a9f6-7001-8b5e-3de9de0f6c43` stage 1): in the agents block
  above Pinned, and not also under its org heading.

  Every absence is asserted in the SAME render as the presence that makes
  it meaningful. An absence from the org section on its own passes for an
  implementation that drops the space from BOTH places, which is the one
  failure this feature must never have: the space unreachable, its unread
  still counted in the left-rail badge. So each "absent from the org list"
  is paired with "present in the block", and each case also asserts the
  no-goal sibling in the same org still lists, which is the positive control
  against an over-broad filter.

  Setup mirrors `chat_live_agents_goal_surface_test.exs`.

  Stage 2 extends the same rule to the two mobile surfaces that read
  `@sidebar_sections`: the drawer's org sections and the channel-pills strip.
  The filter is applied once, at `resolve_sidebar_sections/4`, so these cases
  prove that one filter reaches both, and each absence is again paired in the
  same render with the presence that makes it meaningful: the drawer's Agents
  block row, and the Agents chip in the mobile pinned strip.

  `async: false` — the feature flag is application env, global to the node.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy

  @flag_key :agents_goal_surface

  setup do
    previous = Application.get_env(:platform, @flag_key)
    on_exit(fn -> Application.put_env(:platform, @flag_key, previous) end)
    :ok
  end

  defp enable_flag, do: Application.put_env(:platform, @flag_key, true)
  defp disable_flag, do: Application.put_env(:platform, @flag_key, false)

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "agents_org_list_#{n}@example.com",
        name: "Agents Org List User",
        oidc_sub: "oidc-agents-org-list-#{n}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  # `can_edit_goal?` is `Tenancy.fabrikam_admin?/1`, so case (d) — which drives
  # `save_goal` — needs the viewer to be a Fabrikam admin or the write is refused.
  defp make_fabrikam_admin(user) do
    %Tenancy.OrgMembership{}
    |> Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: fabrikam_org().id,
      role: "admin"
    })
    |> Repo.insert!()
  end

  defp fabrikam_org, do: Tenancy.get_org_by_slug!("fabrikam")

  defp fabrikam_section do
    Enum.find(Sidebar.list_active_default_sections(), &(&1.org_id == fabrikam_org().id))
  end

  defp create_space(name, attrs) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(
          %{
            name: "#{name} #{n}",
            slug: "agents-org-list-#{name}-#{n}",
            kind: "channel",
            org_id: fabrikam_org().id
          },
          Map.new(attrs)
        )
      )

    space
  end

  defp add_user(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    :ok
  end

  defp live_at(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: redirect}}} -> live(conn, redirect)
      ok -> ok
    end
  end

  # The org fixture: a goal-capable space and a no-goal sibling, both in the
  # Fabrikam org, the viewer a participant of both.
  defp seed(conn, agents_attrs) do
    {conn, user} = authenticated_conn(conn)
    agents = create_space("agents", agents_attrs)
    sibling = create_space("design", %{})
    add_user(agents, user)
    add_user(sibling, user)
    %{conn: conn, user: user, agents: agents, sibling: sibling, section: fabrikam_section()}
  end

  defp in_org_section?(html, section, space) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(section[data-section-id="#{section.id}"] [data-space-id="#{space.id}"]))
    |> Kernel.!=([])
  end

  defp in_rail_block?(html, space) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s([data-role="agents-rail-block"] [data-space-id="#{space.id}"]))
    |> Kernel.!=([])
  end

  defp rail_block_rendered?(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s([data-role="agents-rail-block"]))
    |> Kernel.!=([])
  end

  defp open_drawer(view) do
    view
    |> element(~s(button[phx-click="toggle_mobile_browser"]))
    |> render_click()
  end

  defp find(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector)
  end

  defp drawer_rows(html, space),
    do:
      find(
        html,
        ~s(#mobile-channel-browser [data-role="drawer-row-wrap"][data-space-id="#{space.id}"])
      )

  defp drawer_block_rows(html, space),
    do:
      find(
        html,
        ~s(#mobile-channel-browser [data-role="agents-drawer-block"] [data-role="drawer-row-wrap"][data-space-id="#{space.id}"])
      )

  defp in_drawer_org_section?(html, section, space) do
    find(
      html,
      ~s(#mobile-channel-browser section[data-section-id="#{section.id}"] [data-role="drawer-row-wrap"][data-space-id="#{space.id}"])
    ) != []
  end

  defp pills(html, space),
    do: find(html, ~s(a[data-role="channel-pill"][data-space-id="#{space.id}"]))

  defp agents_chip(html, space),
    do:
      find(
        html,
        ~s([data-role="mobile-pinned-strip"] [data-role="agents-pinned-strip-chip"][data-space-id="#{space.id}"])
      )

  test "(a) flag on + goal: the space leaves its org list and shows in the block, in one render",
       %{conn: conn} do
    enable_flag()

    %{conn: conn, agents: agents, sibling: sibling, section: section} =
      seed(conn, goal: "Close backlog items in Suite")

    # Positive control for the section selector: the fixture org's section
    # must exist, or every `refute in_org_section?` below passes vacuously.
    assert section, "the Fabrikam org has no default channel section"

    {:ok, _view, html} = live_at(conn, "/chat/#{sibling.slug}")

    refute in_org_section?(html, section, agents),
           "the agents space is listed under its org AND in the block"

    assert in_rail_block?(html, agents),
           "the agents space is not in the rail block — it is reachable nowhere"

    assert in_org_section?(html, section, sibling),
           "the no-goal sibling was filtered out of its org too"

    # Only the listing changed: the row keeps its org.
    assert Repo.reload!(agents).org_id == fabrikam_org().id
  end

  test "(b) flag off: the space lists under its org and no block renders", %{conn: conn} do
    disable_flag()

    %{conn: conn, agents: agents, sibling: sibling, section: section} =
      seed(conn, goal: "Close backlog items in Suite")

    {:ok, _view, html} = live_at(conn, "/chat/#{sibling.slug}")

    assert in_org_section?(html, section, agents)
    assert in_org_section?(html, section, sibling)
    refute rail_block_rendered?(html)
  end

  test "(c) flag on, no goal anywhere: the space lists under its org", %{conn: conn} do
    enable_flag()
    %{conn: conn, agents: agents, sibling: sibling, section: section} = seed(conn, %{})

    {:ok, _view, html} = live_at(conn, "/chat/#{sibling.slug}")

    assert in_org_section?(html, section, agents)
    assert in_org_section?(html, section, sibling)
    refute rail_block_rendered?(html)
  end

  test "(d) saving then clearing the goal moves the space into the block and back, no remount",
       %{conn: conn} do
    enable_flag()

    %{conn: conn, user: user, agents: agents, sibling: sibling, section: section} =
      seed(conn, %{})

    make_fabrikam_admin(user)

    {:ok, view, html} = live_at(conn, "/chat/#{agents.slug}")

    assert in_org_section?(html, section, agents)
    refute rail_block_rendered?(html)

    # The same event the header goal editor submits (the `save_goal` path).
    html = render_change(view, "save_goal", %{"goal" => "Close backlog items in Suite"})

    assert Repo.reload!(agents).goal == "Close backlog items in Suite",
           "save_goal was refused — the viewer is not a Fabrikam admin"

    refute in_org_section?(html, section, agents),
           "a saved goal left the space listed under its org beside the block"

    assert in_rail_block?(html, agents)
    assert in_org_section?(html, section, sibling)

    html = render_change(view, "save_goal", %{"goal" => ""})

    assert Repo.reload!(agents).goal in [nil, ""]
    refute rail_block_rendered?(html)

    assert in_org_section?(html, section, agents),
           "a cleared goal left the space missing from both the block and its org"

    assert in_org_section?(html, section, sibling)
  end

  test "(e) flag on + goal: both mobile surfaces drop the space and keep it reachable, in one render",
       %{conn: conn} do
    enable_flag()

    %{conn: conn, agents: agents, sibling: sibling, section: section} =
      seed(conn, goal: "Close backlog items in Suite")

    {:ok, view, _html} = live_at(conn, "/chat/#{sibling.slug}")

    # ONE render carries the drawer, the pinned strip and the pills strip.
    html = open_drawer(view)

    # Positive controls for every selector below: the sibling lists in the
    # drawer's org section and as a pill. Without these, each `refute`
    # passes vacuously on a drawer that did not open or a strip that did
    # not render.
    assert in_drawer_org_section?(html, section, sibling),
           "the no-goal sibling is not in the drawer's org section"

    assert [_] = pills(html, sibling),
           "the no-goal sibling is not a channel pill"

    # Drawer: exactly one row for the space, and it is the Agents block's.
    assert [_] = drawer_block_rows(html, agents),
           "the agents space is not in the drawer's Agents block"

    assert length(drawer_rows(html, agents)) == 1,
           "the agents space renders #{length(drawer_rows(html, agents))} drawer rows; " <>
             "every row outside the Agents block is its twin"

    refute in_drawer_org_section?(html, section, agents),
           "the agents space is listed under its org in the drawer AND in the block"

    # Pills strip: no pill for the space, and the Agents chip is present.
    assert pills(html, agents) == [],
           "the agents space is a channel pill AND the Agents chip"

    assert [_] = agents_chip(html, agents),
           "the Agents chip is missing from the mobile pinned strip — the space " <>
             "is reachable nowhere on mobile"
  end

  test "(f) flag off: the space is back as a pill and in the drawer's org section",
       %{conn: conn} do
    disable_flag()

    %{conn: conn, agents: agents, sibling: sibling, section: section} =
      seed(conn, goal: "Close backlog items in Suite")

    {:ok, view, _html} = live_at(conn, "/chat/#{sibling.slug}")
    html = open_drawer(view)

    assert in_drawer_org_section?(html, section, agents)
    assert in_drawer_org_section?(html, section, sibling)
    assert [_] = pills(html, agents)
    assert [_] = pills(html, sibling)

    assert drawer_block_rows(html, agents) == []
    assert find(html, ~s([data-role="agents-drawer-block"])) == []
    assert agents_chip(html, agents) == []
  end
end
