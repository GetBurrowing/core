defmodule PlatformWeb.RootLayoutThemeColorsTest do
  @moduledoc """
  Every app page re-themes from the stored `install_branding` row (task
  01a0dbee-f598-7001-b450-7890103f44c4 stage 2). This is the ticket's
  anti-hardcode test.

  ## Why ONE save is followed by many assertions

  The failure this guards is a half-wired theme: light follows the row and
  dark does not, or the explicit `data-theme` path follows and the
  OS-preference path does not, or the stored values are swapped between
  modes. The sentinels differ from every Suite default in BOTH modes and from
  each other, so a renderer that emits defaults, drops a mode, or swaps the
  selectors reds at least one assertion. A second save then proves the next
  GET re-reads the row (no cache).

  The page is `/tasks`, an ordinary app page through the `:browser`
  pipeline and the root layout, rendered as the Fabrikam admin the save needs.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Branding
  alias Platform.Branding.Palette
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @light_sel ~s|:root:not([data-theme]),[data-theme="light"]:not([data-theme-preview])|
  @dark_sel ~s|[data-theme="dark"]:not([data-theme-preview])|
  @os_dark_sel ~s|:root:not([data-theme="light"])|

  defp admin! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "theme-colors-#{n}@example.com",
        name: "Theme Colors #{n}",
        oidc_sub: "oidc-theme-colors-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("fabrikam").id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  defp render_page(user) do
    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"current_user_id" => user.id})
      |> get("/tasks")

    html_response(conn, 200)
  end

  defp install_theme(html) do
    case Regex.run(~r{<style[^>]*id="install-theme"[^>]*>(.*?)</style>}s, html) do
      [_, css] -> css
      nil -> nil
    end
  end

  # Declarations of the block whose selector is exactly `sel`, as a map.
  # `sel` may appear inside the @media wrapper; the first occurrence of
  # `sel{` is taken, which is why the light and dark selectors are distinct
  # strings.
  defp block(css, sel) do
    case :binary.match(css, sel <> "{") do
      :nomatch ->
        flunk("no #{sel} block in:\n#{css}")

      {idx, len} ->
        rest = binary_part(css, idx + len, byte_size(css) - idx - len)
        [body | _] = String.split(rest, "}", parts: 2)

        body
        |> String.split(";", trim: true)
        |> Map.new(fn decl ->
          [k, v] = decl |> String.trim() |> String.split(":", parts: 2)
          {k, v}
        end)
    end
  end

  defp media_block(css) do
    [_, inner] = Regex.run(~r/@media \(prefers-color-scheme: dark\)\{(.*)\}\s*\z/s, css)
    block(inner, @os_dark_sel)
  end

  test "a fresh install renders no install-theme element at all", %{conn: _conn} do
    html = render_page(admin!())

    refute html =~ ~s(id="install-theme")
    refute html =~ ~s(data-role="install-theme")
  end

  test "stored colours reach every page, per mode, and the next GET follows a re-save" do
    admin = admin!()

    sentinels = %{
      light: %{action: "#7a3fd1", surface: "#fbfaf5"},
      dark: %{action: "#9fe870", surface: "#10141a"}
    }

    defaults = Palette.suite_defaults()

    for mode <- [:light, :dark], slot <- [:action, :surface] do
      refute sentinels[mode][slot] == defaults[mode][slot]
    end

    {:ok, _} =
      Branding.update_colors(admin, %{
        light_action: "#7a3fd1",
        light_surface: "#fbfaf5",
        dark_action: "#9fe870",
        dark_surface: "#10141a"
      })

    html = render_page(admin)
    css = install_theme(html)
    assert css, "no <style id=\"install-theme\"> on the page"

    # After the app.css link, so it wins on source order.
    {link_at, _} = :binary.match(html, "/assets/css/app.css")
    {style_at, _} = :binary.match(html, ~s(id="install-theme"))
    assert link_at < style_at

    light = block(css, @light_sel)
    dark = block(css, @dark_sel)
    os_dark = media_block(css)

    assert light["--color-primary"] == "#7a3fd1"
    assert light["--color-base-100"] == "#fbfaf5"
    assert dark["--color-primary"] == "#9fe870"
    assert dark["--color-base-100"] == "#10141a"
    assert os_dark["--color-primary"] == "#9fe870"
    assert os_dark["--color-base-100"] == "#10141a"

    for {name, decls} <- [light: light, dark: dark, os_dark: os_dark] do
      assert decls["--focus-ring"], "#{name} has no --focus-ring"
      assert decls["--color-interactive"], "#{name} has no --color-interactive"
      assert decls["--edge"], "#{name} has no --edge"
    end

    refute css =~ "--color-edge:"
    refute css =~ "--color-focus-ring:"

    # Source order: light, then dark, then the OS-preference media block LAST.
    {l, _} = :binary.match(css, @light_sel <> "{")
    {d, _} = :binary.match(css, @dark_sel <> "{")
    {m, _} = :binary.match(css, "@media (prefers-color-scheme: dark)")
    assert l < d and d < m

    # No cache: re-save, and the very next GET carries the new values.
    {:ok, _} =
      Branding.update_colors(admin, %{light_action: "#1f6f3a", dark_surface: "#0b0d12"})

    css = install_theme(render_page(admin))

    assert block(css, @light_sel)["--color-primary"] == "#1f6f3a"
    assert block(css, @light_sel)["--color-base-100"] == "#fbfaf5"
    assert block(css, @dark_sel)["--color-base-100"] == "#0b0d12"
    assert media_block(css)["--color-base-100"] == "#0b0d12"
    refute css =~ "#7a3fd1"

    # And a reset removes the element again: back to exactly app.css.
    {:ok, _} = Branding.reset_colors(admin)
    refute render_page(admin) =~ ~s(id="install-theme")
  end
end
