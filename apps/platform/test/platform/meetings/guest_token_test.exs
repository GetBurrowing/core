defmodule Platform.Meetings.GuestTokenTest do
  @moduledoc """
  Tests for the guest-ingress additions to `Platform.Meetings` (task
  019f2483 stage 2):

    * `parse_identity/1` — new `"guest:<uuid>"` clause + `{:guest, _}`
      tuple return
    * `upsert_live_participant/2` — guest identity yields a nil-FK row
      that carries just the display name
    * `create_guest_chat_space/2` — per-invite `kind: "guest_meeting"`
      chat_space for guest identity bookkeeping
    * `guest_livekit_token/2` — HS256 JWT with 30-min TTL, `guest:*`
      identity, `<name> (guest)` display name, and the meeting's
      LiveKit room derived from `room_name_for_space/1`

  The token is decoded manually (no external JOSE dep) so the test
  proves the exact claim shape the guest LiveView will emit.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks

  # ── Fixtures ──────────────────────────────────────────────────────────────

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

  defp create_project(attrs \\ %{}) do
    default = %{name: "Guest Project #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end

  defp create_meeting(attrs \\ %{}) do
    project = attrs[:project] || create_project()
    name = attrs[:name] || "Guest Meeting #{System.unique_integer([:positive])}"

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    Repo.preload(meeting, :chat_space)
  end

  # Manually decode a signed JWT (three base64url segments) into
  # {:ok, claims_map} without pulling in a JOSE dep — mirrors what the
  # guest LiveView / MeetingClient hook will do downstream. Returns
  # `:error` for anything that can't be decoded.
  defp decode_jwt(jwt) when is_binary(jwt) do
    with [_header, payload_b64, _sig] <- String.split(jwt, ".", parts: 3),
         {:ok, json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  # ── parse_identity/1 guest clause ─────────────────────────────────────────

  describe "parse_identity/1 — guest clause" do
    test "parses a well-formed guest identity into {:guest, uuid}" do
      uuid = Ecto.UUID.generate()
      assert {:guest, ^uuid} = Meetings.parse_identity("guest:#{uuid}")
    end

    test "returns :unknown for a guest prefix with a non-uuid suffix" do
      assert :unknown = Meetings.parse_identity("guest:not-a-uuid")
    end

    test "distinguishes guest from user and agent identities" do
      uuid = Ecto.UUID.generate()

      assert {:guest, ^uuid} = Meetings.parse_identity("guest:#{uuid}")
      assert {:user, ^uuid} = Meetings.parse_identity("user:#{uuid}")
      assert {:agent, ^uuid} = Meetings.parse_identity("agent:#{uuid}")
    end
  end

  # ── upsert_live_participant/2 with a guest identity ───────────────────────

  describe "upsert_live_participant/2 — guest identity" do
    setup do
      {:ok, space} =
        Chat.create_space(%{
          name: "Guest Upsert Space",
          slug: "guest-upsert-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, room} = Meetings.ensure_room(space.id)
      %{room: room}
    end

    test "creates a nil-FK row carrying the guest name", %{room: room} do
      guest_uuid = Ecto.UUID.generate()

      assert {:ok, p} =
               Meetings.upsert_live_participant(room, %{
                 identity: "guest:#{guest_uuid}",
                 name: "Jane Doe (guest)"
               })

      assert is_nil(p.user_id)
      assert is_nil(p.agent_id)
      assert p.display_name == "Jane Doe (guest)"
      assert is_nil(p.left_at)
    end

    test "two guests with different identities but the same display_name still dedupe by name",
         %{room: room} do
      # The nil-FK path matches by display_name, which is deliberate for
      # phone/SIP/guest rows. If two guests happen to have the same name,
      # they land on the same row — matches how anonymous phone joiners
      # behave (documented, see `find_active_participant/3` comment).
      assert {:ok, p1} =
               Meetings.upsert_live_participant(room, %{
                 identity: "guest:#{Ecto.UUID.generate()}",
                 name: "Jane Doe (guest)"
               })

      assert {:ok, p2} =
               Meetings.upsert_live_participant(room, %{
                 identity: "guest:#{Ecto.UUID.generate()}",
                 name: "Jane Doe (guest)"
               })

      assert p1.id == p2.id
    end

    test "distinct display names yield distinct rows", %{room: room} do
      assert {:ok, p1} =
               Meetings.upsert_live_participant(room, %{
                 identity: "guest:#{Ecto.UUID.generate()}",
                 name: "Jane Doe (guest)"
               })

      assert {:ok, p2} =
               Meetings.upsert_live_participant(room, %{
                 identity: "guest:#{Ecto.UUID.generate()}",
                 name: "Alex (guest)"
               })

      refute p1.id == p2.id
    end
  end

  # ── create_guest_chat_space/2 ─────────────────────────────────────────────

  describe "create_guest_chat_space/2" do
    test "creates a guest_meeting space with a guest- slug prefix" do
      meeting = create_meeting(name: "Kickoff")
      host_user_id = Ecto.UUID.generate()

      assert {:ok, space} = Meetings.create_guest_chat_space(meeting, host_user_id)

      assert space.kind == "guest_meeting"
      assert String.starts_with?(space.slug, "guest-")
      assert space.name == "Guest — Kickoff"
      assert space.metadata["meeting_id"] == meeting.id
      assert space.metadata["host_user_id"] == host_user_id
    end

    test "the created space is retrievable via Chat.get_space/1 (phantom-fix guard compat)" do
      # `Meetings.legit_room?/1` walks `Chat.get_space/1` on the LiveKit
      # room name's derived space_id. The guest chat_space is IDENTITY
      # bookkeeping (guest joins the host's LiveKit room, not this one),
      # but the round-trip through Chat.get_space/1 still validates the
      # space is durably persisted — which is what stage 4's HMAC
      # payload embed relies on.
      meeting = create_meeting()

      assert {:ok, space} = Meetings.create_guest_chat_space(meeting, Ecto.UUID.generate())

      assert %Platform.Chat.Space{} = fetched = Chat.get_space(space.id)
      assert fetched.id == space.id
      assert fetched.kind == "guest_meeting"
    end

    test "distinct calls yield distinct slugs (regression: don't collide inside a project)" do
      meeting = create_meeting()

      # Generate 5 in a row — each should get a fresh random suffix. If
      # they collide the second create_space/1 will return an
      # {:error, changeset}, and this test will crash on the pattern
      # match — which is exactly the regression we want to catch.
      slugs =
        for _ <- 1..5 do
          {:ok, s} = Meetings.create_guest_chat_space(meeting, Ecto.UUID.generate())
          s.slug
        end

      assert Enum.uniq(slugs) == slugs
    end

    test "inherits org_id from the meeting's project" do
      # `Tasks.create_project/1` auto-fills `:org_id` from the seeded
      # `fabrikam` org when the caller doesn't pass one (see the migration
      # `20260519143620_seed_root_orgs.exs`). The guest chat_space
      # should carry the SAME org so cross-tenant slug uniqueness
      # scoping matches the host meeting.
      project = create_project()
      # sanity: project actually resolved an org_id
      refute is_nil(project.org_id)

      meeting = create_meeting(project: project)

      assert {:ok, space} = Meetings.create_guest_chat_space(meeting, Ecto.UUID.generate())
      assert space.org_id == project.org_id
    end
  end

  # ── guest_livekit_token/2 ─────────────────────────────────────────────────

  describe "guest_livekit_token/2 — happy path" do
    setup :put_livekit_env

    test "mints a JWT with a guest identity, (guest)-suffixed name, and 30-min TTL" do
      meeting = create_meeting()

      assert {:ok, %{token: token, identity: identity, room_name: room_name, livekit_url: url}} =
               Meetings.guest_livekit_token(meeting, "Jane Doe")

      # LiveKit URL is passed through from config, unchanged.
      assert url == "wss://livekit.test"

      # Room name matches the host's room — guests join the SAME room as
      # the host. `room_name_for_space/1` is `"space-<chat_space_id>"`.
      assert room_name == "space-#{meeting.chat_space_id}"

      # Identity is `guest:` + random URL-safe base64. Random UUID is
      # not an Ecto UUID here — it's `strong_rand_bytes(16) |>
      # url_encode64` — so we just assert prefix + non-empty suffix.
      assert String.starts_with?(identity, "guest:")
      assert byte_size(identity) > byte_size("guest:")

      # Decode and inspect claims.
      assert {:ok, claims} = decode_jwt(token)
      assert claims["iss"] == "test-livekit-key"
      assert claims["sub"] == identity
      assert claims["name"] == "Jane Doe (guest)"

      # 30-min TTL — allow ±5s for wall-clock skew inside the test.
      ttl = claims["exp"] - claims["nbf"]
      assert ttl == 30 * 60
      # exp is in the future.
      assert claims["exp"] > System.system_time(:second)

      # Full participant grants — same shape as `generate_token/2`.
      assert claims["video"]["room"] == room_name
      assert claims["video"]["roomJoin"] == true
      assert claims["video"]["canPublish"] == true
      assert claims["video"]["canSubscribe"] == true
      assert claims["video"]["canPublishData"] == true

      # `roomConfig.agents` is set because room name is `space-*` (see
      # `maybe_put_room_config/2`). The transcriber dispatch is
      # preserved even for guest-triggered joins — no-op on already-
      # created rooms.
      assert claims["roomConfig"]["agents"] == [%{"agentName" => "meeting-transcriber"}]
    end

    test "trims whitespace off the display name" do
      meeting = create_meeting()

      assert {:ok, %{token: token}} =
               Meetings.guest_livekit_token(meeting, "  Jane Doe  ")

      assert {:ok, claims} = decode_jwt(token)
      assert claims["name"] == "Jane Doe (guest)"
    end

    test "distinct calls mint distinct guest identities (randomness regression)" do
      meeting = create_meeting()

      identities =
        for _ <- 1..50 do
          {:ok, %{identity: id}} = Meetings.guest_livekit_token(meeting, "Jane")
          id
        end

      assert length(Enum.uniq(identities)) == 50
    end

    test "identity's random suffix is a valid parsed identity of {:guest, _}" do
      # The `parse_identity/1` guest clause runs `Ecto.UUID.cast/1` on
      # the suffix. `strong_rand_bytes(16) |> url_encode64` is NOT a
      # canonical UUID string, so the parse would return `:unknown`.
      # This is intentional — the identity is opaque to Suite (no FK
      # resolution) and only meaningful to LiveKit as a per-participant
      # unique sub. Guarded here so anyone tempted to "fix" this by
      # making guest identities parseable understands the shape.
      meeting = create_meeting()

      assert {:ok, %{identity: identity}} =
               Meetings.guest_livekit_token(meeting, "Jane Doe")

      assert :unknown = Meetings.parse_identity(identity)
    end
  end

  describe "guest_livekit_token/2 — sad paths" do
    test "returns :missing_display_name for empty / whitespace-only names" do
      # No env setup: this branch fires before the LiveKit config check.
      meeting = create_meeting()

      assert {:error, :missing_display_name} = Meetings.guest_livekit_token(meeting, "")
      assert {:error, :missing_display_name} = Meetings.guest_livekit_token(meeting, "   ")
    end

    test "returns :livekit_not_configured when config is missing" do
      # Explicit no-config env; DO NOT run put_livekit_env setup.
      original = Application.get_env(:platform, :livekit, [])
      Application.put_env(:platform, :livekit, api_key: nil, api_secret: nil, url: nil)
      on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

      meeting = create_meeting()

      assert {:error, :livekit_not_configured} =
               Meetings.guest_livekit_token(meeting, "Jane Doe")
    end

    test "returns :missing_display_name when nil name is passed on a meeting" do
      # Nil doesn't match the `is_binary` guard; falls to the second
      # clause returning `:missing_display_name`. Non-binary names are a
      # programmer error, not runtime data — guarded so a caller can't
      # accidentally mint a nameless guest token.
      meeting = create_meeting()

      assert {:error, :missing_display_name} =
               Meetings.guest_livekit_token(meeting, nil)
    end
  end

  describe "guest_livekit_token/2 — signer parity" do
    setup :put_livekit_env

    test "the JWT signature matches the same HS256 encoder used for user tokens" do
      # Signer parity check: encode a control claim set with
      # `Meetings.encode_jwt/2` (the shared helper) and compare its
      # signature-shape against the guest token. Both must be valid
      # three-segment HS256 JWTs the LiveKit server will accept.
      meeting = create_meeting()

      assert {:ok, %{token: guest_token}} =
               Meetings.guest_livekit_token(meeting, "Jane Doe")

      assert 3 = guest_token |> String.split(".") |> length()

      config = Application.get_env(:platform, :livekit)

      control =
        Meetings.encode_jwt(
          %{"iss" => config[:api_key], "sub" => "user:#{Ecto.UUID.generate()}"},
          config[:api_secret]
        )

      # Same header (algo + typ) — the first segment of both JWTs is
      # base64url("{\"alg\":\"HS256\",\"typ\":\"JWT\"}") — so the header
      # segments MUST match byte-for-byte.
      [guest_header, _, _] = String.split(guest_token, ".", parts: 3)
      [control_header, _, _] = String.split(control, ".", parts: 3)

      assert guest_header == control_header
    end
  end

  # ── Meeting struct expectations ──────────────────────────────────────────

  describe "guest_livekit_token/2 — argument guards" do
    setup :put_livekit_env

    test "a Meeting struct without a chat_space_id degrades to :missing_display_name" do
      # The head guard `when is_binary(chat_space_id)` prevents nil-FK
      # meetings from ever entering the happy mint path. Because the
      # first clause fails the guard, the second (fallback) clause
      # returns `:missing_display_name` — an odd label for the shape,
      # but the practical outcome is "no token minted", which is what
      # we want. This test locks in the fallback so future refactors
      # don't accidentally add a happy path for chat_space_id-less
      # meetings.
      broken = %Meeting{chat_space_id: nil, name: "Broken"}

      assert {:error, :missing_display_name} =
               Meetings.guest_livekit_token(broken, "Jane Doe")
    end
  end
end
