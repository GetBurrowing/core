defmodule Platform.Secretary.StoreTest do
  @moduledoc """
  Every public read in `Platform.Secretary.Store` and
  `Platform.Secretary.Todos` is the viewer's own (task 01a1b721 stage 1),
  and the person's list deduplicates, refuses rooms they are not in, and
  records `not_a_todo` on a dismissal.
  """
  use Platform.DataCase, async: true

  import Platform.ExternalUserFixtures

  alias Platform.Repo
  alias Platform.Secretary.{Feedback, Store, Todo, Todos}

  defp errors_on(changeset),
    do: Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

  setup do
    a = create_user!()
    b = create_user!()
    room = channel!()
    add_user!(room.id, a.id)
    open = channel!()

    {:ok, batch} =
      Store.create_batch(a.id, %{
        item_refs: [%{"ref_type" => "chat_message", "ref_id" => Ecto.UUID.generate()}],
        reserved_tokens: 100
      })

    ref_id = Ecto.UUID.generate()

    {:ok, evaluation} =
      Store.upsert_evaluation(a.id, %{
        ref_type: "chat_message",
        ref_id: ref_id,
        tag: "decide",
        reason: "they asked you",
        model_version: "fallback",
        batch_id: batch.id
      })

    {:ok, feedback} =
      Store.record_feedback(a.id, %{
        ref_type: "chat_message",
        ref_id: ref_id,
        kind_key: "chat:channel",
        action: "hide_kind"
      })

    {:ok, reachout} = Store.record_reachout(a.id, evaluation.id, "sent")
    {:ok, own} = Todos.add_own(a.id, "Call the printer")

    {:ok, heard} =
      Todos.suggest(a.id, %{
        title: "Send the menu draft",
        source_space_id: room.id,
        source_ref_type: "chat_message",
        source_ref_id: ref_id
      })

    %{
      a: a,
      b: b,
      room: room,
      open: open,
      batch: batch,
      evaluation: evaluation,
      feedback: feedback,
      reachout: reachout,
      own: own,
      heard: heard,
      ref_id: ref_id
    }
  end

  describe "cross-user: B's id returns none of A's rows" do
    test "positive control: A's id reads A's rows", c do
      assert [%{id: id}] = Store.list_batches(c.a.id)
      assert id == c.batch.id
      assert Store.get_batch(c.a.id, c.batch.id)
      assert [_] = Store.list_evaluations(c.a.id)
      assert Store.get_evaluation(c.a.id, "chat_message", c.ref_id)
      assert [_] = Store.list_feedback(c.a.id)
      assert Store.hidden_kind?(c.a.id, "chat:channel")
      assert [_] = Store.list_reachouts(c.a.id)
      assert length(Todos.list(c.a.id)) == 2
      assert Todos.get(c.a.id, c.own.id)
    end

    test "every public read with B's id", c do
      assert Store.list_batches(c.b.id) == []
      assert Store.get_batch(c.b.id, c.batch.id) == nil
      assert Store.list_evaluations(c.b.id) == []
      assert Store.get_evaluation(c.b.id, "chat_message", c.ref_id) == nil
      assert Store.list_feedback(c.b.id) == []
      refute Store.hidden_kind?(c.b.id, "chat:channel")
      assert Store.list_reachouts(c.b.id) == []
      assert Store.list_reachouts(c.b.id, evaluation_id: c.evaluation.id) == []
      assert Todos.list(c.b.id) == []
      assert Todos.list(c.b.id, statuses: Todo.statuses()) == []
      assert Todos.get(c.b.id, c.own.id) == nil
    end

    test "every write keyed on another person's row is not_found", c do
      assert {:error, :not_found} = Store.finish_batch(c.b.id, c.batch.id, %{status: "submitted"})
      assert {:error, :not_found} = Store.record_reachout(c.b.id, c.evaluation.id, "released")
      assert {:error, :not_found} = Todos.keep(c.b.id, c.heard.id)
      assert {:error, :not_found} = Todos.edit(c.b.id, c.own.id, %{title: "x"})
      assert {:error, :not_found} = Todos.dismiss(c.b.id, c.own.id)
      assert {:error, :not_found} = Todos.mark_done(c.b.id, c.own.id, "done")
      assert {:error, :not_found} = Todos.undo(c.b.id, c.own.id)
    end

    test "malformed ids read as missing", c do
      assert Store.get_batch("nope", c.batch.id) == nil
      assert Store.list_evaluations("nope") == []
      assert Todos.get(c.a.id, "nope") == nil
    end
  end

  describe "evaluations" do
    test "a re-evaluation replaces the row and keeps the old tag", c do
      {:ok, again} =
        Store.upsert_evaluation(c.a.id, %{
          ref_type: "chat_message",
          ref_id: c.ref_id,
          tag: "fyi",
          model_version: "host:agent-1:claude_code"
        })

      assert again.id == c.evaluation.id
      assert again.previous_tag == "decide"
      assert [_] = Store.list_evaluations(c.a.id)
    end

    test "a reason over 200 chars and a bad model_version are refused", c do
      assert {:error, cs} =
               Store.upsert_evaluation(c.a.id, %{
                 ref_type: "task",
                 ref_id: Ecto.UUID.generate(),
                 tag: "fyi",
                 reason: String.duplicate("x", 201),
                 model_version: "gpt"
               })

      assert %{reason: [_], model_version: [_]} = errors_on(cs)
    end

    test "a reach-out of the same kind lands once", c do
      assert {:ok, :duplicate} = Store.record_reachout(c.a.id, c.evaluation.id, "sent")
      assert [_] = Store.list_reachouts(c.a.id)
    end
  end

  describe "my list" do
    test "a heard suggestion deduplicates on title and source", c do
      assert {:ok, again} =
               Todos.suggest(c.a.id, %{
                 title: "  send the MENU draft! ",
                 source_space_id: c.room.id,
                 source_ref_type: "chat_message",
                 source_ref_id: c.ref_id
               })

      assert again.id == c.heard.id

      assert Repo.aggregate(
               from(t in Todo, where: t.user_id == ^c.a.id and t.origin == "heard"),
               :count
             ) ==
               1
    end

    test "a suggestion from a readable channel the person is not in is refused", c do
      assert {:error, :not_a_participant} =
               Todos.suggest(c.a.id, %{title: "Something heard", source_space_id: c.open.id})

      assert {:error, :not_a_participant} = Todos.suggest(c.a.id, %{title: "No room"})
    end

    test "dismiss writes not_a_todo feedback; undo restores and records undo", c do
      assert {:ok, %Todo{status: "dismissed"}} = Todos.dismiss(c.a.id, c.heard.id)

      assert [%Feedback{action: "not_a_todo", ref_type: "todo", ref_id: ref}] =
               Store.list_feedback(c.a.id, action: "not_a_todo")

      assert ref == c.heard.id

      assert {:ok, %Todo{status: "suggested"}} = Todos.undo(c.a.id, c.heard.id)
      assert [_] = Store.list_feedback(c.a.id, action: "undo")
    end

    test "keep, edit, mark_done", c do
      assert {:ok, %Todo{status: "kept"}} = Todos.keep(c.a.id, c.heard.id)

      assert {:ok, %Todo{title: "New title"}} =
               Todos.edit(c.a.id, c.own.id, %{"title" => "New title", "status" => "done"})

      assert %Todo{status: "kept"} = Todos.get(c.a.id, c.own.id)

      assert {:ok, %Todo{status: "done", done_reason: "sent it"}} =
               Todos.mark_done(c.a.id, c.own.id, "sent it")

      refute Enum.any?(Todos.list(c.a.id), &(&1.id == c.own.id))
    end
  end
end
