defmodule Platform.Accounts.ThemePreferenceTest do
  @moduledoc """
  Task 01a1557a stage 1: the theme registry (`Platform.Accounts.ThemePreference`)
  and the per-user read/write pair `Accounts.theme_preference/1` /
  `Accounts.put_theme_preference/2`, stored under `users.preferences["theme"]`.
  """

  use Platform.DataCase, async: true

  import Ecto.Query

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

  # Task 01a1557a-fe9b stage 3: a preset may be "org-<uuid>", a published org
  # theme, accepted on write only when visible to the writer and sent back to
  # the default on read once it is not. Mutation (c), keep an unpublished id
  # in normalize, turns "a stored org id falls back ..." red.
  describe "org presets" do
    import Platform.OrgThemeFixtures

    alias Platform.Theming
    alias Platform.Theming.OrgTheme

    setup do
      org_theme_world!()
    end

    test "validate/3 accepts an org id only when it is in the visible set", ctx do
      id = OrgTheme.preset_id(ctx.visible)
      other = OrgTheme.preset_id(ctx.hidden)

      assert ThemePreference.validate(%{"preset" => id}, nil, [id]) ==
               {:ok, %{"preset" => id, "mode" => "dark"}}

      assert ThemePreference.validate(%{"preset" => id}, nil, [other]) == {:error, :invalid}
      assert ThemePreference.validate(%{"preset" => id}, nil) == {:error, :invalid}
      assert ThemePreference.validate(%{"preset" => id}) == {:error, :invalid}
      # A malformed org id is not an org preset, even when listed.
      assert ThemePreference.validate(%{"preset" => "org-x"}, nil, ["org-x"]) ==
               {:error, :invalid}
    end

    test "put_theme_preference/2 stores a visible org theme", ctx do
      id = OrgTheme.preset_id(ctx.visible)

      assert {:ok, _} = Accounts.put_theme_preference(ctx.member, %{"preset" => id})
      assert stored_prefs(ctx.member.id)["theme"] == %{"preset" => id, "mode" => "dark"}
      assert Accounts.theme_preference(ctx.member.id) == %{"preset" => id, "mode" => "dark"}
    end

    test "put_theme_preference/2 refuses an org theme the person cannot see and writes nothing",
         ctx do
      {:ok, _} =
        Accounts.put_theme_preference(ctx.outsider, %{
          "preset" => "burrow-sand",
          "mode" => "light"
        })

      before = stored_prefs(ctx.outsider.id)

      assert {:error, :invalid} =
               Accounts.put_theme_preference(ctx.outsider, %{
                 "preset" => OrgTheme.preset_id(ctx.visible)
               })

      assert stored_prefs(ctx.outsider.id) == before

      # A draft in the person's own org is not visible either.
      {:ok, draft} = Theming.create_draft(ctx.admin, ctx.root.id, %{name: "Draft s3"})

      assert {:error, :invalid} =
               Accounts.put_theme_preference(ctx.member, %{"preset" => OrgTheme.preset_id(draft)})
    end

    test "normalize/2 keeps a visible org id and sends any other back to the default", ctx do
      id = OrgTheme.preset_id(ctx.visible)
      stored = %{"preset" => id, "mode" => "light"}

      assert ThemePreference.normalize(stored, [id]) == stored
      assert ThemePreference.normalize(stored, []) == %{"preset" => "burrow", "mode" => "light"}
      assert ThemePreference.normalize(stored) == %{"preset" => "burrow", "mode" => "light"}
    end

    test "a stored org id falls back to the default once unpublished, deleted or not visible",
         ctx do
      # Unpublished: a draft id written around the validator.
      {:ok, draft} = Theming.create_draft(ctx.admin, ctx.root.id, %{name: "Never published"})
      draft_pref = %{"preset" => OrgTheme.preset_id(draft), "mode" => "light"}
      member = insert_user("org-draft", %{"theme" => draft_pref})
      Platform.ExternalUserFixtures.plain_member!(member, ctx.root)

      assert Accounts.theme_preference(member) == %{"preset" => "burrow", "mode" => "light"}
      assert Accounts.theme_preference(member.id) == %{"preset" => "burrow", "mode" => "light"}

      # Not visible: the outsider holding the root theme's id.
      vis_pref = %{"preset" => OrgTheme.preset_id(ctx.visible), "mode" => "dark"}

      {1, _} =
        Repo.update_all(
          from(u in User, where: u.id == ^ctx.outsider.id),
          set: [preferences: %{"theme" => vis_pref}]
        )

      assert Accounts.theme_preference(ctx.outsider.id) == ThemePreference.default()

      # Visible, then deleted.
      {:ok, _} = Accounts.put_theme_preference(ctx.member, %{"preset" => vis_pref["preset"]})
      assert Accounts.theme_preference(ctx.member.id)["preset"] == vis_pref["preset"]

      {:ok, _} = Theming.delete(ctx.admin, ctx.visible)
      assert Accounts.theme_preference(ctx.member.id) == ThemePreference.default()
    end
  end
end
