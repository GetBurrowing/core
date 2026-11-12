defmodule Platform.SwitcherTest do
  @moduledoc """
  Task 01a1ccd4 stage 2: badge keys for the web install switcher. Origin
  normalization, mint / verify / revoke / expiry and the unread payload.
  """
  use Platform.DataCase, async: true

  import Platform.ExternalUserFixtures

  alias Platform.Accounts
  alias Platform.Repo
  alias Platform.Switcher
  alias Platform.Switcher.BadgeKey

  @a "https://a.example"

  describe "normalize_origin/1" do
    test "accepts https origins and normalizes case and default ports" do
      assert Switcher.normalize_origin("https://a.example") == {:ok, "https://a.example"}
      assert Switcher.normalize_origin("HTTPS://A.Example") == {:ok, "https://a.example"}
      assert Switcher.normalize_origin("https://a.example:443") == {:ok, "https://a.example"}

      assert Switcher.normalize_origin("https://a.example:8443") ==
               {:ok, "https://a.example:8443"}

      assert Switcher.normalize_origin("https://burrow.team-1.example.co") ==
               {:ok, "https://burrow.team-1.example.co"}
    end

    test "http only for localhost, *.localhost and 127.0.0.1" do
      assert Switcher.normalize_origin("http://localhost:4000") == {:ok, "http://localhost:4000"}

      assert Switcher.normalize_origin("http://b.localhost:4001") ==
               {:ok, "http://b.localhost:4001"}

      assert Switcher.normalize_origin("http://127.0.0.1:4000") == {:ok, "http://127.0.0.1:4000"}
      assert Switcher.normalize_origin("http://localhost") == {:ok, "http://localhost"}
      assert Switcher.normalize_origin("http://a.example") == {:error, :invalid_origin}

      assert Switcher.normalize_origin("http://localhost.evil.example") ==
               {:error, :invalid_origin}

      assert Switcher.normalize_origin("http://127.0.0.2") == {:error, :invalid_origin}
    end

    test "refuses paths, queries, fragments, userinfo, other schemes and junk" do
      for bad <- [
            "https://a.example/",
            "https://a.example/switcher",
            "https://a.example?x=1",
            "https://a.example#x",
            "https://user@a.example",
            "https://user:pw@a.example",
            "javascript:alert(1)",
            "data:text/html,hi",
            "ftp://a.example",
            "wss://a.example",
            "//a.example",
            "a.example",
            "https:a.example",
            "https:/a.example",
            "https://",
            "https://a.example\\@evil.example",
            "https://a.exa mple",
            " https://a.example",
            "https://a.example\n",
            "https://a_b.example",
            "https://a.example.",
            "https://[::1]",
            "",
            "null",
            "https://" <> String.duplicate("a", 300) <> ".example",
            nil,
            123,
            ["https://a.example"]
          ] do
        assert Switcher.normalize_origin(bad) == {:error, :invalid_origin}, inspect(bad)
      end
    end
  end

  describe "mint/3 and verify/3" do
    setup do
      %{user: create_user!()}
    end

    test "a minted key verifies for its own origin only, and is stored hashed", %{user: user} do
      assert {:ok, %{token: token, key: key}} = Switcher.mint(user, @a)
      assert "bk_" <> _ = token
      assert key.bound_origin == @a
      assert key.label == "a.example"
      assert key.token_hash == :crypto.hash(:sha256, token)
      refute Repo.get!(BadgeKey, key.id).token_hash == token

      assert {:ok, %{id: user_id}, %{id: key_id}} = Switcher.verify(token, @a)
      assert {user_id, key_id} == {user.id, key.id}
      # The request Origin is normalized before comparison.
      assert {:ok, _, _} = Switcher.verify(token, "HTTPS://A.EXAMPLE:443")

      assert Switcher.verify(token, "https://b.example") == :error
      assert Switcher.verify(token, "https://a.example:8443") == :error
      assert Switcher.verify(token, "https://sub.a.example") == :error
      assert Switcher.verify(token, nil) == :error
      assert Switcher.verify(token, "not an origin") == :error
      assert Switcher.verify("bk_unknown", @a) == :error
      assert Switcher.verify("", @a) == :error
      assert Switcher.verify(nil, @a) == :error
    end

    test "expires 90 days after minting", %{user: user} do
      minted = ~U[2026-11-01 00:00:00.000000Z]
      {:ok, %{token: token, key: key}} = Switcher.mint(user, @a, now: minted)

      assert DateTime.diff(key.expires_at, minted, :day) == 90
      assert {:ok, _, _} = Switcher.verify(token, @a, now: DateTime.add(minted, 89, :day))
      assert Switcher.verify(token, @a, now: key.expires_at) == :error
      assert Switcher.verify(token, @a, now: DateTime.add(minted, 91, :day)) == :error
      assert Switcher.list_for_user(user, now: DateTime.add(minted, 91, :day)) == []
    end

    test "revoke/2 stops the key, and only its owner can revoke it", %{user: user} do
      other = create_user!()
      {:ok, %{token: token, key: key}} = Switcher.mint(user, @a)

      assert Switcher.revoke(other, key.id) == {:error, :not_found}
      assert {:ok, _, _} = Switcher.verify(token, @a)

      assert {:ok, %BadgeKey{revoked_at: %DateTime{}}} = Switcher.revoke(user, key.id)
      assert Switcher.verify(token, @a) == :error
      assert Switcher.revoke(user, key.id) == {:error, :not_found}
      assert Switcher.revoke(user, "not-a-uuid") == {:error, :not_found}
      assert Switcher.list_for_user(user) == []
    end

    test "minting again for the same origin revokes the older key", %{user: user} do
      {:ok, %{token: first}} = Switcher.mint(user, @a)
      {:ok, %{token: second, key: key}} = Switcher.mint(user, @a)
      {:ok, %{key: other}} = Switcher.mint(user, "https://c.example")

      assert Switcher.verify(first, @a) == :error
      assert {:ok, _, _} = Switcher.verify(second, @a)

      assert user |> Switcher.list_for_user() |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([key.id, other.id])
    end

    test "an archived user's key does not verify", %{user: user} do
      {:ok, %{token: token}} = Switcher.mint(user, @a)
      {:ok, _} = Accounts.archive_user(user)
      assert Switcher.verify(token, @a) == :error
    end

    test "an invalid origin mints nothing", %{user: user} do
      assert Switcher.mint(user, "https://a.example/path") == {:error, :invalid_origin}
      assert Switcher.mint(user, "http://a.example") == {:error, :invalid_origin}
      assert Repo.aggregate(BadgeKey, :count) == 0
    end

    test "a badge key is not an app_sessions bearer", %{user: user} do
      {:ok, %{token: token}} = Switcher.mint(user, @a)
      assert Platform.Mobile.verify_bearer(token) == :error
    end
  end

  test "unread_payload/1 is exactly unread and as_of" do
    payload = Switcher.unread_payload(create_user!())
    assert payload |> Map.keys() |> Enum.sort() == [:as_of, :unread]
    assert is_integer(payload.unread)
    assert {:ok, _, 0} = DateTime.from_iso8601(payload.as_of)
  end
end
