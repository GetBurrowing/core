defmodule Platform.Chat.CanvasSearchIndexTest do
  @moduledoc """
  Task `01a07402` stage 2: **every** writer of `chat_canvases.document` leaves
  a matching `chat_canvas_search` row behind, in the same transaction.

  There is one test per writer on purpose. A single "indexing works" test
  passes while three of the four paths write nothing, and a canvas that is
  saved but not indexed is invisible to search while looking entirely healthy
  everywhere else — there is no error, no log line and no user-visible symptom
  to notice. The per-writer split plus `writer coverage` below is what turns
  "somebody added a fifth writer and forgot" into a red test.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.VersionHandlers
  alias Platform.Chat.CanvasSearchIndex
  alias Platform.Repo

  setup do
    # `config/test.exs` already sets this, but the canvas server's persist path
    # is only synchronous while it holds — pin it here so this file does not
    # start racing a `Task.Supervisor` child if that config ever moves.
    Application.put_env(:platform, :canvas_persist_sync, true)
    on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, true) end)

    {:ok, space} =
      Chat.create_space(%{
        name: "CSI #{System.unique_integer([:positive])}",
        slug: "csi-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    agent_participant_id = Ecto.UUID.generate()

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent_participant_id,
        display_name: "Index Author",
        joined_at: DateTime.utc_now()
      })

    %{space: space, participant: participant, agent_id: agent_participant_id}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp index_row(canvas_id), do: Repo.get(CanvasSearchIndex, canvas_id)

  defp indexed_body(canvas_id) do
    case index_row(canvas_id) do
      nil -> nil
      row -> row.body_text
    end
  end

  # A minimal valid canonical document carrying exactly one distinctive phrase.
  defp text_doc(phrase) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{"id" => "t1", "type" => "text", "props" => %{"value" => phrase}, "children" => []}
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  # ── one test per writer of chat_canvases.document ────────────────────────

  describe "writer: Chat.do_create_canvas/1" do
    test "create_canvas/1 indexes the body it inserted", %{space: s, participant: p} do
      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => s.id,
          "created_by" => p.id,
          "title" => "Created",
          "document" => text_doc("zorbling quimbat")
        })

      assert indexed_body(canvas.id) =~ "zorbling quimbat"
    end

    test "clone_canvas/3 indexes the clone, because it routes through create_canvas/1",
         %{space: s, participant: p} do
      {:ok, source} =
        Chat.create_canvas(%{
          "space_id" => s.id,
          "created_by" => p.id,
          "title" => "Source",
          "document" => text_doc("frimsy toadlark")
        })

      {:ok, clone} = Chat.clone_canvas(source.id, s.id, p.id)

      refute clone.id == source.id
      assert indexed_body(clone.id) =~ "frimsy toadlark"
    end
  end

  describe "writer: Chat.do_create_canvas_with_message/3" do
    test "create_canvas_with_message/3 indexes the body it inserted",
         %{space: s, participant: p} do
      {:ok, canvas, _message} =
        Chat.create_canvas_with_message(s.id, p.id, %{
          "title" => "WithMessage",
          "document" => text_doc("wumberton glissade")
        })

      assert indexed_body(canvas.id) =~ "wumberton glissade"
    end
  end

  describe "writer: Chat.do_update_canvas/2" do
    test "update_canvas/3 replaces the indexed body", %{space: s, participant: p} do
      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => s.id,
          "created_by" => p.id,
          "title" => "Updatable",
          "document" => text_doc("plinthwark obelating")
        })

      assert indexed_body(canvas.id) =~ "plinthwark obelating"

      assert {:ok, _updated} =
               Chat.update_canvas(:system, canvas, %{
                 "document" => text_doc("grendlewick sopor")
               })

      body = indexed_body(canvas.id)

      # Both directions. Asserting only the new phrase passes against an
      # append-only bug, which is exactly the way an upsert goes wrong.
      assert body =~ "grendlewick sopor"
      refute body =~ "plinthwark obelating"
    end
  end

  describe "writer: Canvas.Server.do_persist/5 (the hot path)" do
    test "a patch replaces the indexed body: old phrase GONE, new phrase PRESENT",
         %{space: s, participant: p} do
      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(s.id, p.id, %{
          "title" => "Patchable",
          "document" => text_doc("quandolent shrike")
        })

      on_exit(fn -> CanvasServer.stop(canvas.id) end)

      assert indexed_body(canvas.id) =~ "quandolent shrike"

      {:ok, %{revision: revision}} = CanvasServer.describe(canvas.id)

      assert {:ok, _new_revision} =
               CanvasServer.apply_patches(
                 canvas.id,
                 [{:set_props, "t1", %{"value" => "murrelet flanging"}}],
                 revision
               )

      body = indexed_body(canvas.id)

      assert body =~ "murrelet flanging"
      refute body =~ "quandolent shrike"
    end

    test "a version restore re-indexes to the restored document",
         %{space: s, participant: p, agent_id: agent_id} do
      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(s.id, p.id, %{
          "title" => "Restorable",
          "document" => text_doc("halcyon prattlebrook")
        })

      on_exit(fn -> CanvasServer.stop(canvas.id) end)

      {:ok, %{revision: revision}} = CanvasServer.describe(canvas.id)

      assert {:ok, _} =
               CanvasServer.apply_patches(
                 canvas.id,
                 [{:set_props, "t1", %{"value" => "vespertine kithara"}}],
                 revision
               )

      assert indexed_body(canvas.id) =~ "vespertine kithara"

      assert {:ok, %{restored_from: ^revision}} =
               VersionHandlers.restore(
                 %{"canvas_id" => canvas.id, "revision" => revision},
                 %{agent_id: agent_id}
               )

      body = indexed_body(canvas.id)

      assert body =~ "halcyon prattlebrook"
      refute body =~ "vespertine kithara"
    end
  end

  # ── the table's own behaviour ────────────────────────────────────────────

  describe "chat_canvas_search row lifecycle" do
    test "body_search_vector is generated by Postgres and is non-empty for a non-empty body",
         %{space: s, participant: p} do
      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => s.id,
          "created_by" => p.id,
          "title" => "Vectorised",
          "document" => text_doc("brindlewash cantivore")
        })

      row = index_row(canvas.id)

      refute row.body_text == ""
      assert is_list(row.body_search_vector)
      refute row.body_search_vector == []

      # It is really a searchable vector, not just a non-empty blob: match it
      # the way a search query would.
      assert %{rows: [[true]]} =
               Repo.query!(
                 """
                 SELECT body_search_vector @@ to_tsquery('english', 'brindlewash')
                 FROM chat_canvas_search WHERE canvas_id = $1
                 """,
                 [Ecto.UUID.dump!(canvas.id)]
               )
    end

    test "weight D makes a title match outrank a body match with no hand-rolled scoring",
         %{space: s, participant: p} do
      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => s.id,
          "created_by" => p.id,
          "title" => "Ranked",
          "document" => text_doc("brindlewash cantivore")
        })

      # `D` is Postgres's DEFAULT weight, so it is not rendered as a suffix and
      # a decoded `Postgrex.Lexeme` carries `nil` rather than `:D`. Asserting
      # on the struct would therefore prove nothing either way. Assert the
      # property the weight was chosen FOR instead: `ts_rank_cd`'s default
      # weights (B=0.4, D=0.1) rank a title hit above a body hit on their own.
      assert %{rows: [[body_rank, title_rank]]} =
               Repo.query!(
                 """
                 SELECT
                   ts_rank_cd(body_search_vector, to_tsquery('english', 'brindlewash')),
                   ts_rank_cd(
                     setweight(to_tsvector('english', 'brindlewash'), 'B'),
                     to_tsquery('english', 'brindlewash')
                   )
                 FROM chat_canvas_search WHERE canvas_id = $1
                 """,
                 [Ecto.UUID.dump!(canvas.id)]
               )

      assert body_rank > 0.0, "the body vector does not match its own text"
      assert body_rank < title_rank
    end

    test "hard-deleting the canvas row removes the index row via the FK cascade",
         %{space: s, participant: p} do
      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => s.id,
          "created_by" => p.id,
          "title" => "Doomed",
          "document" => text_doc("skerrick vandolin")
        })

      assert index_row(canvas.id)

      # A HARD delete — `Chat.delete_canvas/1` is a soft delete and must NOT
      # drop the index row, since a restore has to find it still there.
      Repo.delete!(%Canvas{id: canvas.id})

      refute index_row(canvas.id)
    end

    test "soft-deleting the canvas KEEPS the index row", %{space: s, participant: p} do
      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => s.id,
          "created_by" => p.id,
          "title" => "Hidden",
          "document" => text_doc("porringer cantlewisp")
        })

      assert {:ok, _} = Chat.delete_canvas(canvas)

      assert indexed_body(canvas.id) =~ "porringer cantlewisp"
    end
  end

  # ── the guard against a fifth, unwired writer ────────────────────────────

  describe "writer coverage" do
    test "every lib/ file that builds a Canvas.changeset also wires the search index" do
      lib_root = Path.expand("../../../lib/platform", __DIR__)

      files =
        [lib_root, "**", "*.ex"]
        |> Path.join()
        |> Path.wildcard()

      # Reachability: the sweep must actually have read the tree.
      assert length(files) > 100

      writers =
        for path <- files,
            source = File.read!(path),
            String.contains?(source, "Canvas.changeset("),
            do: {Path.relative_to(path, lib_root), source}

      # Three canonical writers: ordinary context writes, server patches,
      # and the actor-authorized restore transaction (task 01a1557a). The
      # restore also calls CanvasSearchIndex.upsert_multi in that transaction.
      assert MapSet.new(writers, &elem(&1, 0)) ==
               MapSet.new(["chat.ex", "chat/canvas/server.ex", "chat/canvas/restore.ex"])

      unwired =
        for {relative, source} <- writers,
            not String.contains?(source, "CanvasSearchIndex"),
            do: relative

      assert unwired == [],
             "these files write chat_canvases.document but never touch " <>
               "CanvasSearchIndex, so their canvases are saved unindexed: " <>
               inspect(unwired)
    end
  end
end
