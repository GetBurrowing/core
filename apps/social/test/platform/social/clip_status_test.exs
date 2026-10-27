defmodule Platform.Social.ClipStatusTest do
  @moduledoc """
  Clip Studio 2/9 (task 01a16662) stage 3: per-platform status is one entry
  per post and is never rolled up; `clip_state/2` is a separate label in the
  studio prototype's order; every failed entry points at its own account to
  reconnect. Not async: ClipPublish runs in its own process and the Fake's
  call log is global.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{Account, AgentDrafts, Clip, ClipLibrary, ClipPublish, Post, Publishing}
  alias Platform.Social.{RateLimit}
  alias Platform.Social.Publisher.Fake

  @now ~U[2026-10-23 12:00:00.000000Z]

  defp post(attrs) do
    struct!(
      %Post{
        id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate(),
        account: %Account{platform: "tiktok"},
        publish_attempts: 0,
        updated_at: @now
      },
      attrs
    )
  end

  defp later(s), do: DateTime.add(@now, s, :second)

  test "platform_status maps every post status" do
    cases = [
      {post(status: "draft"), :queued},
      {post(status: "needs_approval"), :queued},
      {post(status: "approved", publish_after: later(5)), :queued},
      {post(status: "approved", publish_after: nil), :uploading},
      {post(status: "scheduled", external_id: "z1", scheduled_at: nil), :uploading},
      {post(status: "scheduled", external_id: "z1", scheduled_at: later(-1)), :uploading},
      {post(status: "scheduled", external_id: "z1", scheduled_at: later(3600)), :scheduled},
      {post(status: "published", external_url: "https://t.example/1", published_at: later(-5)),
       :published},
      {post(status: "failed", error: "token expired", publish_attempts: 2), :failed},
      {post(
         status: "approved",
         publish_after: nil,
         refused_reason: "rate_limited",
         refused_at: later(-2),
         error: "TikTok's posting limit is reached."
       ), :failed}
    ]

    for {p, state} <- cases do
      entry = ClipLibrary.platform_status(p, @now)
      assert entry.state == state, "#{p.status}: got #{entry.state}, want #{state}"
      assert entry.pct == nil
      assert entry.views == nil
      assert entry.post_id == p.id
      assert entry.account_id == p.account_id
      assert entry.platform == "tiktok"
    end

    [_, _, queued, _, _, _, scheduled, published, failed, refused] =
      Enum.map(cases, fn {p, _} -> ClipLibrary.platform_status(p, @now) end)

    assert queued.at == later(5)
    assert scheduled.at == later(3600)
    assert {published.at, published.url} == {later(-5), "https://t.example/1"}
    assert {failed.error, failed.attempts} == {"token expired", 2}
    assert {refused.error, refused.at} == {"TikTok's posting limit is reached.", later(-2)}
  end

  test "clip_state follows the prototype order" do
    e = fn states -> Enum.map(states, &%{state: &1}) end
    approved = %Clip{review_status: "approved"}

    assert ClipLibrary.clip_state(%Clip{review_status: "pending"}, []) == "In review"
    assert ClipLibrary.clip_state(%Clip{review_status: "rejected"}, []) == "Rejected"

    assert ClipLibrary.clip_state(approved, e.([:published, :failed, :scheduled, :queued])) ==
             "Failed"

    assert ClipLibrary.clip_state(approved, e.([:published, :scheduled, :uploading])) ==
             "Scheduled"

    assert ClipLibrary.clip_state(approved, e.([:published, :uploading])) == "Publishing"
    assert ClipLibrary.clip_state(approved, e.([:queued, :published])) == "Publishing"
    assert ClipLibrary.clip_state(approved, e.([:published, :published])) == "Published"
    assert ClipLibrary.clip_state(approved, e.([:failed, :published])) == "Failed"
  end

  describe "a real clip" do
    setup do
      Fake.reset()
      RateLimit.reset()
      w = render_world!()
      {:ok, ig} = Social.create_account(w.org_id, w.profile, %{platform: "instagram"})
      file = stored_file!(w.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

      {:ok, clip} =
        AgentDrafts.submit_clip(
          w.scope,
          w.profile.id,
          %{
            "file_id" => file.id,
            "caption" => "c",
            "duration_s" => 30.0,
            "width" => 1080,
            "height" => 1920
          },
          w.agent.id
        )

      pid =
        start_supervised!(
          {ClipPublish, name: :clip_status_publish, interval_ms: :infinity, boot_sweep: false}
        )

      t0 = DateTime.utc_now()

      {:ok, %{posts: posts}} =
        Social.approve_clip(
          w.org_id,
          clip.id,
          w.approver.id,
          %{"render_id" => render_id!(clip), "account_ids" => [ig.id, w.tiktok.id]},
          now: t0,
          publish_server: pid
        )

      %{w: w, ig: ig, clip: Repo.get!(Clip, clip.id), posts: posts, pid: pid, t0: t0}
    end

    test "a published IG post and a failed TikTok post report separately", ctx do
      Fake.put_next_for(ctx.w.tiktok.id, :publish, {:error, "video rejected by TikTok"})
      ClipPublish.sweep_now(ctx.pid, DateTime.add(ctx.t0, 8, :second))

      ig_post = Enum.find(ctx.posts, &(&1.account_id == ctx.ig.id))

      {:ok, _} =
        Publishing.apply_outcome(Repo.get!(Post, ig_post.id), %{
          kind: :published,
          external_url: "https://ig.example.test/p/1",
          error: nil
        })

      entries = ClipLibrary.clip_status(ctx.clip)
      assert length(entries) == 2
      by = Map.new(entries, &{&1.platform, &1})

      assert %{state: :published, url: "https://ig.example.test/p/1", error: nil, reconnect: nil} =
               by["instagram"]

      assert %DateTime{} = by["instagram"].at

      assert %{state: :failed, error: "video rejected by TikTok", attempts: 1} = by["tiktok"]

      # The label is separate and never replaces the entries.
      assert ClipLibrary.clip_state(ctx.clip, entries) == "Failed"
      assert ClipLibrary.clip_state(ctx.clip) == "Failed"
    end

    test "every failed entry offers reconnect for its own account", ctx do
      Fake.put_next_for(ctx.w.tiktok.id, :publish, {:error, :token_expired})
      Fake.put_next_for(ctx.ig.id, :publish, {:error, :token_expired})
      ClipPublish.sweep_now(ctx.pid, DateTime.add(ctx.t0, 8, :second))

      entries = ClipLibrary.clip_status(ctx.clip)
      assert Enum.all?(entries, &(&1.state == :failed))

      for entry <- entries do
        assert entry.reconnect == %{account_id: entry.account_id, platform: entry.platform}
      end

      assert Enum.sort(Enum.map(entries, & &1.reconnect.account_id)) ==
               Enum.sort([ctx.ig.id, ctx.w.tiktok.id])

      # A refusal before the vendor is failed too, with its own reconnect.
      {:ok, refused} =
        Social.approve_post(
          ctx.w.org_id,
          elem(Social.create_post(ctx.w.org_id, ctx.w.x, %{body: "x"}), 1),
          ctx.w.approver.id
        )

      {:ok, _} = Social.archive_account(ctx.w.org_id, ctx.w.x)
      {:error, :account_archived} = Publishing.publish_post(ctx.w.org_id, refused.id)
      entry = ClipLibrary.platform_status(Repo.get!(Post, refused.id))
      assert entry.state == :failed
      assert entry.reconnect == %{account_id: ctx.w.x.id, platform: "x"}
    end

    test "queued inside the window, then uploading, never a rolled-up state", ctx do
      entries = ClipLibrary.clip_status(ctx.clip, ctx.t0)
      assert Enum.map(entries, & &1.state) == [:queued, :queued]
      assert ClipLibrary.clip_state(ctx.clip, entries) == "Publishing"

      ClipPublish.sweep_now(ctx.pid, DateTime.add(ctx.t0, 8, :second))
      entries = ClipLibrary.clip_status(ctx.clip)
      # The Fake answers scheduled with no scheduled_at: accepted, processing.
      assert Enum.map(entries, & &1.state) == [:uploading, :uploading]
      assert Enum.all?(entries, &(&1.pct == nil))
    end
  end
end
