defmodule Platform.Meetings.CompanionTokenTest do
  @moduledoc """
  Task 01a13ca2 stage 1: the iOS app's video-only COMPANION connection.

  The app keeps call audio on its native `user:<uuid>` connection and opens a
  second connection as `video:user:<uuid>` for camera publish and video
  viewing. This file pins the server half:

    * `companion_token_for_user/3`: the same join gate, TTL and room as the
      person's token, a grant that can NEVER publish a microphone, and no
      roster row, chat participant or join broadcast;
    * `parse_identity/1`, `person_identity/1`, `companion_identity?/1`,
      including the shared cross-language fixture
      `test/support/fixtures/companion_identities_v1.json`;
    * `presence_from_identities/2` counting people, not connections.

  Tokens are decoded by hand (no JOSE dep), as in `guest_token_test.exs`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Participant
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  @fixture Path.expand("../../support/fixtures/companion_identities_v1.json", __DIR__)

  defp put_livekit_env(_ctx) do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
    :ok
  end

  defp create_user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "companion-#{label}-#{n}@example.com",
      name: "Companion #{label} #{n}",
      oidc_sub: "oidc-companion-#{label}-#{n}"
    })
    |> Repo.insert!()
  end

  defp external_user! do
    n = System.unique_integer([:positive])

    org =
      %Org{}
      |> Org.changeset(%{
        name: "Companion Tenant #{n}",
        slug: "tenant_companion_#{n}",
        parent_org_id: Tenancy.get_org_by_slug!("acme").id
      })
      |> Repo.insert!()

    user = create_user!("ext")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    user
  end

  defp meeting_space! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Companion #{n}"})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Companion Meeting #{n}",
        slug: "companion-#{n}"
      })

    Chat.get_space(meeting.chat_space_id)
  end

  defp jwt_claims(token) do
    [_header, payload, _sig] = String.split(token, ".")
    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp meeting_participant_count do
    Repo.aggregate(Participant, :count)
  end

  defp chat_participant_count(space_id) do
    Repo.aggregate(from(p in Chat.Participant, where: p.space_id == ^space_id), :count)
  end

  # ── companion_token_for_user/3 ───────────────────────────────────────────

  describe "companion_token_for_user/3" do
    setup [:put_livekit_env]

    setup do
      %{space: meeting_space!(), user: create_user!("joiner")}
    end

    test "mints a video-only grant scoped exactly like the person's token", ctx do
      assert {:ok, %{token: token, room: room, identity: identity}} =
               Meetings.companion_token_for_user(ctx.space.id, ctx.user.id, "Ada")

      assert identity == "video:user:#{ctx.user.id}"

      claims = jwt_claims(token)
      assert claims["sub"] == "video:user:#{ctx.user.id}"
      assert claims["name"] == "Ada"

      video = claims["video"]
      assert video["canPublishSources"] == ["camera", "screen_share"]
      refute "microphone" in video["canPublishSources"]
      assert video["canPublish"] == true
      assert video["canSubscribe"] == true
      assert video["canPublishData"] == false
      assert video["roomJoin"] == true

      assert claims["attributes"] == %{"companion_of" => "user:#{ctx.user.id}"}

      # Same TTL and room as the person's own token, by construction.
      {:ok, person_token} =
        Meetings.generate_token(room, %{identity: "user:#{ctx.user.id}", name: "Ada"})

      person = jwt_claims(person_token)
      assert claims["exp"] - claims["nbf"] == person["exp"] - person["nbf"]
      assert claims["exp"] - claims["nbf"] == 6 * 60 * 60
      assert video["room"] == person["video"]["room"]
      assert video["room"] == room.livekit_room_name
      assert claims["roomConfig"] == person["roomConfig"]

      # The person's own grant is unchanged by the shared builder.
      refute Map.has_key?(person["video"], "canPublishSources")
      assert person["video"]["canPublishData"] == true
      refute Map.has_key?(person, "attributes")
    end

    test "an external user with no live invite is refused", ctx do
      ext = external_user!()

      assert {:error, :join_not_permitted} =
               Meetings.companion_token_for_user(ctx.space.id, ext.id, "Outsider")
    end

    test "writes no roster row, no chat participant and broadcasts no join", ctx do
      {:ok, room} = Meetings.ensure_room(ctx.space.id)
      :ok = MeetingsPubSub.subscribe_room(room.id)
      :ok = MeetingsPubSub.subscribe_presence(ctx.space.id)

      rows_before = meeting_participant_count()
      chat_before = chat_participant_count(ctx.space.id)

      assert {:ok, %{room: %{id: room_id}}} =
               Meetings.companion_token_for_user(ctx.space.id, ctx.user.id, "Ada")

      assert room_id == room.id
      assert meeting_participant_count() == rows_before
      assert chat_participant_count(ctx.space.id) == chat_before
      assert Meetings.active_participants(room.id) == []

      refute_receive {:participant_joined, _}, 200
      refute_receive {:meeting_presence_update, _}, 50
    end

    test "rejects a non-binary user id" do
      assert {:error, :invalid_join} = Meetings.companion_token_for_user(nil, nil, "x")
    end
  end

  # ── identity helpers ─────────────────────────────────────────────────────

  describe "parse_identity/1 companion clause" do
    test "a well-formed companion parses to {:companion, uuid}" do
      uuid = Ecto.UUID.generate()
      assert {:companion, ^uuid} = Meetings.parse_identity("video:user:#{uuid}")
    end

    test "a bad uuid is :unknown" do
      assert :unknown = Meetings.parse_identity("video:user:not-a-uuid")
    end

    test "a 16-character suffix is :unknown, never a fabricated uuid" do
      assert :unknown = Meetings.parse_identity("video:user:0123456789abcdef")
    end

    test "user, agent and guest identities are unchanged" do
      uuid = Ecto.UUID.generate()
      assert {:user, ^uuid} = Meetings.parse_identity("user:#{uuid}")
      assert {:agent, ^uuid} = Meetings.parse_identity("agent:#{uuid}")
      assert {:guest, ^uuid} = Meetings.parse_identity("guest:#{uuid}")
      assert :unknown = Meetings.parse_identity(nil)
    end
  end

  describe "companion_identity/1, person_identity/1, companion_identity?/1" do
    test "round trip" do
      uuid = Ecto.UUID.generate()
      companion = Meetings.companion_identity(uuid)

      assert companion == "video:user:#{uuid}"
      assert Meetings.companion_identity?(companion)
      assert Meetings.person_identity(companion) == "user:#{uuid}"
      refute Meetings.companion_identity?("user:#{uuid}")
      assert Meetings.person_identity("user:#{uuid}") == "user:#{uuid}"
      assert Meetings.person_identity(nil) == nil
      refute Meetings.companion_identity?(nil)
      refute Meetings.companion_identity?(:atom)
    end
  end

  describe "shared fixture companion_identities_v1.json" do
    # Stage 2 (JS personIdentity / isCompanionIdentity) and stage 4 (Swift
    # CallParticipant.isCompanion) read this same file, so a later prefix
    # rename cannot change one language's copy and miss the others.
    test "person_identity/1 and companion_identity?/1 agree with every case" do
      assert File.exists?(@fixture), "missing shared fixture #{@fixture}"
      fixture = @fixture |> File.read!() |> Jason.decode!()

      assert fixture["version"] == 1
      cases = fixture["cases"]
      assert is_list(cases)
      assert length(cases) > 0, "the companion identity fixture has no cases"

      for %{"identity" => identity, "person" => person, "companion" => companion} = c <-
            cases do
        assert Meetings.person_identity(identity) == person,
               "person_identity(#{inspect(identity)}) for case #{inspect(c["note"])}"

        assert Meetings.companion_identity?(identity) == companion,
               "companion_identity?(#{inspect(identity)}) for case #{inspect(c["note"])}"
      end

      # The fixture must exercise both answers, or a constant predicate passes.
      assert Enum.any?(cases, & &1["companion"])
      assert Enum.any?(cases, &(!&1["companion"]))
    end
  end

  # ── presence_from_identities/2 ───────────────────────────────────────────

  describe "presence_from_identities/2" do
    test "the viewer's companion is not someone else, and one person counts once" do
      assert Meetings.presence_from_identities(
               ["user:A", "video:user:A", "user:B"],
               "user:A"
             ) == %{viewer_present?: true, others: ["user:B"]}
    end

    test "another person's companion and audio connection count as one other" do
      assert Meetings.presence_from_identities(
               ["user:A", "user:B", "video:user:B"],
               "user:A"
             ) == %{viewer_present?: true, others: ["user:B"]}
    end

    test "a viewer present only through their companion is present" do
      assert Meetings.presence_from_identities(["video:user:A", "user:B"], "user:A") ==
               %{viewer_present?: true, others: ["user:B"]}
    end
  end
end
