defmodule Platform.Meetings.CalendarLinkTest do
  # async: false — several tests swap `Application` config (the signing
  # keys) to prove rotation is a real revocation lever. That is global
  # state, so this module must not run concurrently with anything else
  # that signs or verifies a meeting token.
  use ExUnit.Case, async: false

  alias Platform.Meetings.CalendarLink
  alias Platform.Meetings.GuestInvite

  # The salts are pinned EXACTLY, not asserted loosely, because they are
  # the decision this module records: a calendar link and a guest invite
  # must live in separate signing namespaces. A test that only round-trips
  # through the public API cannot see the salt at all — sign/1 and verify/1
  # move together, so changing `@salt` in the module under test leaves such
  # a test green. Constructing tokens directly against a literal salt is
  # what makes the choice observable.
  @calendar_salt "meeting_calendar_link"
  @guest_salt "meeting_guest_invite"

  defp calendar_key, do: Application.fetch_env!(:platform, :meeting_calendar_signing_key)
  defp guest_key, do: Application.fetch_env!(:platform, :meeting_guest_signing_key)

  defp restore_env(key) do
    original = Application.get_env(:platform, key)
    on_exit(fn -> Application.put_env(:platform, key, original) end)
    original
  end

  describe "sign/1 and verify/1" do
    test "round-trips the meeting id" do
      meeting_id = Ecto.UUID.generate()

      assert {:ok, payload} = CalendarLink.verify(CalendarLink.sign(meeting_id))
      assert payload == %{meeting_id: meeting_id}
    end

    test "the payload carries the meeting id and NOTHING else" do
      meeting_id = Ecto.UUID.generate()

      {:ok, payload} = CalendarLink.verify(CalendarLink.sign(meeting_id))

      # Equality, not a subset match: a forwarded calendar link is a bearer
      # capability over whatever the payload holds, so any extra key is
      # another fact the link discloses. This also pins the no-expiry
      # decision structurally — there is no `:expires_at` to check because
      # there is no `:expires_at` at all.
      assert payload == %{meeting_id: meeting_id}
      assert Map.keys(payload) == [:meeting_id]
    end

    test "a tampered token is invalid" do
      token = CalendarLink.sign(Ecto.UUID.generate())

      [protected, body, signature] = String.split(token, ".", parts: 3)
      tampered_body = flip_first_char(body)

      refute tampered_body == body

      assert {:error, :invalid} =
               CalendarLink.verify(Enum.join([protected, tampered_body, signature], "."))
    end

    test "a token that is not a token at all is invalid" do
      assert {:error, :invalid} = CalendarLink.verify("not-a-token")
    end
  end

  describe "namespace isolation from GuestInvite (both directions)" do
    test "a GuestInvite token does not verify as a calendar link" do
      # Minted the way production mints them (`invite_guest/2` passes
      # `meeting_id:`), which is the adversarial case: this payload WOULD
      # satisfy CalendarLink's shape guard, so only the signing namespace
      # can reject it.
      guest_token =
        GuestInvite.sign_with_default_expiry("some-meeting", "Jane Doe",
          meeting_id: Ecto.UUID.generate(),
          invite_id: Ecto.UUID.generate()
        )

      assert {:error, :invalid} = CalendarLink.verify(guest_token)
    end

    test "a calendar link token does not verify as a GuestInvite" do
      calendar_token = CalendarLink.sign(Ecto.UUID.generate())

      assert {:error, :invalid} = GuestInvite.verify(calendar_token)
    end
  end

  # The two cross-verify tests above are necessary but NOT sufficient on
  # their own: each is killed only if the salt AND the key are both shared,
  # because either separation alone already breaks the HMAC. The three
  # tests below hold one variable constant and vary the other, so a red is
  # attributable to exactly one of the two separations.
  describe "signing namespace, one variable at a time" do
    test "a token signed with the calendar key under the calendar salt verifies" do
      meeting_id = Ecto.UUID.generate()

      token = Plug.Crypto.sign(calendar_key(), @calendar_salt, %{meeting_id: meeting_id})

      assert {:ok, %{meeting_id: ^meeting_id}} = CalendarLink.verify(token)
    end

    test "the GUEST key under the calendar salt does not verify" do
      # Same salt, different key. Goes red if `signing_key/0` reads
      # `:meeting_guest_signing_key`.
      token = Plug.Crypto.sign(guest_key(), @calendar_salt, %{meeting_id: Ecto.UUID.generate()})

      assert {:error, :invalid} = CalendarLink.verify(token)
    end

    test "the calendar key under the GUEST salt does not verify" do
      # Same key, different salt. Goes red if `@salt` is changed to
      # GuestInvite's salt.
      token = Plug.Crypto.sign(calendar_key(), @guest_salt, %{meeting_id: Ecto.UUID.generate()})

      assert {:error, :invalid} = CalendarLink.verify(token)
    end
  end

  describe "key rotation is the revocation lever" do
    test "a token minted under key A fails to verify after rotation to key B" do
      restore_env(:meeting_calendar_signing_key)

      Application.put_env(
        :platform,
        :meeting_calendar_signing_key,
        "key-A-" <> String.duplicate("a", 32)
      )

      token = CalendarLink.sign(Ecto.UUID.generate())
      assert {:ok, _} = CalendarLink.verify(token)

      Application.put_env(
        :platform,
        :meeting_calendar_signing_key,
        "key-B-" <> String.duplicate("b", 32)
      )

      assert {:error, :invalid} = CalendarLink.verify(token)
    end

    test "rotating the calendar key does not invalidate guest invites" do
      restore_env(:meeting_calendar_signing_key)

      guest_token = GuestInvite.sign_with_default_expiry("some-meeting", nil)

      Application.put_env(
        :platform,
        :meeting_calendar_signing_key,
        "rotated-" <> String.duplicate("c", 32)
      )

      assert {:ok, _} = GuestInvite.verify(guest_token)
    end

    test "rotating the guest key does not invalidate calendar links" do
      restore_env(:meeting_guest_signing_key)

      calendar_token = CalendarLink.sign(Ecto.UUID.generate())

      Application.put_env(
        :platform,
        :meeting_guest_signing_key,
        "rotated-" <> String.duplicate("d", 32)
      )

      assert {:ok, _} = CalendarLink.verify(calendar_token)
    end
  end

  describe "no expiry" do
    test "a token issued years ago still verifies" do
      meeting_id = Ecto.UUID.generate()
      four_years_ago = DateTime.to_unix(DateTime.utc_now()) - 4 * 365 * 24 * 60 * 60

      # Constructed with an explicit issue time rather than by waiting:
      # `Plug.Crypto` stamps the token, and `verify/1` is what decides
      # whether that stamp can ever disqualify it. A calendar client
      # refetches this URL for as long as the event is on its calendar, so
      # a finite `max_age` here would freeze the event at its last
      # successful fetch — the ghost-event failure the endpoint exists to
      # avoid.
      token =
        Plug.Crypto.sign(calendar_key(), @calendar_salt, %{meeting_id: meeting_id},
          signed_at: four_years_ago
        )

      assert {:ok, %{meeting_id: ^meeting_id}} = CalendarLink.verify(token)
    end
  end

  describe "signing_key/0" do
    test "raises with a config hint when the key is unset" do
      restore_env(:meeting_calendar_signing_key)
      Application.delete_env(:platform, :meeting_calendar_signing_key)

      assert_raise RuntimeError, ~r/:meeting_calendar_signing_key not configured/, fn ->
        CalendarLink.sign(Ecto.UUID.generate())
      end
    end
  end

  describe "Platform.Meetings.calendar_link_path/1" do
    test "is a path with a verifying token and no host" do
      meeting_id = Ecto.UUID.generate()

      path = Platform.Meetings.calendar_link_path(%Platform.Meetings.Meeting{id: meeting_id})

      uri = URI.parse(path)

      # Equality on each component rather than a substring match on the
      # whole string: `core` is a public repo and this link must never
      # acquire a hostname, so "contains the right path" is not the
      # assertion — "is only the path" is.
      assert uri.scheme == nil
      assert uri.host == nil
      assert uri.path == "/meetings/#{meeting_id}/invite.ics"

      assert %{"token" => token} = URI.decode_query(uri.query)
      assert {:ok, %{meeting_id: ^meeting_id}} = CalendarLink.verify(token)
    end
  end

  defp flip_first_char(<<first::binary-size(1), rest::binary>>) do
    replacement = if first == "A", do: "B", else: "A"
    replacement <> rest
  end
end
