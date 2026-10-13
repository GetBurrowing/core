defmodule Platform.Prototypes.PurgerTest do
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.PrototypeFixtures
  import Platform.TenancyFixtures

  alias Platform.Prototypes
  alias Platform.Prototypes.Purger
  alias Platform.Prototypes.Version
  alias Platform.Repo

  setup do
    scratch = scratch_storage!("prototype_purger_test")
    set_settings!(%{enabled: true, retention_days: 90})
    org_id = tenant_org_id("proto-purge-#{System.unique_integer([:positive])}")
    agent = agent!()

    {:ok, %{prototype: p}} =
      Prototypes.publish(
        agent_publisher(agent),
        %{org_id: org_id, name: "P"},
        {:files, bundle_files("v1")}
      )

    p =
      Enum.reduce(2..3, p, fn n, p ->
        {:ok, %{prototype: p}} =
          Prototypes.publish(
            agent_publisher(agent),
            %{prototype: p},
            {:files, bundle_files("v#{n}")}
          )

        p
      end)

    # Every version is 100 days old.
    old = DateTime.add(DateTime.utc_now(), -100, :day)
    Repo.update_all(from(v in Version, where: v.prototype_id == ^p.id), set: [inserted_at: old])

    {:ok, scratch: scratch, prototype: p, agent: agent}
  end

  defp removed(p) do
    Repo.all(from(v in Version, where: v.prototype_id == ^p.id, order_by: v.version))
    |> Enum.map(&{&1.version, not is_nil(&1.removed_at)})
  end

  defp files_of(scratch, p, n),
    do:
      Path.wildcard(Path.join(scratch, "prototypes/#{p.id}/#{n}/**/*"))
      |> Enum.filter(&File.regular?/1)

  test "removes versions past retention and keeps the latest", ctx do
    assert {:ok, 2} = Purger.sweep()
    assert removed(ctx.prototype) == [{1, true}, {2, true}, {3, false}]
    assert files_of(ctx.scratch, ctx.prototype, 1) == []
    assert files_of(ctx.scratch, ctx.prototype, 2) == []
    assert length(files_of(ctx.scratch, ctx.prototype, 3)) == 4
    assert Prototypes.get_live_version(ctx.prototype.id, 1) == nil
  end

  test "latest is the pointer: a version rolled back to is kept", ctx do
    {:ok, _} = Prototypes.rollback(agent_publisher(ctx.agent), ctx.prototype, 1)
    assert {:ok, 2} = Purger.sweep()
    assert removed(ctx.prototype) == [{1, false}, {2, true}, {3, true}]
  end

  test "nothing inside the window is removed, and nil retention keeps everything", ctx do
    assert {:ok, 0} = Purger.sweep(now: DateTime.add(DateTime.utc_now(), -20, :day))
    set_settings!(%{retention_days: nil})
    assert {:ok, 0} = Purger.sweep()
    assert removed(ctx.prototype) == [{1, false}, {2, false}, {3, false}]
  end
end
