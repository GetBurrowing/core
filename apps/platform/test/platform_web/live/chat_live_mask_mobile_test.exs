defmodule PlatformWeb.ChatLiveMaskMobileTest do
  @moduledoc """
  Render-level tests for screen-share name masking on the MOBILE surfaces
  (task 01a00c66 stage 3): the chat-header scope pill and the space sheet's
  Scope row, the hidden-channels list (now in the Chat list's Options popover;
  Burrow redesign 22 stage 2 deleted the desktop channel rail and its drawer),
  and the copy of the phone Chat list.

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
      avatar_url: nil,
      preferences: %{"first_run_goal" => "existing"}
    })
  end

  defp authenticated_conn(conn) do
    user = insert_chat_user()
    {init_test_session(conn, current_user_id: user.id), user}
  end

  # Stamps `org_id` so the channel resolves a scope for it (post-019fa0ac
  # the Scope rows read the space's org, not its slug).
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

  # Burrow redesign 22 stage 2 deleted the desktop channel rail and its eye
  # button, which these tests used to click; the event is what survives.
  defp mask_on(view) do
    render_click(view, "toggle_mask_names", %{"masked" => "true"})
  end

  describe "scope pills" do
    # The compact MOBILE header pill was deleted in task 01a1557a-8a6d stage 3;
    # the phone's scope control is the space sheet's Scope row and its switch.
    # Its masking assertions moved there, with the same placeholder and the
    # same three-form refutation, rather than being dropped.
    # Burrow redesign 22 stage 4 deleted the desktop header pill too; the
    # desktop control is the details panel's Scope row and switch, asserted
    # the same way.
    test "the panel's and the sheet's Scope rows and switches mask their text",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("vandelay_ind")

      {:ok, view, html} = live(conn, ~p"/chat/vandelay_ind")

      refute html =~ "chat-header-scope-pill"

      nodes = fn ->
        Tuple.to_list(sheet_scope_nodes(view)) ++ Tuple.to_list(panel_scope_nodes(view))
      end

      for node <- nodes.(), do: assert_name_anywhere(node, @canary)

      mask_on(view)

      for {node, name} <-
            Enum.zip(nodes.(), [
              "sheet Scope row",
              "sheet switch",
              "panel Scope row",
              "panel switch"
            ]) do
        # Masking changes the NAME, never whether the affordance exists.
        assert node =~ "Workspace", "expected the #{name} to render a placeholder"
        refute_name_anywhere(node, @canary)
      end
    end
  end

  # The details panel's Scope row (Space segment) and switch (Scope page).
  defp panel_scope_nodes(view) do
    render_click(view, "details_open", %{"page" => "space"})
    row = view |> element(~s(#details-panel button[data-role="details-scope"])) |> render()
    render_click(view, "details_open", %{"page" => "scope"})
    switch = view |> element(~s(#details-panel [data-page="scope"])) |> render()
    render_click(view, "details_close", %{})
    {row, switch}
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

  # Burrow redesign 22 stage 2 deleted the desktop channel rail and the
  # hidden-channels drawer at its foot (with its org grouping headings). The
  # hidden list now lives in the Chat list's Options popover, flat, one row
  # per hidden channel; an org-named hidden channel must mask there.
  describe "hidden channels in the Options popover" do
    defp open_hidden(view) do
      unless has_element?(view, "#chat-list-popover"),
        do: view |> element("#list-more") |> render_click()

      unless has_element?(view, "#chat-list-pop-hidden"),
        do:
          view
          |> element(~s(#chat-list-popover [data-role="chat-list-pop-option-hidden"]))
          |> render_click()

      view |> element("#chat-list-pop-hidden") |> render()
    end

    test "an org-named hidden channel's row and unhide label mask", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      channel = create_channel("vandelay_ind", @canary)
      create_channel("acme")
      {:ok, _} = Platform.Accounts.hide_channel(user.id, channel.id)

      {:ok, view, _html} = live_following_redirect(conn)

      row =
        ~s(#chat-list-pop-hidden [data-role="chat-list-pop-hidden-row"][data-space-id="#{channel.id}"])

      unmasked = open_hidden(view)
      assert has_element?(view, row)
      assert_name_anywhere(unmasked, @canary)

      mask_on(view)
      masked = open_hidden(view)

      assert has_element?(view, row),
             "expected the hidden row to render while masked, or the refute is vacuous"

      assert masked =~ ~r/workspace-[a-z]+/i
      refute_name_anywhere(masked, @canary)
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
    # The compact mobile header pill left in task 01a1557a-8a6d stage 3 and
    # the desktop one in Burrow redesign 22 stage 4; their places are the
    # space sheet's and the details panel's Scope rows and switches. The
    # hidden-channels drawer's group label left with the desktop rail
    # (Burrow redesign 22 stage 2).

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

    test "the sheet's and the panel's Scope rows mask every spelling",
         %{conn: conn} do
      {conn, visible} = runtime_org_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/#{visible.id}")

      # The rows and switches carry the org NAME. Their slug is only in
      # `phx-value-scope`, the attribute the assertions name as the filter's
      # argument, so only the name is asserted present here. Anti-vacuity:
      # without this the refutations below pass on nodes that never rendered.
      nodes = fn ->
        Tuple.to_list(sheet_scope_nodes(view)) ++ Tuple.to_list(panel_scope_nodes(view))
      end

      for node <- nodes.(), do: assert_name_anywhere(node, "Newclient")

      mask_on(view)

      for node <- nodes.() do
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
