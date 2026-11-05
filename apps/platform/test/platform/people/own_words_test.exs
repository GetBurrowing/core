defmodule Platform.People.OwnWordsTest do
  @moduledoc """
  Task 01a1aa47 stage 3 — `Platform.People.OwnWords.for_subject/4` returns the
  subject's own chat and spoken words with citations, scrubbed, and nothing
  anyone else said.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant}
  alias Platform.Meetings.Transcript
  alias Platform.People.OwnWords
  alias Platform.Repo

  @now ~U[2026-10-20 10:00:00.000000Z]
  @ws ~U[2026-10-20 09:00:00.000000Z]
  @we ~U[2026-10-20 11:00:00.000000Z]
  @others_chat "Marisol keeps slow playing the deploy"
  @others_spoken "I think Marisol is slow playing us"

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "ow-#{n}@example.com", name: name, oidc_sub: "ow-#{n}"})
    |> Repo.insert!()
  end

  defp space! do
    {:ok, space} =
      Chat.create_space(%{
        name: "eng",
        slug: "ow-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp participant!(space, user, name) do
    %Participant{}
    |> Participant.changeset(%{
      space_id: space.id,
      participant_type: "user",
      participant_id: user.id,
      display_name: name,
      joined_at: @now
    })
    |> Repo.insert!()
  end

  defp message!(space, participant, user_id, name, content, at) do
    %Message{}
    |> Message.changeset(%{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: content,
      author_display_name: name,
      author_user_id: user_id,
      author_participant_type: "user"
    })
    |> Ecto.Changeset.put_change(:inserted_at, at)
    |> Repo.insert!()
  end

  defp transcript!(space, completed_at) do
    %Transcript{}
    |> Transcript.changeset(%{
      room_id: "room-#{System.unique_integer([:positive])}",
      space_id: space.id,
      status: "complete",
      completed_at: completed_at,
      summary: "Fixture Founder doubted Marisol's pace",
      segments: [
        %{
          "id" => "s1",
          "speaker_name" => "Fixture Founder",
          "text" => @others_spoken,
          "spoken_at" => "2026-10-20T10:01:00Z"
        },
        %{
          "id" => "s2",
          "speaker_name" => "Marisol Tennebrook",
          "text" => "I will own the pipeline, page me on 904-555-0100",
          "spoken_at" => "2026-10-20T10:02:00Z"
        }
      ]
    })
    |> Repo.insert!()
  end

  test "collects the subject's chat and spoken words with citations and nothing by others" do
    marisol = user!("Marisol Tennebrook")
    founder = user!("Fixture Founder")
    space = space!()
    m_part = participant!(space, marisol, "Marisol Tennebrook")
    f_part = participant!(space, founder, "Fixture Founder")

    own =
      message!(
        space,
        m_part,
        marisol.id,
        "Marisol Tennebrook",
        "I prefer small PRs",
        DateTime.add(@now, 10, :second)
      )

    message!(
      space,
      f_part,
      founder.id,
      "Fixture Founder",
      @others_chat,
      DateTime.add(@now, 20, :second)
    )

    # same display name, a different account: never the subject's words
    impostor = user!("Marisol Tennebrook")
    i_part = participant!(space, impostor, "Marisol Tennebrook")

    message!(
      space,
      i_part,
      impostor.id,
      "Marisol Tennebrook",
      "impostor line",
      DateTime.add(@now, 30, :second)
    )

    message!(
      space,
      m_part,
      marisol.id,
      "Marisol Tennebrook",
      "too early",
      DateTime.add(@ws, -1, :second)
    )

    transcript = transcript!(space, DateTime.add(@now, 40, :second))
    transcript!(space, @we)

    items =
      OwnWords.for_subject(
        %{user_id: marisol.id, names: ["Marisol Tennebrook", "Mari"]},
        @ws,
        @we
      )

    assert [
             %{text: "I prefer small PRs", citation: chat_cite, at: %DateTime{}},
             %{text: spoken, citation: spoken_cite, at: %DateTime{}}
           ] = items

    assert chat_cite == "chat:#{space.id}:#{own.id}"
    assert spoken_cite == "meeting:transcript:#{transcript.id}:s2"
    assert spoken == "I will own the pipeline, page me on [REDACTED: phone]"

    dump = inspect(items)
    refute dump =~ "slow playing"
    refute dump =~ "impostor"
    refute dump =~ "doubted"
    refute dump =~ "too early"
  end

  test "a subject without an account is matched by display name only on account-less messages" do
    oskar = user!("Oskar Vellinghausen")
    space = space!()
    part = participant!(space, oskar, "Oskar Vellinghausen")
    message!(space, part, nil, "Oskar Vellinghausen", "from the guest seat", @now)

    message!(
      space,
      part,
      oskar.id,
      "Oskar Vellinghausen",
      "with an account",
      DateTime.add(@now, 1, :second)
    )

    assert [%{text: "from the guest seat"}] =
             OwnWords.for_subject(%{user_id: nil, names: ["@[Oskar Vellinghausen]"]}, @ws, @we)

    assert OwnWords.for_subject(%{user_id: nil, names: []}, @ws, @we) == []
  end

  test "caps at 40 items" do
    priya = user!("Priya Kalloway")
    space = space!()
    part = participant!(space, priya, "Priya Kalloway")

    for i <- 1..45 do
      message!(
        space,
        part,
        priya.id,
        "Priya Kalloway",
        "line #{i}",
        DateTime.add(@now, i, :second)
      )
    end

    items = OwnWords.for_subject(%{user_id: priya.id, names: ["Priya Kalloway"]}, @ws, @we)
    assert length(items) == 40
    assert List.first(items).text == "line 1"
  end
end
