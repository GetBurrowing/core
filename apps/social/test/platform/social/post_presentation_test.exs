defmodule Platform.Social.PostPresentationTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures
  alias Platform.Social.{Approvals, PostPresentation}

  setup do
    ctx = approval_fixture() |> with_ideas_runtime()

    {post, card} =
      pending_post!(ctx, ctx.a, %{
        body: "\n#topic https://example.org\nCan AI ever be funny?\nLong private caption"
      })

    Map.merge(ctx, %{post: post, card: card})
  end

  test "current reader sees a bounded useful title and exact post route without approval", ctx do
    view = Approvals.card_view(ctx.card.id, {:user, ctx.n.id})
    assert view.role == :viewer
    assert view.title == "Can AI ever be funny?"
    assert URI.decode_query(URI.parse(view.post_url).query)["post"] == ctx.post.id
    refute Map.has_key?(view, :body)
    refute :approve in Map.get(view, :actions, [])
  end

  test "fresh project deny removes title and link, not only the markup", ctx do
    assert PostPresentation.read(ctx.post, {:user, ctx.n.id})

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.n.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    assert PostPresentation.read(ctx.post, {:user, ctx.n.id}) == nil
    view = Approvals.card_view(ctx.card.id, {:user, ctx.n.id})
    refute Map.has_key?(view, :title)
    refute Map.has_key?(view, :post_url)
  end

  test "an update batch cannot reuse another viewer's authority", ctx do
    context = PostPresentation.authorize({:user, ctx.h1.id}, [ctx.profile.id])

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.n.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    refute Map.has_key?(Approvals.card_view(ctx.card.id, {:user, ctx.n.id}, context), :title)
  end

  test "agents and foreign humans get neither title nor link", ctx do
    outsider = named_user!("Foreign reader")
    member!(outsider, org_id!())

    for viewer <- [{:agent, ctx.g.id}, {:user, outsider.id}, nil] do
      assert PostPresentation.read(ctx.post, viewer) == nil
    end
  end

  test "title is bounded by words, strips urls and hashtags, and has a platform fallback", ctx do
    assert PostPresentation.title(%{ctx.post | body: "#tag https://example.org"}, ctx.a) ==
             "LinkedIn post"

    title = PostPresentation.title(%{ctx.post | body: String.duplicate("word ", 30)}, ctx.a)
    assert String.length(title) <= 61
    assert String.ends_with?(title, "…")
    refute title =~ "  "
  end

  test "caption display uses a complete sentence within seventy characters before truncating",
       ctx do
    for {caption, expected} <- [
          {"If AI could cure aging, who would get access? Maybe about something else",
           "If AI could cure aging, who would get access?"},
          {"To be funny you have to get culture, wordplay, timing and irony. Then more",
           "To be funny you have to get culture, wordplay, timing and irony."}
        ] do
      assert PostPresentation.title(%{ctx.post | body: caption}, ctx.a) == expected
    end
  end

  test "stored Clip identity wins, then idea, and foreign-profile links do not supply a title",
       ctx do
    w = render_world!()
    file = stored_file!(w.project, "rendered clip", "clip.mp4", "video/mp4")

    {:ok, clip} =
      Platform.Social.AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{file_id: file.id, title: "Clip title", episode_code: "Ep 4"},
        w.agent.id
      )

    clip_post = %Platform.Social.Post{
      account_id: w.tiktok.id,
      clip_id: clip.id,
      body: "Caption fallback"
    }

    assert PostPresentation.title(clip_post, w.tiktok) == "Ep 4 · Clip title"

    assert PostPresentation.title(%{ctx.post | clip_id: clip.id}, ctx.a) ==
             "Can AI ever be funny?"

    {:ok, %{idea: idea}} =
      Platform.Federation.ToolArguments.dispatch(
        "social_idea_create",
        %{"profile_id" => ctx.profile.id, "title" => "Idea title", "brief" => "A brief"},
        ctx.agent_ctx
      )

    assert PostPresentation.title(%{ctx.post | idea_id: idea.id}, ctx.a) == "Idea title"
  end

  test "project-less legacy profiles get no new caption title or direct link", ctx do
    profile = Repo.update!(Ecto.Changeset.change(ctx.profile, project_id: nil))
    assert profile.project_id == nil
    assert PostPresentation.read(ctx.post, {:user, ctx.n.id}) == nil
  end

  test "inbox and card choose a link per current recipient read, not profile project presence",
       ctx do
    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.h1.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    {post, card} = pending_post!(ctx, ctx.a)

    legacy =
      "/m/social?" <>
        URI.encode_query([{"profile", ctx.profile.id}, {"tab", "queue"}, {"idea", post.id}])

    assert Approvals.queue_url(post, ctx.profile) == legacy

    denied_item =
      Repo.get_by!(Platform.Inbox.Item,
        user_id: ctx.h1.id,
        source_id: post.id,
        kind: "social_post_approval"
      )

    allowed_item =
      Repo.get_by!(Platform.Inbox.Item,
        user_id: ctx.h2.id,
        source_id: post.id,
        kind: "social_post_approval"
      )

    assert denied_item.url == legacy
    assert Approvals.card_view(card.id, {:user, ctx.h1.id}).queue_url == legacy
    assert URI.decode_query(URI.parse(allowed_item.url).query)["post"] == post.id
    assert Approvals.card_view(card.id, {:user, ctx.h2.id}).queue_url == allowed_item.url
  end

  test "archived users cannot receive new identity or exact read detail", ctx do
    assert PostPresentation.read(ctx.post, {:user, ctx.n.id})
    {:ok, _} = Platform.Accounts.archive_user(ctx.n)
    assert PostPresentation.read(ctx.post, {:user, ctx.n.id}) == nil
    refute Map.has_key?(Approvals.card_view(ctx.card.id, {:user, ctx.n.id}), :title)
  end

  test "new channel and inbox payloads remain minimal, without caption-derived text", ctx do
    message = Platform.Chat.get_message(ctx.card.message_id)
    assert message.content == "Needs approval: LinkedIn post for #{ctx.profile.name}"
    canvas = Platform.Chat.get_canvas(ctx.card.canvas_id)
    assert canvas.title == message.content

    item =
      Repo.get_by!(Platform.Inbox.Item,
        user_id: ctx.h1.id,
        source_id: ctx.post.id,
        kind: "social_post_approval"
      )

    refute item.body =~ ctx.a.handle
    refute inspect(canvas.document) =~ "Can AI"
  end
end
