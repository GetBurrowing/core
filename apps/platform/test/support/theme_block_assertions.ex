defmodule Platform.Design.ThemeBlockAssertions do
  @moduledoc """
  The flunking half of `Platform.Design.ThemeBlocks` (task 01a1557a-fe9b
  stage 1). The parser moved to `lib/`; the `!` helper that raises
  `ExUnit.AssertionError` via `flunk/1`, so a guard failure names the block and
  the token, stays in test support.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Platform.Design.ThemeBlocks

  @doc "A token's value, following `var(--x)` chains, parsed as a colour. Flunks on a miss."
  def resolve!(b, var) do
    case ThemeBlocks.resolve(b, var) do
      {:ok, color} -> color
      {:error, reason} -> flunk(reason)
    end
  end
end
