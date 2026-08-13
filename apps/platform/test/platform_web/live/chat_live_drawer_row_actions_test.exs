defmodule PlatformWeb.ChatLiveDrawerRowActionsTest do
  @moduledoc """
  The row-actions sheet in the mobile Conversations drawer (task 019fe998).

  Pin, unpin and hide were all revealed on wrapper hover or `focus-within`.
  Tailwind gates `hover:` behind `@media (hover: hover)`, so on a phone none
  of the three could ever fire. This is the touch path: one always-visible
  overflow control per drawer row, opening the shared bottom sheet.

  Anti-vacuity notes, because a sheet wired to nothing passes every
  markup-only assertion:

    * Every assertion is scoped to ONE element via a CSS selector and
      `render/1` on that element. A whole-page `=~` is not a presence check —
      the conversation's name appears in the row, in the desktop rail, and in
      the page title, so `html =~ "Rowan Ellis"` is green before this
      feature exists.
    * The two load-bearing tests read PERSISTED state back
      (`Sidebar.list_pinned_space_ids/1`, `Accounts.get_hidden_channel_ids/1`)
      rather than asserting on re-rendered markup. Markup can be right while
      the button posts nothing.
    * Fixtures assert their own data exists before anything downstream leans
      on it. An empty drawer makes every row assertion vacuous.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "drawer-row-actions-#{suffix}@example.com",
      name: "Drawer Row Actions #{suffix}",
      oidc_sub: "oidc-drawer-row-actions-#{suffix}",
      avatar_url: nil
    })
  end

  defp authed(conn) do
    user = insert_user(System.unique_integer([:positive]))
    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp fabrikam_org, do: Tenancy.get_org_by_slug!("fabrikam")

  defp create_channel(slug) do
    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel",
        org_id: fabrikam_org().id
      })

    ch
  end

  # A DM reaches the rail only through `Chat.list_user_conversations/2`, which
  # joins participants, so the viewer must actually be in it. The OTHER
  # participant's `display_name` is what `sidebar_display_name/2` resolves,
  # and therefore what both the control's accessible name and the sheet
  # header must carry. A DM has no `name` field: that is the whole point of
  # asserting these on a DM rather than a channel.
  defp create_dm(user, other_name) do
    {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true})

    {:ok, _} =
      Chat.add_participant(dm.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, _} =
      Chat.add_participant(dm.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: other_name,
        joined_at: DateTime.utc_now()
      })

    dm
  end

  # `GET /chat` live-redirects to the first channel once one exists; follow it.
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

  # ── Selectors ───────────────────────────────────────────────────────────
  #
  # The overflow control is scoped INSIDE `#mobile-channel-browser` so a
  # desktop-rail control can never satisfy a drawer assertion — the two
  # surfaces share one DOM and are separated by CSS, not by presence.

  defp control_selector(space_id) do
    ~s(#mobile-channel-browser [data-role="drawer-row-actions"][data-space-id="#{space_id}"])
  end

  @sheet "#chat-row-actions-sheet"
  @sheet_title "#chat-row-actions-sheet .sheet-title"
  @sheet_pin ~s(#chat-row-actions-sheet [data-role="row-actions-pin"])
  @sheet_hide ~s(#chat-row-actions-sheet [data-role="row-actions-hide"])

  defp open_sheet(view, space_id) do
    view |> element(control_selector(space_id)) |> render_click()
    view
  end

  # ── HTML helpers ────────────────────────────────────────────────────────

  # One element's own markup. Not a page grep: `element/2` resolves a single
  # node and `render/1` returns just that node's HTML.
  defp markup(view, selector), do: view |> element(selector) |> render()

  defp attr(html, name) do
    case Regex.run(~r/#{Regex.escape(name)}="([^"]*)"/, html) do
      [_, value] -> value
      _ -> nil
    end
  end

  # A slice's whole visible text, HEEx comments stripped FIRST. A scoped
  # assertion has matched an explanatory comment before; comments are not
  # rendered content. Asserting the WHOLE text catches a stray glyph and an
  # empty label in the same line, which `=~ "name"` does not.
  defp visible_text(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<[^>]*>/s, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # ── 1. The control renders on both kinds of row, normal mode ────────────

  describe "the overflow control" do
    test "renders on a channel row and on a DM row in normal mode", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      dm = create_dm(user, "Rowan Ellis")

      view = open_drawer(conn)

      # The fixture actually reached the drawer. Without this, both
      # assertions below could be passing over an empty list.
      assert has_element?(view, "#mobile-channel-browser", "Gen-migration"),
             "the channel never rendered in the drawer; every row assertion below would be vacuous"

      assert has_element?(view, "#mobile-channel-browser", "Rowan Ellis"),
             "the DM never rendered in the drawer; every row assertion below would be vacuous"

      assert has_element?(view, control_selector(channel.id)),
             "no row-actions control on the drawer's channel row: pinning is still unreachable on touch"

      assert has_element?(view, control_selector(dm.id)),
             "no row-actions control on the drawer's DM row: the control shipped for channels only"
    end

    test "is a 44x44 touch target", %{conn: conn} do
      # The floor the design sets. A 24px glyph is the desktop control, and
      # porting it unchanged is the failure mode this guards.
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      view = open_drawer(conn)
      class = view |> markup(control_selector(channel.id)) |> attr("class")

      assert class =~ "min-h-11", "control class #{inspect(class)} sets no 44px minimum height"
      assert class =~ "min-w-11", "control class #{inspect(class)} sets no 44px minimum width"
    end

    test "keeps a right gutter, so the focus ring is not clipped by the screen edge",
         %{conn: conn} do
      # Measured before this was added: the control's border box ended on
      # x=375 of a 375px viewport, and `focus-visible:ring-2` paints 2px
      # OUTSIDE the border box, so the keyboard focus ring was cut off. Every
      # other element in the drawer sits on a 16px gutter, and the drawer's
      # existing row control (the pinned-task unpin button) uses mr-2.
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      view = open_drawer(conn)
      class = view |> markup(control_selector(channel.id)) |> attr("class")

      assert class =~ "mr-2",
             "control class #{inspect(class)} has no right gutter; the focus ring clips on the screen edge"
    end

    test "is always visible: no hover or focus-within reveal", %{conn: conn} do
      # The entire defect. `opacity-0` plus a `hover:`/`focus-within:` reveal
      # is precisely what a phone cannot trigger.
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      view = open_drawer(conn)
      class = view |> markup(control_selector(channel.id)) |> attr("class")

      refute class =~ "opacity-0",
             "the drawer control is hidden at rest (#{inspect(class)}); touch has no hover to reveal it"

      refute class =~ "group-hover",
             "the drawer control is gated behind hover (#{inspect(class)}); Tailwind gates hover: behind @media (hover: hover)"
    end
  end

  # ── 2. The accessible name carries the conversation's name ──────────────

  describe "the control's accessible name" do
    test "names the DM's person, not a bare More", %{conn: conn} do
      # Asserted on a DM deliberately: a DM has no `name` field and renders
      # empty if the implementation reaches for `space.name`. That bug has
      # already shipped twice on these surfaces.
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")

      view = open_drawer(conn)
      label = view |> markup(control_selector(dm.id)) |> attr("aria-label")

      assert label == "More actions for Rowan Ellis",
             "accessible name #{inspect(label)} does not name the conversation; twenty identical More controls are indistinguishable"
    end

    test "names the channel", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      view = open_drawer(conn)
      label = view |> markup(control_selector(channel.id)) |> attr("aria-label")

      assert label == "More actions for Gen-migration",
             "accessible name #{inspect(label)} does not name the channel"
    end
  end

  # ── 3. The sheet header names the conversation ──────────────────────────

  describe "the sheet header" do
    test "shows the DM's person", %{conn: conn} do
      # The sheet covers the row that identifies the subject. Without the name
      # in the header there is a menu on screen naming nothing.
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")

      view = conn |> open_drawer() |> open_sheet(dm.id)
      title = view |> markup(@sheet_title) |> visible_text()

      assert title == "Rowan Ellis",
             "sheet header reads #{inspect(title)}; a DM has no name field and this is where it renders empty"
    end

    test "shows the channel's name", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      view = conn |> open_drawer() |> open_sheet(channel.id)
      title = view |> markup(@sheet_title) |> visible_text()

      assert title == "Gen-migration", "sheet header reads #{inspect(title)}"
    end

    test "is empty while the sheet is closed", %{conn: conn} do
      # The sheet is DOM-present and CSS-hidden (the .sheet contract). If the
      # header kept a name while closed, the "shows the name" tests above
      # would pass without the control ever having been activated.
      {conn, _user} = authed(conn)
      create_channel("gen-migration")

      view = open_drawer(conn)

      assert view |> markup(@sheet_title) |> visible_text() == "",
             "the closed sheet already carries a title; the header tests prove nothing"

      refute view |> markup(@sheet) |> attr("class") =~ "sheet-open",
             "the sheet renders open before anything was tapped"
    end
  end

  # ── 4. The pin action's verb follows the row's state ────────────────────

  describe "the pin action" do
    test "reads Pin on an unpinned conversation", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      view = conn |> open_drawer() |> open_sheet(channel.id)

      assert view |> markup(@sheet_pin) |> visible_text() == "Pin conversation"
    end

    test "reads Unpin on a pinned conversation", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      # The pin actually persisted, so the row below really is a pinned row.
      assert Sidebar.list_pinned_space_ids(user.id) == [channel.id]

      view = conn |> open_drawer() |> open_sheet(channel.id)

      assert view |> markup(@sheet_pin) |> visible_text() == "Unpin conversation"
    end

    test "posts the DESIRED next state, so a double-fire is idempotent", %{conn: conn} do
      # `toggle_pinned` takes the next state rather than flipping what it
      # finds. A control that posted a bare toggle would silently unpin on a
      # duplicated event from a render race.
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      view = conn |> open_drawer() |> open_sheet(channel.id)
      pin = view |> markup(@sheet_pin)

      assert attr(pin, "phx-value-pinned") == "true"
      assert attr(pin, "phx-value-space_id") == channel.id
    end
  end

  # ── 5. Activating Pin persists the pin (load-bearing) ───────────────────

  describe "activating Pin" do
    test "persists the pin, read back from storage", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")

      assert Sidebar.list_pinned_space_ids(user.id) == [],
             "the user starts pinned-clean, or the assertion below proves nothing"

      view = conn |> open_drawer() |> open_sheet(channel.id)
      view |> element(@sheet_pin) |> render_click()

      assert Sidebar.list_pinned_space_ids(user.id) == [channel.id],
             "the sheet's Pin action is wired to nothing: the pin never reached storage"
    end

    test "persists a DM pin too", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")

      view = conn |> open_drawer() |> open_sheet(dm.id)
      view |> element(@sheet_pin) |> render_click()

      assert Sidebar.list_pinned_space_ids(user.id) == [dm.id],
             "pinning is kind-agnostic; the DM pin never reached storage"
    end

    test "unpins a pinned conversation", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      view = conn |> open_drawer() |> open_sheet(channel.id)
      view |> element(@sheet_pin) |> render_click()

      assert Sidebar.list_pinned_space_ids(user.id) == [],
             "the Unpin verb rendered but the action did not unpin"
    end

    test "closes the sheet, so the menu never outlives the row state", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      view = conn |> open_drawer() |> open_sheet(channel.id)

      assert view |> markup(@sheet) |> attr("class") =~ "sheet-open",
             "the sheet did not open, so the close assertion below is vacuous"

      view |> element(@sheet_pin) |> render_click()

      refute view |> markup(@sheet) |> attr("class") =~ "sheet-open",
             "the sheet stayed open after acting"
    end
  end

  # ── 6. Activating Hide hides the channel (load-bearing) ─────────────────

  describe "activating Hide" do
    test "hides the channel, read back from storage", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      create_channel("stays-put")

      # A MapSet, not a list — `Accounts.get_hidden_channel_ids/1` wraps and
      # dedupes the stored preference.
      assert Accounts.get_hidden_channel_ids(user.id) == MapSet.new(),
             "the user starts with nothing hidden, or the assertion below proves nothing"

      view = conn |> open_drawer() |> open_sheet(channel.id)
      view |> element(@sheet_hide) |> render_click()

      assert channel.id in Accounts.get_hidden_channel_ids(user.id),
             "the sheet's Hide action is wired to nothing: the hide never reached storage"
    end

    test "drops the row from the drawer and leaves its neighbour alone", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")
      create_channel("stays-put")

      view = conn |> open_drawer() |> open_sheet(channel.id)

      # Positive control: a subtractive assertion is worthless without proof
      # that both rows were there to begin with.
      assert has_element?(view, control_selector(channel.id))
      assert has_element?(view, "#mobile-channel-browser", "Stays-put")

      view |> element(@sheet_hide) |> render_click()

      refute has_element?(view, control_selector(channel.id)),
             "the hidden row is still in the drawer"

      assert has_element?(view, "#mobile-channel-browser", "Stays-put"),
             "hiding one channel took its neighbour with it"
    end
  end

  # ── 7. The sheet is mobile-only ─────────────────────────────────────────

  describe "breakpoint" do
    test "the sheet root is gated to below lg", %{conn: conn} do
      # Marlowe reported the bottom-sheet component rendering on desktop at all
      # widths on 2026-07-12; the design system scopes sheets to mobile. This
      # is the DOM-observable half of that rule — the rendered geometry is
      # covered by the screenshot evidence, not by this test.
      {conn, _user} = authed(conn)
      create_channel("gen-migration")

      view = open_drawer(conn)
      class = view |> markup(@sheet) |> attr("class")

      assert class =~ "sheet",
             "selector did not resolve the sheet root; class was #{inspect(class)}"

      assert class =~ "lg:hidden",
             "the row-actions sheet renders at every width (#{inspect(class)}); sheets are mobile-only"
    end
  end
end
