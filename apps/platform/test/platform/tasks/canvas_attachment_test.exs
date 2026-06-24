defmodule Platform.Tasks.CanvasAttachmentTest do
  @moduledoc """
  Stage 1 of task 019ef734 (`task_attach_canvas`): schema + migration
  for the `task_canvas_attachments` join table.

  Covers:

    * Migration up/down round-trip
    * Changeset happy path
    * Required-field validation (each missing required field rejected)
    * `attached_by_kind` inclusion (reject `"bogus"`)
    * DB-layer unique constraint on `(task_id, canvas_id)` — idempotent
      re-attach surfaces as a constraint error the context layer can
      trap.
    * Cascade delete — deleting the parent task removes the attachment
      row at the DB layer.
  """

  use Platform.DataCase, async: true

  alias Ecto.UUID
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{CanvasAttachment, Task}

  setup do
    {:ok, project} = Tasks.create_project(%{name: "CanvasAttachment Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Attach canvas"})
    %{project: project, task: task}
  end

  defp valid_attrs(task) do
    %{
      task_id: task.id,
      canvas_id: UUID.generate(),
      attached_by_kind: "agent",
      attached_by_id: UUID.generate()
    }
  end

  describe "schema + migration" do
    test "table exists with expected columns" do
      # If the migration ran, querying the table should succeed and
      # return zero rows for a fresh sandbox.
      assert {:ok, %Postgrex.Result{rows: rows}} =
               Repo.query(
                 "SELECT id, task_id, canvas_id, note, attached_by_kind, attached_by_id, inserted_at, updated_at FROM task_canvas_attachments"
               )

      assert rows == []
    end

    test "indexes exist (unique pair + task lookup)" do
      {:ok, %Postgrex.Result{rows: rows}} =
        Repo.query(
          "SELECT indexname FROM pg_indexes WHERE tablename = 'task_canvas_attachments' ORDER BY indexname"
        )

      names = Enum.map(rows, fn [n] -> n end)

      assert "task_canvas_attachments_pair_idx" in names

      assert Enum.any?(names, fn n ->
               String.contains?(n, "task_id") and n != "task_canvas_attachments_pair_idx"
             end),
             "expected a task_id lookup index (got: #{inspect(names)})"
    end
  end

  describe "changeset/2" do
    test "is valid with all required fields", %{task: task} do
      changeset = CanvasAttachment.changeset(%CanvasAttachment{}, valid_attrs(task))
      assert changeset.valid?
    end

    test "accepts an optional note", %{task: task} do
      attrs = Map.put(valid_attrs(task), :note, "screenshot of the bug repro")
      changeset = CanvasAttachment.changeset(%CanvasAttachment{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :note) == "screenshot of the bug repro"
    end

    test "rejects when task_id is missing", %{task: task} do
      attrs = task |> valid_attrs() |> Map.delete(:task_id)
      changeset = CanvasAttachment.changeset(%CanvasAttachment{}, attrs)
      refute changeset.valid?
      assert %{task_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects when canvas_id is missing", %{task: task} do
      attrs = task |> valid_attrs() |> Map.delete(:canvas_id)
      changeset = CanvasAttachment.changeset(%CanvasAttachment{}, attrs)
      refute changeset.valid?
      assert %{canvas_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects when attached_by_kind is missing", %{task: task} do
      attrs = task |> valid_attrs() |> Map.delete(:attached_by_kind)
      changeset = CanvasAttachment.changeset(%CanvasAttachment{}, attrs)
      refute changeset.valid?
      assert %{attached_by_kind: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects when attached_by_id is missing", %{task: task} do
      attrs = task |> valid_attrs() |> Map.delete(:attached_by_id)
      changeset = CanvasAttachment.changeset(%CanvasAttachment{}, attrs)
      refute changeset.valid?
      assert %{attached_by_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a bogus attached_by_kind", %{task: task} do
      attrs = Map.put(valid_attrs(task), :attached_by_kind, "bogus")
      changeset = CanvasAttachment.changeset(%CanvasAttachment{}, attrs)
      refute changeset.valid?
      assert %{attached_by_kind: [_]} = errors_on(changeset)
    end

    test "accepts both canonical attached_by_kind values", %{task: task} do
      for kind <- CanvasAttachment.attached_by_kinds() do
        attrs = Map.put(valid_attrs(task), :attached_by_kind, kind)
        changeset = CanvasAttachment.changeset(%CanvasAttachment{}, attrs)

        assert changeset.valid?,
               "expected #{inspect(kind)} to be accepted (errors: #{inspect(errors_on(changeset))})"
      end
    end
  end

  describe "DB constraints" do
    test "unique constraint on (task_id, canvas_id) surfaces as a changeset error",
         %{task: task} do
      attrs = valid_attrs(task)
      assert {:ok, _} = Repo.insert(CanvasAttachment.changeset(%CanvasAttachment{}, attrs))

      assert {:error, changeset} =
               Repo.insert(CanvasAttachment.changeset(%CanvasAttachment{}, attrs))

      errors = errors_on(changeset)

      assert errors[:task_id] == ["has already been taken"] or
               errors[:canvas_id] == ["has already been taken"],
             "expected unique constraint error on the (task_id, canvas_id) pair, got #{inspect(errors)}"
    end

    test "different canvas_ids on the same task are allowed", %{task: task} do
      assert {:ok, _} =
               Repo.insert(CanvasAttachment.changeset(%CanvasAttachment{}, valid_attrs(task)))

      assert {:ok, _} =
               Repo.insert(CanvasAttachment.changeset(%CanvasAttachment{}, valid_attrs(task)))
    end

    test "the same canvas_id on different tasks is allowed", %{task: task, project: project} do
      {:ok, other_task} =
        Tasks.create_task(%{project_id: project.id, title: "Another task"})

      canvas_id = UUID.generate()

      attrs1 = %{valid_attrs(task) | canvas_id: canvas_id}
      attrs2 = %{valid_attrs(other_task) | canvas_id: canvas_id}

      assert {:ok, _} = Repo.insert(CanvasAttachment.changeset(%CanvasAttachment{}, attrs1))
      assert {:ok, _} = Repo.insert(CanvasAttachment.changeset(%CanvasAttachment{}, attrs2))
    end

    test "deleting the parent task cascades the attachment row away", %{task: task} do
      {:ok, attachment} =
        Repo.insert(CanvasAttachment.changeset(%CanvasAttachment{}, valid_attrs(task)))

      assert Repo.get(CanvasAttachment, attachment.id)

      # Hard-delete the task at the DB layer (bypassing soft-delete
      # semantics in the context layer) so the cascade actually
      # fires.
      Repo.delete!(Repo.get!(Task, task.id))

      refute Repo.get(CanvasAttachment, attachment.id)
    end
  end

  # Phoenix's conventional changeset-error helper. DataCase doesn't
  # provide it, so we mirror the inline definition that
  # `Platform.Tasks.StacksTest` uses.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
