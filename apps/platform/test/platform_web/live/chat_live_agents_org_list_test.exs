defmodule PlatformWeb.ChatLiveAgentsOrgListTest do
  @moduledoc """
  The agents space renders ONCE in the chat list (task
  `01a0ca8b-a9f6-7001-8b5e-3de9de0f6c43` stage 1): as the Agents row at the
  head of Pinned, and not also among the Spaces rows.

  Burrow redesign 22 stage 2 deleted the desktop channel rail (its org
  section headers and its agents block); the same rule is asserted on the
  Chat list that replaced it, which renders beside the conversation at lg.
  "Org list" below means the list's Spaces section (every sub-org channel,
  flattened) and "block" means the Agents row.

  Every absence is asserted in the SAME render as the presence that makes
  it meaningful. An absence from the org section on its own passes for an
  implementation that drops the space from BOTH places, which is the one
  failure this feature must never have: the space unreachable, its unread
  still counted in the left-rail badge. So each "absent from the org list"
  is paired with "present in the block", and each case also asserts the
  no-goal sibling in the same org still lists, which is the positive control
  against an over-broad filter.

  Setup mirrors `chat_live_agents_goal_surface_test.exs`.

  Stage 2 extended the same rule to two mobile surfaces (the phone drawer's
  org sections and the strip of channel pills); both were deleted in task
  01a1557a-8562 stage 5, and their cases (e) and (f) with them. The phone
  Chat list's Agents row is covered in `chat_live_chat_list_test.exs`
  ("PINNED leads with the Agents row, then the pinned conversations").

  `async: false` — the feature flag is application env, global to the node.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
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

  # `can_edit_goal?` is `Tenancy.root_admin?/1`, so case (d) — which drives
  # `save_goal` — needs the viewer to be an Acme admin or the write is refused.
  defp make_acme_admin(user) do
    %Tenancy.OrgMembership{}
    |> Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: acme_org().id,
      role: "admin"
    })
    |> Repo.insert!()
  end

  defp acme_org, do: Tenancy.get_org_by_slug!("acme")

  defp create_space(name, attrs) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(
          %{
            name: "#{name} #{n}",
            slug: "agents-org-list-#{name}-#{n}",
            kind: "channel",
            org_id: acme_org().id
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
  # Acme org, the viewer a participant of both.
  defp seed(conn, agents_attrs) do
    {conn, user} = authenticated_conn(conn)
    agents = create_space("agents", agents_attrs)
    sibling = create_space("design", %{})
    add_user(agents, user)
    add_user(sibling, user)
    %{conn: conn, user: user, agents: agents, sibling: sibling}
  end

  defp found?(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.any?()
  end

  # The list's Spaces section, scoped to the scroller so a search sheet or
  # popover row (same data-role) can never stand in for it.
  defp in_org_section?(html, space) do
    found?(
      html,
      ~s(#chat-list-scroller [data-role="chat-list-spaces"] a[data-role="chat-list-row"][data-space-id="#{space.id}"])
    )
  end

  defp in_rail_block?(html, space) do
    found?(
      html,
      ~s(#chat-list-scroller [data-role="chat-list-pinned"] a[data-row-kind="agents"][data-space-id="#{space.id}"])
    )
  end

  defp rail_block_rendered?(html) do
    found?(html, ~s(#chat-list-scroller a[data-role="chat-list-row"][data-row-kind="agents"]))
  end

  test "(a) flag on + goal: the space leaves its org list and shows in the block, in one render",
       %{conn: conn} do
    enable_flag()

    %{conn: conn, agents: agents, sibling: sibling} =
      seed(conn, goal: "Close backlog items in Suite")

    {:ok, _view, html} = live_at(conn, "/chat/#{sibling.slug}")

    refute in_org_section?(html, agents),
           "the agents space is listed under its org AND in the block"

    assert in_rail_block?(html, agents),
           "the agents space is not the Agents row — it is reachable nowhere"

    assert in_org_section?(html, sibling),
           "the no-goal sibling was filtered out of its org too"

    # Only the listing changed: the row keeps its org.
    assert Repo.reload!(agents).org_id == acme_org().id
  end

  test "(b) flag off: the space lists under its org and no block renders", %{conn: conn} do
    disable_flag()

    %{conn: conn, agents: agents, sibling: sibling} =
      seed(conn, goal: "Close backlog items in Suite")

    {:ok, _view, html} = live_at(conn, "/chat/#{sibling.slug}")

    assert in_org_section?(html, agents)
    assert in_org_section?(html, sibling)
    refute rail_block_rendered?(html)
  end

  test "(c) flag on, no goal anywhere: the space lists under its org", %{conn: conn} do
    enable_flag()
    %{conn: conn, agents: agents, sibling: sibling} = seed(conn, %{})

    {:ok, _view, html} = live_at(conn, "/chat/#{sibling.slug}")

    assert in_org_section?(html, agents)
    assert in_org_section?(html, sibling)
    refute rail_block_rendered?(html)
  end

  test "(d) saving then clearing the goal moves the space into the block and back, no remount",
       %{conn: conn} do
    enable_flag()

    %{conn: conn, user: user, agents: agents, sibling: sibling} =
      seed(conn, %{})

    make_acme_admin(user)

    {:ok, view, html} = live_at(conn, "/chat/#{agents.slug}")

    assert in_org_section?(html, agents)
    refute rail_block_rendered?(html)

    # The same event the header goal editor submits (the `save_goal` path).
    html = render_change(view, "save_goal", %{"goal" => "Close backlog items in Suite"})

    assert Repo.reload!(agents).goal == "Close backlog items in Suite",
           "save_goal was refused — the viewer is not an Acme admin"

    refute in_org_section?(html, agents),
           "a saved goal left the space listed under its org beside the block"

    assert in_rail_block?(html, agents)
    assert in_org_section?(html, sibling)

    html = render_change(view, "save_goal", %{"goal" => ""})

    assert Repo.reload!(agents).goal in [nil, ""]
    refute rail_block_rendered?(html)

    assert in_org_section?(html, agents),
           "a cleared goal left the space missing from both the block and its org"

    assert in_org_section?(html, sibling)
  end
end
