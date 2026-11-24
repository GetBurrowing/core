defmodule Platform.Chat.FindMessageByMetadataTest do
  @moduledoc """
  `Platform.Chat.find_message_by_metadata/3` (task 01a20dc5 stage 3): the
  earliest message in a space, by one participant, whose metadata contains
  every given pair. It backs the Voice tab's on-device turn dedupe.
  """
  use Platform.DataCase, async: true

  alias Platform.Chat

  setup do
    {:ok, space} =
      Chat.create_space(%{
        name: "Meta lookup",
        slug: "meta-lookup-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    [author, other] =
      for n <- ["Author", "Other"] do
        {:ok, p} =
          Chat.add_participant(space.id, %{
            participant_type: "user",
            participant_id: user!(n).id,
            display_name: n,
            joined_at: DateTime.utc_now()
          })

        p
      end

    {:ok, space: space, author: author, other: other}
  end

  defp user!(name) do
    n = System.unique_integer([:positive])

    Platform.Repo.insert!(%Platform.Accounts.User{
      name: name,
      email: "meta-lookup-#{n}@example.com",
      oidc_sub: "oidc-meta-lookup-#{n}"
    })
  end

  defp post(space, participant, content, metadata) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content,
        metadata: metadata
      })

    message
  end

  test "finds the earliest message whose metadata contains every pair", %{
    space: space,
    author: author
  } do
    first = post(space, author, "one", %{"input" => "on_device", "client_turn_id" => "ct-1"})
    _again = post(space, author, "two", %{"input" => "on_device", "client_turn_id" => "ct-1"})

    _other_id =
      post(space, author, "three", %{"input" => "on_device", "client_turn_id" => "ct-2"})

    match = %{"input" => "on_device", "client_turn_id" => "ct-1"}
    assert Chat.find_message_by_metadata(space.id, author.id, match).id == first.id

    assert Chat.find_message_by_metadata(space.id, author.id, %{"client_turn_id" => "ct-2"}).content ==
             "three"
  end

  test "every pair must match, and only the named participant's messages count", %{
    space: space,
    author: author,
    other: other
  } do
    _typed = post(space, author, "typed", %{"input" => "typed", "client_turn_id" => "ct-3"})
    _theirs = post(space, other, "theirs", %{"input" => "on_device", "client_turn_id" => "ct-4"})

    assert Chat.find_message_by_metadata(space.id, author.id, %{
             "input" => "on_device",
             "client_turn_id" => "ct-3"
           }) == nil

    assert Chat.find_message_by_metadata(space.id, author.id, %{"client_turn_id" => "ct-4"}) ==
             nil

    assert Chat.find_message_by_metadata(space.id, other.id, %{"client_turn_id" => "ct-4"}).content ==
             "theirs"
  end

  test "malformed ids and an empty match answer nil without raising", %{
    space: space,
    author: author
  } do
    _m = post(space, author, "x", %{"client_turn_id" => "ct-5"})

    assert Chat.find_message_by_metadata("not-a-uuid", author.id, %{"client_turn_id" => "ct-5"}) ==
             nil

    assert Chat.find_message_by_metadata(space.id, "not-a-uuid", %{"client_turn_id" => "ct-5"}) ==
             nil

    assert Chat.find_message_by_metadata(space.id, author.id, %{}) == nil
    assert Chat.find_message_by_metadata(nil, nil, nil) == nil
  end
end
