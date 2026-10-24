defmodule Platform.Social.ClipRetryTest do
  @moduledoc """
  Clip Studio 2/9 (task 01a16662) stage 3: `Platform.Social.retry_post/3`
  re-publishes ONE clip post for a human. A refusal before the vendor goes
  through #1323's `Publishing.retry_publish/3` unchanged; a post the vendor
  failed is re-approved by the retrying human and published again. Not
  async: ClipPublish runs in its own process and the Fake's log is global.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ClipPublish, Post, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    w = render_world!()
    file = stored_file!(w.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{"file_id" => file.id, "caption" => "c", "duration_s" => 30.0},
        w.agent.id
      )

    pid =
      start_supervised!(
        {ClipPublish, name: :clip_retry_publish, interval_ms: :infinity, boot_sweep: false}
      )

    t0 = DateTime.utc_now()

    {:ok, %{posts: posts}} =
      Social.approve_clip(
        w.org_id,
        clip.id,
        w.approver.id,
        %{"account_ids" => [w.tiktok.id, w.x.id]},
        now: t0,
        publish_server: pid
      )

    by = Map.new(posts, &{&1.account_id, &1})
    %{w: w, clip: clip, pid: pid, t0: t0, tiktok_post: by[w.tiktok.id], x_post: by[w.x.id]}
  end

  # Sends both posts to the Fake with TikTok failing at the vendor.
  defp tiktok_fails!(ctx) do
    Fake.put_next_for(ctx.w.tiktok.id, :publish, {:error, :token_expired})
    ClipPublish.sweep_now(ctx.pid, DateTime.add(ctx.t0, 8, :second))
    assert %Post{status: "failed"} = Repo.get!(Post, ctx.tiktok_post.id)
    assert %Post{status: "scheduled"} = Repo.get!(Post, ctx.x_post.id)
    Fake.reset()
  end

  defp publish_keys,
    do: Fake.calls(:publish) |> Enum.map(fn {:publish, [_, req], _} -> req.idempotency_key end)

  test "retry_post re-publishes only the failed platform", ctx do
    # Both platforms fail at the vendor.
    Fake.put_next_for(ctx.w.tiktok.id, :publish, {:error, :token_expired})
    Fake.put_next_for(ctx.w.x.id, :publish, {:error, :duplicate_content})
    ClipPublish.sweep_now(ctx.pid, DateTime.add(ctx.t0, 8, :second))
    Fake.reset()

    x_before = Repo.get!(Post, ctx.x_post.id)
    assert x_before.status == "failed"
    retrier = make_approver!(ctx.w.org_id, ctx.w.profile, member!(user!(), ctx.w.org_id))

    assert {:ok, %Post{status: "scheduled"} = retried} =
             Social.retry_post(ctx.w.org_id, ctx.tiktok_post.id, retrier.id)

    # One vendor call, for the post asked about; X stays failed, untouched.
    assert publish_keys() == [ctx.tiktok_post.id]
    assert Repo.get!(Post, ctx.x_post.id) == x_before
    assert retried.error == nil
    # The retrying human is recorded truthfully.
    assert retried.approved_by_user_id == retrier.id
  end

  test "retrying a scheduled sibling's failed post leaves the sibling alone", ctx do
    tiktok_fails!(ctx)
    x_before = Repo.get!(Post, ctx.x_post.id)
    assert {:ok, _} = Social.retry_post(ctx.w.org_id, ctx.tiktok_post.id, ctx.w.approver.id)
    assert publish_keys() == [ctx.tiktok_post.id]
    assert Repo.get!(Post, ctx.x_post.id) == x_before
  end

  test "retry_post counts attempts", ctx do
    tiktok_fails!(ctx)
    assert Repo.get!(Post, ctx.tiktok_post.id).publish_attempts == 1

    Fake.put_next_for(ctx.w.tiktok.id, :publish, {:error, :still_down})

    assert {:error, {:publish_failed, :still_down}} =
             Social.retry_post(ctx.w.org_id, ctx.tiktok_post.id, ctx.w.approver.id)

    assert Repo.get!(Post, ctx.tiktok_post.id).publish_attempts == 2

    assert {:ok, _} = Social.retry_post(ctx.w.org_id, ctx.tiktok_post.id, ctx.w.approver.id)
    assert Repo.get!(Post, ctx.tiktok_post.id).publish_attempts == 3
    assert Repo.get!(Post, ctx.x_post.id).publish_attempts == 1
  end

  test "retry_post on a refused post goes through retry_publish", ctx do
    previous = Application.get_env(:social, :rate_limit)
    Application.put_env(:social, :rate_limit, per_window: 0, window_ms: 60_000)
    on_exit(fn -> Application.put_env(:social, :rate_limit, previous) end)

    ClipPublish.sweep_now(ctx.pid, DateTime.add(ctx.t0, 8, :second))

    refused = Repo.get!(Post, ctx.tiktok_post.id)
    assert %Post{status: "approved", refused_reason: "rate_limited"} = refused
    assert %DateTime{} = at = refused.retry_after
    assert Fake.calls(:publish) == []

    # retry_publish's own rule: before retry_after it waits.
    assert {:error, {:wait_until, ^at}} =
             Social.retry_post(ctx.w.org_id, refused.id, ctx.w.approver.id)

    assert Repo.get!(Post, refused.id).publish_attempts == 0

    # Once retry_after has passed (and the limit lifts), it re-runs publish_post.
    Application.put_env(:social, :rate_limit, previous)
    RateLimit.reset()

    Repo.update_all(from(p in Post, where: p.id == ^refused.id),
      set: [retry_after: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, %Post{status: "scheduled", refused_reason: nil}} =
             Social.retry_post(ctx.w.org_id, refused.id, ctx.w.approver.id)

    assert publish_keys() == [refused.id]
  end

  test "a non-approver and an agent cannot retry", ctx do
    tiktok_fails!(ctx)
    before = Repo.get!(Post, ctx.tiktok_post.id)
    stranger = member!(user!(), ctx.w.org_id)

    assert {:error, :not_an_approver} =
             Social.retry_post(ctx.w.org_id, ctx.tiktok_post.id, stranger.id)

    assert {:error, :not_a_human} =
             Social.retry_post(ctx.w.org_id, ctx.tiktok_post.id, ctx.w.agent.id)

    assert Repo.get!(Post, ctx.tiktok_post.id) == before
    assert Fake.calls(:publish) == []
  end

  test "retry_post on a published post is not_failed", ctx do
    ClipPublish.sweep_now(ctx.pid, DateTime.add(ctx.t0, 8, :second))

    {:ok, _} =
      Social.Publishing.apply_outcome(Repo.get!(Post, ctx.x_post.id), %{
        kind: :published,
        external_url: "https://x.example.test/1",
        error: nil
      })

    Fake.reset()

    assert {:error, :not_failed} =
             Social.retry_post(ctx.w.org_id, ctx.x_post.id, ctx.w.approver.id)

    # Scheduled and still-queued posts are not retryable either.
    assert {:error, :not_failed} =
             Social.retry_post(ctx.w.org_id, ctx.tiktok_post.id, ctx.w.approver.id)

    # Nor is a cancelled one.
    Repo.update_all(from(p in Post, where: p.id == ^ctx.tiktok_post.id),
      set: [status: "failed", error: "cancelled before publishing"]
    )

    assert {:error, :not_failed} =
             Social.retry_post(ctx.w.org_id, ctx.tiktok_post.id, ctx.w.approver.id)

    assert Fake.calls(:publish) == []
  end

  test "a cross-org post is not_found", ctx do
    tiktok_fails!(ctx)

    assert {:error, :not_found} =
             Social.retry_post(org_id!(), ctx.tiktok_post.id, ctx.w.approver.id)

    assert {:error, :not_found} =
             Social.retry_post(ctx.w.org_id, Ecto.UUID.generate(), ctx.w.approver.id)

    assert {:error, :not_found} = Social.retry_post(ctx.w.org_id, "nope", ctx.w.approver.id)

    # A post that is not a clip's is refused by name.
    plain = approved_post!(ctx.w.org_id, ctx.w.x)

    assert {:error, :not_a_clip_post} =
             Social.retry_post(ctx.w.org_id, plain.id, ctx.w.approver.id)

    assert Fake.calls(:publish) == []
  end
end
