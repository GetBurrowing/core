defmodule PlatformWeb.RootLayoutOrgThemesTest do
  @moduledoc """
  The root layout's published org themes (task 01a1557a-fe9b stage 3):
  `<style id="org-themes" data-role="org-themes">` after `#install-theme`,
  one block per mode for each published theme the signed-in viewer can see,
  and those ids in the theme boot's `data-presets`, so a stored org preset is
  right in the first paint.

  Named mutations, recorded in the stage commit: (a) drop the membership
  filter from `Theming.list_published_for_user/1` and "only the viewer's
  visible themes" goes red (the outsider sees the root theme); (b) emit the
  stored value unsanitised and "a stored value carrying } or url( is dropped"
  goes red.

  Dead `get/2` renders, as in `theme_boot_render_test.exs`: only the dead
  render carries the root layout.
  """

  use PlatformWeb.ConnCase, async: true

  import Ecto.Query
  import Platform.OrgThemeFixtures

  alias Platform.Accounts
  alias Platform.Repo
  alias Platform.Theming.OrgTheme
  alias Platform.Theming.OrgThemeCss
  alias Platform.Theming.Tokens

  setup do
    org_theme_world!()
  end

  # /settings: a ShellLive route every member reaches, whatever their org
  # (a root-org space redirects a tenant-only member).
  defp page_for(conn, user) do
    conn
    |> init_test_session(current_user_id: user.id)
    |> get(~p"/settings")
    |> html_response(200)
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp org_css(html) do
    case html |> doc() |> LazyHTML.query("style#org-themes") |> Enum.to_list() do
      [] -> nil
      [style] -> LazyHTML.text(style)
    end
  end

  defp boot_presets(html) do
    [presets] =
      html
      |> doc()
      |> LazyHTML.query(~s(script[data-role="theme-boot"]))
      |> LazyHTML.attribute("data-presets")

    String.split(presets, " ", trim: true)
  end

  defp selector(theme, mode),
    do:
      ~s|[data-preset="#{OrgTheme.preset_id(theme)}"][data-theme="#{mode}"]:not([data-theme-preview])|

  describe "blocks for the viewer's visible published themes" do
    test "only the viewer's visible themes are emitted, one block per mode", ctx do
      member_html = page_for(build_conn(), ctx.member)
      css = org_css(member_html)

      assert is_binary(css)
      assert css =~ selector(ctx.visible, "dark")
      assert css =~ selector(ctx.visible, "light")
      refute css =~ OrgTheme.preset_id(ctx.hidden)

      # The other org's member sees their own theme and not the root's.
      outsider_css = page_for(build_conn(), ctx.outsider) |> org_css()
      assert outsider_css =~ selector(ctx.hidden, "dark")
      refute outsider_css =~ OrgTheme.preset_id(ctx.visible)

      # Same ids in the boot script's preset list, after the registry.
      presets = boot_presets(member_html)
      assert OrgTheme.preset_id(ctx.visible) in presets
      refute OrgTheme.preset_id(ctx.hidden) in presets
      assert Enum.take(presets, 5) == Platform.Accounts.ThemePreference.preset_ids()
    end

    test "the block sits after #install-theme and carries the theme's declarations", ctx do
      html = page_for(build_conn(), ctx.member)
      css = org_css(html)

      # Every line of the block is the sanitised declaration string.
      for line <- String.split(Tokens.safe_declarations(ctx.visible, "dark"), "\n"),
          do: assert(css =~ line)

      # Source order: no install-theme block here, so the style follows the
      # app.css link; when one exists it must precede ours.
      {css_at, _} = :binary.match(html, ~s(id="org-themes"))
      {link_at, _} = :binary.match(html, "/assets/css/app.css")
      assert link_at < css_at

      case :binary.match(html, ~s(id="install-theme")) do
        {install_at, _} -> assert install_at < css_at
        :nomatch -> :ok
      end
    end

    test "a viewer with no visible published theme gets no style and no org ids",
         %{conn: conn} do
      lonely = Platform.ExternalUserFixtures.create_user!()
      html = page_for(conn, lonely)

      assert org_css(html) == nil
      assert boot_presets(html) == Platform.Accounts.ThemePreference.preset_ids()
    end

    test "a signed-out render gets no org css and only the registry ids" do
      boot = PlatformWeb.Layouts.theme_boot(%{})

      assert boot.org_theme_css == nil
      assert boot.presets == Enum.join(Platform.Accounts.ThemePreference.preset_ids(), " ")
    end

    test "a stored org preset paints on <html> in the first frame", ctx do
      {:ok, _} =
        Accounts.put_theme_preference(ctx.member, %{
          "preset" => OrgTheme.preset_id(ctx.visible),
          "mode" => "light"
        })

      html = page_for(build_conn(), ctx.member)
      [tag] = Regex.run(~r/<html\b[^>]*>/, html, capture: :first)

      assert tag =~ ~s(data-preset="#{OrgTheme.preset_id(ctx.visible)}")
      assert tag =~ ~s(data-theme="light")
    end
  end

  describe "re-sanitised at render" do
    test "a stored value carrying } or url( is dropped; the rest of the block stays", ctx do
      bad_ink = "#ffffff} body { background: url(https://evil.example/x.png)"
      bad_font = "Inter; } @import url(evil.css); x"

      dark = Map.put(ctx.visible.dark, "ink", bad_ink)
      shape = Map.put(ctx.visible.shape, "font", bad_font)

      {1, _} =
        Repo.update_all(from(t in OrgTheme, where: t.id == ^ctx.visible.id),
          set: [dark: dark, shape: shape]
        )

      css = page_for(build_conn(), ctx.member) |> org_css()

      # Anti-vacuity: the block for the tampered theme is still there.
      assert css =~ selector(ctx.visible, "dark")
      assert css =~ "--color-base-200: #{ctx.visible.dark["ground"]};"

      refute css =~ "url("
      refute css =~ "@import"
      refute css =~ "evil"
      refute css =~ "body {"
      # The tampered slots are absent, not emptied: Burrow's value shows.
      dark_block = css |> String.split(selector(ctx.visible, "light")) |> hd()
      refute dark_block =~ "--color-base-content:"
      refute css =~ "--font-sans:"
      # Exactly two closing braces per theme: ours.
      assert length(Regex.scan(~r/}/, css)) == 2
    end

    test "a clean theme loses nothing: safe_declarations/2 == declarations/2", ctx do
      for theme <- [ctx.visible | Platform.Theming.Presets.all()], mode <- ["dark", "light"] do
        assert Tokens.safe_declarations(theme, mode) == Tokens.declarations(theme, mode)
      end
    end

    test "safe_declaration?/2 drops every forbidden form and any unlisted name" do
      for value <- [
            "#fff}",
            "#ffffff;",
            "url(x)",
            "@import 'x'",
            "<script>",
            "expression(alert(1))",
            "attr(x)",
            "#FFFFFF",
            "red"
          ] do
        refute Tokens.safe_declaration?("--color-base-100", value), value
      end

      refute Tokens.safe_declaration?("--font-sans", "Inter; } @import url(x)")
      refute Tokens.safe_declaration?("--radius-box", "10px;")
      refute Tokens.safe_declaration?("background", "#ffffff")
      refute Tokens.safe_declaration?("--color-base-100", nil)

      # Positive controls: the values the server does produce pass.
      assert Tokens.safe_declaration?("--color-base-100", "#0e1116")
      assert Tokens.safe_declaration?("--radius-box", "10px")
      assert Tokens.safe_declaration?("--font-sans", ~s("Public Sans", system-ui, sans-serif))
      assert Tokens.safe_declaration?("--subtle", Tokens.mix(55))
    end

    test "a theme whose id is not a UUID emits nothing" do
      assert OrgThemeCss.render([%OrgTheme{id: "x} body{", name: "Bad"}]) == nil
      assert OrgThemeCss.render([]) == nil
    end
  end
end
