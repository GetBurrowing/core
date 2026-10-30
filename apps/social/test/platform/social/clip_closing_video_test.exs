defmodule Platform.Social.ClipClosingVideoTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Social.{ClipClosingVideo, ClosingAsset, ClipJobs, EpisodeDiscovery, Profile}
  alias Platform.Files

  @moduletag :ffmpeg
  setup_all do
    path = Path.join(System.tmp_dir!(), "closing-test-#{System.unique_integer([:positive])}.mp4")

    {_, 0} =
      System.cmd("ffmpeg", [
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=c=magenta:s=64x96:d=0.4",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-y",
        path
      ])

    bytes = File.read!(path)
    File.rm!(path)
    %{bytes: bytes}
  end

  setup do
    %{w: render_world!()}
  end

  defp upload(w, bytes, name \\ "TEST-ONLY-closing.mp4"),
    do: ClipClosingVideo.upload(w.org_id, w.profile.id, w.approver.id, bytes, name, "video/mp4")

  defp save(w, attrs), do: ClipClosingVideo.save(w.org_id, w.profile.id, w.approver.id, attrs)
  defp current(w), do: Repo.get!(Profile, w.profile.id).closing_video

  test "picker upload is excluded before save, after cancellation, replacement, removal and repeated sweeps",
       %{w: w, bytes: bytes} do
    {:ok, pipeline} = EpisodeDiscovery.activate(w.profile)
    assert {:ok, %{file: first}} = upload(w, bytes)
    assert ClipClosingVideo.asset?(first.id)
    assert EpisodeDiscovery.sweep([w.profile.id]) == []
    assert {:error, :ineligible_episode} = ClipJobs.enqueue_episode(pipeline.id, first.id)
    assert {:ok, profile} = save(w, %{file_id: first.id, enabled: true, audio: :keep})
    assert profile.closing_video.audio == :keep
    assert {:ok, %{file: second}} = upload(w, bytes <> "second")
    assert {:ok, _} = save(w, %{file_id: second.id, enabled: true, audio: :mute})
    assert {:ok, _} = ClipClosingVideo.remove(w.org_id, w.profile.id, w.approver.id)
    assert current(w).file_id == nil
    for _ <- 1..3, do: assert(EpisodeDiscovery.sweep([w.profile.id]) == [])
    assert Files.get_file(first.id)
    assert Files.get_file(second.id)

    {:ok, episode, _} =
      Files.add_bytes(w.project, bytes <> "episode", "episode.mp4", "video/mp4",
        ingest: false,
        uploaded_by_user_id: w.approver.id
      )

    assert [{:ok, job}] = EpisodeDiscovery.sweep([w.profile.id])
    assert job.source_file_id == episode.id
    assert EpisodeDiscovery.sweep([w.profile.id]) == []
  end

  test "typed defaults isolate profiles, disable preserves file, generic update cannot overwrite",
       %{w: w, bytes: bytes} do
    {:ok, %{file: file, asset: asset}} = upload(w, bytes)
    assert asset.content_hash == file.content_hash
    assert asset.duration_s > 0 and asset.width == 64 and asset.height == 96
    assert {:ok, _} = save(w, %{file_id: file.id, enabled: true, audio: "keep"})
    assert {:ok, _} = save(w, %{enabled: false})
    assert current(w).file_id == file.id
    refute current(w).enabled
    other = render_world!()
    assert Repo.get!(Profile, other.profile.id).closing_video.file_id == nil

    assert {:ok, _} =
             Platform.Social.update_profile(w.org_id, w.profile.id, %{
               closing_video: %{file_id: nil, enabled: true}
             })

    assert current(w).file_id == file.id
    assert {:error, %Ecto.Changeset{}} = save(w, %{audio: "invented"})
    assert {:error, %Ecto.Changeset{}} = save(w, %{file_id: "bogus"})
    assert {:error, %Ecto.Changeset{}} = save(w, %{file_id: nil, enabled: true})
  end

  test "foreign, unfinalized, deleted, fake containers and invalid bytes preserve saved value", %{
    w: w,
    bytes: bytes
  } do
    {:ok, %{file: good}} = upload(w, bytes)
    {:ok, _} = save(w, %{file_id: good.id, enabled: true})
    foreign = render_world!()
    {:ok, %{file: foreign_file}} = upload(foreign, bytes)
    assert {:error, :foreign_asset} = save(w, %{file_id: foreign_file.id})
    assert {:error, :asset_unavailable} = save(w, %{file_id: Ecto.UUID.generate()})
    assert {:error, :invalid_video} = upload(w, "not really video")
    assert {:error, :invalid_video} = upload(w, "")
    {:ok, fake, _} = Files.add_bytes(w.project, "fake", "fake.mp4", "video/mp4", ingest: false)
    assert {:error, :invalid_video} = save(w, %{file_id: fake.id})

    Repo.update_all(from(f in Platform.Files.File, where: f.id == ^fake.id),
      set: [content_hash: nil]
    )

    assert {:error, :asset_unavailable} = save(w, %{file_id: fake.id})
    assert current(w).file_id == good.id

    Repo.update_all(from(f in Platform.Files.File, where: f.id == ^good.id),
      set: [deleted_at: DateTime.utc_now()]
    )

    assert {:error, :asset_unavailable} = save(w, %{enabled: false})
    assert ClipClosingVideo.asset?(good.id)
  end

  test "already discovered episodes including deduplicated uploads are refused without deleting originals",
       %{w: w, bytes: bytes} do
    {:ok, pipeline} = EpisodeDiscovery.activate(w.profile)

    {:ok, episode, _} =
      Files.add_bytes(w.project, bytes, "episode.mp4", "video/mp4",
        ingest: false,
        uploaded_by_user_id: w.approver.id
      )

    {:ok, job} = ClipJobs.enqueue_episode(pipeline.id, episode.id)
    assert {:error, :already_an_episode} = save(w, %{file_id: episode.id, enabled: true})
    # add_bytes deduplicates only against ingested siblings.
    {:ok, episode} = Files.update_ingest_status(episode, "ingested")
    assert {:error, :already_an_episode} = upload(w, bytes)
    refute ClipClosingVideo.asset?(episode.id)
    assert Files.get_file(episode.id)
    assert Repo.get!(Platform.Social.ClipJob, job.id).status == "queued"
  end

  test "revoked/non-human/archived access and malformed IDs cannot list, upload or mutate", %{
    w: w,
    bytes: bytes
  } do
    {:ok, %{file: file}} = upload(w, bytes)

    for user <- [w.agent.id, w.outsider.id, "bad", "sixteen-byte-key"] do
      assert {:error, _} = ClipClosingVideo.list(w.org_id, w.profile.id, user)

      assert {:error, _} =
               ClipClosingVideo.upload(
                 w.org_id,
                 w.profile.id,
                 user,
                 bytes,
                 "test.mp4",
                 "video/mp4"
               )

      assert {:error, _} =
               ClipClosingVideo.save(w.org_id, w.profile.id, user, %{file_id: file.id})
    end

    Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
      set: [approver_user_ids: []]
    )

    assert {:error, _} = save(w, %{file_id: file.id})
    assert {:error, _} = upload(w, bytes)

    Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
      set: [approver_user_ids: [w.approver.id]]
    )

    Repo.update_all(from(p in Platform.Tasks.Project, where: p.id == ^w.project.id),
      set: [archived_at: DateTime.utc_now()]
    )

    assert {:error, _} = save(w, %{file_id: file.id})
    assert {:error, _} = upload(w, bytes)
    assert Repo.aggregate(ClosingAsset, :count) == 1
  end

  test "missing probe fails closed and upload rollback cleans its new object and row", %{
    w: w,
    bytes: bytes
  } do
    prior = Application.get_env(:social, :ffprobe_path)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:social, :ffprobe_path, prior),
        else: Application.delete_env(:social, :ffprobe_path)
    end)

    Application.put_env(:social, :ffprobe_path, "/missing/ffprobe")
    before = Repo.aggregate(Platform.Files.File, :count)
    assert {:error, :invalid_video} = upload(w, bytes)
    assert Repo.aggregate(Platform.Files.File, :count) == before
    assert Repo.aggregate(ClosingAsset, :count) == 0
  end

  test "byte limit is enforced against file metadata and actual upload size", %{
    w: w,
    bytes: bytes
  } do
    {:ok, file, _} = Files.add_bytes(w.project, bytes, "test.mp4", "video/mp4", ingest: false)

    Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
      set: [byte_size: ClipClosingVideo.max_bytes() + 1]
    )

    assert {:error, :video_too_large} = save(w, %{file_id: file.id})

    assert {:error, :video_too_large} =
             upload(w, :binary.copy(<<0>>, ClipClosingVideo.max_bytes() + 1))

    assert Repo.aggregate(ClosingAsset, :count) == 0
  end

  defp unboxed(fun) do
    Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end) |> Task.await(30_000)
  end

  defp committed_world! do
    w =
      unboxed(fn ->
        before = Repo.all(from(u in Platform.Accounts.User, select: u.id))
        w = render_world!()
        created = Repo.all(from(u in Platform.Accounts.User, select: u.id)) -- before
        Map.put(w, :created_users, created)
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(p in Profile, where: p.id == ^w.profile.id))
        Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^w.project.id))
        Repo.delete_all(from(s in Platform.Chat.Space, where: s.id == ^w.profile.space_id))
        Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^w.agent.id))

        Repo.delete_all(from(u in Platform.Accounts.User, where: u.id in ^w.created_users))

        Repo.delete_all(
          from(o in Platform.Tenancy.Org, where: o.id in ^[w.org_id, w.other_org_id])
        )
      end)
    end)

    w
  end

  test "independent discovery sees no picker upload before commit and rejects it after commit", %{
    bytes: bytes
  } do
    w = committed_world!()
    {:ok, pipeline} = unboxed(fn -> EpisodeDiscovery.activate(w.profile) end)
    parent = self()

    uploader =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, %{file: file}} = upload(w, bytes)
            send(parent, {:registered_uncommitted, file.id, self()})

            receive do
              :commit -> file.id
            after
              5000 -> raise "upload commit barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:registered_uncommitted, id, pid}, 5000
    assert unboxed(fn -> EpisodeDiscovery.sweep([w.profile.id]) end) == []
    send(pid, :commit)
    assert {:ok, ^id} = Task.await(uploader)
    assert unboxed(fn -> EpisodeDiscovery.sweep([w.profile.id]) end) == []

    assert {:error, :ineligible_episode} =
             unboxed(fn -> ClipJobs.enqueue_episode(pipeline.id, id) end)
  end

  test "stale discovery blocks on registration file lock and rechecks exclusion", %{bytes: bytes} do
    w = committed_world!()
    {:ok, pipeline} = unboxed(fn -> EpisodeDiscovery.activate(w.profile) end)

    {:ok, file, _} =
      unboxed(fn ->
        Files.add_bytes(w.project, bytes, "existing.mp4", "video/mp4",
          ingest: false,
          uploaded_by_user_id: w.approver.id
        )
      end)

    parent = self()

    saver =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, _} = save(w, %{file_id: file.id, enabled: true})
            send(parent, {:selected_uncommitted, self()})

            receive do
              :commit -> :ok
            after
              5000 -> raise "selection commit barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:selected_uncommitted, pid}, 5000

    discovery =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(
          Repo,
          fn -> ClipJobs.enqueue_episode(pipeline.id, file.id) end
        )
      end)

    assert Task.yield(discovery, 100) == nil
    send(pid, :commit)
    assert {:ok, :ok} = Task.await(saver)
    assert {:error, :ineligible_episode} = Task.await(discovery)
  end

  test "default save and enqueue serialize on the profile so a job gets one complete committed choice",
       %{bytes: bytes} do
    w = committed_world!()
    {:ok, %{file: a}} = unboxed(fn -> upload(w, bytes) end)
    {:ok, %{file: b}} = unboxed(fn -> upload(w, bytes <> "replacement") end)
    {:ok, _} = unboxed(fn -> save(w, %{file_id: a.id, enabled: true, audio: "keep"}) end)
    parent = self()

    saver =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, _} = save(w, %{file_id: b.id, enabled: true, audio: "mute"})
            send(parent, {:default_locked, self()})

            receive do
              :commit -> :ok
            after
              5000 -> raise "default commit barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:default_locked, pid}, 5000

    enqueuer =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          send(parent, :enqueuer_ready)

          ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
            source_url: "https://example.com/episode",
            in_s: 0,
            out_s: 3
          })
        end)
      end)

    assert_receive :enqueuer_ready, 5000
    assert Task.yield(enqueuer, 100) == nil
    send(pid, :commit)
    assert {:ok, :ok} = Task.await(saver)
    assert {:ok, %{job: job}} = Task.await(enqueuer)
    assert job.payload["closing_video"]["file_id"] == b.id
    assert job.payload["closing_video"]["audio"] == "mute"
    assert job.payload["closing_video"]["content_hash"] == b.content_hash
  end

  test "a profile moved to another tenant while enqueue waits is not authorized by stale org scope" do
    w = committed_world!()

    {org, project} =
      unboxed(fn ->
        org = w.other_org_id
        member!(w.approver, org)
        {org, project!(org)}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(p in Profile, where: p.id == ^w.profile.id))
        Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id))
        Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org))
      end)
    end)

    parent = self()

    mover =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
              set: [org_id: org, project_id: project.id]
            )

            send(parent, {:tenant_move_locked, self()})

            receive do
              :commit -> :ok
            after
              5000 -> raise "tenant-move barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:tenant_move_locked, mover_pid}, 5000

    enqueuer =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:enqueue_backend, backend_pid})

          ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
            source_url: "https://example.com/episode",
            in_s: 0,
            out_s: 3
          })
        end)
      end)

    assert_receive {:enqueue_backend, backend_pid}, 5000
    # Observe an actual database lock wait, so a late-starting worker cannot
    # make this race test pass without reaching the stale pre-lock lookup.
    assert_eventually(fn ->
      unboxed(fn ->
        %{rows: [[n]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1))", [backend_pid])
        n > 0
      end)
    end)

    send(mover_pid, :commit)
    assert {:ok, :ok} = Task.await(mover)
    assert {:error, :not_found} = Task.await(enqueuer)

    refute unboxed(fn ->
             Repo.exists?(
               from(j in Platform.Social.ClipJob, where: j.profile_id == ^w.profile.id)
             )
           end)
  end

  test "revocation or project reassignment during probing rejects upload completion and save",
       %{bytes: bytes} do
    original = Application.get_env(:social, :ffprobe_path)
    real = System.find_executable("ffprobe")
    prefix = Path.join(System.tmp_dir!(), "closing-probe-#{unique()}")
    wrapper = prefix <> ".sh"
    # A real probe behind an explicit barrier makes the authorization race deterministic.
    File.write!(
      wrapper,
      "#!/bin/sh\ntouch '" <>
        prefix <>
        ".ready'\nwhile [ ! -f '" <>
        prefix <>
        ".release' ]; do sleep 0.02; done\nexec '" <> real <> "' \"$@\"\n"
    )

    File.chmod!(wrapper, 0o700)

    on_exit(fn ->
      if original,
        do: Application.put_env(:social, :ffprobe_path, original),
        else: Application.delete_env(:social, :ffprobe_path)

      for suffix <- [".sh", ".ready", ".release"], do: File.rm(prefix <> suffix)
    end)

    for operation <- [:upload, :save], change <- [:revoke, :project] do
      File.rm(prefix <> ".ready")
      File.rm(prefix <> ".release")
      w = committed_world!()

      file =
        if operation == :save do
          {:ok, file, _} =
            unboxed(fn ->
              Files.add_bytes(w.project, bytes, "existing.mp4", "video/mp4", ingest: false)
            end)

          file
        end

      Application.put_env(:social, :ffprobe_path, wrapper)

      worker =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            if operation == :upload,
              do: upload(w, bytes),
              else: save(w, %{file_id: file.id, enabled: true})
          end)
        end)

      assert_eventually(fn -> File.exists?(prefix <> ".ready") end)

      if change == :revoke do
        unboxed(fn ->
          Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
            set: [approver_user_ids: []]
          )
        end)
      else
        project = unboxed(fn -> project!(w.org_id) end)

        on_exit(fn ->
          unboxed(fn ->
            Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id))
          end)
        end)

        unboxed(fn ->
          Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
            set: [project_id: project.id]
          )
        end)
      end

      File.write!(prefix <> ".release", "go")
      assert {:error, _} = Task.await(worker, 10_000)

      unboxed(fn ->
        refute Repo.exists?(from(a in ClosingAsset, where: a.profile_id == ^w.profile.id))
        assert Repo.get!(Profile, w.profile.id).closing_video.file_id == nil

        assert length(Files.list_files_for_project(w.project.id, limit: nil)) ==
                 if(operation == :save, do: 3, else: 2)
      end)
    end
  end

  test "Files registration rollback removes only new objects, including callback crashes", %{
    w: w,
    bytes: bytes
  } do
    for failure <- [:error, :raise] do
      result =
        Files.add_bytes_registered(w.project, bytes, "rollback.mp4", "video/mp4", [], fn file ->
          {:ok, path} = Files.Extractor.local_path(file)
          send(self(), {:allocated, path, file.id})

          if failure == :raise,
            do: raise("fixture registration crash"),
            else: {:error, :fixture_reject}
        end)

      assert {:error, _} = result
      assert_receive {:allocated, path, id}
      refute File.exists?(path)
      refute Files.get_file(id)
    end

    {:ok, original, _} = Files.add_bytes(w.project, bytes, "keep.mp4", "video/mp4", ingest: false)
    {:ok, _} = Files.update_ingest_status(original, "ingested")

    assert {:error, :fixture_reject} =
             Files.add_bytes_registered(w.project, bytes, "dedup.mp4", "video/mp4", [], fn _ ->
               {:error, :fixture_reject}
             end)

    {:ok, path} = Files.Extractor.local_path(original)
    assert File.exists?(path)
    assert Files.get_file(original.id)
  end

  test "same-org foreign project, forged container type, hash mismatch and archived humans fail safely",
       %{w: w, bytes: bytes} do
    other_project = project!(w.org_id)

    {:ok, file, _} =
      Files.add_bytes(other_project, bytes, "foreign.mp4", "video/mp4", ingest: false)

    assert {:error, :foreign_asset} = save(w, %{file_id: file.id})

    assert {:error, :invalid_video} =
             ClipClosingVideo.upload(
               w.org_id,
               w.profile.id,
               w.approver.id,
               bytes,
               "fake.webm",
               "video/webm"
             )

    {:ok, file, _} = Files.add_bytes(w.project, bytes, "hash.mp4", "video/mp4", ingest: false)

    Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
      set: [content_hash: "forged"]
    )

    assert {:error, :invalid_video} = save(w, %{file_id: file.id})

    Repo.update_all(from(u in Platform.Accounts.User, where: u.id == ^w.approver.id),
      set: [archived_at: DateTime.utc_now()]
    )

    assert {:error, _} = upload(w, bytes)
    assert {:error, _} = save(w, %{file_id: file.id})
    assert {:error, _} = ClipClosingVideo.list(w.org_id, w.profile.id, w.approver.id)
  end

  test "episode winning the file lock refuses concurrent selection without changing the default",
       %{bytes: bytes} do
    w = committed_world!()
    {:ok, pipeline} = unboxed(fn -> EpisodeDiscovery.activate(w.profile) end)

    {:ok, file, _} =
      unboxed(fn ->
        Files.add_bytes(w.project, bytes, "episode.mp4", "video/mp4",
          ingest: false,
          uploaded_by_user_id: w.approver.id
        )
      end)

    parent = self()

    discovery =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, job} = ClipJobs.enqueue_episode(pipeline.id, file.id)
            send(parent, {:episode_uncommitted, self(), job.id})

            receive do
              :commit -> job.id
            after
              5000 -> raise "episode commit barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:episode_uncommitted, pid, job_id}, 5000

    saver =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          save(w, %{file_id: file.id, enabled: true})
        end)
      end)

    assert Task.yield(saver, 100) == nil
    send(pid, :commit)
    assert {:ok, ^job_id} = Task.await(discovery)
    assert {:error, :already_an_episode} = Task.await(saver)

    unboxed(fn ->
      assert Repo.get!(Profile, w.profile.id).closing_video.file_id == nil
      refute ClipClosingVideo.asset?(file.id)
      assert Repo.get!(Platform.Social.ClipJob, job_id).status == "queued"
    end)
  end

  test "successful deduplicated picker upload reuses the durable asset identity", %{
    w: w,
    bytes: bytes
  } do
    {:ok, %{file: file, asset: asset}} = upload(w, bytes)
    {:ok, _} = Files.update_ingest_status(file, "ingested")
    assert {:ok, %{file: same_file, asset: same_asset}} = upload(w, bytes)
    assert same_file.id == file.id
    assert same_asset.id == asset.id
    assert Repo.aggregate(ClosingAsset, :count) == 1
    assert ClipClosingVideo.asset?(file.id)
  end

  test "sixteen-byte raw IDs never raise or become fabricated UUIDs", %{w: w} do
    raw = "abcdefghijklmnop"
    assert {:error, _} = ClipClosingVideo.list(w.org_id, raw, w.approver.id)
    assert {:error, _} = ClipClosingVideo.list(raw, w.profile.id, w.approver.id)
    assert {:error, _} = ClipClosingVideo.list(w.org_id, w.profile.id, raw)
    assert {:error, %Ecto.Changeset{}} = save(w, %{file_id: raw, enabled: true})
    refute ClipClosingVideo.lock_file(raw)
    assert current(w).file_id == nil
  end
end
