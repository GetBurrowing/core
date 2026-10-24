defmodule PlatformWeb.ChatViewerLiveTest do
  @moduledoc """
  Redesign rung 13 stage 2: the in-app viewer replaces the image lightbox.
  The client names a message and an attachment (or a card index); the server
  resolves the item from what this viewer may already read.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Prototypes
  alias PlatformWeb.Components.ChatViewer

  defp origin do
    uri = PlatformWeb.Endpoint.struct_url()
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end

  defp channel!(name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "#{name}-#{System.unique_integer([:positive])}",
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

  defp attach!(msg, filename, content_type, byte_size) do
    {:ok, att} =
      Chat.create_attachment(%{
        space_id: msg.space_id,
        message_id: msg.id,
        filename: filename,
        content_type: content_type,
        byte_size: byte_size,
        storage_key: "viewer-#{System.unique_integer([:positive])}"
      })

    att
  end

  defp viewer_open?(view), do: has_element?(view, "#chat-viewer[data-state=open]")

  describe "component modes" do
    defp render_viewer(viewer) do
      assigns = %{viewer: viewer}
      rendered_to_string(~H"<ChatViewer.chat_viewer viewer={@viewer} />")
    end

    defp query(html, selector),
      do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.to_list()

    defp base(mode, extra) do
      Map.merge(
        %{
          mode: mode,
          filename: "spec.pdf",
          meta: "PDF · 2.1 MB",
          src: "/chat/attachments/a1",
          download_url: "/chat/attachments/a1",
          share_path: "/chat/attachments/a1",
          pdf?: false
        },
        extra
      )
    end

    test "closed is an empty hidden root with no fullscreen marker" do
      html = render_viewer(nil)
      assert [_] = query(html, "#chat-viewer[data-state=closed][hidden]")
      refute html =~ "data-fullscreen-viewer"
      refute html =~ "role=\"dialog\""
    end

    test "every mode has back and share; never a sheet" do
      for mode <- ["image", "video", "file", "prototype", "link"] do
        html = render_viewer(base(mode, %{url: "https://example.com/x", host: "example.com"}))

        assert [_] =
                 query(html, "#chat-viewer[role=dialog][aria-modal=true][data-fullscreen-viewer]")

        assert [_] =
                 query(html, ~s(#chat-viewer [data-role=viewer-back][aria-label="Back to chat"]))

        assert [_] = query(html, "#chat-viewer [data-role=viewer-share][aria-label=Share]")
        assert [] = query(html, "#chat-viewer .sheet-backdrop")
        assert [] = query(html, "#chat-viewer .sheet-handle")
        assert html =~ "swipe down or ← to go back"
        assert html =~ "Esc or ← to go back"
      end
    end

    test "stage 4: data-mode per mode; gestures owned by the bar, and by the stage only for media" do
      for mode <- ["image", "video", "file", "prototype", "link"] do
        html = render_viewer(base(mode, %{url: "https://example.com/x", host: "example.com"}))
        assert [_] = query(html, ~s(#chat-viewer[data-mode="#{mode}"]))
        assert [_] = query(html, "#chat-viewer [data-role=viewer-bar].touch-none")

        stage_touch = query(html, "#chat-viewer [data-role=viewer-stage].touch-none")

        if mode in ["image", "video"],
          do: assert([_] = stage_touch),
          else: assert([] = stage_touch)
      end
    end

    test "download only where a file exists" do
      for mode <- ["image", "video", "file"] do
        assert [_] = query(render_viewer(base(mode, %{})), "[data-role=viewer-download]")
      end

      assert [] =
               query(
                 render_viewer(
                   base("link", %{url: "https://example.com/x", host: "example.com"})
                 ),
                 "[data-role=viewer-download]"
               )

      assert [] =
               query(
                 render_viewer(base("prototype", %{src: "/proto/p1/3/", download_url: nil})),
                 "[data-role=viewer-download]"
               )
    end

    test "image and video sit on the viewer ground; the rest on base-100" do
      assert [_] =
               query(render_viewer(base("image", %{})), "#chat-viewer.bg-viewer.text-on-viewer")

      assert [_] = query(render_viewer(base("video", %{})), "#chat-viewer.bg-viewer")
      assert [_] = query(render_viewer(base("file", %{})), "#chat-viewer.bg-base-100")
    end

    test "a PDF frames the same-origin attachment; any other file gets a panel" do
      pdf = render_viewer(base("file", %{pdf?: true}))
      assert [_] = query(pdf, ~s(iframe[data-role=viewer-pdf][src="/chat/attachments/a1"]))

      zip = render_viewer(base("file", %{filename: "bundle.zip", meta: "ZIP · 3 KB"}))
      assert [] = query(zip, "iframe")
      assert [_] = query(zip, "[data-role=viewer-file-panel]")
      assert [_] = query(zip, ~s([data-role=viewer-file-download][href="/chat/attachments/a1"]))
      assert zip =~ "ZIP · 3 KB"
    end

    test "a prototype frame is sandboxed like PrototypeFrame" do
      html = render_viewer(base("prototype", %{src: "/proto/p1/3/", download_url: nil}))

      assert [_] =
               query(
                 html,
                 ~s(iframe[data-role=viewer-prototype][src="/proto/p1/3/"][sandbox=allow-scripts][referrerpolicy=no-referrer])
               )
    end

    test "link mode: host, full URL in mono, and Open in browser" do
      html =
        render_viewer(
          base("link", %{
            url: "https://example.com/docs/a",
            host: "example.com",
            src: nil,
            download_url: nil
          })
        )

      assert [_] = query(html, "[data-role=viewer-link-url].font-mono")

      assert [_] =
               query(
                 html,
                 ~s(a[data-role=viewer-open-in-browser][href="https://example.com/docs/a"][target=_blank][rel="noopener noreferrer"])
               )
    end
  end

  describe "in ChatLive" do
    setup %{conn: conn} do
      a = user!("Viewer A")
      room = channel!("viewer-room")
      p_a = seat!(room, a)
      conn = init_test_session(conn, current_user_id: a.id)
      %{conn: conn, a: a, room: room, p_a: p_a}
    end

    test "a gallery tile opens image mode, pages, and closes", ctx do
      msg = post!(ctx.room, ctx.p_a, "four shots")
      [i1, i2, _i3, _i4] = for n <- 1..4, do: attach!(msg, "shot-#{n}.png", "image/png", 1200)

      {:ok, view, _html} = live(ctx.conn, "/chat/#{ctx.room.slug}")
      refute viewer_open?(view)
      refute has_element?(view, "[data-fullscreen-viewer]")
      assert has_element?(view, "#gallery-#{msg.id}-#{i1.id}[data-viewer-open]")

      view |> element("#gallery-#{msg.id}-#{i2.id}") |> render_click()
      assert has_element?(view, "#chat-viewer[data-state=open][data-mode=image]")
      assert has_element?(view, "#chat-viewer [data-role=viewer-filename]", "shot-2.png")
      assert has_element?(view, "#chat-viewer [data-role=viewer-count]", "2 of 4")
      assert has_element?(view, ~s(#chat-viewer img[src="/chat/attachments/#{i2.id}"]))
      refute has_element?(view, "#chat-viewer .sheet-backdrop")
      refute has_element?(view, "#chat-viewer .sheet-handle")

      view |> element("#chat-viewer [data-role=viewer-next]") |> render_click()
      assert has_element?(view, "#chat-viewer [data-role=viewer-count]", "3 of 4")

      view |> element("#chat-viewer [data-role=viewer-back]") |> render_click()
      refute viewer_open?(view)
      assert has_element?(view, "#chat-viewer[data-state=closed]")
    end

    test "a PDF opens in a frame, a zip opens the file panel", ctx do
      msg = post!(ctx.room, ctx.p_a, "docs")
      pdf = attach!(msg, "spec-final.pdf", "application/pdf", 2_100_000)
      zip = attach!(msg, "bundle.zip", "application/zip", 3000)

      {:ok, view, _html} = live(ctx.conn, "/chat/#{ctx.room.slug}")

      render_hook(view, "viewer_open", %{"message_id" => msg.id, "attachment_id" => pdf.id})
      assert has_element?(view, "#chat-viewer[data-mode=file]")
      assert has_element?(view, ~s(#chat-viewer iframe[src="/chat/attachments/#{pdf.id}"]))
      assert has_element?(view, "#chat-viewer [data-role=viewer-meta]", "PDF · ")

      render_hook(view, "viewer_open", %{"message_id" => msg.id, "attachment_id" => zip.id})
      assert has_element?(view, "#chat-viewer [data-role=viewer-file-panel]")
      refute has_element?(view, "#chat-viewer iframe")
    end

    test "a non-PDF file named .pdf is never framed (content type decides)", ctx do
      msg = post!(ctx.room, ctx.p_a, "looks like a pdf")
      html_file = attach!(msg, "invoice.pdf", "text/html", 120)

      {:ok, view, _html} = live(ctx.conn, "/chat/#{ctx.room.slug}")

      html =
        render_hook(view, "viewer_open", %{
          "message_id" => msg.id,
          "attachment_id" => html_file.id
        })

      assert has_element?(view, "#chat-viewer[data-mode=file] [data-role=viewer-file-panel]")
      refute has_element?(view, "#chat-viewer iframe")
      refute html =~ ~r{<iframe[^>]*/chat/attachments/#{html_file.id}}
    end

    test "an attachment id from another message, or a forged one, opens nothing", ctx do
      m1 = post!(ctx.room, ctx.p_a, "one")
      m2 = post!(ctx.room, ctx.p_a, "two")
      other = attach!(m2, "x.png", "image/png", 10)
      _ = attach!(m1, "y.png", "image/png", 10)

      {:ok, view, _html} = live(ctx.conn, "/chat/#{ctx.room.slug}")

      render_hook(view, "viewer_open", %{"message_id" => m1.id, "attachment_id" => other.id})
      refute viewer_open?(view)

      render_hook(view, "viewer_open", %{"message_id" => m1.id, "url" => "https://evil.example/"})
      refute viewer_open?(view)
    end

    test "cards open link and prototype modes; a locked prototype opens nothing", ctx do
      scratch_storage!("chat_viewer_live_test")
      set_settings!(%{enabled: true, who_may_publish: "members", retention_days: 90})
      org_id = tenant_org_id("viewer-live-#{System.unique_integer([:positive])}")
      member!(ctx.a, org_id)

      {:ok, %{prototype: proto}} =
        Prototypes.publish(
          agent_publisher(agent!()),
          %{org_id: org_id, name: "Burrow masters"},
          {:files, bundle_files("v1")}
        )

      other_org = tenant_org_id("viewer-other-#{System.unique_integer([:positive])}")

      {:ok, %{prototype: hidden}} =
        Prototypes.publish(
          agent_publisher(agent!()),
          %{org_id: other_org, name: "Confidential proto"},
          {:files, bundle_files("v1")}
        )

      m_link = post!(ctx.room, ctx.p_a, "https://example.com/docs/a")
      m_proto = post!(ctx.room, ctx.p_a, "#{origin()}/proto/#{proto.id}/1/")
      m_hidden = post!(ctx.room, ctx.p_a, "#{origin()}/proto/#{hidden.id}/1/")

      {:ok, view, _html} = live(ctx.conn, "/chat/#{ctx.room.slug}")

      render_hook(view, "viewer_open", %{"message_id" => m_link.id, "card" => "0"})
      assert has_element?(view, "#chat-viewer[data-mode=link]")

      assert has_element?(
               view,
               "#chat-viewer [data-role=viewer-open-in-browser]",
               "Open in browser"
             )

      refute has_element?(view, "#chat-viewer [data-role=viewer-download]")

      render_hook(view, "viewer_open", %{"message_id" => m_proto.id, "card" => "0"})
      assert has_element?(view, "#chat-viewer[data-mode=prototype]")

      assert has_element?(
               view,
               ~s(#chat-viewer iframe[sandbox=allow-scripts][src="/proto/#{proto.id}/1/"])
             )

      render_hook(view, "viewer_close", %{})
      view |> element("#link-card-#{m_proto.id}-0") |> render_click()
      assert has_element?(view, ~s(#chat-viewer iframe[src^="/proto/#{proto.id}/"]))
      render_hook(view, "viewer_close", %{})

      # A mid-sentence same-host anchor, intercepted by the hook.
      render_hook(view, "viewer_open_link", %{"href" => "#{origin()}/proto/#{proto.id}/latest/"})
      assert has_element?(view, ~s(#chat-viewer iframe[src="/proto/#{proto.id}/latest/"]))
      render_hook(view, "viewer_close", %{})

      render_hook(view, "viewer_open_link", %{"href" => "#{origin()}/proto/#{hidden.id}/1/"})
      refute viewer_open?(view)

      render_hook(view, "viewer_open_link", %{
        "href" => "https://example.test/proto/#{proto.id}/1/"
      })

      refute viewer_open?(view)

      assert has_element?(view, ~s(#link-card-#{m_hidden.id}-0[data-kind=locked]))
      refute has_element?(view, ~s(#link-card-#{m_hidden.id}-0[phx-click]))
      html = render_hook(view, "viewer_open", %{"message_id" => m_hidden.id, "card" => "0"})
      refute viewer_open?(view)
      refute html =~ "Confidential proto"
    end

    test "a file attachment is a card that opens the viewer, never a new tab", ctx do
      msg = post!(ctx.room, ctx.p_a, "the spec")
      pdf = attach!(msg, "spec-final-with-a-very-long-name.pdf", "application/pdf", 2_000_000)
      zip = attach!(msg, "bundle.zip", "application/zip", 3000)

      {:ok, view, _html} = live(ctx.conn, "/chat/#{ctx.room.slug}")
      card = "#file-card-#{msg.id}-#{pdf.id}"

      assert has_element?(
               view,
               "#{card}[data-role=file-card] .truncate",
               "spec-final-with-a-very-long-name"
             )

      assert has_element?(view, "#{card} .shrink-0", ".pdf")
      assert has_element?(view, "#{card} [data-role=link-card-meta]", "PDF · ")
      refute has_element?(view, ~s([data-message-id="#{msg.id}"] [target="_blank"]))

      # Stage 4: every viewer source carries a stable id, which is what the
      # hook rings for 1s on close and restores focus to.
      sources =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#message-list [data-viewer-open]")
        |> Enum.to_list()

      assert sources != []
      ids = Enum.map(sources, &List.first(LazyHTML.attribute(&1, "id")))
      refute Enum.any?(ids, &(&1 in [nil, ""]))

      view |> element(card) |> render_click()
      assert has_element?(view, "#chat-viewer[data-mode=file] iframe[data-role=viewer-pdf]")

      view |> element("#chat-viewer [data-role=viewer-back]") |> render_click()
      view |> element("#file-card-#{msg.id}-#{zip.id}") |> render_click()
      assert has_element?(view, "#chat-viewer [data-role=viewer-file-panel]")
      assert has_element?(view, "#chat-viewer [data-role=viewer-file-download]", "Download")
    end

    test "a link to a file attached to the same message gives one card", ctx do
      msg = post!(ctx.room, ctx.p_a, "placeholder")
      pdf = attach!(msg, "spec.pdf", "application/pdf", 10)

      {:ok, msg} =
        msg
        |> Ecto.Changeset.change(content: "#{origin()}/chat/attachments/#{pdf.id}")
        |> Platform.Repo.update()

      {:ok, view, _html} = live(ctx.conn, "/chat/#{ctx.room.slug}")
      assert has_element?(view, "#file-card-#{msg.id}-#{pdf.id}")
      refute has_element?(view, ~s([data-message-id="#{msg.id}"] .chat-markdown))
    end

    test "link, image and video cards open their viewer modes", ctx do
      m_link = post!(ctx.room, ctx.p_a, "https://example.com/docs/a")
      m_img = post!(ctx.room, ctx.p_a, "https://example.com/shots/hero.png")
      m_vid = post!(ctx.room, ctx.p_a, "https://example.com/clips/demo.mp4")

      {:ok, view, _html} = live(ctx.conn, "/chat/#{ctx.room.slug}")

      view |> element("#link-card-#{m_link.id}-0") |> render_click()

      assert has_element?(
               view,
               "#chat-viewer[data-mode=link] [data-role=viewer-link-url]",
               "https://example.com/docs/a"
             )

      assert has_element?(
               view,
               "#chat-viewer [data-role=viewer-open-in-browser]",
               "Open in browser"
             )

      render_hook(view, "viewer_close", %{})

      view |> element("#link-card-#{m_img.id}-0") |> render_click()

      assert has_element?(
               view,
               ~s(#chat-viewer[data-mode=image] img[src="https://example.com/shots/hero.png"])
             )

      render_hook(view, "viewer_close", %{})

      assert has_element?(view, "#link-card-#{m_vid.id}-0 video[controls]")
      refute has_element?(view, "#link-card-#{m_vid.id}-0 video[autoplay]")
      view |> element("#link-card-#{m_vid.id}-0-expand") |> render_click()

      assert has_element?(
               view,
               ~s(#chat-viewer[data-mode=video] video[src="https://example.com/clips/demo.mp4"])
             )

      refute has_element?(view, "#chat-viewer video[autoplay]")
    end
  end
end
