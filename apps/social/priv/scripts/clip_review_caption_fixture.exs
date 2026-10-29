# Dedicated browser fixture server; never run against a shared/dev database.
# From apps/social, after mix test has prepared the private test database:
# MIX_ENV=test PLATFORM_TEST_DATABASE=platform_test_<unique> \
# CLIP_REVIEW_VIDEO=/absolute/test.mp4 CLIP_REVIEW_OUTPUT=/tmp/clip-review.json \
# mix run --no-start priv/scripts/clip_review_viewport_fixture.exs
# Then CLIP_REVIEW_FIXTURE=/tmp/clip-review.json npx playwright test
# tests/social_clip_review_viewport.spec.ts --project=chromium --retries=0
unless Mix.env() == :test and
         String.starts_with?(System.get_env("PLATFORM_TEST_DATABASE", ""), "platform_test_") do
  raise "Use MIX_ENV=test and a private PLATFORM_TEST_DATABASE=platform_test_<unique>"
end

port = System.get_env("CLIP_REVIEW_PORT", "4461") |> String.to_integer()
output = System.fetch_env!("CLIP_REVIEW_OUTPUT") |> Path.expand()
bytes = System.fetch_env!("CLIP_REVIEW_VIDEO") |> File.read!()

Application.put_env(
  :platform,
  PlatformWeb.Endpoint,
  Application.get_env(:platform, PlatformWeb.Endpoint)
  |> Keyword.merge(server: true, http: [ip: {127, 0, 0, 1}, port: port], check_origin: false)
)

{:ok, _} = Application.ensure_all_started(:social)
Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, :auto)
import Platform.SocialFixtures
w = render_world!()

{:ok, _} =
  Platform.Social.update_profile(w.org_id, w.profile, %{name: "Clip Review viewport fixture"})

file = stored_file!(w.project, bytes, "clip.mp4", "video/mp4")

clips =
  for n <- 1..35 do
    {:ok, clip} =
      Platform.Social.AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => "Clip #{n}: A long queue should never hide decisions",
          "episode_code" => "S3E12",
          "duration_s" => 5,
          "caption" => String.duplicate("A caption for review. ", 30),
          "platforms" => ["tiktok", "x"]
        },
        w.agent.id
      )

    clip
  end

for n <- 1..12 do
  pipeline =
    Platform.Repo.insert!(%Platform.Social.EpisodePipeline{
      profile_id: w.profile.id,
      version: "viewport-fixture-#{n}",
      activated_at: DateTime.utc_now()
    })

  Platform.Repo.insert!(%Platform.Social.ClipJob{
    profile_id: w.profile.id,
    source_file_id: w.video.id,
    episode_pipeline_id: pipeline.id,
    kind: "episode",
    status: "failed",
    error: "RUNNER_UNAVAILABLE",
    payload: %{}
  })
end

# Authenticated fixture cookie stays in a local file, never stdout or git.
conn =
  Plug.Test.conn(:get, "/")
  |> Map.put(:secret_key_base, PlatformWeb.Endpoint.config(:secret_key_base))
  |> Plug.Session.call(
    Plug.Session.init(
      store: :cookie,
      key: "_platform_session",
      signing_salt: "LVkhtRt/",
      same_site: "Lax"
    )
  )
  |> Plug.Conn.fetch_session()
  |> Plug.Conn.put_session(:current_user_id, w.approver.id)
  |> Plug.Conn.send_resp(200, "ok")

File.write!(
  output,
  Jason.encode!(%{
    cookie: conn.resp_cookies["_platform_session"].value,
    base_url: "http://127.0.0.1:#{port}",
    clip_ids: Enum.map(clips, & &1.id)
  })
)

IO.puts("CLIP_REVIEW_READY #{output}")
# Test driver requests completion/failure through a private local file. No app route.
command_path = output <> ".command"

handle = fn ->
  if File.exists?(command_path) do
    command = File.read!(command_path) |> Jason.decode!()
    File.rm!(command_path)
    jobs = Platform.Repo.all(Platform.Social.ClipJob)

    job =
      Enum.find(
        jobs,
        &(&1.profile_id == w.profile.id and &1.kind == "rerender" and &1.status == "queued" and
            &1.payload["appearance"])
      )

    if job do
      {:ok, _} = Platform.Social.ClipJobs.claim(w.scope, job.id, w.agent.id)

      if command["action"] == "fail" do
        {:ok, _} =
          Platform.Social.ClipJobs.fail(
            w.scope,
            job.id,
            w.agent.id,
            "APPEARANCE_PROJECT_MISSING",
            "Original project missing"
          )
      else
        style = job.payload["clip_overrides"]["mapped"]["captions.style"]
        rendered = File.read!(Path.join(System.fetch_env!("CLIP_STYLE_VIDEOS"), style <> ".mp4"))
        next_file = stored_file!(w.project, rendered, "preview.mp4", "video/mp4")

        {:ok, _} =
          Platform.Social.ClipJobs.complete(w.scope, job.id, w.agent.id, %{file_id: next_file.id})
      end

      File.write!(output <> ".receipt", Jason.encode!(%{job_id: job.id, payload: job.payload}))
    end
  end
end

Stream.repeatedly(fn ->
  handle.()
  Process.sleep(100)
end)
|> Stream.run()
