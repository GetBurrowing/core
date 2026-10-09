defmodule PlatformWeb.ChatLiveMaskDesktopTest do
  @moduledoc """
  Render-level tests for screen-share name masking in the DESKTOP rail
  (task 01a00c66 stage 2). Setup mirrors `chat_live_section_render_test.exs`,
  which already seeds the real org names the mask has to swap out.

  Coverage here is the rail's behaviour: the mode strip is absent by default,
  one click renders it, `Show all` clears the reveals, and the placeholder
  reaches the desktop rail. The stronger assertion — that the REAL name is
  absent from the whole document including attributes — is stage 4's file
  (`chat_live_mask_absence_test.exs`), deliberately kept separate because
  asserting the placeholder appears proves almost nothing on its own: a
  `display:none` real name renders `Workspace B` on screen while the real
  string sits in the page source and the accessibility tree.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "mask_desktop_test@example.com",
        name: "Mask Desktop Test User",
        oidc_sub: "oidc-mask-desktop-test",
        avatar_url: nil
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_channel(slug) do
    {:ok, ch} = Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"})
    ch
  end

  # `GET /chat` redirects to the first channel once one exists.
  defp live_following_redirect(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  defp desktop_sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  defp toggle_mask(view) do
    view
    |> element(~s(button[phx-click="toggle_mask_names"]))
    |> render_click()
  end

  # The reveal control is one button per masked section, so a bare selector
  # matches several and `element/2` refuses an ambiguous match. Target the
  # first section in rail order by its id.
  defp reveal_first_section(view, html) do
    [_, section_id] = Regex.run(~r/data-section-id="([^"]+)"/, desktop_sidebar(html))

    view
    |> element(~s(button[phx-click="reveal_section"][phx-value-section_id="#{section_id}"]))
    |> render_click()
  end

  defp mounted_view(conn) do
    create_channel("general")
    {:ok, view, html} = live_following_redirect(conn)
    {view, html}
  end

  describe "mode strip" do
    test "is absent by default — masking is OFF on mount", %{conn: conn} do
      {_view, html} = conn |> authenticated_conn() |> mounted_view()
      sidebar = desktop_sidebar(html)

      refute sidebar =~ "channel-mask-strip"
      refute sidebar =~ "Names hidden for sharing"

      # The control itself is permanently visible in the header — it is the
      # STRIP that is conditional, never the toggle. A toggle that only
      # appears once masking is on could never be used to turn it on.
      assert sidebar =~ ~s(phx-click="toggle_mask_names")
      assert sidebar =~ ~s(aria-label="Hide workspace names for sharing")
      assert sidebar =~ "hero-eye"
    end

    test "one click on the eye renders the warning strip and its Show all action", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()
      sidebar = view |> toggle_mask() |> desktop_sidebar()

      assert sidebar =~ "channel-mask-strip"
      assert sidebar =~ "Names hidden for sharing"
      assert sidebar =~ "channel-mask-strip-action"
      assert sidebar =~ "Show all"
      assert sidebar =~ ~s(aria-pressed="true")
    end

    test "copy is about presenting, never privacy — and carries no lock metaphor", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()
      html = toggle_mask(view)

      for forbidden <- ["privacy", "Privacy", "secure", "Secure", "encrypted", "protected"] do
        refute html =~ forbidden,
               "Masking copy must be about presenting, not privacy — found #{forbidden}"
      end

      # A padlock or shield makes the same overclaim the forbidden words do.
      refute html =~ "hero-lock"
      refute html =~ "hero-shield"
    end
  end

  describe "absence of the real name" do
    # Stage 3 finding: this file's original anti-vacuity assertion was written
    # as `refute html =~ "Wayne-Tech"`, which PASSES while
    # `data-section-slug="wayne-tech"` sits in the DOM in plain sight. Slugs are
    # stored underscored and rendered hyphenated, so a display-form assertion
    # says nothing about the attribute surface. Replaced with the three-form,
    # case-insensitive helper — and the desktop rail now masks
    # `data-section-slug` too, which is what makes it pass.
    test "the rail carries no spelling of a masked org name, attributes included", %{conn: conn} do
      {view, html} = conn |> authenticated_conn() |> mounted_view()

      assert_name_anywhere(desktop_sidebar(html), "Wayne-Tech")

      sidebar = view |> toggle_mask() |> desktop_sidebar()

      for name <- ["Wayne-Tech", "Soylent", "Paragon", "Acme"] do
        refute_name_anywhere(sidebar, name)
      end
    end

    test "revealing one org brings back that org and only that org", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()
      masked = toggle_mask(view)
      sidebar = view |> reveal_first_section(masked) |> desktop_sidebar()

      # The revealed section is first in rail order; the rest stay gone in
      # every spelling.
      refute_name_anywhere(sidebar, "Wayne-Tech")
    end
  end

  describe "masked labels" do
    test "the placeholder reaches the desktop rail at the untouched label treatment", %{
      conn: conn
    } do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()
      sidebar = view |> toggle_mask() |> desktop_sidebar()

      assert sidebar =~ "Workspace A"
      assert sidebar =~ "Workspace B"

      # Same class as an unmasked name — full weight and colour, not dimmed,
      # not italic, not blurred. The strip already carries the signal once;
      # degrading every label would duplicate it and make the rail look
      # disabled while it still has to be navigable.
      assert sidebar =~ "channel-section-label"

      # The word is `Workspace`, never `Client` — `Client A` leaks the
      # category and the count.
      refute sidebar =~ "Client A"
    end

    test "the colour dots survive masking, including the hollow unassigned dot", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()
      sidebar = view |> toggle_mask() |> desktop_sidebar()

      assert sidebar =~ "channel-section-color-dot"
      assert sidebar =~ "bg-sxi-dot"
      assert sidebar =~ "channel-section-color-dot--unassigned"
    end

    test "a masked root section's dot drops its data-scope (task 01a116de stage 3)", %{
      conn: conn
    } do
      # The root org's dot is coloured from its row through `data-scope`, and
      # the slug is a spelling of the org's name, so masking suppresses it,
      # the same cost a masked scope chip already pays.
      {view, html} = conn |> authenticated_conn() |> mounted_view()
      assert desktop_sidebar(html) =~ ~s(data-scope="acme")

      refute view |> toggle_mask() |> desktop_sidebar() =~ ~s(data-scope="acme")
    end

    test "turning the mode back off restores the real names", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()

      assert toggle_mask(view) =~ "Workspace A"

      sidebar = view |> toggle_mask() |> desktop_sidebar()

      refute sidebar =~ "Workspace A"
      assert sidebar =~ "Wayne-Tech"
    end
  end

  describe "per-item reveal" do
    test "revealing one org shows its real name, marks it, and leaves the rest masked", %{
      conn: conn
    } do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()
      masked = toggle_mask(view)

      sidebar = view |> reveal_first_section(masked) |> desktop_sidebar()

      assert sidebar =~ "channel-section--revealed"
      assert sidebar =~ "Names hidden · 1 showing"
      # Reveals are per-section: the other sections keep their placeholders.
      assert sidebar =~ "Workspace B"
    end

    test "Show all clears every reveal while the mode stays on", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()
      masked = toggle_mask(view)
      reveal_first_section(view, masked)

      sidebar =
        view
        |> element(~s(button[phx-click="remask_all"]))
        |> render_click()
        |> desktop_sidebar()

      refute sidebar =~ "channel-section--revealed"
      refute sidebar =~ "showing"
      assert sidebar =~ "Names hidden for sharing"
      assert sidebar =~ "Workspace A"
    end

    test "toggling the mode off and on again does not resurrect a stale reveal", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()
      masked = toggle_mask(view)
      reveal_first_section(view, masked)

      # off, then on again
      toggle_mask(view)
      sidebar = view |> toggle_mask() |> desktop_sidebar()

      refute sidebar =~ "channel-section--revealed"
      assert sidebar =~ "Names hidden for sharing"
    end
  end
end
