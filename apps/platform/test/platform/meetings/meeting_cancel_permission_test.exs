defmodule Platform.Meetings.MeetingCancelPermissionTest do
  @moduledoc """
  Pins the cancel permission rule and the user-facing cancel entry point
  (task 01a19e7f stage 1): `Meetings.can_cancel_meeting?/2`,
  `Meetings.cancel_meeting_for_user/2`, `Meetings.cancellation_audience_count/1`
  and the `created_by_user_id` stamp through `Meetings.create_meeting/1`.

  Every refusal here is paired, on the same fixture, with a caller who IS
  allowed, so a rule that refuses everybody fails a named test instead of
  passing every `:forbidden` vacuously.

  Users are seeded with `@example.com` addresses: a `@acme.test` address
  would make `Tenancy.derive_role_from_email/1` return `:admin`.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "meeting_cancel_#{n}@example.com",
      name: "Meeting Cancel User #{n}",
      oidc_sub: "oidc-meeting-cancel-#{n}"
    })
  end

  defp member!(user, org_id, opts \\ []) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: Keyword.get(opts, :role, "member"),
      external: Keyword.get(opts, :external, false)
    })
    |> Repo.insert!()

    user
  end

  defp project!(org_id) do
    name = "Meeting Cancel Project #{System.unique_integer([:positive])}"

    %Project{}
    |> Project.changeset(%{
      name: name,
      slug: name |> String.downcase() |> String.replace(" ", "-"),
      org_id: org_id
    })
    |> Repo.insert!()
  end

  defp meeting!(project, attrs \\ %{}) do
    name = "Cancel Meeting #{System.unique_integer([:positive])}"
    {:ok, meeting} = Meetings.create_meeting(Map.merge(%{project_id: project.id, name: name}, attrs))
    meeting
  end

  defp seat!(meeting, user) do
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp host!(meeting, user) do
    participant = seat!(meeting, user)
    Repo.update!(Ecto.Changeset.change(meeting, host_participant_id: participant.id))
  end

  defp invite!(meeting, attrs) do
    %Invite{}
    |> Invite.changeset(Map.merge(%{meeting_id: meeting.id, display_name: "Invitee"}, attrs))
    |> Repo.insert!()
  end

  defp reload(meeting), do: Repo.get!(Meeting, meeting.id)

  defp chat_participant_count(meeting) do
    meeting.chat_space_id
    |> Chat.list_participants(participant_type: "user")
    |> length()
  end

  setup do
    org = Platform.TenancyFixtures.tenant_org_id("initech")
    other_org = Platform.TenancyFixtures.tenant_org_id("vandelay_ind")
    project = project!(org)

    creator = member!(user!(), org)
    plain = member!(user!(), org)

    %{
      org: org,
      other_org: other_org,
      project: project,
      creator: creator,
      plain: plain,
      meeting: meeting!(project, %{created_by_user_id: creator.id})
    }
  end

  # ── created_by_user_id ────────────────────────────────────────────────────

  describe "create_meeting/1" do
    test "persists created_by_user_id", %{meeting: meeting, creator: creator} do
      assert reload(meeting).created_by_user_id == creator.id
    end

    test "leaves created_by_user_id nil when no creator is given", %{project: project} do
      assert reload(meeting!(project)).created_by_user_id == nil
    end
  end

  # ── Who may cancel ────────────────────────────────────────────────────────

  describe "cancel_meeting_for_user/2 — permitted callers" do
    test "the host may cancel", %{project: project, org: org} do
      host = member!(user!(), org)
      meeting = project |> meeting!() |> host!(host)

      assert reload(meeting).created_by_user_id == nil
      assert Meetings.can_cancel_meeting?(meeting, host)
      assert {:ok, %Meeting{status: "cancelled"}} = Meetings.cancel_meeting_for_user(meeting.id, host)
      assert reload(meeting).status == "cancelled"
    end

    test "the creator of a hostless meeting may cancel, attributed to their existing seat",
         %{meeting: meeting, creator: creator} do
      assert meeting.host_participant_id == nil
      participant = seat!(meeting, creator)

      assert Meetings.can_cancel_meeting?(meeting, creator)
      assert {:ok, %Meeting{status: "cancelled"}} = Meetings.cancel_meeting_for_user(meeting.id, creator)

      cancelled = reload(meeting)
      assert cancelled.status == "cancelled"
      assert %DateTime{} = cancelled.cancelled_at
      assert cancelled.cancelled_by_participant_id == participant.id
    end

    test "an org admin who is neither host nor creator may cancel", %{meeting: meeting, org: org} do
      admin = member!(user!(), org, role: "admin")

      assert Meetings.can_cancel_meeting?(meeting, admin)
      assert {:ok, %Meeting{status: "cancelled"}} = Meetings.cancel_meeting_for_user(meeting.id, admin)
    end

    test "cancelling creates NO chat participant row for the canceller",
         %{meeting: meeting, creator: creator} do
      before = chat_participant_count(meeting)

      assert {:ok, _} = Meetings.cancel_meeting_for_user(meeting.id, creator)

      assert chat_participant_count(meeting) == before
      assert reload(meeting).cancelled_by_participant_id == nil
    end
  end

  describe "cancel_meeting_for_user/2 — refused callers" do
    test "a plain org member who is neither host nor creator is :forbidden and the row is unchanged",
         %{meeting: meeting, plain: plain, creator: creator} do
      before = reload(meeting)

      refute Meetings.can_cancel_meeting?(meeting, plain)
      assert {:error, :forbidden} = Meetings.cancel_meeting_for_user(meeting.id, plain)
      assert reload(meeting) == before

      # Positive control on the same fixture.
      assert {:ok, _} = Meetings.cancel_meeting_for_user(meeting.id, creator)
    end

    test "an external invitee is :forbidden even when they created the meeting",
         %{project: project, org: org} do
      external = member!(user!(), org, external: true)
      meeting = meeting!(project, %{created_by_user_id: external.id})
      invite!(meeting, %{user_id: external.id})

      refute Meetings.can_cancel_meeting?(meeting, external)
      assert {:error, :forbidden} = Meetings.cancel_meeting_for_user(meeting.id, external)
      assert reload(meeting).status == "scheduled"
    end

    test "a user in another org is :not_found, not :forbidden",
         %{meeting: meeting, other_org: other_org, org: org} do
      outsider = member!(user!(), other_org, role: "admin")

      assert {:error, :not_found} = Meetings.cancel_meeting_for_user(meeting.id, outsider)
      assert reload(meeting).status == "scheduled"

      # Positive control: an admin of the meeting's own org gets through.
      admin = member!(user!(), org, role: "admin")
      assert {:ok, _} = Meetings.cancel_meeting_for_user(meeting.id, admin)
    end

    test "a nil user is :not_found", %{meeting: meeting} do
      refute Meetings.can_cancel_meeting?(meeting, nil)
      assert {:error, :not_found} = Meetings.cancel_meeting_for_user(meeting.id, nil)
      assert reload(meeting).status == "scheduled"
    end

    test "a malformed or unknown id is :not_found", %{creator: creator} do
      assert {:error, :not_found} = Meetings.cancel_meeting_for_user("not-a-uuid", creator)
      assert {:error, :not_found} = Meetings.cancel_meeting_for_user(Ecto.UUID.generate(), creator)
    end
  end

  # ── Status ────────────────────────────────────────────────────────────────

  describe "cancel_meeting_for_user/2 — status" do
    test "an ended meeting is :not_cancellable", %{meeting: meeting, creator: creator} do
      {:ok, live} = Meetings.start_meeting(meeting)
      {:ok, ended} = Meetings.end_meeting(live)
      assert ended.status == "ended"

      refute Meetings.cancellable_status?(ended)
      assert {:error, :not_cancellable} = Meetings.cancel_meeting_for_user(meeting.id, creator)
      assert reload(meeting).status == "ended"
    end

    test "a live meeting is cancellable", %{meeting: meeting, creator: creator} do
      {:ok, live} = Meetings.start_meeting(meeting)
      assert Meetings.cancellable_status?(live)
      assert {:ok, %Meeting{status: "cancelled"}} = Meetings.cancel_meeting_for_user(meeting.id, creator)
    end

    test "re-cancel is {:ok, _} with no write and no broadcast",
         %{meeting: meeting, creator: creator, project: project} do
      assert {:ok, _} = Meetings.cancel_meeting_for_user(meeting.id, creator)
      first = reload(meeting)

      Phoenix.PubSub.subscribe(Platform.PubSub, Meetings.project_meetings_topic(project.id))

      assert {:ok, %Meeting{status: "cancelled"} = again} =
               Meetings.cancel_meeting_for_user(meeting.id, creator)

      second = reload(meeting)
      assert again.cancelled_at == first.cancelled_at
      assert second.cancelled_at == first.cancelled_at
      assert second.updated_at == first.updated_at
      refute_receive {:meeting_cancelled, _}, 200
    end
  end

  # ── Audience ──────────────────────────────────────────────────────────────

  describe "cancellation_audience_count/1" do
    test "is the notifier's invitee count", %{meeting: meeting, plain: plain} do
      assert Meetings.cancellation_audience_count(meeting) == 0

      invite!(meeting, %{user_id: plain.id})
      invite!(meeting, %{email: "guest_#{System.unique_integer([:positive])}@example.com"})

      assert Meetings.cancellation_audience_count(meeting) == 2

      assert Meetings.cancellation_audience_count(meeting) ==
               Meetings.recipients_for_meeting(meeting).invitee_count
    end
  end
end
