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

    # Burrow redesign 22 stage 2 deleted the desktop channel rail (and its
    # collapsible org sections); the desktop restricted row is the Chat list's.
    {:ok, member_view, _html} = live(member_conn, ~p"/chat/#{lobby.id}")

    html = render(member_view)

    assert has_element?(
             member_view,
             ~s(#chat-list-scroller [data-role="restricted-channel-row"][data-space-id="#{finance.id}"])
           )

    refute has_element?(member_view, ~s(#chat-list-scroller a[data-space-id="#{finance.id}"]))
    assert html =~ "Restricted, ask an admin"
    # The no-entry marker, never the lock (the lock means "private, and yours").
    assert has_element?(
             member_view,
             ~s([data-role="restricted-channel-row"][data-space-id="#{finance.id}"] [data-glyph="restricted"])
           )

    refute html =~ marker

    [restricted_row] =
      Regex.run(
        ~r/<div[^>]*data-role="restricted-channel-row"[^>]*data-space-id="#{finance.id}"[^>]*>.*?<\/div>/s,
        html
      )

    # The name stays readable (task 01a15902 stage 4): the marker and the
    # wording carry "restricted"; the name is ordinary text and nothing in the
    # row uses the WCAG-exempt disabled colour.
    assert restricted_row =~ ~r/<span class="[^"]*text-base-content[^"]*">\s*Finance/
    refute restricted_row =~ "text-disabled"

    refute restricted_row =~ "<a "
    refute restricted_row =~ "<button "
    refute restricted_row =~ "chat-list-unread-count"

    # The phone's restricted row lives on the Chat list since task
    # 01a1557a-8562 (the drawer and pills that carried it here were deleted):
    # chat_live_chat_list_test.exs "a restricted channel renders the
    # restricted row with no excerpt and no link".

    participant_count = length(Chat.list_participants(finance.id))
    denied = live(member_conn, ~p"/chat/#{finance.id}")
    assert {:error, {:live_redirect, %{to: "/chat"}}} = denied
    assert {:ok, _denied_view, denied_html} = follow_redirect(denied, member_conn, "/chat")
    assert denied_html =~ "Restricted, ask an admin"
    refute denied_html =~ marker

    deep_denied = live(member_conn, ~p"/chat/#{finance.id}?message=#{Ecto.UUID.generate()}")
    assert {:error, {:live_redirect, %{to: "/chat"}}} = deep_denied
    assert {:ok, _deep_view, deep_html} = follow_redirect(deep_denied, member_conn, "/chat")
    assert deep_html =~ "Restricted, ask an admin"
    refute deep_html =~ marker
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
