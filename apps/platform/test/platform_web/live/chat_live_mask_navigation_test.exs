defmodule PlatformWeb.ChatLiveMaskNavigationTest do
  @moduledoc """
  Stage 6 regression: screen-share mask state must survive IN-SESSION
  navigation, and must NOT survive a full page reload.

  The behavioural review found both halves broken in the same place. With
  masking on and one org revealed, clicking a rail channel row brought the
  rail back with `aria-pressed="false"`, the mode strip removed from the DOM
  entirely, and every real org name repainted mid-screen-share. The reviewer
  proved the mechanism rather than inferring it: a `window.__probe` set before
  the click read back afterwards, so the browsing context was never torn down
  — it was a LiveView REMOUNT over the same socket, and `mount/3`'s
  unconditional `assign(:mask_names?, false)` re-ran.

  Cause: every rail row rendered `<.link navigate=…>`. They are now
  `<.link patch=…>`, so the LiveView process survives the switch and the
  process lifetime IS the session scope.

  These tests go RED against a53c7e6f: `render_click/1` on a `navigate` link
  returns `{:error, {:live_redirect, …}}` instead of patched HTML, so the
  first assertion after the click blows up.

  The reload half is asserted here too, deliberately in the same file: the
  obvious "fix" for the navigation bug is a sessionStorage-backed restore,
  which SURVIVES a reload and would break the deliberate
  returns-unmasked-next-morning behaviour. Anyone reaching for it trips this.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp create_user do
    Repo.insert!(%User{
      email: "mask_nav_test@example.com",
      name: "Mask Nav Test User",
      oidc_sub: "oidc-mask-nav-test",
      avatar_url: nil
    })
  end

  # A RELOAD is the SAME user opening a NEW LiveView process — so the reload
  # test re-authenticates as the existing row rather than inserting a second
  # user, which would test "a different person's first visit" instead.
  defp authenticated_conn(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp create_channel(slug) do
    {:ok, ch} = Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"})
    ch
  end

  defp desktop_sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  defp toggle_mask(view) do
    view |> element(~s(button[phx-click="toggle_mask_names"])) |> render_click()
  end

  defp first_section_id(html) do
    [_, id] = Regex.run(~r/data-section-id="([^"]+)"/, desktop_sidebar(html))
    id
  end

  defp reveal_section(view, section_id) do
    view
    |> element(~s(button[phx-click="reveal_section"][phx-value-section_id="#{section_id}"]))
    |> render_click()
  end

  defp live_following_redirect(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: to}}} -> live(conn, to)
      ok -> ok
    end
  end

  setup %{conn: conn} do
    create_channel("general")
    create_channel("random")
    user = create_user()
    {:ok, view, html} = live_following_redirect(authenticated_conn(conn, user), ~p"/chat")
    %{conn: conn, user: user, view: view, html: html}
  end

  describe "in-session navigation" do
    test "clicking a rail channel row keeps the mask ON and keeps the mode strip",
         %{view: view} do
      masked = toggle_mask(view)
      assert desktop_sidebar(masked) =~ "channel-mask-strip"
      assert desktop_sidebar(masked) =~ ~s(aria-pressed="true")

      # A rail row is an ordinary anchor. On the pre-fix tree this is a
      # `navigate` and `render_click/1` returns a live_redirect tuple, so
      # `after_nav` is not HTML and the first `=~` raises.
      after_nav =
        view
        |> element(~s(#chat-sidebar a[href="/chat/random"]))
        |> render_click()

      sidebar = desktop_sidebar(after_nav)

      assert sidebar =~ "channel-mask-strip",
             "the mode strip vanished on channel switch — mount/3 re-ran"

      assert sidebar =~ ~s(aria-pressed="true"),
             "the mask toggle reset to off on channel switch"
    end

    test "a per-org reveal survives the same navigation", %{view: view, html: html} do
      toggle_mask(view)
      section_id = first_section_id(html)
      revealed = reveal_section(view, section_id)

      # Sanity: the reveal took effect before we navigate. A test that
      # navigates from a state it never established proves nothing.
      assert desktop_sidebar(revealed) =~ "1 showing"

      after_nav =
        view
        |> element(~s(#chat-sidebar a[href="/chat/random"]))
        |> render_click()

      assert desktop_sidebar(after_nav) =~ "1 showing",
             "the revealed org was dropped on channel switch"
    end

    test "the URL really changed — this is navigation, not a no-op click", %{view: view} do
      toggle_mask(view)

      view
      |> element(~s(#chat-sidebar a[href="/chat/random"]))
      |> render_click()

      assert_patched(view, "/chat/random")
    end
  end

  describe "full page reload" do
    test "returns UNMASKED — session-only is deliberate, do not persist it",
         %{conn: conn, user: user, view: view} do
      masked = toggle_mask(view)
      assert desktop_sidebar(masked) =~ "channel-mask-strip"

      # A reload is a NEW LiveView process on the same browser session. If
      # this ever fails, someone has backed the flag with sessionStorage or a
      # preferences row: someone who masked for one call would return next
      # morning to a rail where their orgs appear to be missing.
      {:ok, _reloaded, html} = live_following_redirect(authenticated_conn(conn, user), ~p"/chat")

      refute desktop_sidebar(html) =~ "channel-mask-strip"
      refute desktop_sidebar(html) =~ "Names hidden"
    end
  end
end
