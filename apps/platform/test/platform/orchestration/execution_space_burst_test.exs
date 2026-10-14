defmodule Platform.Orchestration.ExecutionSpaceBurstTest do
  @moduledoc """
  Task 01a07783 stage 2 — the exec-space slug derivation holds on the paths
  that actually materialise execution spaces in production.

  ## The vacuity trap this suite is built around

  The obvious test for this defect is "create N tasks in a burst and assert
  none fails". **That test passes on the unfixed build**, because
  `Tasks.create_task/1` never mints a slug. `do_create_task/2` inserts the
  task and then calls `References.upsert_from_description/1`,
  `Memory.ingest_async/1` and `maybe_emit_sponsor_assigned/3`, and nothing
  else — there is no `ExecutionSpace.find_or_create/1` anywhere on the
  creation path.

  Execution spaces materialise LAZILY, at four call sites:

    * `Platform.Tasks.ChatPins.pin/3`
    * `Platform.Federation.ToolSurface` (the MCP surface)
    * `Platform.Orchestration.ContextAssembler`
    * `Platform.Orchestration.TaskRouter`

  So every burst here is followed by an explicit materialisation pass. A
  creation loop on its own asserts nothing about slugs.

  This is also why the observed failure looked the way it did:
  `chat_pins_test.exs` creates its second task successfully and detonates
  eight lines later on `ChatPins.pin(task2.id, ...)`. The task insert was
  never the failure site.

  ## The second vacuity trap: hoping for a same-millisecond pair

  A tight creation loop does not RELIABLY put two tasks in one millisecond.
  On a machine where each `create_task/1` round trip exceeds 1ms, twenty
  inserts land in twenty distinct milliseconds, the burst never exercises
  the hazard, and it goes green on the unfixed build for the second time.

  Every case below therefore contains a CONSTRUCTED same-millisecond pair —
  two task ids sharing their leading 12 hex characters, which for a UUIDv7
  is exactly the creation millisecond and nothing else. The collision is
  made to happen; it is never waited for. The natural burst rides alongside
  as a realism check on the real creation path, not as the proof.

  ## Failure shape

  A collision comes back as `{:error, %Ecto.Changeset{}}`, not a raise:
  `Platform.Chat.Space.changeset/2` declares
  `unique_constraint(:slug, name: :chat_spaces_unique_org_slug)`, so
  `Chat.create_space/1` returns the invalid changeset. `assert_raise` would
  be the wrong instrument.

  `chat_spaces_unique_org_slug` is `(org_id, slug) WHERE org_id IS NOT NULL`
  and is the only index that can fire on an execution row: exec rows carry
  `workspace_id: nil` (and `(NULL, x)` is never btree-equal to itself), and
  the meeting / null-scope-channel indexes are partial on other kinds.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ChatPins
  alias Platform.Tasks.Task

  @slug_prefix "task-exec-"

  # The leading 12 hex characters of a UUIDv7 are its 48-bit creation
  # millisecond. Two ids that agree here were created in the same
  # millisecond, which is the entire precondition for the defect.
  @ms_prefix_len 12

  defp hex(id), do: String.replace(id, "-", "")
  defp ms_prefix(id), do: id |> hex() |> String.slice(0, @ms_prefix_len)

  # Build a task id that shares `source_id`'s creation millisecond exactly
  # but differs everywhere after it — i.e. the id a second task would have
  # carried had it been created in the same millisecond as `source_id`.
  #
  # A UUID is 8-4-4-4-12 hex, so the first 12 hex characters are exactly the
  # first two dash-separated groups plus the trailing dash: 14 characters of
  # the formatted string.
  defp same_millisecond_twin(source_id, suffix)
       when is_binary(source_id) and is_binary(suffix) do
    String.slice(source_id, 0, 14) <> "7000-8000-" <> suffix
  end

  defp count_exec_spaces_for_tasks(task_ids) do
    Repo.aggregate(
      from(s in Space,
        where:
          s.kind == "execution" and
            fragment("?->>'task_id' = ANY(?)", s.metadata, ^task_ids)
      ),
      :count
    )
  end

  defp count_exec_spaces_for(task_id), do: count_exec_spaces_for_tasks([task_id])

  defp project_in_acme(name) do
    org_id = acme_org_id()
    {:ok, project} = Tasks.create_project(%{name: name, org_id: org_id})
    {org_id, project}
  end

  describe "burst creation followed by lazy materialisation" do
    test "every task in a one-org burst materialises its own execution space" do
      {org_id, project} = project_in_acme("Exec Slug Burst Project")

      # ── Realism: 20 tasks through the real creation path, tight loop, no
      # sleeps, no jitter, no serialisation. This half exercises
      # `Tasks.create_task/1` as production calls it (FindingFiler,
      # Meetings.Triage, the architecture cron sweep, the MCP `task_create`
      # surface all drive it in reduces).
      natural_tasks =
        for n <- 1..20 do
          {:ok, task} =
            Tasks.create_task(%{project_id: project.id, title: "Burst task #{n}"})

          task
        end

      # ── Determinism: the loop above MAY put two inserts in one
      # millisecond and may not — that is machine-dependent, and a case
      # that only bites on a fast machine is not coverage. So the
      # same-millisecond pair is CONSTRUCTED rather than hoped for: take a
      # real id out of the burst and mint the id a twin task would have
      # carried had it been created in the same millisecond.
      #
      # The twin is inserted with `Repo.insert!/1` because
      # `Task.changeset/2` does not cast `:id`, so `create_task/1` cannot be
      # handed one. That is immaterial to what is under test: the creation
      # path provably does not touch `chat_spaces`, so how the task row got
      # there has no bearing on the slug. The production materialisation
      # path is covered by the `ChatPins.pin/3` case below.
      twin_source = Enum.at(natural_tasks, 9)
      twin_id = same_millisecond_twin(twin_source.id, "00000000beef")

      assert ms_prefix(twin_id) == ms_prefix(twin_source.id),
             "fixture is broken: the twin must share the source's UUIDv7 millisecond"

      refute twin_id == twin_source.id

      twin = Repo.insert!(%Task{id: twin_id, project_id: project.id, title: "Burst twin"})

      tasks = natural_tasks ++ [twin]
      task_ids = Enum.map(tasks, & &1.id)

      # How many same-millisecond pairs the NATURAL loop happened to
      # produce. Reported in the assertion messages rather than asserted on:
      # it is a property of the machine, not of the code. The constructed
      # twin is what guarantees the hazard is exercised at all.
      natural_ms_buckets = natural_tasks |> Enum.map(&ms_prefix(&1.id)) |> Enum.uniq() |> length()
      natural_pairs = length(natural_tasks) - natural_ms_buckets

      # At least one same-millisecond pair is present by construction.
      assert length(Enum.uniq(Enum.map(task_ids, &ms_prefix/1))) < length(task_ids),
             "the burst must contain a same-millisecond pair or it does not exercise the defect"

      # ── Materialise. This is the step the naive burst test omits, and
      # without it every assertion below is vacuous.
      results = Enum.map(task_ids, fn id -> {id, ExecutionSpace.find_or_create(id)} end)

      failures = for {id, {:error, reason}} <- results, do: {id, reason}

      assert failures == [],
             "every find_or_create/1 in the burst must succeed " <>
               "(natural same-ms pairs in this run: #{natural_pairs}); failures: " <>
               inspect(failures, limit: :infinity)

      spaces = for {_id, {:ok, space}} <- results, do: space
      assert length(spaces) == length(task_ids)

      # One slug per task: the derivation is a bijection of the task id.
      slugs = Enum.map(spaces, & &1.slug)
      assert length(Enum.uniq(slugs)) == length(task_ids)
      assert Enum.uniq(Enum.map(spaces, & &1.id)) |> length() == length(task_ids)

      # And every slug is the whole task id, not a prefix of it.
      for {id, space} <- Enum.zip(task_ids, spaces) do
        assert space.slug == @slug_prefix <> hex(id)
        assert space.org_id == org_id
      end

      # The rows are really there, counted by task_id — independent of the
      # slug derivation, so this cannot pass by agreeing with itself.
      assert count_exec_spaces_for_tasks(task_ids) == length(task_ids)
    end
  end

  describe "ChatPins.pin/3 — a real production materialisation path" do
    test "both members of a same-millisecond pair pin successfully in one org" do
      {org_id, project} = project_in_acme("Exec Slug Pin Project")

      # Constructed to share the UUIDv7 millisecond `0b0b0b0b2c2c`.
      id_a = "0b0b0b0b-2c2c-7000-8000-00000000000a"
      id_b = "0b0b0b0b-2c2c-7000-8000-00000000000b"

      assert ms_prefix(id_a) == ms_prefix(id_b)
      refute hex(id_a) == hex(id_b)

      task_a = Repo.insert!(%Task{id: id_a, project_id: project.id, title: "Pin path A"})
      task_b = Repo.insert!(%Task{id: id_b, project_id: project.id, title: "Pin path B"})

      viewer = %{kind: "user", id: "viewer@example.com"}

      # `pin/3` calls `ExecutionSpace.find_or_create/1` first and threads the
      # result through a `with`, so a slug collision surfaces here as
      # `{:error, %Ecto.Changeset{}}` from `pin/3` itself.
      assert {:ok, %{space: space_a}} = ChatPins.pin(task_a.id, viewer, "sponsor@example.com")
      assert {:ok, %{space: space_b}} = ChatPins.pin(task_b.id, viewer, "sponsor@example.com")

      assert space_a.slug == @slug_prefix <> hex(id_a)
      assert space_b.slug == @slug_prefix <> hex(id_b)
      assert space_a.slug != space_b.slug
      assert space_a.id != space_b.id

      # `org_id` is what brings `chat_spaces_unique_org_slug` into play. With
      # nil on both rows the index cannot fire and the pair proves nothing.
      assert space_a.org_id == org_id
      assert space_b.org_id == org_id

      assert count_exec_spaces_for(id_a) == 1
      assert count_exec_spaces_for(id_b) == 1
    end
  end

  describe "back-compatibility with pre-existing short slugs" do
    test "a legacy 12-character slug row resolves alongside a newly minted one" do
      {org_id, project} = project_in_acme("Exec Slug Legacy Project")

      # Deliberately a same-millisecond pair. A legacy row occupying
      # `task-exec-<12 hex>` is precisely what the old derivation left
      # behind, and a task created in that same millisecond is the one the
      # old derivation would have blocked. On the fixed build the new row
      # takes the full 32-hex slug and the two coexist.
      legacy_id = "0c0c0c0c-3d3d-7000-8000-00000000000a"
      fresh_id = "0c0c0c0c-3d3d-7000-8000-00000000000b"

      assert ms_prefix(legacy_id) == ms_prefix(fresh_id)

      Repo.insert!(%Task{id: legacy_id, project_id: project.id, title: "Legacy slug task"})
      Repo.insert!(%Task{id: fresh_id, project_id: project.id, title: "Fresh slug task"})

      legacy_slug = @slug_prefix <> ms_prefix(legacy_id)
      assert String.length(legacy_slug) == String.length(@slug_prefix) + @ms_prefix_len

      # Written directly, exactly as the pre-fix code would have written it.
      {:ok, legacy_space} =
        Chat.create_space(%{
          name: legacy_slug,
          slug: legacy_slug,
          kind: "execution",
          org_id: org_id,
          metadata: %{"task_id" => legacy_id}
        })

      assert {:ok, fresh_space} = ExecutionSpace.find_or_create(fresh_id)

      fresh_slug = @slug_prefix <> hex(fresh_id)
      assert fresh_space.slug == fresh_slug
      refute fresh_space.slug == legacy_slug

      # Both resolve BY SLUG, org-scoped.
      assert %Space{id: found_legacy} = Chat.get_space_by_slug(legacy_slug, org_id: org_id)
      assert found_legacy == legacy_space.id

      assert %Space{id: found_fresh} = Chat.get_space_by_slug(fresh_slug, org_id: org_id)
      assert found_fresh == fresh_space.id

      # Both resolve BY TASK ID — the path every resolver in the codebase
      # actually uses (`metadata->>'task_id'`), which is why no backfill
      # migration is needed for the short-slug rows.
      assert %Space{id: ^found_legacy} = ExecutionSpace.find_by_task_id(legacy_id)
      assert %Space{id: ^found_fresh} = ExecutionSpace.find_by_task_id(fresh_id)

      # `find_or_create/1` RESOLVES the legacy row; it never re-mints it at
      # the new width and never inserts a second row beside it.
      assert {:ok, %Space{id: ^found_legacy, slug: ^legacy_slug}} =
               ExecutionSpace.find_or_create(legacy_id)

      assert count_exec_spaces_for(legacy_id) == 1
      assert count_exec_spaces_for(fresh_id) == 1

      # The pinned-rail label reads through `metadata->>'task_id'` too, so it
      # is indifferent to slug width: a legacy row renders its task's title
      # exactly as a new-width row does.
      assert ChatPins.display_name_for_space(legacy_space) == "Legacy slug task"
      assert ChatPins.display_name_for_space(fresh_space) == "Fresh slug task"

      # And the fallback still fires when the task_id resolves to nothing.
      # `display_name_for_space/1` falls back to `space.name`, which on an
      # execution row is the slug verbatim (`find_or_create/1` writes the
      # same string to both fields).
      orphan_task_id = "0d0d0d0d-4e4e-7000-8000-00000000000a"
      orphan_slug = @slug_prefix <> ms_prefix(orphan_task_id)

      {:ok, orphan_space} =
        Chat.create_space(%{
          name: orphan_slug,
          slug: orphan_slug,
          kind: "execution",
          org_id: org_id,
          metadata: %{"task_id" => orphan_task_id}
        })

      refute Repo.exists?(from(t in Task, where: t.id == ^orphan_task_id))
      assert ChatPins.display_name_for_space(orphan_space) == orphan_slug
      assert orphan_space.name == orphan_space.slug
    end
  end
end
