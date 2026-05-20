defmodule PlatformWeb.ChatLiveScopePillsTest do
  @moduledoc """
  Render + event tests for the chat-rail and chat-header scope-pills
  (chat plan v2 Stage 4).

  Coverage:
    * Active channel row renders a `<.scope_pill>` with the channel's
      scope dot color.
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

  defp create_channel(slug) do
    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel"
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

  describe "active-row scope-pill" do
    test "active channel row in a sub-org section renders a scope-pill with the section's scope",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      # Slug "paragon" is classified into the Paragon sub-org bucket
      # (see ChatLive.channel_scope/1). Navigating to /chat/paragon
      # makes it the active space.
      create_channel("paragon")

      {:ok, _view, html} = live_at(conn, ~p"/chat/paragon")
      sidebar = desktop_sidebar(html)

      # The active-row pill is wrapped in `.channel-row-scope-pill` and
      # contains the static-variant scope-pill `<span>` whose
      # aria-label is "Paragon scope" (ScopePill.aria_label_static/1).
      assert sidebar =~ "channel-row-scope-pill",
             "Expected active-row scope-pill wrapper to render on the active channel"

      assert sidebar =~ ~s(aria-label="Paragon scope"),
             "Expected the active-row scope-pill to carry the Paragon scope label"
    end

    test "non-active channel rows do NOT render a scope-pill", %{conn: conn} do
      conn = authenticated_conn(conn)
      # Seed two channels — one active (general → Fabrikam bucket), one not
      # (paragon → Paragon bucket). The active-row pill should appear
      # on the general row only.
      create_channel("general")
      create_channel("paragon")

      {:ok, _view, html} = live_at(conn, ~p"/chat/general")
      sidebar = desktop_sidebar(html)

      # Only one `.channel-row-scope-pill` should be rendered (active row).
      pill_count =
        sidebar
        |> String.split("channel-row-scope-pill")
        |> length()
        |> Kernel.-(1)

      assert pill_count == 1,
             "Expected exactly one active-row scope-pill, got #{pill_count}"
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
      refute sidebar =~ ~r/<p[^>]*class="channel-section-label"[^>]*>Paragon</,
             "Paragon sub-org section should be hidden by the Soylent scope filter"

      refute sidebar =~ ~r/<p[^>]*class="channel-section-label"[^>]*>Fabrikam</,
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

      refute sidebar1 =~ ~r/<p[^>]*class="channel-section-label"[^>]*>Paragon</,
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

      assert sidebar2 =~ ~r/<p[^>]*class="channel-section-label"[^>]*>Paragon</,
             "After second click on the same pill, Paragon bucket should re-appear"

      assert sidebar2 =~ ~r/<p[^>]*class="channel-section-label"[^>]*>Soylent</
    end
  end
end
