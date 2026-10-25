defmodule PlatformWeb.ChatLiveMaskAbsenceTest do
  @moduledoc """
  The ABSENCE half of screen-share name masking (task 01a00c66 stage 4).

  ## Why a separate file from the stage-2 and stage-3 render tests

  Asserting that `Workspace B` appears proves almost nothing. A `display:none`
  real name renders `Workspace B` on screen while the real string sits in the
  page source, in the accessibility tree, and one devtools panel away from a
  shared screen. This file asserts the opposite direction: that the real name
  is NOWHERE in the document, attributes included.

  ## Every refute here is a matched pair

  A refute that has never been seen to fail is indistinguishable from a typo in
  the selector. So every absence test in this file has a twin — same fixture,
  same string, same surface, `mask_names?` off instead of on — that asserts the
  name IS present. If the mask is ever removed, the pair splits: the absence
  test goes red and the presence test stays green, and the failure names the
  surface that leaked.

  This was verified by hand during stage 4 rather than assumed: `SidebarMask.label/4`
  was temporarily neutered to return `section.name` unconditionally, and every
  absence test in this file failed on the `refute_name_anywhere/2` message. The
  neutering was then reverted and the file re-run green. A guard that has never
  been observed to fire proves nothing.

  ## Why the refutes run against the FULL rendered document

  Not a scoped `element/2` selection. The point is that the string is nowhere —
  a scoped assertion only proves the leak is not in the one node the author
  thought to look at, and the leaks this feature actually shipped (stage 2's
  `data-section-slug`) were in the nodes nobody scoped to.

  ## Fixture names

  The seeded root orgs (`priv/repo/migrations/20260519143620_seed_root_orgs.exs`)
  are Acme, Initech, Vandelay-Ind, Globex and Hooli. Those are the production-shaped
  strings, so they are what the assertions bite on. `Wonka` is not a seeded
  org on this branch and is not invented here — a fixture the app never renders
  would make every refute about it vacuously true.

  `Globex` was checked before being trusted: three uppercase letters can collide
  with unrelated markup, base64 or class fragments, and a refute failing for a
  reason unrelated to masking is a false RED that trains people to loosen the
  assertion. Rendered unmasked, `globex` occurs exactly 7 times and every one is a
  section-header surface (`data-section-key`, `data-section-slug`, the section
  `aria-label`, the collapse toggle, the visible label, the reorder handle).
  No collisions, so it stays.

  Burrow redesign 22 stage 2 deleted the desktop channel rail, which was the
  surface that spelled the seeded orgs (as section headers) on any page. The
  Chat list has no org headers, so the fixture now seeds one channel NAMED
  after each org in @orgs — the org-derived rule masks those rows — and every
  refute still runs against the full document beside its unmasked pair. The
  per-item reveal test went with the rail (nothing in chat reveals a section).
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  # Three seeded orgs whose display form, hyphen slug and underscore slug are
  # not all the same string — which is the property that makes a three-form
  # assertion able to catch what `refute html =~ "Vandelay-Ind"` sails past.
  @orgs ["Vandelay-Ind", "Globex", "Initech"]

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "mask_absence_#{suffix}@example.com",
      name: "Mask Absence #{suffix}",
      oidc_sub: "oidc-mask-absence-#{suffix}",
      avatar_url: nil
    })
  end

  defp authenticated_conn(conn, suffix) do
    init_test_session(conn, current_user_id: insert_user(suffix).id)
  end

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

  # `GET /chat` redirects to the first channel once one exists.
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

  # `general` is first so the desktop landing opens a channel named after
  # no org; one channel per org in @orgs is what carries the names into the
  # Chat list.
  defp seed_channels do
    create_channel("general")
    for name <- @orgs, do: create_channel(String.downcase(name), name)
  end

  defp mounted_view(conn) do
    seed_channels()
    {:ok, view, html} = live_following_redirect(conn)
    {view, html}
  end

  @mask_switch ~s(#chat-list-popover [data-role="chat-list-pop-option-mask"])

  # The Chat list's Options popover switch (the rail's eye went with the rail).
  defp toggle_mask(view) do
    unless has_element?(view, @mask_switch),
      do: view |> element("#list-more") |> render_click()

    view |> element(@mask_switch) |> render_click()
  end

  defp extract(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_html()
  end

  describe "absence — desktop Chat list" do
    test "no spelling of any seeded org name survives anywhere in the document",
         %{conn: conn} do
      {view, _html} = conn |> authenticated_conn("desktop") |> mounted_view()

      html = toggle_mask(view)

      for name <- @orgs, do: refute_name_anywhere(html, name)
    end

    test "MATCHED PAIR: the same names ARE present in the same document unmasked",
         %{conn: conn} do
      {_view, html} = conn |> authenticated_conn("desktop-pair") |> mounted_view()

      # No toggle: `mask_names?` is false on mount. Same fixture, same
      # document, opposite expectation — this is what makes the refute above
      # an assertion about masking rather than about an empty rail.
      for name <- @orgs, do: assert_name_anywhere(html, name)
    end
  end

  # The phone's masked surface is the Chat list since task 01a1557a-8562
  # (the drawer this file used to open was deleted): its absence pair is
  # chat_live_chat_list_test.exs "masked: no org-derived name and no excerpt
  # text anywhere in #chat-list".

  # Burrow redesign 22 stage 2 deleted the desktop channel rail; the
  # "per-item reveal leaks exactly one name" test went with its reveal control.

  describe "masking is view state and never crosses sessions" do
    test "a second user's live session still shows the real names", %{conn: conn} do
      seed_channels()

      first = conn |> authenticated_conn("session-one") |> live_following_redirect()
      {:ok, first_view, _} = first

      second =
        Phoenix.ConnTest.build_conn()
        |> authenticated_conn("session-two")
        |> live_following_redirect()

      {:ok, second_view, second_html} = second

      for name <- @orgs, do: assert_name_anywhere(second_html, name)

      masked = toggle_mask(first_view)
      for name <- @orgs, do: refute_name_anywhere(masked, name)

      # The other session is untouched: no PubSub broadcast, no row written,
      # so a re-render of the second view still carries the real names.
      still = render(second_view)
      for name <- @orgs, do: assert_name_anywhere(still, name)
    end
  end

  describe "word discipline" do
    test "no user-facing string in this feature contains \"client\"", %{conn: conn} do
      {view, _html} = conn |> authenticated_conn("words") |> mounted_view()

      html = toggle_mask(view)

      # Scoped to THIS feature's surfaces. A document-wide refute would trip
      # on `id="meeting-client"` and LiveView's own upload `entry.client_name`,
      # neither of which is this feature and neither of which this stage may
      # rename. The rail's strip, eye and reveal controls are gone; the
      # surviving surfaces are the popover's mask switch, the list's counts
      # line and the masked rows.
      surfaces =
        [
          ~s([data-role="chat-list-pop-option-mask"]),
          ~s(#chat-list [data-role="chat-list-counts"]),
          "#chat-list-scroller"
        ]
        |> Enum.map_join(" ", &extract(html, &1))

      assert surfaces =~ "Mask names",
             "expected the mask switch's label in the scoped surfaces"

      assert surfaces =~ "names masked"
      assert surfaces =~ ~r/workspace-[a-z]+/

      refute String.downcase(surfaces) =~ "client",
             """
             The word `client` is forbidden in this feature's user-facing
             surface. `Client A` leaks the category and the count, and an
             aria-label carrying it puts the word in the accessibility tree —
             which is read aloud on the very share the mode exists for.
             """
    end
  end
end
