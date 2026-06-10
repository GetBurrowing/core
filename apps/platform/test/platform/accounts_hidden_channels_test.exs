defmodule Platform.AccountsHiddenChannelsTest do
  @moduledoc """
  Covers the hidden-channel preference helpers added for chat sidebar v3
  Stage 1: `get_hidden_channel_ids/1`, `hide_channel/2`, `unhide_channel/2`.

  Storage shape: `users.preferences["hidden_channel_ids"] = ["<uuid>", ...]`
  managed via `Accounts.update_user_preference/3` (same JSONB column the
  chat_section_order feature uses).
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "hidden_#{suffix}@example.com",
      name: "Hidden Test #{suffix}",
      oidc_sub: "oidc-hidden-#{suffix}",
      avatar_url: nil
    })
  end

  describe "get_hidden_channel_ids/1" do
    test "returns empty MapSet for a user with no preferences" do
      user = insert_user("empty")
      assert %MapSet{} = result = Accounts.get_hidden_channel_ids(user.id)
      assert MapSet.size(result) == 0
    end

    test "returns empty MapSet for an unknown user id" do
      result = Accounts.get_hidden_channel_ids(Ecto.UUID.generate())
      assert MapSet.equal?(result, MapSet.new())
    end

    test "returns empty MapSet for a nil user_id (anonymous session)" do
      assert MapSet.equal?(Accounts.get_hidden_channel_ids(nil), MapSet.new())
    end

    test "reads ids previously persisted via hide_channel/2" do
      user = insert_user("read")
      space_a = Ecto.UUID.generate()
      space_b = Ecto.UUID.generate()

      {:ok, _} = Accounts.hide_channel(user.id, space_a)
      {:ok, _} = Accounts.hide_channel(user.id, space_b)

      hidden = Accounts.get_hidden_channel_ids(user.id)
      assert MapSet.equal?(hidden, MapSet.new([space_a, space_b]))
    end
  end

  describe "hide_channel/2" do
    test "persists the id into preferences['hidden_channel_ids']" do
      user = insert_user("hide")
      space_id = Ecto.UUID.generate()

      assert {:ok, _} = Accounts.hide_channel(user.id, space_id)

      reloaded = Repo.get!(User, user.id)
      assert reloaded.preferences["hidden_channel_ids"] == [space_id]
    end

    test "is idempotent on double-hide (no duplicates)" do
      user = insert_user("dup")
      space_id = Ecto.UUID.generate()

      assert {:ok, _} = Accounts.hide_channel(user.id, space_id)
      assert {:ok, _} = Accounts.hide_channel(user.id, space_id)

      reloaded = Repo.get!(User, user.id)
      assert reloaded.preferences["hidden_channel_ids"] == [space_id]
    end

    test "preserves other preference keys when hiding (chat_section_order untouched)" do
      user = insert_user("coexist")

      {:ok, _} =
        Accounts.update_user_preference(user.id, :chat_section_order, ["Fabrikam", "Paragon"])

      space_id = Ecto.UUID.generate()
      assert {:ok, _} = Accounts.hide_channel(user.id, space_id)

      reloaded = Repo.get!(User, user.id)
      assert reloaded.preferences["chat_section_order"] == ["Fabrikam", "Paragon"]
      assert reloaded.preferences["hidden_channel_ids"] == [space_id]
    end

    test "returns {:error, :not_found} for an unknown user_id (anonymous session)" do
      assert {:error, :not_found} =
               Accounts.hide_channel(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "returns {:error, :not_found} when user_id is nil" do
      assert {:error, :not_found} = Accounts.hide_channel(nil, Ecto.UUID.generate())
    end
  end

  describe "unhide_channel/2" do
    test "removes a previously hidden id" do
      user = insert_user("unhide")
      space_id = Ecto.UUID.generate()
      {:ok, _} = Accounts.hide_channel(user.id, space_id)

      assert {:ok, _} = Accounts.unhide_channel(user.id, space_id)

      reloaded = Repo.get!(User, user.id)
      assert reloaded.preferences["hidden_channel_ids"] == []
    end

    test "is idempotent on unhide of a never-hidden id" do
      user = insert_user("noop_unhide")
      space_id = Ecto.UUID.generate()

      assert {:ok, _} = Accounts.unhide_channel(user.id, space_id)

      reloaded = Repo.get!(User, user.id)
      assert reloaded.preferences["hidden_channel_ids"] == []
    end

    test "only removes the target id; other hidden ids remain" do
      user = insert_user("partial")
      keep = Ecto.UUID.generate()
      drop = Ecto.UUID.generate()
      {:ok, _} = Accounts.hide_channel(user.id, keep)
      {:ok, _} = Accounts.hide_channel(user.id, drop)

      assert {:ok, _} = Accounts.unhide_channel(user.id, drop)

      hidden = Accounts.get_hidden_channel_ids(user.id)
      assert MapSet.equal?(hidden, MapSet.new([keep]))
    end

    test "returns {:error, :not_found} for an unknown user_id" do
      assert {:error, :not_found} =
               Accounts.unhide_channel(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end
end
