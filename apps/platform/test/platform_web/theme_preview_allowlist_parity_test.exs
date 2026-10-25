defmodule PlatformWeb.ThemePreviewAllowlistParityTest do
  @moduledoc """
  The preview receiver's `ALLOWED_VARS`
  (assets/js/hooks/theme_preview_receiver.js) is every name
  `Platform.Theming.Tokens.declarations/2` emits, and nothing else (task
  01a1557a-fe9b stage 2). A name the server pushes that the receiver does not
  allow is silently dropped from the preview; a name the receiver allows that
  the server never sends is attack surface for nothing.
  """
  use ExUnit.Case, async: true

  alias Platform.Theming.Presets
  alias Platform.Theming.Tokens

  @receiver Path.expand(
              "../../assets/js/hooks/theme_preview_receiver.js",
              __DIR__
            )

  defp receiver_names do
    source = File.read!(@receiver)

    [_, body] =
      Regex.run(~r/export const ALLOWED_VARS = new Set\(\[(.*?)\n\]\)/s, source) ||
        flunk("no ALLOWED_VARS set in the receiver")

    [_, agents] = Regex.run(~r/const AGENTS = \[([^\]]+)\]/, source)
    agent_ids = for [_, id] <- Regex.scan(~r/"([a-z]+)"/, agents), do: id

    literal = for [_, name] <- Regex.scan(~r/^\s*"(--[a-z0-9-]+)",?$/m, body), do: name

    if body =~ "...AGENTS.flatMap",
      do: literal ++ Enum.flat_map(agent_ids, &["--ag-#{&1}", "--ag-#{&1}-text"]),
      else: literal
  end

  defp server_names do
    for preset <- Presets.all(), mode <- ["light", "dark"], reduce: MapSet.new() do
      acc ->
        preset
        |> Tokens.declarations(mode)
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.split(":") |> hd()))
        |> MapSet.new()
        |> MapSet.union(acc)
    end
  end

  test "the receiver allows exactly the names the server declares" do
    names = receiver_names()
    # Anti-vacuity: the parse found the list, agents included.
    assert "--color-base-200" in names
    assert "--ag-lime-text" in names
    assert length(names) == length(Enum.uniq(names))

    assert MapSet.new(names) == server_names()
  end

  # Task 01a1557a-fe9b stage 3: the root layout's org theme sanitiser
  # (`Tokens.safe_declaration?/2`) allows `Tokens.declared_names/0`; it is the
  # same list, so the receiver, the editor and the stylesheet share one
  # allowlist.
  test "the receiver allows exactly Tokens.declared_names/0, the stylesheet's allowlist" do
    assert MapSet.new(receiver_names()) == MapSet.new(Tokens.declared_names())
    assert MapSet.new(Tokens.declared_names()) == server_names()
  end

  test "the agent ids match the token mapping" do
    names = receiver_names()
    for id <- Tokens.agent_ids(), do: assert("--ag-#{id}" in names)
  end
end
