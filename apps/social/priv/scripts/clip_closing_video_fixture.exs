# TEST ONLY integration seed. Run on an isolated test rig/private database:
# CLOSING_FIXTURE_ROOT=/private/generated CLOSING_FIXTURE_MANIFEST=/private/ids.json \
# MIX_ENV=test mix run --no-start priv/scripts/clip_closing_video_fixture.exs
# Generate the media first with clip_closing_video_fixture.py and the canonical runner.
unless Mix.env() == :test and System.get_env("PLATFORM_TEST_DATABASE") not in [nil, ""] do
  raise "requires MIX_ENV=test and a private PLATFORM_TEST_DATABASE"
end

# A browser server must use this same private blob root.
if root = System.get_env("CLOSING_FIXTURE_STORAGE_ROOT") do
  Application.put_env(:platform, :chat_attachments_root, root)
end

{:ok, _} = Application.ensure_all_started(:social)
Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, :auto)
Logger.configure(level: :warning)

alias Platform.Social.{ClipClosingVideo, ClipJobs, ClipVersions}
root = System.fetch_env!("CLOSING_FIXTURE_ROOT")
output_path = System.fetch_env!("CLOSING_FIXTURE_MANIFEST")
world = Platform.SocialFixtures.render_world!()

{:ok, profile} =
  Platform.Social.update_profile(world.org_id, world.profile, %{name: "Closing video — TEST ONLY"})

assets =
  for label <- ~w(A B), into: %{} do
    filename = "closing-TEST-ONLY-#{label}.mp4"

    upload_name =
      if label == "A",
        do: "closing-TEST-ONLY-A-with-a-long-filename-to-check-phone-truncation.mp4",
        else: filename

    {:ok, %{file: file}} =
      ClipClosingVideo.upload(
        world.org_id,
        profile.id,
        world.approver.id,
        File.read!(Path.join(root, filename)),
        upload_name,
        "video/mp4"
      )

    {label, file}
  end

{:ok, _} =
  ClipClosingVideo.save(world.org_id, profile.id, world.approver.id, %{
    file_id: assets["A"].id,
    enabled: true,
    audio: "keep"
  })

clips =
  for {name, audio} <- [{"clip1-A-keep", "keep"}, {"clip2-A-mute", "mute"}] do
    {:ok, _} = ClipClosingVideo.save(world.org_id, profile.id, world.approver.id, %{audio: audio})

    {:ok, %{job: job}} =
      ClipJobs.enqueue_new_clip(world.org_id, profile.id, world.approver.id, %{
        source_url: "https://example.com/TEST-ONLY-source",
        in_s: 0,
        out_s: 5,
        title: name <> " — TEST ONLY"
      })

    {:ok, _} = ClipJobs.claim(world.scope, job.id, world.agent.id)

    file =
      Platform.SocialFixtures.stored_file!(
        world.project,
        File.read!(Path.join(root, name <> ".mp4")),
        name <> "-TEST-ONLY.mp4",
        "video/mp4"
      )

    {:ok, %{clip: clip}} =
      ClipJobs.complete(world.scope, job.id, world.agent.id, %{
        file_id: file.id,
        candidate_id: "abc123",
        actual_in_s: 0,
        actual_out_s: 5
      })

    {:ok, [render | _]} = ClipVersions.recent(world.org_id, profile.id, clip.id)
    %{clip_id: clip.id, render_id: render.id, file_id: file.id}
  end

{:ok, _} =
  ClipClosingVideo.save(world.org_id, profile.id, world.approver.id, %{
    file_id: assets["B"].id,
    enabled: true,
    audio: "mute"
  })

manifest = %{
  org_id: world.org_id,
  profile_id: profile.id,
  project_id: world.project.id,
  user_id: world.approver.id,
  agent_id: world.agent.id,
  a: assets["A"].id,
  b: assets["B"].id,
  clips: clips
}

File.write!(output_path, Jason.encode!(manifest, pretty: true))
File.chmod!(output_path, 0o600)

IO.puts(
  "TEST ONLY fixture seeded two pending clips; saved default is B/mute. Manifest contains identities only, no credentials."
)
