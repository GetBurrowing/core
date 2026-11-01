defmodule Platform.Design.AdminReskinContrastGuardTest do
  @moduledoc """
  Holds the re-skinned `/admin` index (Burrow redesign 24, task 01a1557a-fe9b
  stage 4) in all ten preset variants (Burrow, Midnight, Sand, Forest, High
  contrast; light and dark).

  ## Pairs and floors

  | pair                                                   | floor     |
  |--------------------------------------------------------|-----------|
  | base-content on base-200 (card rest, ghost rest)       | 4.5       |
  | base-content on base-300 (card at lg:hover)            | 4.5       |
  | --subtle on base-200 (painted, worst pixel)            | 4.5       |
  | --subtle on base-300 (painted, worst pixel)            | 4.5       |
  | focus ring (`focus-visible-ring`) on base-200          | 3         |
  | edge on base-100                                       | recorded  |

  Stage 5 adds the admin sub-pages (branding, orgs, federation, prompts,
  vault, sign-in users, recovery, external logins, access, insights,
  prototypes), which move status hue off text onto dots, icons and borders:

  | pair                                                   | floor     |
  |--------------------------------------------------------|-----------|
  | base-content on base-100                               | 4.5       |
  | --subtle on base-100 (painted, worst pixel)            | 4.5       |
  | primary-content on primary (buttons)                   | 4.5       |
  | error-content on error (destructive buttons)           | 4.5       |
  | info, success, warning, error mark on base-100         | 3         |
  | info, success, warning, error mark on base-200         | 3         |

  Floors come from `Platform.Theming.ContrastPairs`, colours from each
  preset's declared variant (`Platform.Theming.Presets`), and --subtle is
  painted on the worst pixel `Platform.Design.PaintedComposite` allows. If a
  pair fails, the token changes, never the floor.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedComposite, as: PC
  alias Platform.Design.WcagContrast, as: W
  alias Platform.Theming.ContrastPairs
  alias Platform.Theming.Presets

  @source_path Path.expand("../../../lib/platform_web/live/admin_live.html.heex", __DIR__)

  @live Path.expand("../../../lib/platform_web/live", __DIR__)

  # Sub-pages whose status hue now rides on a mark (dot, icon, border).
  @sub_pages ~w(admin_branding_live.html.heex admin_orgs_live.html.heex
                admin_federation_live.html.heex admin_prompts_live.html.heex
                admin_vault_live.html.heex admin_vault_live.ex
                admin_sign_in_users_live.html.heex recovery_live.ex
                recovery_live.html.heex external_recovery_live.html.heex
                access_live.html.heex access_live.ex)

  @status ~w(info success warning error)

  defp variants do
    for preset <- Presets.all(), mode <- ["light", "dark"] do
      {"#{preset.id} #{mode}", Map.fetch!(preset.variants, mode)}
    end
  end

  defp c(v, slot), do: v.colors |> Map.fetch!(slot) |> W.hex()

  defp solid(v, fg, bg), do: W.contrast(c(v, fg), c(v, bg))

  defp painted(v, bg) do
    {r, _} = PC.contrast_min(c(v, "--color-base-content"), c(v, bg), v.subtle)
    r
  end

  defp pairs(v) do
    text = ContrastPairs.aa_text()
    ui = ContrastPairs.non_text()

    [
      {"base-content / base-200", text, solid(v, "--color-base-content", "--color-base-200")},
      {"base-content / base-300", text, solid(v, "--color-base-content", "--color-base-300")},
      {"subtle / base-200 (painted)", text, painted(v, "--color-base-200")},
      {"subtle / base-300 (painted)", text, painted(v, "--color-base-300")},
      {"focus-ring / base-200", ui, solid(v, "--focus-ring", "--color-base-200")}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  test "every admin index pair clears its floor in all ten variants; the table prints" do
    rows = for {name, v} <- variants(), do: {name, v, pairs(v)}
    assert length(rows) == 12

    labels = rows |> hd() |> elem(2) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nAdmin index AA table (WCAG 2.x; --subtle painted on the worst pixel):\n" <>
        "| Variant | " <>
        Enum.join(labels ++ ["edge / base-100 (recorded)"], " | ") <>
        " |\n" <>
        Enum.map_join(rows, "\n", fn {name, v, ps} ->
          "| #{name} | " <>
            Enum.map_join(ps, " | ", fn {_, _, r} -> f4(r) end) <>
            " | " <> f4(solid(v, "--edge", "--color-base-100")) <> " |"
        end)
    )

    failures =
      for {name, _v, ps} <- rows, {label, floor, r} <- ps, r < floor do
        "#{name}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "edge on base-100 is recorded, not floored" do
    for {_name, v} <- variants(), do: assert(solid(v, "--edge", "--color-base-100") > 1.0)
  end

  test "anti-vacuity: the index paints exactly the slots this guard measures" do
    source = File.read!(@source_path)

    for slot <- ~w(bg-base-200 lg:hover:bg-base-300 text-base-content text-subtle
                   focus-visible-ring border-edge) do
      assert source =~ slot, "the admin index no longer paints #{slot}; update the guard"
    end
  end

  defp sub_page_pairs(v) do
    text = ContrastPairs.aa_text()
    ui = ContrastPairs.non_text()

    [
      {"base-content / base-100", text, solid(v, "--color-base-content", "--color-base-100")},
      {"subtle / base-100 (painted)", text, painted(v, "--color-base-100")},
      {"primary-content / primary", text, solid(v, "--color-primary-content", "--color-primary")},
      {"error-content / error", text, solid(v, "--color-error-content", "--color-error")}
    ] ++
      for slot <- @status, ground <- ["base-100", "base-200"] do
        {"#{slot} mark / #{ground}", ui, solid(v, "--color-#{slot}", "--color-#{ground}")}
      end
  end

  test "every admin sub-page pair clears its floor in all ten variants; the table prints" do
    rows = for {name, v} <- variants(), do: {name, sub_page_pairs(v)}
    assert length(rows) == 12

    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))
    assert length(labels) == 12

    IO.puts(
      "\nAdmin sub-page table (WCAG 2.x; marks at the 3:1 non-text floor):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n" <>
        Enum.map_join(rows, "\n", fn {name, ps} ->
          "| #{name} | " <> Enum.map_join(ps, " | ", fn {_, _, r} -> f4(r) end) <> " |"
        end)
    )

    failures =
      for {name, ps} <- rows, {label, floor, r} <- ps, r < floor do
        "#{name}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "anti-vacuity: the sub-pages paint the marks and fills this guard measures" do
    all = Enum.map_join(@sub_pages, "\n", &File.read!(Path.join(@live, &1)))

    for slot <- @status do
      assert all =~ ~r/\b(bg|border)-#{slot}\b/,
             "no sub-page paints a #{slot} mark any more; update the guard"
    end

    for slot <- ~w(btn-primary btn-error bg-base-100 bg-base-200 text-subtle text-base-content) do
      assert all =~ slot, "no sub-page paints #{slot}; update the guard"
    end
  end
end
