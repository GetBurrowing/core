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

  defp mention_query(view), do: :sys.get_state(view.pid).socket.assigns.mention_query

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

      # A form test that supplies the param key cannot see the template drop
      # it — so assert the RENDERED form carries the input name, rather than
      # trusting a hand-built param map to round-trip.
      assert count(html, "form#compose-form input[hidden][name='compose[text]']") == 1
      assert count(html, "form#compose-form input[type=file][name=attachments]") == 1
    end
  end

  describe "the rich field (redesign rung 10)" do
    test "the field is a combobox chip field the server never patches", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-field")
      join(space, user)

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      field =
        "form#compose-form div#compose_text[contenteditable=true][phx-hook=ComposeInput]"

      assert count(html, field) == 1
      assert count(html, field <> "[phx-update=ignore]") == 1
      assert count(html, field <> "[role=combobox][aria-autocomplete=list]") == 1

      assert count(html, field <> "[aria-expanded=false][aria-controls=compose-mention-list]") ==
               1

      assert count(html, field <> "[enterkeyhint=send][aria-multiline=true]") == 1
      assert count(html, field <> "[data-value-input=compose_text_value]") == 1
      assert count(html, field <> ~s([data-draft-key="chat-draft:#{space.id}"])) == 1

      # The form value is the hidden input the hook serializes into, and it
      # is the ONLY compose[text] in the form: no textarea is left behind.
      assert count(
               html,
               "form#compose-form input#compose_text_value[hidden][name='compose[text]']"
             ) ==
               1

      assert count(html, "form#compose-form [name='compose[text]']") == 1
      assert count(html, "form#compose-form textarea") == 0

      # The @ button sits between the field and Send, and is not a submit.
      assert count(
               html,
               ~s(form#compose-form div#compose_text ~ button[type=button][data-role=compose-mention-button][aria-label="Mention someone"] ~ button[type=submit].compose-pill-send)
             ) == 1
    end

    test "Send is really disabled while empty, and enabled when a file is staged",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-send")
      join(space, user)

      {:ok, view, html} = live(conn, ~p"/chat/#{space.slug}")

      assert count(html, "button[type=submit].compose-pill-send[disabled]") == 1

      assert count(html, "button.compose-pill-send[data-staged=false][data-send-blocked=false]") ==
               1

      upload =
        file_input(view, "#compose-form", :attachments, [
          %{name: "shot.png", content: "png-bytes", type: "image/png"}
        ])

      render_upload(upload, "shot.png")
      html = render(view)

      assert count(html, "button[type=submit].compose-pill-send") == 1
      assert count(html, "button[type=submit].compose-pill-send[disabled]") == 0
      assert count(html, "button.compose-pill-send[data-staged=true]") == 1
    end

    test "typed text enables Send through the hidden input's phx-change", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-typed")
      join(space, user)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      html =
        view
        |> form("#compose-form", compose: %{text: "hi @[Someone]"})
        |> render_change()

      assert count(html, "button[type=submit].compose-pill-send[disabled]") == 0
      assert count(html, ~s(input#compose_text_value[value="hi @[Someone]"])) == 1

      html = view |> form("#compose-form", compose: %{text: "   "}) |> render_change()
      assert count(html, "button[type=submit].compose-pill-send[disabled]") == 1
    end
  end

  describe "the in-flow @mention list (redesign rung 10, stage 3)" do
    test "opens as a child of #compose-form, before the pill, and closes on clear",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-mention")
      join(space, user)

      {:ok, view, html} = live(conn, ~p"/chat/#{space.slug}")

      # Closed: only the empty wrapper, already in place before the pill, so
      # opening the list inserts INTO it and never moves the field.
      wrapper = ~s(form#compose-form > [data-role="mention-list"])
      assert count(html, wrapper) == 1
      assert count(html, wrapper <> " ~ .compose-pill-bar") == 1
      assert count(html, wrapper <> " [role=listbox]") == 0

      assert count(html, wrapper <> ~s( > [data-role="mention-list-status"][aria-live=polite])) ==
               1

      assert count(html, "#compose-mention-list") == 0

      html = render_hook(view, "mention_query", %{"query" => "", "source" => "compose-form"})

      list = ~s(form#compose-form > [data-role="mention-list"])
      assert count(html, list) == 1
      assert count(html, list <> " ~ .compose-pill-bar") == 1
      assert count(html, ".compose-pill-bar ~ [data-role=\"mention-list\"]") == 0

      # The listbox is the one the field's aria-controls names, and the old
      # floating popover is gone.
      assert count(html, ~s(#{list} #compose-mention-list[role=listbox])) == 1
      assert count(html, "#compose-mention-list [role=option]") >= 1
      assert count(html, "form#compose-form .shadow-lg") == 0
      assert count(html, "form#compose-form .w-64") == 0

      html = render_hook(view, "mention_clear", %{})
      assert count(html, "#compose-mention-list") == 0
      assert count(html, wrapper) == 1
    end

    test "MentionsHooks tracks the active query (the empty row's text), nil once cleared",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-mention-q")
      join(space, user)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      assert mention_query(view) == nil

      render_hook(view, "mention_query", %{"query" => "zzqx", "source" => "compose-form"})
      assert mention_query(view) == "zzqx"

      render_hook(view, "mention_clear", %{})
      assert mention_query(view) == nil
    end

    test "a query from another composer does not open the space composer's list",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-mention-src")
      join(space, user)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      html =
        render_hook(view, "mention_query", %{
          "query" => "",
          "source" => "inline-thread-compose-form-x"
        })

      assert count(html, "form#compose-form #compose-mention-list") == 0
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
      assert count(html, "input[type=file][name=attachments]") == 0
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

  # Redesign rung 10, stage 4: the empty row in live chat, and the thread
  # reply box's list, which lives in a stream row.
  describe "the @mention list's empty row and the thread reply list" do
    test "a query that matches no one renders the empty row in the space composer",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-empty-row")
      join(space, user)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      html = render_hook(view, "mention_query", %{"query" => "zzqx", "source" => "compose-form"})

      [row] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s([data-role="mention-list-empty"]))
        |> Enum.map(&LazyHTML.text/1)

      assert row =~ "No one matches “zzqx”"
      assert count(html, ~s(#compose-mention-list [data-role="mention-list-empty"])) == 1
    end

    test "a thread composer's query opens the list above that reply box, live", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("composer-thread-list")
      join(space, user)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      view |> form("#compose-form", compose: %{text: "thread root"}) |> render_submit()
      [msg | _] = Chat.list_messages(space.id)
      render_click(view, "open_thread", %{"message-id" => msg.id})

      form = "form#inline-thread-compose-form-#{msg.id}"
      list = "#inline-thread-mention-list-#{msg.id}"
      source = "inline-thread-compose-form-#{msg.id}"

      html = render(view)
      assert count(html, "#{form} [data-role=mention-list]") == 1
      assert count(html, list) == 0

      html = render_hook(view, "mention_query", %{"query" => "", "source" => source})
      assert count(html, "#{form} .thread-field-box #{list}[role=listbox]") == 1
      # Only the thread's list: the space composer's stays closed.
      assert count(html, "#compose-mention-list") == 0

      html = render_hook(view, "mention_query", %{"query" => "zzqx", "source" => source})
      assert count(html, ~s(#{list} [data-role="mention-list-empty"])) == 1

      html = render_hook(view, "mention_clear", %{})
      assert count(html, list) == 0
      assert count(html, "#{form} [data-role=mention-list]") == 1
    end
  end
end
