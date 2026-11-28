defmodule Platform.Social.ClipRevisionLockTest do
  use Platform.DataCase, async: false
  import Ecto.Query
  import Platform.SocialFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.{Repo, Social}
  alias Platform.Social.{AgentDrafts, Clip, ClipEditRequest, ClipRender, ClipRevisions}

  for replay? <- [false, true] do
    @replay replay?
    test "authority revoked while waiting on the profile refuses #{if replay?, do: "a receipt replay", else: "a new request"}" do
      w = committed_world()

      attrs = %{
        request_id: Ecto.UUID.generate(),
        base_render_id: w.base.id,
        assignee: :self,
        note: "Edit"
      }

      if @replay do
        assert {:ok, _} =
                 unboxed(fn ->
                   ClipRevisions.request_edit(w.scope, w.clip.id, w.approver.id, attrs)
                 end)
      end

      parent = self()

      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              profile =
                Repo.one!(
                  from(p in Social.Profile, where: p.id == ^w.profile.id, lock: "FOR UPDATE")
                )

              [[pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
              send(parent, {:held_profile, self(), pid})

              receive do
                :commit_revocation ->
                  Repo.update!(Ecto.Changeset.change(profile, approver_user_ids: []))
                  :ok
              after
                5000 -> raise "profile holder timed out"
              end
            end)
          end)
        end)

      assert_receive {:held_profile, holder_pid, database_holder}, 5000

      caller =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
            send(parent, {:caller_backend, pid})
            ClipRevisions.request_edit(w.scope, w.clip.id, w.approver.id, attrs)
          end)
        end)

      try do
        assert_receive {:caller_backend, database_caller}, 5000

        assert waits_for?(
                 database_caller,
                 database_holder,
                 System.monotonic_time(:millisecond) + 3000
               )

        send(holder_pid, :commit_revocation)
        assert {:ok, :ok} = Task.await(holder, 5000)
        assert {:error, :not_an_approver} = Task.await(caller, 5000)

        assert unboxed(fn ->
                 Repo.aggregate(
                   from(r in ClipEditRequest, where: r.clip_id == ^w.clip.id),
                   :count
                 )
               end) == if(@replay, do: 1, else: 0)

        assert unboxed(fn -> Repo.get!(Clip, w.clip.id).rev end) == w.clip.rev
      after
        send(holder_pid, :commit_revocation)
        Task.shutdown(caller, :brutal_kill)
        Task.shutdown(holder, :brutal_kill)
      end
    end
  end

  test "revocation after return precheck still refuses under the profile lock" do
    w = committed_world()
    bytes = File.read!(Path.expand("../../support/fixtures/episode_pipeline/one.mp4", __DIR__))
    output = unboxed(fn -> stored_file!(w.project, bytes, "locked-return.mp4", "video/mp4") end)

    {:ok, %{request: request}} =
      unboxed(fn ->
        ClipRevisions.request_edit(w.scope, w.clip.id, w.approver.id, %{
          request_id: Ecto.UUID.generate(),
          base_render_id: w.base.id,
          assignee: :self,
          note: "Edit"
        })
      end)

    {:ok, id} =
      Social.ClipRevisionContract.submission_id(
        request.id,
        w.clip.id,
        w.base.id,
        output.content_hash
      )

    attrs = %{
      file_id: output.id,
      request_id: request.id,
      base_render_id: w.base.id,
      submission_id: id,
      sha256: output.content_hash,
      byte_size: output.byte_size,
      duration_s: 0.3,
      width: 320,
      height: 180
    }

    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            profile =
              Repo.one!(
                from(p in Social.Profile, where: p.id == ^w.profile.id, lock: "FOR UPDATE")
              )

            [[pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
            send(parent, {:return_held, self(), pid})

            receive do
              :revoke_return ->
                Repo.update!(Ecto.Changeset.change(profile, approver_user_ids: []))
            after
              5000 -> raise "return lock holder timed out"
            end
          end)
        end)
      end)

    assert_receive {:return_held, holder_pid, database_holder}, 5000

    caller =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {:return_caller, pid})
          ClipRevisions.append_version(w.scope, w.clip.id, {:user, w.approver.id}, attrs)
        end)
      end)

    try do
      assert_receive {:return_caller, database_caller}, 5000
      # The caller can reach this profile lock only after its current-authority
      # precheck and media preparation. Prove the actual SQL lock wait.
      assert waits_for?(
               database_caller,
               database_holder,
               System.monotonic_time(:millisecond) + 3000
             )

      send(holder_pid, :revoke_return)
      assert {:ok, _} = Task.await(holder, 5000)
      assert {:error, :not_an_approver} = Task.await(caller, 5000)
      assert unboxed(fn -> Repo.get!(Clip, w.clip.id).rev end) == w.clip.rev
      assert unboxed(fn -> Repo.get!(ClipEditRequest, request.id).returned_render_id end) == nil
    after
      send(holder_pid, :revoke_return)
      Task.shutdown(caller, :brutal_kill)
      Task.shutdown(holder, :brutal_kill)
    end
  end

  defp waits_for?(caller, holder, deadline) do
    case Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [holder, caller]).rows do
      [[true]] ->
        true

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            5 -> waits_for?(caller, holder, deadline)
          end
        else
          false
        end
    end
  end

  defp unboxed(fun),
    do: Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end) |> Task.await(30_000)

  defp committed_world do
    w =
      unboxed(fn ->
        before = Repo.all(from(u in Platform.Accounts.User, select: u.id))
        w = render_world!()
        media = stored_file!(w.project, "locked #{unique()}", "clip.mp4", "video/mp4")

        {:ok, clip} =
          AgentDrafts.submit_clip(
            w.scope,
            w.profile.id,
            %{
              "file_id" => media.id,
              "title" => "Clip",
              "caption" => "Copy",
              "duration_s" => 10,
              "width" => 1080,
              "height" => 1920
            },
            w.agent.id
          )

        base = Repo.get_by!(ClipRender, clip_id: clip.id, rev: clip.rev)

        Map.merge(w, %{
          clip: clip,
          base: base,
          users: Repo.all(from(u in Platform.Accounts.User, select: u.id)) -- before
        })
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(r in ClipEditRequest, where: r.clip_id == ^w.clip.id))
        Repo.delete_all(from(c in Clip, where: c.id == ^w.clip.id))
        Repo.delete_all(from(p in Social.Profile, where: p.id == ^w.profile.id))
        Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^w.project.id))
        Repo.delete_all(from(s in Platform.Chat.Space, where: s.id == ^w.profile.space_id))
        Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^w.agent.id))
        Repo.delete_all(from(u in Platform.Accounts.User, where: u.id in ^w.users))

        Repo.delete_all(
          from(o in Platform.Tenancy.Org, where: o.id in ^[w.org_id, w.other_org_id])
        )
      end)
    end)

    w
  end
end
