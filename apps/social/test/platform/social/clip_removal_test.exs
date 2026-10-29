defmodule Platform.Social.ClipRemovalTest do
  use Platform.DataCase, async: false
  import Ecto.Query
  import Platform.SocialFixtures
  alias Platform.{Repo, Social}

  alias Platform.Social.{
    AgentDrafts,
    Clip,
    ClipJob,
    ClipJobs,
    ClipLibrary,
    ClipRemoval,
    ClipRender,
    ClipReviewFeed,
    ClipVersions,
    Post
  }

  setup do
    w = world!()
    {:ok, w: w}
  end

  defp world! do
    w = render_world!()
    file = stored_file!(w.project, "render-one-#{unique()}", "one.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{file_id: file.id, title: "First render", duration_s: 12.0},
        w.agent.id
      )

    Map.merge(w, %{clip: clip, file: file, first: render_id!(clip)})
  end

  defp remove(w), do: Social.remove_clip(w.org_id, w.profile.id, w.clip.id, w.approver.id)

  defp version(w, id),
    do: Social.remove_clip_render(w.org_id, w.profile.id, w.clip.id, id, w.approver.id)

  defp second!(w) do
    file = stored_file!(w.project, "render-two-#{unique()}", "two.mp4", "video/mp4")

    {:ok, clip} =
      Repo.transaction(fn ->
        ClipVersions.append!(w.clip.id, file, %{title: "Second render"}, %{
          headline: "Second render",
          completion_key: "second:#{unique()}"
        })
      end)

    %{w | clip: clip} |> Map.put(:second, render_id!(clip))
  end

  test "removal hides both read models but retains history, Files bytes and actor", %{w: w} do
    assert {:ok, %{removed_clip?: true, clip: removed}} = remove(w)
    assert removed.removed_by_user_id == w.approver.id
    assert %DateTime{} = removed.removed_at
    assert Social.get_clip(w.org_id, w.clip.id) == nil
    assert Social.list_clips(w.org_id) == []
    assert ClipReviewFeed.pending_count(w.org_id, w.profile.id) == 0
    assert ClipLibrary.list(w.org_id).items == []
    assert {:error, :not_found} = ClipVersions.get(w.org_id, w.profile.id, w.clip.id, w.first)
    assert Repo.get!(ClipRender, w.first).removed_at
    assert {:ok, _} = Repo.get!(ClipRender, w.first) |> ClipVersions.metadata() |> Jason.encode()
    assert Platform.Files.get_file(w.file.id)
    assert {:ok, stream} = Platform.Files.Storage.get(w.file.storage_key)
    assert IO.iodata_to_binary(Enum.to_list(stream)) =~ "render-one"
    assert {:error, :not_found} = remove(w)
  end

  test "human approver is freshly checked; old raw context cannot cascade", %{w: w} do
    for {user, reason} <- [{w.agent.id, :not_a_human}, {w.outsider.id, :not_an_approver}] do
      assert {:error, ^reason} = Social.remove_clip(w.org_id, w.profile.id, w.clip.id, user)
    end

    assert {:error, :human_required} = Social.delete_clip(w.org_id, w.clip)
    {:ok, _} = Social.update_profile(w.org_id, w.profile, %{approver_user_ids: []})
    assert {:error, :not_an_approver} = remove(w)
    assert is_nil(Repo.get!(Clip, w.clip.id).removed_at)
  end

  test "foreign scope/profile/version and malformed or stale ids do not mutate", %{w: w} do
    other = world!()

    assert {:error, :not_found} =
             Social.remove_clip(other.org_id, w.profile.id, w.clip.id, other.approver.id)

    assert {:error, :not_found} =
             Social.remove_clip(w.org_id, other.profile.id, w.clip.id, w.approver.id)

    for id <- ["bad", other.first, Ecto.UUID.generate()] do
      assert {:error, :not_found} = version(w, id)
    end

    assert is_nil(Repo.get!(ClipRender, w.first).removed_at)
  end

  test "noncurrent removal changes only that entry and never reuses revision or completion keys",
       %{w: w} do
    w = second!(w)
    assert {:ok, %{removed_clip?: false, clip: clip}} = version(w, w.first)
    assert clip.render_file_id == w.clip.render_file_id
    assert clip.rev == 2
    assert [%{id: id}] = ClipRemoval.history(w.org_id, w.profile.id, clip.id)
    assert id == w.second
    assert {:error, :not_found} = version(w, w.first)
    assert Repo.get!(ClipRender, w.first).rev == 1
  end

  test "current removal promotes playable history and future render gets max historical rev + 1",
       %{w: w} do
    w = second!(w)
    assert {:ok, %{clip: clip, removed_clip?: false}} = version(w, w.second)
    assert {clip.rev, clip.render_file_id, clip.review_status} == {1, w.file.id, "pending"}
    assert clip.title == "First render"
    assert clip.reviewed_render_id == nil
    {:ok, job} = ClipJobs.enqueue_rerender(w.org_id, clip.id, w.approver.id, %{})
    assert job.payload["expected_rev"] == 3
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

    assert {:ok, %{clip: next}} =
             ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.file.id})

    assert next.rev == 3
    assert Repo.get!(ClipRender, w.second).rev == 2
  end

  test "last playable removal hides clip rather than leaving broken playback", %{w: w} do
    assert {:ok, %{removed_clip?: true}} = version(w, w.first)
    assert ClipReviewFeed.review_queue(w.org_id, w.profile.id) == []

    assert {:error, :not_found} =
             ClipJobs.enqueue_rerender(w.org_id, w.clip.id, w.approver.id, %{})

    assert {:error, :not_found} =
             Repo.transaction(fn ->
               ClipVersions.append!(w.clip.id, w.file, %{}, %{completion_key: "late"})
             end)

    assert Repo.aggregate(from(r in ClipRender, where: r.clip_id == ^w.clip.id), :count) == 1
  end

  test "approved identity remains protected even without a post", %{w: w} do
    Repo.update!(Ecto.Changeset.change(w.clip, reviewed_render_id: w.first))
    assert {:error, :version_in_use} = version(w, w.first)
    assert {:error, :version_in_use} = remove(w)
    assert is_nil(Repo.get!(ClipRender, w.first).removed_at)
  end

  test "all post states, immutable render links and legacy media-only references are guarded", %{
    w: w
  } do
    for status <- ~w(draft needs_approval approved scheduled published failed) do
      post =
        Repo.insert!(%Post{
          account_id: w.tiktok.id,
          status: status,
          approved_by_user_id: w.approver.id,
          approved_at: DateTime.utc_now(),
          body: "post",
          media_file_ids: [w.file.id]
        })

      assert {:error, :post_reference} = version(w, w.first)
      assert {:error, :post_reference} = remove(w)
      Repo.delete!(post)
    end

    post =
      Repo.insert!(%Post{
        account_id: w.tiktok.id,
        status: "published",
        approved_by_user_id: w.approver.id,
        approved_at: DateTime.utc_now(),
        body: "post",
        clip_render_id: w.first
      })

    assert {:error, :post_reference} = remove(w)
    assert Repo.get!(Post, post.id).status == "published"
  end

  test "legacy clip-bound posts and shared cover files block even without version id", %{w: w} do
    for attrs <- [%{clip_id: w.clip.id}, %{cover_file_id: w.file.id}] do
      post =
        Repo.insert!(
          struct(
            Post,
            Map.merge(
              %{
                account_id: w.tiktok.id,
                status: "published",
                approved_by_user_id: w.approver.id,
                approved_at: DateTime.utc_now(),
                body: "post"
              },
              attrs
            )
          )
        )

      assert {:error, :post_reference} = version(w, w.first)
      Repo.delete!(post)
    end
  end

  test "whole clip rejects a reference to any child while an unrelated version can be removed", %{
    w: w
  } do
    w = second!(w)

    post =
      Repo.insert!(%Post{
        account_id: w.tiktok.id,
        status: "scheduled",
        approved_by_user_id: w.approver.id,
        approved_at: DateTime.utc_now(),
        body: "post",
        clip_render_id: w.first
      })

    assert {:error, :post_reference} = remove(w)
    assert {:ok, %{clip: clip}} = version(w, w.second)
    assert clip.render_file_id == w.file.id
    assert Repo.get!(Post, post.id).clip_render_id == w.first
  end

  test "queued, claimed and running jobs refuse before removal; failed jobs retain audit", %{w: w} do
    {:ok, job} = ClipJobs.enqueue_rerender(w.org_id, w.clip.id, w.approver.id, %{})

    for status <- ~w(queued claimed running) do
      Repo.update!(Ecto.Changeset.change(job, status: status))
      assert {:error, :job_in_flight} = remove(w)
      assert {:error, :job_in_flight} = version(w, w.first)
    end

    Repo.update!(Ecto.Changeset.change(job, status: "failed"))
    assert {:ok, _} = remove(w)
    assert Repo.get!(ClipJob, job.id).clip_id == w.clip.id
  end

  test "two independent connections serialize deletion before a concurrent enqueue" do
    # Committed fixtures and separate unboxed connections prove actual PG locks,
    # rather than tasks sharing the test's one sandbox connection.
    w = committed_world!()
    parent = self()

    remover =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.one!(from(c in Clip, where: c.id == ^w.clip.id, lock: "FOR UPDATE"))
            assert {:ok, _} = remove(w)
            send(parent, {:removed_uncommitted, self()})

            receive do
              :commit -> :ok
            after
              5000 -> raise "commit barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:removed_uncommitted, pid}, 5000

    enqueuer =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          ClipJobs.enqueue_rerender(w.org_id, w.clip.id, w.approver.id, %{})
        end)
      end)

    assert Task.yield(enqueuer, 100) == nil
    send(pid, :commit)
    assert {:ok, :ok} = Task.await(remover)
    assert {:error, :not_found} = Task.await(enqueuer)

    unboxed(fn ->
      assert Repo.aggregate(from(j in ClipJob, where: j.clip_id == ^w.clip.id), :count) == 0
    end)
  end

  test "deletion serializes before a human approval on another connection" do
    w = committed_world!()
    parent = self()

    remover =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.one!(from(c in Clip, where: c.id == ^w.clip.id, lock: "FOR UPDATE"))
            assert {:ok, _} = remove(w)
            send(parent, {:removing, self()})

            receive do
              :commit -> :ok
            after
              5000 -> raise "commit barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:removing, pid}, 5000

    approver =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Social.approve_clip(w.org_id, w.clip.id, w.approver.id, %{
            "render_id" => w.first,
            "account_ids" => [w.tiktok.id]
          })
        end)
      end)

    assert Task.yield(approver, 100) == nil
    send(pid, :commit)
    assert {:ok, :ok} = Task.await(remover)
    assert {:error, :not_found} = Task.await(approver)

    unboxed(fn ->
      assert Repo.aggregate(from(p in Post, where: p.clip_id == ^w.clip.id), :count) == 0
    end)
  end

  test "completion and removal serialize without resurrection or loss of completion audit" do
    w = committed_world!()

    job =
      unboxed(fn ->
        {:ok, job} = ClipJobs.enqueue_rerender(w.org_id, w.clip.id, w.approver.id, %{})
        {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
        job
      end)

    parent = self()

    completer =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, %{clip: clip}} =
                     ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.file.id})

            assert clip.rev == 2
            send(parent, {:completing, self()})

            receive do
              :commit -> :ok
            after
              5000 -> raise "commit barrier timed out"
            end
          end)
        end)
      end)

    assert_receive {:completing, pid}, 5000

    remover =
      Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> remove(w) end) end)

    assert Task.yield(remover, 100) == nil
    send(pid, :commit)
    assert {:ok, :ok} = Task.await(completer)
    assert {:ok, %{removed_clip?: true}} = Task.await(remover)

    unboxed(fn ->
      assert Repo.get!(ClipJob, job.id).status == "done"
      assert Repo.aggregate(from(r in ClipRender, where: r.clip_id == ^w.clip.id), :count) == 2

      assert {:error, :job_closed} =
               ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.file.id})

      assert Social.get_clip(w.org_id, w.clip.id) == nil
    end)
  end

  defp unboxed(fun) do
    Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end) |> Task.await(30_000)
  end

  defp committed_world! do
    w =
      unboxed(fn ->
        before_users = Repo.all(from(u in Platform.Accounts.User, select: u.id))
        w = world!()
        after_users = Repo.all(from(u in Platform.Accounts.User, select: u.id))
        Map.put(w, :created_users, after_users -- before_users)
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(p in Platform.Social.Profile, where: p.id == ^w.profile.id))
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
end
