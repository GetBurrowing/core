defmodule Platform.Design.DarkTokenDiffTest do
  @moduledoc """
  Guards the painted dark-token table in
  `Platform.Design.DarkTokenPaintedFixture` (task 01a0cf85, stage 1): live
  Suite against the meetings mock, twelve rows, both measured by painted
  pixel.

  Pure ExUnit. No browser and no database: the bytes were taken by
  `priv/measurements/01a0cf85-dark-token-diff/probe.mjs` and pasted into the
  fixture. What this file proves is narrower and checkable offline:

    1. the instrument's controls are recorded as it reported them (exact
       white, black and planted; five negatives unresolved, never a hex);
    2. every row of the table is present on both sides;
    3. every recorded ratio reproduces from the recorded bytes, under the
       convention its label names, to 4 dp;
    4. the live dark block still declares exactly what each live reading was
       taken from. Edit a token and this fails with "re-measure", so the
       table cannot silently describe a palette that no longer ships;
    5. `docs/design-system/06-dark-token-diff.md`, the decision document
       Robin signs, carries exactly the fixture's hexes and ratios, and every
       pass/FAIL verdict in it agrees with its floor (stage 2).

  Ratio conventions (see `Platform.Design.WcagContrast`): `painted` is
  hex-to-hex over the painted bytes (`contrast_painted/2`); `token_space` is
  float-through from the declaration (`contrast/2`, `composite/3`).
  """
  use ExUnit.Case, async: true

  alias Platform.Design.DarkTokenPaintedFixture, as: F
  alias Platform.Design.WcagContrast, as: W

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @lib_root Path.expand("../../../lib", __DIR__)
  @doc_path Path.expand("../../../../../docs/design-system/06-dark-token-diff.md", __DIR__)
  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)

  # Mock grounds that are not a row: the card is a literal in the mock CSS.
  @mock_card "#12161f"
  @mock_warning_fallback "#f59e0b"

  setup_all do
    css = File.read!(@css_path)
    {:ok, dark: theme_block(css, "dark")}
  end

  # ── 1. the instrument ───────────────────────────────────────────────────

  describe "instrument controls" do
    for side <- [:live, :mock] do
      test "#{side}: positive controls read back exactly" do
        c = F.controls()[unquote(side)]

        assert c.white == "#FFFFFF"
        assert c.black == "#000000"
        assert c.planted == F.planted()
        assert c.canvas_white == "#FFFFFF"
        assert c.canvas_black == "#000000"
        assert c.canvas_planted == F.planted()
      end

      test "#{side}: negative controls are recorded as unresolved, never as a hex" do
        c = F.controls()[unquote(side)]

        for key <- [
              :undefined_var,
              :invalid_colour,
              :offscreen,
              :unpainted,
              :undefined_var_over_ground,
              :canvas_invalid_colour
            ] do
          assert Map.fetch!(c, key) == :unresolved,
                 "#{unquote(side)} control #{key} is recorded as #{inspect(c[key])}. A negative " <>
                   "control that yields a hex means the instrument reports a colour for a " <>
                   "swatch that painted nothing; every reading in the fixture is then suspect."
        end
      end

      test "#{side}: the canvas trap reproduced, so its guard was tested against something" do
        assert F.controls()[unquote(side)].canvas_unguarded_trap == F.planted()
      end
    end

    test "the planted colour is in neither palette" do
      painted =
        for side <- [:live, :mock], row <- F.rows(), do: row_bytes(side, row)

      refute F.planted() in List.flatten(painted)
    end
  end

  # ── 2. every row present ────────────────────────────────────────────────

  describe "table completeness" do
    test "the twelve rows are exactly the ones the table promises" do
      assert F.rows() ==
               ~w(base-100 base-200 base-300 edge base-content muted faint primary info success warning error)
    end

    for side <- [:live, :mock] do
      test "#{side}: every row is present" do
        table = if unquote(side) == :live, do: F.live(), else: F.mock()
        missing = F.rows() -- Map.keys(table)
        assert missing == [], "#{unquote(side)} is missing rows #{inspect(missing)}"
      end
    end

    test "live: every row resolved to painted bytes" do
      for row <- F.rows() do
        for hex <- List.wrap(row_bytes(:live, row)) do
          assert hex =~ ~r/^#[0-9A-F]{6}$/, "live #{row} has no painted hex: #{inspect(hex)}"
        end
      end
    end

    test "mock: warning has no token, and the fallback the mock paints is recorded" do
      warning = F.mock()["warning"]
      assert warning.painted == :unresolved
      assert warning.fallback.painted == String.upcase(@mock_warning_fallback)
    end

    test "translucent rows carry a composite for every ground they sit on" do
      assert Map.keys(F.live()["muted"].over) == ~w(base-100 base-200)
      assert Map.keys(F.live()["faint"].over) == ~w(base-100 base-200)
      assert Map.keys(F.mock()["muted"].over) == ~w(base-100 card)
      assert Map.keys(F.mock()["faint"].over) == ~w(base-100 card)
    end
  end

  # ── 3. ratios reproduce ─────────────────────────────────────────────────

  describe "recorded ratios reproduce" do
    test "every painted ratio reproduces from the painted bytes via contrast_painted/2" do
      misses =
        Enum.flat_map(F.ratios(), fn {side, fg, bg, painted, _} ->
          got = Float.round(W.contrast_painted(bytes(side, fg), bytes(side, bg)), 4)

          if got == painted,
            do: [],
            else: ["#{side} #{fg} on #{bg}: recorded #{painted}, bytes give #{got}"]
        end)

      assert misses == [],
             "painted ratios that do not reproduce from the recorded bytes:\n  " <>
               Enum.join(misses, "\n  ")
    end

    test "every cross row names a measured value on each side" do
      for {:cross, fg, bg, painted, nil} <- F.ratios() do
        assert F.painted_hex(:cross, fg) =~ ~r/^#[0-9A-F]{6}$/, "cross #{fg} has no painted bytes"
        assert F.painted_hex(:cross, bg) =~ ~r/^#[0-9A-F]{6}$/, "cross #{bg} has no painted bytes"
        assert is_float(painted)
      end
    end

    test "every token-space ratio reproduces from the declarations via contrast/2" do
      misses =
        F.ratios()
        |> Enum.reject(fn {_, _, _, _, token_space} -> is_nil(token_space) end)
        |> Enum.flat_map(fn {side, fg, bg, _, token_space} ->
          got = Float.round(W.contrast(token(side, fg), token(side, bg)), 4)

          if got == token_space,
            do: [],
            else: ["#{side} #{fg} on #{bg}: recorded #{token_space}, declarations give #{got}"]
        end)

      assert misses == [],
             "token-space ratios that do not reproduce:\n  " <> Enum.join(misses, "\n  ")
    end

    test "the ground decision's two figures are the painted table's own" do
      assert ratio(:live, "base-100", "base-200") == 1.2011
      assert ratio(:mock, "base-100", "base-200") == 1.1077
    end
  end

  # ── 4. staleness ────────────────────────────────────────────────────────

  describe "staleness guard" do
    # Since the Burrow recolor (task 01a120c5) this fixture is a dated record
    # of the PRE-Burrow palette. The guard below therefore requires it to be
    # MARKED superseded whenever it no longer matches, and the next test holds
    # the current dark block to the Burrow re-measure instead.
    test "each live reading's declaration still matches, or the table is marked superseded",
         %{dark: dark} do
      stale =
        F.live()
        |> Map.keys()
        |> Enum.flat_map(fn row ->
          {var, value} = split_declaration(F.live()[row].declaration)
          current = declaration(dark, var)

          if current == value,
            do: [],
            else: [
              "#{row}: measured from `#{var}: #{value};`, dark block now declares `#{var}: #{current};`"
            ]
        end)

      # Superseded means: the superseding re-measure is committed beside the
      # probe (task 01a120c5, `F.superseded_by/0`). Read from disk, so the check is a
      # fact about the repo rather than a constant.
      superseded? =
        File.exists?(Path.expand("../../../" <> F.burrow_remeasure_path(), __DIR__))

      assert stale == [] or superseded?,
             "re-measure: the dark palette changed since the painted table was taken. Run " <>
               "priv/measurements/01a0cf85-dark-token-diff/probe.mjs and paste the new bytes " <>
               "into DarkTokenPaintedFixture.\n  " <> Enum.join(stale, "\n  ")

      # A superseded mark on a table that still matches would be a false label.
      assert stale != [] or not superseded?, "marked superseded but still current"
    end

    test "the current dark block is what the Burrow live re-measure painted", %{dark: dark} do
      run =
        Path.expand("../../../" <> F.burrow_remeasure_path(), __DIR__)
        |> File.read!()
        |> Jason.decode!()

      assert run["git"]["assets_dirty"] == false

      for {_k, c} <- Map.take(run["controls"]["live"], ["white", "black", "planted"]) do
        assert c["status"] == "painted"
      end

      checked =
        for {row, %{"declaration" => decl, "hex" => painted}} <- run["live"]["rows"],
            is_binary(decl),
            {var, value} <- [split_declaration(decl)],
            String.starts_with?(value, "#") do
          current = declaration(dark, var)

          assert String.upcase(current) == painted,
                 "re-measure: #{row} painted #{painted} from `#{decl}` in the Burrow run, " <>
                   "but the dark block now declares `#{var}: #{current};`. Run probe.mjs " <>
                   "again and replace #{F.burrow_remeasure_path()}."

          row
        end

      # Every hex-declared Burrow token was checked, not a convenient subset.
      assert length(checked) >= 9, "only #{length(checked)} rows checked: #{inspect(checked)}"
    end

    test "the ground decision is still recorded in the dark block", %{dark: dark} do
      assert dark =~ "1.2011:1" and dark =~ "1.1077:1",
             "re-measure: the dark block no longer carries the 2026-09-06 ground decision " <>
               "(#000306 kept, #0C1016 rejected at 1.2011:1 vs 1.1077:1) that this table cites."
    end

    test "the muted and faint recipes are still used in lib/" do
      sources =
        Path.wildcard(Path.join(@lib_root, "**/*.{ex,heex}"))
        |> Enum.map(&File.read!/1)
        |> Enum.join("\n")

      for row <- ~w(muted faint) do
        recipe = F.live()[row].recipe

        assert String.contains?(sources, recipe),
               "re-measure: #{recipe}, the live #{row} counterpart, no longer appears in lib/."
      end
    end
  end

  # ── 5. the decision document ────────────────────────────────────────────

  describe "docs/design-system/06-dark-token-diff.md matches the fixture" do
    setup do
      {:ok, doc: File.read!(@doc_path)}
    end

    test "the token table carries every row, with the painted hexes of each side", %{doc: doc} do
      rows = doc |> section("tokens") |> table_rows()

      assert Enum.map(rows, &(&1 |> hd() |> strip_ticks())) == F.rows(),
             "the token table does not list the twelve fixture rows, in order"

      misses =
        Enum.flat_map(rows, fn [token, mock_cell, live_cell | _] ->
          row = strip_ticks(token)

          for {side, cell} <- [mock: mock_cell, live: live_cell],
              hexes(cell) != List.wrap(row_bytes(side, row)) do
            "#{row} #{side}: doc says #{inspect(hexes(cell))}, fixture has " <>
              inspect(List.wrap(row_bytes(side, row)))
          end
        end)

      assert misses == [],
             "token table drifted from the fixture:\n  " <> Enum.join(misses, "\n  ")
    end

    test "the pairs table lists every measured ratio exactly, and nothing else", %{doc: doc} do
      doc_rows =
        doc
        |> section("pairs")
        |> table_rows()
        |> Enum.map(fn [side, fg, bg, painted, token_space | _] ->
          {side, strip_ticks(fg), strip_ticks(bg), painted, token_space}
        end)

      fixture_rows =
        for {side, fg, bg, painted, token_space} <- F.ratios() do
          {Atom.to_string(side), fg, bg, fmt(painted), fmt(token_space)}
        end

      assert doc_rows -- fixture_rows == [],
             "doc rows that do not match the fixture: #{inspect(doc_rows -- fixture_rows)}"

      assert fixture_rows -- doc_rows == [],
             "fixture ratios missing from the doc: #{inspect(fixture_rows -- doc_rows)}"
    end

    test "every recommendation is Adopt, Adapt or Reject, and the table has its full shape",
         %{doc: doc} do
      rows = doc |> section("tokens") |> table_rows()

      for [token | _] = cells <- rows do
        assert length(cells) == 7,
               "#{token}: expected 7 columns (token, mock, live, product-wide change, " <>
                 "regression, recommendation, flagged defect), got #{length(cells)}"

        recommendation = cells |> Enum.at(5) |> String.trim_leading("*")

        assert Regex.match?(~r/^(Adopt|Adapt|Reject)\b/, recommendation),
               "#{token}: recommendation must start with Adopt, Adapt or Reject, " <>
                 "got #{inspect(Enum.at(cells, 5))}"
      end
    end

    test "every verdict in the pairs table agrees with its floor", %{doc: doc} do
      for [side, fg, bg, painted, _, floor, verdict] <- doc |> section("pairs") |> table_rows() do
        want =
          case floor do
            "N/A" -> "N/A"
            _ -> if String.to_float(painted) >= String.to_float(floor), do: "pass", else: "FAIL"
          end

        assert verdict == want,
               "#{side} #{fg} on #{bg}: painted #{painted} against floor #{floor} says " <>
                 "#{verdict}, should be #{want}"
      end
    end
  end

  defp section(doc, name) do
    [_, rest] = String.split(doc, "<!-- drift-guard:#{name} -->", parts: 2)
    [body, _] = String.split(rest, "<!-- /drift-guard:#{name} -->", parts: 2)
    body
  end

  # Data rows only: skips the header row and the |---| separator.
  defp table_rows(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.drop(2)
    |> Enum.map(fn line ->
      line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
    end)
  end

  defp strip_ticks(cell), do: String.trim(cell, "`")
  defp hexes(cell), do: ~r/#[0-9A-F]{6}/ |> Regex.scan(cell) |> List.flatten()
  defp fmt(nil), do: "N/A"
  defp fmt(x), do: :erlang.float_to_binary(x, decimals: 4)

  # ── helpers ─────────────────────────────────────────────────────────────

  defp ratio(side, fg, bg) do
    Enum.find_value(F.ratios(), fn
      {^side, ^fg, ^bg, painted, _} -> painted
      _ -> nil
    end)
  end

  defp row_bytes(side, row) do
    table = if side == :live, do: F.live(), else: F.mock()

    case table[row] do
      %{over: over} -> Map.values(over)
      %{painted: :unresolved, fallback: %{painted: hex}} -> hex
      %{painted: hex} -> hex
    end
  end

  defp bytes(side, key), do: W.hex(F.painted_hex(side, key))

  # The declared colour behind a ratio operand, float-through.
  defp token(:live, key) do
    case String.split(key, "@") do
      [row, ground] ->
        W.composite(live_decl("base-content"), F.live()[row].alpha, live_decl(ground))

      [row] ->
        live_decl(row)
    end
  end

  defp token(:mock, key) do
    case String.split(key, "@") do
      [row, ground] ->
        m = F.mock()[row]
        W.composite(W.hex(m.content), m.alpha, mock_decl(ground))

      ["warning-fallback"] ->
        W.hex(@mock_warning_fallback)

      [row] ->
        mock_decl(row)
    end
  end

  defp live_decl(row) do
    {_var, value} = split_declaration(F.live()[row].declaration)
    W.parse!(value)
  end

  defp mock_decl("card"), do: W.hex(@mock_card)

  defp mock_decl(row) do
    case F.mock()[row] do
      %{literal: literal} ->
        W.hex(literal)

      %{declaration: declaration} ->
        {_var, value} = split_declaration(declaration)
        W.parse!(value)
    end
  end

  defp split_declaration(text) do
    [_, var, value] = Regex.run(~r/^(--[a-z0-9-]+)\s*:\s*(.+?);$/, text)
    {var, String.trim(value)}
  end

  defp theme_block(css, name) do
    css
    |> :binary.matches(@plugin_open)
    |> Enum.map(fn {at, len} ->
      rest = binary_part(css, at + len, byte_size(css) - at - len)
      {close, _} = :binary.match(rest, "\n}")
      binary_part(rest, 0, close)
    end)
    |> Enum.find(&Regex.match?(~r/^\s*name:\s*"#{name}";/m, &1)) ||
      flunk("no daisyui-theme block named #{inspect(name)} in #{@css_path}")
  end

  defp declaration(block, var) do
    case Regex.run(~r/^\s*#{Regex.escape(var)}\s*:\s*([^;]+);/m, block) do
      [_, value] -> String.trim(value)
      nil -> "(no declaration)"
    end
  end
end
