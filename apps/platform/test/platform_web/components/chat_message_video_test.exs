defmodule PlatformWeb.Components.ChatMessageVideoTest do
  @moduledoc """
  Task 01a120be stage 3: a received video plays in place.

  Task 01a1655c stage 2 adds the end-to-end render proof: a video an agent
  uploaded (attachment_upload_start + presigned POST) and then posted with
  send_media attachment_ids renders the same inline player. That test reads
  the database, hence DataCase; it is not async because it points the
  global attachments root at a temp dir.
  """
  use Platform.DataCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  defp row_html(attachments, content \\ "the clip", msg_id \\ "msg-1") do
    assigns = %{
      msg: %{
        id: msg_id,
        space_id: "space-1",
        participant_id: "p-1",
        content: content,
        content_type: "text",
        canvas_id: nil,
        inserted_at: ~U[2026-10-09 10:00:00.000000Z],
        day_label: nil,
        reactions: [],
        versions_count: 1,
        corrects_message_id: nil,
        metadata: %{}
      },
      attachments_map: %{msg_id => attachments}
    }

    rendered_to_string(~H"""
    <PlatformWeb.Components.ChatMessage.chat_message
      dom_id="row-1"
      msg={@msg}
      current_participant={nil}
      agent_participant_ids={MapSet.new()}
      participants_map={%{"p-1" => %{name: "Alex", avatar_url: nil, avatar_seed: nil}}}
      quick_emojis={[]}
      pinned_message_ids={MapSet.new()}
      canvases_by_id={%{}}
      attachments_map={@attachments_map}
      thread_previews={%{}}
      expanded_threads={MapSet.new()}
      inline_thread_messages={%{}}
    />
    """)
  end

  @video %{
    id: "0199aaaa-0000-7000-8000-000000000001",
    filename: "launch-walkthrough.mov",
    content_type: "video/quicktime",
    byte_size: 900_000_000
  }

  test "a video renders <video preload=metadata> without autoplay, with the size and Download" do
    html = row_html([@video])
    doc = LazyHTML.from_fragment(html)

    [video] = doc |> LazyHTML.query("video") |> Enum.to_list()
    assert LazyHTML.attribute(video, "preload") == ["metadata"]
    # Task 01a1655c stage 3: no stored poster, so a #t=0.1 fragment paints the first frame.
    assert LazyHTML.attribute(video, "src") == ["/chat/attachments/#{@video.id}#t=0.1"]
    assert LazyHTML.attribute(video, "autoplay") == []
    assert LazyHTML.attribute(video, "controls") != []

    line = doc |> LazyHTML.query(~s([data-role="clip-file-line"])) |> LazyHTML.text()
    assert line =~ "900 MB"
    assert line =~ "launch-walkthrough"
    assert line =~ ".mov"

    # Task 01a1655c stage 5: an attached clip's file line carries Download.
    assert [_] =
             doc
             |> LazyHTML.query(
               ~s([data-role="clip-file-line"] a[download][href="/chat/attachments/#{@video.id}"])
             )
             |> Enum.to_list()
  end

  test "a video posted with send_media attachment_ids renders the inline player" do
    root = Platform.TestTemp.mkdir!("chat_message_video_test_uploads")
    prev = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      Application.put_env(:platform, :chat_attachments_root, prev)
      File.rm_rf(root)
    end)

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Video",
        slug: "video-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, agent} =
      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(%{
        slug: "agent-#{System.unique_integer([:positive])}",
        name: "Clip Agent",
        status: "active"
      })
      |> Repo.insert()

    {:ok, participant} =
      Platform.Chat.add_agent_participant(space.id, agent, display_name: agent.name)

    context = %{space_id: space.id, agent_id: agent.id, agent_participant_id: participant.id}
    bytes = :crypto.strong_rand_bytes(256)

    {:ok, started} =
      Platform.Chat.Attachments.ToolHandlers.upload_start(
        %{
          "space_id" => space.id,
          "filename" => "clip.mp4",
          "content_type" => "video/mp4",
          "byte_size" => byte_size(bytes)
        },
        context
      )

    pending = Repo.get!(Platform.Chat.Attachment, started.id)

    {:ok, _} =
      Platform.Chat.AttachmentStorage.Adapter.LocalDisk.persist(
        pending.storage_key,
        {:binary, bytes}
      )

    {:ok, %{id: attachment_id}} =
      Platform.Chat.Attachments.ToolHandlers.finalize_pending(started.id, %{
        byte_size: byte_size(bytes),
        content_hash: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      })

    {:ok, %{message_id: message_id}} =
      Platform.Federation.ToolSurface.execute(
        "send_media",
        %{"space_id" => space.id, "attachment_ids" => [attachment_id], "content" => "the clip"},
        context
      )

    %{^message_id => [%{id: ^attachment_id, content_type: "video/mp4"}] = rows} =
      Platform.Chat.list_attachments_for_messages([message_id])

    doc = LazyHTML.from_fragment(row_html(rows))

    assert [video] =
             doc |> LazyHTML.query(~s([data-role="video-attachment"] video)) |> Enum.to_list()

    assert LazyHTML.attribute(video, "src") == ["/chat/attachments/#{attachment_id}#t=0.1"]
  end

  # Rung 13 stage 3: the paperclip chip became a file card that opens the
  # in-app viewer (no new tab).
  test "a non-video file renders the file card" do
    html = row_html([%{@video | content_type: "application/pdf", filename: "spec.pdf"}])
    refute html =~ "<video"
    refute html =~ "hero-paper-clip"
    refute html =~ ~s(target="_blank")
    assert html =~ ~s(data-role="file-card")
    assert html =~ "spec"
    assert html =~ ".pdf"
  end

  # ── Task 01a1655c stage 4: canvas fidelity ──────────────────────────────

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp q(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.to_list()

  defp text_of(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  defp att_link(att), do: "/chat/attachments/#{att.id}"

  @clip2 %{
    id: "0199aaaa-0000-7000-8000-000000000002",
    filename: "clip-02.mp4",
    content_type: "video/mp4",
    byte_size: 58_000_000,
    metadata: %{"width" => 1080, "height" => 1920, "duration" => 42}
  }

  @image %{
    id: "0199aaaa-0000-7000-8000-000000000003",
    filename: "still.png",
    content_type: "image/png",
    byte_size: 2_000
  }

  describe "link stripping" do
    test "a resolved link alone on its line is dropped from the rendered text" do
      d = doc(row_html([@video], "Here are the cuts.\n#{att_link(@video)}"))

      assert text_of(d, ".chat-markdown") =~ "Here are the cuts."
      refute text_of(d, ".chat-markdown") =~ @video.id
      assert [_] = q(d, ~s([data-role="video-attachment"]))
    end

    test "a mid-sentence link stays in the text and the player follows it" do
      d = doc(row_html([@video], "watch #{att_link(@video)} before standup"))

      assert text_of(d, ".chat-markdown") =~ @video.id
      assert text_of(d, ".chat-markdown") =~ "before standup"
      assert [_] = q(d, ~s([data-role="video-attachment"]))
    end

    test "an unresolved link is never stripped" do
      other = Ecto.UUID.generate()
      d = doc(row_html([], "/chat/attachments/#{other}"))

      assert text_of(d, ".chat-markdown") =~ other
      assert q(d, ~s([data-role="video-attachment"])) == []
    end
  end

  describe "one player per attachment" do
    setup do
      user =
        %Platform.Accounts.User{}
        |> Platform.Accounts.User.changeset(%{
          email: "clip-#{System.unique_integer([:positive])}@example.com",
          name: "Viewer",
          oidc_sub: "clip-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, space} =
        Platform.Chat.create_space(%{
          name: "Clips",
          slug: "clips-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, p} =
        Platform.Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          joined_at: DateTime.utc_now()
        })

      att = fn attrs ->
        {:ok, a} =
          Platform.Chat.create_attachment(
            Map.merge(
              %{
                space_id: space.id,
                filename: "clip.mp4",
                content_type: "video/mp4",
                byte_size: 10,
                storage_key: "k-#{System.unique_integer([:positive])}"
              },
              attrs
            )
          )

        a
      end

      post = fn content ->
        {:ok, msg} =
          Platform.Chat.post_message(%{
            space_id: space.id,
            participant_id: p.id,
            content_type: "text",
            content: content
          })

        msg
      end

      %{viewer: {:user, user.id}, att: att, post: post}
    end

    defp render_resolved(msg, real, viewer) do
      map =
        %{msg.id => real}
        |> Platform.Chat.AttachmentLinks.merge(
          Platform.Chat.AttachmentLinks.resolve_for_viewer([msg], viewer)
        )

      doc(row_html(Map.get(map, msg.id, []), msg.content, msg.id))
    end

    test "the same link twice gives one player", %{viewer: viewer, att: att, post: post} do
      a = att.(%{})
      msg = post.("#{att_link(a)}\nand again #{att_link(a)}")

      assert [_] = q(render_resolved(msg, [], viewer), ~s([data-role="video-attachment"]))
    end

    test "a link to a file that is also a real attachment gives one player",
         %{viewer: viewer, att: att, post: post} do
      a = att.(%{})
      msg = post.(att_link(a))

      assert [_] = q(render_resolved(msg, [a], viewer), ~s([data-role="video-attachment"]))
    end

    test "two clips stack as two players with two file lines",
         %{viewer: viewer, att: att, post: post} do
      a = att.(%{filename: "clip-01.mp4"})
      b = att.(%{filename: "clip-02.mp4"})
      msg = post.("Two cuts:\n#{att_link(a)}\n#{att_link(b)}")
      d = render_resolved(msg, [], viewer)

      assert length(q(d, ~s([data-role="video-attachment"]))) == 2
      lines = q(d, ~s([data-role="clip-file-line"]))
      assert length(lines) == 2
      assert Enum.map(lines, &LazyHTML.text/1) |> Enum.map(&(&1 =~ "clip-0")) == [true, true]
    end
  end

  describe "file line" do
    test "holds the filename, size and stored duration, with the stem truncating" do
      d = doc(row_html([@clip2]))

      line = text_of(d, ~s([data-role="clip-file-line"]))
      assert line =~ "clip-02"
      assert line =~ ".mp4"
      assert line =~ "58 MB"
      assert text_of(d, ~s([data-role="clip-duration"])) =~ "0:42"

      [line_el] = q(d, ~s([data-role="clip-file-line"]))
      [cls] = LazyHTML.attribute(line_el, "class")
      assert "text-subtle" in String.split(cls)
      assert "text-[13px]" in String.split(cls)

      assert [_] = q(d, ~s([data-role="clip-file-line"] .truncate))
    end

    test "an unknown duration renders a hidden slot the hook fills" do
      d = doc(row_html([@video]))
      [dur] = q(d, ~s([data-role="clip-duration"]))
      [cls] = LazyHTML.attribute(dur, "class")
      assert "hidden" in String.split(cls)
    end
  end

  describe "frame" do
    test "has no border, a base-300 rounded-box frame and the ChatClip hook" do
      d = doc(row_html([@video]))

      [card] = q(d, ~s([data-role="video-attachment"]))
      assert LazyHTML.attribute(card, "phx-hook") == ["ChatClip"]
      assert LazyHTML.attribute(card, "phx-update") == ["ignore"]
      [card_cls] = LazyHTML.attribute(card, "class")
      assert "sm:max-w-[480px]" in String.split(card_cls)

      [frame] = q(d, ~s([data-role="clip-frame"]))
      [cls] = LazyHTML.attribute(frame, "class")
      tokens = String.split(cls)
      assert "bg-base-300" in tokens
      assert "rounded-box" in tokens
      assert "max-h-[60vh]" in tokens

      for el <- [card, frame], [c] = LazyHTML.attribute(el, "class"), token <- String.split(c) do
        refute token == "border" or String.starts_with?(token, "border-"), token
      end
    end

    test "reserves the stored aspect ratio when metadata has width and height" do
      [frame] = q(doc(row_html([@clip2])), ~s([data-role="clip-frame"]))
      [style] = LazyHTML.attribute(frame, "style")
      assert style =~ "aspect-ratio: 1080 / 1920"
    end
  end

  test "the fallback card holds the exact copy and a Download link to the file" do
    d = doc(row_html([@video]))

    assert [fallback] = q(d, ~s([data-role="clip-fallback"]))
    assert LazyHTML.text(fallback) =~ "Can't play this video"

    assert [dl] = q(d, ~s([data-role="clip-fallback"] a[download]))
    assert LazyHTML.attribute(dl, "href") == ["/chat/attachments/#{@video.id}"]
    assert LazyHTML.text(dl) =~ "Download"

    assert [_] = q(d, ~s([data-role="clip-fallback"] .text-error))
    [cls] = LazyHTML.attribute(fallback, "class")
    refute "text-error" in String.split(cls)
  end

  test "a linked image renders in the gallery with no clip file line" do
    d = doc(row_html([@image], att_link(@image)))

    assert [_] = q(d, ".image-gallery .gallery-item")
    assert q(d, ~s([data-role="clip-file-line"])) == []
    assert q(d, ".chat-markdown") == []
  end
end
