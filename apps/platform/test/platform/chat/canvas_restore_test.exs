defmodule Platform.Chat.CanvasRestoreTest do
  use Platform.DataCase, async: false
  import Platform.ExternalUserFixtures
  alias Platform.{Chat, Repo}
  alias Platform.Chat.Canvas.{Restore, Server, Versions, Version}

  setup do
    org = Platform.Tenancy.get_org_by_slug!("globex")
    user = create_user!()
    plain_member!(user, org)
    space = channel!(%{org_id: org.id})
    p = add_user!(space.id, user.id)

    {:ok, canvas, _} =
      Chat.create_canvas_with_message(space.id, p.id, %{
        title: "Restore contract",
        document: document("Source")
      })

    {:ok, 2} =
      Server.apply_patches(canvas.id, [{:set_props, "body", %{"value" => "Previous head"}}], 1)

    on_exit(fn -> Server.stop(canvas.id) end)
    %{user: user, space: space, p: p, canvas: canvas}
  end

  defp document(text),
    do: %{
      "version" => 1,
      "revision" => 1,
      "root" => %{"id" => "body", "type" => "text", "props" => %{"value" => text}}
    }

  test "restore commits a new head, source attribution and both old documents", c do
    Chat.PubSub.subscribe_canvas(c.canvas.id)
    assert {:ok, 3} = Restore.restore(c.user, c.canvas.id, 1, 2)
    assert_receive {:canvas_patched, _, 3, _}
    assert Chat.get_canvas(c.canvas.id).document["root"]["props"]["value"] == "Source"
    assert Versions.get(c.canvas.id, 2).document["root"]["props"]["value"] == "Previous head"
    assert Versions.get(c.canvas.id, 1).document["root"]["props"]["value"] == "Source"
    restored = Versions.get(c.canvas.id, 3)
    assert Version.ops(restored) == [["restore_from_revision", 1]]
    assert restored.written_by["participant_id"] == c.user.id
    assert {:ok, %{revision: 3}} = Server.describe(c.canvas.id)
    assert Enum.map(Versions.list_for_canvas(c.canvas.id), & &1.revision) == [3, 2, 1]
    assert {:conflict, %{current_revision: 3}} = Restore.restore(c.user, c.canvas.id, 1, 2)
    refute Versions.get(c.canvas.id, 4)
  end

  test "stale confirmation, missing source and forged id leave the head and history unchanged",
       c do
    assert {:ok, 3} =
             Server.apply_patches(
               c.canvas.id,
               [{:set_props, "body", %{"value" => "Concurrent work"}}],
               2
             )

    assert {:conflict, %{current_revision: 3}} = Restore.restore(c.user, c.canvas.id, 1, 2)
    assert {:error, :revision_not_found} = Restore.restore(c.user, c.canvas.id, 99, 3)
    assert {:error, :not_found} = Restore.restore(c.user, "malformed", 1, 3)
    assert {:ok, %{revision: 3, document: doc}} = Server.describe(c.canvas.id)
    assert doc["root"]["props"]["value"] == "Concurrent work"
    refute Versions.get(c.canvas.id, 4)
  end

  test "read grant is insufficient; revocation and archive are checked again", c do
    reader = create_user!()
    plain_member!(reader, Platform.Tenancy.get_org_by_slug!("globex"))
    assert {:error, :forbidden} = Restore.restore(reader, c.canvas.id, 1, 2)
    Repo.delete!(c.p)
    assert {:error, :forbidden} = Restore.restore(c.user, c.canvas.id, 1, 2)
    add_user!(c.space.id, c.user.id)

    c.space
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, :space_archived} = Restore.restore(c.user, c.canvas.id, 1, 2)
    assert {:ok, %{revision: 2}} = Server.describe(c.canvas.id)
    refute Versions.get(c.canvas.id, 3)
  end

  test "an explicit write deny is reloaded at confirmation time", c do
    assert {:ok, _, _} = Restore.authorize(c.user, c.canvas.id)

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: c.user,
        permission: "canvas.write",
        resource: c.canvas
      })

    assert {:error, _} = Restore.restore(c.user, c.canvas.id, 1, 2)
    assert {:ok, %{revision: 2}} = Server.describe(c.canvas.id)
    refute Versions.get(c.canvas.id, 3)
  end

  test "pending write-through cannot overwrite the completed restore", c do
    test_pid = self()
    canvas_id = c.canvas.id
    # A supervised pending writer deliberately withholds its final old-head
    # write. Releasing it after a restore without the barrier would regress
    # the canonical row while the server claims revision 3.
    pending =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :release ->
               canvas = Chat.get_canvas(canvas_id)

               canvas
               |> Ecto.Changeset.change(document: document("Delayed old head"))
               |> Repo.update!()

               send(test_pid, :old_write_done)
           end
         end}
      )

    :sys.replace_state(Server.whereis(canvas_id), fn state ->
      # The monitor belongs to the server, exactly as persist_async creates it.
      %{state | pending_writes: %{Process.monitor(pending) => pending}}
    end)

    start_supervised!(
      {Task,
       fn ->
         send(test_pid, :restore_started)
         send(test_pid, {:restore_result, Restore.restore(c.user, canvas_id, 1, 2)})
       end},
      id: :restore_caller
    )

    assert_receive :restore_started
    refute_receive {:restore_result, _}
    send(pending, :release)
    assert_receive :old_write_done
    assert_receive {:restore_result, {:ok, 3}}, 2000
    assert Chat.get_canvas(canvas_id).document["root"]["props"]["value"] == "Source"
    assert {:ok, %{revision: 3}} = Server.describe(canvas_id)
  end

  test "canonical current is retained even when no stored snapshot exists for its revision", c do
    import Ecto.Query
    Repo.delete_all(from(v in Version, where: v.canvas_id == ^c.canvas.id and v.revision == 2))
    assert {:ok, 3} = Restore.restore(c.user, c.canvas.id, 1, 2)
    assert Versions.get(c.canvas.id, 2).document["root"]["props"]["value"] == "Previous head"
  end

  test "failed version insert rolls back head and current snapshot together", c do
    %Version{}
    |> Version.changeset(%{
      canvas_id: c.canvas.id,
      revision: 3,
      document: document("Sentinel"),
      written_by: %{"type" => "system"},
      written_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:error, %Ecto.Changeset{}} = Restore.restore(c.user, c.canvas.id, 1, 2)
    assert {:ok, %{revision: 2}} = Server.describe(c.canvas.id)
    assert Chat.get_canvas(c.canvas.id).document["root"]["props"]["value"] == "Previous head"
    assert Versions.get(c.canvas.id, 3).document["root"]["props"]["value"] == "Sentinel"
  end
end
