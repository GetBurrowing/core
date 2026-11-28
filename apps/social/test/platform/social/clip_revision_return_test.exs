defmodule Platform.Social.ClipRevisionReturnTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.{Repo, Social}
  alias Platform.Social.{AgentDrafts, Clip, ClipDecisions, ClipRender, ClipReviewFeed, Post}

  setup do
    w = render_world!()
    file = stored_file!(w.project, video_bytes() <> "base #{unique()}", "base.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => "Current working title",
          "caption" => "Current working caption",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    base = Repo.get_by!(ClipRender, clip_id: clip.id, rev: clip.rev)

    {:ok, %{request: request}} =
      apply(Platform.Social.ClipRevisions, :request_edit, [
        w.scope,
        clip.id,
        w.approver.id,
        %{
          request_id: Ecto.UUID.generate(),
          base_render_id: base.id,
          assignee: :self,
          note: "Cut the pause"
        }
      ])

    output = stored_file!(w.project, video_bytes(), "new.mp4", "video/mp4")

    args = %{
      file_id: output.id,
      sha256: output.content_hash,
      byte_size: output.byte_size,
      duration_s: 0.3,
      width: 320,
      height: 180,
      base_render_id: base.id,
      request_id: request.id
    }

    {:ok, id} =
      apply(Platform.Social.ClipRevisionContract, :submission_id, [
        request.id,
        clip.id,
        base.id,
        output.content_hash
      ])

    %{
      w: w,
      clip: clip,
      base: base,
      request: request,
      base_file: file,
      output: output,
      args: Map.put(args, :submission_id, id)
    }
  end

  defp append(ctx, args) do
    apply(Platform.Social.ClipRevisions, :append_version, [
      ctx.w.scope,
      ctx.clip.id,
      {:user, ctx.w.approver.id},
      args
    ])
  end

  test "a returned recut appends pending without replacing copy or old versions", ctx do
    assert {:ok, %{clip: clip, render: render, duplicate?: false}} = append(ctx, ctx.args)
    assert clip.id == ctx.clip.id
    assert clip.rev == ctx.clip.rev + 1
    assert clip.review_status == "pending"
    assert clip.title == ctx.clip.title
    assert clip.caption == ctx.clip.caption
    assert render.file_id == ctx.output.id
    # No transcript/burned-in copy was supplied by this slice.
    assert render.headline == nil
    assert render.caption == nil
    assert render.provenance["actor_kind"] == "user"
    assert render.provenance["actor_id"] == ctx.w.approver.id
    assert render.submitted_by_agent_id == nil
    assert Repo.get!(ClipRender, ctx.base.id).file_id == ctx.base_file.id
    request = Repo.get!(Platform.Social.ClipEditRequest, ctx.request.id)
    assert request.note == "Cut the pause"
    assert request.returned_render_id == render.id
    assert Repo.all(Post) == []
  end

  test "equal replay returns the original render even after a later version; changed facts conflict",
       ctx do
    assert {:ok, %{render: first}} = append(ctx, ctx.args)
    later_file = stored_file!(ctx.w.project, "later #{unique()}", "later.mp4", "video/mp4")

    {:ok, later} =
      Repo.transaction(fn ->
        Platform.Social.ClipVersions.append!(ctx.clip.id, later_file, %{}, %{
          completion_key: "later-test"
        })
      end)

    assert later.rev == ctx.clip.rev + 2
    Repo.update!(Ecto.Changeset.change(first, removed_at: DateTime.utc_now()))
    assert {:ok, %{clip: current, render: same, duplicate?: true}} = append(ctx, ctx.args)
    assert current.rev == later.rev
    assert current.render_file_id == later_file.id
    assert same.removed_at != nil
    assert same.id == first.id
    assert {:error, :idempotency_conflict} = append(ctx, %{ctx.args | duration_s: 26.0})

    assert {:error, :request_already_returned} =
             append(
               ctx,
               %{ctx.args | submission_id: Ecto.UUID.generate()}
             )
  end

  test "an undo and a later send-back cannot reactivate the old request", ctx do
    assert {:ok, _} =
             ClipDecisions.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id)

    assert {:ok, %{request: newer}} =
             Platform.Social.ClipRevisions.request_edit(
               ctx.w.scope,
               ctx.clip.id,
               ctx.w.approver.id,
               %{
                 request_id: Ecto.UUID.generate(),
                 base_render_id: ctx.base.id,
                 assignee: :self,
                 note: "New request"
               }
             )

    assert newer.id != ctx.request.id
    assert {:error, :request_not_open} = append(ctx, ctx.args)
  end

  test "undo followed by a bare rejection cannot reactivate an old editing request", ctx do
    assert {:ok, _} =
             ClipDecisions.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id)

    assert {:ok, _} =
             ClipDecisions.reject_clip(
               ctx.w.org_id,
               ctx.clip.id,
               ctx.w.approver.id,
               ctx.request.note
             )

    # Same base, actor and text deliberately: a later decision is a different origin.
    assert {:error, :request_not_open} = append(ctx, ctx.args)

    assert {:ok, nil} =
             Social.ClipRevisions.state(ctx.w.scope, ctx.clip.id, {:user, ctx.w.approver.id})
  end

  test "human upload retains the specific stale-request refusal before media preparation",
       ctx do
    assert {:ok, _} =
             ClipDecisions.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id)

    # Authority is valid, but a closed request is refused before media work.
    attrs = Map.drop(ctx.args, [:file_id])
    bytes = video_bytes()

    attrs = %{
      attrs
      | sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        byte_size: byte_size(bytes)
    }

    assert {:error, :request_not_open} =
             apply(Platform.Social.ClipRevisions, :upload_version, [
               ctx.w.scope,
               ctx.clip.id,
               ctx.w.approver.id,
               bytes,
               "human.mp4",
               "video/mp4",
               attrs
             ])

    assert Repo.get!(Clip, ctx.clip.id).rev == ctx.clip.rev
  end

  test "undo invalidates a still-unreturned instruction", ctx do
    assert {:ok, _} =
             ClipDecisions.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id)

    assert {:error, :request_not_open} = append(ctx, ctx.args)
    assert Repo.get!(Clip, ctx.clip.id).rev == ctx.clip.rev
  end

  test "choosing the clip after undo prevents return and preserves the actual draft", ctx do
    assert {:ok, _} =
             ClipDecisions.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id)

    assert {:ok, %{posts: [post]}} =
             ClipDecisions.draft_clip(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id, %{
               "render_id" => ctx.base.id,
               "account_ids" => [ctx.w.tiktok.id],
               "copy_rev" => ClipReviewFeed.copy_rev(ctx.clip)
             })

    before = Repo.get!(Post, post.id)
    assert Repo.get!(Clip, ctx.clip.id).review_status == "approved"
    assert {:error, :request_not_open} = append(ctx, ctx.args)
    assert Repo.get!(Post, post.id) == before
    assert Repo.get!(Clip, ctx.clip.id).rev == ctx.clip.rev
  end

  test "a human upload appends through the registration callback", ctx do
    bytes = video_bytes() <> "new human upload #{unique()}"
    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    {:ok, id} =
      Platform.Social.ClipRevisionContract.submission_id(
        ctx.request.id,
        ctx.clip.id,
        ctx.base.id,
        sha
      )

    attrs =
      ctx.args
      |> Map.drop([:file_id])
      |> Map.merge(%{sha256: sha, byte_size: byte_size(bytes), submission_id: id})

    assert {:ok, %{render: render, duplicate?: false}} =
             Platform.Social.ClipRevisions.upload_version(
               ctx.w.scope,
               ctx.clip.id,
               ctx.w.approver.id,
               bytes,
               "human.mp4",
               "video/mp4",
               attrs
             )

    file = Platform.Files.get_file(render.file_id)
    assert file.uploaded_by_user_id == ctx.w.approver.id
    assert file.content_hash == sha
    assert render.provenance["media_facts_source"] == "server_probe"

    assert {:ok, %{render: same, duplicate?: true}} =
             Platform.Social.ClipRevisions.upload_version(
               ctx.w.scope,
               ctx.clip.id,
               ctx.w.approver.id,
               bytes,
               "human.mp4",
               "video/mp4",
               attrs
             )

    assert same.id == render.id
  end

  test "a current quality reviewer can request and return their own recut without final-approver membership",
       ctx do
    {:ok, _} = ClipDecisions.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id)
    reviewer = member!(user!(), ctx.w.org_id)

    profile =
      Repo.update!(Ecto.Changeset.change(ctx.w.profile, quality_reviewer_user_ids: [reviewer.id]))

    assert {:error, :not_an_approver} = Social.approver_check(ctx.w.org_id, profile, reviewer.id)
    assert :ok = Social.quality_reviewer_check(ctx.w.org_id, profile, reviewer.id)

    {:ok, %{request: request}} =
      Social.ClipRevisions.request_edit(ctx.w.scope, ctx.clip.id, reviewer.id, %{
        request_id: Ecto.UUID.generate(),
        base_render_id: ctx.base.id,
        assignee: :self,
        note: "My edit"
      })

    {:ok, id} =
      Social.ClipRevisionContract.submission_id(
        request.id,
        ctx.clip.id,
        ctx.base.id,
        ctx.output.content_hash
      )

    assert {:ok, %{clip: returned, render: render}} =
             Social.ClipRevisions.append_version(
               ctx.w.scope,
               ctx.clip.id,
               {:user, reviewer.id},
               %{ctx.args | request_id: request.id, submission_id: id}
             )

    assert returned.review_status == "pending"
    assert render.provenance["actor_id"] == reviewer.id
    assert render.submitted_by_agent_id == nil
  end

  test "another current preparer cannot return a request assigned to a different human", ctx do
    reviewer = member!(user!(), ctx.w.org_id)
    Repo.update!(Ecto.Changeset.change(ctx.w.profile, quality_reviewer_user_ids: [reviewer.id]))

    assert {:error, :unauthorized} =
             Social.ClipRevisions.append_version(
               ctx.w.scope,
               ctx.clip.id,
               {:user, reviewer.id},
               ctx.args
             )

    assert Repo.get!(Clip, ctx.clip.id).rev == ctx.clip.rev
  end

  test "revoked authority cannot replay a historical receipt", ctx do
    assert {:ok, _} = append(ctx, ctx.args)
    Repo.update!(Ecto.Changeset.change(ctx.w.profile, approver_user_ids: []))
    assert {:error, :not_an_approver} = append(ctx, ctx.args)
  end

  test "same content under a renamed file is not a recut", ctx do
    args = %{
      ctx.args
      | file_id: ctx.base_file.id,
        sha256: ctx.base_file.content_hash,
        byte_size: ctx.base_file.byte_size
    }

    {:ok, id} =
      apply(Platform.Social.ClipRevisionContract, :submission_id, [
        ctx.request.id,
        ctx.clip.id,
        ctx.base.id,
        args.sha256
      ])

    assert {:error, :same_content} = append(ctx, %{args | submission_id: id})
  end

  test "probe input bytes use a private temporary directory and are removed on refusal", ctx do
    # A refusing executable observes allocation only; it never supplies successful media facts.
    prefix = Path.join(System.tmp_dir!(), "revision-probe-control-" <> Ecto.UUID.generate())
    script = prefix <> ".py"
    report = prefix <> ".json"
    python = System.find_executable("python3")
    assert is_binary(python)

    File.write!(
      script,
      "#!" <>
        python <>
        "\n" <>
        "import json, os, stat, sys\n" <>
        "if sys.argv[1] == '-h': sys.exit(1)\n" <>
        "p = sys.argv[-1]\n" <>
        "with open(" <>
        Jason.encode!(report) <>
        ", 'w') as f: json.dump({'path': p, 'parent': os.path.dirname(p), 'mode': stat.S_IMODE(os.stat(os.path.dirname(p)).st_mode)}, f)\n" <>
        "sys.exit(1)\n"
    )

    File.chmod!(script, 0o700)
    previous = Application.get_env(:social, :ffprobe_path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:social, :ffprobe_path, previous),
        else: Application.delete_env(:social, :ffprobe_path)

      File.rm(script)
      File.rm(report)
    end)

    Application.put_env(:social, :ffprobe_path, script)
    assert {:error, :unreadable_video} = append(ctx, ctx.args)
    allocation = report |> File.read!() |> Jason.decode!()
    refute allocation["parent"] == System.tmp_dir!()
    assert allocation["mode"] == 0o700
    refute File.exists?(allocation["path"])
    refute File.exists?(allocation["parent"])
  end

  test "a foreign-project upload cannot be admitted to this request", ctx do
    foreign =
      stored_file!(project!(ctx.w.other_org_id), "foreign #{unique()}", "other.mp4", "video/mp4")

    args = %{
      ctx.args
      | file_id: foreign.id,
        sha256: foreign.content_hash,
        byte_size: foreign.byte_size
    }

    assert {:error, :file_not_in_project} = append(ctx, args)
    assert Repo.get!(Clip, ctx.clip.id).rev == ctx.clip.rev
  end

  test "return leaves a legacy approved post and its older render binding unchanged", ctx do
    assert {:ok, _} =
             ClipDecisions.undo_clip_decision(ctx.w.org_id, ctx.clip.id, ctx.w.approver.id)

    server = :clip_revision_legacy_fixture

    start_supervised!(
      {Social.ClipPublish, name: server, interval_ms: :infinity, boot_sweep: false}
    )

    assert {:ok, %{posts: [post]}} =
             Social.LegacyClipApproval.approve_clip(
               ctx.w.org_id,
               ctx.clip.id,
               ctx.w.approver.id,
               %{"render_id" => ctx.base.id, "account_ids" => [ctx.w.tiktok.id]},
               now: DateTime.add(DateTime.utc_now(), 3600, :second),
               publish_server: server
             )

    assert post.status == "approved"
    before = Repo.get!(Post, post.id)
    intermediate = stored_file!(ctx.w.project, "middle #{unique()}", "middle.mp4", "video/mp4")

    {:ok, newer} =
      Repo.transaction(fn ->
        Social.ClipVersions.append!(ctx.clip.id, intermediate, %{}, %{
          completion_key: "intermediate"
        })
      end)

    base = Repo.get_by!(ClipRender, clip_id: newer.id, rev: newer.rev)

    {:ok, %{request: request}} =
      Social.ClipRevisions.request_edit(ctx.w.scope, newer.id, ctx.w.approver.id, %{
        request_id: Ecto.UUID.generate(),
        base_render_id: base.id,
        assignee: :self,
        note: "Another cut"
      })

    {:ok, id} =
      Social.ClipRevisionContract.submission_id(
        request.id,
        newer.id,
        base.id,
        ctx.output.content_hash
      )

    args = %{ctx.args | request_id: request.id, base_render_id: base.id, submission_id: id}
    assert {:ok, %{clip: returned}} = append(ctx, args)
    assert returned.review_status == "pending"
    assert Repo.get!(Post, post.id) == before
    assert before.clip_render_id == ctx.base.id
    assert Repo.get!(ClipRender, ctx.base.id).file_id == ctx.base_file.id
  end

  test "a newer working-copy value survives the returned media", ctx do
    # This is the real changeset used by the details rail; return must never copy a stale snapshot over it.
    {:ok, changeset} =
      ClipReviewFeed.copy_changeset(
        Repo.get!(Clip, ctx.clip.id),
        %{"title" => "Newer words", "caption" => "Newer caption"}
      )

    Repo.update!(changeset)
    assert {:ok, %{clip: clip}} = append(ctx, ctx.args)
    assert clip.title == "Newer words"
    assert clip.caption == "Newer caption"
    assert Social.list_posts(ctx.w.org_id, %{}) == []
  end

  test "an unassigned admitted caller causes no file read or media preparation", ctx do
    other = pinned_agent!(ctx.w.org_id)

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "unassigned-#{unique()}",
        agent_id: other.id,
        owner_user_id: ctx.w.approver.id,
        status: "active"
      })

    {:ok, _} =
      Platform.Access.RuntimeProfiles.create_for_runtime(runtime, ["social", "files"], nil)

    collector = spawn_link(fn -> collect_media_calls([]) end)
    patterns = [{File, :read, 1}, {Social.ClipRevisionMedia, :prepare, 1}]
    for mfa <- patterns, do: :erlang.trace_pattern(mfa, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, collector}])

    try do
      assert {:error, :unauthorized} =
               Social.ClipRevisions.append_version(
                 ctx.w.scope,
                 ctx.clip.id,
                 {:agent, other.id, runtime.runtime_id},
                 ctx.args
               )

      barrier = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^barrier}
      send(collector, {:get, self()})
      assert_receive {:media_calls, []}
    after
      :erlang.trace(self(), false, [:call])
      for mfa <- patterns, do: :erlang.trace_pattern(mfa, false, [])
      send(collector, :stop)
    end
  end

  test "editing-request notes are omitted from a generic rerender payload", ctx do
    assert {:ok, job} =
             Social.ClipJobs.enqueue_rerender(
               ctx.w.org_id,
               ctx.clip.id,
               ctx.w.approver.id,
               %{base_render_id: ctx.base.id, trim_in_s: 0.0, trim_out_s: 0.3}
             )

    other = pinned_agent!(ctx.w.org_id)
    assert {:ok, claimed} = Social.ClipJobs.claim(ctx.w.scope, job.id, other.id)
    refute claimed.payload["review_note"]
    refute inspect(claimed.payload) =~ ctx.request.note
    assert Repo.get!(Social.ClipEditRequest, ctx.request.id).note == ctx.request.note
  end

  defp collect_media_calls(calls) do
    receive do
      {:trace, _, :call, {module, function, _args}} ->
        collect_media_calls([{module, function} | calls])

      {:get, caller} ->
        send(caller, {:media_calls, Enum.reverse(calls)})
        collect_media_calls(calls)

      :stop ->
        :ok
    end
  end

  defp video_bytes do
    File.read!(Path.expand("../../support/fixtures/episode_pipeline/one.mp4", __DIR__))
  end

  test "an uncertain probe task exit refuses through Files and retains only the owned input",
       ctx do
    # Kill only the exact supervised job owned by this upload, after its real
    # controlled child has opened the copy. No success metadata is injected.
    root = Path.join(System.tmp_dir!(), "revision-lifecycle-" <> Ecto.UUID.generate())
    File.mkdir!(root)
    script = Path.join(root, "probe")
    report = Path.join(root, "opened")
    release = Path.join(root, "release")
    finished = Path.join(root, "finished")
    python = System.find_executable("python3")

    File.write!(
      script,
      "#!" <>
        python <>
        "\n" <>
        """
        import os, sys, time
        if sys.argv[1] == '-h':
            print('-o <output_file> write to specified output')
            sys.exit(0)
        p = sys.argv[-1]
        with open(p, 'rb') as media:
            media.read(1)
            import json
            with open(#{Jason.encode!(report)}, 'w') as f: json.dump({'input': p, 'output': sys.argv[sys.argv.index('-o') + 1]}, f)
            while not os.path.exists(#{Jason.encode!(release)}): time.sleep(0.005)
        with open(#{Jason.encode!(finished)}, 'w') as f: f.write('exited')
        sys.exit(1)
        """
    )

    File.chmod!(script, 0o700)
    previous = Application.get_env(:social, :ffprobe_path)
    Application.put_env(:social, :ffprobe_path, script)
    owner = self()

    controller =
      Task.async(fn ->
        deadline = System.monotonic_time(:millisecond) + 4_000
        wait_file!(report, deadline)
        jobs = Task.Supervisor.children(Platform.TaskSupervisor)

        owned =
          Enum.filter(jobs, fn pid ->
            case Process.info(pid, :dictionary) do
              {:dictionary, dict} -> owner in Keyword.get(dict, :"$callers", [])
              _ -> false
            end
          end)

        assert [job] = owned
        Process.exit(job, :kill)
      end)

    on_exit(fn ->
      File.write(release, "release")

      if previous,
        do: Application.put_env(:social, :ffprobe_path, previous),
        else: Application.delete_env(:social, :ffprobe_path)

      # Never remove files a still-running child might be using.
      if File.exists?(finished), do: File.rm_rf!(root)
    end)

    bytes = video_bytes() <> "lifecycle #{unique()}"
    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    {:ok, id} =
      Social.ClipRevisionContract.submission_id(ctx.request.id, ctx.clip.id, ctx.base.id, sha)

    attrs =
      ctx.args
      |> Map.drop([:file_id])
      |> Map.merge(%{sha256: sha, byte_size: byte_size(bytes), submission_id: id})

    handler = "revision-files-" <> Ecto.UUID.generate()

    :telemetry.attach(
      handler,
      [:platform, :repo, :query],
      fn _, _, metadata, owner ->
        if self() == owner and
             String.starts_with?(metadata.query, "INSERT INTO \"platform_files\"") do
          send(owner, {:registered_file_insert, handler})
        end
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    files_before = Repo.aggregate(Platform.Files.File, :count)

    assert {:error, :probe_lifecycle} =
             Social.ClipRevisions.upload_version(
               ctx.w.scope,
               ctx.clip.id,
               ctx.w.approver.id,
               bytes,
               "human.mp4",
               "video/mp4",
               attrs
             )

    Task.await(controller, 5_000)
    assert_receive {:registered_file_insert, ^handler}
    :telemetry.detach(handler)
    assert Repo.aggregate(Platform.Files.File, :count) == files_before
    assert Repo.get!(Clip, ctx.clip.id).rev == ctx.clip.rev
    assert Repo.get!(Social.ClipEditRequest, ctx.request.id).returned_render_id == nil
    observed = Jason.decode!(File.read!(report))
    path = observed["input"]
    assert Path.type(path) == :absolute
    assert File.read!(path) == bytes
    obligation = Jason.decode!(File.read!(Path.join(Path.dirname(path), "cleanup.json")))
    assert obligation["child_exit"] == "unconfirmed"
    assert obligation["input_used?"] == true
    assert obligation["input_path"] == path
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
    File.write!(release, "release")
    wait_file!(finished, System.monotonic_time(:millisecond) + 4_000)
    File.rm_rf!(Path.dirname(path))
    # The task died before returning output metadata. The controlled child
    # supplies its own exact output path for test cleanup after its exit only.
    File.rm_rf!(Path.dirname(observed["output"]))
    File.rm_rf!(root)
  end

  defp wait_file!(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("controlled child boundary not reached")

      true ->
        Process.sleep(5)
        wait_file!(path, deadline)
    end
  end
end
