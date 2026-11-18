defmodule Platform.Meetings.TranscriptViewerScopeTest do
  @moduledoc """
  `Meetings.get_transcript_for_user/2` (task 01a1b288 stage 1) at the context
  level, behind the ExternalUserScope plug that already 403s external users on
  the HTTP route. Each denial carries a positive control on the same fixture.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.ExternalUserFixtures

  alias Platform.Meetings
  alias Platform.Meetings.Transcript
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  defp meeting!(org) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Transcript Scope #{n}", org_id: org.id})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Transcript Scope Meeting #{n}",
        slug: "transcript-scope-#{n}"
      })

    meeting
  end

  defp transcript!(meeting) do
    %Transcript{}
    |> Transcript.changeset(%{
      room_id: "space-#{meeting.chat_space_id}",
      space_id: meeting.chat_space_id,
      meeting_id: meeting.id,
      started_at: DateTime.utc_now(),
      status: "complete"
    })
    |> Repo.insert!()
  end

  setup do
    globex = Tenancy.get_org_by_slug!("globex")
    meeting = meeting!(globex)
    insider = create_user!()
    plain_member!(insider, globex)
    %{globex: globex, meeting: meeting, insider: insider, transcript: transcript!(meeting)}
  end

  test "an external user with no invite gets {:error, :not_found}", ctx do
    external = external_user!(ctx.globex)
    assert Tenancy.external_user?(external)

    assert {:ok, %Transcript{}} = Meetings.get_transcript_for_user(ctx.insider, ctx.transcript.id),
           "positive control"

    assert Meetings.get_transcript_for_user(external, ctx.transcript.id) == {:error, :not_found}
  end

  test "an external user with a live invite is admitted by the meeting rule", ctx do
    external = external_user!(ctx.globex)
    {:ok, _} = Meetings.invite_user(ctx.meeting, external.id)

    assert {:ok, %Transcript{id: id}} =
             Meetings.get_transcript_for_user(external, ctx.transcript.id)

    assert id == ctx.transcript.id
  end

  # Task 01a1b281 stage 4: the delete confirm promises "Its transcript and
  # recording are kept", so the read must not inherit the deleted filter
  # the lists carry. The viewer rule itself still applies.
  test "a soft-deleted meeting's transcript stays readable under the same viewer rule", ctx do
    assert {:ok, %Transcript{id: id}} =
             Meetings.get_transcript_for_user(ctx.insider, ctx.transcript.id)

    assert id == ctx.transcript.id

    {1, _} =
      from(m in Meetings.Meeting, where: m.id == ^ctx.meeting.id)
      |> Repo.update_all(set: [status: "cancelled", deleted_at: DateTime.utc_now()])

    assert {:error, :not_found} = Meetings.get_meeting_for_user(ctx.insider, ctx.meeting.id)
    assert {:ok, %Transcript{id: ^id}} = Meetings.get_transcript_for_user(ctx.insider, id)

    outsider = create_user!()
    assert {:error, :not_found} = Meetings.get_transcript_for_user(outsider, id)
  end

  test "malformed ids and nil or id-less users are not_found", ctx do
    assert Meetings.get_transcript_for_user(ctx.insider, "not-a-uuid") == {:error, :not_found}
    assert Meetings.get_transcript_for_user(ctx.insider, nil) == {:error, :not_found}
    assert Meetings.get_transcript_for_user(nil, ctx.transcript.id) == {:error, :not_found}
    assert Meetings.get_transcript_for_user(%{}, ctx.transcript.id) == {:error, :not_found}
  end
end
