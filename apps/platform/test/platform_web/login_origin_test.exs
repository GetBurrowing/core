defmodule PlatformWeb.LoginOriginTest do
  @moduledoc """
  The catch-all clauses of `read/1` are the load-bearing ones. A test that only
  feeds `read/1` values `capture/1` produced can never reach them, so the
  rejection cases below put raw values into the session directly.
  """
  use ExUnit.Case, async: false

  import Plug.Test, only: [init_test_session: 2]

  alias PlatformWeb.LoginOrigin

  @meet_host "meet.localhost"
  @chat_host "chat.localhost"
  @app_host "example.com"

  setup do
    prev_meet = Application.get_env(:platform, :meet_host)
    prev_chat = Application.get_env(:platform, :chat_host)

    Application.put_env(:platform, :meet_host, @meet_host)
    Application.put_env(:platform, :chat_host, @chat_host)

    on_exit(fn ->
      restore(:meet_host, prev_meet)
      restore(:chat_host, prev_chat)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  defp conn_on(host) do
    :get
    |> Plug.Test.conn("/auth/login")
    |> Map.put(:host, host)
    |> init_test_session(%{})
  end

  defp session_with(value) do
    :get
    |> Plug.Test.conn("/auth/callback")
    |> init_test_session(%{})
    |> Plug.Conn.put_session(LoginOrigin.session_key(), value)
  end

  describe "capture/1" do
    test "stores :meet on the configured meet host" do
      conn = LoginOrigin.capture(conn_on(@meet_host))

      assert Plug.Conn.get_session(conn, LoginOrigin.session_key()) == :meet
      assert LoginOrigin.read(conn) == :meet
    end

    test "stores :chat on a chat. host" do
      conn = LoginOrigin.capture(conn_on(@chat_host))

      assert Plug.Conn.get_session(conn, LoginOrigin.session_key()) == :chat
      assert LoginOrigin.read(conn) == :chat
    end

    test "stores :app on the primary app host" do
      conn = LoginOrigin.capture(conn_on(@app_host))

      assert Plug.Conn.get_session(conn, LoginOrigin.session_key()) == :app
      assert LoginOrigin.read(conn) == :app
    end

    test "stores :app on a meet host when :meet_host is UNSET (feature is dark)" do
      Application.delete_env(:platform, :meet_host)

      conn = LoginOrigin.capture(conn_on(@meet_host))

      assert Plug.Conn.get_session(conn, LoginOrigin.session_key()) == :app,
             "with no configured meet host there is no meet surface to return to; " <>
               "capture must fail closed to :app rather than trust the meet. prefix"
    end
  end

  describe "read/1 rejects anything outside the closed set" do
    test "an absent key reads :app" do
      conn = :get |> Plug.Test.conn("/auth/callback") |> init_test_session(%{})

      assert Plug.Conn.get_session(conn, LoginOrigin.session_key()) == nil
      assert LoginOrigin.read(conn) == :app
    end

    test "the BINARY \"meet\" reads :app, not :meet" do
      conn = session_with("meet")

      assert Plug.Conn.get_session(conn, LoginOrigin.session_key()) == "meet"
      assert LoginOrigin.read(conn) == :app
    end

    test "an unknown atom reads :app" do
      conn = session_with(:evil)

      assert Plug.Conn.get_session(conn, LoginOrigin.session_key()) == :evil
      assert LoginOrigin.read(conn) == :app
    end

    test "nil and a map read :app" do
      assert LoginOrigin.read(session_with(nil)) == :app
      assert LoginOrigin.read(session_with(%{"surface" => "meet"})) == :app
    end
  end

  describe "clear/1" do
    test "removes the key so a completed login cannot influence a later one" do
      captured = LoginOrigin.capture(conn_on(@meet_host))
      assert Plug.Conn.get_session(captured, LoginOrigin.session_key()) == :meet

      cleared = LoginOrigin.clear(captured)

      assert Plug.Conn.get_session(cleared, LoginOrigin.session_key()) == nil
      assert LoginOrigin.read(cleared) == :app
    end
  end
end
