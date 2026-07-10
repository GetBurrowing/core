defmodule Platform.MeetingsTest do
  @moduledoc """
  Tests for the top-level `Platform.Meetings` helpers added for the
  phantom LiveKit `RM_<random>` transcript guard + empty-transcript
  cleanup work (task 019f24e3):

    * `app_registered_room?/1` — cheap regex guard for the
      `space-<uuid>` naming convention. Used on the hot webhook path
      to reject events for rooms this app never registered.

    * `delete_transcript/1` — struct-or-id delete that returns
      `{:error, :not_found}` for missing / already-deleted / malformed
      inputs (so the cleanup handler is naturally idempotent).
  """
  use Platform.DataCase, async: true

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.Transcript

  describe "app_registered_room?/1" do
    test "returns true for the canonical space-<uuid> pattern" do
      assert Meetings.app_registered_room?("space-019f24e3-e718-7521-ab33-f495b2e60c85")
    end

    test "returns true for any space- prefix followed by a valid uuid" do
      uuid = Ecto.UUID.generate()
      assert Meetings.app_registered_room?("space-#{uuid}")
    end

    test "rejects LiveKit auto-generated RM_<random> room names" do
      refute Meetings.app_registered_room?("RM_26KcSg8ZBUGd")
      refute Meetings.app_registered_room?("RM_abcdef123456")
    end

    test "rejects the empty string" do
      refute Meetings.app_registered_room?("")
    end

    test "rejects space- with a non-uuid suffix" do
      refute Meetings.app_registered_room?("space-not-a-uuid")
      refute Meetings.app_registered_room?("space-1234")
    end

    test "rejects the predecessor meeting-<uuid> naming" do
      uuid = Ecto.UUID.generate()
      refute Meetings.app_registered_room?("meeting-#{uuid}")
    end

    test "rejects non-binary inputs without raising" do
      refute Meetings.app_registered_room?(nil)
      refute Meetings.app_registered_room?(42)
      refute Meetings.app_registered_room?(:atom)
    end

    test "matches every room name produced by room_name_for_space/1" do
      space_id = Ecto.UUID.generate()
      name = Meetings.room_name_for_space(space_id)
      assert Meetings.app_registered_room?(name)
    end
  end

  describe "legit_room?/1 (task 019f3312 stage 1)" do
    # `legit_room?/1` is the tightened successor to `app_registered_room?/1`
    # for the LiveKit webhook hot path. Regex + chat_spaces existence
    # check closes the "well-formed `space-<uuid>` name pointing at a
    # non-existent space" attack observed in the phantom-flood incident
    # (curl-forged webhook deliveries with UUIDs that no Suite space had
    # ever registered).

    defp create_chat_space! do
      {:ok, space} =
        Chat.create_space(%{
          name: "Legit Room Test Space",
          slug: "legit-room-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      space
    end

    test "returns true for a payload whose name matches a real chat_space" do
      space = create_chat_space!()
      name = Meetings.room_name_for_space(space.id)

      assert Meetings.legit_room?(%{"name" => name, "sid" => "RM_anything"})
    end

    test "returns true even without sid when the name resolves" do
      space = create_chat_space!()
      name = Meetings.room_name_for_space(space.id)

      assert Meetings.legit_room?(%{"name" => name})
    end

    test "returns false for a well-formed space-<uuid> with NO matching chat_space" do
      # Bug 2 fix: the old regex-only guard accepted these. Attacker
      # curl'd exactly this shape (well-formed random UUID) at prod and
      # spawned phantom transcripts en masse.
      fake_uuid = Ecto.UUID.generate()

      refute Meetings.legit_room?(%{
               "name" => "space-#{fake_uuid}",
               "sid" => "RM_forged_by_attacker"
             })
    end

    test "returns false for LiveKit auto-generated RM_<random> names" do
      refute Meetings.legit_room?(%{"name" => "RM_26KcSg8ZBUGd", "sid" => "RM_26KcSg8ZBUGd"})
    end

    test "returns false for space- with a non-uuid suffix" do
      refute Meetings.legit_room?(%{"name" => "space-not-a-uuid", "sid" => "RM_x"})
      refute Meetings.legit_room?(%{"name" => "space-1234", "sid" => "RM_x"})
    end

    test "returns false for the predecessor meeting-<uuid> naming" do
      # Even if a chat_space happens to exist with the same UUID, the
      # `meeting-` prefix is not the app-controlled contract.
      space = create_chat_space!()
      refute Meetings.legit_room?(%{"name" => "meeting-#{space.id}", "sid" => "RM_x"})
    end

    test "returns false when name is missing entirely" do
      refute Meetings.legit_room?(%{"sid" => "RM_only_sid"})
    end

    test "returns false when name is nil" do
      refute Meetings.legit_room?(%{"name" => nil, "sid" => "RM_x"})
    end

    test "returns false for malformed / non-map payloads" do
      refute Meetings.legit_room?(nil)
      refute Meetings.legit_room?("space-abc")
      refute Meetings.legit_room?(%{})
      refute Meetings.legit_room?(42)
    end

    test "reproduces the investigator's curl payload — bogus name, no space" do
      # Reproduction of the exact attacker payload shape from the
      # investigator's report — a `space-<random-uuid>` that no Suite
      # space had ever registered. The regex-only guard accepted this;
      # the tightened guard rejects it.
      curl_payload = %{
        "name" => "space-00000000-0000-0000-0000-000000000000",
        "sid" => "RM_curl_repro"
      }

      refute Meetings.legit_room?(curl_payload)
    end
  end

  describe "delete_transcript/1" do
    defp create_transcript(overrides \\ %{}) do
      attrs =
        Map.merge(
          %{room_id: "space-#{Ecto.UUID.generate()}", status: "recording"},
          overrides
        )

      {:ok, transcript} = Meetings.create_transcript(attrs)
      transcript
    end

    test "deletes an existing transcript struct" do
      transcript = create_transcript()

      assert {:ok, deleted} = Meetings.delete_transcript(transcript)
      assert deleted.id == transcript.id
      assert Meetings.get_transcript(transcript.id) == nil
    end

    test "deletes by string id" do
      transcript = create_transcript()

      assert {:ok, deleted} = Meetings.delete_transcript(transcript.id)
      assert deleted.id == transcript.id
      assert Meetings.get_transcript(transcript.id) == nil
    end

    test "returns {:error, :not_found} for an unknown uuid" do
      missing_id = Ecto.UUID.generate()
      assert Meetings.delete_transcript(missing_id) == {:error, :not_found}
    end

    test "returns {:error, :not_found} for a malformed id string" do
      assert Meetings.delete_transcript("not-a-uuid") == {:error, :not_found}
    end

    test "is idempotent — second delete returns :not_found" do
      transcript = create_transcript()

      assert {:ok, _} = Meetings.delete_transcript(transcript.id)
      assert Meetings.delete_transcript(transcript.id) == {:error, :not_found}
    end

    test "deleting a stale struct after the row is gone returns :not_found" do
      transcript = create_transcript()
      assert {:ok, _} = Meetings.delete_transcript(transcript)

      # `transcript` is now a stale struct pointing at a row that no
      # longer exists — the cleanup handler can plausibly call this
      # twice under retry.
      assert Meetings.delete_transcript(transcript) == {:error, :not_found}
    end

    test "matches the declared return spec — {:ok, %Transcript{}} on success" do
      transcript = create_transcript()
      assert {:ok, %Transcript{}} = Meetings.delete_transcript(transcript)
    end
  end

  describe "stamp_router_dispatched/1 (task 019f2566 stage 1)" do
    defp create_processing_transcript do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "processing"
        })

      transcript
    end

    test "sets router_dispatched_at to a UTC datetime on the matching row" do
      transcript = create_processing_transcript()
      assert is_nil(transcript.router_dispatched_at)

      before = DateTime.utc_now()
      assert {1, nil} = Meetings.stamp_router_dispatched(transcript.id)
      later = DateTime.utc_now()

      reloaded = Meetings.get_transcript(transcript.id)
      assert %DateTime{} = reloaded.router_dispatched_at

      # Stamped time falls within the call window.
      assert DateTime.compare(reloaded.router_dispatched_at, before) in [:eq, :gt]
      assert DateTime.compare(reloaded.router_dispatched_at, later) in [:eq, :lt]
    end

    test "returns {0, nil} for an unknown transcript id" do
      missing_id = Ecto.UUID.generate()
      assert {0, nil} = Meetings.stamp_router_dispatched(missing_id)
    end

    test "second call re-stamps to a newer timestamp" do
      transcript = create_processing_transcript()

      assert {1, nil} = Meetings.stamp_router_dispatched(transcript.id)
      first = Meetings.get_transcript(transcript.id).router_dispatched_at

      # Force a monotonic gap so the re-stamp is strictly newer.
      Process.sleep(2)

      assert {1, nil} = Meetings.stamp_router_dispatched(transcript.id)
      second = Meetings.get_transcript(transcript.id).router_dispatched_at

      assert DateTime.compare(second, first) == :gt
    end
  end

  describe "list_stalled_router_dispatches/1 (task 019f2566 stage 2)" do
    defp create_stalled_transcript(offset_ms) do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "processing"
        })

      {1, nil} =
        Platform.Repo.update_all(
          from(t in Transcript, where: t.id == ^transcript.id),
          set: [router_dispatched_at: DateTime.add(DateTime.utc_now(), offset_ms, :millisecond)]
        )

      Meetings.get_transcript(transcript.id)
    end

    test "returns processing transcripts whose router_dispatched_at is older than the window" do
      stale = create_stalled_transcript(-500)
      _fresh = create_stalled_transcript(-50)

      results = Meetings.list_stalled_router_dispatches(200)

      assert Enum.any?(results, &(&1.id == stale.id))
      refute Enum.empty?(results)
    end

    test "excludes fresh dispatches (within the window)" do
      fresh = create_stalled_transcript(-50)

      results = Meetings.list_stalled_router_dispatches(200)

      refute Enum.any?(results, &(&1.id == fresh.id))
    end

    test "excludes transcripts whose status is not processing" do
      {:ok, done} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "complete",
          summary: "ok"
        })

      {1, nil} =
        Platform.Repo.update_all(
          from(t in Transcript, where: t.id == ^done.id),
          set: [router_dispatched_at: DateTime.add(DateTime.utc_now(), -600, :millisecond)]
        )

      results = Meetings.list_stalled_router_dispatches(200)

      refute Enum.any?(results, &(&1.id == done.id))
    end

    test "excludes transcripts whose router_dispatched_at IS NULL" do
      # Stage 2 covers "router fired but stalled" only. A transcript
      # with NULL router_dispatched_at means the router never fired —
      # the belt-and-braces path is deferred to a later stage.
      {:ok, never_dispatched} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "processing"
        })

      results = Meetings.list_stalled_router_dispatches(200)

      refute Enum.any?(results, &(&1.id == never_dispatched.id))
    end

    test "returns an empty list when no dispatches are stalled" do
      _fresh = create_stalled_transcript(-50)

      assert Meetings.list_stalled_router_dispatches(1_000) == []
    end
  end

  describe "append_segment/2 — transcript_chunk broadcast (task 019f2452 stage 2)" do
    defp make_segment(text \\ "hello world") do
      %{
        "participant_identity" => "user-1",
        "text" => text,
        "start_time" => 0,
        "end_time" => 500
      }
    end

    defp make_transcript_for_room(room_id \\ nil) do
      room_id = room_id || "space-#{Ecto.UUID.generate()}"
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id, status: "recording"})
      transcript
    end

    test "canonical subscriber receives a :transcript_chunk event after append" do
      transcript = make_transcript_for_room()
      segment = make_segment()
      transcript_id = transcript.id
      room_id = transcript.room_id

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()

      assert {:ok, %Transcript{}} = Meetings.append_segment(transcript.id, segment)

      assert_receive {:transcript_chunk,
                      %{
                        room_id: ^room_id,
                        transcript_id: ^transcript_id,
                        segment: ^segment,
                        meeting_id: nil
                      }},
                     200

      MeetingsPubSub.unsubscribe_transcript_chunk()
    end

    test "per-room subscriber receives its own room's chunk" do
      transcript = make_transcript_for_room()
      segment = make_segment("per-room hello")
      transcript_id = transcript.id
      room_id = transcript.room_id

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk(room_id)

      assert {:ok, %Transcript{}} = Meetings.append_segment(transcript.id, segment)

      assert_receive {:transcript_chunk,
                      %{
                        room_id: ^room_id,
                        transcript_id: ^transcript_id,
                        segment: ^segment,
                        meeting_id: nil
                      }},
                     200

      MeetingsPubSub.unsubscribe_transcript_chunk(room_id)
    end

    test "per-room subscriber does NOT receive events from a different room" do
      transcript_a = make_transcript_for_room()
      transcript_b = make_transcript_for_room()

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk(transcript_a.room_id)

      assert {:ok, %Transcript{}} =
               Meetings.append_segment(transcript_b.id, make_segment("wrong room"))

      refute_receive {:transcript_chunk, _}, 100

      MeetingsPubSub.unsubscribe_transcript_chunk(transcript_a.room_id)
    end

    test "returns {:error, :not_found} for a missing transcript and does NOT broadcast" do
      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()

      assert {:error, :not_found} =
               Meetings.append_segment(Ecto.UUID.generate(), make_segment())

      refute_receive {:transcript_chunk, _}, 100

      MeetingsPubSub.unsubscribe_transcript_chunk()
    end

    test "canonical + per-room subscribers both receive the same event" do
      transcript = make_transcript_for_room()
      segment = make_segment("dual delivery")
      transcript_id = transcript.id
      room_id = transcript.room_id

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()
      assert :ok = MeetingsPubSub.subscribe_transcript_chunk(room_id)

      assert {:ok, %Transcript{}} = Meetings.append_segment(transcript.id, segment)

      # Two deliveries (one per subscription).
      assert_receive {:transcript_chunk,
                      %{
                        room_id: ^room_id,
                        transcript_id: ^transcript_id,
                        segment: ^segment,
                        meeting_id: nil
                      }},
                     200

      assert_receive {:transcript_chunk,
                      %{
                        room_id: ^room_id,
                        transcript_id: ^transcript_id,
                        segment: ^segment,
                        meeting_id: nil
                      }},
                     200

      MeetingsPubSub.unsubscribe_transcript_chunk()
      MeetingsPubSub.unsubscribe_transcript_chunk(room_id)
    end
  end

  describe "post_fallback_notice/3 (task 019f2566 stage 5)" do
    defp create_execution_space! do
      {:ok, space} = Chat.create_space(%{kind: "execution"})
      space
    end

    defp find_fallback_notice(space_id, transcript_id) do
      space_id
      |> Chat.list_messages()
      |> Kernel.||([])
      |> Enum.find(fn m ->
        m.metadata["source"] == "meeting_summarizer_fallback" and
          m.metadata["transcript_id"] == transcript_id
      end)
    end

    test "posts a system message naming the previously-assigned agent slug" do
      space = create_execution_space!()
      transcript_id = Platform.Types.UUIDv7.generate()

      assert :ok =
               Meetings.post_fallback_notice(space.id, transcript_id, %{
                 previously_assigned_agent: "scribe-alpha",
                 stalled_for_ms: 12 * 60 * 1_000
               })

      msg = find_fallback_notice(space.id, transcript_id)
      assert msg, "expected a fallback notice message in the space"
      assert msg.content_type == "system"
      # Legacy `@slug` mention — decorated as-highlighted by ContentRenderer.
      assert msg.content =~ "@scribe-alpha"
      # Human-readable stall window renders in minutes for a 12-minute stall.
      assert msg.content =~ "12 minutes"
      # Deep-link to Control Center → Roles so operators can reassign fast.
      assert msg.content =~ "/control-center/roles"
      # Metadata mirrors the notice for downstream audit consumers.
      assert msg.metadata["mode"] == "completed"
      assert msg.metadata["previously_assigned_agent"] == "scribe-alpha"
    end

    test "degrades gracefully when previously_assigned_agent is nil" do
      space = create_execution_space!()
      transcript_id = Platform.Types.UUIDv7.generate()

      assert :ok =
               Meetings.post_fallback_notice(space.id, transcript_id, %{
                 previously_assigned_agent: nil,
                 stalled_for_ms: 60 * 60 * 1_000
               })

      msg = find_fallback_notice(space.id, transcript_id)
      assert msg
      assert msg.content =~ "The assigned summarizer"
      refute msg.content =~ "@"
      assert msg.content =~ "1 hour"
    end

    test "uses the `also_failed` copy when mode is :also_failed" do
      space = create_execution_space!()
      transcript_id = Platform.Types.UUIDv7.generate()

      assert :ok =
               Meetings.post_fallback_notice(space.id, transcript_id, %{
                 previously_assigned_agent: "scribe-beta",
                 stalled_for_ms: 90 * 60 * 1_000,
                 mode: :also_failed
               })

      msg = find_fallback_notice(space.id, transcript_id)
      assert msg
      assert msg.content =~ "Summary fallback also failed"
      assert msg.content =~ "@scribe-beta"
      # 90 minutes → "1 hour" rounding is fine; the important assertion is
      # the shape of the "also failed" copy and its link back to Roles.
      assert msg.content =~ "/control-center/roles"
      assert msg.metadata["mode"] == "also_failed"
    end

    test "returns {:error, ...} for a space that does not exist" do
      transcript_id = Platform.Types.UUIDv7.generate()

      assert {:error, _} =
               Meetings.post_fallback_notice(Ecto.UUID.generate(), transcript_id, %{
                 previously_assigned_agent: "scribe-gamma",
                 stalled_for_ms: 1_000
               })
    end

    test "renders sub-minute stalls in seconds" do
      space = create_execution_space!()
      transcript_id = Platform.Types.UUIDv7.generate()

      assert :ok =
               Meetings.post_fallback_notice(space.id, transcript_id, %{
                 previously_assigned_agent: "scribe-delta",
                 stalled_for_ms: 47_000
               })

      msg = find_fallback_notice(space.id, transcript_id)
      assert msg
      assert msg.content =~ "47 seconds"
    end
  end

  describe "verify_livekit_jwt/2 (task 019f3312 stage 2)" do
    alias Platform.LivekitTestHelpers

    setup do
      prev_livekit = Application.get_env(:platform, :livekit)

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: LivekitTestHelpers.default_secret()
      )

      on_exit(fn ->
        case prev_livekit do
          nil -> Application.delete_env(:platform, :livekit)
          v -> Application.put_env(:platform, :livekit, v)
        end
      end)

      :ok
    end

    test "returns :ok for a freshly-signed payload" do
      body = Jason.encode!(%{"event" => "room_started"})
      {body, jwt} = LivekitTestHelpers.sign_livekit_payload(body)

      assert :ok = Meetings.verify_livekit_jwt(jwt, body)
    end

    test "returns {:error, :missing_secret} when LIVEKIT_API_SECRET is unset" do
      Application.put_env(:platform, :livekit, api_key: "x", api_secret: nil)

      body = Jason.encode!(%{"event" => "room_started"})
      {body, jwt} = LivekitTestHelpers.sign_livekit_payload(body)

      assert {:error, :missing_secret} = Meetings.verify_livekit_jwt(jwt, body)
    end

    test "returns {:error, :malformed} for nil / empty / non-triple tokens" do
      assert {:error, :malformed} = Meetings.verify_livekit_jwt(nil, "")
      assert {:error, :malformed} = Meetings.verify_livekit_jwt("", "")
      assert {:error, :malformed} = Meetings.verify_livekit_jwt("abc.def", "")
      assert {:error, :malformed} = Meetings.verify_livekit_jwt("not-a-jwt", "")
    end

    test "returns {:error, :bad_signature} when HS256 doesn't verify" do
      body = Jason.encode!(%{"event" => "room_started"})
      {body, jwt} = LivekitTestHelpers.sign_livekit_payload(body)

      [h, p, s] = String.split(jwt, ".", parts: 3)

      flipped =
        String.slice(s, 0..-2//1) <>
          if String.last(s) == "A", do: "B", else: "A"

      tampered = Enum.join([h, p, flipped], ".")
      assert {:error, :bad_signature} = Meetings.verify_livekit_jwt(tampered, body)
    end

    test "returns {:error, :body_hash_mismatch} when body doesn't match sha256 claim" do
      original = Jason.encode!(%{"event" => "room_started", "room" => %{"name" => "a"}})
      {_original, jwt} = LivekitTestHelpers.sign_livekit_payload(original)

      tampered = Jason.encode!(%{"event" => "room_started", "room" => %{"name" => "b"}})
      assert {:error, :body_hash_mismatch} = Meetings.verify_livekit_jwt(jwt, tampered)
    end

    test "returns {:error, :expired} when exp is in the past" do
      body = Jason.encode!(%{"event" => "room_started"})
      body_hash = :crypto.hash(:sha256, body) |> Base.encode64()

      past = System.system_time(:second) - 60

      claims = %{
        "iss" => "test-livekit-key",
        "nbf" => past - 60,
        "exp" => past,
        "sha256" => body_hash
      }

      jwt = Meetings.encode_jwt(claims, LivekitTestHelpers.default_secret())
      assert {:error, :expired} = Meetings.verify_livekit_jwt(jwt, body)
    end

    test "returns {:error, :malformed} when exp is missing" do
      body = Jason.encode!(%{"event" => "room_started"})
      body_hash = :crypto.hash(:sha256, body) |> Base.encode64()

      # No `exp` claim.
      claims = %{"iss" => "test-livekit-key", "sha256" => body_hash}
      jwt = Meetings.encode_jwt(claims, LivekitTestHelpers.default_secret())
      assert {:error, :malformed} = Meetings.verify_livekit_jwt(jwt, body)
    end
  end

  # ── Shared guest-invite resolver (task 019f498d stage 2) ─────────────────
  #
  # `resolve_guest_invite/2` is the single place `PlatformWeb.MeetingLive`
  # (with `chrome_mode: :none` on the `meet.` host) branches the invite
  # token into `{name_entry, in_meeting, expired, invalid}`. Pinning each
  # branch here keeps the guest ingress from drifting from what the
  # context returns.
  describe "resolve_guest_invite/2 (task 019f498d stage 2)" do
    alias Platform.Meetings.GuestInvite
    alias Platform.Meetings.Meeting
    alias Platform.Tasks

    # The resolver never mints a LiveKit token — it only verifies the
    # HMAC + does a slug lookup — so it does not depend on the
    # `Application.put_env(:platform, :livekit, ...)` global. That means
    # this describe can stay in the `async: true` module without
    # racing other tests that mutate the livekit config.

    defp create_project! do
      org_id = Platform.TenancyFixtures.fabrikam_org_id()

      {:ok, project} =
        Tasks.create_project(%{
          name: "Guest Invite Resolver Project #{System.unique_integer([:positive])}",
          org_id: org_id
        })

      project
    end

    defp create_meeting!(attrs \\ %{}) do
      project = Map.get_lazy(attrs, :project, fn -> create_project!() end)
      name = Map.get(attrs, :name, "Guest Kickoff #{System.unique_integer([:positive])}")

      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
      Platform.Repo.preload(meeting, :chat_space)
    end

    test "returns :in_meeting with preloaded chat_space when token carries a display_name" do
      meeting = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      assert {:ok, %{state: :in_meeting, meeting: resolved, display_name: "Juno Fairbanks"}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      assert %Meeting{} = resolved
      assert resolved.id == meeting.id
      # `:chat_space` must be preloaded — downstream `guest_join_event_payload/2`
      # reads `meeting.chat_space.slug` and would blow up on a NotLoaded assoc.
      assert %Chat.Space{} = resolved.chat_space
    end

    test "returns :name_entry when token payload carries nil display_name" do
      meeting = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      assert {:ok, %{state: :name_entry, meeting: resolved}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      assert resolved.id == meeting.id
      assert %Chat.Space{} = resolved.chat_space
    end

    test "returns {:error, :expired} for a past-expiry token" do
      meeting = create_meeting!()
      # 60s in the past → GuestInvite.verify returns {:error, :expired}.
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")

      assert {:error, :expired} = Meetings.resolve_guest_invite(meeting.slug, token)
    end

    test "returns {:error, :invalid} when the HMAC signature is tampered" do
      meeting = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Juno Fairbanks")
      # Flip a byte early in the token so the signature check fails.
      tampered = String.replace(token, ~r/./, "X", global: false)

      assert {:error, :invalid} = Meetings.resolve_guest_invite(meeting.slug, tampered)
    end

    test "returns {:error, :invalid} when URL slug differs from payload slug" do
      meeting_a = create_meeting!()
      meeting_b = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      # Token signed against meeting_a, then hit at meeting_b's URL.
      token = GuestInvite.sign(meeting_a.slug, expires_at, "Juno Fairbanks")

      assert {:error, :invalid} = Meetings.resolve_guest_invite(meeting_b.slug, token)
    end

    test "returns {:error, :invalid} when the payload slug no longer resolves to a meeting" do
      # Sign for a slug that has no Meeting row (deleted-after-issue).
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      slug = "ghost-meeting-#{System.unique_integer([:positive])}"
      token = GuestInvite.sign(slug, expires_at, "Juno Fairbanks")

      assert {:error, :invalid} = Meetings.resolve_guest_invite(slug, token)
    end

    test "returns {:error, :invalid} for a completely malformed token string" do
      # Not a Plug.Crypto-signed token at all.
      assert {:error, :invalid} =
               Meetings.resolve_guest_invite("some-meeting", "definitely-not-a-token")
    end
  end

  # ── mint_guest_join_bundle/2 (task 019f498d stage 2) ─────────────────────
  #
  # Thin alias over `guest_livekit_token/2` so downstream callers can
  # standardise on the "mint bundle" verb. The full success-shape
  # (`{:ok, bundle}`) contract is covered by `guest_token_test.exs`
  # (an `async: false` module that mutates `Application.put_env(:platform,
  # :livekit, ...)` safely) — the same code path is exercised end-to-end
  # via `PlatformWeb.MeetingLive.mount/3`'s guest branch (chrome_mode:
  # :none), which calls `mint_guest_join_bundle/2` under the hood.
  #
  # We pin only the failure branches here — those don't require
  # LiveKit env, so they're safe under `async: true`.
  describe "mint_guest_join_bundle/2 (task 019f498d stage 2)" do
    alias Platform.Meetings.Meeting
    alias Platform.Tasks

    defp create_bundle_meeting! do
      org_id = Platform.TenancyFixtures.fabrikam_org_id()

      {:ok, project} =
        Tasks.create_project(%{
          name: "Bundle Alias Project #{System.unique_integer([:positive])}",
          org_id: org_id
        })

      {:ok, meeting} =
        Meetings.create_meeting(%{project_id: project.id, name: "Bundle Kickoff"})

      Platform.Repo.preload(meeting, :chat_space)
    end

    test "propagates {:error, :missing_display_name} for an empty display name" do
      meeting = create_bundle_meeting!()

      assert {:error, :missing_display_name} =
               Meetings.mint_guest_join_bundle(meeting, "")
    end

    test "propagates {:error, :missing_display_name} for a whitespace-only display name" do
      meeting = create_bundle_meeting!()

      assert {:error, :missing_display_name} =
               Meetings.mint_guest_join_bundle(meeting, "   ")
    end

    test "propagates {:error, :missing_display_name} for a nil display name" do
      meeting = create_bundle_meeting!()

      # `guest_livekit_token/2`'s catch-all clause returns this for any
      # non-binary — the alias must forward it unchanged.
      assert {:error, :missing_display_name} =
               Meetings.mint_guest_join_bundle(meeting, nil)
    end
  end

  # ── guest_join_event_payload/2 (task 019f498d stage 2) ───────────────────
  #
  # Payload shape MeetingClient's phx-hook consumes. Load-bearing keys
  # are `:token` + `:url`; the rest are surfaced for parity + debug.
  describe "guest_join_event_payload/2 (task 019f498d stage 2)" do
    alias Platform.Meetings.Meeting
    alias Platform.Tasks

    defp create_payload_meeting! do
      org_id = Platform.TenancyFixtures.fabrikam_org_id()

      {:ok, project} =
        Tasks.create_project(%{
          name: "Payload Shape Project #{System.unique_integer([:positive])}",
          org_id: org_id
        })

      {:ok, meeting} =
        Meetings.create_meeting(%{project_id: project.id, name: "Payload Kickoff"})

      Platform.Repo.preload(meeting, :chat_space)
    end

    test "maps bundle -> push_event map with token/url/room_name/space_slug" do
      meeting = create_payload_meeting!()

      bundle = %{
        token: "jwt.payload.signature",
        identity: "guest:abc",
        room_name: "space-#{meeting.chat_space_id}",
        livekit_url: "wss://livekit.test"
      }

      payload = Meetings.guest_join_event_payload(bundle, meeting)

      assert payload.token == bundle.token
      assert payload.url == bundle.livekit_url
      assert payload.room_name == bundle.room_name
      assert payload.space_slug == meeting.chat_space.slug
    end

    test "space_slug is nil when the meeting's chat_space is nil" do
      meeting = %Meeting{
        id: Ecto.UUID.generate(),
        name: "No-space Meeting",
        chat_space_id: nil,
        chat_space: nil
      }

      bundle = %{
        token: "t",
        identity: "guest:x",
        room_name: "space-none",
        livekit_url: nil
      }

      payload = Meetings.guest_join_event_payload(bundle, meeting)
      assert payload.space_slug == nil
      assert payload.url == nil
    end
  end
end
