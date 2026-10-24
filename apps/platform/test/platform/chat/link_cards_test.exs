defmodule Platform.Chat.LinkCardsTest do
  @moduledoc """
  Redesign rung 13 stage 1: cards are resolved per viewer with the checks the
  destination pages use, and a locked card carries nothing but its type.
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Chat.{LinkCards, LinkTargets}
  alias Platform.Prototypes
  alias Platform.Repo

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

  defp canvas!(space, author_participant, title, children \\ []) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author_participant.id,
        "title" => title,
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{"id" => "root", "type" => "stack", "props" => %{}, "children" => children},
          "theme" => %{},
          "bindings" => %{},
          "meta" => %{}
        }
      })

    canvas
  end

  setup do
    scratch_storage!("link_cards_test")
    set_settings!(%{enabled: true, who_may_publish: "members", retention_days: 90})

    org_id = tenant_org_id("link-cards-#{System.unique_integer([:positive])}")
    a = user!("Reader A")
    b = user!("Reader B")
    member!(a, org_id)

    secret_space = channel!("pricing-war-room")
    p_a = seat!(secret_space, a)
    canvas = canvas!(secret_space, p_a, "Secret pricing canvas")

    {:ok, %{prototype: proto}} =
      Prototypes.publish(
        agent_publisher(agent!()),
        %{org_id: org_id, name: "Confidential proto"},
        {:files, bundle_files("v1")}
      )

    %{
      a: a,
      b: b,
      org_id: org_id,
      canvas: canvas,
      proto: proto,
      secret_space: secret_space,
      p_a: p_a
    }
  end

  defp cards_for(content, user),
    do: content |> LinkTargets.from_content() |> LinkCards.resolve(user.id)

  test "a reader in the canvas's space gets its title and space", ctx do
    assert [card] = cards_for("#{origin()}/canvases/#{ctx.canvas.id}", ctx.a)
    assert card.kind == :canvas
    assert card.title == "Secret pricing canvas"
    assert card.space_name == "pricing-war-room"
    assert card.canvas_id == ctx.canvas.id
    assert card.bare_line?
  end

  test "a reader outside the canvas's space gets :locked with no title anywhere", ctx do
    assert [card] = cards_for("#{origin()}/canvases/#{ctx.canvas.id}", ctx.b)
    assert %{kind: :locked, type: :canvas} = card

    dumped = inspect(card, limit: :infinity, printable_limit: :infinity)
    refute dumped =~ "Secret pricing canvas"
    refute dumped =~ "pricing-war-room"
    refute Map.has_key?(card, :title)
    refute Map.has_key?(card, :space_name)
  end

  test "a missing canvas is locked exactly like a refused one", ctx do
    assert [%{kind: :locked, type: :canvas}] =
             cards_for("#{origin()}/canvases/#{Ecto.UUID.generate()}", ctx.a)
  end

  test "an org member reads a prototype card with name and version", ctx do
    assert [card] = cards_for("#{origin()}/proto/#{ctx.proto.id}/1/", ctx.a)
    assert card.kind == :prototype
    assert card.name == "Confidential proto"
    assert card.version == 1
    assert card.open_url == "/proto/#{ctx.proto.id}/1/"

    assert [%{kind: :prototype, version: 1}] =
             cards_for("#{origin()}/proto/#{ctx.proto.id}/latest/", ctx.a)
  end

  test "a prototype in an org the reader is not in is locked, and the route 404s", ctx do
    assert [card] = cards_for("#{origin()}/proto/#{ctx.proto.id}/1/", ctx.b)
    assert %{kind: :locked, type: :prototype} = card

    dumped = inspect(card, limit: :infinity, printable_limit: :infinity)
    refute dumped =~ "Confidential proto"
    refute Map.has_key?(card, :version)
    refute Map.has_key?(card, :name)

    conn = build_conn() |> init_test_session(current_user_id: ctx.b.id)
    assert conn |> get("/proto/#{ctx.proto.id}/1/") |> response(404)

    conn = build_conn() |> init_test_session(current_user_id: ctx.a.id)
    assert conn |> get("/proto/#{ctx.proto.id}/1/") |> response(302)
  end

  test "readable_by?/2 is the route's check", ctx do
    assert Prototypes.readable_by?(ctx.a, ctx.proto)
    refute Prototypes.readable_by?(ctx.b, ctx.proto)
    refute Prototypes.readable_by?(nil, ctx.proto)
  end

  test "Prototypes.list_readable/2 returns readable rows and omits the rest", ctx do
    ctx.proto |> Ecto.Changeset.change(canvas_id: ctx.canvas.id) |> Repo.update!()
    missing = Ecto.UUID.generate()

    assert [%{id: id}] = Prototypes.list_readable(ctx.a, ids: [ctx.proto.id, missing])
    assert id == ctx.proto.id
    assert Prototypes.list_readable(ctx.b, ids: [ctx.proto.id]) == []

    assert [%{id: ^id}] = Prototypes.list_readable(ctx.a, canvas_ids: [ctx.canvas.id])
    assert Prototypes.list_readable(ctx.b, canvas_ids: [ctx.canvas.id]) == []
    assert Prototypes.list_readable(ctx.a, ids: ["not-a-uuid"]) == []
  end

  test "a canvas that has a prototype row becomes a prototype card", ctx do
    ctx.proto |> Ecto.Changeset.change(canvas_id: ctx.canvas.id) |> Repo.update!()

    assert [%{kind: :prototype, name: "Confidential proto", version: 1}] =
             cards_for("#{origin()}/canvases/#{ctx.canvas.id}", ctx.a)
  end

  test "link, image and video targets need no lookup and fetch nothing", ctx do
    content =
      "https://example.com/pricing/plans\nhttps://example.com/a/photo.png\nhttps://example.com/clip.mp4"

    assert [
             %{kind: :link, host: "example.com", path: "/pricing/plans"},
             %{kind: :image, filename: "photo.png"},
             %{kind: :video, filename: "clip.mp4"}
           ] = cards_for(content, ctx.a)
  end

  test "annotate/2 puts :link_cards on every message of a page", ctx do
    messages = [
      %{id: "m1", content: "#{origin()}/canvases/#{ctx.canvas.id}"},
      %{id: "m2", content: "no links here"},
      %{id: "m3", content: "see https://example.com/x for details"}
    ]

    [m1, m2, m3] = LinkCards.annotate(messages, ctx.b.id)
    assert [%{kind: :locked}] = m1.link_cards
    assert m2.link_cards == []
    assert [%{kind: :link, bare_line?: false}] = m3.link_cards

    assert LinkCards.annotate(messages, nil) == messages
  end

  describe "Burrow card previews (link previews stage 1)" do
    defp node(type, props, children \\ []),
      do: %{
        "id" => "n#{System.unique_integer([:positive])}",
        "type" => type,
        "props" => props,
        "children" => children
      }

    defp image_attachment!(space) do
      {:ok, att} =
        Chat.create_attachment(%{
          space_id: space.id,
          filename: "cover.png",
          content_type: "image/png",
          byte_size: 10,
          storage_key: "link-cards-#{System.unique_integer([:positive])}"
        })

      att
    end

    test "a plain canvas: Canvas badge, no hint, no cover", ctx do
      assert [card] = cards_for("#{origin()}/canvases/#{ctx.canvas.id}", ctx.a)
      assert %{badge: "Canvas", hint: nil, cover: nil, tagline: nil} = card
    end

    test "card and prototype children become the options hint", ctx do
      p_a = ctx.p_a

      children =
        for i <- 1..4 do
          node("card", %{"title" => "Option #{i}"}, [node("text", %{"content" => "x"})])
        end ++
          [
            node("prototype", %{"prototype_id" => ctx.proto.id}),
            node("prototype", %{"prototype_id" => ctx.proto.id})
          ]

      canvas = canvas!(ctx.secret_space, p_a, "Send button feel", children)

      assert [card] = cards_for("#{origin()}/canvases/#{canvas.id}", ctx.a)
      assert card.hint == "6 options · tap to open"
      assert card.badge == "Mockup"
    end

    test "the first image the viewer may read is the cover; an unreadable one is not", ctx do
      p_a = ctx.p_a
      readable = image_attachment!(ctx.secret_space)
      foreign = image_attachment!(channel!("elsewhere"))

      with_cover =
        canvas!(ctx.secret_space, p_a, "Masters", [
          node("image", %{"src" => "/chat/attachments/#{foreign.id}"}),
          node("card", %{}, [node("image", %{"src" => "/chat/attachments/#{readable.id}"})])
        ])

      without =
        canvas!(ctx.secret_space, p_a, "Only foreign", [
          node("image", %{"src" => "/chat/attachments/#{foreign.id}"})
        ])

      assert [a_card, b_card] =
               cards_for(
                 "#{origin()}/canvases/#{with_cover.id}\n#{origin()}/canvases/#{without.id}",
                 ctx.a
               )

      assert a_card.cover == %{src: "/chat/attachments/#{readable.id}", tier: :first_image}
      assert b_card.cover == nil
    end

    test "a locked card still carries only its type", ctx do
      assert [card] = cards_for("#{origin()}/canvases/#{ctx.canvas.id}", ctx.b)
      assert Map.keys(card) |> Enum.sort() == [:bare_line?, :kind, :type, :url]
    end

    test "an outside link carries its smart preview and display", ctx do
      content =
        "https://github.com/acme/api/pull/7\nsee https://www.youtube.com/watch?v=abc and https://example.com/x/office-orders today"

      assert [pr, yt, other] = cards_for(content, ctx.a)
      assert %{display: :card, preview: %{title: "Pull request #7", site: :github}} = pr
      assert %{display: :card, preview: %{video?: true}} = yt
      assert %{display: :chip, preview: %{title: "Office orders", site: nil}} = other
    end
  end
end
