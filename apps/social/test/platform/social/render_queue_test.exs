defmodule Platform.Social.RenderQueueTest do
  @moduledoc """
  The clip render queue (Social 5/7) with the Fake renderer: the tool call
  returns at once while the render runs in another process; statuses go
  candidate -> rendering -> rendered | failed; concurrency 1 runs renders
  one at a time; a raising or killed render ends failed and the queue keeps
  serving; a restarted queue re-enqueues what it lost, once.

  `async: false`: the app's queue and the Fake renderer are shared.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, RenderQueue}
  alias Platform.Social.Renderer.Fake

  setup do
    Fake.reset()
    world = render_world!()
    Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(world.profile.id))
    world
  end

  defp await_status(clip_id, status, timeout \\ 5_000) do
    assert_receive {:social_clip, %Clip{id: ^clip_id, status: ^status} = clip}, timeout
    clip
  end

  defp blocked do
    assert_receive {:fake_render_blocked, ref, pid}, 5_000
    {ref, pid}
  end

  # The queue hears a task's result just after the clip's own broadcast.
  defp idle?(server \\ RenderQueue, tries \\ 50) do
    case RenderQueue.status(server) do
      %{running: [], queued: []} ->
        true

      _ when tries == 0 ->
        false

      _ ->
        receive do
          :never -> :ok
        after
          20 -> idle?(server, tries - 1)
        end
    end
  end

  defp tool(world, name, args) do
    ToolArguments.dispatch(name, args, %{agent_id: world.agent.id})
  end

  test "the tool call returns in under 200ms, in rendering, while the render is blocked elsewhere",
       world do
    clip = file_clip!(world, 4.3, 15.2)
    Fake.block_next(self())

    {micros, result} =
      :timer.tc(fn -> tool(world, "social_clip_render", %{"clip_id" => clip.id}) end)

    assert {:ok, %{clip: %{status: "rendering"}}} = result
    assert micros < 200_000, "the call took #{div(micros, 1000)}ms"

    {ref, render_pid} = blocked()
    assert render_pid != self()
    assert Repo.get!(Clip, clip.id).status == "rendering"

    send(render_pid, {:release, ref})
    rendered = await_status(clip.id, "rendered")

    # requested times kept; snapped to the 4.0 and 16.0 sentence boundaries
    assert {rendered.requested_start_s, rendered.requested_end_s} == {4.3, 15.2}
    assert {rendered.start_s, rendered.end_s} == {4.0, 16.0}
    assert rendered.render_file_id
    assert {rendered.width, rendered.height} == {1080, 1920}
    assert_in_delta rendered.duration_s, 14.0, 0.001
    assert rendered.byte_size > 0
    assert rendered.attempts == 1
    assert rendered.platforms == ["tiktok", "x"]
  end

  test "concurrency 1: B does not start until A finishes; a raise ends C failed, queue alive",
       world do
    assert RenderQueue.concurrency() == 1
    queue = Process.whereis(RenderQueue)

    [a, b, c] = for _ <- 1..3, do: file_clip!(world, 4.0, 12.0)
    Fake.block_next(self())
    Fake.block_next(self())
    Fake.raise_next()

    {:ok, _} = Social.render_clip(world.scope, a.id)
    {:ok, _} = Social.render_clip(world.scope, b.id)
    {:ok, _} = Social.render_clip(world.scope, c.id)

    {ref_a, pid_a} = blocked()
    refute_receive {:fake_render_blocked, _, _}, 300
    assert Repo.get!(Clip, b.id).status == "rendering"

    send(pid_a, {:release, ref_a})
    await_status(a.id, "rendered")

    {ref_b, pid_b} = blocked()
    send(pid_b, {:release, ref_b})
    await_status(b.id, "rendered")

    failed = await_status(c.id, "failed")
    assert failed.error == "render crashed: fake renderer crashed"
    assert failed.render_file_id == nil

    assert Process.whereis(RenderQueue) == queue
    assert idle?()

    # the queue still serves a good render
    d = file_clip!(world, 4.0, 12.0)
    {:ok, _} = Social.render_clip(world.scope, d.id)
    await_status(d.id, "rendered")
  end

  test "a render task killed mid-render is recorded failed; the queue keeps serving", world do
    clip = file_clip!(world, 4.0, 12.0)
    Fake.block_next(self())
    {:ok, _} = Social.render_clip(world.scope, clip.id)
    {_ref, pid} = blocked()

    Process.exit(pid, :kill)
    failed = await_status(clip.id, "failed")
    assert failed.error == "render crashed: the render process was killed"

    # failed may render again
    {:ok, %{status: "rendering"}} = Social.render_clip(world.scope, clip.id)
    await_status(clip.id, "rendered")
  end

  test "the queue process is killed mid-render: it restarts and re-renders the clip once",
       world do
    clip = file_clip!(world, 4.0, 12.0)
    Fake.block_next(self())
    {:ok, _} = Social.render_clip(world.scope, clip.id)
    {_ref, render_pid} = blocked()
    render_ref = Process.monitor(render_pid)

    old = Process.whereis(RenderQueue)
    Process.exit(old, :kill)

    # the restarted queue stops its predecessor's task and re-enqueues the clip
    assert_receive {:DOWN, ^render_ref, :process, ^render_pid, _}, 5_000
    rendered = await_status(clip.id, "rendered")
    assert rendered.attempts == 2
    assert Process.whereis(RenderQueue) not in [nil, old]
  end

  test "boot recovery: attempts < 2 is re-enqueued, the rest fail", world do
    retry = file_clip!(world, 4.0, 12.0)
    stuck = file_clip!(world, 4.0, 12.0)

    Repo.update_all(Ecto.Query.where(Clip, [c], c.id == ^retry.id),
      set: [status: "rendering", attempts: 1]
    )

    Repo.update_all(Ecto.Query.where(Clip, [c], c.id == ^stuck.id),
      set: [status: "rendering", attempts: 2]
    )

    start_supervised!({Task.Supervisor, name: :social_test_render_tasks})

    start_supervised!(
      {RenderQueue,
       name: :social_test_render_queue, task_supervisor: :social_test_render_tasks, recover: true}
    )

    await_status(retry.id, "rendered")
    failed = await_status(stuck.id, "failed")
    assert failed.error == "render interrupted by a restart"
  end

  # The job writes the clip's terminal status (and broadcasts it) BEFORE
  # its task returns, so a caller can re-request a render while the queue
  # still lists the clip as running. That request must run after the
  # current one, not be dropped as a duplicate (it left a forced re-render
  # stuck in `rendering`).
  test "a clip enqueued while its render is finishing renders again afterwards" do
    test_pid = self()

    job = fn clip_id ->
      ref = make_ref()
      send(test_pid, {:job_finishing, ref, self(), clip_id})

      receive do
        {:finish, ^ref} -> {:ok, clip_id}
      end
    end

    start_supervised!({Task.Supervisor, name: :social_test_rerun_tasks})

    queue =
      start_supervised!(
        {RenderQueue,
         name: :social_test_rerun_queue,
         task_supervisor: :social_test_rerun_tasks,
         job: job,
         recover: false}
      )

    clip_id = Ecto.UUID.generate()
    RenderQueue.enqueue(clip_id, queue)
    assert_receive {:job_finishing, ref1, pid1, ^clip_id}, 5_000

    # re-requested while the first run is still the queue's running task
    RenderQueue.enqueue(clip_id, queue)
    RenderQueue.enqueue(clip_id, queue)
    assert %{running: [^clip_id], queued: []} = RenderQueue.status(queue)

    send(pid1, {:finish, ref1})
    assert_receive {:job_finishing, ref2, pid2, ^clip_id}, 5_000
    send(pid2, {:finish, ref2})

    # two enqueues during one run collapse into a single re-run
    refute_receive {:job_finishing, _, _, _}, 300
    assert idle?(queue)
  end

  describe "render_clip/3 refusals" do
    test "rendering, rendered without force, another org's clip", world do
      clip = file_clip!(world, 4.0, 12.0)
      Fake.block_next(self())
      {:ok, _} = Social.render_clip(world.scope, clip.id)
      {ref, pid} = blocked()

      assert {:error, :already_rendering} = Social.render_clip(world.scope, clip.id)

      send(pid, {:release, ref})
      await_status(clip.id, "rendered")

      assert {:error, :already_rendered} = Social.render_clip(world.scope, clip.id)
      assert {:error, :not_found} = Social.render_clip({:tenant, world.other_org_id}, clip.id)

      assert {:ok, %{status: "rendering"}} =
               Social.render_clip(world.scope, clip.id, force: true)

      await_status(clip.id, "rendered")
    end

    test "platforms must be among the profile's accounts", world do
      clip = file_clip!(world, 4.0, 12.0)

      assert {:error, {:invalid_platforms, ["instagram"]}} =
               Social.render_clip(world.scope, clip.id, platforms: ["instagram"])

      assert Repo.get!(Clip, clip.id).status == "candidate"
    end
  end
end
