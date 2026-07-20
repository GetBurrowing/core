defmodule Platform.Tasks.Stacks.MigrationSlotTest do
  # async: false → DataCase puts the sandbox in {:shared, self()} mode, which
  # is what lets the Task.async_stream children below touch the Repo at all.
  use Platform.DataCase, async: false

  alias Platform.Tasks
  alias Platform.Tasks.{Stack, Stacks}

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  defp stack! do
    {:ok, project} = Tasks.create_project(%{name: "Migration Slot #{uniq()}"})
    slug = "slot-#{uniq()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stack #{slug}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  # Inverse of `Calendar.strftime(dt, "%Y%m%d%H%M%S")`.
  defp parse!(<<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2>>) do
    NaiveDateTime.new!(
      String.to_integer(y),
      String.to_integer(mo),
      String.to_integer(d),
      String.to_integer(h),
      String.to_integer(mi),
      String.to_integer(s)
    )
  end

  # ── Sequential allocation ─────────────────────────────────────────────────

  describe "allocate_migration_slot/1 — sequential" do
    test "three consecutive calls yield three distinct, monotonic timestamps" do
      stack = stack!()

      assert {:ok, t1} = Stacks.allocate_migration_slot(stack)
      assert {:ok, t2} = Stacks.allocate_migration_slot(stack)
      assert {:ok, t3} = Stacks.allocate_migration_slot(stack)

      assert length(Enum.uniq([t1, t2, t3])) == 3
      assert [t1, t2, t3] == Enum.sort([t1, t2, t3])

      # Canonical `mix ecto.gen.migration` shape: 14 digits.
      for ts <- [t1, t2, t3] do
        assert String.length(ts) == 14
        assert ts =~ ~r/^\d{14}$/
      end
    end

    test "accepts a bare stack_id binary as well as a %Stack{}" do
      stack = stack!()

      assert {:ok, from_struct} = Stacks.allocate_migration_slot(stack)
      assert {:ok, from_id} = Stacks.allocate_migration_slot(stack.id)

      refute from_struct == from_id
    end

    test "a stale in-memory struct does not replay an already-issued slot" do
      stack = stack!()

      assert {:ok, first} = Stacks.allocate_migration_slot(stack)
      # `stack` still carries next_migration_slot: nil — the allocator must
      # re-read inside the lock rather than trust the caller's copy.
      assert {:ok, second} = Stacks.allocate_migration_slot(stack)

      refute first == second
    end
  end

  # ── Concurrency ───────────────────────────────────────────────────────────

  describe "allocate_migration_slot/1 — concurrency" do
    test "20 concurrent allocations on one stack yield 20 distinct timestamps" do
      stack = stack!()

      results =
        1..20
        |> Task.async_stream(
          fn _ -> Stacks.allocate_migration_slot(stack) end,
          max_concurrency: 20,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, {:ok, ts}} -> ts end)

      assert length(results) == 20
      assert MapSet.new(results) |> MapSet.size() == 20
    end
  end

  # ── Cross-stack isolation ─────────────────────────────────────────────────

  describe "allocate_migration_slot/1 — cross-stack isolation" do
    test "two stacks allocate independently; sequences do not interfere" do
      stack_a = stack!()
      stack_b = stack!()

      pairs =
        [stack_a, stack_b, stack_a, stack_b, stack_a, stack_b]
        |> Task.async_stream(
          fn s -> {s.id, elem(Stacks.allocate_migration_slot(s), 1)} end,
          max_concurrency: 6,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, pair} -> pair end)

      by_stack = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))

      # Each stack ran its own sequence of 3, all distinct within the stack.
      for id <- [stack_a.id, stack_b.id] do
        slots = Map.fetch!(by_stack, id)
        assert length(slots) == 3
        assert length(Enum.uniq(slots)) == 3
      end

      # Sequences are independent: the two stacks' cursors advanced
      # separately, so each stack allocated its full run of 3 rather than
      # sharing a single global counter.
      assert Stacks.get_stack(stack_a.id).next_migration_slot != nil
      assert Stacks.get_stack(stack_b.id).next_migration_slot != nil
    end
  end

  # ── Lazy init ─────────────────────────────────────────────────────────────

  describe "allocate_migration_slot/1 — lazy initialization" do
    test "a stack with nil cursor initializes to ~now and then increments" do
      stack = stack!()
      assert stack.next_migration_slot == nil

      before = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      assert {:ok, first} = Stacks.allocate_migration_slot(stack)
      later = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      allocated = parse!(first)

      # First slot is wall-clock now, not some synthetic epoch base.
      assert NaiveDateTime.compare(allocated, before) in [:gt, :eq]
      assert NaiveDateTime.compare(allocated, later) in [:lt, :eq]

      assert {:ok, second} = Stacks.allocate_migration_slot(stack)
      assert NaiveDateTime.compare(parse!(second), allocated) == :gt
    end

    test "a dormant stack's next slot reflects wall clock, not cursor + 1" do
      stack = stack!()

      # Simulate a stack that last allocated long ago.
      stale = ~N[2020-01-01 00:00:00]

      {:ok, _} =
        stack
        |> Stack.changeset(%{next_migration_slot: stale})
        |> Repo.update()

      assert {:ok, ts} = Stacks.allocate_migration_slot(stack)

      # max(current, now) → now wins, so we do NOT get 2020.
      assert NaiveDateTime.compare(parse!(ts), ~N[2025-01-01 00:00:00]) == :gt
    end
  end

  # ── Persistence ───────────────────────────────────────────────────────────

  describe "allocate_migration_slot/1 — persistence" do
    test "reloaded stack's cursor equals the allocated timestamp + 1s" do
      stack = stack!()

      assert {:ok, ts} = Stacks.allocate_migration_slot(stack)

      reloaded = Repo.reload(stack)
      expected = NaiveDateTime.add(parse!(ts), 1, :second)

      assert NaiveDateTime.compare(reloaded.next_migration_slot, expected) == :eq
    end
  end

  # ── Error paths ───────────────────────────────────────────────────────────

  describe "allocate_migration_slot/1 — errors" do
    test "unknown stack id returns {:error, :stack_not_found}" do
      assert {:error, :stack_not_found} =
               Stacks.allocate_migration_slot("019f0000-0000-7000-8000-000000000000")
    end
  end
end
