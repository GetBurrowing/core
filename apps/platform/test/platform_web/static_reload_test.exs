defmodule PlatformWeb.StaticReloadTest do
  # async: false because the endpoint's cache manifest is global config.
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Platform.Repo

  @latest %{
    "assets/css/app.css" => "assets/css/app-new0digest.css",
    "assets/js/app.js" => "assets/js/app-new0digest.js"
  }

  setup %{conn: conn} do
    previous = PlatformWeb.Endpoint.config(:cache_static_manifest_latest)
    Phoenix.Config.put(PlatformWeb.Endpoint, :cache_static_manifest_latest, @latest)

    on_exit(fn ->
      Phoenix.Config.put(PlatformWeb.Endpoint, :cache_static_manifest_latest, previous)
    end)

    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "static-reload-#{n}@example.com",
        name: "Static reload user",
        oidc_sub: "static-reload-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })

    %{conn: init_test_session(conn, current_user_id: user.id)}
  end

  defp tracking(conn, statics), do: put_connect_params(conn, %{"_track_static" => statics})

  test "a client holding a previous deploy's stylesheet is sent a full reload of the same URL",
       %{conn: conn} do
    stale = [
      "http://www.example.com/assets/css/app-old0digest.css",
      "http://www.example.com/assets/js/app-new0digest.js"
    ]

    assert {:error, {:redirect, %{to: to}}} =
             conn |> tracking(stale) |> live("/calendar/settings")

    assert URI.parse(to).path == "/calendar/settings"
  end

  test "the reload keeps the query string", %{conn: conn} do
    stale = ["http://www.example.com/assets/css/app-old0digest.css"]

    assert {:error, {:redirect, %{to: to}}} =
             conn |> tracking(stale) |> live("/meetings?tab=archive")

    assert %URI{path: "/meetings", query: "tab=archive"} = URI.parse(to)
  end

  test "a client on the current deploy's assets mounts normally", %{conn: conn} do
    current = [
      "http://www.example.com/assets/css/app-new0digest.css",
      "http://www.example.com/assets/js/app-new0digest.js"
    ]

    assert {:ok, _view, html} = conn |> tracking(current) |> live("/calendar/settings")
    assert html =~ "cal-page"
  end

  test "a client that tracks nothing mounts normally", %{conn: conn} do
    assert {:ok, _view, _html} = live(conn, "/calendar/settings")
  end
end
