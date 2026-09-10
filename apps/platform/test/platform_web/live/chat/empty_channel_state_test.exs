defmodule PlatformWeb.ChatLive.EmptyChannelStateTest do
  @moduledoc """
  Guard for the zero-message empty state in
  `PlatformWeb.ChatLive.Partials.Composer.message_scroller/1` (task
  `01a0312e` stage 8, E2E case 4 sub-clause (a)).

  ## WHAT FAILED

  A channel with no messages rendered a genuinely blank pane: `#message-list`
  with zero children, `#chat-message-scroller` with empty innerText. There
  was no zero-message empty state anywhere in the chat templates — the only
  `<.empty_state>` instances were search-no-results, the mobile drawer's, and
  the brand-new-user rail one. This was NOT a regression from the stage 1–7
  extraction; the state never existed.

  ## WHY THE NEGATIVE CASE IS NOT ENOUGH ON ITS OWN

  An archived channel also has zero messages, and it already carries
  `#archived-banner` plus a structurally absent composer. Stacking a "say
  something to get started" invitation on a channel nobody can post to is the
  defect the archived clause exists to prevent — so the archived assertion is
  an ABSENCE assertion, and an absence assertion whose selector never matches
  anything anywhere passes forever for the wrong reason. The positive test in
  this file is that selector's anti-vacuity proof: same selector, same page,
  one state apart.

  The third test (a channel WITH a message) closes the other side: it proves
  the gate is reading message emptiness and not merely "this is a channel".

  Note `LazyHTML.query/2` returns a struct, so emptiness is checked via
  `Enum.count/1`, not `== []` or `is_nil/1`.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  # The empty state lives INSIDE the message scroller. Scoping the selector
  # there is what keeps it from matching the rail's brand-new-user empty
  # state or the mobile drawer's, both of which render on the same page.
  @selector "#chat-message-scroller .empty-state.empty-conversational"

  defp login(conn) do
    user =
      Repo.insert!(%User{
        email: "empty_channel_#{System.unique_integer([:positive])}@example.com",
        name: "Empty Channel User",
        oidc_sub: "oidc-empty-channel-#{System.unique_integer([:positive])}"
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

  defp query(html, selector) do
    html |> LazyHTML.from_document() |> LazyHTML.query(selector)
  end

  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  describe "a live channel with no messages" do
    test "renders the empty state inside the message scroller", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("empty-live")
      join(space, user)

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      # Anti-vacuity: the scroller itself is on the page, so a zero count
      # below would mean the empty state is missing, not that the page
      # failed to render.
      assert count(html, "#chat-message-scroller") == 1
      assert count(html, "#archived-banner") == 0

      assert count(html, @selector) == 1

      # The copy names the channel. Whitespace-tolerant because the HEEx
      # formatter reflows the interpolation freely.
      text = html |> query(@selector) |> LazyHTML.text()
      assert text =~ ~r/no\s+messages\s+yet\s+in\s+##{space.name}/
      assert text =~ ~r/This\s+space\s+is\s+quiet/
    end
  end

  describe "an ARCHIVED channel with no messages" do
    test "does NOT render the empty state — the archived banner owns that pane",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("empty-archived")
      join(space, user)
      {:ok, _archived} = Chat.archive_space(space)

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      # Anti-vacuity for the refute: the page rendered, the channel really is
      # archived, and it really does have zero messages (same state that made
      # the live channel above match).
      assert count(html, "#chat-message-scroller") == 1
      assert count(html, "#archived-banner") == 1

      assert count(html, @selector) == 0
    end
  end

  describe "a live channel WITH a message" do
    test "does NOT render the empty state", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("empty-populated")
      participant = join(space, user)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: "first light"
        })

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      assert count(html, "#chat-message-scroller") == 1
      assert count(html, "#archived-banner") == 0
      assert html =~ "first light"

      assert count(html, @selector) == 0
    end
  end

  # ── The SAME zero-message state, worded for a call (task 01a084bf stage 4)
  #    ─────────────────────────────────────────────────────────────────────
  #
  # The meetings call rail's Chat and Transcript panes are both "words from
  # this call" and their labels are too short to carry the difference, so the
  # distinction goes in the two empty states. The Chat one is
  # `data-role="call-rail-chat-empty"`, and it lives in
  # `Composer.message_scroller/1` because "the bound chat space has no
  # messages" is `:rendered_message_ids` — this LiveView's own count, not
  # something `CallShell.call_rail/1` or `MeetingLive` can see without keeping
  # a second copy of it.
  #
  # `ChatLive.Embedded` is the module `MeetingLive` `live_render`s, mounted
  # here in isolation because that is the only thing `@embedded` distinguishes.
  # Every test in this block is paired with its `/chat` counterpart above or
  # below: the two states share one selector each, one condition apart.
  @embedded_selector ~s([data-role="call-rail-chat-empty"])

  defp embedded_pane(conn, user, slug) do
    live_isolated(conn, PlatformWeb.ChatLive.Embedded,
      session: %{"current_user_id" => user.id, "chat_space_slug" => slug}
    )
  end

  describe "the EMBEDDED chat pane with a bound space and no messages" do
    test "says nothing is TYPED yet, and never that anything is being captured",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("empty-embedded")
      join(space, user)

      {:ok, _view, html} = embedded_pane(conn, user, space.slug)

      assert count(html, "#chat-message-scroller") == 1
      assert count(html, @embedded_selector) == 1

      text = html |> query(@embedded_selector) |> LazyHTML.text()

      # It names TYPED words, and it names the other pane so the two are told
      # apart by their copy rather than by a four-letter label.
      assert text =~ ~r/typed/i
      assert text =~ ~r/Transcript\s+tab/

      # It must be a DIFFERENT sentence from the transcript pane's
      # "No speech yet. Lines appear here as people talk." — asserted as the
      # literal, so a future edit that converges the two reds here.
      refute text =~ "No speech yet"

      # THE REFUSAL, as a test rather than a comment. This pane must never
      # read as "something is being recorded" or "content is on its way".
      for lie <- [~r/listening/i, ~r/transcrib/i, ~r/captur/i, ~r/recording/i, ~r/loading/i] do
        refute text =~ lie, "the Chat empty state must not imply capture or loading: #{text}"
      end
    end

    test "it REPLACES the standalone card rather than stacking a second empty state",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("embedded-single")
      join(space, user)

      {:ok, _view, html} = embedded_pane(conn, user, space.slug)

      # Anti-vacuity for the `== 0`: the pane rendered, the space really is
      # empty, and the rail's own line really is there — the SAME conditions
      # that make `@selector` match on `/chat`.
      assert count(html, @embedded_selector) == 1
      assert count(html, @selector) == 0

      # Two empty states in one 312px column is worse than either, and
      # "Connect your agent and @ them to plan and work in this space" is not
      # what someone mid-call needs.
      refute html =~ "This space is quiet"
    end

    test "a space with a message gets neither empty state", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("embedded-populated")
      participant = join(space, user)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: "typed out loud"
        })

      {:ok, _view, html} = embedded_pane(conn, user, space.slug)

      # The gate reads message emptiness, not "this is an embed".
      assert html =~ "typed out loud"
      assert count(html, @embedded_selector) == 0
      assert count(html, @selector) == 0
    end
  end

  describe "the two empty states are scoped to their own surface" do
    test "/chat never renders the rail's line, and the embed never renders /chat's",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("scoped-both")
      join(space, user)

      {:ok, _view, standalone} = live(conn, ~p"/chat/#{space.slug}")
      {:ok, _view, embedded} = embedded_pane(conn, user, space.slug)

      # Both `refute`s are guarded by the positive on the SAME selector in the
      # other surface, one assign apart, so neither can pass because a
      # selector stopped matching anywhere.
      assert count(standalone, @selector) == 1
      assert count(standalone, @embedded_selector) == 0

      assert count(embedded, @embedded_selector) == 1
      assert count(embedded, @selector) == 0
    end
  end
end
