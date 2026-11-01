defmodule Platform.Design.PinnedReorderContrastGuardTest do
  @moduledoc """
  Holds the paint of the desktop pinned reorder (Burrow redesign 25 stage 2,
  direction canvas 01a17470) in all ten preset variants (Burrow, Midnight,
  Sand, Forest, High contrast; light and dark), measured as painted.

  ## Pairs and floors

  | pair                                                          | floor |
  |---------------------------------------------------------------|-------|
  | grip: --subtle on base-300 (hover and current-row fill)        | 3     |
  | grip: --subtle on base-200 (keyboard focus, row not hovered)   | 3     |
  | grip: --subtle on base-100 (the lifted row, stage 3)           | 3     |
  | drop line: base-content on base-200 (stage 3)                  | 3     |
  | toast text: base-content on base-100                           | 4.5   |
  | Undo: base-content on base-100                                 | 4.5   |
  | Undo on hover: base-content on base-300                        | 4.5   |

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`, alpha
  over the ground, so the grip pairs are PAINTED: the worst pixel
  `Platform.Design.PaintedComposite` allows at the block's declared
  strength. Every other token is opaque and measured with
  `WcagContrast.contrast/2`.

  ## Exempt: the origin-slot outline

  While a row is lifted (stage 3) its original slot keeps a base-300
  outline of the same height. It is DECORATIVE: the 2px base-content drop
  line carries the position, and the lifted row carries the identity, so
  nothing is lost if the outline cannot be seen. It is the only pair this
  guard does not claim.

  If a claimed pair fails, report the variant and the ratio; never swap a
  token or lower a floor here.

  ## Source guard

  The rendered HTML of the grip, the undo toast and the announcer carries no
  `primary` and no hex colour (the direction: no primary anywhere in this
  interaction).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat.Sidebar
  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.WcagContrast, as: W
  alias Platform.Tenancy

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)

  @aa_text 4.5
  @non_text 3.0

  @variants [
    {"burrow", "light"},
    {"burrow", "dark"},
    {"burrow-midnight", "light"},
    {"burrow-midnight", "dark"},
    {"burrow-sand", "light"},
    {"burrow-sand", "dark"},
    {"burrow-forest", "light"},
    {"burrow-forest", "dark"},
    {"high-contrast", "light"},
    {"high-contrast", "dark"},
    {"sage", "light"},
    {"sage", "dark"}
  ]

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/
  @hex ~r/#[0-9a-fA-F]{3,8}\b/
  @flag_key :agents_goal_surface

  setup_all do
    app_css = File.read!(@app_css_path)
    presets = File.read!(@presets_path)

    by_key =
      Map.new(Blocks.preset_blocks(presets), &{{&1.id, &1.mode}, &1})
      |> Map.put({"burrow", "light"}, Blocks.burrow_block(app_css, "light"))
      |> Map.put({"burrow", "dark"}, Blocks.burrow_block(app_css, "dark"))

    blocks =
      for {id, mode} = key <- @variants do
        Map.get(by_key, key) || flunk("no #{id} #{mode} block")
      end

    {:ok, blocks: blocks}
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: ThemeBlockAssertions.resolve!(b, token)
  defp ratio(b, ink, ground), do: W.contrast(c(b, ink), c(b, ground))

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  defp subtle_on(b, ground) do
    {r, _} =
      PaintedComposite.contrast_min(c(b, "--color-base-content"), c(b, ground), subtle_pct(b))

    r
  end

  defp pairs(b) do
    [
      {"grip (subtle) / base-300 (painted)", subtle_on(b, "--color-base-300"), @non_text},
      {"grip (subtle) / base-200 (painted)", subtle_on(b, "--color-base-200"), @non_text},
      {"grip (subtle) / base-100 (painted)", subtle_on(b, "--color-base-100"), @non_text},
      {"drop line base-content / base-200", ratio(b, "--color-base-content", "--color-base-200"),
       @non_text},
      {"toast text base-content / base-100", ratio(b, "--color-base-content", "--color-base-100"),
       @aa_text},
      {"Undo base-content / base-100", ratio(b, "--color-base-content", "--color-base-100"),
       @aa_text},
      {"Undo hover base-content / base-300", ratio(b, "--color-base-content", "--color-base-300"),
       @aa_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  test "every claimed pair clears its floor in all ten variants; the table prints",
       %{blocks: blocks} do
    assert length(blocks) == 12
    rows = for b <- blocks, do: {b, pairs(b)}
    {_, first} = hd(rows)
    labels = Enum.map(first, &elem(&1, 0))

    IO.puts(
      "\nPinned reorder AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <> " |"
        end)
    )

    minima =
      for {label, _, floor} <- first do
        {b, r} =
          rows
          |> Enum.map(fn {b, ps} -> {b, ps |> Enum.find(&(elem(&1, 0) == label)) |> elem(1)} end)
          |> Enum.min_by(&elem(&1, 1))

        "#{label}: min #{f4(r)} (#{b.id} #{b.mode}, floor #{floor})"
      end

    IO.puts("Minima across the ten variants:\n" <> Enum.join(minima, "\n"))

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  # ── source guard ───────────────────────────────────────────────────────

  describe "source guard" do
    setup do
      previous = Application.get_env(:platform, @flag_key)
      on_exit(fn -> Application.put_env(:platform, @flag_key, previous) end)
      Application.put_env(:platform, @flag_key, false)
      :ok
    end

    test "the grip, the undo toast and the announcer render no primary and no hex",
         %{conn: conn} do
      user = create_user!()
      org = Tenancy.get_org!(acme_org_id())
      plain_member!(user, org)

      [a, b] =
        for name <- ~w(GuardA GuardB) do
          n = System.unique_integer([:positive])
          channel!(%{name: "#{name}#{n}", slug: "pin-guard-#{n}", org_id: org.id})
        end

      for s <- [a, b], do: {:ok, _} = Sidebar.set_space_pinned(user.id, s.id, true)
      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")

      render_hook(view, "move_pinned_step", %{"space_id" => b.id, "direction" => "up"})

      doc = view |> element("#chat-list") |> render() |> LazyHTML.from_fragment()

      parts =
        for sel <- [
              "[data-role=chat-list-row-grip]",
              "#pinned-undo-toast",
              "#pinned-reorder-announcer"
            ] do
          html = doc |> LazyHTML.query(sel) |> LazyHTML.to_html()
          # Anti-vacuity: each part is really in the DOM.
          assert html != "", "#{sel} did not render"
          {sel, html}
        end

      for {sel, html} <- parts do
        refute html =~ "primary", "#{sel} carries primary: #{html}"
        refute html =~ @hex, "#{sel} carries a hex colour: #{html}"
      end
    end
  end
end
