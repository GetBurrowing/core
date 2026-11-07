defmodule Platform.Secretary.SettingsTest do
  use Platform.DataCase, async: true

  import Platform.ExternalUserFixtures

  alias Platform.Accounts
  alias Platform.Secretary.Settings

  test "defaults carry the sponsor's three calls" do
    user = create_user!()
    settings = Settings.get(user)

    # 1: an urgent new item takes the top slot.
    assert settings["urgent_takes_top"] == true
    # 2: interrupt for goal-tied items by default.
    assert settings["interrupt_level"] == "goals"
    # 3: hold in meetings; FYIs wait for the evening read.
    assert settings["hold_in_meetings"] == true
    assert settings["evening_read_at"] == "20:00"

    assert settings["time_zone"] == "Etc/UTC"
    assert settings["family_placement"] == "brief_and_list"
    assert settings["family_private"] == true
    assert settings["daily_token_ceiling"] == nil
    assert settings["max_nudges_per_hour"] == 3
    assert Settings.get(user.id) == settings
  end

  test "put round-trips and keeps other preferences" do
    user = create_user!()

    assert {:ok, saved} =
             Settings.put(user.id, %{
               interrupt_level: "urgent",
               time_zone: "Europe/London",
               evening_read_at: "19:30",
               daily_token_ceiling: 5000
             })

    assert saved["interrupt_level"] == "urgent"
    assert Settings.get(user.id) == saved
    assert Settings.get(Accounts.get_user(user.id))["time_zone"] == "Europe/London"
    assert Accounts.get_user_preferences(user.id)["first_run_goal"] == "existing"

    assert {:ok, again} = Settings.put(user.id, %{"max_nudges_per_hour" => 1})
    assert again["time_zone"] == "Europe/London"
  end

  test "family_private cannot be turned off, unknown keys and bad values are refused" do
    user = create_user!()

    assert {:error, ["family_private cannot be turned off"]} =
             Settings.put(user.id, %{family_private: false})

    assert {:error, ["unknown keys: colour"]} = Settings.put(user.id, %{colour: "red"})
    assert {:error, [_]} = Settings.put(user.id, %{time_zone: "Mars/Olympus"})
    assert {:error, [_]} = Settings.put(user.id, %{evening_read_at: "25:00"})
    assert {:error, [_]} = Settings.put(user.id, %{interrupt_level: "sometimes"})
    assert {:error, [_]} = Settings.put(user.id, %{daily_token_ceiling: 0})
    assert {:ok, _} = Settings.put(user.id, %{family_private: true})
    assert Settings.get(user.id)["family_private"] == true
  end
end
