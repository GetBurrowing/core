defmodule Platform.Files.BrowserActionsTest do
  use Platform.DataCase, async: false
  import Platform.TenancyFixtures
  alias Platform.{Accounts, Chat, Files, Repo, Tasks, Tenancy}
  alias Platform.Accounts.User
  alias Platform.Chat.{Attachment, Canvas, Participant, Space}
  alias Platform.Chat.Canvas.Server
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Files.{Browser, BrowserActions, Star, Stars}
  alias Platform.Tenancy.OrgMembership

  defp unique, do: System.unique_integer([:positive])

  defp user! do
    n = unique()
    Repo.insert!(%User{email: "stars#{n}@example.test", name: "User #{n}", oidc_sub: "stars#{n}"})
  end

  defp join!(space, user),
    do:
      Repo.insert!(%Participant{
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id,
        role: "member",
        joined_at: DateTime.utc_now(),
        display_name: user.name
      })

  defp space!(org, kind \\ "channel") do
    n = unique()

    Repo.insert!(
      Space.changeset(%Space{}, %{
        name: "Stars #{n}",
        slug: "stars#{n}",
        kind: kind,
        org_id: org.id
      })
    )
  end

  defp member!(user, org),
    do:
      Repo.insert!(
        OrgMembership.changeset(%OrgMembership{}, %{
          user_id: user.id,
          org_id: org.id,
          role: "member"
        })
      )

  setup do
    Application.put_env(:platform, :canvas_persist_sync, true)

    {:ok, org} =
      Tenancy.create_org(root_admin!(), %{name: "Stars #{unique()}", slug: "stars#{unique()}"})

    user = user!()
    other = user!()
    member!(user, org)
    member!(other, org)
    source = space!(org, "group")
    dest = space!(org, "group")
    p = join!(source, user)
    _ = join!(source, other)
    _ = join!(dest, user)

    {:ok, canvas} =
      Chat.create_canvas(%{space_id: source.id, created_by: p.id, title: "Original"})

    on_exit(fn -> Server.stop(canvas.id) end)
    {:ok, project} = Tasks.create_project(%{name: "Stars project #{unique()}", org_id: org.id})

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        name: "Display",
        original_filename: "original.pdf",
        content_type: "application/pdf",
        byte_size: 10,
        storage_key: "stars/#{unique()}",
        content_hash: "hash#{unique()}",
        ingest_intent: "human_only"
      })

    %{
      user: user,
      other: other,
      org: org,
      source: source,
      dest: dest,
      canvas: canvas,
      stored_file: file,
      project: project
    }
  end

  test "stars are persisted, idempotent and private across sessions", c do
    target = {:canvas, c.canvas.id}
    assert :ok = Stars.subscribe(c.user)
    assert :ok = ChatPubSub.subscribe(c.source.id)
    assert :ok = Stars.set(c.user, target, true)
    assert_receive {:stars_changed, ^target}
    refute_receive {:stars_changed, _}, 20
    assert :ok = Stars.set(c.user, target, true)
    assert Repo.aggregate(Star, :count) == 1
    assert [%{id: id}] = Browser.starred(Accounts.get_user(c.user.id)).items
    assert id == c.canvas.id
    assert Browser.starred(c.other).items == []
    assert :ok = Stars.set(c.other, target, true)
    assert Repo.aggregate(Star, :count) == 2
    assert :ok = Stars.set(c.user, target, false)
    assert :ok = Stars.set(c.user, target, false)
    assert Browser.starred(c.user).items == []
    assert [%{id: ^id}] = Browser.starred(c.other).items
  end

  test "newest-starred ordering and hidden targets do not consume the cap", c do
    assert :ok = Stars.set(c.user, {:file, c.stored_file.id}, true)
    assert :ok = Stars.set(c.user, {:canvas, c.canvas.id}, true)
    assert [%{id: first}, %{id: second}] = Browser.starred(c.user).items
    assert first == c.canvas.id
    assert second == c.stored_file.id
    assert {:ok, _} = BrowserActions.execute(c.user, {:canvas, c.canvas.id}, :delete)
    assert %{items: [%{id: ^second}], capped?: false} = Browser.starred(c.user, limit: 1)
  end

  test "delete and Undo preserve target identity and personal stars", c do
    for {kind, row} <- [canvas: c.canvas, file: c.stored_file] do
      target = {kind, row.id}
      assert :ok = Stars.set(c.user, target, true)
      assert {:ok, deleted} = BrowserActions.execute(c.user, target, :delete)
      assert deleted.id == row.id
      assert deleted.deleted_at
      assert Browser.starred(c.user).items == []
      assert {:error, _} = BrowserActions.execute(c.user, target, :rename, %{title: "stale"})
      assert {:ok, restored} = BrowserActions.execute(c.user, target, :undo)
      assert restored.id == row.id
      assert restored.deleted_at == nil
      assert [%{id: id}] = Browser.starred(c.user).items
      assert id == row.id
      assert :ok = Stars.set(c.user, target, false)
    end
  end

  test "forged actors, malformed targets and foreign IDs cannot mutate", c do
    outsider = user!()

    for action <- [:star, :rename, :move, :delete, :undo] do
      assert {:error, _} =
               BrowserActions.execute(outsider, {:canvas, c.canvas.id}, action, %{
                 title: "forged",
                 space_id: c.dest.id
               })

      assert {:error, _} = BrowserActions.execute(c.user, {:canvas, "not-an-id"}, action)
      assert {:error, _} = BrowserActions.execute(nil, {:file, c.stored_file.id}, action)
    end

    assert Repo.get!(Canvas, c.canvas.id).title == "Original"
    assert Repo.get!(Canvas, c.canvas.id).space_id == c.source.id
    assert Repo.aggregate(Star, :count) == 0
  end

  test "stale viewer scope cannot preserve revoked membership or grants", c do
    {:ok, viewer} = BrowserActions.viewer(c.user)
    assert :ok = Stars.set(viewer, {:canvas, c.canvas.id}, true)
    assert {:ok, actions} = BrowserActions.eligible(viewer, {:canvas, c.canvas.id})
    assert :delete in actions

    Repo.delete_all(
      from(p in Participant, where: p.space_id == ^c.source.id and p.participant_id == ^c.user.id)
    )

    assert Browser.starred(viewer).items == []
    assert {:error, _} = BrowserActions.execute(viewer, {:canvas, c.canvas.id}, :delete)
  end

  test "fresh grants override an already-rendered command and saved star", c do
    target = {:canvas, c.canvas.id}
    {:ok, stale_viewer} = BrowserActions.viewer(c.user)
    assert {:ok, actions} = BrowserActions.eligible(stale_viewer, target)
    assert :rename in actions
    assert :ok = Stars.set(c.user, target, true)

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: c.user,
        permission: "canvas.write",
        resource: c.canvas
      })

    assert {:error, _} = BrowserActions.execute(stale_viewer, target, :rename, %{title: "denied"})
    assert {:ok, actions} = BrowserActions.eligible(stale_viewer, target)
    refute :rename in actions
    assert [%{id: id}] = Browser.starred(stale_viewer).items
    assert id == c.canvas.id

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: c.user,
        permission: "canvas.read",
        resource: c.canvas
      })

    assert Browser.starred(stale_viewer).items == []
    assert {:error, _} = Stars.set(stale_viewer, target, true)
    assert Repo.get!(Canvas, c.canvas.id).title == "Original"
  end

  test "file read grants and revoked destination grants are checked at command time", c do
    file_target = {:file, c.stored_file.id}
    assert :ok = Stars.set(c.user, file_target, true)

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: c.user,
        permission: "files.read",
        resource: c.project
      })

    assert Browser.starred(c.user).items == []
    assert {:error, _} = BrowserActions.execute(c.user, file_target, :rename, %{title: "denied"})
    target = {:canvas, c.canvas.id}
    assert {:ok, destinations} = BrowserActions.move_destinations(c.user, target)
    assert c.dest.id in Enum.map(destinations, & &1.id)

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: c.user,
        permission: "canvas.write",
        resource: c.dest
      })

    assert {:error, _} = BrowserActions.execute(c.user, target, :move, %{space_id: c.dest.id})
    assert Repo.get!(Canvas, c.canvas.id).space_id == c.source.id
  end

  test "delayed pre-move update publishes canonical ownership only", c do
    ChatPubSub.subscribe(c.source.id)
    ChatPubSub.subscribe(c.dest.id)

    assert {:ok, _} =
             BrowserActions.execute(c.user, {:canvas, c.canvas.id}, :move, %{space_id: c.dest.id})

    assert_receive {:canvas_deleted, _}
    assert_receive {:canvas_arrived, _}
    Chat.publish_canvas_updated(c.canvas)
    assert_receive {:canvas_updated, %{space_id: destination}}
    assert destination == c.dest.id
    old_space_id = c.source.id
    refute_receive {:canvas_updated, %{space_id: ^old_space_id}}, 20
  end

  test "rename only changes display metadata", c do
    assert {:ok, file} =
             BrowserActions.execute(c.user, {:file, c.stored_file.id}, :rename, %{
               title: "New name",
               storage_key: "forged"
             })

    assert file.name == "New name"
    assert file.original_filename == "original.pdf"
    assert file.storage_key == c.stored_file.storage_key

    assert {:ok, canvas} =
             BrowserActions.execute(c.user, {:canvas, c.canvas.id}, :rename, %{
               title: "New title",
               document: %{}
             })

    assert canvas.title == "New title"
    assert canvas.document == c.canvas.document

    assert {:error, :invalid_title} =
             BrowserActions.execute(c.user, {:canvas, c.canvas.id}, :rename, %{title: " "})

    assert {:ok, actions} = BrowserActions.eligible(c.user, {:file, c.stored_file.id})
    refute :move in actions

    assert {:error, :unsupported} =
             BrowserActions.execute(c.user, {:file, c.stored_file.id}, :move, %{
               space_id: c.dest.id
             })
  end

  test "space attachments support stars without ownership mutation", c do
    attachment =
      Repo.insert!(
        Attachment.changeset(%Attachment{}, %{
          space_id: c.source.id,
          filename: "shared.pdf",
          content_type: "application/pdf",
          byte_size: 1,
          storage_key: "starsatt#{unique()}"
        })
      )

    target = {:space_file, attachment.id}
    assert {:ok, [:star]} = BrowserActions.eligible(c.user, target)
    assert :ok = Stars.set(c.user, target, true)
    assert [%{id: id, kind: :space_file}] = Browser.starred(c.user).items
    assert id == attachment.id

    for action <- [:rename, :move, :delete] do
      assert {:error, :unsupported} = BrowserActions.execute(c.user, target, action)
    end

    assert Repo.get!(Attachment, attachment.id).space_id == c.source.id
  end

  test "archived spaces and projects hide stars and reject commands", c do
    assert :ok = Stars.set(c.user, {:canvas, c.canvas.id}, true)
    assert :ok = Stars.set(c.user, {:file, c.stored_file.id}, true)
    Repo.update!(Ecto.Changeset.change(c.source, archived_at: DateTime.utc_now()))
    Repo.update!(Ecto.Changeset.change(c.project, archived_at: DateTime.utc_now()))
    assert Browser.starred(c.user).items == []
    assert {:error, _} = BrowserActions.execute(c.user, {:canvas, c.canvas.id}, :delete)
    assert {:error, _} = BrowserActions.execute(c.user, {:file, c.stored_file.id}, :delete)
  end

  test "move requires source and destination authorization including cross-org denial", c do
    target = {:canvas, c.canvas.id}
    assert {:error, _} = BrowserActions.execute(c.other, target, :move, %{space_id: c.dest.id})

    {:ok, org2} =
      Tenancy.create_org(root_admin!(), %{name: "Other #{unique()}", slug: "other#{unique()}"})

    member!(c.user, org2)
    foreign = space!(org2)
    join!(foreign, c.user)
    assert {:error, _} = BrowserActions.execute(c.user, target, :move, %{space_id: foreign.id})
    assert {:error, _} = BrowserActions.execute(c.user, target, :move, %{space_id: "forged"})
    assert Repo.get!(Canvas, c.canvas.id).space_id == c.source.id
    assert {:ok, moved} = BrowserActions.execute(c.user, target, :move, %{space_id: c.dest.id})
    assert moved.id == c.canvas.id
    assert moved.space_id == c.dest.id
    assert {:error, _} = BrowserActions.execute(c.other, target, :delete)

    assert {:ok, %{space_id: space_id}} =
             Server.describe(c.canvas.id)
             |> then(fn {:ok, _} -> {:ok, :sys.get_state(Server.whereis(c.canvas.id))} end)

    assert space_id == c.dest.id
  end

  test "move retires old subscriptions even when moved back; new subscriber sees updates", c do
    target = {:canvas, c.canvas.id}
    old_topic = ChatPubSub.canvas_topic(c.canvas.id)
    :ok = ChatPubSub.subscribe_canvas(c.canvas.id)
    assert {:ok, moved} = BrowserActions.execute(c.user, target, :move, %{space_id: c.dest.id})
    assert_receive {:canvas_deleted, %{id: id, space_id: old_space}}
    assert id == c.canvas.id
    assert old_space == c.source.id
    refute ChatPubSub.canvas_topic(c.canvas.id) == old_topic
    ChatPubSub.broadcast_canvas(moved.id, {:new_location, moved.id})
    refute_receive {:new_location, _}, 20
    assert {:ok, _} = BrowserActions.execute(c.user, target, :move, %{space_id: c.source.id})
    refute ChatPubSub.canvas_topic(c.canvas.id) == old_topic
    :ok = ChatPubSub.subscribe_canvas(c.canvas.id)
    ChatPubSub.broadcast_canvas(c.canvas.id, {:new_location, c.canvas.id})
    assert_receive {:new_location, ^id}
    :ok = ChatPubSub.unsubscribe_canvas(c.canvas.id)
    assert Registry.lookup(Platform.PubSub, old_topic) == []
  end

  test "a stale attributed patch cannot write after move", c do
    assert {:ok, _} = Server.start_server(c.canvas.id)

    assert {:ok, _} =
             BrowserActions.execute(c.user, {:canvas, c.canvas.id}, :move, %{space_id: c.dest.id})

    attribution = %{"type" => "user", "id" => c.other.id}
    assert {:error, :forbidden} = Server.apply_patches(c.canvas.id, [], 1, attribution)

    assert {:ok, _} =
             Server.apply_patches(c.canvas.id, [], 1, %{"type" => "user", "id" => c.user.id})
  end

  test "personal-star invalidation reaches only the starring user's sessions", c do
    parent = self()
    other = c.other

    pid =
      spawn(fn ->
        :ok = Stars.subscribe(other)
        send(parent, :other_subscribed)

        receive do
          event -> send(parent, {:other_session, event})
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive :other_subscribed
    target = {:canvas, c.canvas.id}
    assert :ok = Stars.set(c.user, target, true)
    refute_receive {:other_session, _}, 30
    assert :ok = Stars.set(c.other, target, true)
    assert_receive {:other_session, {:stars_changed, ^target}}
  end

  test "move preserves history and stars and moves only canvas-owned uploads", c do
    target = {:canvas, c.canvas.id}
    assert :ok = Stars.set(c.user, target, true)
    assert :ok = Stars.set(c.other, target, true)
    author = Chat.get_participant(c.canvas.created_by)

    {:ok, msg} =
      Chat.post_message(%{
        space_id: c.source.id,
        participant_id: author.id,
        content_type: "text",
        content: "shared upload"
      })

    owned =
      Repo.insert!(
        Attachment.changeset(%Attachment{}, %{
          space_id: c.source.id,
          canvas_id: c.canvas.id,
          filename: "owned.png",
          content_type: "image/png",
          byte_size: 1,
          storage_key: "owned#{unique()}"
        })
      )

    shared =
      Repo.insert!(
        Attachment.changeset(%Attachment{}, %{
          space_id: c.source.id,
          canvas_id: c.canvas.id,
          message_id: msg.id,
          filename: "shared.png",
          content_type: "image/png",
          byte_size: 1,
          storage_key: "shared#{unique()}"
        })
      )

    versions = Chat.Canvas.Versions.list_for_canvas(c.canvas.id)
    assert length(versions) > 0
    assert {:ok, moved} = BrowserActions.execute(c.user, target, :move, %{space_id: c.dest.id})
    assert moved.document == c.canvas.document
    assert Chat.Canvas.Versions.list_for_canvas(c.canvas.id) == versions
    assert Repo.get!(Attachment, owned.id).space_id == c.dest.id
    assert Repo.get!(Attachment, shared.id).space_id == c.source.id
    assert Chat.get_visible_attachment_for_principal(owned.id, {:user, c.other.id}) == nil
    assert Chat.get_visible_attachment_for_principal(owned.id, {:user, c.user.id})
    assert length(Browser.starred(c.user).items) == 1
    assert Browser.starred(c.other).items == []
    assert Repo.aggregate(Star, :count) == 2
  end

  test "destination arrival carries no document and rechecks each receiver's fresh scope", c do
    join!(c.dest, c.other)
    ChatPubSub.subscribe(c.dest.id)

    assert {:ok, _} =
             BrowserActions.execute(c.user, {:canvas, c.canvas.id}, :move, %{space_id: c.dest.id})

    assert_receive {:canvas_arrived, payload}
    assert Enum.sort(Map.keys(payload)) == [:id, :space_id]
    assert {:ok, %{id: id}} = Platform.Files.CanvasMove.fetch_arrival(c.other, payload)
    assert id == c.canvas.id
    {:ok, stale} = BrowserActions.viewer(c.other)

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: c.other,
        permission: "canvas.read",
        resource: c.canvas
      })

    assert {:error, :not_found} = Platform.Files.CanvasMove.fetch_arrival(stale, payload)

    assert {:error, :not_found} =
             Platform.Files.CanvasMove.fetch_arrival(c.user, %{payload | space_id: c.source.id})
  end

  test "database refuses multiple targets for one star", c do
    changeset =
      Star.changeset(%Star{}, %{
        user_id: c.user.id,
        canvas_id: c.canvas.id,
        file_id: c.stored_file.id
      })

    assert {:error, invalid} = Repo.insert(changeset)
    assert Keyword.has_key?(invalid.errors, :canvas_id)
    assert Repo.aggregate(Star, :count) == 0
  end

  test "target and user foreign-key cleanup and single-target DB constraint", c do
    assert :ok = Stars.set(c.user, {:canvas, c.canvas.id}, true)
    Repo.delete!(c.canvas)
    assert Repo.aggregate(Star, :count) == 0
    assert :ok = Stars.set(c.user, {:file, c.stored_file.id}, true)
    Repo.delete!(c.user)
    assert Repo.aggregate(Star, :count) == 0
    changeset = Star.changeset(%Star{}, %{user_id: c.other.id})
    assert {:error, invalid} = Repo.insert(changeset)
    assert Keyword.has_key?(invalid.errors, :canvas_id)
  end
end
