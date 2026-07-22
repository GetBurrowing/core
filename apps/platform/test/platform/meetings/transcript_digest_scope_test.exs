defmodule Platform.Meetings.TranscriptDigestScopeTest do
  @moduledoc """
  Stack member 12 (rbac-external-users) — the `:scope` partition on
  `Platform.Meetings.list_transcripts_since/2`, mirroring the messages
  corpus: `:internal` (default) excludes external-user spaces from the
  Fabrikam-internal digest; `{:external_spaces, ids}` restricts to them.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Transcript
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.TenancyFixtures

  defp create_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "u-#{n}@example.com", name: "User #{n}", oidc_sub: "oidc-#{n}"})
    |> Repo.insert!()
  end

  defp external_user! do
    user = create_user!()

    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: TenancyFixtures.tenant_org_id("sxi")
      })

    user
  end

  defp create_space!(name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "sp-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp add_user!(space_id, user_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp complete_transcript!(space_id, summary) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Transcript{}
    |> Transcript.changeset(%{
      room_id: "room-#{System.unique_integer([:positive])}",
      space_id: space_id,
      status: "complete",
      summary: summary,
      started_at: DateTime.add(now, -600, :second),
      completed_at: now
    })
    |> Repo.insert!()
  end

  defp window do
    now = DateTime.utc_now()
    {DateTime.add(now, -3600, :second), DateTime.add(now, 3600, :second)}
  end

  describe "list_transcripts_since/2 :scope" do
    test "default :internal omits external-space transcripts" do
      fabrikam = create_user!()
      ext = external_user!()

      internal = create_space!("fabrikam-eng")
      add_user!(internal.id, fabrikam.id)
      complete_transcript!(internal.id, "internal meeting")

      external = create_space!("sxi-support")
      add_user!(external.id, ext.id)
      complete_transcript!(external.id, "external meeting")

      {ws, we} = window()
      summaries = Meetings.list_transcripts_since(ws, window_end: we) |> Enum.map(& &1.summary)

      assert "internal meeting" in summaries
      refute "external meeting" in summaries
    end

    test "{:external_spaces, ids} returns only those spaces' transcripts" do
      fabrikam = create_user!()
      ext = external_user!()

      internal = create_space!("fabrikam-eng")
      add_user!(internal.id, fabrikam.id)
      complete_transcript!(internal.id, "internal meeting")

      external = create_space!("sxi-support")
      add_user!(external.id, ext.id)
      complete_transcript!(external.id, "external meeting")

      {ws, we} = window()

      summaries =
        Meetings.list_transcripts_since(ws,
          window_end: we,
          scope: {:external_spaces, [external.id]}
        )
        |> Enum.map(& &1.summary)

      assert "external meeting" in summaries
      refute "internal meeting" in summaries
    end

    test "zero external users → default filter is a no-op (regression guard)" do
      fabrikam = create_user!()
      internal = create_space!("fabrikam-eng")
      add_user!(internal.id, fabrikam.id)
      complete_transcript!(internal.id, "internal meeting")

      assert Chat.external_space_ids() == []

      {ws, we} = window()
      summaries = Meetings.list_transcripts_since(ws, window_end: we) |> Enum.map(& &1.summary)
      assert "internal meeting" in summaries
    end
  end
end
