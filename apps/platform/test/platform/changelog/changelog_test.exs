defmodule Platform.Changelog.ChangelogTest do
  @moduledoc "Tests for the Changelog context module."
  use Platform.DataCase, async: true

  alias Platform.Changelog
  alias Platform.Tasks

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Helper to create a project + task for FK references
  defp create_task!(attrs \\ %{}) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Test Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/repo"
      })

    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{project_id: project.id, title: "Test task"},
          attrs
        )
      )

    {project, task}
  end

  defp entry_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Add changelog module",
        pr_number: System.unique_integer([:positive]),
        pr_url: "https://github.com/test/repo/pull/1",
        commit_sha: "abc123",
        author: "dev-user",
        tags: ["feature"],
        merged_at: DateTime.utc_now()
      },
      overrides
    )
  end

  describe "create_entry/1" do
    test "creates a changelog entry with valid attrs" do
      assert {:ok, entry} = Changelog.create_entry(entry_attrs())
      assert entry.title == "Add changelog module"
      assert entry.tags == ["feature"]
      assert entry.author == "dev-user"
    end

    test "requires title and merged_at" do
      assert {:error, changeset} = Changelog.create_entry(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.title
      assert "can't be blank" in errors.merged_at
    end

    test "enforces unique pr_number" do
      attrs = entry_attrs(%{pr_number: 42})
      assert {:ok, _} = Changelog.create_entry(attrs)
      assert {:error, changeset} = Changelog.create_entry(attrs)
      errors = errors_on(changeset)
      assert "has already been taken" in errors.pr_number
    end

    test "links to a task via task_id" do
      {_project, task} = create_task!()
      attrs = entry_attrs(%{task_id: task.id})
      assert {:ok, entry} = Changelog.create_entry(attrs)
      assert entry.task_id == task.id
    end

    test "broadcasts new entry on PubSub" do
      Changelog.subscribe()
      attrs = entry_attrs()
      {:ok, entry} = Changelog.create_entry(attrs)
      assert_receive {:new_changelog_entry, ^entry}
    end
  end

  describe "list_entries/1" do
    test "returns entries in reverse chronological order" do
      now = DateTime.utc_now()

      {:ok, old} =
        Changelog.create_entry(
          entry_attrs(%{title: "Old", merged_at: DateTime.add(now, -3600, :second)})
        )

      {:ok, new} =
        Changelog.create_entry(entry_attrs(%{title: "New", merged_at: now}))

      entries = Changelog.list_entries()
      ids = Enum.map(entries, & &1.id)
      assert List.first(ids) == new.id
      assert List.last(ids) == old.id
    end

    test "filters by tag" do
      {:ok, _feat} = Changelog.create_entry(entry_attrs(%{tags: ["feature"]}))
      {:ok, _fix} = Changelog.create_entry(entry_attrs(%{tags: ["fix"]}))

      entries = Changelog.list_entries(tag: "feature")
      assert length(entries) == 1
      assert hd(entries).tags == ["feature"]
    end

    test "paginates with :before cursor" do
      now = DateTime.utc_now()

      {:ok, _old} =
        Changelog.create_entry(
          entry_attrs(%{title: "Old", merged_at: DateTime.add(now, -7200, :second)})
        )

      {:ok, middle} =
        Changelog.create_entry(
          entry_attrs(%{title: "Middle", merged_at: DateTime.add(now, -3600, :second)})
        )

      {:ok, _new} =
        Changelog.create_entry(entry_attrs(%{title: "New", merged_at: now}))

      entries = Changelog.list_entries(before: middle.merged_at, limit: 10)
      assert length(entries) == 1
      assert hd(entries).title == "Old"
    end

    test "preloads task association" do
      {_project, task} = create_task!()
      {:ok, _entry} = Changelog.create_entry(entry_attrs(%{task_id: task.id}))

      [entry] = Changelog.list_entries()
      assert entry.task.id == task.id
      assert entry.task.title == "Test task"
    end
  end

  describe "group_by_date/1" do
    test "groups entries by date with human-readable labels" do
      today = DateTime.utc_now()
      yesterday = DateTime.add(today, -86_400, :second)
      old = DateTime.add(today, -86_400 * 3, :second)

      {:ok, e1} = Changelog.create_entry(entry_attrs(%{title: "Today PR", merged_at: today}))

      {:ok, e2} =
        Changelog.create_entry(entry_attrs(%{title: "Yesterday PR", merged_at: yesterday}))

      {:ok, e3} = Changelog.create_entry(entry_attrs(%{title: "Old PR", merged_at: old}))

      groups = Changelog.group_by_date([e1, e2, e3])

      labels = Enum.map(groups, fn {label, _} -> label end)
      assert "Today" in labels
      assert "Yesterday" in labels
      # Third label is a formatted date
      assert length(labels) == 3
    end
  end

  describe "parse_title/1" do
    test "parses feat: prefix" do
      assert {"add changelog", ["feature"]} = Changelog.parse_title("feat: add changelog")
    end

    test "parses fix: prefix" do
      assert {"crash on reload", ["fix"]} = Changelog.parse_title("fix: crash on reload")
    end

    test "parses scoped prefix like fix(chat):" do
      assert {"resolve error", ["fix"]} = Changelog.parse_title("fix(chat): resolve error")
    end

    test "parses refactor: as improvement" do
      assert {"clean up code", ["improvement"]} =
               Changelog.parse_title("refactor: clean up code")
    end

    test "returns empty tags for non-conventional title" do
      assert {"Update README", []} = Changelog.parse_title("Update README")
    end

    test "handles chore: prefix" do
      assert {"bump deps", ["chore"]} = Changelog.parse_title("chore: bump deps")
    end
  end

  describe "extract_task_id_from_branch/1" do
    test "returns nil for nil" do
      assert Changelog.extract_task_id_from_branch(nil) == nil
    end

    test "returns nil for unrelated branch names" do
      assert Changelog.extract_task_id_from_branch("feat/changelog") == nil
      assert Changelog.extract_task_id_from_branch("main") == nil
    end

    test "extracts full UUID from task/ prefix" do
      {_project, task} = create_task!()
      branch = "task/#{task.id}"
      assert Changelog.extract_task_id_from_branch(branch) == task.id
    end

    test "extracts short prefix and finds matching task" do
      {_project, task} = create_task!()
      # Extract the first 8 chars of the UUID
      prefix = task.id |> String.slice(0, 8)
      branch = "task/#{prefix}"
      assert Changelog.extract_task_id_from_branch(branch) == task.id
    end

    test "returns nil when prefix matches no task" do
      assert Changelog.extract_task_id_from_branch("task/00000000") == nil
    end
  end

  describe "extract_task_id_from_body/1" do
    test "returns nil for nil" do
      assert Changelog.extract_task_id_from_body(nil) == nil
    end

    test "extracts task ID from 'Task: <uuid>' pattern" do
      {_project, task} = create_task!()
      body = "Some text\n\nTask: #{task.id}\n\nMore text"
      assert Changelog.extract_task_id_from_body(body) == task.id
    end
  end
end
