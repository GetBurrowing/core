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

  # ── CHAT_HOST is readable OUTSIDE :prod (task 019fb955-f8b1 rework) ─────
  #
  # Every test above sets `:chat_host` as an OTP app env directly, so none of
  # them can see the bug: `runtime.exs` read `CHAT_HOST` only INSIDE
  # `if config_env() == :prod`, which meant exporting the variable in dev or
  # CI had NO effect on `chat_host_configured?/0`. The external-chat fence was
  # silently INERT outside prod, and any dev/CI exercise of it was VACUOUS —
  # it passed an unarmed fence. A reviewer following the setup instructions
  # literally hit exactly that and had to inject the app env by hand to arm it.
  #
  # Asserted against the config SOURCE because that is where the defect lives:
  # the running test VM has `config_env() == :test`, so by construction it can
  # never observe a prod-only assignment. `MEET_HOST` is the shipped precedent
  # (stage 1 put it at top level for this same reason) and doubles as the
  # anti-vacuity control — if the parse below stops finding it, the regexes
  # have drifted and the whole block proves nothing.
  describe "runtime.exs host configuration" do
    setup do
      %{
        lines: File.read!(Path.join([File.cwd!(), "config", "runtime.exs"])) |> String.split("\n")
      }
    end

    # TOP LEVEL IS A COLUMN, not a line number. runtime.exs has SIX separate
    # `if config_env() == :prod do` blocks, so "before the prod block" is not
    # a well-defined position — the first attempt at this test asserted it and
    # failed the `:meet_host` control, which has shipped correctly since stage
    # 1. What actually distinguishes the two placements is indentation, which
    # `mix format` enforces: a `config` call inside any block is indented, a
    # top-level one starts at column 0.
    defp placements(lines, key) do
      Enum.split_with(
        Enum.filter(lines, &(&1 =~ ~r/config :platform, :#{key},/)),
        &String.starts_with?(&1, "config ")
      )
    end

    test "`:meet_host` is set at top level (the shipped precedent, and the control)",
         %{lines: lines} do
      {top_level, nested} = placements(lines, "meet_host")

      assert length(top_level) == 1
      assert nested == []
    end

    test "`:chat_host` is set at top level, so dev and CI can arm the fence",
         %{lines: lines} do
      {top_level, nested} = placements(lines, "chat_host")

      assert length(top_level) == 1,
             "CHAT_HOST must be read at top level — inside the :prod block the " <>
               "external chat fence is inert in dev/CI and every local test of it is vacuous"

      assert nested == [],
             "a nested `config :platform, :chat_host` would shadow the top-level one " <>
               "in prod: #{inspect(nested)}"
    end

    test "neither host carries a `||` fallback — a guessed host is not a default",
         %{lines: lines} do
      for key <- ["meet_host", "chat_host"] do
        {[line], []} = placements(lines, key)

        assert line =~ ~s(System.get_env(")
        refute line =~ "||", "#{key} has a fallback; a guessed host is an authorization decision"
      end
    end
  end
end
