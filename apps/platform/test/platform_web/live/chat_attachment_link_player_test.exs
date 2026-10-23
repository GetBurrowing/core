defmodule PlatformWeb.ChatAttachmentLinkPlayerTest do
  @moduledoc """
  Task 01a1655c stage 3: a message whose text links a video attachment on
  this install renders the inline player, but only for a viewer who can read
  the attachment. Everyone else gets the plain link, exactly as before, and
  the download route answers them 404.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  @player "[data-role=video-attachment] video[playsinline][controls][preload=metadata]"

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "#{label}_#{n}@example.com",
      name: "#{label} #{n}",
      oidc_sub: "oidc-#{label}-#{n}"
    })
  end

  defp channel!(prefix) do
    {:ok, space} =
      Chat.create_space(%{
        name: prefix,
        slug: "#{prefix}-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp seat!(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    p
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

  defp video!(space) do
    {:ok, att} =
      Chat.create_attachment(%{
        space_id: space.id,
        filename: "clip-01.mp4",
        content_type: "video/mp4",
        byte_size: 58_000_000,
        storage_key: "k-#{System.unique_integer([:positive])}"
      })

    att
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  setup %{conn: conn} do
    # The clip lives in `home`. `member` is seated there; `outsider` is
    # seated only in `lobby`, where someone pastes the link.
    home = channel!("home")
    lobby = channel!("lobby")
    member = user!("member")
    outsider = user!("outsider")
    author = user!("author")

    p_member = seat!(home, member)
    _ = seat!(lobby, outsider)
    p_author_lobby = seat!(lobby, author)

    clip = video!(home)

    %{
      conn: conn,
      home: home,
      lobby: lobby,
      member: member,
      outsider: outsider,
      p_member: p_member,
      p_author_lobby: p_author_lobby,
      clip: clip
    }
  end

  test "a member viewer gets the inline player, no autoplay, with a poster frame", ctx do
    msg = post!(ctx.home, ctx.p_member, "Here are the cuts.\n/chat/attachments/#{ctx.clip.id}")

    conn = init_test_session(ctx.conn, current_user_id: ctx.member.id)
    {:ok, view, _html} = live(conn, "/chat/#{ctx.home.slug}")

    assert has_element?(view, @player)
    refute has_element?(view, "[data-role=video-attachment] video[autoplay]")

    [video] = doc(view) |> LazyHTML.query(@player) |> Enum.to_list()
    [src] = LazyHTML.attribute(video, "src")
    poster = LazyHTML.attribute(video, "poster")
    assert poster != [] or src =~ "#t="
    assert src =~ "/chat/attachments/#{ctx.clip.id}"

    # The bare link line is replaced by the player; the prose stays.
    assert has_element?(
             view,
             ~s([data-message-id="#{msg.id}"] .chat-markdown),
             "Here are the cuts."
           )

    refute has_element?(
             view,
             ~s([data-message-id="#{msg.id}"] .chat-markdown a[href="/chat/attachments/#{ctx.clip.id}"])
           )
  end

  test "a viewer outside the clip's space sees the plain link and no player", ctx do
    post!(ctx.lobby, ctx.p_author_lobby, "look: [clip](/chat/attachments/#{ctx.clip.id})")

    conn = init_test_session(ctx.conn, current_user_id: ctx.outsider.id)
    {:ok, view, _html} = live(conn, "/chat/#{ctx.lobby.slug}")

    refute has_element?(view, "[data-role=video-attachment]")
    assert has_element?(view, ~s(a[href="/chat/attachments/#{ctx.clip.id}"]))

    # The download route denies the same viewer.
    resp = get(conn, "/chat/attachments/#{ctx.clip.id}")
    assert resp.status == 404
  end

  test "a link posted live (message_posted broadcast) renders the player without a reload",
       ctx do
    conn = init_test_session(ctx.conn, current_user_id: ctx.member.id)
    {:ok, view, _html} = live(conn, "/chat/#{ctx.home.slug}")
    refute has_element?(view, "[data-role=video-attachment]")

    uri = PlatformWeb.Endpoint.struct_url()
    url = "#{uri.scheme}://#{uri.host}:#{uri.port}/chat/attachments/#{ctx.clip.id}"
    post!(ctx.home, ctx.p_member, url)

    assert has_element?(view, @player)
  end

  # Task 01a1655c stage 5: the SENDER's own LiveView. Its broadcast is sent
  # `from_pid: self()`, so the send_message handler itself must resolve the
  # link; no second session and no reload here.
  describe "the sender's own session" do
    defp latest_message!(space) do
      [msg | _] = Chat.list_messages(space.id, limit: 1)
      msg
    end

    defp send_as_member(ctx, text) do
      conn = init_test_session(ctx.conn, current_user_id: ctx.member.id)
      {:ok, view, _html} = live(conn, "/chat/#{ctx.home.slug}")
      refute has_element?(view, "[data-role=video-attachment]")

      view
      |> form("#compose-form", %{"compose" => %{"text" => text}})
      |> render_submit()

      {view, latest_message!(ctx.home)}
    end

    defp assert_one_player_stripped(view, msg, clip) do
      row = ~s([data-message-id="#{msg.id}"])
      assert has_element?(view, "#{row} [data-role=video-attachment] video")

      assert doc(view) |> LazyHTML.query("#{row} [data-role=video-attachment]") |> Enum.count() ==
               1

      assert has_element?(view, "#{row} .chat-markdown", "take a look")
      refute has_element?(view, "#{row} .chat-markdown", "/chat/attachments/#{clip.id}")

      # Stage 5: the file line carries main's Download affordance.
      assert has_element?(
               view,
               ~s(#{row} [data-role=clip-file-line] a[download][href="/chat/attachments/#{clip.id}"])
             )
    end

    test "a relative attachment path renders the player without a reload", ctx do
      {view, msg} = send_as_member(ctx, "take a look\n/chat/attachments/#{ctx.clip.id}")
      assert msg.participant_id == ctx.p_member.id
      assert_one_player_stripped(view, msg, ctx.clip)
    end

    test "a bare absolute URL renders the player without a reload", ctx do
      uri = PlatformWeb.Endpoint.struct_url()
      url = "#{uri.scheme}://#{uri.host}:#{uri.port}/chat/attachments/#{ctx.clip.id}"

      {view, msg} = send_as_member(ctx, "take a look\n#{url}")
      assert_one_player_stripped(view, msg, ctx.clip)
    end

    test "an edit that adds the link renders the player without a reload", ctx do
      {view, msg} = send_as_member(ctx, "take a look")
      refute has_element?(view, "[data-role=video-attachment]")

      render_hook(view, "save_edit", %{
        "message_id" => msg.id,
        "body" => "take a look\n/chat/attachments/#{ctx.clip.id}",
        "removes_content" => "false"
      })

      assert_one_player_stripped(view, msg, ctx.clip)
    end
  end
end
