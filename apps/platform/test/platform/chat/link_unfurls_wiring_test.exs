defmodule Platform.Chat.LinkUnfurlsWiringTest do
  @moduledoc """
  Link unfurls stage 3 (task 01a1a944): posts and edits ensure their outside
  links, the `{:link_unfurls_ready, msg}` event, the install switch, the
  author-only hide flag, and `LinkCards.annotate/2` reading stored previews.

  Every request goes to the `Req.Test` stub `Platform.Chat.LinkUnfurls.Fetcher`
  and every host resolves through the static resolver set here, so nothing
  reaches DNS or the network. Each request is reported as `{:hit, ip, path}`.
  Spawned work is drained with `Platform.SandboxHelpers.await_supervised_writes/1`
  before a count is read (shared sandbox, `async: false`).
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.{LinkCards, LinkUnfurl, LinkUnfurls, Message}
  alias Platform.Chat.LinkUnfurls.{Fetcher, Settings}
  alias Platform.Chat.Messages.Edit
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo
  alias Platform.SandboxHelpers

  @public {93, 184, 216, 34}
  @page ~s(<html><head><meta property="og:title" content="Public page"><meta property="og:image" content="https://cdn.public.test/i.jpg"></head></html>)

  setup do
    prev = Application.get_env(:platform, :link_unfurl_resolver)
    Application.put_env(:platform, :link_unfurl_resolver, %{"public.test" => [@public]})
    on_exit(fn -> Application.put_env(:platform, :link_unfurl_resolver, prev) end)

    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "unfurl-#{n}", slug: "unfurl-#{n}", kind: "channel"})

    author = seat!(space, user!("author-#{n}"))
    other_user = user!("other-#{n}")
    other = seat!(space, other_user)
    :ok = ChatPubSub.subscribe(space.id)

    %{space: space, author: author, other: other, other_user: other_user}
  end

  defp user!(tag) do
    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        sub: "unfurl-wiring-#{tag}",
        email: "unfurl-wiring-#{tag}@example.com",
        name: "Unfurl #{tag}"
      })

    user
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

  defp origin do
    uri = PlatformWeb.Endpoint.struct_url()
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end

  defp ip, do: @public |> :inet.ntoa() |> to_string()

  defp stub(fun) do
    me = self()

    Req.Test.stub(Fetcher, fn conn ->
      send(me, {:hit, conn.host, conn.request_path})
      fun.(conn)
    end)
  end

  defp page_stub, do: stub(&Req.Test.html(&1, @page))

  defp hits do
    receive do
      {:hit, host, path} -> [{host, path} | hits()]
    after
      0 -> []
    end
  end

  defp post!(ctx, content, extra \\ %{}) do
    {:ok, msg} =
      Chat.post_message(
        Map.merge(
          %{space_id: ctx.space.id, participant_id: ctx.author.id, content: content},
          extra
        )
      )

    msg
  end

  defp drain!, do: assert(SandboxHelpers.await_supervised_writes(timeout: 3_000) == :ok)
  defp rows, do: Repo.aggregate(LinkUnfurl, :count)

  defp canvas!(ctx) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => ctx.space.id,
        "created_by" => ctx.author.id,
        "title" => "A canvas",
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

  describe "posting" do
    test "an outside url and a canvas url: only the outside one is fetched, then the ready event",
         ctx do
      page_stub()
      canvas = canvas!(ctx)
      msg = post!(ctx, "https://public.test/post\n#{origin()}/canvases/#{canvas.id}")
      msg_id = msg.id

      assert_receive {:link_unfurls_ready, %Message{id: ^msg_id}}, 3_000
      drain!()
      assert hits() == [{ip(), "/post"}]

      assert [%LinkUnfurl{url_key: "https://public.test/post", status: "ok"}] =
               Repo.all(LinkUnfurl)

      # The event is the new one, never an edit.
      refute_received {:message_updated, %{id: ^msg_id}}
    end

    test "an image or video media url is not unfurled", ctx do
      page_stub()
      post!(ctx, "https://public.test/cat.png\nhttps://public.test/clip.mp4")
      drain!()
      assert hits() == []
      assert rows() == 0
    end

    test "the post still succeeds when the fetch fails or the stub raises", ctx do
      stub(&Plug.Conn.send_resp(&1, 500, "boom"))
      assert %Message{} = post!(ctx, "https://public.test/fails")
      drain!()

      stub(fn _conn -> raise "stub exploded" end)
      assert %Message{} = post!(ctx, "https://public.test/raises")
      drain!()

      assert Repo.all(from(u in LinkUnfurl, select: u.status, order_by: u.url_key)) == [
               "failed",
               "failed"
             ]
    end

    test "a log_only message is not unfurled", ctx do
      page_stub()
      post!(ctx, "https://public.test/log", %{log_only: true})
      drain!()
      assert rows() == 0
    end
  end

  describe "edits" do
    test "an edit that adds an outside url unfurls it", ctx do
      page_stub()
      msg = post!(ctx, "no links yet")
      drain!()
      assert rows() == 0

      assert {:ok, _} = Edit.apply_edit(msg, ctx.author, "now with https://public.test/edited")
      msg_id = msg.id
      assert_receive {:link_unfurls_ready, %Message{id: ^msg_id}}, 3_000
      drain!()
      assert hits() == [{ip(), "/edited"}]
    end
  end

  describe "the install switch" do
    test "off: no fetch and no row; on again (positive control): one row", ctx do
      page_stub()
      Repo.update_all(Settings, set: [enabled: false])
      refute Settings.enabled?()

      post!(ctx, "https://public.test/off")
      drain!()
      assert rows() == 0
      assert hits() == []

      Repo.update_all(Settings, set: [enabled: true])
      msg = post!(ctx, "https://public.test/on")
      msg_id = msg.id
      assert_receive {:link_unfurls_ready, %Message{id: ^msg_id}}, 3_000
      drain!()
      assert rows() == 1
    end

    test "update/2 refuses a non-admin", ctx do
      assert {:error, :unauthorized} = Settings.update(ctx.other_user, %{enabled: false})
      assert Settings.enabled?()
    end
  end

  describe "hide_link_unfurls/2" do
    test "the author hides; the flag persists and other metadata keys survive", ctx do
      page_stub()
      msg = post!(ctx, "https://public.test/h", %{metadata: %{"keep" => "me"}})
      drain!()
      _ = hits()

      assert {:ok, _} = Chat.hide_link_unfurls(msg.id, ctx.author)
      msg_id = msg.id
      assert_receive {:link_unfurls_ready, %Message{id: ^msg_id}}, 1_000

      stored = Repo.get!(Message, msg.id)
      assert stored.metadata["unfurl_hidden"] == true
      assert stored.metadata["keep"] == "me"
    end

    test "a non-author is refused and the flag stays unset", ctx do
      page_stub()
      msg = post!(ctx, "https://public.test/nh")
      drain!()

      assert {:error, :not_author} = Chat.hide_link_unfurls(msg.id, ctx.other)
      refute Map.has_key?(Repo.get!(Message, msg.id).metadata || %{}, "unfurl_hidden")
      msg_id = msg.id

      refute_received {:link_unfurls_ready,
                       %Message{id: ^msg_id, metadata: %{"unfurl_hidden" => _}}}

      # Positive control: the author can.
      assert {:ok, _} = Chat.hide_link_unfurls(msg.id, ctx.author)
    end

    test "a malformed or unknown id is :not_found", ctx do
      assert {:error, :not_found} = Chat.hide_link_unfurls("nope", ctx.author)
      assert {:error, :not_found} = Chat.hide_link_unfurls(Ecto.UUID.generate(), ctx.author)
    end
  end

  describe "LinkCards.annotate/2" do
    defp row!(url, status) do
      now = DateTime.utc_now()

      Repo.insert!(%LinkUnfurl{
        url_key: LinkUnfurls.normalize(url),
        url: url,
        status: status,
        title: if(status == "ok", do: "Stored title"),
        image_url: if(status == "ok", do: "https://cdn.public.test/i.jpg"),
        media_kind: if(status == "ok", do: "article"),
        expires_at: DateTime.add(now, 3600, :second)
      })
    end

    defp msg(content, metadata \\ %{}),
      do: %{id: Ecto.UUID.generate(), content: content, content_type: "text", metadata: metadata}

    defp card(msg, user_id) do
      [annotated] = LinkCards.annotate([msg], user_id)
      Enum.find(annotated.link_cards, &(&1.kind == :link))
    end

    test "an ok row puts :unfurl on the card; a failed row does not", ctx do
      row!("https://public.test/ok", "ok")
      row!("https://public.test/bad", "failed")

      assert %{unfurl: %{title: "Stored title", media_kind: "article"}, display: :card} =
               card(msg("https://public.test/ok"), ctx.author.participant_id)

      refute Map.has_key?(
               card(msg("https://public.test/bad"), ctx.author.participant_id),
               :unfurl
             )
    end

    test "unfurl_hidden: the card is a chip with no :unfurl, and its line is kept", ctx do
      row!("https://public.test/ok", "ok")

      c =
        card(msg("https://public.test/ok", %{"unfurl_hidden" => true}), ctx.author.participant_id)

      assert c.display == :chip
      assert c.bare_line? == false
      refute Map.has_key?(c, :unfurl)
    end

    test "a 50-message page costs exactly one more query for its outside links", ctx do
      canvas = canvas!(ctx)
      viewer = ctx.author.participant_id
      canvas_url = "#{origin()}/canvases/#{canvas.id}"

      base = for _ <- 1..50, do: msg(canvas_url)
      with_links = for n <- 1..50, do: msg("#{canvas_url}\nhttps://public.test/p#{n}")
      plain = for _ <- 1..50, do: msg("no links")

      assert count_queries(fn -> LinkCards.annotate(plain, viewer) end) == 0

      # Warm both paths first: the first canvas read of a process caches
      # what later reads skip, which would otherwise land in whichever page
      # is measured first.
      LinkCards.annotate(base, viewer)
      LinkCards.annotate(with_links, viewer)

      base_count = count_queries(fn -> LinkCards.annotate(base, viewer) end)
      assert base_count > 0
      assert count_queries(fn -> LinkCards.annotate(with_links, viewer) end) == base_count + 1
    end
  end

  # Statements the TEST process ran while `fun` executed (handlers are
  # global, so a sibling file's queries are filtered out by pid).
  defp count_queries(fun) do
    me = self()
    id = "unfurl-wiring-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:platform, :repo, :query],
        fn _, _, _, _ ->
          if self() == me, do: send(me, {:q, id})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    count(id, 0)
  end

  defp count(id, n) do
    receive do
      {:q, ^id} -> count(id, n + 1)
    after
      0 -> n
    end
  end
end
