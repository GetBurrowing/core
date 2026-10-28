defmodule Platform.Social.EpisodeFakeRunner do
  @moduledoc """
  Deterministic protocol peer, not an agent-side runner. Calls real public
  tools/storage with prerecorded headline MP4s; no CLI, model or vendor.
  Canonical helper behavior is tested separately in burrow-clip-runner.
  Generated text stays in local fixture artifacts, never MCP.
  """
  use GenServer

  alias Platform.Files
  alias Platform.Social.Tools
  @fixtures Path.expand("fixtures/episode_pipeline", __DIR__)
  @picks [
    %{id: "demo", start: 1.0, stop: 8.0, output: "one.mp4", headline: "The demo finally worked"},
    %{
      id: "button",
      start: 10.0,
      stop: 19.0,
      output: "two.mp4",
      headline: "We fixed the wrong button"
    },
    %{id: "bug", start: 22.0, stop: 31.0, output: "three.mp4", headline: "The tiny bug won again"}
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    send(self(), :poll)
    {:ok, opts}
  end

  @impl true
  def handle_info(:poll, opts) do
    world = Keyword.fetch!(opts, :world)
    args = %{"profile_id" => world.profile.id, "status" => "queued", "kind" => "episode"}

    {:ok, %{jobs: jobs}} =
      Tools.execute("social_clip_job_list", args, %{agent_id: world.agent.id})

    case jobs do
      [] ->
        Process.send_after(self(), :poll, 10)

      [job | _] ->
        trace = run(world, job, opts)
        send(Keyword.fetch!(opts, :notify), {:episode_runner, job.id, trace})
    end

    {:noreply, opts}
  end

  def run(world, job, opts \\ []) do
    Process.put({__MODULE__, :calls}, [])
    Process.put({__MODULE__, :local}, [])
    ctx = %{agent_id: world.agent.id}
    {:ok, %{job: claimed}} = call("social_clip_job_claim", %{"job_id" => job.id}, ctx)

    if opts[:failure] == :before_picks do
      fail(claimed, ctx, "HEADLINE_CLI_UNSUPPORTED")
    else
      {:ok, source} = call("social_clip_job_source", %{"job_id" => claimed.id}, ctx)
      token = source.url |> URI.parse() |> Map.fetch!(:path) |> String.split("/") |> List.last()
      {:ok, source_id} = Files.SignedUrl.verify(token)
      source_file = Platform.Repo.get!(Files.File, source_id)
      {:ok, stream} = Files.Storage.get(source_file.storage_key)
      _downloaded_bytes = stream |> Enum.to_list() |> IO.iodata_to_binary()
      picks = if opts[:zero_picks], do: [], else: @picks
      plan = Enum.map(picks, &%{"candidate_id" => &1.id, "in_s" => &1.start, "out_s" => &1.stop})
      args = %{"job_id" => claimed.id, "progress" => 0.4, "picks" => plan}
      {:ok, %{jobs: children}} = call("social_clip_job_progress", args, ctx)
      {:ok, %{jobs: replay}} = call("social_clip_job_progress", args, ctx)
      true = Enum.map(children, & &1.id) == Enum.map(replay, & &1.id)

      if owner = opts[:observer] do
        snapshot =
          Enum.map(children, fn child ->
            clip = Platform.Repo.get!(Platform.Social.Clip, child.clip_id)
            {clip.status, clip.render_file_id}
          end)

        send(owner, {:episode_candidates, children, snapshot})
      end

      failed =
        Enum.reduce(Enum.zip(children, picks), false, fn {child, pick}, failed ->
          {:ok, %{job: child}} = call("social_clip_job_claim", %{"job_id" => child.id}, ctx)

          if opts[:failure] == :second_render and pick.id == "button" do
            fail(child, ctx, "HEADLINE_RENDER_MISSING")
            true
          else
            bytes = File.read!(Path.join(@fixtures, pick.output))

            {:ok, file, false} =
              Files.add_bytes(world.project, bytes, "clip-#{child.clip_id}.mp4", "video/mp4",
                ingest: false
              )

            Process.put({__MODULE__, :local}, [
              %{candidate_id: pick.id, headline: pick.headline, file_id: file.id}
              | Process.get({__MODULE__, :local})
            ])

            {:ok, _} =
              call(
                "social_clip_job_complete",
                %{"job_id" => child.id, "file_id" => file.id, "headline_applied" => true},
                ctx
              )

            failed
          end
        end)

      unless failed, do: call("social_clip_job_complete", %{"job_id" => claimed.id}, ctx)
    end

    %{
      calls: Enum.reverse(Process.get({__MODULE__, :calls})),
      artifacts: Enum.reverse(Process.get({__MODULE__, :local}))
    }
  end

  defp fail(job, ctx, code),
    do: call("social_clip_job_fail", %{"job_id" => job.id, "code" => code, "error" => code}, ctx)

  defp call(tool, args, ctx) do
    Process.put({__MODULE__, :calls}, [{tool, args} | Process.get({__MODULE__, :calls})])
    Tools.execute(tool, args, ctx)
  end
end
