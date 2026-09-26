defmodule Platform.Tasks.StageNameLengthTest do
  @moduledoc """
  `stages.name` is `varchar(255)` NOT NULL
  (`20260320120000_create_tasks_tables.exs:100`). Before task 01a08a87 an
  over-length name reached Postgres and raised `Postgrex.Error` 22001 from
  inside the `plan_create` / `plan_update` transaction, so an MCP caller got an
  opaque 500. `Stage.changeset/2` now bounds it with
  `validate_length(:name, max: 255, count: :codepoints)`, and `plan_update`
  renders the changeset envelope field-keyed (like `plan_create`) instead of
  dumping the `%Ecto.Changeset{}` struct.

  Why codepoints: Postgres `varchar(n)` counts characters in the server
  encoding (UTF8 -> codepoints). Ecto's default `:graphemes` is looser and
  `:bytes` is stricter; cases 4 and 5 pin each side. Multi-byte fixtures are
  built from byte-explicit expressions, never pasted glyphs, because the
  combining and precomposed forms render identically.

  Covers `name` ONLY. Every task here is titled "Stage name host", well under
  any bound, so no case can pass on `Task.changeset/2`'s title bound
  (`task_title_length_test.exs` covers that field).
  """
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Tasks
  alias Platform.Tasks.Stage

  # e + U+0301 COMBINING ACUTE ACCENT: 1 grapheme, 2 codepoints, 3 bytes.
  @comb "e" <> <<0x0301::utf8>>
  # U+00E9 precomposed: 1 grapheme, 1 codepoint, 2 bytes.
  @pre <<0x00E9::utf8>>

  defp create_task do
    {:ok, project} =
      Tasks.create_project(%{name: "Stage Name Project #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Stage name host"})
    task
  end

  defp stage_input(name, description \\ "d") do
    %{
      "name" => name,
      "description" => description,
      "position" => 1,
      "validations" => [%{"kind" => "test_pass"}]
    }
  end

  defp plan_create(task, name) do
    ToolSurface.execute(
      "plan_create",
      %{"task_id" => task.id, "stages" => [stage_input(name)]},
      %{}
    )
  end

  defp assert_name_error(result) do
    assert {:error, %{error: msg}} = result
    assert msg =~ "name"
    assert msg =~ "255"
    msg
  end

  defp stage_snapshot(plan_id) do
    plan_id
    |> Tasks.list_stages()
    |> Enum.map(&{&1.id, &1.name})
  end

  test "1. a 256-char name via plan_create is a name field error and persists no plan" do
    task = create_task()
    name = String.duplicate("s", 256)

    assert_name_error(plan_create(task, name))
    assert Tasks.latest_plan(task.id) == nil

    changeset =
      Stage.changeset(%Stage{}, %{plan_id: Ecto.UUID.generate(), position: 1, name: name})

    refute changeset.valid?
    assert {_msg, opts} = changeset.errors[:name]
    assert opts[:validation] == :length
    assert opts[:kind] == :max
    assert opts[:count] == 255
  end

  test "2. a 255-char name via plan_create succeeds and persists exactly" do
    task = create_task()
    name = String.duplicate("s", 255)

    assert {:ok, plan} = plan_create(task, name)
    assert [{_id, ^name}] = stage_snapshot(plan.id)
  end

  test "3. a rejected plan_update leaves the draft unchanged and does not dump the changeset" do
    task = create_task()
    assert {:ok, plan} = plan_create(task, "Original")

    before_stages = stage_snapshot(plan.id)
    before_plan = Tasks.get_plan(plan.id)
    assert [{_id, "Original"}] = before_stages

    msg =
      assert_name_error(
        ToolSurface.execute(
          "plan_update",
          %{
            "plan_id" => plan.id,
            "stages" => [stage_input(String.duplicate("s", 256), "d2")]
          },
          %{}
        )
      )

    refute msg =~ "#Ecto.Changeset"

    # Same stage ids and names: delete_plan_stage_tree!/1 rolled back with
    # the failed insert.
    assert stage_snapshot(plan.id) == before_stages
    assert Tasks.get_plan(plan.id).updated_at == before_plan.updated_at
  end

  test "4. codepoint pin: 128 combining sequences (256 codepoints) are rejected" do
    task = create_task()
    name = String.duplicate(@comb, 128)

    # The fixture proves itself: under a grapheme bound this would pass.
    assert String.length(name) == 128
    assert length(String.codepoints(name)) == 256

    assert_name_error(plan_create(task, name))
    assert Tasks.latest_plan(task.id) == nil
  end

  test "5. byte pin: 255 precomposed chars (510 bytes) succeed and round-trip" do
    task = create_task()
    name = String.duplicate(@pre, 255)

    assert length(String.codepoints(name)) == 255
    assert byte_size(name) == 510

    assert {:ok, plan} = plan_create(task, name)
    assert [{_id, ^name}] = stage_snapshot(plan.id)
  end

  test "6. trailing-space pin: 255 chars plus a space is rejected, not truncated" do
    # Postgres silently truncates an over-length varchar value when every
    # excess character is a space, so on main this SUCCEEDED as a 255-char
    # name. Rejecting it is a deliberate behaviour change (task 01a08a87).
    task = create_task()

    assert_name_error(plan_create(task, String.duplicate("a", 255) <> " "))
    assert Tasks.latest_plan(task.id) == nil
  end
end
