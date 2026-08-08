defmodule PlatformWeb.Plugs.HostSurfaceTest do
  @moduledoc """
  Unit coverage for the app-host fence. Async false — it mutates the
  `:host_surface_enforcement` app env.

  The app-host PASS case with enforcement `:on` is mandatory, not decorative:
  without it, a plug that halts unconditionally satisfies every denial
  assertion in this file.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias PlatformWeb.Plugs.HostSurface

  setup do
    prev = Application.get_env(:platform, :host_surface_enforcement)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:platform, :host_surface_enforcement, prev),
        else: Application.delete_env(:platform, :host_surface_enforcement)
    end)

    Application.delete_env(:platform, :host_surface_enforcement)
    :ok
  end

  defp conn_on(host) do
    :get
    |> conn("/")
    |> Map.put(:host, host)
    |> put_private(:phoenix_endpoint, PlatformWeb.Endpoint)
    |> Phoenix.Controller.accepts(["html"])
  end

  describe "enforcement :off (shipped state)" do
    test "a chat-host conn passes through unhalted" do
      conn = HostSurface.call(conn_on("chat.example.test"), [])

      refute conn.halted
      assert conn.status == nil
    end

    test "explicit :off is also a no-op" do
      Application.put_env(:platform, :host_surface_enforcement, :off)
      conn = HostSurface.call(conn_on("meet.example.com"), [])

      refute conn.halted
    end
  end

  describe "enforcement :on" do
    setup do
      Application.put_env(:platform, :host_surface_enforcement, :on)
      :ok
    end

    test "a chat-host conn is halted with 404" do
      conn = HostSurface.call(conn_on("chat.example.test"), [])

      assert conn.halted
      assert conn.status == 404
    end

    test "a meet-host conn is halted with 404" do
      conn = HostSurface.call(conn_on("meet.example.com"), [])

      assert conn.halted
      assert conn.status == 404
    end

    test "an app-host conn passes through unhalted (positive control)" do
      conn = HostSurface.call(conn_on("example.com"), [])

      refute conn.halted
      assert conn.status == nil
    end

    test "the 404 body does not echo the requested path" do
      conn =
        :get
        |> conn("/admin/secret-route")
        |> Map.put(:host, "chat.example.test")
        |> put_private(:phoenix_endpoint, PlatformWeb.Endpoint)
        |> Phoenix.Controller.accepts(["html"])
        |> HostSurface.call([])

      assert conn.status == 404
      refute conn.resp_body =~ "secret-route"
      refute conn.resp_body =~ "/admin"
    end
  end
end
