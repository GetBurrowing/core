defmodule Platform.AccountsClosedDmsTest do
  @moduledoc """
  Covers the closed-DM preference helpers: `get_closed_dm_at/1`,
  `close_dm/2`, `reopen_dm/2`.

  Storage shape: `users.preferences["closed_dm_at"] = %{"<space_uuid>" =>
  "<ISO8601>"}` managed via `Accounts.update_user_preference/3`, the same
  JSONB column `hidden_channel_ids` and `chat_section_order` already use.

  Close is only half the contract; a closed DM has to be reopenable, so the
  round-trip tests here close and then reopen in the same test. Reads fail
  open: anything that will not parse back into a `DateTime` is dropped, which
  leaves the conversation visible.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "closed_dm_#{suffix}@example.com",
      name: "Closed DM Test #{suffix}",
      oidc_sub: "oidc-closed-dm-#{suffix}",
      avatar_url: nil
    })
  end

  describe "get_closed_dm_at/1" do
    test "returns an empty map for a user with no preferences" do
      user = insert_user("empty")
      assert Accounts.get_closed_dm_at(user.id) == %{}
    end

    test "returns an empty map for an unknown user id" do
      assert Accounts.get_closed_dm_at(Ecto.UUID.generate()) == %{}
    end

    test "returns an empty map for a nil user_id (anonymous session)" do
      assert Accounts.get_closed_dm_at(nil) == %{}
    end

    test "drops a stored value that will not parse, so the DM stays visible" do
      user = insert_user("garbage")
      good = Ecto.UUID.generate()
      bad = Ecto.UUID.generate()

      {:ok, _} = Accounts.close_dm(user.id, good)

      {:ok, _} =
        Accounts.update_user_preference(
          user.id,
          "closed_dm_at",
          Map.put(
            Repo.get!(User, user.id).preferences["closed_dm_at"],
            bad,
            "yesterday-ish"
          )
        )

      closed = Accounts.get_closed_dm_at(user.id)
      assert Map.has_key?(closed, good)
      refute Map.has_key?(closed, bad)
    end

    test "returns an empty map when the stored key is not a map at all" do
      user = insert_user("wrongshape")
      {:ok, _} = Accounts.update_user_preference(user.id, "closed_dm_at", ["not", "a", "map"])

      assert Accounts.get_closed_dm_at(user.id) == %{}
    end
  end

  describe "close_dm/2 and reopen_dm/2" do
    test "round-trips: close records a timestamp, reopen removes the key" do
      user = insert_user("roundtrip")
      space_id = Ecto.UUID.generate()
      before_close = DateTime.utc_now()

      assert {:ok, _} = Accounts.close_dm(user.id, space_id)

      closed = Accounts.get_closed_dm_at(user.id)
      assert %DateTime{} = closed_at = Map.fetch!(closed, space_id)
      assert DateTime.compare(closed_at, before_close) in [:gt, :eq]
      assert DateTime.compare(closed_at, DateTime.utc_now()) in [:lt, :eq]

      assert {:ok, _} = Accounts.reopen_dm(user.id, space_id)
      assert Accounts.get_closed_dm_at(user.id) == %{}
    end

    test "persists as an ISO8601 string under preferences['closed_dm_at']" do
      user = insert_user("shape")
      space_id = Ecto.UUID.generate()

      assert {:ok, _} = Accounts.close_dm(user.id, space_id)

      stored = Repo.get!(User, user.id).preferences["closed_dm_at"]
      assert is_map(stored)
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(stored[space_id])
    end

    test "closing again overwrites the previous timestamp" do
      user = insert_user("reclose")
      space_id = Ecto.UUID.generate()

      {:ok, _} = Accounts.close_dm(user.id, space_id)
      first = Accounts.get_closed_dm_at(user.id)[space_id]

      Process.sleep(2)
      {:ok, _} = Accounts.close_dm(user.id, space_id)
      second = Accounts.get_closed_dm_at(user.id)[space_id]

      assert DateTime.compare(second, first) == :gt
    end

    test "closing one DM leaves other closed DMs and other preference keys alone" do
      user = insert_user("coexist")
      keep = Ecto.UUID.generate()
      drop = Ecto.UUID.generate()
      channel_id = Ecto.UUID.generate()

      {:ok, _} = Accounts.update_user_preference(user.id, :chat_section_order, ["Fabrikam"])
      {:ok, _} = Accounts.hide_channel(user.id, channel_id)
      {:ok, _} = Accounts.close_dm(user.id, keep)
      {:ok, _} = Accounts.close_dm(user.id, drop)

      assert {:ok, _} = Accounts.reopen_dm(user.id, drop)

      closed = Accounts.get_closed_dm_at(user.id)
      assert Map.keys(closed) == [keep]

      reloaded = Repo.get!(User, user.id)
      assert reloaded.preferences["chat_section_order"] == ["Fabrikam"]
      assert reloaded.preferences["hidden_channel_ids"] == [channel_id]
    end

    test "reopen of a never-closed id is a no-op" do
      user = insert_user("noop_reopen")

      assert {:ok, _} = Accounts.reopen_dm(user.id, Ecto.UUID.generate())
      assert Accounts.get_closed_dm_at(user.id) == %{}
    end

    test "returns {:error, :not_found} for an unknown user id" do
      assert {:error, :not_found} = Accounts.close_dm(Ecto.UUID.generate(), Ecto.UUID.generate())

      assert {:error, :not_found} =
               Accounts.reopen_dm(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "returns {:error, :not_found} when user_id is nil" do
      assert {:error, :not_found} = Accounts.close_dm(nil, Ecto.UUID.generate())
      assert {:error, :not_found} = Accounts.reopen_dm(nil, Ecto.UUID.generate())
    end
  end
end
