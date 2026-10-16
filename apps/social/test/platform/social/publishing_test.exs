defmodule Platform.Social.PublishingTest do
  @moduledoc """
  The one guarded publish path, exercised with the Fake publisher. The Fake's
  call log and the rate-limit counters are global ETS tables, so this file
  runs `async: false`.

  The guard tests assert `Fake.calls(:publish) == []` after a refusal: a
  refusal that still reached the adapter is the defect they exist to catch.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{Post, Publishing, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    org_id = org_id!()
    {profile, account} = social_account!(org_id, "linkedin")
    %{org_id: org_id, profile: profile, account: account}
  end

  describe "happy path" do
    test "approved -> scheduled with external_id -> published with external_url", ctx do
      post = approved_post!(ctx.org_id, ctx.account, %{body: "launch day"})

      assert {:ok, %Post{status: "scheduled"} = scheduled} =
               Publishing.publish_post(ctx.org_id, post.id)

      assert scheduled.external_id == "fake_" <> post.id
      assert [{:publish, [_account, request], _}] = Fake.calls(:publish)
      assert request.body == "launch day"
      assert request.idempotency_key == post.id
      assert request.platform == "linkedin"

      assert {:ok, %Post{status: "published", external_url: "https://example.test/p/1"}} =
               Publishing.apply_outcome(scheduled, %{
                 kind: :published,
                 external_url: "https://example.test/p/1",
                 error: nil
               })

      row = Repo.get!(Post, post.id)
      assert row.status == "published"
      assert row.approved_by_user_id == post.approved_by_user_id
      assert row.approved_at == post.approved_at
    end

    test "an adapter error moves the post to failed with a readable error", ctx do
      post = approved_post!(ctx.org_id, ctx.account)
      Fake.fail_next(:publish, :rate_limited)

      assert {:error, {:publish_failed, :rate_limited}} =
               Publishing.publish_post(ctx.org_id, post.id)

      row = Repo.get!(Post, post.id)
      assert row.status == "failed"
      assert row.error == "rate limited by the vendor"
    end

    test "is_aigc and ai_disclosure reach the adapter's request", ctx do
      agent = agent!()
      post = approved_post!(ctx.org_id, ctx.account, %{generated_by_agent_id: agent.id})

      labelled =
        approved_post!(ctx.org_id, ctx.account, %{is_aigc: true, ai_disclosure: "AI voice"})

      plain = approved_post!(ctx.org_id, ctx.account)

      for p <- [post, labelled, plain], do: {:ok, _} = Publishing.publish_post(ctx.org_id, p.id)

      [r1, r2, r3] = Enum.map(Fake.calls(:publish), fn {:publish, [_, req], _} -> req end)
      assert {r1.is_aigc, r1.ai_disclosure} == {true, "Made with AI"}
      assert {r2.is_aigc, r2.ai_disclosure} == {true, "AI voice"}
      assert {r3.is_aigc, r3.ai_disclosure} == {false, nil}
    end

    test "a post in another org is not found and never published", ctx do
      post = approved_post!(ctx.org_id, ctx.account)
      assert {:error, :not_found} = Publishing.publish_post(org_id!(), post.id)
      assert Fake.calls() == []
    end

    test "an archived account is refused before the adapter", ctx do
      post = approved_post!(ctx.org_id, ctx.account)
      {:ok, _} = Social.archive_account(ctx.org_id, ctx.account)
      assert {:error, :account_archived} = Publishing.publish_post(ctx.org_id, post.id)
      assert Repo.get!(Post, post.id).status == "approved"
      assert Fake.calls() == []
    end

    test "no configured publisher refuses without touching the row", ctx do
      post = approved_post!(ctx.org_id, ctx.account)
      previous = Application.get_env(:social, :publisher)
      Application.delete_env(:social, :publisher)
      on_exit(fn -> Application.put_env(:social, :publisher, previous) end)

      assert {:error, :publisher_not_configured} = Publishing.publish_post(ctx.org_id, post.id)
      assert Repo.get!(Post, post.id).status == "approved"
    end
  end

  describe "guard" do
    test "a draft post is refused and the adapter is never called", ctx do
      {:ok, draft} = Social.create_post(ctx.org_id, ctx.account, %{body: "draft"})
      assert {:error, :not_approved} = Publishing.publish_post(ctx.org_id, draft.id)
      assert Repo.get!(Post, draft.id).status == "draft"
      assert Fake.calls(:publish) == []
    end

    test "a needs_approval post is refused and the adapter is never called", ctx do
      {:ok, post} =
        Social.create_post(ctx.org_id, ctx.account, %{body: "x", status: "needs_approval"})

      assert {:error, :not_approved} = Publishing.publish_post(ctx.org_id, post.id)
      assert Repo.get!(Post, post.id).status == "needs_approval"
      assert Fake.calls(:publish) == []
    end

    test "an approver whose user row is archived is refused, on the locked re-read", ctx do
      approver = user!()
      post = approved_post!(ctx.org_id, ctx.account, %{}, approver)

      approver
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Repo.update!()

      # The caller's struct still looks publishable; the guard re-reads.
      assert Publishing.publishable?(post) == false
      assert {:error, :not_approved} = Publishing.publish_post(ctx.org_id, post.id)
      assert Repo.get!(Post, post.id).status == "approved"
      assert Fake.calls(:publish) == []
    end

    test "the database refuses an approved row with no approver (insert_all)", ctx do
      row = %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        account_id: Ecto.UUID.dump!(ctx.account.id),
        status: "approved",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn -> Repo.insert_all("social_posts", [row]) end)
        end

      assert error.postgres.constraint == "social_posts_approved_needs_approver_check"
    end

    test "publishable?/1 is false without an approver, with an agent id, and off approved" do
      refute Publishing.publishable?(%Post{status: "approved", approved_by_user_id: nil})

      agent = agent!()
      refute Publishing.publishable?(%Post{status: "approved", approved_by_user_id: agent.id})

      user = user!()

      for status <- Post.statuses() -- ["approved"] do
        refute Publishing.publishable?(%Post{status: status, approved_by_user_id: user.id}),
               "publishable? was true for status #{status}"
      end

      assert Publishing.publishable?(%Post{status: "approved", approved_by_user_id: user.id})
    end

    test "publish_post/2 is the only call site of a publisher's publish/2 in apps/social/lib" do
      lib = Path.expand("../../../lib", __DIR__)

      sites =
        for path <- Path.wildcard(Path.join(lib, "**/*.ex")),
            {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            String.contains?(line, ".publish(") or
              String.contains?(line, "Publisher.impl().publish"),
            do: {Path.relative_to(path, lib), n, String.trim(line)}

      assert [
               {"platform/social/publishing.ex", _,
                "apply_publish(post, adapter.publish(account, request))"}
             ] =
               sites
    end
  end

  describe "media rules run before the adapter" do
    defp post_with_media(ctx, account, files_with_meta) do
      ids = Enum.map(files_with_meta, fn {file, _} -> file.id end)

      meta =
        Map.new(files_with_meta, fn {file, meta} -> {file.id, meta} end)
        |> Map.reject(fn {_, m} -> m == nil end)

      approved_post!(ctx.org_id, account, %{media_file_ids: ids, media_meta: meta})
    end

    test "a refused post keeps its status and nothing reaches the publisher", ctx do
      {_, tiktok} = social_account!(ctx.org_id, "tiktok")
      {_, insta} = social_account!(ctx.org_id, "instagram", %{platform_account_type: "personal"})
      {_, x} = social_account!(ctx.org_id, "x")
      video = fn -> media_file!(ctx.org_id, "video/mp4") end
      image = fn -> media_file!(ctx.org_id, "image/png") end

      cases = [
        {tiktok, [{video.(), %{"duration_s" => 30}}, {video.(), %{"duration_s" => 30}}],
         "TikTok allows one video per post; this post has 2"},
        {tiktok, [{video.(), %{"duration_s" => 1.5}}],
         "TikTok videos must be at least 3 seconds; this one is 1.5 seconds"},
        {tiktok, [{video.(), nil}], "TikTok needs the video's duration; it is unknown"},
        {tiktok, [{video.(), %{"duration_s" => 30}}, {image.(), nil}],
         "TikTok cannot mix a video and images in one post"},
        {insta, [{video.(), %{"duration_s" => 30}}],
         "Instagram Reels need a Business or Creator account"},
        {x, for(_ <- 1..5, do: {image.(), nil}),
         "X allows at most 4 images per post; this post has 5"},
        {x, [{video.(), %{"duration_s" => 30}}, {image.(), nil}],
         "X cannot mix videos, GIFs and images in one post"}
      ]

      for {account, media, message} <- cases do
        post = post_with_media(ctx, account, media)

        assert {:error, {:media_rejected, [^message]}} =
                 Publishing.publish_post(ctx.org_id, post.id)

        assert Repo.get!(Post, post.id).status == "approved"
      end

      assert Fake.calls() == []

      compliant = post_with_media(ctx, tiktok, [{video.(), %{"duration_s" => 30}}])
      assert {:ok, %Post{status: "scheduled"}} = Publishing.publish_post(ctx.org_id, compliant.id)

      assert [{:publish, [_, %{media: [%{content_type: "video/mp4", duration_s: 30}]}], _}] =
               Fake.calls(:publish)
    end

    test "a media file from another org is refused", ctx do
      foreign = media_file!(org_id!(), "image/png")
      post = approved_post!(ctx.org_id, ctx.account, %{media_file_ids: [foreign.id]})

      assert {:error, {:media_rejected, ["A media file is missing or not in this org"]}} =
               Publishing.publish_post(ctx.org_id, post.id)

      assert Fake.calls() == []
    end
  end

  describe "rate limit" do
    setup do
      previous = Application.get_env(:social, :rate_limit)
      Application.put_env(:social, :rate_limit, per_window: 3, window_ms: 60_000)
      on_exit(fn -> Application.put_env(:social, :rate_limit, previous) end)
      :ok
    end

    test "the account's 4th publish in a window is refused; another account still passes", ctx do
      {_, other} = social_account!(ctx.org_id, "linkedin")
      posts = for _ <- 1..4, do: approved_post!(ctx.org_id, ctx.account)
      [p1, p2, p3, p4] = posts

      for p <- [p1, p2, p3],
          do:
            assert({:ok, %Post{status: "scheduled"}} = Publishing.publish_post(ctx.org_id, p.id))

      assert {:error, :rate_limited} = Publishing.publish_post(ctx.org_id, p4.id)
      assert Repo.get!(Post, p4.id).status == "approved"
      assert length(Fake.calls(:publish)) == 3

      b = approved_post!(ctx.org_id, other)
      assert {:ok, %Post{status: "scheduled"}} = Publishing.publish_post(ctx.org_id, b.id)
    end
  end

  describe "cancel, refresh and connect" do
    test "cancel_post deletes at the vendor and only for scheduled posts", ctx do
      post = approved_post!(ctx.org_id, ctx.account)
      assert {:error, :not_scheduled} = Publishing.cancel_post(ctx.org_id, post.id)
      {:ok, scheduled} = Publishing.publish_post(ctx.org_id, post.id)

      assert {:ok, %Post{status: "failed", error: "cancelled before publishing"}} =
               Publishing.cancel_post(ctx.org_id, post.id)

      assert [{:delete, [_, external_id], _}] = Fake.calls(:delete)
      assert external_id == scheduled.external_id
    end

    test "refresh_status applies the vendor's outcome through apply_outcome", ctx do
      post = approved_post!(ctx.org_id, ctx.account)
      {:ok, _} = Publishing.publish_post(ctx.org_id, post.id)

      assert {:ok, :noop} = Publishing.refresh_status(ctx.org_id, post.id)

      Fake.put_next(
        :status,
        {:ok, %{status: :published, external_url: "https://example.test/p/9", error: nil}}
      )

      assert {:ok, %Post{status: "published", external_url: "https://example.test/p/9"}} =
               Publishing.refresh_status(ctx.org_id, post.id)
    end

    test "apply_outcome is idempotent and refuses unapproved posts", ctx do
      post = approved_post!(ctx.org_id, ctx.account)
      {:ok, scheduled} = Publishing.publish_post(ctx.org_id, post.id)
      outcome = %{kind: :published, external_url: "https://example.test/p/2", error: nil}

      {:ok, published} = Publishing.apply_outcome(scheduled, outcome)
      assert {:ok, :noop} = Publishing.apply_outcome(scheduled, outcome)
      assert {:ok, :noop} = Publishing.apply_outcome(scheduled, %{kind: :failed, error: "late"})
      assert Repo.get!(Post, post.id) == published

      {:ok, draft} = Social.create_post(ctx.org_id, ctx.account, %{body: "d"})
      assert {:error, :invalid_transition} = Publishing.apply_outcome(draft, outcome)
      assert Repo.get!(Post, draft.id).status == "draft"
    end

    test "connect_url needs an org admin and a redirect to this install", ctx do
      admin = user!()
      member = user!()

      Repo.insert!(%Platform.Tenancy.OrgMembership{
        org_id: ctx.org_id,
        user_id: admin.id,
        role: "admin"
      })

      Repo.insert!(%Platform.Tenancy.OrgMembership{
        org_id: ctx.org_id,
        user_id: member.id,
        role: "member"
      })

      ours = PlatformWeb.Endpoint.url() <> "/social/connected"

      assert {:ok, url} = Publishing.connect_url(ctx.org_id, admin.id, ctx.account.id, ours)
      assert url =~ URI.encode_www_form(ours)

      assert {:error, :forbidden} =
               Publishing.connect_url(ctx.org_id, member.id, ctx.account.id, ours)

      assert {:error, :forbidden} =
               Publishing.connect_url(ctx.org_id, agent!().id, ctx.account.id, ours)

      assert {:error, :redirect_not_allowed} =
               Publishing.connect_url(
                 ctx.org_id,
                 admin.id,
                 ctx.account.id,
                 "https://evil.example/cb"
               )

      assert length(Fake.calls(:connect_url)) == 1
    end
  end
end
