defmodule Platform.AccountsFloatNewMessagesTest do
  @moduledoc """
  `Accounts.float_new_messages?/1` and `put_float_new_messages/2` (task
  01a1b6fd stage 1): the chat list's "Move new messages to the top" setting
  in `users.preferences["chat_float_new_messages"]`. Default ON; only a
  literal `false` is off. The write sets ONE key with `jsonb_set`, so a
  sibling key survives whichever write lands first.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "float_#{n}@example.com",
      name: "Float Test #{n}",
      oidc_sub: "oidc-float-#{n}",
      avatar_url: nil
    })
  end

  test "the default is true, and false round-trips" do
    user = insert_user()

    assert Accounts.float_new_messages?(user)
    assert Accounts.float_new_messages?(user.id)
    assert Accounts.float_new_messages?(Ecto.UUID.generate())
    assert Accounts.float_new_messages?(nil)

    assert {:ok, %User{} = off} = Accounts.put_float_new_messages(user.id, false)
    refute Accounts.float_new_messages?(off)
    refute Accounts.float_new_messages?(user.id)
    assert Accounts.get_user_preferences(user.id)["chat_float_new_messages"] == false

    assert {:ok, on} = Accounts.put_float_new_messages(user.id, true)
    assert Accounts.float_new_messages?(on)
    assert Accounts.float_new_messages?(user.id)
  end

  test "an unknown user is not_found" do
    assert Accounts.put_float_new_messages(Ecto.UUID.generate(), false) == {:error, :not_found}
  end

  test "a sibling key survives: sibling written first, then the setting" do
    user = insert_user()
    {:ok, _} = Accounts.update_user_preference(user.id, "chat_section_order", ["a", "b"])
    {:ok, _} = Accounts.put_float_new_messages(user.id, false)

    prefs = Accounts.get_user_preferences(user.id)
    assert prefs["chat_section_order"] == ["a", "b"]
    assert prefs["chat_float_new_messages"] == false
  end

  test "a sibling key survives: the setting written first, then the sibling" do
    user = insert_user()
    {:ok, _} = Accounts.put_float_new_messages(user.id, false)
    {:ok, _} = Accounts.update_user_preference(user.id, "chat_section_order", ["a", "b"])

    prefs = Accounts.get_user_preferences(user.id)
    assert prefs["chat_section_order"] == ["a", "b"]
    assert prefs["chat_float_new_messages"] == false
  end

  test "the write broadcasts :sidebar_changed to the user's sessions" do
    user = insert_user()
    :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "chat:sidebar:#{user.id}")
    {:ok, _} = Accounts.put_float_new_messages(user.id, false)
    assert_receive :sidebar_changed
  end
end
