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

  Burrow redesign 22 stage 2 deleted the desktop channel rail: its eye
  toggle, mode strip and `Show all`, per-section reveal, section labels and
  colour dots. Those tests are deleted with it. What survives is retargeted to
  the desktop Chat list pane and its Options popover switch: masking is off
  on mount, the switch turns it on, an org-named channel row shows no
  spelling of the org and reads `#workspace-<letter>`, and turning it off
  restores the names. The fixture now seeds channels NAMED after the orgs,
  since the list has no org headers.
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

  @orgs ["Vandelay-Ind", "Initech", "Hooli", "Acme"]
  @mask_switch ~s(#chat-list-popover [data-role="chat-list-pop-option-mask"])

  defp create_channel(slug, name \\ nil) do
    {:ok, ch} =
      Chat.create_space(%{name: name || String.capitalize(slug), slug: slug, kind: "channel"})

    ch
  end

  # `GET /chat` redirects to the first channel once one exists.
  defp live_following_redirect(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  # The desktop Chat list's rows (not the popover's search results, which
  # also carry chat-list-row).
  defp list(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#chat-list-scroller")
    |> LazyHTML.to_html()
  end

  defp switch_checked(view) do
    unless has_element?(view, @mask_switch),
      do: view |> element("#list-more") |> render_click()

    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(@mask_switch)
    |> LazyHTML.attribute("aria-checked")
  end

  defp toggle_mask(view) do
    unless has_element?(view, @mask_switch),
      do: view |> element("#list-more") |> render_click()

    view |> element(@mask_switch) |> render_click()
  end

  defp mounted_view(conn) do
    create_channel("general")
    for name <- @orgs, do: create_channel(String.downcase(name), name)
    {:ok, view, html} = live_following_redirect(conn)
    {view, html}
  end

  describe "the mask switch" do
    test "is off on mount and one click turns it on", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()

      # The control is permanently reachable — it is the masked STATE that is
      # conditional, never the switch. A switch that only appeared once
      # masking was on could never be used to turn it on.
      assert switch_checked(view) == ["false"]
      refute has_element?(view, ~s(#chat-list [data-role="chat-list-counts"]), "names masked")

      html = toggle_mask(view)

      assert switch_checked(view) == ["true"]
      assert has_element?(view, ~s(#chat-list [data-role="chat-list-counts"]), "names masked")
      assert list(html) =~ ~r/workspace-[a-z]+/
    end

    test "copy is about presenting, never privacy — and carries no lock metaphor", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()
      toggle_mask(view)

      # Scoped to the masking control: the list legitimately draws a lock
      # glyph on private channel rows, which is not this feature's copy.
      control = view |> element(@mask_switch) |> render()
      assert control =~ "Mask names"

      for forbidden <- ["privacy", "Privacy", "secure", "Secure", "encrypted", "protected"] do
        refute control =~ forbidden,
               "Masking copy must be about presenting, not privacy — found #{forbidden}"
      end

      # A padlock or shield makes the same overclaim the forbidden words do.
      refute control =~ "hero-lock"
      refute control =~ "hero-shield"
    end
  end

  describe "absence of the real name" do
    # Stage 3 finding: a display-form assertion (`refute html =~
    # "Vandelay-Ind"`) passes while a slug attribute spells the org, so every
    # absence here goes through the three-form, case-insensitive helper.
    test "the Chat list carries no spelling of a masked org name, attributes included", %{
      conn: conn
    } do
      {view, html} = conn |> authenticated_conn() |> mounted_view()

      for name <- @orgs, do: assert_name_anywhere(list(html), name)

      masked = view |> toggle_mask() |> list()

      for name <- @orgs, do: refute_name_anywhere(masked, name)
    end
  end

  describe "masked labels" do
    test "the placeholder reaches the desktop Chat list rows", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()
      masked = view |> toggle_mask() |> list()

      placeholders =
        ~r/workspace-[a-z]+/
        |> Regex.scan(String.downcase(masked))
        |> Enum.uniq()

      assert length(placeholders) >= 2,
             "expected distinct placeholders for the org-named rows, got #{inspect(placeholders)}"

      # The word is `Workspace`, never `Client` — `Client A` leaks the
      # category and the count.
      refute String.downcase(masked) =~ "client"
    end

    test "turning the mode back off restores the real names", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn() |> mounted_view()

      assert view |> toggle_mask() |> list() =~ ~r/workspace-[a-z]+/

      restored = view |> toggle_mask() |> list()

      refute restored =~ ~r/workspace-[a-z]+/
      assert_name_anywhere(restored, "Vandelay-Ind")
    end
  end

  # Burrow redesign 22 stage 2 deleted the desktop channel rail; its mode
  # strip, `Show all`, per-item reveal, section label class and colour-dot
  # tests went with it.
end
