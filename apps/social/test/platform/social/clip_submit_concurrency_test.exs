defmodule Platform.Social.ClipSubmitConcurrencyTest do
  @moduledoc """
  `AgentDrafts.submit_clip/4` (the door behind `social_clip_submit`) is
  idempotent per profile + exact file, atomically: it takes the profile row
  `FOR UPDATE` (`Social.lock_profile/3`), re-decides every check on the locked
  rows, and only then looks for the profile's live clip on that file.

  Two real database connections (the sandbox is switched to `:auto`; its one
  shared connection can never show a lock blocking). The world is committed and
  removed by hand.

  The guard under test is the `Social.lock_profile(scope, profile_id, :update)`
  call in `AgentDrafts.submit_locked/5`. The holder below takes the same row
  lock only to park submitters on it; with the guard removed the submitters do
  not wait, so "must block" fails first. Mutations to run (each must go red):
    1. remove the lock_profile call: "concurrent repeats ..." fails (not blocked);
    2. drop `render_project` / `check_clip_file` / the profile re-read under the
       lock: the matching "re-decided under the lock" test fails.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, ClipRender, Profile}

  setup do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])

    {root, own_root?} =
      case Repo.one(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1)) do
        nil ->
          {Repo.insert!(%Platform.Tenancy.Org{
             name: "Dedupe root #{n}",
             slug: "dedupe-root-#{n}"
           }), true}

        root ->
          {root, false}
      end

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "Dedupe lock #{n}",
        slug: "dedupe-lock-#{n}",
        parent_org_id: root.id
      })

    {:ok, project} = Platform.Tasks.create_project(%{name: "Dedupe lock #{n}", org_id: org.id})

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      profile_ids = Repo.all(from(p in Profile, where: p.org_id == ^org.id, select: p.id))

      # Clips and renders go with the profile by FK; files go with the project.
      for step <- [
            fn -> Repo.delete_all(from(p in Profile, where: p.id in ^profile_ids)) end,
            fn ->
              Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id))
            end,
            fn -> Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id)) end,
            fn ->
              if own_root?,
                do: Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^root.id))
            end
          ] do
        try do
          step.()
        rescue
          _ -> :ok
        end
      end

      Sandbox.mode(Repo, :manual)
    end)

    {:ok, profile} =
      Social.create_profile(org.id, %{
        name: "Dedupe show #{n}",
        project_id: project.id,
        home_url: "https://www.youtube.com/@dedupeshow"
      })

    %{org: org, project: project, profile: profile, scope: {:tenant, org.id}}
  end

  defp video!(ctx) do
    {:ok, file, _} =
      Platform.Files.add_bytes(
        ctx.project,
        "dedupe clip #{System.unique_integer([:positive])}",
        "c.mp4",
        "video/mp4",
        ingest: false
      )

    file
  end

  defp submit(ctx, file, extra \\ %{}),
    do:
      AgentDrafts.submit_clip(
        ctx.scope,
        ctx.profile.id,
        Map.merge(%{"file_id" => file.id}, extra),
        nil
      )

  defp clip_count(profile_id),
    do: Repo.aggregate(from(c in Clip, where: c.profile_id == ^profile_id), :count)

  defp render_count(profile_id) do
    Repo.aggregate(
      from(r in ClipRender,
        join: c in Clip,
        on: c.id == r.clip_id,
        where: c.profile_id == ^profile_id
      ),
      :count
    )
  end

  # Waits until `count` connections are blocked, directly or queued behind another
  # waiter, on the transaction of backend `holder_backend_pid`: bound to this holder.
  defp await_blocked_on!(holder_backend_pid, count, tries \\ 100) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        WITH RECURSIVE waiting(pid) AS (
          SELECT a.pid FROM pg_stat_activity a WHERE $1 = ANY(pg_blocking_pids(a.pid))
          UNION
          SELECT a.pid FROM pg_stat_activity a, waiting w WHERE w.pid = ANY(pg_blocking_pids(a.pid))
        )
        SELECT count(*) FROM waiting
        """,
        [holder_backend_pid]
      )

    cond do
      waiting >= count ->
        :ok

      tries == 0 ->
        flunk("only #{waiting} of #{count} submitters were blocked on the holder")

      true ->
        receive do
        after
          50 -> await_blocked_on!(holder_backend_pid, count, tries - 1)
        end
    end
  end

  # A process that locks the profile row FOR UPDATE and holds its transaction open
  # until told to :release; `work` then runs inside that transaction. Returns the
  # task and its backend pid.
  defp backend_pid(ctx, work \\ fn -> :ok end) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Social.lock_profile(ctx.org.id, ctx.profile.id, :update) || Repo.rollback(:gone)
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:locked, pid})

          receive do
            :release -> work.()
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:locked, pid}, 5_000
    {task, pid}
  end

  test "first import still works", ctx do
    file = video!(ctx)
    assert {:ok, %Clip{review_status: "pending", rev: 1}} = submit(ctx, file)
    assert clip_count(ctx.profile.id) == 1
    assert render_count(ctx.profile.id) == 1
  end

  test "concurrent repeats serialise on the profile lock: one clip, one render", ctx do
    file = video!(ctx)
    {lock_holder, pid} = backend_pid(ctx)

    submitters = for _ <- 1..4, do: Task.async(fn -> submit(ctx, file) end)

    # Observed, not slept: all four are blocked on the holder's profile row lock.
    # Without `lock_profile` in submit_locked/5 they never block and this fails.
    await_blocked_on!(pid, 4)
    assert Enum.all?(submitters, &(Task.yield(&1, 0) == nil))

    send(lock_holder.pid, :release)
    assert {:ok, _} = Task.await(lock_holder, 10_000)

    results = Enum.map(submitters, &Task.await(&1, 10_000))
    assert [{:ok, %Clip{id: id}} | rest] = results
    assert Enum.all?(rest, &match?({:ok, %Clip{id: ^id}}, &1))
    assert clip_count(ctx.profile.id) == 1
    assert render_count(ctx.profile.id) == 1
  end

  # Smoke only: the race window is tiny, so this passes even with the lock removed
  # (observed). The parked test above is the proof for the lock.
  test "unparked concurrent repeats of one file yield one live clip (smoke)", ctx do
    file = video!(ctx)

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> submit(ctx, file) end) end)
      |> Enum.map(&Task.await(&1, 15_000))

    ids = results |> Enum.map(fn {:ok, c} -> c.id end) |> Enum.uniq()
    assert length(ids) == 1
    assert clip_count(ctx.profile.id) == 1
    assert render_count(ctx.profile.id) == 1
  end

  test "concurrent submits of different files keep separate clips", ctx do
    files = for _ <- 1..3, do: video!(ctx)

    results =
      files
      |> Enum.map(fn f -> Task.async(fn -> submit(ctx, f) end) end)
      |> Enum.map(&Task.await(&1, 15_000))

    assert length(results |> Enum.map(fn {:ok, c} -> c.id end) |> Enum.uniq()) == 3
    assert render_count(ctx.profile.id) == 3
  end

  describe "every decision is made again on the locked rows" do
    # A holder locks the profile, a submitter passes its pre-flight and blocks,
    # the holder changes ONE thing in its transaction and commits; the submitter
    # must be refused, nothing written, and no existing clip returned.
    defp blocked_submit(ctx, file, holder_work) do
      {lock_holder, pid} = backend_pid(ctx, holder_work)
      submitter = Task.async(fn -> submit(ctx, file) end)
      await_blocked_on!(pid, 1)
      send(lock_holder.pid, :release)
      assert {:ok, _} = Task.await(lock_holder, 10_000)
      Task.await(submitter, 10_000)
    end

    defp unlink_project(ctx) do
      fn ->
        Repo.update_all(from(p in Profile, where: p.id == ^ctx.profile.id),
          set: [project_id: nil]
        )
      end
    end

    test "profile removed while waiting: not_found, nothing written", ctx do
      file = video!(ctx)

      remove = fn -> Repo.delete!(Repo.get!(Profile, ctx.profile.id)) end
      assert {:error, :not_found} = blocked_submit(ctx, file, remove)
      assert Repo.get(Profile, ctx.profile.id) == nil
    end

    test "project removed while waiting: profile_needs_project, new file", ctx do
      file = video!(ctx)
      assert {:error, :profile_needs_project} = blocked_submit(ctx, file, unlink_project(ctx))
      assert clip_count(ctx.profile.id) == 0
      assert render_count(ctx.profile.id) == 0
    end

    test "project removed while waiting: profile_needs_project, replay does not leak the clip",
         ctx do
      file = video!(ctx)
      assert {:ok, _existing} = submit(ctx, file)

      assert {:error, :profile_needs_project} = blocked_submit(ctx, file, unlink_project(ctx))
      assert clip_count(ctx.profile.id) == 1
      assert render_count(ctx.profile.id) == 1
    end

    test "file deleted while waiting: file_not_in_project, replay does not leak the clip", ctx do
      file = video!(ctx)
      assert {:ok, _} = submit(ctx, file)

      # the file row carries no lock the submitter waits on, so it can change in the
      # holder's transaction too; it commits before the submitter's locked re-check
      delete = fn ->
        Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
          set: [deleted_at: DateTime.utc_now()]
        )
      end

      assert {:error, :file_not_in_project} = blocked_submit(ctx, file, delete)
      assert clip_count(ctx.profile.id) == 1
    end
  end
end
