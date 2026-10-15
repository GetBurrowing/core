defmodule PlatformWeb.ChatLiveRestrictedChannelTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.Restrictions
  alias Platform.Chat
  alias Platform.Tenancy

  test "a restricted channel stays listed but cannot be entered from desktop, mobile, or a direct URL",
       %{conn: conn} do
    org = Tenancy.get_org!(acme_org_id())
    member = create_user!()
    unjoined = create_user!()
    admin = create_user!()
    plain_member!(member, org)
    plain_member!(unjoined, org)
    plain_member!(admin, org, "admin")
    finance = channel!(%{name: "Finance", org_id: org.id})
    lobby = channel!(%{name: "Lobby", org_id: org.id})
    add_user!(finance.id, admin.id)
    marker = "finance-secret-#{System.unique_integer([:positive])}"

    admin_participant =
      Enum.find(Chat.list_participants(finance.id), &(&1.participant_id == admin.id))

    {:ok, _} =
      Chat.post_message(%{
        space_id: finance.id,
        participant_id: admin_participant.id,
        content_type: "text",
        content: marker
      })

    member_conn = login(conn, member.id)
    {:ok, _before_view, before_html} = live(member_conn, ~p"/chat/#{finance.id}")
    assert before_html =~ marker
    assert before_html =~ ~s(href="/chat/#{finance.id}")
    assert Enum.any?(Chat.list_participants(finance.id), &(&1.participant_id == member.id))
    assert {:ok, _} = Restrictions.restrict_space(finance, ["admin"], admin.id)

    {:ok, member_view, html} = live(member_conn, ~p"/chat/#{lobby.id}")
    assert html =~ ~s(data-role="restricted-channel-row")
    assert html =~ ~s(data-space-id="#{finance.id}")
    assert html =~ "Restricted, ask an admin"
    assert html =~ "hero-lock-closed-mini"
    refute html =~ ~s(href="/chat/#{finance.id}")
    refute html =~ marker

    member_view |> element(~s(button[phx-click="toggle_mobile_browser"])) |> render_click()
    mobile = render(member_view)
    assert mobile =~ ~s(id="mobile-channel-browser")
    assert mobile =~ ~s(data-role="restricted-channel-row")
    refute mobile =~ ~s(href="/chat/#{finance.id}")

    participant_count = length(Chat.list_participants(finance.id))
    assert {:error, {:live_redirect, %{to: "/chat"}}} = live(member_conn, ~p"/chat/#{finance.id}")
    assert length(Chat.list_participants(finance.id)) == participant_count

    assert {:error, {:live_redirect, %{to: "/chat"}}} =
             live(login(conn, unjoined.id), ~p"/chat/#{finance.id}")

    refute Enum.any?(Chat.list_participants(finance.id), &(&1.participant_id == unjoined.id))

    {:ok, _admin_view, admin_html} = live(login(conn, admin.id), ~p"/chat/#{finance.id}")
    assert admin_html =~ marker
    assert admin_html =~ ~s(href="/chat/#{finance.id}")
    refute admin_html =~ ~s(data-role="restricted-channel-row" data-space-id="#{finance.id}")
  end
end
