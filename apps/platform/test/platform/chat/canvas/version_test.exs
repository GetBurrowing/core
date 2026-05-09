defmodule Platform.Chat.Canvas.VersionTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Version
  alias Platform.Chat.Canvas.Versions
  alias Platform.Repo

  defp setup_space_and_participant do
    {:ok, space} =
      Chat.create_space(%{
        name: "Versions Test #{System.unique_integer([:positive])}",
        slug: "versions-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    %{space: space, participant: participant}
  end

  defp create_canvas(space_id, participant_id, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "space_id" => space_id,
          "created_by" => participant_id,
          "title" => "Test"
        },
        overrides
      )

    {:ok, canvas} = Chat.create_canvas(attrs)
    canvas
  end

  defp build_version_attrs(canvas_id, revision, overrides \\ %{}) do
    Map.merge(
      %{
        canvas_id: canvas_id,
        revision: revision,
        document: %{
          "version" => 1,
          "revision" => revision,
          "root" => %{"id" => "root", "type" => "stack"}
        },
        ops: nil,
        written_by: %{"type" => "user", "display_name" => "Tester", "id" => Ecto.UUID.generate()},
        written_at: DateTime.utc_now()
      },
      overrides
    )
  end

  describe "schema + insert" do
    setup do
      ctx = setup_space_and_participant()
      canvas = create_canvas(ctx.space.id, ctx.participant.id)
      Map.put(ctx, :canvas, canvas)
    end

    test "valid changeset inserts a row", %{canvas: canvas} do
      attrs = build_version_attrs(canvas.id, 7)
      changeset = Version.changeset(%Version{}, attrs)
      assert changeset.valid?
      assert {:ok, %Version{revision: 7}} = Repo.insert(changeset)
    end

    test "unique index rejects duplicate (canvas_id, revision)", %{canvas: canvas} do
      # create_canvas already wrote v1 — re-inserting v1 must fail.
      assert {:error, changeset} =
               %Version{}
               |> Version.changeset(build_version_attrs(canvas.id, 1))
               |> Repo.insert()

      refute changeset.valid?
      assert {_msg, [constraint: :unique, constraint_name: _]} = changeset.errors[:canvas_id]
    end

    test "deleting the canvas cascades to versions", %{canvas: canvas} do
      # `create_canvas/1` already wrote a v1 — exercise cascade by adding
      # additional revisions on top.
      assert {:ok, _v2} =
               %Version{}
               |> Version.changeset(build_version_attrs(canvas.id, 2))
               |> Repo.insert()

      assert {:ok, _v3} =
               %Version{}
               |> Version.changeset(build_version_attrs(canvas.id, 3))
               |> Repo.insert()

      total_before = Repo.aggregate(Version, :count)
      assert total_before >= 3

      Repo.delete!(Repo.get!(Canvas, canvas.id))

      # All rows for this canvas removed; other canvases (if any in this
      # transaction) still exist.
      import Ecto.Query
      assert Repo.aggregate(from(v in Version, where: v.canvas_id == ^canvas.id), :count) == 0
    end

    test "ops field accepts a list (wrapped) and round-trips", %{canvas: canvas} do
      ops = [["set_props", "node-1", %{"value" => "hi"}]]

      assert {:ok, version} =
               %Version{}
               |> Version.changeset(build_version_attrs(canvas.id, 3, %{ops: ops}))
               |> Repo.insert()

      reloaded = Repo.get!(Version, version.id)
      assert Version.ops(reloaded) == ops
    end

    test "missing required fields fails validation", %{canvas: canvas} do
      changeset =
        Version.changeset(%Version{}, %{canvas_id: canvas.id})

      refute changeset.valid?
      assert changeset.errors[:revision]
      assert changeset.errors[:document]
      assert changeset.errors[:written_by]
    end
  end

  describe "Versions.op_summary/1" do
    test "nil → initial create" do
      assert Versions.op_summary(nil) == "initial create"
    end

    test "single set_props op" do
      assert Versions.op_summary([["set_props", "embed-1", %{"a" => 1, "b" => 2}]]) =~
               "set_props on 'embed-1' (2 keys)"
    end

    test "single replace_children op" do
      assert Versions.op_summary([["replace_children", "root", [%{"id" => "x"}]]]) =~
               "replace_children on 'root' (1 children)"
    end

    test "restore marker" do
      assert Versions.op_summary([["restore_from_revision", 3]]) ==
               "restore from revision 3"
    end

    test "multiple ops shows summary plus +N more" do
      ops = [
        ["set_props", "a", %{}],
        ["delete_node", "b"],
        ["append_child", "root", %{"id" => "c"}]
      ]

      summary = Versions.op_summary(ops)
      assert summary =~ "set_props on 'a' (0 keys)"
      assert summary =~ "+2 more"
    end
  end
end
