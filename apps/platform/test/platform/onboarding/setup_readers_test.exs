defmodule Platform.Onboarding.SetupReadersTest do
  @moduledoc """
  The public readers and single-key writes the person setup checklist and
  the member welcome use (task 01a1b6de stage 2), in their owning contexts.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.NativeLogin
  alias Platform.Audit
  alias Platform.Push
  alias Platform.Repo

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "sr-#{n}@example.com",
      name: "Reader #{n}",
      oidc_sub: "oidc-sr-#{n}",
      preferences: %{"theme" => "dark"}
    })
  end

  describe "Accounts.claim_preference/3, swap_preference/4, release_preference/3" do
    test "a claim wins only while the key is absent and leaves other keys alone" do
      user = user!()
      assert Accounts.claim_preference(user.id, "k", "posting") == :ok
      assert Accounts.claim_preference(user.id, "k", "posting") == {:error, :taken}
      assert Accounts.claim_preference(user.id, "k", "other") == {:error, :taken}

      assert Accounts.get_user_preferences(user.id) == %{"theme" => "dark", "k" => "posting"}
    end

    test "a swap needs the exact expected value" do
      user = user!()
      :ok = Accounts.claim_preference(user.id, "k", "posting")

      assert Accounts.swap_preference(user.id, "k", "nope", "x") == {:error, :changed}
      assert Accounts.swap_preference(user.id, "k", "posting", "done") == :ok
      assert Accounts.get_user_preferences(user.id)["k"] == "done"
      assert Accounts.swap_preference(user.id, "k", "posting", "again") == {:error, :changed}
    end

    test "a release removes only its own value" do
      user = user!()
      :ok = Accounts.claim_preference(user.id, "k", "posting")

      assert Accounts.release_preference(user.id, "k", "someone-else") == :ok
      assert Accounts.get_user_preferences(user.id)["k"] == "posting"

      assert Accounts.release_preference(user.id, "k", "posting") == :ok
      assert Accounts.get_user_preferences(user.id) == %{"theme" => "dark"}
      assert Accounts.claim_preference(user.id, "k", "posting") == :ok
    end

    test "a malformed or unknown user id is refused, not raised on" do
      for id <- ["not-a-uuid", Ecto.UUID.generate()] do
        assert Accounts.claim_preference(id, "k", "v") == {:error, :taken}
        assert Accounts.swap_preference(id, "k", "v", "w") == {:error, :changed}
        assert Accounts.release_preference(id, "k", "v") == :ok
      end
    end
  end

  describe "Accounts.first_sign_in_at/1 and Audit.earliest_at/1" do
    test "the earliest admission or callback success, nil otherwise" do
      user = user!()
      assert Accounts.first_sign_in_at(user.id) == nil

      {:ok, first} =
        Audit.record(%{
          event_type: "platform.auth.callback",
          actor_id: user.id,
          actor_type: "user",
          action: "success"
        })

      {:ok, _later} =
        Audit.record(%{
          event_type: "platform.auth.external_admission",
          actor_id: user.id,
          actor_type: "user",
          action: "full"
        })

      assert Accounts.first_sign_in_at(user.id) == first.inserted_at
    end

    test "a logout row is not a sign-in" do
      user = user!()

      {:ok, _} =
        Audit.record(%{
          event_type: "platform.auth.logout",
          actor_id: user.id,
          actor_type: "user",
          action: "logout"
        })

      assert Accounts.first_sign_in_at(user.id) == nil
    end

    test "a malformed id is nil, not a cast error" do
      assert Accounts.first_sign_in_at("not-a-uuid") == nil
      assert Accounts.first_sign_in_at(nil) == nil
      assert Audit.earliest_at(actor_id: "not-a-uuid") == nil
      assert Audit.earliest_at(actor_id: 123) == nil
    end
  end

  describe "Push and NativeLogin readers" do
    test "a malformed id reads as nothing recorded" do
      refute Push.web_subscribed?("not-a-uuid")
      refute Push.web_subscribed?(nil)
      assert Push.native_platforms("not-a-uuid") == []
      assert Push.native_platforms(nil) == []
      refute NativeLogin.subscription_logged_in?(nil)
    end
  end
end
