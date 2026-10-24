defmodule PlatformWeb.ChatLinkCardsLiveTest do
  @moduledoc """
  Redesign rung 13 stage 1: links in message text render as the card family,
  per viewer. Hosts come from `PlatformWeb.Endpoint`; foreign hosts are
  example.com.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Prototypes

  defp origin do
    uri = PlatformWeb.Endpoint.struct_url()
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end

  defp channel!(name, kind \\ "channel") do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "#{name}-#{System.unique_integer([:positive])}",
        kind: kind
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

  defp canvas!(space, participant, title) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => title,
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{"id" => "root", "type" => "stack", "props" => %{}, "children" => []},
          "theme" => %{},
          "bindings" => %{},
          "meta" => %{}
        }
      })

    canvas
  end

  defp msg_sel(msg, rest), do: ~s([data-message-id="#{msg.id}"] #{rest})

  setup %{conn: conn} do
    scratch_storage!("chat_link_cards_live_test")
    set_settings!(%{enabled: true, who_may_publish: "members", retention_days: 90})

    org_id = tenant_org_id("link-cards-live-#{System.unique_integer([:positive])}")
    a = user!("Reader A")
    b = user!("Reader B")
    member!(a, org_id)

    room = channel!("frontend-design")
    # A private group B is not in, so B's sidebar does not list it either.
    vault = channel!("pricing-war-room", "group")
    p_a = seat!(room, a)
    _ = seat!(room, b)
    p_a_vault = seat!(vault, a)

    here = canvas!(room, p_a, "Q4 launch plan")
    secret = canvas!(vault, p_a_vault, "Secret pricing canvas")

    {:ok, %{prototype: proto}} =
      Prototypes.publish(
        agent_publisher(agent!()),
        %{org_id: org_id, name: "Burrow masters"},
        {:files, bundle_files("v1")}
      )

    %{conn: conn, a: a, b: b, room: room, p_a: p_a, here: here, secret: secret, proto: proto}
  end

  test "each URL kind renders its card for a reader who may see it", ctx do
    m_canvas = post!(ctx.room, ctx.p_a, "#{origin()}/canvases/#{ctx.here.id}")
    m_proto = post!(ctx.room, ctx.p_a, "#{origin()}/proto/#{ctx.proto.id}/1/")
    m_mid = post!(ctx.room, ctx.p_a, "see https://example.com/pricing/plans for details")
    m_link = post!(ctx.room, ctx.p_a, "https://example.com/pricing/plans")
    m_img = post!(ctx.room, ctx.p_a, "https://example.com/shots/hero.png")
    m_vid = post!(ctx.room, ctx.p_a, "https://example.com/clips/demo.mp4")
    m_other = post!(ctx.room, ctx.p_a, "#{origin()}/canvases/#{ctx.secret.id}")

    conn = init_test_session(ctx.conn, current_user_id: ctx.a.id)
    {:ok, view, _html} = live(conn, "/chat/#{ctx.room.slug}")

    # Canvas: title + "Canvas · #space", and the bare line is gone.
    assert has_element?(
             view,
             msg_sel(m_canvas, "[data-role=link-card][data-kind=canvas]"),
             "Q4 launch plan"
           )

    assert has_element?(
             view,
             msg_sel(m_canvas, "[data-role=link-card-meta]"),
             "Canvas · #frontend-design"
           )

    refute has_element?(view, msg_sel(m_canvas, ".chat-markdown"))

    # Prototype: name, "Prototype · v1", outline Clickable badge; opens the
    # viewer (stage 3), never a new tab.
    assert has_element?(
             view,
             msg_sel(
               m_proto,
               ~s(button[data-role=link-card][data-kind=prototype][phx-click=viewer_open][phx-value-card="0"])
             ),
             "Burrow masters"
           )

    assert has_element?(view, msg_sel(m_proto, "[data-role=link-card-meta]"), "Prototype · v1")
    assert has_element?(view, msg_sel(m_proto, ".badge.badge-outline"), "Clickable")
    refute has_element?(view, msg_sel(m_proto, "[data-kind=prototype][target]"))

    # Mid-sentence: the sender's words stay, the card follows.
    assert has_element?(view, msg_sel(m_mid, ".chat-markdown"), "for details")
    assert has_element?(view, msg_sel(m_mid, "[data-role=link-card][data-kind=link]"))

    # Bare link: host + path title, host second line, text line replaced.
    assert has_element?(
             view,
             msg_sel(m_link, "[data-role=link-card][data-kind=link] [data-role=link-card-title]"),
             "example.com/pricing/plans"
           )

    assert has_element?(
             view,
             msg_sel(m_link, "[data-role=link-card-meta] .shrink-0"),
             "example.com"
           )

    refute has_element?(view, msg_sel(m_link, ".chat-markdown"))

    # Image and video render inline as media.
    assert has_element?(
             view,
             msg_sel(
               m_img,
               ~s([data-role=link-media][data-kind=image] img[loading=lazy][referrerpolicy=no-referrer][src="https://example.com/shots/hero.png"])
             )
           )

    assert has_element?(
             view,
             msg_sel(
               m_vid,
               "[data-role=link-video] video[controls][preload=metadata][playsinline]"
             )
           )

    refute has_element?(view, msg_sel(m_vid, "video[autoplay]"))

    # A canvas in another space A can read is a canvas card too.
    assert has_element?(view, msg_sel(m_other, "[data-kind=canvas]"), "Secret pricing canvas")
  end

  test "a second reader without access sees locked cards and no secret strings", ctx do
    m_secret = post!(ctx.room, ctx.p_a, "#{origin()}/canvases/#{ctx.secret.id}")
    m_proto = post!(ctx.room, ctx.p_a, "#{origin()}/proto/#{ctx.proto.id}/1/")

    conn = init_test_session(ctx.conn, current_user_id: ctx.b.id)
    {:ok, view, html} = live(conn, "/chat/#{ctx.room.slug}")

    assert has_element?(
             view,
             msg_sel(
               m_secret,
               "[data-role=link-card][data-kind=locked][data-locked-type=canvas]"
             ),
             "Canvas · You don't have access"
           )

    assert has_element?(
             view,
             msg_sel(
               m_proto,
               "[data-role=link-card][data-kind=locked][data-locked-type=prototype]"
             ),
             "Prototype · You don't have access"
           )

    for page <- [html, render(view)] do
      refute page =~ "Secret pricing canvas"
      refute page =~ "pricing-war-room"
      refute page =~ "Burrow masters"
    end
  end

  test "spoofed hosts and dangerous schemes never become canvas cards", ctx do
    host = PlatformWeb.Endpoint.struct_url().host

    m =
      post!(
        ctx.room,
        ctx.p_a,
        Enum.join(
          [
            "https://example.test/canvases/#{ctx.secret.id}",
            "https://#{host}.evil.example/canvases/#{ctx.secret.id}",
            "[click](javascript:alert(1))",
            ~s(<iframe src="https://example.com"></iframe>)
          ],
          "\n"
        )
      )

    conn = init_test_session(ctx.conn, current_user_id: ctx.a.id)
    {:ok, view, _html} = live(conn, "/chat/#{ctx.room.slug}")

    refute has_element?(view, msg_sel(m, "[data-kind=canvas]"))
    assert has_element?(view, msg_sel(m, "[data-role=link-card][data-kind=link]"))
    refute has_element?(view, msg_sel(m, "iframe"))
    assert has_element?(view, msg_sel(m, ~s(a[href^="#blocked:"])))
    refute render(view) =~ "Secret pricing canvas"
  end

  test "a canvas card opens the in-chat canvas for its own space and navigates otherwise",
       ctx do
    m_here = post!(ctx.room, ctx.p_a, "#{origin()}/canvases/#{ctx.here.id}")
    m_other = post!(ctx.room, ctx.p_a, "#{origin()}/canvases/#{ctx.secret.id}")

    conn = init_test_session(ctx.conn, current_user_id: ctx.a.id)
    {:ok, view, _html} = live(conn, "/chat/#{ctx.room.slug}")

    view |> element(msg_sel(m_here, "[data-kind=canvas]")) |> render_click()
    refute_redirected(view, "/canvases/#{ctx.here.id}")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element(msg_sel(m_other, "[data-kind=canvas]")) |> render_click()

    assert to == "/canvases/#{ctx.secret.id}"
  end

  test "a locked card has nothing to click", ctx do
    m = post!(ctx.room, ctx.p_a, "#{origin()}/canvases/#{ctx.secret.id}")

    conn = init_test_session(ctx.conn, current_user_id: ctx.b.id)
    {:ok, view, _html} = live(conn, "/chat/#{ctx.room.slug}")

    refute has_element?(view, msg_sel(m, "[data-kind=locked][phx-click]"))
    refute has_element?(view, msg_sel(m, "[data-kind=locked] a"))

    # Even a forged event for the canvas does nothing for B.
    render_hook(view, "link_card_open_canvas", %{"canvas-id" => ctx.secret.id})
    refute_redirected(view, "/canvases/#{ctx.secret.id}")
  end
end
