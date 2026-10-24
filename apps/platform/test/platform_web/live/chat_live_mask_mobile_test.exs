defmodule PlatformWeb.ChatLiveMaskMobileTest do
  @moduledoc """
  Render-level tests for screen-share name masking on the MOBILE surfaces
  (task 01a00c66 stage 3): both chat-header scope pills, the hidden-channels
  drawer's org groupings, and the copy of the phone Chat list.

  The phone's conversation drawer this file was written for was deleted in
  task 01a1557a-8562 stage 5. The phone list that replaced it carries its own
  mask tests in `chat_live_chat_list_test.exs` ("mask names", and the search
  sheet's "masked: no org-derived name and no snippet text ..."), which cover
  the list rows and the search oracle the drawer tests here used to.

  ## The absence assertions are three-form and case-insensitive

  `refute html =~ "Vandelay-Ind"` PASSES while `data-section-slug="vandelay-ind"` sits
  in the DOM in plain sight: org slugs are stored underscored (`vandelay_ind`) and
  rendered hyphenated (`vandelay-ind`), so a display-form absence assertion proves
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
  @canary "Vandelay-Ind"

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
      {:error, {:live_redirect, %{to: path}}} ->
        live(conn, path)

      # Since task 01a1557a-8562 stage 2, /chat is the phone Chat list and
      # does not redirect. Land in the first channel the way a desktop
      # viewport does: the ViewportBreakpoint hook's `below: false` report.
      {:ok, view, _html} ->
        render_hook(view, "chat_viewport", %{"below" => false})
        {:ok, view, render(view)}
    end
  end

  defp extract(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_html()
  end

  describe "scope pills" do
    # The compact MOBILE header pill was deleted in task 01a1557a-8a6d stage 3;
    # the phone's scope control is the space sheet's Scope row and its switch.
    # Its masking assertions moved there, with the same placeholder and the
    # same three-form refutation, rather than being dropped.
    test "the header pill and the sheet's Scope row and switch mask text AND aria-label",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("vandelay_ind")

      {:ok, view, html} = live(conn, ~p"/chat/vandelay_ind")

      assert html =~ "chat-header-scope-pill"
      refute html =~ "chat-header-scope-pill-mobile"
      assert html =~ ~s(aria-label="Filter by #{@canary} scope")

      {row, switch} = sheet_scope_nodes(view)
      assert_name_anywhere(row, @canary)
      assert_name_anywhere(switch, @canary)

      masked =
        view
        |> element(~s(button[phx-click="toggle_mask_names"]))
        |> render_click()

      # The header pill still renders — masking changes the NAME, never
      # whether the affordance exists.
      assert masked =~ "chat-header-scope-pill"

      # A masked pill whose screen-reader name still says the real org has not
      # been masked.
      assert masked =~ ~s(aria-label="Filter by Workspace)
      refute masked =~ ~s(aria-label="Filter by #{@canary} scope")

      # Scoped to the pill wrapper itself — a `<header>`-shaped regex matches
      # the FIRST header in the document, which is a different element
      # entirely, and the assertion would pass without ever seeing a pill.
      pill = extract(masked, ".chat-header-scope-pill")
      assert pill =~ "Workspace", "expected the header pill to render a placeholder"
      refute_name_anywhere(pill, @canary)

      {row, switch} = sheet_scope_nodes(view)

      for {node, name} <- [{row, "Scope row"}, {switch, "Scope switch"}] do
        assert node =~ "Workspace", "expected the #{name} to render a placeholder"
        refute_name_anywhere(node, @canary)
      end
    end
  end

  # The sheet's Scope row (Space page) and its switch (Scope page), read
  # through the title button and the row, as a person on a phone reaches them.
  defp sheet_scope_nodes(view) do
    view |> element(~s(button[data-role="space-title"])) |> render_click()
    # The title opens on the All segment; the Scope row is on Space.
    view |> element(~s(#space-sheet button[data-seg="space"])) |> render_click()
    row = view |> element(~s(#space-sheet button[data-role="space-sheet-scope"])) |> render()
    view |> element(~s(#space-sheet button[data-role="space-sheet-scope"])) |> render_click()
    switch = view |> element(~s(#space-sheet [data-page="scope"])) |> render()
    render_click(view, "close_space_sheet", %{})
    {row, switch}
  end

  describe "hidden-channels drawer groupings" do
    test "the org grouping heading masks", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      channel = create_channel("vandelay_ind")
      create_channel("acme")
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
    # The compact mobile header pill left in task 01a1557a-8a6d stage 3; its
    # place is the space sheet's Scope row and switch, asserted below.
    @runtime_pills [
      ".channel-hidden-drawer-group-label",
      ".chat-header-scope-pill"
    ]

    # An Acme member, so the viewer can see the runtime org (the shell's colour
    # rules are built from the orgs the viewer can see).
    defp runtime_org_conn(conn) do
      user = insert_chat_user()

      %Platform.Tenancy.OrgMembership{}
      |> Platform.Tenancy.OrgMembership.changeset(%{
        user_id: user.id,
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id,
        role: "member"
      })
      |> Repo.insert!()

      org =
        Repo.insert!(
          Platform.Tenancy.Org.changeset(%Platform.Tenancy.Org{}, %{
            name: "Newclient",
            slug: "new_client",
            parent_org_id: Platform.Tenancy.get_org_by_slug!("acme").id,
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

    test "the drawer group label, the header pill and the sheet's Scope row mask every spelling",
         %{conn: conn} do
      {conn, visible} = runtime_org_conn(conn)
      {:ok, view, html} = live(conn, ~p"/chat/#{visible.id}")

      # Anti-vacuity: unmasked, each pill really does spell the org both ways.
      # Without this, the refutations below pass on a pill that never rendered.
      for selector <- @runtime_pills, name <- @runtime_names do
        assert_name_anywhere(extract(html, selector), name)
      end

      # The sheet's row and switch carry the org NAME. Their slug is only in
      # `phx-value-scope`, the attribute the assertions name as the filter's
      # argument, so only the name is asserted present here.
      {row, switch} = sheet_scope_nodes(view)
      assert_name_anywhere(row, "Newclient")
      assert_name_anywhere(switch, "Newclient")

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

      {row, switch} = sheet_scope_nodes(view)

      for node <- [row, switch] do
        assert node =~ "Workspace"
        refute node =~ "data-scope="

        for name <- @runtime_names do
          refute_name_anywhere(node, name)
        end
      end
    end
  end

  describe "word discipline" do
    test "no padlock, no shield, and no privacy vocabulary on the mobile surfaces",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("acme")
      # /chat with no viewport report renders the phone Chat list.
      {:ok, view, _html} = live(conn, ~p"/chat")
      assert has_element?(view, "#chat-list")
      html = render_click(view, "toggle_mask_names", %{})

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
