defmodule PlatformWeb.ExternalRedirectTest do
  @moduledoc """
  Unit coverage for the chat-host URL builder (task 019f9257). Async false —
  it mutates the `:chat_host` app env.
  """
  use ExUnit.Case, async: false

  alias PlatformWeb.ExternalRedirect

  setup do
    prev = Application.get_env(:platform, :chat_host)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:platform, :chat_host, prev),
        else: Application.delete_env(:platform, :chat_host)
    end)

    :ok
  end

  describe "configured (prod)" do
    setup do
      Application.put_env(:platform, :chat_host, "chat.example.com")
      :ok
    end

    test "chat_host_configured?/0 is true" do
      assert ExternalRedirect.chat_host_configured?()
    end

    test "chat_url/1 builds an absolute https chat-host URL" do
      assert ExternalRedirect.chat_url("/chat") == "https://chat.example.com/chat"
      assert ExternalRedirect.chat_url() == "https://chat.example.com/chat"
      assert ExternalRedirect.chat_url("/chat/orion") == "https://chat.example.com/chat/orion"
    end

    test "chat_url/1 normalizes a path missing a leading slash" do
      assert ExternalRedirect.chat_url("chat") == "https://chat.example.com/chat"
    end
  end

  describe "unconfigured (dev/test/CI)" do
    setup do
      Application.delete_env(:platform, :chat_host)
      :ok
    end

    test "chat_host_configured?/0 is false" do
      refute ExternalRedirect.chat_host_configured?()
    end

    test "chat_url/1 degrades to a host-relative path — never https:///chat" do
      assert ExternalRedirect.chat_url("/chat") == "/chat"
      assert ExternalRedirect.chat_url() == "/chat"
      refute ExternalRedirect.chat_url("/chat") =~ "https://"
    end
  end

  describe "empty string CHAT_HOST" do
    test "treated as unconfigured (no https:// host built)" do
      Application.put_env(:platform, :chat_host, "")
      refute ExternalRedirect.chat_host_configured?()
      assert ExternalRedirect.chat_url("/chat") == "/chat"
    end
  end
end
