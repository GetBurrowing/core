defmodule Platform.Social.ClipPublishTest do
  @moduledoc """
  Clip Studio 2/9 (task 01a16662) stage 2: `Platform.Social.ClipPublish`,
  the server-side undo window. All state is in the database, so a server
  that starts (the boot sweep) publishes what a restart left due, and a
  claim is one conditional update, so nothing publishes twice.

  Each test starts its own instance with `start_supervised!/1`. The shared
  sandbox (not async) lets that process use the test's connection. No sleep:
  `:sys.get_state/1` waits for the server to finish what it was sent.
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
    world = render_world!()
    file = stored_file!(world.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        world.scope,
        world.profile.id,
        %{"file_id" => file.id, "caption" => "c", "duration_s" => 30.0},
        world.agent.id
      )

    %{w: world, clip: clip}
  end

  # Approves the clip on both accounts as of `now`, against a parked server
  # that arms nothing, so only the instance under test can publish.
  defp approve!(ctx, now) do
    parked = :"clip_publish_parked_#{unique()}"
    start_supervised!({ClipPublish, name: parked, interval_ms: :infinity, boot_sweep: false})

    {:ok, %{posts: posts}} =
      Social.approve_clip(
        ctx.w.org_id,
        ctx.clip.id,
        ctx.w.approver.id,
        %{"render_id" => render_id!(ctx.clip), "account_ids" => [ctx.w.tiktok.id, ctx.w.x.id]},
        now: now,
        publish_server: parked
      )

    posts
  end

  defp published_keys,
    do: Fake.calls(:publish) |> Enum.map(fn {:publish, [_, req], _} -> req.idempotency_key end)

  test "a due post is published by the boot sweep", ctx do
    # Approved a minute ago; the window closed while nothing was running.
    posts = approve!(ctx, DateTime.add(DateTime.utc_now(), -60, :second))
    assert Fake.calls(:publish) == []

    pid =
      start_supervised!(
        {ClipPublish, name: :clip_publish_boot, interval_ms: :infinity, boot_sweep: true}
      )

    :sys.get_state(pid)

    assert Enum.sort(published_keys()) == Enum.sort(Enum.map(posts, & &1.id))

    for p <- posts,
        do: assert(%Post{status: "scheduled", publish_after: nil} = Repo.get!(Post, p.id))
  end

  test "the boot sweep leaves a post inside its window alone", ctx do
    posts = approve!(ctx, DateTime.utc_now())

    pid =
      start_supervised!(
        {ClipPublish, name: :clip_publish_boot_early, interval_ms: :infinity, boot_sweep: true}
      )

    :sys.get_state(pid)
    assert Fake.calls(:publish) == []
    for p <- posts, do: assert(Repo.get!(Post, p.id).status == "approved")
  end

  test "schedule/3 publishes once the window's end has passed", ctx do
    posts = approve!(ctx, DateTime.add(DateTime.utc_now(), -9, :second))

    pid =
      start_supervised!(
        {ClipPublish,
         name: :clip_publish_timer,
         interval_ms: 3_600_000,
         boot_sweep: false,
         timers: true,
         notify: self()}
      )

    publish_after = Repo.get!(Post, hd(posts).id).publish_after
    :ok = ClipPublish.schedule(Enum.map(posts, & &1.id), publish_after, :clip_publish_timer)

    assert_receive {:clip_publish_swept, ^pid, [_, _]}, 2_000
    assert Enum.sort(published_keys()) == Enum.sort(Enum.map(posts, & &1.id))
  end

  test "due/1 needs a clip post, approved, past publish_after and not yet sent", ctx do
    now = DateTime.utc_now()
    [p1, p2] = approve!(ctx, DateTime.add(now, -9, :second))

    due_ids = fn -> ClipPublish.due(now) |> Enum.map(&elem(&1, 1)) |> Enum.sort() end
    assert due_ids.() == Enum.sort([p1.id, p2.id])

    Repo.update_all(from(p in Post, where: p.id == ^p1.id), set: [external_id: "sent"])
    assert due_ids.() == [p2.id]

    Repo.update_all(from(p in Post, where: p.id == ^p2.id), set: [clip_id: nil])
    assert due_ids.() == []

    # A plain approved post with a publish_after is never this sweep's.
    plain = approved_post!(ctx.w.org_id, ctx.w.x)
    Repo.update_all(from(p in Post, where: p.id == ^plain.id), set: [publish_after: now])
    assert due_ids.() == []
  end

  test "a vendor failure is not retried by the sweep; the other account still publishes",
       ctx do
    now = DateTime.utc_now()
    posts = approve!(ctx, DateTime.add(now, -9, :second))
    Fake.put_next_for(ctx.w.tiktok.id, :publish, {:error, :token_expired})

    pid =
      start_supervised!(
        {ClipPublish, name: :clip_publish_fail, interval_ms: :infinity, boot_sweep: false}
      )

    results = ClipPublish.sweep_now(pid, now) |> Map.new()
    assert map_size(results) == 2

    by_account = Map.new(posts, &{&1.account_id, &1.id})
    assert {:error, {:publish_failed, :token_expired}} = results[by_account[ctx.w.tiktok.id]]
    assert {:ok, %Post{status: "scheduled"}} = results[by_account[ctx.w.x.id]]

    assert %Post{status: "failed", publish_after: nil, publish_attempts: 1} =
             Repo.get!(Post, by_account[ctx.w.tiktok.id])

    assert ClipPublish.sweep_now(pid, DateTime.add(now, 60, :second)) == []
    assert length(Fake.calls(:publish)) == 2
  end

  describe "the real timer path (stage 5)" do
    # No periodic sweep (interval :infinity) and no boot sweep, so ONLY the
    # window timer and its re-arm can publish; `notify` reports each
    # timer-driven sweep.
    defp timer_server!(name) do
      start_supervised!(
        {ClipPublish,
         name: name, interval_ms: :infinity, boot_sweep: false, timers: true, notify: self()}
      )
    end

    defp set_publish_after!(posts, at) do
      ids = Enum.map(posts, & &1.id)
      {n, _} = Repo.update_all(from(p in Post, where: p.id in ^ids), set: [publish_after: at])
      ^n = length(posts)
    end

    # A short busy-wait (no sleep): returns once the wall clock reaches `at`.
    defp spin_until(at) do
      if DateTime.compare(DateTime.utc_now(), at) == :lt, do: spin_until(at), else: :ok
    end

    test "a schedule whose floored delay would fire early still publishes on that one timer",
         ctx do
      posts = approve!(ctx, DateTime.utc_now())
      ids = Enum.map(posts, & &1.id)
      pid = timer_server!(:clip_publish_subms)

      # Eight rounds on the real timer. In each, publish_after carries a
      # sub-millisecond remainder and schedule/3 is called with ~0.5ms to go,
      # so a floored delay is 0 and a timer armed with it lands at or near
      # once, typically BEFORE publish_after. Every round must publish on its
      # one timer: with interval :infinity nothing else can.
      for round <- 1..8 do
        Repo.update_all(from(p in Post, where: p.id in ^ids),
          set: [status: "approved", external_id: nil, platform_post_id: nil]
        )

        publish_after = DateTime.add(DateTime.utc_now(), 30_000, :microsecond)
        set_publish_after!(posts, publish_after)
        spin_until(DateTime.add(publish_after, -500, :microsecond))
        :ok = ClipPublish.schedule(ids, publish_after, pid)

        assert_receive {:clip_publish_swept, ^pid, results}, 2_000

        assert length(results) == 2,
               "round #{round}: the first timer sweep found #{length(results)} due posts"

        assert Enum.all?(results, &match?({_, {:ok, %Post{status: "scheduled"}}}, &1))
      end

      assert length(Fake.calls(:publish)) == 16

      for p <- posts do
        row = Repo.get!(Post, p.id)
        assert row.status == "scheduled"
        assert row.publish_attempts == 8
      end
    end

    test "a timer that lands before publish_after still sweeps as of publish_after", ctx do
      posts = approve!(ctx, DateTime.utc_now())
      pid = timer_server!(:clip_publish_early)
      publish_after = DateTime.add(DateTime.utc_now(), 5, :second)
      set_publish_after!(posts, publish_after)

      # The early landing, delivered by hand seconds before publish_after.
      # Nothing was scheduled on this server and the wait (2s) ends before
      # publish_after (5s), so only this message can publish the posts.
      send(pid, {:window_closed, publish_after})

      assert_receive {:clip_publish_swept, ^pid, [_, _] = results}, 2_000
      assert Enum.all?(results, &match?({_, {:ok, %Post{status: "scheduled"}}}, &1))
    end

    test "a sweep that finds a not-yet-due post re-arms a timer for it", ctx do
      posts = approve!(ctx, DateTime.utc_now())
      pid = timer_server!(:clip_publish_rearm)
      set_publish_after!(posts, DateTime.add(DateTime.utc_now(), 40, :millisecond))

      # Nothing is due yet, and nothing was scheduled on this server.
      assert ClipPublish.sweep_now(pid) == []
      assert Fake.calls(:publish) == []

      # The re-arm alone publishes them when their window closes.
      assert_receive {:clip_publish_swept, ^pid, [_, _] = results}, 2_000
      assert Enum.all?(results, &match?({_, {:ok, %Post{status: "scheduled"}}}, &1))
      assert Enum.sort(published_keys()) == Enum.sort(Enum.map(posts, & &1.id))
    end

    test "an earlier window replaces a later armed timer, and the later one still fires",
         ctx do
      [p1, p2] = approve!(ctx, DateTime.utc_now())
      pid = timer_server!(:clip_publish_two)
      now = DateTime.utc_now()
      late = DateTime.add(now, 120, :millisecond)
      early = DateTime.add(now, 30, :millisecond)
      set_publish_after!([p1], late)
      set_publish_after!([p2], early)

      :ok = ClipPublish.schedule([p1.id], late, pid)
      :ok = ClipPublish.schedule([p2.id], early, pid)

      assert_receive {:clip_publish_swept, ^pid, [{id2, {:ok, _}}]}, 2_000
      assert id2 == p2.id
      assert_receive {:clip_publish_swept, ^pid, [{id1, {:ok, _}}]}, 2_000
      assert id1 == p1.id
      assert published_keys() == [p2.id, p1.id]
    end

    test "delay_ms rounds up to the next millisecond and is never negative" do
      now = DateTime.utc_now()
      assert ClipPublish.delay_ms(DateTime.add(now, 900, :microsecond), now) == 1
      assert ClipPublish.delay_ms(DateTime.add(now, 1_000, :microsecond), now) == 1
      assert ClipPublish.delay_ms(DateTime.add(now, 1_001, :microsecond), now) == 2
      assert ClipPublish.delay_ms(DateTime.add(now, 8_000_500, :microsecond), now) == 8_001
      assert ClipPublish.delay_ms(now, now) == 0
      assert ClipPublish.delay_ms(DateTime.add(now, -5, :millisecond), now) == 0
    end
  end
end
