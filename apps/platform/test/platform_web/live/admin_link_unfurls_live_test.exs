defmodule PlatformWeb.AdminLinkUnfurlsLiveTest do
  @moduledoc """
  `/admin/link-unfurls` (task 01a1a944 stage 4): the install switch for
  link previews. Admin-only by the `:admin` live_session, and
  `Platform.Chat.LinkUnfurls.Settings.update/2` re-checks root admin.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.InsightFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat.LinkUnfurls.Settings

  @form "#admin-link-unfurls-form"

  defp conn_for(conn, user), do: init_test_session(conn, %{"current_user_id" => user.id})

  test "a non-admin is refused by the route gate", %{conn: conn} do
    assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
             conn |> conn_for(person!("member")) |> live(~p"/admin/link-unfurls")

    assert {:error, :unauthorized} = Settings.update(person!("member"), %{enabled: false})
    assert Settings.get().enabled

    # Control: an admin mounts the page.
    {:ok, _view, html} = conn |> conn_for(root_admin!()) |> live(~p"/admin/link-unfurls")
    assert html =~ "Show link previews"
  end

  test "previews default on; turning them off persists, and back on", %{conn: conn} do
    {:ok, view, _html} = conn |> conn_for(root_admin!()) |> live(~p"/admin/link-unfurls")
    assert has_element?(view, ~s([data-role="link-unfurls-enabled"][checked]))

    view |> form(@form, settings: %{enabled: "false"}) |> render_submit()
    refute Settings.get().enabled

    {:ok, view, _html} = conn |> conn_for(root_admin!()) |> live(~p"/admin/link-unfurls")
    refute has_element?(view, ~s([data-role="link-unfurls-enabled"][checked]))

    view |> form(@form, settings: %{enabled: "true"}) |> render_submit()
    assert Settings.get().enabled
  end

  test "the admin index links here", %{conn: conn} do
    {:ok, view, _html} = conn |> conn_for(root_admin!()) |> live(~p"/admin")

    assert has_element?(
             view,
             ~s(a[data-role="admin-link-unfurls-link"][href="/admin/link-unfurls"])
           )
  end
end
