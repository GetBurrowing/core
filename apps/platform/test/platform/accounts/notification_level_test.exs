defmodule Platform.Accounts.NotificationLevelTest do
  @moduledoc """
  Task 01a1557a-e538 stage 1: the per-user notification level,
  `Accounts.notification_level/1`, `Accounts.put_notification_level/2` and
  `Accounts.notification_levels/1`, stored under
  `users.preferences["notification_level"]` beside the theme.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo

  defp insert_user(prefs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "notif_level_#{n}@example.com",
      name: "Notif Level #{n}",
      oidc_sub: "oidc-notif-level-#{n}",
      preferences: prefs
    })
  end

  defp stored_prefs(user_id), do: Repo.get!(User, user_id).preferences

  # Every SQL statement THIS process sends to `users` while `fun` runs.
  # Telemetry handlers run in the process that executed the query, so the
  # `self()` check keeps sibling async tests (which fire the same global
  # event) out of the count.
  defp count_user_queries(fun) do
    test_pid = self()
    handler_id = "notif-level-queries-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test_pid and is_binary(meta[:query]) and meta[:query] =~ ~s("users") do
            send(test_pid, {:users_query, handler_id})
          end
        end,
        nil
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain(handler_id, 0)}
  end

  defp drain(handler_id, n) do
    receive do
      {:users_query, ^handler_id} -> drain(handler_id, n + 1)
    after
      0 -> n
    end
  end

  describe "notification_level/1 and put_notification_level/2" do
    test "the default is \"mentions\"" do
      user = insert_user()
      assert Accounts.default_notification_level() == "mentions"
      assert Accounts.notification_level(user) == "mentions"
      assert Accounts.notification_level(user.id) == "mentions"
      assert Accounts.notification_level(nil) == "mentions"
      assert Accounts.notification_level(Ecto.UUID.generate()) == "mentions"
      assert Accounts.notification_level("not-a-uuid") == "mentions"
    end

    test "each valid level round-trips, by id and by struct" do
      user = insert_user()

      for level <- ~w(all mentions direct) do
        assert {:ok, %User{} = updated} = Accounts.put_notification_level(user.id, level)
        assert Accounts.notification_level(user.id) == level
        assert Accounts.notification_level(updated) == level
        assert stored_prefs(user.id)["notification_level"] == level
      end
    end

    test "a %User{} is read from the struct with no query" do
      user = insert_user(%{"notification_level" => "direct"})
      {level, queries} = count_user_queries(fn -> Accounts.notification_level(user) end)
      assert level == "direct"
      assert queries == 0

      # Positive control: the counter does see a read by id.
      {by_id, id_queries} = count_user_queries(fn -> Accounts.notification_level(user.id) end)
      assert by_id == "direct"
      assert id_queries == 1
    end

    test "an unknown stored value reads as the default" do
      user = insert_user(%{"notification_level" => "everything"})
      assert Accounts.notification_level(user) == "mentions"
      assert Accounts.notification_level(user.id) == "mentions"
    end

    test "an invalid value is refused and nothing is written" do
      user = insert_user(%{"notification_level" => "direct"})

      for bad <- ["everything", "", nil, :all, "ALL"] do
        assert {:error, :invalid} = Accounts.put_notification_level(user.id, bad)
      end

      assert stored_prefs(user.id)["notification_level"] == "direct"
    end

    test "an unknown user is refused" do
      assert {:error, :not_found} = Accounts.put_notification_level(Ecto.UUID.generate(), "all")
      assert {:error, :not_found} = Accounts.put_notification_level(nil, "all")
    end

    test "a stored theme survives a level write, and a level survives a theme write" do
      user = insert_user()

      {:ok, _} =
        Accounts.put_theme_preference(user.id, %{"preset" => "burrow-sand", "mode" => "light"})

      {:ok, _} = Accounts.put_notification_level(user.id, "all")

      assert Accounts.theme_preference(user.id) == %{"preset" => "burrow-sand", "mode" => "light"}
      assert Accounts.notification_level(user.id) == "all"

      {:ok, _} = Accounts.put_theme_preference(user.id, %{"mode" => "dark"})
      assert Accounts.notification_level(user.id) == "all"

      assert %{
               "theme" => %{"preset" => "burrow-sand", "mode" => "dark"},
               "notification_level" => "all"
             } = stored_prefs(user.id)
    end
  end

  describe "notification_levels/1" do
    test "returns only users with a valid stored level" do
      all = insert_user(%{"notification_level" => "all"})
      direct = insert_user(%{"notification_level" => "direct"})
      mentions = insert_user(%{"notification_level" => "mentions"})
      unset = insert_user()
      junk = insert_user(%{"notification_level" => "everything"})

      ids = [all.id, direct.id, mentions.id, unset.id, junk.id, Ecto.UUID.generate(), "nope"]

      assert Accounts.notification_levels(ids) == %{
               all.id => "all",
               direct.id => "direct",
               mentions.id => "mentions"
             }
    end

    test "runs ONE query however many users it reads, and none for an empty list" do
      users =
        for level <- ~w(all direct mentions all),
            do: insert_user(%{"notification_level" => level})

      ids = Enum.map(users, & &1.id) ++ [insert_user().id]

      {levels, queries} = count_user_queries(fn -> Accounts.notification_levels(ids) end)
      assert map_size(levels) == 4
      assert queries == 1

      {empty, none} = count_user_queries(fn -> Accounts.notification_levels([]) end)
      assert empty == %{}
      assert none == 0
    end
  end
end
