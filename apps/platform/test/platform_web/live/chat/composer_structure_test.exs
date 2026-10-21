defmodule PlatformWeb.ChatLive.ComposerStructureTest do
  @moduledoc """
  Structural guard for the extraction in task `01a0312e` stage 6, which moved
  the archived banner, the message scroller, the streaming/typing indicators
  and the composer out of `chat_live.html.heex` into
  `PlatformWeb.ChatLive.Partials.Composer`.

  ## WHY A CLASS-STRING DIFF CANNOT COVER THIS

  `#chat-message-scroller` carries `min-h-0`, and that class is load-bearing:
  without it the flex item defaults to `min-height: auto`, the message list
  refuses to shrink below its intrinsic content height, and with 80+ messages
  the composer and the bottom-tab nav are pushed off-screen on iOS Safari /
  PWA standalone.

  The failure mode this file exists for is that **the chain breaks if ANY
  element is interposed between the flex parent and the scroller, even though
  every class string is intact**. A function component whose template root is
  a fresh `<div>` wrapping the moved markup does exactly that: `min-h-0` is
  still on `#chat-message-scroller`, every attribute assertion in the suite
  still passes, and the layout is broken on a phone with a long channel.

  So these tests assert the parent-CHILD RELATION with `>` combinators, not
  the attributes. `#chat-drop-zone > #chat-message-scroller` matches only if
  the scroller is a DIRECT child; a wrapper makes it a grandchild and the
  selector goes empty. The same holds for the banner and the composer, which
  are the scroller's flex siblings and share the same fate.

  Note `LazyHTML.query/2` returns a struct, so emptiness is checked via
  `Enum.count/1`, not `== []` or `== nil`.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp login(conn) do
    user =
      Repo.insert!(%User{
        email: "composer_structure_#{System.unique_integer([:positive])}@example.com",
        name: "Composer Structure User",
        oidc_sub: "oidc-composer-structure-#{System.unique_integer([:positive])}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp join(space, user) do
    case Chat.add_participant(space.id, %{
           participant_type: "user",
           participant_id: user.id,
           display_name: user.name,
           joined_at: DateTime.utc_now()
         }) do
      {:ok, p} ->
        p

      {:error, _} ->
        Enum.find(Chat.list_participants(space.id), fn p ->
          p.participant_type == "user" and p.participant_id == user.id
        end)
    end
  end

  defp new_space(slug_prefix) do
    slug = "#{slug_prefix}-#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"})

    space
  end

  defp count(html, selector) do
    html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()
  end

  describe "no element may be interposed above #chat-message-scroller" do
    test "the scroller is a DIRECT child of #chat-drop-zone", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("scroller-chain")
      join(space, user)

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      # The scroller exists at all (anti-vacuity for the assertion below —
      # a `> ` selector on a missing element is also 0).
      assert count(html, "#chat-message-scroller") == 1

      # The load-bearing relation. A component that wraps its output in a
      # <div> renders the scroller as a grandchild and this goes to 0 while
      # every class-string assertion in the suite stays green.
      assert count(html, "#chat-drop-zone > #chat-message-scroller") == 1

      # And the flex chain above it: #chat-drop-zone itself is still the
      # direct child of the flex row it was, with min-h-0 on both.
      assert count(html, "#chat-drop-zone") == 1

      drop_zone_class =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#chat-drop-zone")
        |> LazyHTML.attribute("class")
        |> List.first()

      assert drop_zone_class =~ "min-h-0"

      scroller_class =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#chat-drop-zone > #chat-message-scroller")
        |> LazyHTML.attribute("class")
        |> List.first()

      assert scroller_class =~ "min-h-0"
      assert scroller_class =~ "overscroll-contain"
      assert scroller_class =~ "[overflow-anchor:none]"
    end

    test "the composer area and #message-list keep their own direct-child relations",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-chain")
      join(space, user)

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      # The composer region is a flex sibling of the scroller. Since task
      # 01a15f2e stage 3 its one wrapper is #chat-dock, which is
      # `display: contents` at every width (no box, so the composer stays a
      # flex item of #chat-drop-zone) and becomes the glass overlay only below
      # lg on a routed mount. That CSS is pinned in
      # test/platform/design/phone_chrome_clearance_guard_test.exs; any OTHER
      # wrapper still turns this selector to 0.
      assert count(html, "#chat-drop-zone > #chat-dock.chat-dock > div.compose-input-area") == 1

      # #message-list is a direct child of the scroller — the infinite-scroll
      # sentinels are its siblings inside the same scroll viewport.
      assert count(html, "#chat-message-scroller > #message-list") == 1
      assert count(html, "#chat-message-scroller > #message-list[phx-update=stream]") == 1
    end
  end

  describe "hook identity survived the move" do
    test "scroll container marker and composer form wiring sit on their own elements",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-hooks")
      join(space, user)

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      assert count(html, "#chat-message-scroller[data-scroll-container]") == 1
      assert count(html, "#message-list[phx-hook=ScrollToBottom]") == 1

      assert count(html, "form#compose-form[phx-submit=send_message][phx-change=compose_changed]") ==
               1

      assert count(html, "form#upload-send-form[phx-submit=upload_send]") == 1

      # A form test that supplies the param key cannot see the template drop
      # it — so assert the RENDERED form carries the input name, rather than
      # trusting a hand-built param map to round-trip.
      assert count(html, "form#compose-form textarea[name='compose[text]']") == 1
      assert count(html, "form#upload-send-form input[type=file][name=attachments]") == 1
    end
  end

  describe "archived spaces" do
    test "banner renders as a direct child and the composer forms are structurally absent",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-archived")
      join(space, user)
      {:ok, space} = Chat.archive_space(space)

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      assert count(html, "#chat-drop-zone > #archived-banner[role=status]") == 1
      # The scroller relation holds on the archived branch too — the banner
      # is a sibling above it, not a wrapper around it.
      assert count(html, "#chat-drop-zone > #chat-message-scroller") == 1

      # Hiding is affordance; the context layer rejects the writes regardless.
      # The absence is deliberate and asserted so a later refactor cannot
      # restore the forms by accident.
      assert count(html, "form#compose-form") == 0
      assert count(html, "form#upload-send-form") == 0
      # The compose-input-area shell itself stays (it is unconditional), as
      # the dock's child (see the live-space test above).
      assert count(html, "#chat-drop-zone > #chat-dock.chat-dock > div.compose-input-area") == 1
    end

    test "a live space renders the composer and no banner", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-live")
      join(space, user)

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      assert count(html, "#archived-banner") == 0
      assert count(html, "form#compose-form") == 1
    end
  end
end
