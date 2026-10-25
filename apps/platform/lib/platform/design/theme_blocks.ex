defmodule Platform.Design.ThemeBlocks do
  @moduledoc """
  Reads the theme token blocks out of `assets/css/app.css` and
  `assets/css/theme_presets.css` for the design guards (lifted out of
  `theme_presets_guard_test.exs` in task 01a1557a rung 3 stage 1, so the
  agent-slot guard parses the blocks exactly as the preset guard does).

  A block is `%{id, mode, raw, decls}`: `raw` keeps comments, `decls` has
  them stripped. Burrow's two variants are built the way the Burrow guard
  resolves them: the daisyUI theme block, then the theme-scoped selectors,
  then `:root`. First declaration wins.

  Moved out of test support by task 01a1557a-fe9b stage 1 so
  `Platform.Theming.Presets` parses the shipped presets exactly as the guards
  do. Nothing here asserts: `resolve/2` returns `{:error, reason}`, and the
  guards' flunking `resolve!/2` lives in test support
  (`Platform.Design.ThemeBlockAssertions`).
  """

  alias Platform.Design.WcagContrast, as: W

  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)
  @canonical ~r/^\[data-preset="([a-z0-9-]+)"\]\[data-theme="(dark|light)"\]:not\(\[data-theme-preview\]\)$/

  @doc "The canonical preset selector pattern, capturing id and mode."
  def canonical, do: @canonical

  @doc "The opening of a daisyUI theme plugin block in app.css."
  def plugin_open, do: @plugin_open

  @doc "Blocks in theme_presets.css, keyed by the canonical selector."
  def preset_blocks(css) do
    Regex.scan(~r/^(\[data-preset[^\n{]*)\{(.*?)\n\}/ms, css, capture: :all_but_first)
    |> Enum.flat_map(fn [sel, body] ->
      case Regex.run(@canonical, String.trim(sel)) do
        [_, id, mode] -> [%{id: id, mode: mode, raw: body, decls: strip_comments(body)}]
        nil -> []
      end
    end)
  end

  @doc "Burrow's `mode` variant from app.css."
  def burrow_block(app_css, mode) do
    theme =
      app_css
      |> blocks_after(@plugin_open)
      |> Enum.find(&Regex.match?(~r/^\s*name:\s*"#{mode}";/m, &1))

    scoped =
      if mode == "dark", do: blocks_after(app_css, ~s(\n[data-theme="dark"] {)), else: []

    decls =
      Enum.map_join(
        [theme | scoped] ++ blocks_after(app_css, "\n:root {"),
        "\n",
        &strip_comments/1
      )

    %{id: "burrow", mode: mode, raw: theme, decls: decls}
  end

  @doc """
  A token's value, following `var(--x)` chains, parsed as a colour:
  `{:ok, colour}`, or `{:error, reason}` naming the block and the token when
  the token is undeclared or its chain loops.
  """
  @spec resolve(map(), String.t()) :: {:ok, W.color()} | {:error, String.t()}
  def resolve(b, var), do: resolve(b, var, 0)

  defp resolve(b, var, depth) when depth > 8, do: {:error, "#{b.id} #{b.mode}: #{var} loops"}

  defp resolve(b, var, depth) do
    case declaration(b.decls, var) do
      nil ->
        {:error, "#{b.id} #{b.mode}: no #{var} declared"}

      value ->
        case Regex.run(~r/^var\(\s*(--[A-Za-z0-9_-]+)\s*\)$/, value) do
          [_, next] -> resolve(b, next, depth + 1)
          nil -> {:ok, W.parse!(value)}
        end
    end
  end

  @doc "Removes CSS comments."
  def strip_comments(text), do: Regex.replace(~r{/\*.*?\*/}s, text, "")

  @doc "The selector of every rule in `css`."
  def rule_selectors(css) do
    css
    |> strip_comments()
    |> then(&Regex.scan(~r/^([^\s{}][^{}]*)\{/m, &1, capture: :all_but_first))
    |> Enum.map(fn [s] -> String.trim(s) end)
  end

  @doc "The body of every block opened by the literal `open`."
  def blocks_after(css, open) do
    css
    |> :binary.matches(open)
    |> Enum.map(fn {at, len} ->
      start = at + len
      rest = binary_part(css, start, byte_size(css) - start)

      case Regex.run(~r/\n\s*\}/, rest, return: :index) do
        [{close, _}] -> binary_part(rest, 0, close)
        nil -> raise ArgumentError, "a block opened by #{inspect(open)} is never closed"
      end
    end)
  end

  @doc "A declaration's value in a block; the first match wins."
  def declaration(block, var) do
    case Regex.run(~r/^\s*#{Regex.escape(var)}\s*:\s*([^;]+);/m, block) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end
end
