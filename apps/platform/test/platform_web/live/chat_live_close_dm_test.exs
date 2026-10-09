defmodule PlatformWeb.ChatLiveCloseDmTest do
  @moduledoc """
  The DM "Close" action (task 019ffc5f stage 2).

  Close takes one DM row off the rail. It is not Hide: nothing is
  unsubscribed, no drawer lists it, and the row returns on its own when a new
  message lands in it or when the user opens that conversation again. Those
  two returns are the whole reason Close ships without an undo surface, so
  every test that proves a row disappeared proves the matching return IN THE
  SAME TEST.

  Closing a PINNED DM unpins it too, so that row leaves the rail on the same
  click (section 2b, added when Marlowe reported that it did not). The pin is
  discarded rather than remembered, so the DM returns unpinned.

  ## Anti-vacuity notes

    * A test that only asserts "the row is gone" passes just as well for a
      rail that dropped DMs entirely, or for a filter that closed every DM in
      the list. Each close assertion below is therefore paired with (a) a
      SECOND DM that must stay, and (b) the return that brings the closed one
      back. The return half was run before the implementation existed and
      failed, which is what makes it a guard rather than decoration.

    * "The row is gone" is anchored on the row wrapper's own `data-space-id`
      INSIDE the Direct Messages section, and for a pinned DM across the whole
      rail (`rail_row/2`), because the bug there was a row that survived in
      the OTHER section. It is deliberately NOT anchored on the absence of a
      menu item: `row_actions_dialog/1` renders at the template root and holds
      ONE row's items at a time, so "no Close button on the page" is true for
      every row in the rail and proves nothing.

    * Both chromes are in the DOM at every width (the sheet is `lg:hidden`,
      the dialog `hidden lg:contents`), so the two Close items carry
      DIFFERENT `data-role`s and every selector below names one of them
      exactly. `rail-row-actions-close` is the dialog's;
      `row-actions-close-dm` is the sheet's. Note that plain
      `row-actions-close` was already taken by the dialog's dismiss button
      before this stage, which is why the sheet's item is suffixed.

    * The dialog is sliced with `LazyHTML.query/2`. `filter/2` keeps ROOT
      nodes and returns nothing when handed a whole rendered page.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "close-dm-#{n}@example.com",
      name: "Close DM #{n}",
      oidc_sub: "oidc-close-dm-#{n}",
      avatar_url: nil
    })
  end

  defp authed(conn) do
    user = insert_user()
    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp acme_org, do: Tenancy.get_org_by_slug!("acme")

  defp create_channel(slug) do
    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel",
        org_id: acme_org().id
      })

    ch
  end

  # A DM reaches the rail only through `Chat.list_user_conversations/2`, which
  # joins participants, so the viewer must actually be in it. That query is
  # also the only read path that populates `Space.last_activity_at`, which is
  # the value the close rule compares against — a DM fetched any other way is
  # permanently visible, and a test that seeded one would prove nothing.
  defp create_conversation(user, kind, other_name) do
    {:ok, space} = Chat.create_space(%{kind: kind, is_direct: kind == "dm"})

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: other_name,
        joined_at: DateTime.utc_now()
      })

    space
  end

  defp create_dm(user, other_name), do: create_conversation(user, "dm", other_name)

  # Inserted straight through `Repo` so `inserted_at` is exact. The close rule
  # is a timestamp comparison, so "roughly now" from the schema's autogenerate
  # would make the return half of every test a race.
  defp post_message!(space, at) do
    participant = space.id |> Chat.list_participants() |> hd()

    Repo.insert!(%Message{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: "still here",
      inserted_at: at
    })
  end

  # A message from the OTHER person in the DM, so the viewer's own participant
  # id is never the author. `{:new_message, msg}` takes a different branch for
  # a message the viewer sent, and that branch is not the one under test.
  # Same `Repo` insert as `post_message!/2` and for the same reason: the close
  # rule is a timestamp comparison, so `inserted_at` has to be exact.
  defp message_from_other!(space, user, at) do
    participant =
      space.id
      |> Chat.list_participants()
      |> Enum.find(fn p -> p.participant_id != user.id end)

    Repo.insert!(%Message{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: "you there?",
      inserted_at: at
    })
  end

  # One DM's `last_activity_at` as the LiveView currently holds it. Read off
  # the assign because the rail renders no timestamp, so the difference
  # between "recomputed again" and "left alone" is invisible in the HTML.
  defp dm_last_activity(view, space_id) do
    view.pid
    |> :sys.get_state()
    |> get_in([Access.key(:socket), Access.key(:assigns), :dm_conversations])
    |> Enum.find(&(&1.id == space_id))
    |> Map.fetch!(:last_activity_at)
  end

  defp live_rail(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  # ── HTML slicing ────────────────────────────────────────────────────────

  defp desktop_sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  defp section_by(sidebar, attr) do
    case Regex.run(~r/<section[^>]*#{Regex.escape(attr)}.*?<\/section>/s, sidebar) do
      [match] -> match
      _ -> nil
    end
  end

  defp dm_section(html), do: html |> desktop_sidebar() |> section_by(~s(data-section-key="dms"))

  defp pinned_block(html),
    do: html |> desktop_sidebar() |> section_by(~s(data-section-key="pinned"))

  # The row wrapper for one space. Matched on its own `data-space-id` so a row
  # in another section can never satisfy the assertion.
  defp row_wrap(nil, _space_id), do: nil

  defp row_wrap(slice, space_id) do
    case Regex.run(
           ~r/<div[^>]*data-space-id="#{Regex.escape(space_id)}"[^>]*>.*?<\/div>/s,
           slice
         ) do
      [match] -> match
      _ -> nil
    end
  end

  defp dm_row(html, space_id), do: html |> dm_section() |> row_wrap(space_id)

  # The row for one space ANYWHERE in the desktop rail, not in one named
  # section. "Off the rail" has to be asserted this way for a pinned DM: the
  # bug being guarded was a row that survived in the OTHER section, so a
  # section-scoped refute is exactly the assertion that missed it.
  #
  # Only row WRAPPERS can match: `row_wrap/2` looks for a `<div>`, and the
  # only other `data-space-id` inside `<aside id="chat-sidebar">` is on the
  # `<button>` that opens a row's menu. Both row-actions chromes render at the
  # template root, outside the aside entirely.
  defp rail_row(html, space_id), do: html |> desktop_sidebar() |> row_wrap(space_id)

  # `query/2`, not `filter/2`: filter keeps ROOT nodes, and the roots of a
  # rendered page are `<html>` and friends.
  defp slice(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_html()
  end

  defp menu(html), do: slice(html, ~s([data-role="row-actions-dialog"]))
  defp sheet(html), do: slice(html, "#chat-row-actions-sheet")

  # The rail's undo toast. Hide is the only verb that raises it: the close
  # variant was rejected at the stage-3 gate and removed. Scoped to
  # `#chat-sidebar` so the count stays honest if a second instance is ever
  # added elsewhere on the page.
  defp rail_toast(html), do: slice(html, "#chat-sidebar .channel-undo-toast")

  # Raw, un-normalised slice of the rail's toast. `slice/2` round-trips through
  # LazyHTML, which is exactly what a byte-identity assertion must not do.
  defp rail_toast_raw(html) do
    case Regex.run(
           ~r/<div[^>]*class="channel-undo-toast"[^>]*>.*?<\/div>/s,
           desktop_sidebar(html)
         ) do
      [match] -> match
      _ -> nil
    end
  end

  defp count(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end

  defp open_menu(view, space_id) do
    render_click(view, "open_row_actions", %{"space_id" => space_id})
  end

  defp button_by_role(nil, _role), do: nil

  defp button_by_role(slice, role) do
    case Regex.run(~r/<button[^>]*data-role="#{Regex.escape(role)}".*?<\/button>/s, slice) do
      [match] -> match
      _ -> nil
    end
  end

  defp item_roles(slice) do
    ~r/<button[^>]*data-role="([^"]+)"/s
    |> Regex.scan(slice || "")
    |> Enum.map(fn [_full, role] -> role end)
  end

  defp attr(nil, _name), do: ""

  defp attr(html, name) do
    case Regex.run(~r/#{Regex.escape(name)}="([^"]*)"/, html) do
      [_, value] -> value
      _ -> nil
    end
  end

  # The `<li>` that wraps one menu item, so the hairline above Close can be
  # asserted. The hairline lives on the list item, not on the button.
  defp item_wrapper_class(slice, role) do
    case Regex.run(
           ~r/<li([^>]*)>\s*<button[^>]*data-role="#{Regex.escape(role)}"/s,
           slice || ""
         ) do
      [_full, attrs] -> attr(attrs, "class")
      _ -> nil
    end
  end

  # The unread badge inside one row slice. Its own element, so a row whose
  # NAME happens to contain the digit cannot satisfy the assertion.
  defp unread_pill(nil), do: nil

  defp unread_pill(row) do
    case Regex.run(~r/<span class="channel-row-unread-pill">(.*?)<\/span>/s, row) do
      [_, inner] -> String.trim(inner)
      _ -> nil
    end
  end

  defp visible_text(nil), do: nil

  defp visible_text(html) do
    html
    |> String.replace(~r/<[^>]*>/s, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # ── 1. Close, and the two ways the row comes back ───────────────────────

  describe "closing a DM and its return" do
    test "the row leaves the rail and a NEWER message in that DM brings it back",
         %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("gen-migration")
      closed = create_dm(user, "Rowan Ellis")
      kept = create_dm(user, "Saru Watanabe")

      {:ok, view, html} = live_rail(conn)

      # Positive control. Without it every assertion below passes for a rail
      # that renders no DM rows at all.
      assert dm_row(html, closed.id), "the DM under test is not on the rail before the close"
      assert dm_row(html, kept.id), "the control DM is not on the rail before the close"

      html = render_click(view, "close_dm", %{"id" => closed.id})

      refute dm_row(html, closed.id), "the closed DM is still on the rail"

      assert dm_row(html, kept.id),
             "the close removed the OTHER DM too — this is a filter that drops DMs, not a close"

      assert Map.has_key?(Accounts.get_closed_dm_at(user.id), closed.id),
             "the close was rendered but never persisted"

      # THE RETURN. A message newer than the stored close timestamp is the
      # whole contract: it is what lets Close ship with no undo list.
      post_message!(closed, DateTime.add(DateTime.utc_now(), 60, :second))

      {:ok, _view, html} = live_rail(conn)

      assert dm_row(html, closed.id),
             "a newer message did not bring the closed DM back — Close is a one-way disappearance"

      assert Map.has_key?(Accounts.get_closed_dm_at(user.id), closed.id),
             "the row returned by clearing stored state rather than by activity"
    end

    test "the row leaves the rail and OPENING that DM brings it back", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("gen-migration")
      closed = create_dm(user, "Rowan Ellis")
      kept = create_dm(user, "Saru Watanabe")

      {:ok, view, html} = live_rail(conn)
      assert dm_row(html, closed.id), "the DM under test is not on the rail before the close"

      html = render_click(view, "close_dm", %{"id" => closed.id})
      refute dm_row(html, closed.id), "the closed DM is still on the rail"
      assert dm_row(html, kept.id), "the close removed the OTHER DM too"

      # `Chat.find_or_create_dm/4` returns the SAME space, so "start a new DM
      # with that person" lands on the closed space id. Entering it is what
      # has to undo the close.
      {:ok, _view, html} = live(conn, ~p"/chat/#{closed.id}")

      assert dm_row(html, closed.id),
             "opening the closed DM did not bring its row back"

      refute Map.has_key?(Accounts.get_closed_dm_at(user.id), closed.id),
             "the row is back on screen but the stored close survived, so the next nav re-hides it"
    end
  end

  # ── 2. Which rows offer which action ────────────────────────────────────

  describe "which rows offer Close" do
    test "the desktop menu offers Close on a DM and a group, and Hide on a channel — never crossed",
         %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      dm = create_dm(user, "Rowan Ellis")
      group = create_conversation(user, "group", "Design huddle")

      {:ok, view, _html} = live_rail(conn)

      dm_menu = view |> open_menu(dm.id) |> menu()
      assert button_by_role(dm_menu, "rail-row-actions-close"), "a DM's menu has no Close"
      refute button_by_role(dm_menu, "rail-row-actions-hide"), "a DM's menu offers Hide"

      group_menu = view |> open_menu(group.id) |> menu()
      assert button_by_role(group_menu, "rail-row-actions-close"), "a group's menu has no Close"

      channel_menu = view |> open_menu(channel.id) |> menu()

      assert button_by_role(channel_menu, "rail-row-actions-hide"),
             "a channel's menu lost Hide — the positive control for the refute above"

      refute button_by_role(channel_menu, "rail-row-actions-close"),
             "a channel row offers Close, which has no meaning for a channel"
    end

    test "the phone sheet offers Close on a DM row and not on a channel row", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      dm = create_dm(user, "Rowan Ellis")

      {:ok, view, _html} = live_rail(conn)

      dm_sheet = view |> open_menu(dm.id) |> sheet()
      assert button_by_role(dm_sheet, "row-actions-close-dm"), "the sheet has no Close on a DM"

      channel_sheet = view |> open_menu(channel.id) |> sheet()

      assert button_by_role(channel_sheet, "row-actions-hide"),
             "the sheet lost Hide on a channel — the positive control for the refute below"

      refute button_by_role(channel_sheet, "row-actions-close-dm"),
             "the sheet offers Close on a channel row"
    end
  end

  # ── 2b. Closing a PINNED DM ─────────────────────────────────────────────
  #
  # This section replaces a test that asserted the OPPOSITE rule. Until
  # Marlowe's report on 2026-08-13, "a PINNED DM is unaffected by a close"
  # asserted that the row STAYED in the Pinned block after a close, and that
  # no toast claimed otherwise. The close was still recorded, so the DM
  # vanished from the rail whenever the user unpinned it later, possibly days
  # later, attached to a click they had no reason to connect to it.
  #
  # Marlowe: "Closing a pinned item doesn't do anything. As soon as I unpin the
  # item (DM), it disappears because I closed it at some point. I expect if I
  # closed a pinned item, it would undo the pin and close the DM."
  #
  # One rule everywhere now: Close means this conversation leaves my list NOW.

  describe "closing a PINNED DM" do
    test "unpins it AND closes it, so the row leaves the rail in one action", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("gen-migration")
      dm = create_dm(user, "Rowan Ellis")
      kept_dm = create_dm(user, "Saru Watanabe")
      kept_channel = create_channel("pin-control")

      Sidebar.set_space_pinned(user.id, dm.id, true)
      Sidebar.set_space_pinned(user.id, kept_channel.id, true)

      {:ok, view, html} = live_rail(conn)

      assert row_wrap(pinned_block(html), dm.id),
             "the pinned DM is not in the Pinned block before the close"

      assert row_wrap(pinned_block(html), kept_channel.id),
             "the control pin is not in the Pinned block before the close"

      html = render_click(view, "close_dm", %{"id" => dm.id})

      # HALF ONE: off the rail, asserted across the WHOLE rail rather than one
      # section. A section-scoped refute is the assertion that missed this bug:
      # the row was gone from Direct Messages the entire time.
      refute rail_row(html, dm.id),
             "the closed DM is still on the rail. Close on a pinned row did nothing visible"

      # HALF TWO, in the same test on purpose: the pin is gone from the store.
      # On its own, half one also passes for a rail that dropped every pinned
      # row, and it passes for a close that hides the row while the pin (and
      # the delayed disappearance) survives underneath.
      refute dm.id in Sidebar.list_pinned_space_ids(user.id),
             "the row left the rail but the pin survived, so unpinning later detonates the close"

      assert Map.has_key?(Accounts.get_closed_dm_at(user.id), dm.id),
             "the row left the rail without the close being persisted"

      # CONTROLS. Close is one conversation leaving, not a bucket emptying.
      assert row_wrap(pinned_block(html), kept_channel.id),
             "closing a pinned DM emptied the Pinned block of everything else too"

      assert kept_channel.id in Sidebar.list_pinned_space_ids(user.id),
             "closing a pinned DM cleared the whole pin list"

      assert dm_row(html, kept_dm.id), "the close removed the OTHER DM too"

      # THE RETURN, and the shape of it. The pin is discarded rather than
      # stashed for later restoration (Designer's call, accepted by Marlowe), so
      # the DM comes back UNPINNED and one click re-pins it. A build that
      # remembered the pin would put this row back in the Pinned block, and
      # would be carrying exactly the invisible state that caused the bug.
      post_message!(dm, DateTime.add(DateTime.utc_now(), 60, :second))

      {:ok, _view, html} = live_rail(conn)

      assert dm_row(html, dm.id),
             "a newer message did not bring the closed DM back"

      refute row_wrap(pinned_block(html), dm.id),
             "the DM came back PINNED. The close stashed the old pin and restored it"
    end

    test "unpinning afterwards is uneventful: it is already gone and stays gone", %{conn: conn} do
      # THE DELAYED DETONATION, which is the bug Marlowe actually hit. Before the
      # fix this second click is where the DM disappeared: the row sat in the
      # Pinned block, which the close filter never sees, and the unpin dropped
      # it into the DM bucket where the close it never showed was waiting.
      {conn, user} = authed(conn)
      create_channel("gen-migration")
      dm = create_dm(user, "Rowan Ellis")
      kept = create_dm(user, "Saru Watanabe")

      Sidebar.set_space_pinned(user.id, dm.id, true)

      {:ok, view, html} = live_rail(conn)
      assert row_wrap(pinned_block(html), dm.id), "the pinned DM is not in the Pinned block"

      html = render_click(view, "close_dm", %{"id" => dm.id})
      refute rail_row(html, dm.id), "the closed DM is still on the rail"

      # The control for the refute above, taken from the SAME html. Without it
      # that line is satisfied by a rail rendering no DM rows at this point,
      # and the interesting half of this test never runs against a real rail.
      assert dm_row(html, kept.id), "the close removed the OTHER DM too"

      # The click that used to detonate. It is now a no-op on an already
      # unpinned space, and the user is looking at a rail where the row has
      # been gone since the close.
      html = render_click(view, "toggle_pinned", %{"space_id" => dm.id, "pinned" => "false"})

      refute rail_row(html, dm.id),
             "unpinning after a close made something happen to a row that was already gone"

      refute dm.id in Sidebar.list_pinned_space_ids(user.id),
             "the unpin re-pinned the closed DM"

      assert dm_row(html, kept.id), "the unpin took the other DM off the rail with it"
    end

    test "an UNPINNED DM closes as it always did, and a pinned CHANNEL is untouched",
         %{conn: conn} do
      # The positive control for the whole section. Close is DM-only: the
      # unpin must not leak onto a channel row, and closing an ordinary DM must
      # not start touching the pin list.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      dm = create_dm(user, "Rowan Ellis")

      Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, html} = live_rail(conn)
      assert dm_row(html, dm.id), "the DM under test is not on the rail before the close"
      assert row_wrap(pinned_block(html), channel.id), "the pinned channel is not in the block"

      html = render_click(view, "close_dm", %{"id" => dm.id})

      refute rail_row(html, dm.id), "closing an unpinned DM stopped working"

      assert row_wrap(pinned_block(html), channel.id),
             "closing an unpinned DM unpinned a CHANNEL"

      assert Sidebar.list_pinned_space_ids(user.id) == [channel.id],
             "closing an unpinned DM rewrote the pin list: " <>
               inspect(Sidebar.list_pinned_space_ids(user.id))

      # And Close aimed at the pinned CHANNEL itself does nothing at all. The
      # handler resolves the id against `@dm_conversations`, so a channel id
      # can never reach the unpin.
      html = render_click(view, "close_dm", %{"id" => channel.id})

      assert row_wrap(pinned_block(html), channel.id),
             "a close aimed at a channel unpinned it"

      assert channel.id in Sidebar.list_pinned_space_ids(user.id),
             "a close aimed at a channel dropped its pin from the store"

      refute Map.has_key?(Accounts.get_closed_dm_at(user.id), channel.id),
             "a channel id was written into the closed-DM map, where the DM filter never looks"
    end

    test "the user's OTHER tab drops the row too, without a reload", %{conn: conn} do
      # Both halves of this action are user preferences, and the pin half
      # already broadcast `:sidebar_changed` from `toggle_pinned`. A close that
      # broadcast the unpin alone would tell the second tab to re-read the pin
      # list and nothing else, and the row would HOP out of the Pinned block
      # into Direct Messages and sit there: the same half-applied state this
      # task is fixing, one tab over.
      {conn, user} = authed(conn)
      create_channel("gen-migration")
      dm = create_dm(user, "Rowan Ellis")
      kept = create_dm(user, "Saru Watanabe")

      Sidebar.set_space_pinned(user.id, dm.id, true)

      {:ok, acting, _html} = live_rail(conn)
      {:ok, other, html} = live_rail(conn)

      assert row_wrap(pinned_block(html), dm.id),
             "the second tab does not show the pinned DM before the close"

      render_click(acting, "close_dm", %{"id" => dm.id})

      html = render(other)

      refute rail_row(html, dm.id),
             "the second tab still shows the closed DM somewhere on the rail"

      assert dm_row(html, kept.id),
             "the second tab lost the other DM, so this is a rail that emptied rather than a close"
    end
  end

  # ── 3. The item's chrome ────────────────────────────────────────────────

  describe "the Close item's chrome" do
    test "Close renders LAST, under a hairline, and styled exactly like its siblings",
         %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("gen-migration")
      dm = create_dm(user, "Rowan Ellis")

      {:ok, view, _html} = live_rail(conn)
      opened = open_menu(view, dm.id)
      dm_menu = menu(opened)

      # Whole list, in order, rather than "Close is present". The dialog's
      # dismiss button trails every menu, so Close being LAST means last of
      # the ACTIONS. An equality is the ordering assertion and the absence
      # assertion at once.
      assert item_roles(dm_menu) == [
               "pin-control",
               "rail-row-actions-close",
               "row-actions-close"
             ]

      assert item_wrapper_class(dm_menu, "rail-row-actions-close") == "border-t border-edge",
             "the Close item has no hairline above it"

      close = button_by_role(dm_menu, "rail-row-actions-close")
      pin = button_by_role(dm_menu, "pin-control")

      assert visible_text(close) == "Close",
             "the Close item's label is not the word Close: #{inspect(visible_text(close))}"

      # Identical to its sibling, asserted by equality. Close is not
      # destructive: nothing is deleted and the conversation returns by
      # itself, so a red label would teach exactly the fear this removes.
      assert attr(close, "class") == attr(pin, "class"),
             "the Close item is styled differently from its siblings: #{attr(close, "class")}"

      refute attr(close, "class") =~ "error", "the Close item is coloured as destructive"

      assert attr(close, "phx-click") == "close_dm"
      assert attr(close, "phx-value-id") == dm.id

      assert attr(close, "aria-label") == "Close Rowan Ellis",
             "the Close item's accessible name does not name the conversation"

      # The sheet's item, same rules, its own role.
      dm_sheet = sheet(opened)
      sheet_close = button_by_role(dm_sheet, "row-actions-close-dm")
      sheet_pin = button_by_role(dm_sheet, "row-actions-pin")

      # The sheet's Hide is still on this list, on a DM, where it has no
      # reverse. That predates this stage (019fe998 shipped the sheet offering
      # hide on every row it opens on) and Hide is explicitly out of scope
      # here. Asserted rather than refuted so the day it is fixed, this line
      # is what says so.
      assert item_roles(dm_sheet) == [
               "row-actions-pin",
               "row-actions-hide",
               "row-actions-close-dm"
             ]

      assert item_wrapper_class(dm_sheet, "row-actions-close-dm") == "border-t border-edge",
             "the sheet's Close item has no hairline above it"

      assert visible_text(sheet_close) == "Close"
      assert attr(sheet_close, "class") == attr(sheet_pin, "class")
      assert attr(sheet_close, "phx-click") == "close_dm"
      assert attr(sheet_close, "phx-value-id") == dm.id
    end

    test "no hover-gated visibility on either Close item", %{conn: conn} do
      # Tailwind compiles `hover:` and `group-hover:` inside
      # `@media (hover: hover)`, which never matches on touch, so a
      # visibility gate written that way makes the control INVISIBLE on a
      # phone rather than quiet. Recorded at `app.css:3211-3218` after a
      # forced removal on 2026-08-11.
      {conn, user} = authed(conn)
      create_channel("gen-migration")
      dm = create_dm(user, "Rowan Ellis")

      {:ok, view, _html} = live_rail(conn)
      opened = open_menu(view, dm.id)

      for {slice_fn, role} <- [
            {&menu/1, "rail-row-actions-close"},
            {&sheet/1, "row-actions-close-dm"}
          ] do
        button = opened |> slice_fn.() |> button_by_role(role)

        # THE POSITIVE CONTROL. Without it every refute below is satisfied by
        # a menu that renders no Close at all: `attr/2` answers "" for nil,
        # and "" contains none of the banned tokens. Verified: this test was
        # the ONE of the eight that passed before the implementation existed.
        assert button, "no #{role} item to check for hover gating"

        classes = attr(button, "class")

        refute classes =~ "group-hover", "#{role} reveals itself on group-hover"
        refute classes =~ "hover:opacity", "#{role} reveals itself on hover"
        refute classes =~ "opacity-0", "#{role} starts invisible"
        refute classes =~ ~r/\bhidden\b/, "#{role} starts hidden"
      end
    end
  end

  # ── 4. Close says nothing ───────────────────────────────────────────────

  describe "closing a DM raises no acknowledgement" do
    test "a close raises no toast, and Hide's is still there", %{conn: conn} do
      # Marlowe's ruling at the stage-3 gate: "We don't need a acknowledgement /
      # affirmation for a close action on a DM. A User can simply search for a
      # person or agent to DM again if they want to bring back the window."
      # Stage 2 shipped a "Closed <name>" toast with an Undo and stage 3 gave
      # it a second line; both are out.
      #
      # The hide half is the POSITIVE CONTROL and it is not optional. Without
      # it, this test passes just as well for a build that deleted the toast
      # element outright — which would take Hide's acknowledgement down with
      # Close's, and Hide was never rejected.
      {conn, user} = authed(conn)
      channel = create_channel("hide-me")
      dm = create_dm(user, "Rowan Ellis")

      {:ok, view, _html} = live_rail(conn)

      # Opened first so the "the menu closed with the row" refute below is a
      # real assertion rather than a restatement of the default nil.
      assert view |> open_menu(dm.id) |> menu() =~ "row-actions-dialog"

      html = render_click(view, "close_dm", %{"id" => dm.id})

      refute dm_row(html, dm.id),
             "the close did not take the row off the rail, so the silence below proves nothing"

      assert count(html, ".channel-undo-toast") == 0,
             "closing a DM raised an acknowledgement, which Marlowe rejected"

      refute html =~ "undo_close_dm",
             "the page still offers an undo for a close"

      refute html =~ "It comes back on their next message",
             "the rejected second line is still on the page"

      # The open menu named a row that has just left the rail, so it must not
      # still be open naming it.
      refute menu(html) =~ "row-actions-dialog",
             "the row-actions menu is still open on a row that has left the rail"

      # THE CONTROL. Same page, same LiveView, the other verb.
      html = render_click(view, "hide_channel", %{"id" => channel.id})

      assert count(html, ".channel-undo-toast") == 1,
             "removing Close's acknowledgement took Hide's with it"

      assert visible_text(rail_toast(html)) =~ "Hidden #Hide-me",
             "Hide's toast no longer names what it hid"
    end

    test "Hide's toast is byte-for-byte what it was before Close existed", %{conn: conn} do
      # Hide is out of scope for the whole of task 019ffc5f. The two verbs
      # shared one element, so the guard is an EQUALITY against the exact
      # markup captured on the stage-2 tip (b6c18974) before a line of stage 3
      # was written — not a `=~`, which would pass while another variant's
      # nodes sat beside it.
      #
      # RE-AIMED, not relaxed (task 01a0312e stage 3). The toast moved from
      # `chat_live.html.heex` into `ChatLive.Partials.Rail.rail_footer/1`,
      # which renders it four levels shallower, so the two INDENTATION runs
      # inside it went 8 spaces -> 4 and 6 -> 2. Nothing else about the string
      # changed: same tags, same attributes, same order, same copy. The
      # literal below is the new render's exact bytes, re-captured on that
      # commit.
      #
      # The equality is kept as an equality on purpose. It is the only
      # assertion in the suite that would notice a whitespace-level change to
      # this element, and softening it to a `=~` or normalising the
      # whitespace to survive the move would delete the guard while appearing
      # to keep it — the move is exactly the event it should report.
      conn = conn |> authed() |> elem(0)
      channel = create_channel("hide-me")

      {:ok, view, _html} = live_rail(conn)
      html = render_click(view, "hide_channel", %{"id" => channel.id})

      expected =
        ~s(<div role="status" aria-live="polite" class="channel-undo-toast">) <>
          ~s(<span class="channel-undo-toast-message">\n) <>
          ~s(    Hidden <span class="font-medium">#Hide-me</span></span>) <>
          ~s(<button type="button" class="channel-undo-toast-button" ) <>
          ~s(phx-click="undo_hide" phx-value-id="#{channel.id}">\n) <>
          ~s(    Undo\n  </button></div>)

      assert rail_toast_raw(html) == expected,
             "Hide's toast markup changed:\n#{inspect(rail_toast_raw(html))}"

      # Hide's toast is the rail's ONE instance. Stage 3 added a second,
      # viewport-anchored copy at the template root for the phone; it was gated
      # on `@undo_toast` alone, so leaving it would have handed Hide a phone
      # acknowledgement it never had.
      assert count(html, ".channel-undo-toast") == 1,
             "Hide's toast renders more than once, so a phone now acknowledges a hide"

      refute visible_text(rail_toast(html)) =~ "Closed",
             "the close variant's copy leaked onto Hide's toast, where it is false"
    end
  end

  # ── 5. The row returns with no reload (stage 4) ─────────────────────────

  describe "a message brings a closed DM back on the open page" do
    test "the row leaves and RETURNS in the same mounted view, unread count intact",
         %{conn: conn} do
      # Section 1 proves the return across a remount, which is a weaker claim
      # than it looks: mount re-reads everything, so it passes for a rail that
      # only recomputes on a page load. This test never remounts. `view` is
      # one LiveView process from the close to the return, exactly as it is
      # for a user sitting on the page while someone writes to them.
      {conn, user} = authed(conn)
      create_channel("gen-migration")
      closed = create_dm(user, "Rowan Ellis")
      kept = create_dm(user, "Saru Watanabe")

      {:ok, view, html} = live_rail(conn)

      assert dm_row(html, closed.id), "the DM under test is not on the rail before the close"
      assert dm_row(html, kept.id), "the control DM is not on the rail before the close"

      html = render_click(view, "close_dm", %{"id" => closed.id})

      refute dm_row(html, closed.id), "the closed DM is still on the rail"

      assert dm_row(html, kept.id),
             "the close removed the OTHER DM too — this is a filter that drops DMs, not a close"

      # The other person writes. Inserted with an explicit `inserted_at` so
      # the comparison against the stored close is not a microsecond race,
      # then broadcast on the space's own topic — the rail subscribes to every
      # conversation it lists, which is how a background DM's unread count
      # moves at all.
      msg = message_from_other!(closed, user, DateTime.add(DateTime.utc_now(), 60, :second))
      Chat.PubSub.broadcast(closed.id, {:new_message, msg})

      html = render(view)

      # THE RETURN, with no reload between it and the close above.
      returned = dm_row(html, closed.id)

      assert returned,
             "a message arrived and the rail ignored it — the row only comes back on a reload"

      assert dm_row(html, kept.id), "the return took the other DM off the rail"

      # The branch this fix extends still does its original job. Without this,
      # a fix that recomputed the sections INSTEAD of counting the message
      # would pass everything above and silently drop the badge.
      assert unread_pill(returned) == "1",
             "the returned row carries no unread count: #{inspect(unread_pill(returned))}"

      # Nothing was written. The row is back because the render-time
      # comparison flipped, not because the stored close was cleared, and that
      # is the property the timestamp design buys: no background job, no
      # clearing pass, no state that can drift.
      assert Map.has_key?(Accounts.get_closed_dm_at(user.id), closed.id),
             "the row returned by clearing stored state rather than by activity"

      # The SECOND message costs nothing. Nothing clears `closed_at` until the
      # viewer opens the DM, so the return branch stays eligible for the rest
      # of the session; re-running it per message would rewrite
      # `last_activity_at` every time, and because the value would differ on
      # each pass, `assign/3` could not short-circuit and LiveView would
      # re-diff the whole sidebar on every inbound message.
      #
      # Asserted on the assign rather than the render because the two cases
      # look identical on screen — which is exactly why this needs a test.
      first_return = dm_last_activity(view, closed.id)

      second = message_from_other!(closed, user, DateTime.add(DateTime.utc_now(), 120, :second))
      Chat.PubSub.broadcast(closed.id, {:new_message, second})

      html = render(view)

      assert dm_last_activity(view, closed.id) == first_return,
             "the second message re-ran the return path on a row that was already back"

      assert unread_pill(dm_row(html, closed.id)) == "2",
             "the second message did not count"
    end
  end
end
