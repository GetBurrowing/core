defmodule Platform.Design.SubtleTextRatchetTest do
  @moduledoc """
  Ratchets the reduced-strength base-content text utilities (task 01a1557a
  stage 5 r2), in the ADR 0050 surface-budget pattern: a pinned count that may
  only go down.

    * The 55% utility is RETIRED: 0 uses. Secondary text paints `text-subtle`,
      the `--subtle` token each theme block declares at its own strength (55%,
      57% in Burrow sand light, where no ink clears 4.5:1 at 55% on the raised
      ground). A fresh use of the utility would bypass that per-theme strength.
    * The 60% utility is BUDGETED at its count when this landed. Every theme
      clears 4.5:1 at 60% (the theme guards hold it), and task 01a15902
      migrates it. Landing under the budget should re-pin it; raising it needs
      a stated reason in the commit, as ADR 0050 rules.

  Scanned: every file under `lib/`, `assets/js/` and `assets/css/` (CSS with
  its comments stripped, so prose about a utility is not a use of it). Any
  variant prefix counts (`hover:`, `md:`): the utility name is what is counted.
  The `(?![0-9])` stops `/600`-style suffixes from matching.

  Positive control (stage 5 r2, recorded in the commit): one `text-subtle` in
  `roles_panel.ex` reverted to the retired utility turns the 55% test red.
  """
  use ExUnit.Case, async: true

  @app Path.expand("../../..", __DIR__)

  @retired ~r/text-base-content\/55(?![0-9])/
  @budgeted ~r/text-base-content\/60(?![0-9])/

  # Pinned 2026-10-20 at the stage 5 r2 tip: lib/ 481, assets/js 8,
  # assets/css 10 (comments stripped).
  @budget_60 499

  defp sources do
    lib = Path.wildcard(Path.join(@app, "lib/**/*.{ex,exs,heex,eex}"))
    js = Path.wildcard(Path.join(@app, "assets/js/**/*.{js,mjs,ts}"))
    css = Path.wildcard(Path.join(@app, "assets/css/**/*.css"))

    Enum.map(lib ++ js, &{&1, File.read!(&1)}) ++
      Enum.map(css, &{&1, Regex.replace(~r{/\*.*?\*/}s, File.read!(&1), "")})
  end

  defp hits(regex) do
    for {path, text} <- sources(),
        n = length(Regex.scan(regex, text)),
        n > 0,
        do: {Path.relative_to(path, @app), n}
  end

  defp total(hits), do: hits |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  test "the scan reads the tree it claims to (anti-vacuity)" do
    files = sources()
    assert Enum.count(files, fn {p, _} -> String.contains?(p, "/lib/") end) > 500
    assert Enum.count(files, fn {p, _} -> String.contains?(p, "/assets/js/") end) > 50
    assert Enum.any?(files, fn {p, _} -> String.ends_with?(p, "assets/css/app.css") end)

    # The swap target is really in use, so 0 retired uses is a migration and
    # not an empty scan.
    assert total(hits(~r/\btext-subtle\b/)) >= 32
  end

  test "the 55% base-content text utility has 0 uses: paint text-subtle" do
    found = hits(@retired)

    assert found == [],
           "text-base-content/55 is retired (task 01a1557a): use text-subtle, which " <>
             "resolves to each theme's own --subtle strength. Found:\n  " <>
             Enum.map_join(found, "\n  ", fn {p, n} -> "#{p}: #{n}" end)
  end

  test "the 60% base-content text utility stays within its budget of #{@budget_60}" do
    count = total(hits(@budgeted))

    assert count <= @budget_60,
           "text-base-content/60 rose to #{count} (budget #{@budget_60}). Prefer " <>
             "text-subtle; raising the budget needs a reason in the commit (ADR 0050)."
  end
end
