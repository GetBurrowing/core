defmodule Platform.Meetings.GuestInviteTest do
  use ExUnit.Case, async: true

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
      token = GuestInvite.sign("standup-2026-07", expires_at, "Juno Fairbanks")

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.meeting_slug == "standup-2026-07"
      assert payload.expires_at == expires_at
      assert payload.display_name == "Juno Fairbanks"
      # Legacy call (no guest_space_id opt) normalises to nil on verify.
      assert is_nil(payload.guest_space_id)
    end

    test "roundtrips a guest_space_id when provided" do
      expires_at = future_ts(3600)
      space_id = Ecto.UUID.generate()

      token =
        GuestInvite.sign("standup-2026-07", expires_at, "Juno Fairbanks", guest_space_id: space_id)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.guest_space_id == space_id
    end

    test "guest_space_id: nil roundtrips as nil" do
      expires_at = future_ts(3600)

      token =
        GuestInvite.sign("standup-2026-07", expires_at, "Juno Fairbanks", guest_space_id: nil)

      assert {:ok, payload} = GuestInvite.verify(token)
      assert is_nil(payload.guest_space_id)
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
      token = GuestInvite.sign("stale-invite", past_ts(60), "Juno Fairbanks")
      assert {:error, :expired} = GuestInvite.verify(token)
    end
  end

  describe ":meeting_guest_host application env" do
    # Stage 5 (task 019f2483): MeetingLive's copy-link builder resolves the
    # public guest hostname via `Application.get_env(:platform,
    # :meeting_guest_host)`. Each Mix env sets a stable value in its
    # config; runtime.exs falls back to the prod default so the key is
    # always resolvable. This test asserts the env is populated so a
    # missing config in a future env swap surfaces immediately instead
    # of silently rendering a URL against the fallback.
    test "resolves to a non-empty string in the current Mix env" do
      host = Application.get_env(:platform, :meeting_guest_host)
      assert is_binary(host)
      assert host != ""
    end
  end

  describe "verify/2 — tampered / invalid tokens" do
    test "returns :invalid for a token with a tampered body" do
      token = GuestInvite.sign("real-meeting", future_ts(3600), "Juno Fairbanks")

      # `Plug.Crypto.sign` produces a base64.body--base64.signature style
      # token. Tamper by flipping the last character of the body segment.
      tampered = tamper_body(token)
      refute tampered == token

      assert {:error, :invalid} = GuestInvite.verify(tampered)
    end

    test "returns :invalid for a token with a wrong signature" do
      token = GuestInvite.sign("real-meeting", future_ts(3600), "Juno Fairbanks")

      tampered = tamper_signature(token)
      refute tampered == token

      assert {:error, :invalid} = GuestInvite.verify(tampered)
    end

    test "returns :invalid for outright garbage" do
      assert {:error, :invalid} = GuestInvite.verify("not-a-token")
    end
  end

  # ---------------------------------------------------------------------
  # Helpers

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
