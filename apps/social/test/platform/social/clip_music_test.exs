defmodule Platform.Social.ClipMusicTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Social.{ClipJobs, ClipLook, ClipMusic, ClipVersions, Tools}

  setup do
    w = render_world!()

    {:ok, %{job: job}} =
      ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
        source_url: "https://example.com/source.mp4",
        in_s: 1,
        out_s: 6
      })

    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
    video = stored_file!(w.project, "video #{unique()}", "v1.mp4", "video/mp4")

    {:ok, %{clip: clip}} =
      ClipJobs.complete(w.scope, job.id, w.agent.id, %{
        file_id: video.id,
        candidate_id: "candidate"
      })

    {:ok, [base]} = ClipVersions.recent(w.scope, w.profile.id, clip.id)
    song = stored_file!(w.project, "RIFF0000WAVEtest #{unique()}", "song.wav", "audio/wav")
    %{w: w, clip: clip, base: base, song: song}
  end

  defp enqueue(w, clip, base, song, gain \\ -18, muted \\ false) do
    ClipJobs.enqueue_appearance(w.org_id, clip.id, w.approver.id, %{
      base_render_id: base.id,
      look: %{
        cap: %{style: "plain"},
        music_track: %{file_id: song && song.id, gain_db: gain, muted: muted}
      }
    })
  end

  test "persist selected track and gain, claimer-only signed source, immutable history and retry dedup",
       %{w: w, clip: c, base: b, song: s} do
    assert {:ok, j} = enqueue(w, c, b, s, -32)
    assert j.payload["music"] == %{"file_id" => s.id, "enabled" => true, "level_db" => -32}
    refute Map.has_key?(j.payload["clip_overrides"]["mapped"], "audio.target_lufs")
    refute Jason.encode!(j.payload) =~ "storage_key"
    refute Jason.encode!(j.payload) =~ "https://suite"
    assert {:error, :not_claimer} = ClipJobs.source_download(w.scope, j.id, w.agent.id, "music")
    assert {:ok, _} = ClipJobs.claim(w.scope, j.id, w.agent.id)

    assert {:error, :not_claimer} =
             ClipJobs.source_download(w.scope, j.id, pinned_agent!(w.org_id).id, "music")

    assert {:ok, source} =
             Tools.execute("social_clip_job_source", %{"job_id" => j.id, "asset" => "music"}, %{
               agent_id: w.agent.id
             })

    assert source.file_id == s.id and source.project_id == w.project.id

    assert is_binary(source.url) and
             DateTime.diff(source.expires_at, DateTime.utc_now()) in 890..900

    assert {:error, :job_in_flight} = enqueue(w, c, b, s, -12)
    f = stored_file!(w.project, "new video #{unique()}", "v2.mp4", "video/mp4")

    assert {:ok, %{clip: updated}} =
             ClipJobs.complete(w.scope, j.id, w.agent.id, %{file_id: f.id})

    assert {:error, :job_closed} = ClipJobs.complete(w.scope, j.id, w.agent.id, %{file_id: f.id})
    assert updated.review_status == "pending"
    assert {:ok, [v2, v1]} = ClipVersions.recent(w.scope, w.profile.id, c.id)
    assert v2.look["music_track"]["file_id"] == s.id
    assert v2.look["music_track"]["gain_db"] == -32
    assert v1.id == b.id and Platform.Files.get_file(v1.file_id)
    assert {:error, :job_closed} = ClipJobs.source_download(w.scope, j.id, w.agent.id, "music")
  end

  test "foreign, deleted, nonaudio, oversized and unfinalized assets cannot enqueue", %{
    w: w,
    clip: c,
    base: b,
    song: s
  } do
    other = render_world!()

    foreign =
      stored_file!(other.project, "RIFF0000WAVEforeign #{unique()}", "foreign.wav", "audio/wav")

    video = stored_file!(w.project, "video #{unique()}", "bad.mp4", "video/mp4")

    for f <- [foreign, video, %{s | id: Ecto.UUID.generate()}] do
      assert {:error, :music_unavailable} = enqueue(w, c, b, f)
    end

    Platform.Repo.update_all(Ecto.Query.from(f in Platform.Files.File, where: f.id == ^s.id),
      set: [byte_size: ClipMusic.max_bytes() + 1]
    )

    assert {:error, :music_unavailable} = enqueue(w, c, b, s)

    Platform.Repo.update_all(Ecto.Query.from(f in Platform.Files.File, where: f.id == ^s.id),
      set: [byte_size: 20, deleted_at: DateTime.utc_now()]
    )

    assert {:error, :music_unavailable} = enqueue(w, c, b, s)
  end

  test "asset removed after enqueue is refused at download, foreign scope never grants a URL", %{
    w: w,
    clip: c,
    base: b,
    song: s
  } do
    {:ok, j} = enqueue(w, c, b, s)
    {:ok, _} = ClipJobs.claim(w.scope, j.id, w.agent.id)
    other = render_world!()
    assert {:error, :not_found} = ClipJobs.source_download(other.scope, j.id, w.agent.id, "music")

    Platform.Repo.update_all(Ecto.Query.from(f in Platform.Files.File, where: f.id == ^s.id),
      set: [deleted_at: DateTime.utc_now()]
    )

    assert {:error, :music_unavailable} =
             ClipJobs.source_download(w.scope, j.id, w.agent.id, "music")
  end

  test "mute retains chosen gain, None disables music, gain and paths reject invalid input", %{
    w: w,
    clip: c,
    base: b,
    song: s
  } do
    assert {:ok, j} = enqueue(w, c, b, s, -60, true)
    assert j.payload["music"] == %{"enabled" => false, "file_id" => s.id, "level_db" => -60}
    {:ok, _} = ClipJobs.claim(w.scope, j.id, w.agent.id)
    {:ok, _} = ClipJobs.fail(w.scope, j.id, w.agent.id, "MUSIC_DOWNLOAD_FAILED", "safe")
    assert {:ok, none} = enqueue(w, c, b, nil, 0, true)
    assert none.payload["music"]["enabled"] == false

    for attrs <- [
          %{gain_db: -61},
          %{gain_db: 1},
          %{gain_db: "-18"},
          %{file_id: "/tmp/music.wav"},
          %{url: "https://private"},
          %{path: "/tmp/audio"}
        ] do
      assert {:error, _} = ClipLook.validate(%{music_track: attrs})
    end

    assert {:ok, _} = ClipLook.validate(%{music: true, level: -18})
    refute Map.has_key?(ClipLook.effective(%{}), "music_track")
  end

  test "upload validates actual bytes, size, MIME and fresh approver authorization", %{w: w} do
    assert {:error, _} =
             ClipMusic.upload(w.profile, w.approver.id, "not audio", "song.wav", "audio/wav")

    assert {:error, _} =
             ClipMusic.upload(w.profile, w.approver.id, "RIFF0000WAVE", "song.txt", "text/plain")

    assert {:error, _} =
             ClipMusic.upload(w.profile, w.agent.id, "RIFF0000WAVEvalid", "song.wav", "audio/wav")

    assert {:error, _} =
             ClipMusic.upload(
               w.profile,
               w.approver.id,
               "RIFF0000WAVE" <> :binary.copy("x", ClipMusic.max_bytes()),
               "large.wav",
               "audio/wav"
             )

    bytes = "RIFF0000WAVEupload #{unique()}"

    assert {:ok, f} =
             ClipMusic.upload(w.profile, w.approver.id, bytes, "../song.wav", "audio/wav")

    assert f.project_id == w.project.id and f.name == "song.wav"

    assert {:ok, again} =
             ClipMusic.upload(w.profile, w.approver.id, bytes, "song.wav", "audio/wav")

    assert again.id == f.id
    {:ok, _} = Platform.Social.update_profile(w.org_id, w.profile, %{approver_user_ids: []})

    assert {:error, _} =
             ClipMusic.upload(
               w.profile,
               w.approver.id,
               "RIFF0000WAVEnew",
               "song.wav",
               "audio/wav"
             )

    assert {:error, _} = ClipMusic.list(w.profile, w.approver.id)
  end

  test "show defaults validate asset ownership but never persist a disposable renderer path", %{
    w: w,
    song: song
  } do
    other = render_world!()

    foreign =
      stored_file!(other.project, "RIFF0000WAVEother #{unique()}", "other.wav", "audio/wav")

    assert {:error, :music_unavailable} =
             ClipJobs.save_show_default(w.org_id, w.profile.id, w.approver.id, %{
               music_track: %{file_id: foreign.id, gain_db: -18, muted: false}
             })

    assert {:ok, %{job: job}} =
             ClipJobs.save_show_default(w.org_id, w.profile.id, w.approver.id, %{
               music_track: %{file_id: song.id, gain_db: -18, muted: false}
             })

    refute Map.has_key?(job.payload["clip_overrides"]["mapped"], "music.path")
    refute Map.has_key?(job.payload["clip_overrides"]["mapped"], "music.enabled")
    assert job.payload["look"]["music_track"]["file_id"] == song.id
  end
end
