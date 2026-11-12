defmodule Platform.Design.ConsoleGlassSafeAreaTest do
  @moduledoc """
  Keeps the phone top bar clear of the iOS status bar on a gaming
  (Console Glass) install.

  The iOS app's web view is edge to edge (`contentInset: "never"`,
  `contentInsetAdjustmentBehavior = .never`) and the status bar / Dynamic
  Island band keeps the taps that land in it. The shell root carries
  `safe-area-top` to push `#phone-top-bar` (and the install switcher in it)
  below that band. Console Glass reset the shell's padding with a
  `padding:` shorthand, which also zeroed the top inset: on Burrow Play the
  whole 44px bar sat at y=0..44 under a 59px inset and nothing in it could
  be tapped, the install switcher included (sponsor report, 2026-11-12).

  The same applies to the `/play` page's phone bar (`.cg-side` below 768px),
  which is sticky at the very top of an edge-to-edge document.

  The rule this holds: any Console Glass rule that sets the shell root's or
  the phone `.cg-side`'s top padding must leave it including
  `env(safe-area-inset-top)`.
  """
  use ExUnit.Case, async: true

  @css_path Path.expand("../../../assets/css/console_glass.css", __DIR__)
  @shell_path Path.expand(
                "../../../lib/platform_web/components/layouts/shell.html.heex",
                __DIR__
              )

  defp css do
    @css_path |> File.read!() |> String.replace(~r{/\*.*?\*/}s, "")
  end

  # `{selector, declarations}` for every innermost rule in `source`.
  defp rules(source) do
    ~r/([^{}]+)\{([^{}]*)\}/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.flat_map(fn [selectors, body] ->
      selectors
      |> String.split(",")
      |> Enum.map(&{String.trim(&1), body})
    end)
  end

  # The body of the first `@media(max-width:767px){...}` block.
  defp phone_block(source) do
    [_, rest] = String.split(source, ~r/@media\s*\(max-width:\s*767px\)\s*\{/, parts: 2)
    take_balanced(rest, 1, [])
  end

  defp take_balanced(<<"}", _::binary>>, 1, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_balanced(<<"}", rest::binary>>, d, acc), do: take_balanced(rest, d - 1, ["}" | acc])
  defp take_balanced(<<"{", rest::binary>>, d, acc), do: take_balanced(rest, d + 1, ["{" | acc])

  defp take_balanced(<<c::utf8, rest::binary>>, d, acc),
    do: take_balanced(rest, d, [<<c::utf8>> | acc])

  # The value that wins for the top edge inside one declaration list: the
  # last `padding` or `padding-top` declaration, or nil when neither is set.
  defp effective_top_padding(body) do
    body
    |> String.split(";")
    |> Enum.map(&String.split(&1, ":", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Enum.map(fn [prop, value] -> {String.trim(prop), String.trim(value)} end)
    |> Enum.filter(fn {prop, _} -> prop in ["padding", "padding-top"] end)
    |> List.last()
  end

  defp assert_keeps_inset(rules, selector) do
    matching = for {^selector, body} <- rules, top = effective_top_padding(body), do: top

    assert matching != [], "expected a Console Glass rule for #{selector} that sets its padding"

    for {prop, value} <- matching do
      assert value =~ "env(safe-area-inset-top",
             "#{selector} sets `#{prop}: #{value}`, which drops env(safe-area-inset-top): " <>
               "on the iOS app the top bar goes under the status bar and cannot be tapped"
    end
  end

  test "every Console Glass rule padding the shell root keeps the top safe-area inset" do
    assert_keeps_inset(rules(css()), ".console-glass .app-shell-root")
  end

  test "the phone .cg-side bar on /play keeps the top safe-area inset" do
    assert_keeps_inset(rules(phone_block(css())), ".cg-side")
  end

  test "the shell root still carries safe-area-top" do
    shell = File.read!(@shell_path)
    [root_class] = Regex.run(~r/class="(app-shell-root[^"]*)"/, shell, capture: :all_but_first)
    assert root_class =~ "safe-area-top"
  end
end
