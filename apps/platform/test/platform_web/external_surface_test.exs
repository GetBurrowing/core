defmodule PlatformWeb.ExternalSurfaceTest do
  @moduledoc """
  Unit coverage for the external-surface resolver. Async false — it mutates
  the `:meet_host` and `:chat_host` app env.

  This module is a security primitive: its answer becomes an input to
  authorization. Every assertion below is written so that it can FAIL — in
  particular the unset-`:meet_host` case is both the fail-closed guarantee and
  the vacuity trap for every other meet-host test in the file (a meet test
  that forgets to set the config silently exercises the unset branch and
  passes for the wrong reason).
  """
  use ExUnit.Case, async: false

  alias PlatformWeb.ExternalSurface

  setup do
    prev_meet = Application.get_env(:platform, :meet_host)
    prev_chat = Application.get_env(:platform, :chat_host)

    on_exit(fn ->
      if prev_meet,
        do: Application.put_env(:platform, :meet_host, prev_meet),
        else: Application.delete_env(:platform, :meet_host)

      if prev_chat,
        do: Application.put_env(:platform, :chat_host, prev_chat),
        else: Application.delete_env(:platform, :chat_host)
    end)

    Application.delete_env(:platform, :meet_host)
    :ok
  end

  defp conn_on(host), do: %Plug.Conn{host: host}

  describe "meet host unset (fail-closed)" do
    test "a meet-looking host is :app when :meet_host is unset" do
      refute ExternalSurface.meet_host_configured?()
      assert ExternalSurface.for_conn(conn_on("meet.example.com")) == :app
    end
  end

  describe "meet host configured" do
    test "an exact host match is :meet" do
      Application.put_env(:platform, :meet_host, "meet.example.com")

      assert ExternalSurface.meet_host_configured?()
      assert ExternalSurface.for_conn(conn_on("meet.example.com")) == :meet
    end

    test "a port suffix on the configured value is stripped before comparing" do
      Application.put_env(:platform, :meet_host, "meet.example.com:4000")

      assert ExternalSurface.for_conn(conn_on("meet.example.com")) == :meet
    end

    test "comparison is case-insensitive on both sides" do
      Application.put_env(:platform, :meet_host, "MEET.Example.com")

      assert ExternalSurface.for_conn(conn_on("meet.example.com")) == :meet
    end

    test "a host that merely CONTAINS the configured value is :app" do
      Application.put_env(:platform, :meet_host, "meet.example.com")

      # Prefix/suffix/substring is not the rule — an attacker-controlled
      # `meet.example.com.evil.test` or a sibling `meet.evil.example.com`
      # must not inherit the meet surface.
      assert ExternalSurface.for_conn(conn_on("meet.evil.example.com")) == :app
      assert ExternalSurface.for_conn(conn_on("meet.example.com.evil.test")) == :app
      assert ExternalSurface.for_conn(conn_on("notmeet.example.com")) == :app
    end
  end

  describe "meet host blank" do
    test "an empty string is not configured and resolves :app" do
      Application.put_env(:platform, :meet_host, "")

      refute ExternalSurface.meet_host_configured?()
      assert ExternalSurface.for_conn(conn_on("meet.example.com")) == :app
      assert ExternalSurface.for_conn(conn_on("")) == :app
    end

    test "a whitespace-only string is not configured" do
      Application.put_env(:platform, :meet_host, "   ")

      refute ExternalSurface.meet_host_configured?()
    end
  end

  describe "chat host" do
    test "a chat.-prefixed host is :chat with :meet_host unset" do
      refute ExternalSurface.meet_host_configured?()
      assert ExternalSurface.for_conn(conn_on("chat.example.com")) == :chat
    end

    test "a chat.-prefixed host is :chat with an unrelated :meet_host set" do
      Application.put_env(:platform, :meet_host, "meet.example.com")

      assert ExternalSurface.meet_host_configured?()
      assert ExternalSurface.for_conn(conn_on("chat.example.com")) == :chat
    end

    test "on_chat_host?/1 keys on the chat. prefix" do
      assert ExternalSurface.on_chat_host?(conn_on("chat.example.com"))
      refute ExternalSurface.on_chat_host?(conn_on("example.com"))
      refute ExternalSurface.on_chat_host?(conn_on("mychat.example.com"))
    end
  end

  describe "precedence" do
    test "chat wins when :meet_host names a chat.-prefixed host" do
      Application.put_env(:platform, :meet_host, "chat.example.com")

      # The configured value matches EXACTLY, so the :meet clause would fire
      # if it were checked first. Chat must win deterministically.
      assert ExternalSurface.meet_host_configured?()
      assert ExternalSurface.for_conn(conn_on("chat.example.com")) == :chat
    end
  end

  describe "app host" do
    test "an unrelated host is :app" do
      Application.put_env(:platform, :meet_host, "meet.example.com")

      assert ExternalSurface.for_conn(conn_on("suite.example.com")) == :app
      assert ExternalSurface.for_conn(conn_on("example.com")) == :app
    end
  end

  describe "chat_host_configured?/0 delegation" do
    test "tracks :chat_host" do
      Application.put_env(:platform, :chat_host, "chat.example.com")
      assert ExternalSurface.chat_host_configured?()

      Application.put_env(:platform, :chat_host, "")
      refute ExternalSurface.chat_host_configured?()

      Application.delete_env(:platform, :chat_host)
      refute ExternalSurface.chat_host_configured?()
    end
  end

  describe "router_surface/1 (the router's prefix rule)" do
    test "meet. prefix is :meet even with :meet_host UNSET, where for_conn/1 says :app" do
      conn = conn_on("meet.example.com")

      # The divergence is the whole point of the second function, so both
      # sides are asserted in one test: it cannot drift into agreement
      # unnoticed, and the :meet answer cannot be passing for the wrong
      # reason (a configured meet host).
      refute ExternalSurface.meet_host_configured?()
      assert ExternalSurface.for_conn(conn) == :app
      assert ExternalSurface.router_surface(conn) == :meet
    end

    test "chat. prefix is :chat" do
      assert ExternalSurface.router_surface(conn_on("chat.example.test")) == :chat
    end

    test "a bare app host is :app" do
      assert ExternalSurface.router_surface(conn_on("example.com")) == :app
    end

    test "a host merely CONTAINING meet. is :app — the router matches a prefix" do
      assert ExternalSurface.router_surface(conn_on("notmeet.example.com")) == :app
    end
  end
end
