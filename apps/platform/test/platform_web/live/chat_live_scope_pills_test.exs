defmodule PlatformWeb.ChatLiveScopePillsTest do
  @moduledoc """
  Render + event tests for the chat-rail and chat-header scope-pills
  (chat plan v2 Stage 4).

  Coverage:
    * Active channel row does NOT render a per-channel `.channel-row-scope-pill`
      (removed in task 019e464d), while the section-header scope-pill is retained.
    * Chat header renders a prominent `<.scope_pill>` (size variant via
      `.chat-header-scope-pill` wrapper) when a channel is active.
    * Clicking the header pill pushes a `scope_filter` event with the
      channel's scope and narrows the sub-org rail to that bucket only.
    * Header pill not rendered when no channel is active (e.g. on a DM /
      group conversation surface).
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user = insert_chat_user()
    init_test_session(conn, current_user_id: user.id)
  end

  defp insert_chat_user do
    Repo.insert!(%User{
      email: "scope_pills_test@example.com",
      name: "Scope Pills Test User",
      oidc_sub: "oidc-scope-pills-test",
      avatar_url: nil
    })
  end

  # Post-019fa0ac the chat-header scope-pill resolves its scope from the
  # space's `org_id` (mirroring the sidebar rail), NOT the channel slug — so a
  # channel must actually belong to the org whose pill we expect to render.
  # The seeded root orgs (priv/repo/migrations/20260519143620_seed_root_orgs.exs)
  # use slugs fabrikam/soylent/wayne_tech/sxi/paragon — the same tokens these tests
  # pass in — so resolve the matching org and stamp its id. (Sidebar *section*
  # bucketing is still slug-based via `channel_scope/1`, so the
  # `channel-section-label` assertions are unaffected by the added org_id.)
  defp create_channel(slug) do
    org = Platform.Tenancy.get_org_by_slug(slug)

    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel",
        org_id: org && org.id
      })

    ch
  end

  # Mirror of the helper in chat_live_section_render_test.exs — `GET /chat`
  # redirects to the first channel as soon as one exists. Tests in this
  # module always land on a real channel slug so the active-channel and
  # chat-header surfaces both render.
  defp live_at(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: redirect}}} -> live(conn, redirect)
      ok -> ok
    end
  end

  defp desktop_sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  describe "per-channel-row scope-pill removal (task 019e464d)" do
    # Before task 019e464d the active channel row rendered a
    # `.channel-row-scope-pill` "you are here" provenance marker next to the
    # channel name. That per-channel pill was redundant with the section
    # header's own org-scope cue and has been removed. These tests lock in the
    # removal AND prove the section header keeps a grouping cue.
    #
    # Task 019e467d then replaced the section-header *scope_pill* (whose visible
    # TEXT was derived from the color token, so a recolor looked like a rename)
    # with a color-ONLY dot. The grouping cue is retained as the dot; the text
    # identity is now exclusively `section.name`.

    test "active channel row does NOT render a per-channel scope-pill", %{conn: conn} do
      conn = authenticated_conn(conn)
      # Slug "paragon" is classified into the Paragon sub-org bucket and
      # becomes the active space — the surface that used to grow a pill.
      create_channel("paragon")

      {:ok, _view, html} = live_at(conn, ~p"/chat/paragon")
      sidebar = desktop_sidebar(html)

      refute sidebar =~ "channel-row-scope-pill",
             "Active channel row should no longer render the per-channel scope-pill wrapper"
    end

    test "the section-header color dot is retained (color-only, no text label)",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      # Removing the per-channel pill must NOT remove the section-header grouping
      # cue. Post-019e467d that cue is a COLOR-ONLY dot (`bg-<token>-dot`), not a
      # text-bearing scope pill — recoloring a section must change only its dot,
      # never any name/label. So the Paragon section header carries the
      # `bg-paragon-dot` swatch but NO "Paragon scope" pill text.
      create_channel("paragon")

      {:ok, _view, html} = live_at(conn, ~p"/chat/paragon")
      sidebar = desktop_sidebar(html)

      assert sidebar =~ "channel-section-color-dot",
             "Section header should render a color-only dot as the grouping cue"

      assert sidebar =~ "bg-paragon-dot",
             "Paragon section dot should carry the paragon color utility"

      # The old color-derived pill text is gone from the section header — the
      # dot is decorative (aria-hidden) and the only identity text is the name.
      refute sidebar =~ ~s(aria-label="Paragon scope"),
             "Section header must no longer render a text-bearing scope pill"
    end
  end

  describe "chat-header scope-pill" do
    test "header renders prominent scope-pill when a channel is active", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("soylent")

      {:ok, _view, html} = live_at(conn, ~p"/chat/soylent")

      # The `.chat-header-scope-pill` wrapper is the load-bearing CSS hook
      # for the prominent size variant.
      assert html =~ "chat-header-scope-pill",
             "Chat header should render the prominent scope-pill wrapper for an active channel"

      # And it's the clickable variant, not the static read-only one —
      # i.e. it carries the `phx-click="scope_filter"` button.
      assert html =~ ~s(phx-click="scope_filter")
    end

    test "header pill click pushes scope_filter event and narrows the sub-org rail", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("fabrikam")
      create_channel("paragon")
      create_channel("soylent")

      {:ok, view, _html} = live_at(conn, ~p"/chat/soylent")

      # Click the chat-header scope-pill — it pushes `scope_filter` with
      # the channel's scope ("soylent"). The active channel is Soylent,
      # so the filter narrows the rail to the Soylent bucket only.
      html_after =
        view
        |> element(
          ~s(.chat-header-scope-pill button[phx-click="scope_filter"][phx-value-scope="soylent"])
        )
        |> render_click()

      sidebar = desktop_sidebar(html_after)

      # Soylent bucket header is still present…
      assert sidebar =~ "Soylent"

      # …but Paragon and Fabrikam sub-org headers are filtered out.
      refute sidebar =~ ~r/<span[^>]*class="channel-section-label"[^>]*>\s*Paragon\s*</,
             "Paragon sub-org section should be hidden by the Soylent scope filter"

      refute sidebar =~ ~r/<span[^>]*class="channel-section-label"[^>]*>\s*Fabrikam\s*</,
             "Fabrikam sub-org section should be hidden by the Soylent scope filter"
    end

    test "header pill is not rendered when no channel is active (DM surface)", %{conn: conn} do
      conn = authenticated_conn(conn)
      # No channels at all — `/chat` lands on the empty state with
      # @active_space == nil, so neither the desktop header nor the
      # header-pill wrapper should render.
      {:ok, _view, html} = live(conn, ~p"/chat")

      refute html =~ "chat-header-scope-pill",
             "Chat-header scope-pill should NOT render when @active_space is nil"
    end
  end

  describe "mobile chat-header compact scope-pill (chat sidebar mobile Stage 2)" do
    test "mobile header renders the compact clickable scope-pill for an active channel",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("soylent")

      {:ok, _view, html} = live_at(conn, ~p"/chat/soylent")

      # The mobile header (lg:hidden) carries its OWN wrapper, distinct from the
      # desktop `.chat-header-scope-pill` so it can size the pill compact and
      # own the 44px tap-target CSS. Present in the DOM even though CSS hides it
      # above the lg breakpoint.
      assert html =~ "chat-header-scope-pill-mobile",
             "Mobile chat header should render the compact scope-pill wrapper for an active channel"

      # It's the compact + clickable variant — the component adds
      # `.scope-pill-hit-expand` only for `size={:compact} clickable={true}`,
      # and it pushes the same `scope_filter` event as the desktop pill.
      assert html =~ "scope-pill-hit-expand"
      assert html =~ ~s(phx-value-scope="soylent")
    end

    test "mobile header pill is suppressed on a DM/group surface (no org-scope)",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      # No channels — `/chat` lands with @active_space == nil, so the whole
      # header (and thus the mobile pill) is suppressed. `space_scope_atom/1`
      # also returns nil for DMs/groups, so the pill never renders there.
      {:ok, _view, html} = live(conn, ~p"/chat")

      refute html =~ "chat-header-scope-pill-mobile",
             "Mobile chat-header scope-pill should NOT render without an active channel"
    end
  end

  describe "scope_filter event toggle semantics" do
    test "clicking the same scope twice clears the filter", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("paragon")
      create_channel("soylent")

      {:ok, view, _} = live_at(conn, ~p"/chat/soylent")

      # First click → narrows to Soylent.
      html1 =
        view
        |> element(
          ~s(.chat-header-scope-pill button[phx-click="scope_filter"][phx-value-scope="soylent"])
        )
        |> render_click()

      sidebar1 = desktop_sidebar(html1)

      refute sidebar1 =~ ~r/<span[^>]*class="channel-section-label"[^>]*>\s*Paragon\s*</,
             "After first click, Paragon bucket should be hidden"

      # Second click on the same pill → clears the filter, both buckets
      # render again.
      html2 =
        view
        |> element(
          ~s(.chat-header-scope-pill button[phx-click="scope_filter"][phx-value-scope="soylent"])
        )
        |> render_click()

      sidebar2 = desktop_sidebar(html2)

      assert sidebar2 =~ ~r/<span[^>]*class="channel-section-label"[^>]*>\s*Paragon\s*</,
             "After second click on the same pill, Paragon bucket should re-appear"

      assert sidebar2 =~ ~r/<span[^>]*class="channel-section-label"[^>]*>\s*Soylent\s*</
    end
  end
end
