defmodule Platform.Social.ClipRetryZernioTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ClipPublish, Post, Publishing, RateLimit}
  alias Platform.Social.Publisher.Zernio

  setup do
    RateLimit.reset()
    old = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, Zernio)
    on_exit(fn -> Application.put_env(:social, :publisher, old) end)

    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, "retry-test-key",
        scope: {:integration, nil},
        provider: "social"
      )

    w = render_world!()
    file = stored_file!(w.project, "retry clip", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{"file_id" => file.id, "caption" => "retry", "duration_s" => 30.0},
        w.agent.id
      )

    server =
      start_supervised!(
        {ClipPublish, name: :zernio_retry_integration, interval_ms: :infinity, boot_sweep: false}
      )

    {:ok, %{posts: posts}} =
      Social.approve_clip(
        w.org_id,
        clip.id,
        w.approver.id,
        %{"render_id" => render_id!(clip), "account_ids" => [w.tiktok.id, w.x.id]},
        publish_server: server
      )

    Req.Test.stub(Zernio, fn conn -> flunk("unexpected #{conn.method} #{conn.request_path}") end)

    %{
      w: w,
      post: Enum.find(posts, &(&1.account_id == w.tiktok.id)),
      sibling: Enum.find(posts, &(&1.account_id == w.x.id))
    }
  end

  defp outcome(ctx, status, entry_status) do
    %{
      post: %{
        _id: "zp_existing",
        status: status,
        platforms: [
          %{
            accountId: ctx.w.tiktok.provider_account_ref,
            status: entry_status,
            errorMessage: "platform upload failed",
            platformPostId: if(entry_status == "published", do: "native_retry"),
            platformPostUrl: if(entry_status == "published", do: "https://example.test/retry")
          }
        ]
      }
    }
  end

  defp expect_create(ctx, response) do
    Req.Test.expect(Zernio, fn conn ->
      assert {conn.method, conn.request_path} == {"POST", "/api/v1/posts"}
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == [ctx.post.id]

      case response do
        :http -> conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{error: "not created"})
        :network -> Req.Test.transport_error(conn, :econnrefused)
        body -> Req.Test.json(conn, body)
      end
    end)
  end

  defp expect_status(ctx, status, entry) do
    Req.Test.expect(Zernio, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/api/v1/posts/zp_existing"}
      Req.Test.json(conn, outcome(ctx, status, entry))
    end)
  end

  defp failed_existing!(ctx) do
    expect_create(ctx, outcome(ctx, "scheduled", "pending"))

    assert {:ok, %{status: "scheduled", external_id: "zp_existing"}} =
             Publishing.publish_post(ctx.w.org_id, ctx.post.id)

    expect_status(ctx, "partial", "failed")

    assert {:ok, %{status: "failed", error: "platform upload failed"}} =
             Publishing.refresh_status(ctx.w.org_id, ctx.post.id)
  end

  defp expect_retry(ctx, status, entry, http \\ 200) do
    test_pid = self()

    Req.Test.expect(Zernio, fn conn ->
      if {conn.method, conn.request_path} == {"POST", "/api/v1/posts"} do
        # Deliberate replay trap: the old key returns the original failed post.
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == [ctx.post.id]
        Req.Test.json(conn, outcome(ctx, "failed", "failed"))
      else
        assert {conn.method, conn.request_path} == {"POST", "/api/v1/posts/zp_existing/retry"}
        send(test_pid, :existing_post_retried)
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == ""
        response = outcome(ctx, status, entry)
        [target] = response.post.platforms

        response =
          put_in(response, [:post, :platforms], [
            %{accountId: "unrelated", status: "published"},
            %{target | accountId: %{_id: ctx.w.tiktok.provider_account_ref}}
          ])

        conn |> Plug.Conn.put_status(http) |> Req.Test.json(response)
      end
    end)
  end

  test "created then platform failed retries existing post and publishes", ctx do
    failed_existing!(ctx)
    expect_retry(ctx, "published", "published")
    retrier = make_approver!(ctx.w.org_id, ctx.w.profile, member!(user!(), ctx.w.org_id))
    assert {:ok, published} = Social.retry_post(ctx.w.org_id, ctx.post.id, retrier.id)
    assert_received :existing_post_retried
    assert published.id == ctx.post.id
    assert published.external_id == "zp_existing"
    assert published.status == "published"
    assert %DateTime{} = published.published_at
    assert published.error == nil
    assert published.refused_reason == nil
    assert published.external_url == "https://example.test/retry"
    assert published.platform_post_id == "native_retry"
    assert published.approved_by_user_id == retrier.id
    assert published.publish_attempts == 2
    assert Repo.get!(Post, ctx.sibling.id) == ctx.sibling
    Req.Test.verify!()
  end

  for failure <- [:http, :network] do
    test "pre-creation #{failure} failure retains original create key", ctx do
      expect_create(ctx, unquote(failure))
      assert {:error, _} = Publishing.publish_post(ctx.w.org_id, ctx.post.id)
      assert Repo.get!(Post, ctx.post.id).external_id == nil
      expect_create(ctx, outcome(ctx, "published", "published"))

      assert {:ok, %{status: "published", publish_attempts: 2}} =
               Social.retry_post(ctx.w.org_id, ctx.post.id, ctx.w.approver.id)

      Req.Test.verify!()
    end
  end

  for status <- ["failed", "partial"] do
    test "207 #{status} retains target failure and existing id", ctx do
      failed_existing!(ctx)
      expect_retry(ctx, unquote(status), "failed", 207)

      assert {:error, {:publish_failed, "platform upload failed"}} =
               Social.retry_post(ctx.w.org_id, ctx.post.id, ctx.w.approver.id)

      assert %{
               status: "failed",
               external_id: "zp_existing",
               publish_attempts: 2,
               error: "platform upload failed"
             } = Repo.get!(Post, ctx.post.id)

      Req.Test.verify!()
    end
  end

  test "207 scheduled settles via refresh", ctx do
    failed_existing!(ctx)
    expect_retry(ctx, "scheduled", "failed", 207)

    assert {:ok, %{status: "scheduled", published_at: nil}} =
             Social.retry_post(ctx.w.org_id, ctx.post.id, ctx.w.approver.id)

    expect_status(ctx, "published", "published")

    assert {:ok, %{status: "published", external_id: "zp_existing", publish_attempts: 2}} =
             Publishing.refresh_status(ctx.w.org_id, ctx.post.id)

    Req.Test.verify!()
  end

  test "approved guard refusal keeps wait and sends no vendor request", ctx do
    old = Application.get_env(:social, :rate_limit)
    Application.put_env(:social, :rate_limit, per_window: 0, window_ms: 60_000)
    on_exit(fn -> Application.put_env(:social, :rate_limit, old) end)
    assert {:error, :rate_limited} = Publishing.publish_post(ctx.w.org_id, ctx.post.id)
    refused = Repo.get!(Post, ctx.post.id)
    assert refused.status == "approved"
    assert %DateTime{} = until = refused.retry_after

    assert {:error, {:wait_until, ^until}} =
             Social.retry_post(ctx.w.org_id, ctx.post.id, ctx.w.approver.id)

    assert Repo.get!(Post, ctx.post.id).publish_attempts == 0
  end
end
