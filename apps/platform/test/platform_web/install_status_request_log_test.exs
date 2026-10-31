defmodule PlatformWeb.InstallStatusRequestLogTest do
  @moduledoc """
  Task 01a18f0c stage 2: the `/install-status/<token>` request line is not
  logged. The token is a live credential (the hand-over link), the live
  route's `log: false` only silences LiveView's mount line, and
  `:filter_parameters` cannot filter a raw path.
  """
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Platform.InstallsFixtures

  test "request_log_level/1 is false for /install-status/..., :info elsewhere" do
    assert PlatformWeb.Endpoint.request_log_level(%Plug.Conn{path_info: ~w(install-status abc)}) ==
             false

    assert PlatformWeb.Endpoint.request_log_level(%Plug.Conn{path_info: ~w(installs)}) == :info
  end

  test "a GET of a real status token never puts the token in the log" do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    use_fake_backend()
    {_install, token} = create_install!()

    log =
      capture_log([level: :info], fn ->
        conn = get(build_conn(), "/install-status/#{token}")
        assert conn.status in [200, 302]
      end)

    refute log =~ token
    refute log =~ "/install-status/"

    # Positive control: the same capture DOES see an ordinary request line.
    control = capture_log([level: :info], fn -> get(build_conn(), "/favicon.ico") end)
    assert control =~ "GET /favicon.ico"
  end
end
