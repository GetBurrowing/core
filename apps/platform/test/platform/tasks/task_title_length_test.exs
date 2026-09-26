defmodule Platform.Tasks.TaskTitleLengthTest do
  @moduledoc """
  `tasks.title` is `varchar(255)` (`20260320120000_create_tasks_tables.exs:52`).
  Before task 01a08a87 an over-length title reached Postgres and raised
  `Postgrex.Error` 22001 out of `Repo.insert`/`Repo.update`, so an MCP caller
  got an opaque 500. `Task.changeset/2` now bounds it with
  `validate_length(:title, max: 255, count: :codepoints)`.

  Why codepoints: Postgres `varchar(n)` counts characters in the server
  encoding (UTF8 -> codepoints). Ecto's default `:graphemes` is looser and
  `:bytes` is stricter; cases 5 and 6 pin each side. Multi-byte fixtures are
  built from byte-explicit expressions, never pasted glyphs, because the
  combining and precomposed forms render identically.

  Covers `title` ONLY. `stages.name` has its own file so neither field's tests
  can pass on the other field's implementation.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  # e + U+0301 COMBINING ACUTE ACCENT: 1 grapheme, 2 codepoints, 3 bytes.
  @comb "e" <> <<0x0301::utf8>>
  # U+00E9 precomposed: 1 grapheme, 1 codepoint, 2 bytes.
  @pre <<0x00E9::utf8>>

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{name: "Title Length Project #{System.unique_integer([:positive])}"})

    project
  end

  defp create_task do
    project = create_project()

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Base", description: "original"})

    task
  end

  defp update_title(task, title, extra \\ %{}) do
    ToolSurface.execute(
      "task_update",
      Map.merge(%{"task_id" => task.id, "title" => title}, extra),
      %{}
    )
  end

  defp assert_title_error(result) do
    assert {:error, %{error: msg}} = result
    assert msg =~ "title"
    assert msg =~ "255"
    msg
  end

  test "1. a 256-char title via task_update is a title field error, not a raise" do
    task = create_task()
    title = String.duplicate("a", 256)

    assert_title_error(update_title(task, title))

    changeset = Task.changeset(task, %{title: title})
    refute changeset.valid?
    assert {_msg, opts} = changeset.errors[:title]
    assert opts[:validation] == :length
    assert opts[:kind] == :max
    assert opts[:count] == 255
  end

  test "2. a 255-char title via task_update succeeds and round-trips exactly" do
    task = create_task()
    title = String.duplicate("a", 255)

    assert {:ok, _} = update_title(task, title)
    assert Tasks.get_task_record(task.id).title == title
  end

  test "3. a rejected title leaves title, description and updated_at unchanged" do
    task = create_task()
    before = Tasks.get_task_record(task.id)

    assert_title_error(
      update_title(task, String.duplicate("a", 256), %{"description" => "changed"})
    )

    after_row = Tasks.get_task_record(task.id)
    assert after_row.title == before.title
    assert after_row.description == before.description
    assert after_row.updated_at == before.updated_at
  end

  test "4. task_create with a 256-char title is a title field error and persists nothing" do
    project = create_project()
    title = String.duplicate("b", 256)

    assert_title_error(
      ToolSurface.execute("task_create", %{"project_id" => project.id, "title" => title}, %{})
    )

    refute Repo.exists?(from(t in Task, where: t.title == ^title))
  end

  test "5. codepoint pin: 128 combining sequences (256 codepoints) are rejected" do
    task = create_task()
    title = String.duplicate(@comb, 128)

    # The fixture proves itself: under a grapheme bound this would pass.
    assert String.length(title) == 128
    assert length(String.codepoints(title)) == 256

    assert_title_error(update_title(task, title))
  end

  test "6. byte pin: 255 precomposed chars (510 bytes) succeed and round-trip" do
    task = create_task()
    title = String.duplicate(@pre, 255)

    assert length(String.codepoints(title)) == 255
    assert byte_size(title) == 510

    assert {:ok, _} = update_title(task, title)
    assert Tasks.get_task_record(task.id).title == title
  end

  test "7. trailing-space pin: 255 chars plus a space is rejected, not truncated" do
    # Postgres silently truncates an over-length varchar value when every
    # excess character is a space, so on main this SUCCEEDED as a 255-char
    # title. Rejecting it is a deliberate behaviour change (task 01a08a87).
    task = create_task()

    assert_title_error(update_title(task, String.duplicate("a", 255) <> " "))
    assert Tasks.get_task_record(task.id).title == "Base"
  end
end
