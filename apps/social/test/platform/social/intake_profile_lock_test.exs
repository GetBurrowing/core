defmodule Platform.Social.IntakeProfileLockTest do
  @moduledoc """
  Social Studio slice C: `Intake.import_manifest/4` takes the profile row lock
  `FOR SHARE` that `Studio.create_post/4` takes (`Social.lock_profile/3`), so
  `Social.delete_profile/2` (`FOR UPDATE`) and an import serialise. Lock order:
  profile row first, then the per-ref advisory lock.

  Two real database connections, as in `studio_profile_lock_concurrency_test.exs`
  (the sandbox is switched to `:auto`); the world is committed and removed by
  hand. The sandbox's single connection cannot show contention, so this file is
  the proof for the lock.

  Mutation checks to run: remove the `Social.lock_profile/3` call in
  `Intake.import_clip/4` and "an import waits for a deletion in flight" fails;
  take `:update` there and "an import does not queue behind a shared lock" fails.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, Intake, Profile}

  setup do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])

    {root, own_root?} =
      case Repo.one(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1)) do
        nil ->
          {Repo.insert!(%Platform.Tenancy.Org{
             name: "Intake root #{n}",
             slug: "intake-root-#{Platform.TenancyFixtures.run_token()}-#{n}"
           }), true}

        root ->
          {root, false}
      end

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "Intake lock #{n}",
        slug: "intake-lock-#{Platform.TenancyFixtures.run_token()}-#{n}",
        parent_org_id: root.id
      })

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "intake-lock-#{Platform.TenancyFixtures.run_token()}-#{n}@example.com",
        oidc_sub: "intake-lock-#{Platform.TenancyFixtures.run_token()}-#{n}",
        name: "Intake Lock #{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: org.id,
      role: "member"
    })

    {:ok, project} = Platform.Tasks.create_project(%{name: "Intake lock #{n}", org_id: org.id})

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      profile_ids = Repo.all(from(p in Profile, where: p.org_id == ^org.id, select: p.id))

      # Clips (and their renders) go with the profile by FK; files go with the project.
      Repo.delete_all(from(p in Profile, where: p.id in ^profile_ids))
      Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id))
      Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
      Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^user.id))
      Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id))
      if own_root?, do: Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^root.id))
      Sandbox.mode(Repo, :manual)
    end)

    %{org: org, user: user, project: project}
  end

  defp world!(ctx) do
    n = System.unique_integer([:positive])

    {:ok, profile} =
      Social.create_profile(ctx.org.id, %{
        name: "Intake show #{n}",
        project_id: ctx.project.id,
        home_url: "https://www.youtube.com/@intakeshow",
        approver_user_ids: [ctx.user.id]
      })

    {:ok, _account} =
      Social.create_account(ctx.org.id, profile, %{platform: "tiktok", handle: "@intake#{n}"})

    {:ok, profile} = Platform.Social.Studio.set_enabled(ctx.org.id, profile.id, ctx.user.id, true)
    %{profile: profile}
  end

  defp manifest(ctx, ref) do
    {:ok, file, _} =
      Platform.Files.add_bytes(
        ctx.project,
        "clip bytes #{System.unique_integer([:positive])}",
        "c.mp4",
        "video/mp4",
        ingest: false
      )

    %{"clips" => [%{"external_ref" => ref, "file_id" => file.id, "title" => "T"}]}
  end

  defp import!(ctx, w, manifest),
    do: Intake.import_manifest({:tenant, ctx.org.id}, w.profile.id, manifest, ctx.user.id)

  # Renders of THIS fixture's clips only, so unrelated committed rows cannot change the answer.
  defp render_count(profile_id) do
    Repo.aggregate(
      from(r in Platform.Social.ClipRender,
        join: c in Clip,
        on: c.id == r.clip_id,
        where: c.profile_id == ^profile_id
      ),
      :count
    )
  end

  defp clip_count(profile_id),
    do: Repo.aggregate(from(c in Clip, where: c.profile_id == ^profile_id), :count)

  # A process that locks the profile row in `mode`, tells the test, and holds its
  # transaction open until told to `:release`; `work` then runs inside it.
  defp holder(ctx, w, mode, work \\ fn -> :ok end) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        Social.lock_profile(ctx.org.id, w.profile.id, mode) || Repo.rollback(:gone)
        send(parent, :locked)

        receive do
          :release -> work.()
        after
          10_000 -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  test "an import waits for a deletion in flight, then reads the profile as not found", ctx do
    w = world!(ctx)
    m = manifest(ctx, "ep4/after-delete")
    deleter = holder(ctx, w, :update, fn -> Repo.delete!(Repo.get!(Profile, w.profile.id)) end)
    assert_receive :locked, 5_000

    importer = Task.async(fn -> import!(ctx, w, m) end)
    assert Task.yield(importer, 400) == nil, "import must block on the profile row lock"

    send(deleter.pid, :release)
    assert {:ok, _} = Task.await(deleter, 10_000)

    assert {:ok, %{clips: [%{status: {:error, :not_found}, clip_id: nil}]}} =
             Task.await(importer, 10_000)

    assert Repo.get(Profile, w.profile.id) == nil
    assert clip_count(w.profile.id) == 0
  end

  # Waits until a connection is blocked on THIS advisory key (`hashtextextended(key, 0)`, which
  # `pg_locks` stores as classid = high 32 bits, objid = low 32 bits, objsubid 1), i.e. the
  # importer has taken the profile row and is now waiting on its per-ref lock. Bound to the key,
  # so another process using the database cannot satisfy it.
  defp await_advisory_waiter!(key, tries \\ 100) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'advisory' AND NOT granted AND objsubid = 1
          AND classid::bigint = ((hashtextextended($1, 0) >> 32) & 4294967295)
          AND objid::bigint = (hashtextextended($1, 0) & 4294967295)
        """,
        [key]
      )

    cond do
      waiting > 0 ->
        :ok

      tries == 0 ->
        flunk("the importer never reached the per-ref lock")

      true ->
        receive do
        after
          50 -> await_advisory_waiter!(key, tries - 1)
        end
    end
  end

  # The import itself must hold the shared profile lock while it is in flight. The test
  # does not take that lock for it (an earlier version had a holder take it, so it passed
  # even with the import's own lock removed): the import is parked on the per-ref advisory
  # lock, which it takes AFTER the profile row, so a deletion that waits is waiting on the
  # import's own share lock.
  test "a deletion waits for an import in flight, then is refused and the clip survives", ctx do
    w = world!(ctx)
    ref = "ep4/before-delete"
    m = manifest(ctx, ref)
    parent = self()
    key = "social:clip_import:#{w.profile.id}:#{ref}"

    ref_holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
          send(parent, :ref_locked)

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :ref_locked, 5_000

    importer = Task.async(fn -> import!(ctx, w, m) end)
    await_advisory_waiter!(key)
    assert Task.yield(importer, 0) == nil, "import must be parked on the per-ref lock"

    deleter = Task.async(fn -> Social.delete_profile(ctx.org.id, w.profile) end)

    assert Task.yield(deleter, 400) == nil,
           "delete must wait on the share lock the in-flight import holds"

    send(ref_holder.pid, :release)
    assert {:ok, _} = Task.await(ref_holder, 10_000)

    assert {:ok, %{clips: [%{status: :created, clip_id: clip_id}]}} =
             Task.await(importer, 10_000)

    assert {:error, :has_studio_clips} = Task.await(deleter, 10_000)
    assert Repo.get(Profile, w.profile.id)
    assert %Clip{flow: "studio"} = Repo.get(Clip, clip_id)
  end

  # The approver check runs before the lock and again on the row read under it
  # (found in review): an approver removed, or archived, while an import
  # waits for the profile row must not be able to import, or to learn an existing clip id.
  defp remove_approver!(w) do
    Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
      set: [approver_user_ids: []]
    )
  end

  test "an approver removed while an import waits is refused, and no clip is written", ctx do
    w = world!(ctx)
    m = manifest(ctx, "ep4/removed")
    remover = holder(ctx, w, :update, fn -> remove_approver!(w) end)
    assert_receive :locked, 5_000

    importer = Task.async(fn -> import!(ctx, w, m) end)
    assert Task.yield(importer, 400) == nil, "import must block on the profile row lock"

    send(remover.pid, :release)
    assert {:ok, _} = Task.await(remover, 10_000)

    assert {:ok, %{clips: [%{status: {:error, reason}, clip_id: nil}]}} =
             Task.await(importer, 10_000)

    assert reason in [:not_an_approver, :approver_no_access]
    assert clip_count(w.profile.id) == 0
    assert render_count(w.profile.id) == 0
  end

  test "an approver removed while a replay waits cannot learn the existing clip id", ctx do
    w = world!(ctx)
    m = manifest(ctx, "ep4/removed-replay")
    assert {:ok, %{clips: [%{status: :created, clip_id: id}]}} = import!(ctx, w, m)

    remover = holder(ctx, w, :update, fn -> remove_approver!(w) end)
    assert_receive :locked, 5_000
    importer = Task.async(fn -> import!(ctx, w, m) end)
    assert Task.yield(importer, 400) == nil

    send(remover.pid, :release)
    assert {:ok, _} = Task.await(remover, 10_000)

    assert {:ok, %{clips: [%{status: {:error, _}, clip_id: nil}]}} = Task.await(importer, 10_000)
    assert Repo.get(Clip, id), "the existing clip is untouched"
  end

  test "an approver archived while an import waits is refused", ctx do
    w = world!(ctx)
    m = manifest(ctx, "ep4/archived")

    archiver =
      holder(ctx, w, :update, fn ->
        Repo.update_all(from(u in Platform.Accounts.User, where: u.id == ^ctx.user.id),
          set: [archived_at: DateTime.utc_now()]
        )
      end)

    assert_receive :locked, 5_000
    importer = Task.async(fn -> import!(ctx, w, m) end)
    assert Task.yield(importer, 400) == nil

    send(archiver.pid, :release)
    assert {:ok, _} = Task.await(archiver, 10_000)

    assert {:ok, %{clips: [%{status: {:error, :approver_archived}, clip_id: nil}]}} =
             Task.await(importer, 10_000)

    assert clip_count(w.profile.id) == 0
  end

  # The other decisions made under the lock (slice A's rule: a preflight check does not
  # replace deciding on the state used inside the transaction). Each test changes one thing
  # while an import waits for the profile row, and asserts that clip alone is refused with
  # no clip, no render and no returned id.
  defp waits_then_refused(ctx, w, ref, change, reason) do
    m = manifest(ctx, ref)
    changer = holder(ctx, w, :update, change)
    assert_receive :locked, 5_000

    importer = Task.async(fn -> import!(ctx, w, m) end)
    assert Task.yield(importer, 400) == nil, "import must block on the profile row lock"

    send(changer.pid, :release)
    assert {:ok, _} = Task.await(changer, 10_000)

    assert {:ok, %{clips: [%{status: {:error, ^reason}, clip_id: nil}]}} =
             Task.await(importer, 10_000)

    assert clip_count(w.profile.id) == 0
    assert render_count(w.profile.id) == 0
  end

  test "Studio switched off while an import waits is refused :studio_disabled", ctx do
    w = world!(ctx)

    waits_then_refused(
      ctx,
      w,
      "ep4/switched-off",
      fn ->
        Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
          set: [studio_enabled: false]
        )
      end,
      :studio_disabled
    )
  end

  test "the project removed from the profile while an import waits is refused", ctx do
    w = world!(ctx)

    waits_then_refused(
      ctx,
      w,
      "ep4/project-removed",
      fn ->
        Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
          set: [project_id: nil]
        )
      end,
      :studio_needs_project
    )
  end

  test "the project archived while an import waits is refused", ctx do
    w = world!(ctx)

    waits_then_refused(
      ctx,
      w,
      "ep4/project-archived",
      fn ->
        Repo.update_all(from(p in Platform.Tasks.Project, where: p.id == ^ctx.project.id),
          set: [archived_at: DateTime.utc_now()]
        )
      end,
      :studio_needs_project
    )
  end

  test "social.use denied on the project while an import waits is refused", ctx do
    w = world!(ctx)

    waits_then_refused(
      ctx,
      w,
      "ep4/use-denied",
      fn ->
        {:ok, _} =
          Platform.Access.Grants.deny(%{
            principal: {:user, ctx.user.id},
            permission: "social.use",
            resource: {:project, ctx.project.id}
          })
      end,
      :no_social_access
    )
  end

  test "files.read denied on the project while an import waits is refused", ctx do
    w = world!(ctx)

    waits_then_refused(
      ctx,
      w,
      "ep4/read-denied",
      fn ->
        {:ok, _} =
          Platform.Access.Grants.deny(%{
            principal: {:user, ctx.user.id},
            permission: "files.read",
            resource: {:project, ctx.project.id}
          })
      end,
      :no_file_access
    )
  end

  # ── the chosen file's row ─────────────────────────────────────────────
  # Lock order is profile row, then the per-ref lock, then the file row. `Files.delete_file/2`
  # is one UPDATE of the file row and takes no other lock, so it cannot form a cycle with it.

  defp file_id_of(manifest), do: manifest["clips"] |> hd() |> Map.fetch!("file_id")

  defp xid!(), do: Repo.query!("SELECT txid_current()").rows |> hd() |> hd()

  # Waits until a connection is blocked on the given transaction (a row lock it holds).
  defp await_blocked_on!(xid, tries \\ 100) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'transactionid' AND NOT granted
          AND transactionid::text::bigint = ($1::bigint & 4294967295)
        """,
        [xid]
      )

    cond do
      waiting > 0 ->
        :ok

      tries == 0 ->
        flunk("nothing ever blocked on the holder's transaction")

      true ->
        receive do
        after
          50 -> await_blocked_on!(xid, tries - 1)
        end
    end
  end

  defp mark_deleted!(file_id) do
    Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file_id),
      set: [deleted_at: DateTime.utc_now()]
    )
  end

  test "a file deleted while an import waits for it is refused, and no clip is written", ctx do
    w = world!(ctx)
    m = manifest(ctx, "ep4/file-deleted")
    file_id = file_id_of(m)
    parent = self()

    # A deletion in flight: holds the file row FOR UPDATE and soft-deletes it on release.
    deleter =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one(
            from(f in Platform.Files.File,
              where: f.id == ^file_id,
              select: f.id,
              lock: "FOR UPDATE"
            )
          )

          send(parent, {:held, xid!()})

          receive do
            :release -> mark_deleted!(file_id)
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:held, xid}, 5_000
    importer = Task.async(fn -> import!(ctx, w, m) end)
    await_blocked_on!(xid)
    assert Task.yield(importer, 0) == nil

    send(deleter.pid, :release)
    assert {:ok, _} = Task.await(deleter, 10_000)

    assert {:ok, %{clips: [%{status: {:error, :file_not_in_project}, clip_id: nil}]}} =
             Task.await(importer, 10_000)

    assert clip_count(w.profile.id) == 0
    assert render_count(w.profile.id) == 0
  end

  test "a file deletion waits for an import that holds the file, then proceeds", ctx do
    w = world!(ctx)
    ref = "ep4/file-held"
    m = manifest(ctx, ref)
    file_id = file_id_of(m)
    parent = self()

    # Stalls the importer's clip INSERT (which comes after it has locked the file) on the unique
    # (profile, external_ref) index: an uncommitted clip with the same ref.
    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.insert!(%Clip{
            profile_id: w.profile.id,
            external_ref: ref,
            source_url: "https://example.com/blocker"
          })

          send(parent, {:held, xid!()})

          receive do
            :release -> Repo.rollback(:released)
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:held, xid}, 5_000
    importer = Task.async(fn -> import!(ctx, w, m) end)
    await_blocked_on!(xid)

    deleter = Task.async(fn -> mark_deleted!(file_id) end)
    assert Task.yield(deleter, 400) == nil, "the deletion must wait for the import's file lock"

    send(blocker.pid, :release)
    assert {:error, :released} = Task.await(blocker, 10_000)

    assert {:ok, %{clips: [%{status: :created}]}} = Task.await(importer, 10_000)
    assert {1, _} = Task.await(deleter, 10_000)
    assert clip_count(w.profile.id) == 1
  end

  test "an import does not queue behind a shared lock held by a creator", ctx do
    w = world!(ctx)
    creator = holder(ctx, w, :share)
    assert_receive :locked, 5_000

    importer = Task.async(fn -> import!(ctx, w, manifest(ctx, "ep4/shared")) end)

    assert {:ok, {:ok, %{clips: [%{status: :created}]}}} = {:ok, Task.await(importer, 2_000)},
           "a :share holder must not block an import"

    send(creator.pid, :release)
    assert {:ok, _} = Task.await(creator, 10_000)
  end
end
