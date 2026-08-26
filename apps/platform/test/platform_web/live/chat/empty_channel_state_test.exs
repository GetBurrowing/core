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
end
