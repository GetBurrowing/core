defmodule Platform.Terminal.GuardsTest do
  @moduledoc """
  Source and schema guards for the remote terminal relay (task 01a17b17).

  The relay is a dumb pipe on a path separate from the native agent-host pane
  mirror. These tests read source with `File.read!` (never git) and fail if a
  terminal module could look inside a frame, log one, redact one, or persist
  one.
  """
  use ExUnit.Case, async: true

  @app_root Path.expand("../../..", __DIR__)

  defp sources do
    files =
      Path.wildcard(Path.join(@app_root, "lib/platform/terminal/*.ex")) ++
        Path.wildcard(Path.join(@app_root, "lib/platform_web/channels/terminal_*.ex")) ++
        [Path.join(@app_root, "lib/platform/terminal.ex")]

    Enum.map(files, &{Path.relative_to(&1, @app_root), File.read!(&1)})
  end

  # Every token that would let a module inspect, transform, scrub or log a
  # frame. The simplest checkable form is: none appears at all.
  @forbidden [
    "Redact",
    "Redaction",
    "AgentHost",
    "Regex",
    "~r",
    "~R",
    "String.",
    ":binary.match",
    ":binary.split",
    ":binary.matches",
    "Jason.decode",
    "Logger"
  ]

  test "the scan covers the modules it is meant to cover" do
    names = Enum.map(sources(), &elem(&1, 0))
    assert "lib/platform_web/channels/terminal_view_channel.ex" in names
    assert "lib/platform_web/channels/terminal_cli_channel.ex" in names
    assert "lib/platform_web/channels/terminal_socket.ex" in names
    assert "lib/platform/terminal/audit.ex" in names
    assert "lib/platform/terminal.ex" in names
  end

  test "no terminal module can inspect, redact or log a frame" do
    for {path, src} <- sources(), token <- @forbidden do
      refute String.contains?(src, token), "#{path} contains #{inspect(token)}"
    end
  end

  test "both channels switch Phoenix's join and handle_in logging off, and end with a catch-all" do
    for name <- ["terminal_view_channel.ex", "terminal_cli_channel.ex"] do
      src = File.read!(Path.join(@app_root, "lib/platform_web/channels/" <> name))
      assert src =~ "use Phoenix.Channel, log_join: false, log_handle_in: false"
      assert src =~ "def handle_in(_event, _payload, socket), do: {:noreply, socket}"
    end
  end

  test "the topic is parsed by pattern match" do
    src = File.read!(Path.join(@app_root, "lib/platform_web/channels/terminal_view_channel.ex"))
    assert src =~ ~s(def join("terminal_view:" <> runtime_id)
  end

  test "no Ecto schema lives under Platform.Terminal" do
    {:ok, modules} = :application.get_key(:platform, :modules)

    terminal =
      Enum.filter(modules, fn m ->
        name = Atom.to_string(m)

        String.starts_with?(name, "Elixir.Platform.Terminal") or
          String.starts_with?(name, "Elixir.PlatformWeb.Terminal")
      end)

    assert Platform.Terminal.Audit in terminal, "the module scan is not vacuous"
    refute Enum.any?(terminal, &function_exported?(&1, :__schema__, 1))
  end

  test "no migration creates a terminal table" do
    dir = Path.join(@app_root, "priv/repo/migrations")
    files = File.ls!(dir)
    assert length(files) > 100

    offenders =
      Enum.filter(files, fn f ->
        dir |> Path.join(f) |> File.read!() |> then(&Regex.match?(~r/table\(\s*:?"?terminal/, &1))
      end)

    assert offenders == []
  end
end
