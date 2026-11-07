defmodule Mix.Tasks.Platform.RevokeOrphanRuntimesTest do
  @moduledoc """
  Task 01a1b34b stage 4: the dry-run-first orphan runtime sweep.

  Seven seeded rows, one per branch of the orphan criterion. Only rows 1
  (stale) and 2 (never connected) are orphans by default; row 3 (connected an
  hour ago) becomes one only when named with `--runtime-id`; rows 4-7 never
  are.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Platform.RevokeOrphanRuntimes
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation.{DeadLetter, DeadLetters, OrphanRuntimes, RuntimePresence}

  defp uniq, do: System.unique_integer([:positive])

  defp agent! do
    n = uniq()

    %Agent{}
    |> Agent.changeset(%{slug: "orphan-agent-#{n}", name: "Orphan Agent #{n}", status: "active"})
    |> Repo.insert!()
  end

  defp runtime!(owner, label, attrs) do
    %AgentRuntime{}
    |> AgentRuntime.changeset(
      Map.merge(
        %{
          runtime_id: "orphan-#{label}-#{uniq()}",
          owner_user_id: owner.id,
          display_name: "Orphan #{label}",
          auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
          status: "active",
          metadata: %{"role" => "gateway-#{label}"}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  setup do
    owner = Platform.TenancyFixtures.root_admin!()
    bound_agent = agent!()

    r1 = runtime!(owner, "stale", %{last_connected_at: ago(30 * 86_400)})
    r2 = runtime!(owner, "never", %{last_connected_at: nil})
    r3 = runtime!(owner, "recent", %{last_connected_at: ago(3_600)})

    r4 =
      runtime!(owner, "bound", %{agent_id: bound_agent.id, last_connected_at: ago(30 * 86_400)})

    r5 = runtime!(owner, "revoked", %{status: "revoked", last_connected_at: nil})
    r6 = runtime!(owner, "suspended", %{status: "suspended", last_connected_at: nil})
    r7 = runtime!(owner, "pointed", %{last_connected_at: ago(30 * 86_400)})

    # Row 7: no agent_id of its own, but an agent's runtime_id points at it.
    agent!() |> Agent.changeset(%{runtime_id: r7.id}) |> Repo.update!()

    rows = [r1, r2, r3, r4, r5, r6, r7]
    on_exit(fn -> Enum.each(rows, &safe_untrack(&1.runtime_id)) end)

    %{rows: rows, r: List.to_tuple(rows)}
  end

  defp safe_untrack(runtime_id) do
    RuntimePresence.untrack(runtime_id)
  catch
    :exit, _ -> :ok
  end

  # Every agent_runtimes and dead letter row as JSON text: byte-equal or not.
  defp snapshot do
    %{rows: runtimes} =
      Repo.query!("SELECT row_to_json(r)::text FROM agent_runtimes r ORDER BY r.id")

    %{rows: letters} =
      Repo.query!("SELECT row_to_json(d)::text FROM federation_dead_letters d ORDER BY d.id")

    {runtimes, letters}
  end

  defp run_task(args) do
    capture_io(fn -> send(self(), {:result, RevokeOrphanRuntimes.run(args)}) end)
    |> then(fn out ->
      assert_received {:result, result}
      {result, out}
    end)
  end

  defp ids(rows), do: rows |> Enum.map(& &1.runtime_id) |> Enum.sort()
  defp reload(%AgentRuntime{id: id}), do: Repo.get!(AgentRuntime, id)

  defp ours(rows, %{rows: seeded}) do
    seeded_ids = MapSet.new(seeded, & &1.runtime_id)
    Enum.filter(rows, &MapSet.member?(seeded_ids, &1.runtime_id))
  end

  defp assert_revoked(runtime) do
    row = reload(runtime)
    assert row.status == "revoked"
    assert row.auth_token_hash == nil
  end

  defp assert_untouched(runtime) do
    assert reload(runtime) == runtime
  end

  describe "dry run (no flags)" do
    test "lists exactly rows 1 and 2 and changes nothing", ctx do
      {r1, r2, _r3, _r4, _r5, _r6, _r7} = ctx.r
      before = snapshot()

      {{:ok, %{dry_run: true, orphans: orphans}}, out} = run_task([])

      assert ids(ours(orphans, ctx)) == ids([r1, r2])
      assert snapshot() == before
      assert out =~ r1.runtime_id
      assert out =~ r2.runtime_id
      assert out =~ "DRY RUN"
      assert out =~ "gateway-stale"
    end

    test "list_orphans returns the documented fields", ctx do
      {r1, _r2, _r3, _r4, _r5, _r6, _r7} = ctx.r
      {:ok, rows} = OrphanRuntimes.list_orphans()
      row = Enum.find(rows, &(&1.runtime_id == r1.runtime_id))

      assert row == %{
               id: r1.id,
               runtime_id: r1.runtime_id,
               owner_user_id: r1.owner_user_id,
               display_name: r1.display_name,
               last_connected_at: r1.last_connected_at,
               inserted_at: r1.inserted_at,
               role: "gateway-stale"
             }
    end

    test "revoke_orphans defaults to a dry run", ctx do
      before = snapshot()
      assert {:ok, %{dry_run: true}} = OrphanRuntimes.revoke_orphans()
      assert {:ok, %{dry_run: true}} = OrphanRuntimes.revoke_orphans(dry_run: nil)
      assert snapshot() == before
      _ = ctx
    end
  end

  describe "--apply" do
    test "revokes exactly rows 1 and 2 and leaves 3-7 untouched", ctx do
      {r1, r2, r3, r4, r5, r6, r7} = ctx.r

      {{:ok, %{dry_run: false, revoked: revoked}}, out} = run_task(["--apply"])

      assert ids(ours(revoked, ctx)) == ids([r1, r2])
      assert_revoked(r1)
      assert_revoked(r2)
      Enum.each([r3, r4, r5, r6, r7], &assert_untouched/1)
      assert out =~ "APPLIED"
    end

    test "disconnects the runtime and abandons its live dead letters", ctx do
      {r1, _r2, r3, _r4, _r5, _r6, _r7} = ctx.r
      PlatformWeb.Endpoint.subscribe("runtime:" <> r1.runtime_id)

      record = fn rid ->
        {:ok, row} =
          DeadLetters.record(%{
            runtime_id: rid,
            source: "system_event",
            responsibility_key: "k.#{uniq()}",
            reason: "runtime_offline"
          })

        row
      end

      orphan_letter = record.(r1.runtime_id)
      other_letter = record.(r3.runtime_id)

      run_task(["--apply"])

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert Repo.get!(DeadLetter, orphan_letter.id).disposition == "abandoned"
      assert Repo.get!(DeadLetter, other_letter.id).disposition == "pending"
    end

    test "re-running is idempotent", ctx do
      {r1, r2, _r3, _r4, _r5, _r6, _r7} = ctx.r
      run_task(["--apply"])
      after_first = snapshot()

      {{:ok, %{revoked: revoked}}, _out} = run_task(["--apply"])

      assert ours(revoked, ctx) == []
      assert snapshot() == after_first
      assert_revoked(r1)
      assert_revoked(r2)
    end

    test "an online runtime is never revoked, even when stale", ctx do
      {r1, r2, _r3, _r4, _r5, _r6, _r7} = ctx.r
      RuntimePresence.track(r1.runtime_id)

      {{:ok, %{orphans: listed}}, _out} = run_task([])
      assert ids(ours(listed, ctx)) == [r2.runtime_id]

      {{:ok, %{revoked: revoked}}, _out} = run_task(["--apply"])

      assert ids(ours(revoked, ctx)) == [r2.runtime_id]
      assert_untouched(r1)
    end

    test "--stale-days moves the cutoff", ctx do
      {_r1, r2, _r3, _r4, _r5, _r6, _r7} = ctx.r
      {{:ok, %{orphans: orphans}}, _out} = run_task(["--stale-days", "60"])
      assert ids(ours(orphans, ctx)) == [r2.runtime_id]
    end
  end

  describe "--runtime-id" do
    test "revokes a named recent orphan (row 3)", ctx do
      {r1, r2, r3, _r4, _r5, _r6, _r7} = ctx.r

      {{:ok, %{revoked: revoked}}, _out} =
        run_task(["--apply", "--runtime-id", r3.runtime_id])

      assert ids(revoked) == [r3.runtime_id]
      assert_revoked(r3)
      # Naming rows restricts the sweep to them.
      assert_untouched(r1)
      assert_untouched(r2)
    end

    test "does not revoke an agent-bound row (4) or an agent-pointed row (7)", ctx do
      {_r1, _r2, _r3, r4, r5, r6, r7} = ctx.r

      {{:ok, %{revoked: revoked, orphans: orphans}}, _out} =
        run_task(
          ["--apply"] ++
            Enum.flat_map([r4, r5, r6, r7], &["--runtime-id", &1.runtime_id])
        )

      assert revoked == []
      assert orphans == []
      Enum.each([r4, r5, r6, r7], &assert_untouched/1)
    end

    test "dry run with --runtime-id changes nothing", ctx do
      {_r1, _r2, r3, _r4, _r5, _r6, _r7} = ctx.r
      before = snapshot()

      {{:ok, %{dry_run: true, orphans: orphans}}, _out} =
        run_task(["--runtime-id", r3.runtime_id])

      assert ids(orphans) == [r3.runtime_id]
      assert snapshot() == before
    end
  end
end
