defmodule PlatformWeb.ChatLiveMarkAllReadTest do
  @moduledoc """
  "Mark all as read" (task `01a02491-a407-794f-a13e-d18398e4b092` stage 3).

  Burrow redesign 22 stage 2 deleted the desktop channel rail and its header
  kebab; the item now lives in the Chat list's Options popover
  (`[data-role=chat-list-pop-mark-all-read]`, opened by `#list-more`), on the
  same `mark_all_read` handler.

  The context-level guarantees live in
  `test/platform/chat/member_space_ids_test.exs`, where the clearing query is
  tested against the counting query it has to agree with. This file covers the
  two things only a mounted LiveView can show: the item is in the popover, and
  pressing it takes the icon rail's Chat badge NODE off the page rather than
  merely taking a number to zero somewhere in the context.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @chat_badge ~s(data-role="chat-badge")

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "mark_all_read_#{n}@example.com",
        name: "Reader #{n}",
        oidc_sub: "oidc-mark-all-read-#{n}"
      })

    root = Tenancy.get_org_by_slug!("acme")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: root.id, role: "member"})
    |> Repo.insert!()

    # Root membership resolves `Tenancy.visibility/1` to `:root_all`, so the
    # org fence is a pass-through and every assertion below is about the kind
    # allow-list and the read cursors, not about tenancy.
    assert Tenancy.visibility(user) == :root_all

    %{conn: init_test_session(conn, current_user_id: user.id), user: user, root: root}
  end

  describe "the Options popover" do
    test "offers Mark all read as an ordinary row", %{conn: conn, root: root} do
      channel!("general", root)
      {:ok, view, _html} = live_following_redirect(conn)

      # Positive control: closed, the item is not on the page.
      refute has_element?(view, ~s([data-role="chat-list-pop-mark-all-read"]))

      popover = open_options(view)

      assert popover =~ ~s(phx-click="mark_all_read")
      assert popover =~ "Mark all read"

      # An ordinary popover row, styled IDENTICALLY to its sibling. Asserted as
      # an equality rather than as the absence of a modifier class, so a
      # warning or destructive treatment added later fails here: reading a
      # conversation undoes this action, and hesitation is the wrong thing to
      # invite.
      assert role_class(popover, "chat-list-pop-mark-all-read") ==
               role_class(popover, "chat-list-pop-appearance")
    end
  end

  describe "pressing it" do
    test "removes the rail badge and leaves an unread meeting space alone", ctx do
      channel = channel!("general", ctx.root)
      dm = space!("dm")
      group = space!("group")
      meeting = space!("meeting")

      Enum.each([channel, dm, group], &seat_with_unread!(&1, ctx.user, 2))
      meeting_seat = seat_with_unread!(meeting, ctx.user, 3)

      {:ok, view, _html} = live_following_redirect(ctx.conn)

      # Entering the space the rail lands on marks it read, so the number here
      # is whatever survives that. It has to be non-zero for the refute below
      # to mean anything.
      assert Chat.total_unread_for_viewer(ctx.user) > 0
      assert render(view) =~ @chat_badge

      open_options(view)

      view
      |> element(~s(#chat-list-popover button[data-role="chat-list-pop-mark-all-read"]))
      |> render_click()

      # `render/1` again on purpose: ShellLive recomputes the badge on the next
      # mailbox turn, and this call is processed after that message.
      refute render(view) =~ @chat_badge

      assert Chat.total_unread_for_viewer(ctx.user) == 0

      # The half that makes the rest mean something. A version that marked
      # every participant row read passes everything above while destroying the
      # unread state of a conversation this reader has never opened.
      assert is_nil(cursor(meeting_seat))
      assert Map.get(Chat.unread_counts_for_user(ctx.user.id), meeting.id) == 3
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp channel!(slug, org) do
    {:ok, space} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: "#{slug}-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, space} = Chat.assign_space_org(space, org.id)
    space
  end

  defp space!(kind) do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "Space #{n}", slug: "space-#{n}", kind: kind})
    space
  end

  defp seat_with_unread!(space, viewer, count) do
    {:ok, seat} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: viewer.id,
        joined_at: DateTime.utc_now()
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: other_user!().id,
        joined_at: DateTime.utc_now()
      })

    Enum.each(1..count, fn i ->
      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "message #{i}"
        })
    end)

    seat
  end

  defp other_user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "mark_all_read_author_#{n}@example.com",
      name: "Author #{n}",
      oidc_sub: "oidc-mark-all-read-author-#{n}"
    })
  end

  defp cursor(%Participant{id: id}), do: Repo.get!(Participant, id).last_read_message_id

  defp live_following_redirect(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  defp open_options(view) do
    view |> element("#list-more") |> render_click()

    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#chat-list-popover")
    |> LazyHTML.to_html()
  end

  defp role_class(html, role) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(button[data-role="#{role}"]))
    |> LazyHTML.attribute("class")
    |> case do
      [class] -> class
      other -> flunk("expected one button[data-role=#{role}], got #{inspect(other)}")
    end
  end
end
