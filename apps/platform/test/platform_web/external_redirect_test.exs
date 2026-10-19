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
      assert ExternalRedirect.chat_url("/chat/atlas") == "https://chat.example.com/chat/atlas"
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

  # ── meet_url/1, the chat_url/1 mirror (task 019ffec0) ──────────────────
  #
  # `:meet_host` has exactly ONE reader, `ExternalSurface.meet_host/0`, and
  # `meet_url/1` builds through it. These cases set the app env directly, the
  # same way the chat cases above do, so they exercise the real read path.
  describe "meet_url/1" do
    setup do
      prev = Application.get_env(:platform, :meet_host)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:platform, :meet_host, prev),
          else: Application.delete_env(:platform, :meet_host)
      end)

      :ok
    end

    test "configured host yields the exact absolute string" do
      Application.put_env(:platform, :meet_host, "meet.example.com")

      assert ExternalRedirect.meet_url("/meetings") == "https://meet.example.com/meetings"

      assert ExternalRedirect.meet_url("/meetings/standup") ==
               "https://meet.example.com/meetings/standup"

      assert ExternalRedirect.meet_host_configured?()
    end

    test "the default path is /meetings" do
      Application.put_env(:platform, :meet_host, "meet.example.com")

      assert ExternalRedirect.meet_url() == "https://meet.example.com/meetings"

      Application.delete_env(:platform, :meet_host)

      assert ExternalRedirect.meet_url() == "/meetings"
    end

    test "a path without a leading slash gets one" do
      Application.put_env(:platform, :meet_host, "meet.example.com")

      assert ExternalRedirect.meet_url("meetings") == "https://meet.example.com/meetings"
    end

    # PINNING OBSERVED BEHAVIOUR, NOT AN ASPIRATION. A `":port"` suffix is
    # carried through into the URL verbatim — neither builder strips it, and
    # `chat_url/1` does the same for the same input (asserted alongside so the
    # mirror claim is checked rather than assumed). Note this is NOT what
    # `ExternalSurface.on_meet_host?/1` does with the same configured value:
    # matching strips the port, building does not. That divergence is
    # deliberate for now — `conn.host` never carries a port, so the matcher
    # must strip it, while a dev-style host:port is a real address to build.
    test "a \":port\" suffix is carried into the URL, exactly as chat_url/1 does" do
      Application.put_env(:platform, :meet_host, "meet.localhost:4000")
      Application.put_env(:platform, :chat_host, "meet.localhost:4000")

      assert ExternalRedirect.meet_url("/meetings") == "https://meet.localhost:4000/meetings"

      assert ExternalRedirect.chat_url("/meetings") == ExternalRedirect.meet_url("/meetings"),
             "meet_url/1 must mirror chat_url/1 clause for clause; same host in, same URL out"
    end

    # BOTH fixtures are required. A guard written as `if host do` handles the
    # UNSET case and silently builds `https:///meetings` for the BLANK one, so
    # a suite testing only `nil` passes while the bug ships.
    test "an UNSET meet host degrades to the host-relative path — never https:///" do
      Application.delete_env(:platform, :meet_host)

      assert ExternalRedirect.meet_url("/meetings") == "/meetings"
      refute ExternalRedirect.meet_url("/meetings") =~ "https:///"
      refute ExternalRedirect.meet_host_configured?()
    end

    test "a BLANK meet host degrades to the host-relative path — never https:///" do
      Application.put_env(:platform, :meet_host, "   ")

      assert ExternalRedirect.meet_url("/meetings") == "/meetings",
             "a blank host must take the same branch as an unset one; a nil-only " <>
               "guard passes the unset case and emits https:///meetings here"

      refute ExternalRedirect.meet_url("/meetings") =~ "https:///"
      refute ExternalRedirect.meet_host_configured?()
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
