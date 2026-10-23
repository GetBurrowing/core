defmodule Platform.Chat.PostMessageWithExistingAttachmentsTest do
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures, only: [create_user!: 0, add_user!: 2]

  alias Platform.Access.Grants
  alias Platform.Chat
  alias Platform.Chat.{Attachment, Message}
  alias Platform.Repo

  defp setup_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Existing Attachments",
        slug: "existing-att-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Poster",
        joined_at: DateTime.utc_now()
      })

    %{space: space, participant: participant}
  end

  defp attachment!(space_id, extra \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, attachment} =
      Chat.create_attachment(
        Map.merge(
          %{
            space_id: space_id,
            filename: "clip-#{n}.mp4",
            content_type: "video/mp4",
            byte_size: 1024,
            storage_key: "test/clip-#{n}.mp4",
            content_hash: "hash-#{n}",
            state: "ready"
          },
          extra
        )
      )

    attachment
  end

  defp attrs(space, participant, content \\ "here is the clip") do
    %{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: content
    }
  end

  defp message_count, do: Repo.aggregate(Message, :count)

  test "(a) links a ready unlinked row in the space" do
    %{space: space, participant: participant} = setup_space()
    row = attachment!(space.id)

    assert {:ok, message, [linked]} =
             Chat.post_message_with_existing_attachments(attrs(space, participant), [row.id])

    assert linked.id == row.id
    assert Enum.map(Chat.list_attachments(message.id), & &1.id) == [row.id]
    assert message.metadata["attachments_linked_by_id"] == true
  end

  test "(b) a row already on another message gets a new reference row" do
    %{space: space, participant: participant} = setup_space()
    row = attachment!(space.id)

    {:ok, first, _} =
      Chat.post_message_with_existing_attachments(attrs(space, participant, "first"), [row.id])

    assert {:ok, second, [copy]} =
             Chat.post_message_with_existing_attachments(attrs(space, participant, "second"), [
               row.id
             ])

    refute copy.id == row.id
    assert copy.storage_key == row.storage_key
    assert copy.content_hash == row.content_hash
    assert copy.message_id == second.id
    assert Enum.map(Chat.list_attachments(first.id), & &1.id) == [row.id]
    assert Enum.map(Chat.list_attachments(second.id), & &1.id) == [copy.id]
  end

  test "(b') a canvas-bound row keeps its own row; duplicates collapse to one" do
    %{space: space, participant: participant} = setup_space()

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Doc"
      })

    row = attachment!(space.id, %{canvas_id: canvas.id})

    assert {:ok, message, [copy]} =
             Chat.post_message_with_existing_attachments(attrs(space, participant), [
               row.id,
               row.id
             ])

    refute copy.id == row.id
    assert Repo.get!(Attachment, row.id).canvas_id == canvas.id
    assert is_nil(Repo.get!(Attachment, row.id).message_id)
    assert length(Chat.list_attachments(message.id)) == 1
  end

  test "(c) a row from another space is not_found and nothing is posted" do
    %{space: space, participant: participant} = setup_space()
    %{space: other} = setup_space()
    row = attachment!(other.id)
    before = message_count()

    assert {:error, {:attachment_not_found, id}} =
             Chat.post_message_with_existing_attachments(attrs(space, participant), [row.id])

    assert id == row.id
    assert message_count() == before
    assert is_nil(Repo.get!(Attachment, row.id).message_id)
  end

  test "(d) a pending row in the space is not_ready and nothing is posted" do
    %{space: space, participant: participant} = setup_space()

    row =
      attachment!(space.id, %{
        state: "pending",
        upload_expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
      })

    before = message_count()

    assert {:error, {:attachment_not_ready, id}} =
             Chat.post_message_with_existing_attachments(attrs(space, participant), [row.id])

    assert id == row.id
    assert message_count() == before
  end

  test "(e) one good id plus one bad id posts nothing and leaves the good row unlinked" do
    %{space: space, participant: participant} = setup_space()
    good = attachment!(space.id)
    bad = Ecto.UUID.generate()
    before = message_count()

    assert {:error, {:attachment_not_found, ^bad}} =
             Chat.post_message_with_existing_attachments(attrs(space, participant), [good.id, bad])

    assert message_count() == before
    assert is_nil(Repo.get!(Attachment, good.id).message_id)

    assert {:error, {:attachment_not_found, "not-a-uuid"}} =
             Chat.post_message_with_existing_attachments(attrs(space, participant), [
               "not-a-uuid"
             ])
  end

  test "(f) a chat.read deny for the poster's scope answers not_found" do
    %{space: space} = setup_space()
    user = create_user!()
    participant = add_user!(space.id, user.id)
    row = attachment!(space.id)

    {:ok, _} =
      Grants.deny(%{
        principal: {:user, user.id},
        permission: "chat.read",
        resource: {:space, space.id}
      })

    assert {:error, :denied} =
             Chat.attachment_access_check(row, Platform.Access.Scope.for_user(%{id: user.id}))

    before = message_count()

    assert {:error, {:attachment_not_found, id}} =
             Chat.post_message_with_existing_attachments(attrs(space, participant), [row.id],
               poster_user_id: user.id
             )

    assert id == row.id
    assert message_count() == before
    assert is_nil(Repo.get!(Attachment, row.id).message_id)
  end

  test "more than ten distinct ids is too_many_attachments" do
    %{space: space, participant: participant} = setup_space()
    ids = for _ <- 1..11, do: attachment!(space.id).id

    assert {:error, :too_many_attachments} =
             Chat.post_message_with_existing_attachments(attrs(space, participant), ids)
  end
end
