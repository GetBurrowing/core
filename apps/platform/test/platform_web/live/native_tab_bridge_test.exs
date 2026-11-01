defmodule PlatformWeb.NativeTabBridgeTest do
  @moduledoc """
  The `#native-tab-bridge` span inside `bottom_rail/1` (task 01a1557b stage 3):
  the NativeTabBar hook reads it to drive the iOS app's native tab bar. These
  check that the shell renders it with the attributes the bar itself shows.
  """
  use PlatformWeb.ConnCase, async: false
  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Inbox
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.IconRail

  @bridge "#bottom-nav #native-tab-bridge[phx-hook='NativeTabBar'][hidden]"
  @more ~s([data-bottom-rail] button[data-destination="more"])

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "native_tab_#{System.unique_integer([:positive])}@example.com",
        name: "Native Tab Test User",
        oidc_sub: "oidc-native-tab-#{System.unique_integer([:positive])}",
        preferences: %{"first_run_goal" => "existing"}
      })

    acme = Tenancy.get_org_by_slug!("acme")
    Repo.insert!(%OrgMembership{user_id: user.id, org_id: acme.id, role: "admin"})
    init_test_session(conn, current_user_id: user.id)
  end

  defp items_attr(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#native-tab-bridge")
    |> LazyHTML.attribute("data-items")
  end

  defp inbox_attrs(user_id) do
    %{
      user_id: user_id,
      kind: "chat_mention",
      source_type: "chat_message",
      source_id: Ecto.UUID.generate(),
      title: "You were mentioned",
      body: "…",
      url: "/chat/x"
    }
  end

  test "data-items is mobile_tab_keys/0 then more, in order" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <IconRail.bottom_rail current_path="/chat" />
      """)

    expected = Enum.map_join(IconRail.mobile_tab_keys(), ",", &to_string/1) <> ",more"
    assert items_attr(html) == [expected]
    assert expected == "chat,calendar,meetings,inbox,more"
  end

  test "/chat selects chat, More closed, no unread", %{conn: conn} do
    {:ok, view, _html} = live(authenticated_conn(conn), ~p"/chat")

    assert has_element?(view, @bridge)

    assert has_element?(
             view,
             "#native-tab-bridge[data-items='chat,calendar,meetings,inbox,more']"
           )

    assert has_element?(view, "#native-tab-bridge[data-active-key='chat']")
    assert has_element?(view, "#native-tab-bridge[data-more-open='false']")
    assert has_element?(view, "#native-tab-bridge[data-inbox-unread='false']")
  end

  # Task 01a174e8 stage 1: the hook reads the bar's inks off these two probes.
  # They are not tabs: nothing that matches .bottom-nav-tab may see them.
  test "the bridge carries the two ink probes, which are not bar tabs", %{conn: conn} do
    {:ok, view, html} = live(authenticated_conn(conn), ~p"/chat")

    assert has_element?(view, "#bottom-nav #native-tab-bridge > span[data-native-ink='selected']")

    assert has_element?(
             view,
             "#bottom-nav #native-tab-bridge > span[data-native-ink='unselected']"
           )

    refute has_element?(view, "[data-native-ink].bottom-nav-tab")
    refute has_element?(view, ".bottom-nav-tab [data-native-ink]")

    probes =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#native-tab-bridge [data-native-ink]")
      |> LazyHTML.attribute("data-native-ink")

    assert probes == ["selected", "unselected"]
  end

  # Task 01a18d9f stage 5: Tasks is a More-sheet row, so /tasks selects More.
  test "/tasks selects more", %{conn: conn} do
    {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")
    assert has_element?(view, "#native-tab-bridge[data-active-key='more']")
  end

  test "/inbox selects inbox", %{conn: conn} do
    {:ok, view, _html} = live(authenticated_conn(conn), ~p"/inbox")
    assert has_element?(view, "#native-tab-bridge[data-active-key='inbox']")
  end

  test "More open selects more and sets data-more-open, and closing restores", %{conn: conn} do
    {:ok, view, _html} = live(authenticated_conn(conn), ~p"/chat")

    view |> element(@more) |> render_click()
    assert has_element?(view, "#native-tab-bridge[data-active-key='more'][data-more-open='true']")

    view |> element(@more) |> render_click()

    assert has_element?(
             view,
             "#native-tab-bridge[data-active-key='chat'][data-more-open='false']"
           )
  end

  test "inbox unread above 0 sets data-inbox-unread true", %{conn: conn} do
    conn = authenticated_conn(conn)
    user_id = conn.private.plug_session["current_user_id"]
    {:ok, _} = Inbox.emit(inbox_attrs(user_id))

    {:ok, view, _html} = live(conn, ~p"/tasks")
    assert has_element?(view, "#native-tab-bridge[data-inbox-unread='true']")
    refute has_element?(view, "#native-tab-bridge[data-inbox-unread='false']")

    assert has_element?(
             view,
             "#bottom-nav a[data-destination='inbox'] [data-role='inbox-unread-dot']"
           )
  end
end
