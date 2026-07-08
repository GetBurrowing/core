defmodule Platform.Tasks.ReferencesTest do
  @moduledoc """
  Stage-2 unit tests for `Platform.Tasks.References` — the write-path
  scanner + upsert that keeps `task_references` in sync with
  `Task.description`. Covers:

    * `extract_uuids/1` — pure regex extraction with dedupe.
    * `upsert_from_description/1` — DB refresh semantics: insert new,
      delete stale, ignore self, skip ghost targets.

  The stage-2 hook wiring in `Platform.Tasks.create_task/1` +
  `update_task/2` is exercised in `Platform.Tasks.TasksContextTest`
  under the `write-path hooks` describe block so a single scanner
  regression doesn't have to be traced back through two modules.
  """

  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.References
  alias Platform.Tasks.TaskReference

  describe "extract_uuids/1" do
    test "returns [] for nil / empty string" do
      assert References.extract_uuids(nil) == []
      assert References.extract_uuids("") == []
    end

    test "extracts a single UUIDv7 substring" do
      text = "See task 019f3dbb-3843-70fb-962c-d26b6d1eefcd for context"
      assert References.extract_uuids(text) == ["019f3dbb-3843-70fb-962c-d26b6d1eefcd"]
    end

    test "dedupes repeated ids" do
      id = "019f3dbb-3843-70fb-962c-d26b6d1eefcd"
      text = "#{id} mentioned twice #{id}"
      assert References.extract_uuids(text) == [id]
    end

    test "extracts multiple distinct ids in insertion order" do
      a = "019f3dbb-3843-70fb-962c-d26b6d1eefcd"
      b = "019f0000-1111-7000-8000-abcdef012345"
      text = "first #{a} then #{b}"
      assert References.extract_uuids(text) == [a, b]
    end

    test "lower-cases mixed-case matches" do
      # UUIDv7 shape but with upper-case hex — the wire form task ids
      # are always lower-case, but a paste from another tool may use
      # mixed case. The scanner is case-insensitive at match time and
      # lower-cases for a stable set-diff.
      text = "quoted: 019F3DBB-3843-70FB-962C-D26B6D1EEFCD"
      assert References.extract_uuids(text) == ["019f3dbb-3843-70fb-962c-d26b6d1eefcd"]
    end

    test "ignores things that only look UUID-ish" do
      # Not starting with 019 → not a task id.
      refute Enum.any?(References.extract_uuids("018f3dbb-3843-70fb-962c-d26b6d1eefcd"), fn _ ->
               true
             end)

      # Version nibble != 7 → not UUIDv7.
      assert References.extract_uuids("019f3dbb-3843-40fb-962c-d26b6d1eefcd") == []

      # Missing groups.
      assert References.extract_uuids("019f3dbb-38430-70fb-962c") == []
    end

    test "matches at end-of-string with no trailing punctuation" do
      id = "019f3dbb-3843-70fb-962c-d26b6d1eefcd"
      assert References.extract_uuids("see #{id}") == [id]
    end

    test "requires a word boundary before the match" do
      # Embedded inside a longer word — should NOT match.
      id = "019f3dbb-3843-70fb-962c-d26b6d1eefcd"
      assert References.extract_uuids("prefix#{id}") == []
    end
  end

  describe "upsert_from_description/1" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Refs Project 2"})

      # Two candidate targets that exist in the DB.
      {:ok, target_a} = Tasks.create_task(%{project_id: project.id, title: "target A"})
      {:ok, target_b} = Tasks.create_task(%{project_id: project.id, title: "target B"})

      # Nothing scanned yet on these targets, so their outgoing_task_references
      # sets are empty. We build the source explicitly per test.
      {:ok, project: project, target_a: target_a, target_b: target_b}
    end

    test "inserts one reference row per unique target id in description",
         %{project: project, target_a: a, target_b: b} do
      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "source",
          description: "refs #{a.id} and #{b.id}"
        })

      # `create_task/1` already invoked the scanner as part of the
      # write-path hook. Call it explicitly again to prove idempotence.
      assert {:ok, 2} = References.upsert_from_description(source)

      refs = list_refs(source.id)
      assert MapSet.new(refs) == MapSet.new([a.id, b.id])
    end

    test "skips UUIDs whose target task doesn't exist",
         %{project: project, target_a: a} do
      ghost = "019f0000-dead-7000-8000-000000000042"

      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "source",
          description: "real #{a.id} + ghost #{ghost}"
        })

      assert {:ok, 1} = References.upsert_from_description(source)
      assert list_refs(source.id) == [a.id]
    end

    test "excludes self-references", %{project: project} do
      # Insert without a self-reference first to get a real id, then
      # update the description to include the id.
      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "self",
          description: "tbd"
        })

      {:ok, source} =
        Tasks.update_task(source, %{description: "cites itself: #{source.id}"})

      # No self-refs even though the id is present in the description.
      assert {:ok, 0} = References.upsert_from_description(source)
      assert list_refs(source.id) == []
    end

    test "delete-stale semantics: removing a UUID drops its reference row",
         %{project: project, target_a: a, target_b: b} do
      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "source",
          description: "refs #{a.id} and #{b.id}"
        })

      assert {:ok, 2} = References.upsert_from_description(source)

      # Drop b from the description.
      {:ok, source} = Tasks.update_task(source, %{description: "only #{a.id} now"})

      # The write-path hook already ran; call again to prove no drift.
      assert {:ok, 1} = References.upsert_from_description(source)
      assert list_refs(source.id) == [a.id]
    end

    test "insert-new semantics: adding a UUID inserts without duplicating existing rows",
         %{project: project, target_a: a, target_b: b} do
      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "source",
          description: "only #{a.id}"
        })

      assert {:ok, 1} = References.upsert_from_description(source)

      {:ok, source} =
        Tasks.update_task(source, %{description: "now both #{a.id} and #{b.id}"})

      assert {:ok, 2} = References.upsert_from_description(source)

      assert Enum.sort(list_refs(source.id)) == Enum.sort([a.id, b.id])
    end

    test "clearing the description removes every outgoing reference",
         %{project: project, target_a: a, target_b: b} do
      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "source",
          description: "refs #{a.id} and #{b.id}"
        })

      assert {:ok, 2} = References.upsert_from_description(source)

      {:ok, source} = Tasks.update_task(source, %{description: ""})

      assert {:ok, 0} = References.upsert_from_description(source)
      assert list_refs(source.id) == []
    end

    test "nil description is a no-op that clears any stale rows",
         %{project: project, target_a: a} do
      {:ok, source} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "source",
          description: "refs #{a.id}"
        })

      assert {:ok, 1} = References.upsert_from_description(source)

      {:ok, source} = Tasks.update_task(source, %{description: nil})

      assert {:ok, 0} = References.upsert_from_description(source)
      assert list_refs(source.id) == []
    end
  end

  # ── Test helpers ─────────────────────────────────────────────────────────

  defp list_refs(source_id) do
    import Ecto.Query

    TaskReference
    |> where([r], r.source_task_id == ^source_id)
    |> select([r], r.target_task_id)
    |> Repo.all()
  end
end
