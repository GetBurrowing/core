defmodule Platform.Design.PrimaryLiteralGuardTest do
  @moduledoc """
  An install can re-theme the app from the admin Branding page (task
  01a0dbee-f598-7001-b450-7890103f44c4): a runtime `<style id="install-theme">`
  re-declares `--color-primary` and friends after `app.css`. A hand-written
  rule that paints the Suite cyan as a LITERAL never reads that variable, so
  it keeps the Suite cyan on an install whose action colour is, say, Nord blue.

  Stage 4 repointed every such rule (`.msg-reply-gutter`, `.thread-indicator`,
  `.thread-avatars .t-av.ai`, `.ai-badge`, `.thread-send`, the thread and
  checklist tints) at `var(--color-primary)` / `color-mix(...)`. This test
  keeps it that way: outside the two daisyUI theme blocks (the ONE place the
  default cyan is declared) and outside comments, `app.css` must not name the
  cyan as `#06d5ed` in any case, nor as `rgba(6, 213, 237, a)`.

  Comments are stripped because they legitimately record measured values
  ("#06D5ED is 1.7875:1 on white"); the guard is about declarations.
  """
  use ExUnit.Case, async: true

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  defp declarations_outside_theme_blocks do
    @css_path
    |> File.read!()
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> strip_theme_blocks()
  end

  # Remove each `@plugin "../vendor/daisyui-theme" { ... }` block by brace
  # depth, so a nested brace inside one cannot end the strip early.
  defp strip_theme_blocks(css) do
    marker = ~s(@plugin "../vendor/daisyui-theme")

    case :binary.match(css, marker) do
      :nomatch ->
        css

      {start, _} ->
        <<before::binary-size(start), rest::binary>> = css
        before <> strip_theme_blocks(drop_block(rest))
    end
  end

  defp drop_block(rest) do
    {open, _} = :binary.match(rest, "{")
    <<_::binary-size(open + 1), body::binary>> = rest
    skip(body, 1)
  end

  defp skip(rest, 0), do: rest
  defp skip("{" <> rest, depth), do: skip(rest, depth + 1)
  defp skip("}" <> rest, depth), do: skip(rest, depth - 1)
  defp skip(<<_::utf8, rest::binary>>, depth), do: skip(rest, depth)

  test "the stripper actually removes the theme blocks (positive control)" do
    raw = @css_path |> File.read!() |> String.replace(~r{/\*.*?\*/}s, "")

    assert raw =~ ~r/--color-primary:\s*#06d5ed/i,
           "app.css no longer declares the default cyan in a theme block; this guard " <>
             "has nothing to exclude and should be revisited"

    refute declarations_outside_theme_blocks() =~ ~r/--color-primary:\s*#06d5ed/i
  end

  test "no rule outside the theme blocks paints the Suite cyan as a hex literal" do
    hits = Regex.scan(~r/[^\n]*#06d5ed[^\n]*/i, declarations_outside_theme_blocks())

    assert hits == [],
           "these app.css lines name #06d5ed directly, so they will not follow an " <>
             "install's colours. Use var(--color-primary) (fills), " <>
             "var(--color-primary-content) (text on a primary fill) or " <>
             "color-mix(in srgb, var(--color-primary) N%, transparent):\n" <>
             Enum.map_join(hits, "\n", &hd/1)
  end

  test "no rule outside the theme blocks paints the Suite cyan as rgba(6, 213, 237, a)" do
    hits =
      Regex.scan(
        ~r/[^\n]*rgba\(\s*6\s*,\s*213\s*,\s*237[^\n]*/,
        declarations_outside_theme_blocks()
      )

    assert hits == [],
           "these app.css lines name the cyan as rgba(); use " <>
             "color-mix(in srgb, var(--color-primary) N%, transparent):\n" <>
             Enum.map_join(hits, "\n", &hd/1)
  end
end
