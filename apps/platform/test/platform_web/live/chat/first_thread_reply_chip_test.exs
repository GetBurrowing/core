defmodule PlatformWeb.ChatLive.FirstThreadReplyChipTest do
  @moduledoc """
  The FIRST reply in a thread reaches other viewers' live views as a thread
  chip on the parent (task 01a174f5 fix stage). Before the fix
  `MessagesHooks.maybe_update_inline_thread/2` only bumped a parent already in
  `:thread_previews`, so a parent with no replies yet got no chip until a
  reload, while the "↳ N new replies to …" row advertised replies it lacked.

  Mutation: reverting the miss path to a no-op makes the first test red.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "first_reply_chip_#{label}_#{n}@example.com",
      name: "First Reply #{label}",
      oidc_sub: "oidc-first-reply-chip-#{label}-#{n}"
    })
  end

  defp member!(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

    p
  end

  setup %{conn: conn} do
    a_user = user!("a")
    b_user = user!("b")
    slug = "first-reply-chip-#{System.unique_integer([:positive])}"
    {:ok, space} = Chat.create_space(%{name: "First reply chip", slug: slug, kind: "channel"})

    %{
      conn: conn,
      a_user: a_user,
      b_user: b_user,
      space: space,
      a: member!(space, a_user),
      b: member!(space, b_user)
    }
  end

  defp post!(space, participant, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp reply!(thread, participant, content) do
    {:ok, msg} = Chat.reply_to_thread(thread.id, participant.id, %{content: content})
    msg
  end

  defp mount_as!(ctx, user) do
    conn = init_test_session(ctx.conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/chat/#{ctx.space.slug}")
    view
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp chip_text(view, parent) do
    doc(view)
    |> LazyHTML.query(~s(#messages-#{parent.id} [data-role=thread-chip]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp message_list_ids(view),
    do: doc(view) |> LazyHTML.query("#message-list > *") |> LazyHTML.attribute("id")

  test "B's live view gets the parent's chip on A's first reply, then counts the second", ctx do
    _ = post!(ctx.space, ctx.a, "before the parent")
    view_b = mount_as!(ctx, ctx.b_user)
    view_a = mount_as!(ctx, ctx.a_user)

    parent = post!(ctx.space, ctx.b, "the parent P1")
    _ = post!(ctx.space, ctx.a, "after the parent")

    assert has_element?(view_b, "#message-list #messages-#{parent.id}")
    assert chip_text(view_b, parent) == []
    before = message_list_ids(view_b)
    assert "messages-#{parent.id}" in before

    {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, parent.id)
    _ = reply!(thread, ctx.a, "r1")

    assert [text] = chip_text(view_b, parent)
    assert String.starts_with?(text, "↩ 1 reply")
    assert message_list_ids(view_b) == before

    # The replier's own other view gets it too.
    assert [a_text] = chip_text(view_a, parent)
    assert String.starts_with?(a_text, "↩ 1 reply")

    _ = reply!(thread, ctx.a, "r2")

    assert [text2] = chip_text(view_b, parent)
    assert String.starts_with?(text2, "↩ 2 replies")
    assert message_list_ids(view_b) == before
  end

  test "a first reply on a parent outside the window adds no chip and no row", ctx do
    parent = post!(ctx.space, ctx.b, "old parent")
    for i <- 1..55, do: post!(ctx.space, ctx.a, "later #{i}")
    {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, parent.id)

    view_b = mount_as!(ctx, ctx.b_user)

    refute MapSet.member?(
             :sys.get_state(view_b.pid).socket.assigns.rendered_message_ids,
             parent.id
           )

    before = message_list_ids(view_b)
    refute "messages-#{parent.id}" in before

    _ = reply!(thread, ctx.a, "r1")

    assert Process.alive?(view_b.pid)
    refute has_element?(view_b, "#messages-#{parent.id}")
    assert doc(view_b) |> LazyHTML.query("#messages-#{parent.id}") |> Enum.empty?()
    assert message_list_ids(view_b) == before

    # Positive control from the same view: a top-level message still lands.
    probe = post!(ctx.space, ctx.a, "probe")
    assert has_element?(view_b, "#message-list #messages-#{probe.id}")
  end
end
