defmodule PlatformWeb.ChatLiveMaskMobileTest do
  @moduledoc """
  Render-level tests for screen-share name masking on the MOBILE surfaces
  (task 01a00c66 stage 3): the `#mobile-channel-browser` drawer, the drawer's
  search box, both chat-header scope pills, and the hidden-channels drawer's
  org groupings.

  ## Why this file exists at all

  The rail renders at two breakpoints and they have diverged before. Masking
  the desktop rail and leaving the drawer unmasked is the most likely way this
  whole feature ships broken — and it is invisible to every desktop test,
  because the drawer is a separate element with its own loop and its own
  derived strings.

  ## The absence assertions are three-form and case-insensitive

  `refute html =~ "Wayne-Tech"` PASSES while `data-section-slug="wayne-tech"` sits
  in the DOM in plain sight: org slugs are stored underscored (`wayne_tech`) and
  rendered hyphenated (`wayne-tech`), so a display-form absence assertion proves
  nothing about the attribute surface. `refute_name_anywhere/2` checks all
  three forms over the whole rendered blob, attributes included. It lives in
  `Platform.MaskAssertions` so the desktop file uses the same one — an
  assertion helper that exists in only one of two breakpoint files is how the
  two breakpoints diverge.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  # The org this file uses as the canary. Its display form, hyphen slug and
  # underscore slug are all DIFFERENT strings, which is exactly the property
  # that makes it able to catch the hole a single-form assertion leaves.
  @canary "Wayne-Tech"

  defp insert_chat_user do
    Repo.insert!(%User{
      email: "mask_mobile_test@example.com",
      name: "Mask Mobile Test User",
      oidc_sub: "oidc-mask-mobile-test",
      avatar_url: nil
    })
  end

  defp authenticated_conn(conn) do
    user = insert_chat_user()
    {init_test_session(conn, current_user_id: user.id), user}
  end

  # Stamps `org_id` so the channel files under the matching rail section AND
  # so the chat header resolves a scope for it (post-019fa0ac the header pill
  # reads the space's org, not its slug).
  defp create_channel(slug, name \\ nil) do
    org = Platform.Tenancy.get_org_by_slug(slug)

    {:ok, ch} =
      Chat.create_space(%{
        name: name || String.capitalize(slug),
        slug: slug,
        kind: "channel",
        org_id: org && org.id
      })

    ch
  end

  defp live_following_redirect(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  defp open_drawer(conn) do
    {:ok, view, _html} = live_following_redirect(conn)

    view
    |> element(~s(button[phx-click="toggle_mobile_browser"]))
    |> render_click()

    view
  end

  # `LazyHTML.query/2`, not a regex: the drawer is a `<div>` full of nested
  # `<div>`s, so any regex that "ends at the closing tag" actually runs to the
  # end of the document and drags the chat header and message list in with it.
  # A leak assertion over THAT slice is not an assertion about the drawer.
  defp drawer(html), do: extract(html, "#mobile-channel-browser")

  defp extract(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_html()
  end

  # The drawer carries its own toggle; target it inside the overlay so the
  # rail's identical control (same event, same value) can't answer instead.
  defp toggle_mask(view) do
    view
    |> element(~s(#mobile-channel-browser button[phx-click="toggle_mask_names"]))
    |> render_click()
  end

  defp search(view, query) do
    view
    |> element(~s(#mobile-channel-browser form[phx-change="drawer_search"]))
    |> render_change(%{"value" => query})
  end

  describe "the drawer masks like the rail" do
    test "the drawer carries the SAME eye control and the SAME strip", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("fabrikam")
      view = open_drawer(conn)

      before = view |> render() |> drawer()
      refute before =~ "channel-mask-strip"
      assert before =~ ~s(phx-click="toggle_mask_names")

      masked = view |> toggle_mask() |> drawer()

      # Not a reduced variant: the full strip, the same copy, the same
      # re-mask action the rail offers.
      assert masked =~ "channel-mask-strip"
      assert masked =~ "Names hidden for sharing"
      assert masked =~ "channel-mask-strip-action"
      assert masked =~ ~s(phx-click="remask_all")
      assert masked =~ ~s(aria-pressed="true")
    end

    test "section headers, their aria-labels and the slug attribute all mask together",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("fabrikam")
      view = open_drawer(conn)

      assert_name_anywhere(view |> render() |> drawer(), @canary)

      masked = view |> toggle_mask() |> drawer()

      assert masked =~ "Workspace A"
      assert masked =~ "Workspace B"
      refute masked =~ "Client A"

      # The strong form: the real name is gone from the drawer in every
      # spelling, attributes included.
      refute_name_anywhere(masked, @canary)
      refute_name_anywhere(masked, "Soylent")
      refute_name_anywhere(masked, "Paragon")
    end

    test "the per-item reveal is a real focusable control, not a hover treatment",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("fabrikam")
      view = open_drawer(conn)
      toggle_mask(view)

      # `@media (hover: hover)` never matches on a touch device, so a
      # hover-gated reveal would leave the drawer unable to reveal anything.
      assert has_element?(
               view,
               ~s(#mobile-channel-browser button[phx-click="reveal_section"][aria-label="Show this workspace name"])
             )
    end

    test "revealing one section in the drawer shows only that org", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("fabrikam")
      view = open_drawer(conn)
      masked = toggle_mask(view)

      [_, section_id] = Regex.run(~r/data-section-id="([^"]+)"/, drawer(masked))

      revealed =
        view
        |> element(
          ~s(#mobile-channel-browser button[phx-click="reveal_section"][phx-value-section_id="#{section_id}"])
        )
        |> render_click()
        |> drawer()

      assert revealed =~ "Names hidden · 1 showing"
      # Every other section keeps its placeholder.
      assert revealed =~ "Workspace B"
    end

    test "a channel named after its own org masks to the section placeholder",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("wayne_tech", @canary)
      view = open_drawer(conn)

      assert_name_anywhere(view |> render() |> drawer(), @canary)

      masked = view |> toggle_mask() |> drawer()

      # Masking the header and leaving `#wayne-tech` under it is the same leak
      # with an extra step.
      refute_name_anywhere(masked, @canary)
      assert masked =~ "workspace-"
    end
  end

  describe "drawer search must not become an oracle" do
    test "typing a real org name while masked surfaces nothing", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("wayne_tech", @canary)
      view = open_drawer(conn)

      # Unmasked, the search finds it — otherwise the masked assertion below
      # would pass on a search box that never worked.
      assert_name_anywhere(view |> search(@canary) |> drawer(), @canary)

      search(view, "")
      toggle_mask(view)

      masked = view |> search(@canary) |> drawer()

      # The assertion is about the LIST, not the whole drawer: the search
      # input's `value` and the "No matches for “…”" line both echo what the
      # user typed, and no mask can un-type a query. What must not happen is
      # a ROW surfacing — a match there confirms the client list to everyone
      # watching the share.
      refute_name_anywhere(extract(masked, "#mobile-channel-browser section"), @canary)

      refute has_element?(view, ~s(#mobile-channel-browser [data-role="drawer-row-wrap"])),
             "A masked row must not be reachable by the string it is hiding"

      # And the drawer says so rather than rendering a blank list — the
      # difference between "blank" and "No matches" is itself an oracle.
      assert masked =~ "No matches for"
    end

    test "searching the placeholder still finds the masked row", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("wayne_tech", @canary)
      view = open_drawer(conn)
      toggle_mask(view)

      masked = view |> search("workspace") |> drawer()

      refute masked =~ "No matches for"
      assert masked =~ "workspace-"
    end
  end

  describe "scope pills" do
    test "both the compact mobile pill and the prominent header pill mask text AND aria-label",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("wayne_tech")

      {:ok, view, html} = live(conn, ~p"/chat/wayne_tech")

      assert html =~ "chat-header-scope-pill"
      assert html =~ "chat-header-scope-pill-mobile"
      assert html =~ ~s(aria-label="Filter by #{@canary} scope")

      masked =
        view
        |> element(~s(button[phx-click="toggle_mask_names"]))
        |> render_click()

      # Both wrappers still render — masking changes the NAME, never whether
      # the affordance exists.
      assert masked =~ "chat-header-scope-pill"
      assert masked =~ "chat-header-scope-pill-mobile"

      # A masked pill whose screen-reader name still says the real org has not
      # been masked.
      assert masked =~ ~s(aria-label="Filter by Workspace)
      refute masked =~ ~s(aria-label="Filter by #{@canary} scope")

      # Scoped to the pill wrappers themselves — a `<header>`-shaped regex
      # matches the FIRST header in the document, which is a different element
      # entirely, and the assertion would pass without ever seeing a pill.
      for selector <- [".chat-header-scope-pill", ".chat-header-scope-pill-mobile"] do
        pill = extract(masked, selector)
        assert pill =~ "Workspace", "expected #{selector} to render a placeholder"
        refute_name_anywhere(pill, @canary)
      end
    end
  end

  describe "hidden-channels drawer groupings" do
    test "the org grouping heading masks", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      channel = create_channel("wayne_tech")
      create_channel("fabrikam")
      {:ok, _} = Platform.Accounts.hide_channel(user.id, channel.id)

      {:ok, view, html} = live_following_redirect(conn)

      assert html =~ "channel-hidden-drawer-group-label"
      assert_name_anywhere(html, @canary)

      masked =
        view
        |> element(~s(button[phx-click="toggle_mask_names"]))
        |> render_click()

      # The group heading is an ORG NAME, so it masks like every other one.
      assert masked =~ "channel-hidden-drawer-group-label"

      group = extract(masked, ".channel-hidden-drawer-group-label")

      assert group != "", "expected the hidden-drawer group label to render while masked"
      assert group =~ "Workspace"
      refute_name_anywhere(group, @canary)
    end
  end

  describe "a runtime-created org on a masked surface" do
    # Task 01a0938b stage 2. The fixture org's name has no separator, so
    # `MaskAssertions.forms/1` (which derives spellings only by swapping
    # `-`/`_` WITHIN the name) never produces its stored slug `new_client`.
    # The slug is therefore refuted as a name of its own below; one
    # `refute_name_anywhere(pill, "Newclient")` would pass on a pill that
    # still says `data-scope="new_client"`.
    @runtime_names ["Newclient", "new_client"]
    @runtime_pills [
      ".channel-hidden-drawer-group-label",
      ".chat-header-scope-pill",
      ".chat-header-scope-pill-mobile"
    ]

    # A Fabrikam member, so the viewer can see the runtime org (the shell's colour
    # rules are built from the orgs the viewer can see).
    defp runtime_org_conn(conn) do
      user = insert_chat_user()

      %Platform.Tenancy.OrgMembership{}
      |> Platform.Tenancy.OrgMembership.changeset(%{
        user_id: user.id,
        org_id: Platform.Tenancy.get_org_by_slug!("fabrikam").id,
        role: "member"
      })
      |> Repo.insert!()

      org =
        Repo.insert!(
          Platform.Tenancy.Org.changeset(%Platform.Tenancy.Org{}, %{
            name: "Newclient",
            slug: "new_client",
            parent_org_id: Platform.Tenancy.get_org_by_slug!("fabrikam").id,
            color_hue: 200
          })
        )

      [visible, hidden] =
        for slug <- ["client-general", "client-archive"] do
          {:ok, ch} =
            Chat.create_space(%{name: slug, slug: slug, kind: "channel", org_id: org.id})

          {:ok, _} =
            Chat.add_participant(ch.id, %{
              participant_type: "user",
              participant_id: user.id,
              joined_at: DateTime.utc_now()
            })

          ch
        end

      {:ok, _} = Platform.Accounts.hide_channel(user.id, hidden.id)
      {init_test_session(conn, current_user_id: user.id), visible}
    end

    test "the drawer group label and both header pills mask every spelling", %{conn: conn} do
      {conn, visible} = runtime_org_conn(conn)
      {:ok, view, html} = live(conn, ~p"/chat/#{visible.id}")

      # Anti-vacuity: unmasked, each pill really does spell the org both ways.
      # Without this, the refutations below pass on a pill that never rendered.
      for selector <- @runtime_pills, name <- @runtime_names do
        assert_name_anywhere(extract(html, selector), name)
      end

      masked =
        view
        |> element(~s(button[phx-click="toggle_mask_names"]))
        |> render_click()

      for selector <- @runtime_pills do
        pill = extract(masked, selector)
        assert pill =~ "Workspace", "expected #{selector} to render a placeholder"
        refute pill =~ "data-scope=", "#{selector} spells a data-scope while masked"

        for name <- @runtime_names do
          refute_name_anywhere(pill, name)
        end
      end
    end
  end

  describe "word discipline" do
    test "no padlock, no shield, and no privacy vocabulary on the mobile surfaces",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("fabrikam")
      view = open_drawer(conn)
      html = toggle_mask(view)

      for forbidden <- ~w(privacy Privacy secure Secure encrypted protected padlock) do
        refute html =~ forbidden,
               "Masking copy must be about presenting, not privacy — found #{forbidden}"
      end

      refute html =~ "hero-lock"
      refute html =~ "hero-shield"
      refute html =~ "client_"
    end
  end
end
