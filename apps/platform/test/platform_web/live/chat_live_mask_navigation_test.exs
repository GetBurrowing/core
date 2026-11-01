defmodule PlatformWeb.ChatLiveMaskNavigationTest do
  @moduledoc """
  Stage 6 regression: screen-share mask state must survive IN-SESSION
  navigation. Since task 01a1557a-e538 stage 2 it also survives a full page
  reload for 12 hours, and not after.

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

  The reload half is asserted here too. Its rule CHANGED in task 01a1557a-e538
  stage 2: the mask is now one person's preference with a 12-hour expiry
  (`Platform.Accounts.mask_names?/1`, `users.preferences["mask_names_until"]`),
  approved by the product owner on 2026-10-21 ("12 hour cross-device is fine"). So a reload
  within 12 hours comes back MASKED, and a reload after the expiry comes back
  UNMASKED. The second half is the old next-morning rule, kept: someone who
  masked for one call must not return the next morning to a rail where their
  orgs appear to be missing. Do not back the flag with sessionStorage: it would
  outlive the expiry.

  Burrow redesign 22 stage 2 deleted the desktop channel rail (its eye
  toggle, mode strip and per-org reveal). The surviving surface is the Chat
  list: its rows are the patch links, its counts line reads "names masked"
  while masked, and an org-named channel row (`Globex`) is the name the mask
  must keep off the list. The per-org reveal test went with the rail.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp create_user do
    Repo.insert!(%User{
      email: "mask_nav_test@example.com",
      name: "Mask Nav Test User",
      oidc_sub: "oidc-mask-nav-test",
      avatar_url: nil,
      preferences: %{"first_run_goal" => "existing"}
    })
  end

  # A RELOAD is the SAME user opening a NEW LiveView process — so the reload
  # test re-authenticates as the existing row rather than inserting a second
  # user, which would test "a different person's first visit" instead.
  defp authenticated_conn(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp create_channel(slug, org_slug \\ nil) do
    org = org_slug && Platform.Tenancy.get_org_by_slug(org_slug)

    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel",
        org_id: org && org.id
      })

    ch
  end

  @mask_switch ~s(#chat-list-popover [data-role="chat-list-pop-option-mask"])

  defp toggle_mask(view) do
    unless has_element?(view, @mask_switch),
      do: view |> element("#list-more") |> render_click()

    view |> element(@mask_switch) |> render_click()
  end

  defp list(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#chat-list-scroller")
    |> LazyHTML.to_html()
  end

  defp counts_line(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#chat-list [data-role="chat-list-counts"]))
    |> LazyHTML.text()
    |> String.trim()
  end

  # Masked as the person sees it: the counts line says so AND the org-named
  # row no longer spells its org. Unmasked is the opposite of both, and each
  # caller asserts the half it needs, so neither direction is vacuous.
  defp assert_masked(html, message) do
    assert counts_line(html) == "names masked", message
    assert list(html) =~ ~s(data-space-id=)
    refute_name_anywhere(list(html), "Globex")
  end

  defp assert_unmasked(html) do
    refute counts_line(html) == "names masked"
    assert_name_anywhere(list(html), "Globex")
  end

  defp live_following_redirect(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: to}}} -> live(conn, to)
      ok -> ok
    end
  end

  setup %{conn: conn} do
    create_channel("general")
    random = create_channel("random")
    create_channel("globex", "globex")
    user = create_user()
    {:ok, view, html} = live_following_redirect(authenticated_conn(conn, user), ~p"/chat")
    # Positive control for every test below: mask off on first mount.
    assert_unmasked(html)
    %{conn: conn, user: user, view: view, html: html, random: random}
  end

  describe "in-session navigation" do
    test "clicking a Chat list row keeps the mask ON", %{view: view, random: random} do
      view |> toggle_mask() |> assert_masked("toggle did not mask")

      # A list row is an ordinary anchor. Were it a `navigate`,
      # `render_click/1` would return a live_redirect tuple, so `after_nav`
      # would not be HTML and the first assertion would raise.
      after_nav =
        view
        |> element(~s(#chat-list a[data-role="chat-list-row"][data-space-id="#{random.id}"]))
        |> render_click()

      assert_masked(after_nav, "the mask reset to off on channel switch — mount/3 re-ran")
    end

    # Burrow redesign 22 stage 2 deleted the desktop channel rail; the per-org
    # reveal survival test went with it (nothing in chat reveals a section).

    test "the URL really changed — this is navigation, not a no-op click",
         %{view: view, random: random} do
      toggle_mask(view)

      view
      |> element(~s(#chat-list a[data-role="chat-list-row"][data-space-id="#{random.id}"]))
      |> render_click()

      assert_patched(view, "/chat/random")
    end
  end

  describe "full page reload" do
    test "within 12 hours returns MASKED: the mount reads the person's preference",
         %{conn: conn, user: user, view: view} do
      view |> toggle_mask() |> assert_masked("toggle did not mask")

      # A reload is a NEW LiveView process on the same browser session.
      {:ok, _reloaded, html} = live_following_redirect(authenticated_conn(conn, user), ~p"/chat")

      assert_masked(html, "a reload within 12 hours came back unmasked")
    end

    test "after the 12-hour expiry returns UNMASKED: the next-morning rule",
         %{conn: conn, user: user, view: view} do
      view |> toggle_mask() |> assert_masked("toggle did not mask")

      # Age the stored instant past now, as the next morning would.
      expired = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
      stored = Repo.get!(User, user.id)

      stored
      |> User.changeset(%{
        preferences: Map.put(stored.preferences || %{}, "mask_names_until", expired)
      })
      |> Repo.update!()

      {:ok, _reloaded, html} = live_following_redirect(authenticated_conn(conn, user), ~p"/chat")

      assert_unmasked(html)
    end
  end
end
