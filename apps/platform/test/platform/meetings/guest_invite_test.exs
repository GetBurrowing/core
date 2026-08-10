defmodule Platform.Meetings.GuestInviteTest do
  # Not async: the `:meeting_guest_host` describe block mutates
  # application env, which is global state shared with every other
  # concurrently-running test.
  use ExUnit.Case, async: false

  alias Platform.Meetings.GuestInvite

  defp future_ts(seconds_ahead) do
    DateTime.utc_now()
    |> DateTime.to_unix()
    |> Kernel.+(seconds_ahead)
  end

  defp past_ts(seconds_behind) do
    DateTime.utc_now()
    |> DateTime.to_unix()
    |> Kernel.-(seconds_behind)
  end

  describe "sign/3 + verify/2 — happy paths" do
    test "roundtrips a pre-provisioned display name" do
      expires_at = future_ts(3600)
      token = GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe")

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.meeting_slug == "standup-2026-07"
      assert payload.expires_at == expires_at
      assert payload.display_name == "Jane Doe"
      # Legacy call (no guest_space_id opt) normalises to nil on verify.
      assert is_nil(payload.guest_space_id)
    end

    test "roundtrips a guest_space_id when provided" do
      expires_at = future_ts(3600)
      space_id = Ecto.UUID.generate()

      token =
        GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe", guest_space_id: space_id)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.guest_space_id == space_id
    end

    test "guest_space_id: nil roundtrips as nil" do
      expires_at = future_ts(3600)

      token =
        GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe", guest_space_id: nil)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert is_nil(payload.guest_space_id)
    end

    # ── meeting_id (task 019f9b14 stage 3) ───────────────────────────────
    #
    # The token is a legitimate bearer capability, but `meeting_slug` alone
    # does not identify a meeting: slug is unique per project, not globally.
    # `meeting_id` pins the subject. It is optional in verify for exactly
    # the same reason `guest_space_id` is — tokens already in the wild must
    # keep working until they expire.

    test "roundtrips a meeting_id when provided" do
      expires_at = future_ts(3600)
      meeting_id = Ecto.UUID.generate()

      token =
        GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe", meeting_id: meeting_id)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.meeting_id == meeting_id
    end

    test "a legacy token minted without meeting_id still verifies and yields meeting_id: nil" do
      expires_at = future_ts(3600)
      space_id = Ecto.UUID.generate()

      # Exactly the pre-019f9b14 mint shape: guest_space_id but no meeting_id.
      token =
        GuestInvite.sign("standup-2026-07", expires_at, nil, guest_space_id: space_id)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert is_nil(payload.meeting_id)
      # And the rest of the payload is untouched by the new key.
      assert payload.meeting_slug == "standup-2026-07"
      assert payload.guest_space_id == space_id
      assert is_nil(payload.display_name)
    end

    test "meeting_id: nil roundtrips as nil" do
      expires_at = future_ts(3600)
      token = GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe", meeting_id: nil)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert is_nil(payload.meeting_id)
    end

    test "meeting_id and guest_space_id roundtrip together" do
      expires_at = future_ts(3600)
      meeting_id = Ecto.UUID.generate()
      space_id = Ecto.UUID.generate()

      token =
        GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe",
          guest_space_id: space_id,
          meeting_id: meeting_id
        )

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.meeting_id == meeting_id
      assert payload.guest_space_id == space_id
    end

    test "sign_with_default_expiry passes meeting_id through" do
      meeting_id = Ecto.UUID.generate()
      token = GuestInvite.sign_with_default_expiry("weekly-sync", nil, meeting_id: meeting_id)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.meeting_id == meeting_id
    end

    test "a non-binary meeting_id raises ArgumentError at sign" do
      expires_at = future_ts(3600)

      assert_raise ArgumentError, ~r/meeting_id must be a binary or nil/, fn ->
        GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe", meeting_id: 42)
      end
    end

    # ── invite_id (task 019fb954 stage 2) ────────────────────────────────
    #
    # The token binds to a `meeting_invites` ROW so a single guest can be
    # revoked without invalidating the others — an issued HMAC cannot be
    # un-issued, so the row is the only revocation surface available.
    # `verify/2` stays pure: it never checks `revoked_at` (that is
    # `Meetings.resolve_guest_invite/2`'s job), it only carries the id.
    # Optional in verify because every token minted in production today —
    # and until the create+invite UI ships — has no `invite_id`.

    test "roundtrips an invite_id when provided" do
      expires_at = future_ts(3600)
      invite_id = Ecto.UUID.generate()

      token =
        GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe", invite_id: invite_id)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.invite_id == invite_id
    end

    test "omitting the invite_id opt yields invite_id: nil" do
      expires_at = future_ts(3600)
      space_id = Ecto.UUID.generate()
      meeting_id = Ecto.UUID.generate()

      token =
        GuestInvite.sign("standup-2026-07", expires_at, nil,
          guest_space_id: space_id,
          meeting_id: meeting_id
        )

      assert {:ok, payload} = GuestInvite.verify(token)
      assert is_nil(payload.invite_id)
      # And the rest of the payload is untouched by the new key.
      assert payload.meeting_slug == "standup-2026-07"
      assert payload.guest_space_id == space_id
      assert payload.meeting_id == meeting_id
      assert is_nil(payload.display_name)
    end

    test "a genuinely legacy token whose payload OMITS the key verifies and normalises to nil" do
      # This must be hand-signed, and that is the whole point. Every token
      # `sign/4` produces now carries `invite_id:` explicitly (nil when the
      # opt is omitted), so a token minted through the module can never
      # exercise the `Map.put/3` normalisation in `verify/2` — the key is
      # already there. Only a token minted by the PREVIOUS version of this
      # module has a payload map lacking the key, and that is exactly the
      # shape sitting in every guest invite URL in the wild right now.
      #
      # Measured, not assumed: with the sign/4-minted "legacy" test above
      # as the only coverage, deleting the `Map.put(:invite_id, ...)` line
      # left the suite green. Same held for the pre-existing
      # `Map.put(:meeting_id, ...)`, whose legacy test has the identical
      # blind spot. This test is what makes both lines load-bearing.
      token =
        raw_sign(%{
          meeting_slug: "standup-2026-07",
          expires_at: future_ts(3600),
          display_name: "Jane Doe",
          guest_space_id: nil
          # no :meeting_id, no :invite_id — pre-019f9b14 / pre-019fb954
        })

      assert {:ok, payload} = GuestInvite.verify(token)
      assert Map.has_key?(payload, :invite_id)
      assert is_nil(payload.invite_id)
      assert Map.has_key?(payload, :meeting_id)
      assert is_nil(payload.meeting_id)
      assert payload.meeting_slug == "standup-2026-07"
      assert payload.display_name == "Jane Doe"
    end

    test "invite_id: nil roundtrips as nil" do
      expires_at = future_ts(3600)
      token = GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe", invite_id: nil)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert is_nil(payload.invite_id)
    end

    test "invite_id, meeting_id and guest_space_id roundtrip together" do
      expires_at = future_ts(3600)
      invite_id = Ecto.UUID.generate()
      meeting_id = Ecto.UUID.generate()
      space_id = Ecto.UUID.generate()

      token =
        GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe",
          guest_space_id: space_id,
          meeting_id: meeting_id,
          invite_id: invite_id
        )

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.invite_id == invite_id
      assert payload.meeting_id == meeting_id
      assert payload.guest_space_id == space_id
    end

    test "two invites on the same meeting yield distinct tokens carrying distinct invite_ids" do
      expires_at = future_ts(3600)
      meeting_id = Ecto.UUID.generate()
      invite_a = Ecto.UUID.generate()
      invite_b = Ecto.UUID.generate()

      token_a =
        GuestInvite.sign("standup-2026-07", expires_at, "Guest A",
          meeting_id: meeting_id,
          invite_id: invite_a
        )

      token_b =
        GuestInvite.sign("standup-2026-07", expires_at, "Guest B",
          meeting_id: meeting_id,
          invite_id: invite_b
        )

      refute token_a == token_b

      assert {:ok, payload_a} = GuestInvite.verify(token_a)
      assert {:ok, payload_b} = GuestInvite.verify(token_b)
      assert payload_a.invite_id == invite_a
      assert payload_b.invite_id == invite_b
    end

    test "sign_with_default_expiry passes invite_id through" do
      invite_id = Ecto.UUID.generate()
      token = GuestInvite.sign_with_default_expiry("weekly-sync", nil, invite_id: invite_id)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.invite_id == invite_id
    end

    test "a non-binary invite_id raises ArgumentError at sign" do
      expires_at = future_ts(3600)

      assert_raise ArgumentError, ~r/invite_id must be a binary or nil/, fn ->
        GuestInvite.sign("standup-2026-07", expires_at, "Jane Doe", invite_id: 42)
      end
    end

    test "roundtrips self-entry (display_name = nil)" do
      expires_at = future_ts(3600)
      token = GuestInvite.sign("open-mic", expires_at, nil)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.meeting_slug == "open-mic"
      assert payload.expires_at == expires_at
      assert is_nil(payload.display_name)
    end

    test "sign_with_default_expiry/2 uses ~24h expiry" do
      before_ts = future_ts(0)
      token = GuestInvite.sign_with_default_expiry("weekly-sync", "Guest Rowan")
      after_ts = future_ts(0)

      assert {:ok, payload} = GuestInvite.verify(token)
      # Expiry should be ~24h ahead of the wall clock at sign time.
      twenty_four_hours = 24 * 60 * 60
      assert payload.expires_at >= before_ts + twenty_four_hours
      assert payload.expires_at <= after_ts + twenty_four_hours
    end

    test "sign_with_default_expiry/1 with omitted display_name preserves nil through verify" do
      token = GuestInvite.sign_with_default_expiry("kick-off")
      assert {:ok, payload} = GuestInvite.verify(token)
      assert is_nil(payload.display_name)
    end
  end

  describe "verify/2 — expired token" do
    test "returns :expired when expires_at is in the past" do
      # Signed with a past expiry (but within Plug.Crypto max_age so the
      # signature envelope itself is still fresh).
      token = GuestInvite.sign("stale-invite", past_ts(60), "Jane Doe")
      assert {:error, :expired} = GuestInvite.verify(token)
    end
  end

  describe "guest_host_configured?/0" do
    setup do
      prior =
        case Application.fetch_env(:platform, :meeting_guest_host) do
          {:ok, value} -> {:set, value}
          :error -> :unset
        end

      on_exit(fn ->
        case prior do
          {:set, value} -> Application.put_env(:platform, :meeting_guest_host, value)
          :unset -> Application.delete_env(:platform, :meeting_guest_host)
        end
      end)

      :ok
    end

    test "false when the key is absent entirely" do
      Application.delete_env(:platform, :meeting_guest_host)
      refute GuestInvite.guest_host_configured?()
      assert is_nil(GuestInvite.guest_host())
    end

    test "false when the key is set to nil" do
      Application.put_env(:platform, :meeting_guest_host, nil)
      refute GuestInvite.guest_host_configured?()
    end

    test "false when the key is an empty string" do
      Application.put_env(:platform, :meeting_guest_host, "")
      refute GuestInvite.guest_host_configured?()
    end

    test "false when the key is whitespace only" do
      Application.put_env(:platform, :meeting_guest_host, "   ")
      refute GuestInvite.guest_host_configured?()
    end

    test "true for a real host, and guest_host/0 returns it verbatim" do
      Application.put_env(:platform, :meeting_guest_host, "meet.example.com")
      assert GuestInvite.guest_host_configured?()
      assert GuestInvite.guest_host() == "meet.example.com"
    end
  end

  describe "verify/2 — tampered / invalid tokens" do
    test "returns :invalid for a token with a tampered body" do
      token = GuestInvite.sign("real-meeting", future_ts(3600), "Jane Doe")

      # `Plug.Crypto.sign` produces a base64.body--base64.signature style
      # token. Tamper by flipping the last character of the body segment.
      tampered = tamper_body(token)
      refute tampered == token

      assert {:error, :invalid} = GuestInvite.verify(tampered)
    end

    test "returns :invalid for a token with a wrong signature" do
      token = GuestInvite.sign("real-meeting", future_ts(3600), "Jane Doe")

      tampered = tamper_signature(token)
      refute tampered == token

      assert {:error, :invalid} = GuestInvite.verify(tampered)
    end

    test "returns :invalid for outright garbage" do
      assert {:error, :invalid} = GuestInvite.verify("not-a-token")
    end

    test "returns :invalid for a validly-signed token whose invite_id is not a binary" do
      # `sign/4` refuses a non-binary invite_id, so this shape can only be
      # produced by something holding the signing key directly. The verify
      # guard exists for that case: a valid HMAC is not a valid payload.
      token =
        raw_sign(%{
          meeting_slug: "standup-2026-07",
          expires_at: future_ts(3600),
          display_name: "Jane Doe",
          guest_space_id: nil,
          meeting_id: nil,
          invite_id: 42
        })

      assert {:error, :invalid} = GuestInvite.verify(token)
    end
  end

  # ---------------------------------------------------------------------
  # Helpers

  # Sign an ARBITRARY payload map with the module's key and salt, bypassing
  # `sign/4`'s shape guarantees. Needed for two things `sign/4` structurally
  # cannot produce: a payload that OMITS an optional key (i.e. a token minted
  # by an older version of the module), and a payload carrying a value the
  # signer refuses (non-binary ids). Key and salt are duplicated here on
  # purpose — they are the token's wire format, and reaching through the
  # module would defeat the point.
  defp raw_sign(payload) do
    key = Application.get_env(:platform, :meeting_guest_signing_key)
    Plug.Crypto.sign(key, "meeting_guest_invite", payload)
  end

  # Plug.Crypto tokens are `header.body.signature` (three base64url
  # segments separated by `.`). We flip a character in either the body or
  # signature segment to simulate tampering.
  defp tamper_body(token) do
    [header, body, sig] = String.split(token, ".", parts: 3)
    body_tampered = flip_first_char(body)
    Enum.join([header, body_tampered, sig], ".")
  end

  defp tamper_signature(token) do
    [header, body, sig] = String.split(token, ".", parts: 3)
    sig_tampered = flip_first_char(sig)
    Enum.join([header, body, sig_tampered], ".")
  end

  defp flip_first_char(<<first::binary-size(1), rest::binary>>) do
    tampered =
      case first do
        "A" -> "B"
        _ -> "A"
      end

    tampered <> rest
  end
end
