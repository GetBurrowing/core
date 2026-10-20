defmodule Platform.Accounts.ThemePreferenceTest do
  @moduledoc """
  Task 01a1557a stage 1: the theme registry (`Platform.Accounts.ThemePreference`)
  and the per-user read/write pair `Accounts.theme_preference/1` /
  `Accounts.put_theme_preference/2`, stored under `users.preferences["theme"]`.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Accounts.ThemePreference
  alias Platform.Accounts.User
  alias Platform.Repo

  defp insert_user(suffix, prefs \\ %{}) do
    Repo.insert!(%User{
      email: "theme_#{suffix}_#{System.unique_integer([:positive])}@example.com",
      name: "Theme Test #{suffix}",
      oidc_sub: "oidc-theme-#{suffix}-#{System.unique_integer([:positive])}",
      preferences: prefs
    })
  end

  defp stored_prefs(user_id), do: Repo.get!(User, user_id).preferences

  describe "registry" do
    test "presets are the five direction-canvas rows, in order" do
      assert ThemePreference.presets() == [
               %{id: "burrow", name: "Burrow"},
               %{id: "burrow-midnight", name: "Burrow midnight"},
               %{id: "burrow-sand", name: "Burrow sand"},
               %{id: "burrow-forest", name: "Burrow forest"},
               %{id: "high-contrast", name: "High contrast"}
             ]
    end

    test "modes and default" do
      assert ThemePreference.modes() == ["light", "dark", "system"]
      assert ThemePreference.default() == %{"preset" => "burrow", "mode" => "dark"}
    end

    test "the base preset is a registered id: the one app.css paints with no data-preset" do
      assert ThemePreference.base_preset() == "burrow"
      assert ThemePreference.valid_preset?(ThemePreference.base_preset())
    end

    test "normalize/1 falls back per field and accepts atom keys" do
      assert ThemePreference.normalize(nil) == ThemePreference.default()
      assert ThemePreference.normalize("burrow") == ThemePreference.default()

      assert ThemePreference.normalize(%{"preset" => "burrow-sand"}) ==
               %{"preset" => "burrow-sand", "mode" => "dark"}

      assert ThemePreference.normalize(%{"preset" => "gone", "mode" => "light"}) ==
               %{"preset" => "burrow", "mode" => "light"}

      assert ThemePreference.normalize(%{preset: "high-contrast", mode: "system"}) ==
               %{"preset" => "high-contrast", "mode" => "system"}
    end
  end

  describe "theme_preference/1" do
    test "a user with no theme key gets the default (burrow, dark)" do
      user = insert_user("none")
      expected = %{"preset" => "burrow", "mode" => "dark"}

      assert Accounts.theme_preference(user.id) == expected
      assert Accounts.theme_preference(user) == expected
    end

    test "nil and an unknown id get the default" do
      assert Accounts.theme_preference(nil) == %{"preset" => "burrow", "mode" => "dark"}

      assert Accounts.theme_preference(Ecto.UUID.generate()) ==
               %{"preset" => "burrow", "mode" => "dark"}
    end

    test "reads a value stored directly under the \"theme\" key" do
      user =
        insert_user("direct", %{"theme" => %{"preset" => "burrow-forest", "mode" => "light"}})

      assert Accounts.theme_preference(user.id) == %{
               "preset" => "burrow-forest",
               "mode" => "light"
             }
    end
  end

  describe "put_theme_preference/2" do
    test "round trip through the id and the struct" do
      user = insert_user("roundtrip")

      assert {:ok, %User{} = updated} =
               Accounts.put_theme_preference(user.id, %{
                 "preset" => "burrow-midnight",
                 "mode" => "system"
               })

      expected = %{"preset" => "burrow-midnight", "mode" => "system"}
      assert Accounts.theme_preference(user.id) == expected
      assert Accounts.theme_preference(updated) == expected
      assert stored_prefs(user.id)["theme"] == expected

      assert {:ok, _} = Accounts.put_theme_preference(updated, %{mode: "light"})

      assert Accounts.theme_preference(user.id) == %{
               "preset" => "burrow-midnight",
               "mode" => "light"
             }
    end

    test "every registered preset and mode is accepted" do
      user = insert_user("all")

      for %{id: preset} <- ThemePreference.presets(), mode <- ThemePreference.modes() do
        assert {:ok, _} =
                 Accounts.put_theme_preference(user.id, %{"preset" => preset, "mode" => mode})

        assert Accounts.theme_preference(user.id) == %{"preset" => preset, "mode" => mode}
      end
    end

    test "an unregistered preset is rejected and nothing is written" do
      user = insert_user("badpreset")
      {:ok, _} = Accounts.put_theme_preference(user.id, %{"preset" => "burrow-sand"})
      before = stored_prefs(user.id)

      assert {:error, :invalid} =
               Accounts.put_theme_preference(user.id, %{"preset" => "burrow-dark"})

      assert stored_prefs(user.id) == before
    end

    test "an unregistered mode is rejected and nothing is written" do
      user = insert_user("badmode", %{"hidden_channel_ids" => ["x"]})
      before = stored_prefs(user.id)

      assert {:error, :invalid} = Accounts.put_theme_preference(user.id, %{"mode" => "dim"})
      assert stored_prefs(user.id) == before
      refute Map.has_key?(stored_prefs(user.id), "theme")
    end

    test "unknown keys and non-map attrs are rejected" do
      user = insert_user("badshape")
      assert {:error, :invalid} = Accounts.put_theme_preference(user.id, %{"accent" => "red"})
      assert {:error, :invalid} = Accounts.put_theme_preference(user.id, "burrow")
      assert stored_prefs(user.id) == %{}
    end

    test "an unknown id returns :not_found" do
      assert {:error, :not_found} =
               Accounts.put_theme_preference(Ecto.UUID.generate(), %{"preset" => "burrow"})

      assert {:error, :not_found} = Accounts.put_theme_preference(nil, %{"preset" => "burrow"})
    end

    test "other preference keys survive a write" do
      space_id = Ecto.UUID.generate()

      user =
        insert_user("survive", %{
          "hidden_channel_ids" => [space_id],
          "notification_banner_dismissed" => true
        })

      assert {:ok, _} =
               Accounts.put_theme_preference(user.id, %{"preset" => "high-contrast"})

      prefs = stored_prefs(user.id)
      assert prefs["hidden_channel_ids"] == [space_id]
      assert prefs["notification_banner_dismissed"] == true
      assert prefs["theme"] == %{"preset" => "high-contrast", "mode" => "dark"}
      assert MapSet.member?(Accounts.get_hidden_channel_ids(user.id), space_id)
    end
  end
end
