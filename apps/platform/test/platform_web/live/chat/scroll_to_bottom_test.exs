defmodule PlatformWeb.ChatLive.ScrollToBottomTest do
  @moduledoc """
  Regression coverage for the chat surface contract that the
  `ScrollToBottom` JS hook (`assets/js/hooks/scroll_to_bottom.js`)
  depends on.

  Background: stages 1 + 2 of task `019e21c7` fixed two distinct bugs:

  1. The hook previously read `scrollHeight`/`scrollTop` off `this.el`
     (the `#message-list` div) but the actual scrolling ancestor was a
     parent `<main>` once the chat surface was wrapped for the PWA
     scroll-lock work. The fix introduced `data-scroll-container` as an
     explicit opt-in marker and re-targeted the hook to climb to it.
     `chat_live.html.heex` marks `#message-list` itself with the
     attribute (commit `c71f90a`); the shell's `<main>` also carries it
     (load-bearing fallback, commit `b22c830`).

  2. `applyDateSeparators` originally removed every `.js-date-separator`
     and reinserted them on every DOM mutation. Each `stream_insert`
     therefore churned the whole list head, defeating the browser's
     scroll-anchoring and causing visible jumps at the top of the
     viewport. The fix made the function incremental and idempotent
     (commits `a481f87` + `b7a926b`): only the changed boundary is
     touched, and a second invocation on the same row set is a no-op.

  These tests pin the LV-side contract so the wiring can't quietly
  regress. The pure DOM-mutating logic of `applyDateSeparators` itself
  is exercised in `assets/test/scroll_to_bottom_unit_test.mjs`
  (Node-runnable, `node --test`); per ORG_MEMORY,
  `Phoenix.LiveViewTest.render_hook/3` does not actually run the
  client-side hook code so a server-only assertion would be vacuous.

  Plan v1 stage 3 calls for three assertions:

    (1) after `stream_insert` of a new message the hook can dispatch a
        scroll-to-bottom — verified server-side by asserting the
        `phx-hook="ScrollToBottom"` + `data-scroll-container` wiring
        survives a re-render that mutates the messages stream.
    (2) `applyDateSeparators` is idempotent — covered by the JS unit
        test; the LV side asserts the `data-date` payload the hook
        reads is present and well-formed (`YYYY-MM-DD`).
    (3) growing the message list by 1 same-day message touches only
        the message row markup, not the surrounding scroll/separator
        wiring — asserted by re-rendering after a second message and
        checking that the load-bearing attributes on `#message-list`
        are unchanged.

  Task `019fabe8` stage 3 adds a fourth contract: `#message-list`
  carries `data-anchor-message-id` when `handle_params/3` accepted a
  `?message=<id>` deep link, and carries no such attribute otherwise.
  That attribute is the ONLY channel by which the hook learns to
  suppress its initial bottom snap, and it is attribute-driven
  precisely so it arrives in the same diff as the streamed window. The
  hook's own branch logic is exercised in
  `assets/test/hooks/scroll_to_bottom.test.js` (vitest) — `render_hook/3`
  still does not run client hook code, so the LV side pins the payload
  and nothing more.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  setup do
    previous_root = Application.get_env(:platform, :chat_attachments_root)

    upload_root =
      Path.join(
        System.tmp_dir!(),
        "platform_scroll_test_uploads_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:platform, :chat_attachments_root, upload_root)

    on_exit(fn ->
      File.rm_rf(upload_root)
      Application.put_env(:platform, :chat_attachments_root, previous_root)
    end)

    :ok
  end

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "scroll_test_#{System.unique_integer([:positive])}@example.com",
        name: "Scroll Test User",
        oidc_sub: "oidc-scroll-#{System.unique_integer([:positive])}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp ensure_space(slug) do
    Chat.get_space_by_slug(slug) ||
      elem(Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"}), 1)
  end

  # Ensure the user has a Participant in the space, then post a message
  # as that participant. `Chat.add_participant/2` strictly inserts (no
  # upsert), so on the second call we look up the existing participant
  # via `Chat.list_participants/1` instead of re-adding.
  defp post_message(space, user, content) do
    participant =
      case Chat.add_participant(space.id, %{
             participant_type: "user",
             participant_id: user.id,
             display_name: user.name || user.email,
             joined_at: DateTime.utc_now()
           }) do
        {:ok, p} ->
          p

        {:error, _changeset} ->
          # Already a member — find the existing row.
          Enum.find(Chat.list_participants(space.id), fn p ->
            p.participant_type == "user" and p.participant_id == user.id
          end) || raise "could not find participant for user #{user.id} in space #{space.id}"
      end

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    {participant, message}
  end

  describe "ScrollToBottom hook wiring (#message-list contract)" do
    test "message-list carries phx-hook=\"ScrollToBottom\" + phx-update=\"stream\"; scroll container is the wrapper ancestor",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/chat/general")

      # Task 019e18fc Stage 3 (infinite scroll) moved data-scroll-container
      # from #message-list onto a new `#chat-message-scroller` wrapper —
      # the sentinels for infinite-scroll need to live INSIDE the scroll
      # viewport, so the wrapper became the actual scroller and
      # #message-list became a non-scrolling flex column inside it. The
      # ScrollToBottom hook's `closest("[data-scroll-container]")` walk
      # now resolves to the wrapper instead of #message-list — same
      # contract intent, different anchor element.
      assert html =~
               ~r/id="chat-message-scroller"[^>]*data-scroll-container/,
             "expected #chat-message-scroller wrapper to carry data-scroll-container — " <>
               "without it the ScrollToBottom hook climbs to <main> and scrolls the wrong element"

      # Hook attribute itself — without phx-hook=\"ScrollToBottom\" the
      # observer never mounts and no scroll-to-bottom happens. Still
      # bound on #message-list since the hook reads its child mutations.
      assert html =~ ~r/id="message-list"[^>]*phx-hook="ScrollToBottom"/,
             "phx-hook=\"ScrollToBottom\" must remain bound on #message-list"

      # phx-update=\"stream\" is what the hook's MutationObserver
      # listens for: each stream_insert mutates childList on this node.
      assert html =~ ~r/id="message-list"[^>]*phx-update="stream"/,
             "stream-update is required for the MutationObserver to fire on inserts"
    end

    test "shell <main> also carries data-scroll-container as fallback ancestor", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/chat/general")

      # The hook prefers an explicit ancestor with the attribute and
      # falls back to <main>. We require the attribute on a <main>
      # element so the fallback path stays usable for any future
      # surface that doesn't put the marker on the scroller itself.
      assert html =~ ~r/<main[^>]*data-scroll-container/,
             "shell <main> must carry data-scroll-container as a load-bearing fallback for the hook"
    end
  end

  describe "data-date / data-participant-id payloads (applyDateSeparators contract)" do
    test "each rendered message row carries data-date=YYYY-MM-DD and data-participant-id", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      space = ensure_space("scroll-data-attrs-#{System.unique_integer([:positive])}")
      {participant, _msg} = post_message(space, user, "hello world from scroll test")

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      # The hook's row scan is `[data-date][data-participant-id]` —
      # both attributes are required for a row to participate in
      # separator computation. Pin the payload format too: the hook
      # parses `YYYY-MM-DD` and dies silently on anything else.
      assert html =~ ~r/data-participant-id="#{participant.id}"/,
             "rendered message row must expose data-participant-id (hook keys grouping by it)"

      assert html =~ ~r/data-date="\d{4}-\d{2}-\d{2}"/,
             "data-date must serialize as YYYY-MM-DD; the JS hook parses with split(\"-\")"
    end

    test "data-participant-id repeats verbatim across consecutive same-sender messages", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      space = ensure_space("scroll-grouping-#{System.unique_integer([:positive])}")
      {participant, _} = post_message(space, user, "first")
      {^participant, _} = post_message(space, user, "second")
      {^participant, _} = post_message(space, user, "third")

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      # `applyGrouping` collapses avatar/header on consecutive rows
      # with matching participant id. Three messages from the same
      # participant must produce three identical data-participant-id
      # values. (We assert >= 3 to tolerate any pre-existing greeter
      # messages that happen to be rendered above ours.)
      occurrences =
        Regex.scan(~r/data-participant-id="#{participant.id}"/, html)
        |> length()

      assert occurrences >= 3,
             "expected 3 same-sender rows so applyGrouping has something to collapse, got #{occurrences}"
    end
  end

  describe "stage 3 acceptance: growing the message list preserves scroll wiring" do
    # Plan v1 stage 3 acceptance (3): when the message list grows by 1
    # message in the same day-bucket, only message DOM changes — no
    # separator removal/reinsert and no churn in the
    # data-scroll-container wiring. Proxy this server-side: post one
    # message, render, then post a second same-day same-sender message
    # and re-render, and assert that the load-bearing markup on
    # #message-list is byte-identical across both renders. The
    # incremental `applyDateSeparators` change relies on the rest of
    # the surrounding wiring being stable (it walks
    # `previousElementSibling`); a refactor that flips
    # phx-update or moves data-scroll-container would silently
    # break the hook.
    test "scroll-container wiring on #message-list is stable across stream_insert renders", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      space = ensure_space("scroll-stable-#{System.unique_integer([:positive])}")
      {_participant, _} = post_message(space, user, "first message")

      {:ok, view, html_a} = live(conn, ~p"/chat/#{space.slug}")

      # Snapshot the load-bearing attribute string on #message-list.
      [_, message_list_a] = Regex.run(~r/<div\s+id="message-list"([^>]*)>/, html_a)

      # Post a second message in the same day-bucket and force a
      # re-render. We don't go through the WS push-broadcast path
      # because the LV PubSub subscription for unbootstrapped paths
      # can race the test process; instead, navigate-patch which
      # re-renders the full surface with the new message present.
      {_participant, _msg2} = post_message(space, user, "second message same bucket")

      html_b = render_patch(view, ~p"/chat/#{space.slug}")
      [_, message_list_b] = Regex.run(~r/<div\s+id="message-list"([^>]*)>/, html_b)

      assert message_list_a == message_list_b,
             """
             #message-list attributes changed between renders. The
             ScrollToBottom hook's MutationObserver is only attached
             on the original mount; if any of {phx-hook,
             phx-update, data-scroll-container, class chain} flips
             between renders the hook silently stops scrolling on
             new messages.

             before: #{inspect(message_list_a)}
             after:  #{inspect(message_list_b)}
             """

      # Sanity: the second message actually rendered into the stream.
      assert html_b =~ "second message same bucket"
    end
  end

  describe "task 019fabe8 stage 3: data-anchor-message-id on #message-list" do
    test "renders on #message-list when ?message= anchored, and the target row is the one named",
         %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = ensure_space("scroll-anchor-#{System.unique_integer([:positive])}")
      {_participant, _first} = post_message(space, user, "context before the anchor")
      {_participant, target} = post_message(space, user, "the anchored message")
      {_participant, _after} = post_message(space, user, "context after the anchor")

      {:ok, view, html} = live(conn, ~p"/chat/#{space.slug}?message=#{target.id}")

      assert html =~ ~r/id="message-list"[^>]*data-anchor-message-id="#{target.id}"/,
             "#message-list must carry data-anchor-message-id when an anchor was accepted — " <>
               "it is the only signal the ScrollToBottom hook has to suppress its initial " <>
               "bottom snap, and it must arrive in the same diff as the streamed window"

      # Positive control for the attribute's meaning: the id it names is
      # a row that actually exists in this render (chat_message.ex emits
      # data-message-id), so the hook's querySelector can resolve it.
      # An attribute naming a row the hook can never find would leave
      # the bottom snap in charge and this feature dead.
      assert html =~ ~s(data-message-id="#{target.id}")

      # And the arrival ring is on that exact row (stage 2's highlight),
      # which is what the reader sees once the hook has centred it.
      target_row = view |> element(~s([data-message-id="#{target.id}"])) |> render()
      assert target_row =~ "ring-primary/20"
    end

    test "absent on a plain channel entry, while the rest of the hook wiring is unchanged", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      space = ensure_space("scroll-noanchor-#{System.unique_integer([:positive])}")
      {_participant, _msg} = post_message(space, user, "just a message")

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      refute html =~ "data-anchor-message-id",
             "a normal entry must not emit data-anchor-message-id — a stale or blanket " <>
               "attribute would suppress the bottom snap on every channel open"

      # Paired positive control: the hook is still mounted on the same
      # element, so the `refute` above is about the anchor attribute
      # specifically and not about the whole surface having vanished.
      assert html =~ ~r/id="message-list"[^>]*phx-hook="ScrollToBottom"/
    end

    test "absent when the requested anchor is refused, present for an accepted one in the same run",
         %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = ensure_space("scroll-anchor-refused-#{System.unique_integer([:positive])}")
      {_participant, real} = post_message(space, user, "a real message")

      # Unknown id: stage 2 resolves this to `:miss`, which lands the
      # reader in the channel with a plain-text notice and no anchor.
      {:ok, _view, refused_html} =
        live(conn, ~p"/chat/#{space.slug}?message=#{Ecto.UUID.generate()}")

      refute refused_html =~ "data-anchor-message-id"

      # Positive control in the same run: an accepted anchor DOES emit
      # the attribute, so the `refute` above measures the refusal path
      # rather than a feature that never shipped.
      {:ok, _view2, accepted_html} = live(conn, ~p"/chat/#{space.slug}?message=#{real.id}")

      assert accepted_html =~ ~r/id="message-list"[^>]*data-anchor-message-id="#{real.id}"/
    end
  end
end
