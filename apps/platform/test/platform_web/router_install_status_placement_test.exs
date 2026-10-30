defmodule PlatformWeb.RouterInstallStatusPlacementTest do
  @moduledoc """
  Pins where `/install-status/:token` resolves (task 01a10315 stage 3).

  The customer's progress link is minted absolute and sent to them, so a
  route declared earlier that also matches two segments would turn it into a
  dead link without any test of the view noticing. `route_info/4` reports
  the clause Phoenix actually matches, in definition order, which is the
  only instrument that sees that (see `router_meet_guest_placement_test.exs`
  for the incident that taught it).
  """
  use ExUnit.Case, async: true

  @app_host "example.com"

  defp info(path, host), do: Phoenix.Router.route_info(PlatformWeb.Router, "GET", path, host)

  test "resolves to InstallStatusLive on the app host, unauthenticated, in its own session" do
    info = info("/install-status/abc", @app_host)

    assert info.route == "/install-status/:token"
    assert info.path_params == %{"token" => "abc"}
    assert {PlatformWeb.InstallStatusLive, :show, _opts, live_session} = info.phoenix_live_view
    assert live_session.name == :install_status
    assert live_session.extra.layout == {PlatformWeb.Layouts, :guest}

    # No login on the path: the token is the capability. App-fenced, last.
    assert info.pipe_through == [:guest_browser, :require_app_surface]
    refute :require_auth in info.pipe_through
  end

  test "a long URL-safe token still resolves here" do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    assert {PlatformWeb.InstallStatusLive, :show, _, _} = info("/install-status/#{token}", @app_host).phoenix_live_view
  end
end
