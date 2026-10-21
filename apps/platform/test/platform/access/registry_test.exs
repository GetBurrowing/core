defmodule Platform.Access.RegistryTest do
  @moduledoc """
  Task 01a1386d-cb5c stage 1: the permission registry covers every rail
  destination and every MCP bundle, in both directions, and the seeded
  built-in roles only name registered, non-install-level permissions.

  `async: false` because the extension describe swaps
  `:platform, :extensions` (see `Platform.FixtureExtension.register/1`).
  """
  use Platform.DataCase, async: false

  alias Platform.Access.{Registry, Role}
  alias Platform.Federation.ToolSurface
  alias Platform.FixtureExtension
  alias Platform.Repo
  alias PlatformWeb.Components.IconRail

  # Email is the one env-gated destination (`Platform.Mail.Config.enabled?/0`);
  # it is switched on here so the rail comparison sees every destination.
  # The registry's own declaration is not env-gated (see the last core test).
  setup do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    :ok
  end

  defp rail_keys, do: Enum.map(IconRail.destinations(root_user: true), & &1.key)
  # `:activity` is the one registry rail entry with no destination, on
  # purpose: the Activity page was retired (task 01a1557a-7a71 stage 4) but
  # ModuleGate still resolves ChangelogLive through `rail_entry(:activity)`
  # (see registry.ex), so it gates /changelog. Every other entry still pairs
  # one-to-one.
  @destinationless_entries [:activity]

  defp entry_keys, do: Enum.map(Registry.rail_entries(), & &1.key) -- @destinationless_entries

  describe "core registry (no extensions)" do
    setup do
      FixtureExtension.register([])
      :ok
    end

    test "every rail destination has exactly one registry entry, and the reverse" do
      assert Enum.sort(rail_keys()) == Enum.sort(entry_keys())
      assert entry_keys() == Enum.uniq(entry_keys())
      # The exemption names an entry that exists and has no destination.
      all_entries = Enum.map(Registry.rail_entries(), & &1.key)

      for key <- @destinationless_entries,
          do: assert(key in all_entries and key not in rail_keys())
    end

    test "a disabled destination keeps its registry entry" do
      Application.put_env(:platform, :mail_enabled, false)
      refute :email in rail_keys()
      assert Registry.rail_permission(:email) == "mail.use"
    end

    test "every rail entry requires a declared permission" do
      for %{key: key, permission: permission} <- Registry.rail_entries() do
        assert Registry.permission?(permission), "#{key} requires undeclared #{permission}"
      end
    end

    test "every root_only? destination requires a permission no built-in role carries" do
      # `install.admin` for /admin; `prompts.manage`, a module-admin permission,
      # for Prompts (ADR 0058 moves Prompts out of install-level, see the
      # registry moduledoc). Either way only the root-admin rule holds it today.
      restricted = Registry.install_level_permissions() ++ Registry.module_admin_permissions()

      root_only =
        for dest <- IconRail.destinations(root_user: true), dest.root_only?, do: dest.key

      assert root_only != []

      for key <- root_only do
        assert Registry.rail_permission(key) in restricted,
               "#{key} is root_only? but requires #{Registry.rail_permission(key)}"
      end

      assert Registry.rail_permission(:admin) == "install.admin"
      assert Registry.install_level?("install.admin")
    end

    test "every bundle in ToolSurface.all_bundles/0 maps to exactly one declared permission" do
      assert Registry.undeclared_bundles() == []

      for bundle <- ToolSurface.all_bundles() do
        permission = Registry.bundle_permission(bundle)
        assert is_binary(permission), "bundle #{bundle} maps to no permission"
        assert Registry.permission?(permission)
      end

      # No two bundles share one permission, so the mapping is invertible.
      values = Map.values(Registry.bundle_permissions())
      assert values == Enum.uniq(values)
    end

    test "every permission matches module.action and is declared once" do
      names = Registry.permission_names()
      assert names != []
      assert names == Enum.uniq(names)

      for name <- names do
        assert Regex.match?(~r/^[a-z_]+\.[a-z_]+$/, name), "bad permission name #{name}"
      end
    end

    test "no module reuses another module's prefix" do
      for permission <- Registry.permissions() do
        [prefix, _action] = String.split(permission.name, ".")

        assert prefix == permission.module,
               "#{permission.name} is declared by #{permission.module}"
      end
    end

    test "the ADR 0058 vocabulary is all declared" do
      for name <- ~w(chat.read chat.write chat.manage tasks.read tasks.write tasks.manage
                     tasks.promote files.read files.write memory.read memory.write memory.journal
                     canvas.read canvas.write meetings.join mail.use mail.manage prototypes.read
                     prototypes.publish experiments.read experiments.propose agents.manage_own
                     agents.manage_all skills.read skills.write vault.use prompts.read
                     prompts.manage access.manage install.admin) do
        assert Registry.permission?(name), "#{name} is not declared"
      end

      assert Registry.install_level_permissions() == ["install.admin"]
      assert Enum.sort(Registry.module_admin_permissions()) == ["prompts.manage", "tasks.manage"]
    end

    test "org visibility is the one derived permission (stage 2)" do
      assert Registry.derived_permissions() == ["orgs.read"]
      refute Registry.install_level?("orgs.read")
      refute "orgs.read" in Enum.map(Registry.rail_entries(), & &1.permission)
    end
  end

  describe "build-time modules" do
    test "an extension that declares permissions/0 is read" do
      FixtureExtension.register([FixtureExtension])

      assert "fixture.use" in Registry.permission_names()
      assert Registry.rail_permission(:fixture) == "fixture.use"
      assert Registry.bundle_permission("fixture") == "fixture.use"
      # The fixture's rail item and bundle are covered both ways.
      assert Enum.sort(rail_keys()) == Enum.sort(entry_keys())
      assert Registry.undeclared_bundles() == []
    end

    test "an extension that omits permissions/0 contributes nothing" do
      FixtureExtension.register([])
      core = Registry.modules()

      FixtureExtension.register([FixtureExtension.Twin])
      refute function_exported?(FixtureExtension.Twin, :permissions, 0)
      assert Platform.Extensions.permissions() == []
      assert Registry.modules() == core
      # Twin's bundle is real but undeclared, and the registry says so.
      assert Registry.undeclared_bundles() == ["fixture"]
    end
  end

  describe "the seeded built-in roles" do
    setup do
      FixtureExtension.register([])
      :ok
    end

    test "exactly admin, member and guest, each valid against the registry" do
      roles = Repo.all(Role)
      builtin = for r <- roles, r.builtin, do: r.key
      assert Enum.sort(builtin) == ["admin", "guest", "member"]

      for role <- roles, role.builtin do
        changeset =
          Role.changeset(%Role{}, Map.take(Map.from_struct(role), [:key, :name, :permissions]))

        assert changeset.valid?, "#{role.key}: #{inspect(changeset.errors)}"
      end
    end

    test "no built-in role carries an install-level or module-admin permission" do
      forbidden =
        Registry.install_level_permissions() ++
          Registry.module_admin_permissions() ++ Registry.derived_permissions()

      for role <- Repo.all(Role), role.builtin, permission <- Map.keys(role.permissions) do
        refute permission in forbidden, "#{role.key} carries #{permission}"
      end
    end

    test "admin is member plus five membership_org permissions; guest is chat on participant spaces" do
      by_key = Map.new(Repo.all(Role), &{&1.key, &1.permissions})

      extra = Map.drop(by_key["admin"], Map.keys(by_key["member"]))

      assert extra == %{
               "access.manage" => "membership_org",
               "agents.manage_all" => "membership_org",
               "mail.manage" => "membership_org",
               "prototypes.publish" => "membership_org",
               "tasks.promote" => "membership_org"
             }

      assert Map.take(by_key["admin"], Map.keys(by_key["member"])) == by_key["member"]

      assert by_key["guest"] == %{
               "chat.read" => "participant_spaces",
               "chat.write" => "participant_spaces"
             }

      # The chat rule for internal roles is implicit_or_participant, never "all".
      assert by_key["member"]["chat.read"] == "implicit_or_participant"
      # Today's unscoped board: internal humans read every task.
      assert by_key["member"]["tasks.read"] == "all"
      # Every rail permission an internal user reaches today is held by member.
      for %{key: key, permission: p} <- Registry.rail_entries(),
          key not in [:admin, :prompts] do
        assert Map.has_key?(by_key["member"], p), "member lacks #{p} for rail #{key}"
      end
    end

    test "the role changeset refuses an install-level permission, an unknown one and a bad rule" do
      valid? = fn permissions ->
        Role.changeset(%Role{}, %{key: "x", name: "X", permissions: permissions}).valid?
      end

      refute valid?.(%{"install.admin" => "all"})
      refute valid?.(%{"orgs.read" => "all"})
      refute valid?.(%{"nope.read" => "all"})
      refute valid?.(%{"chat.read" => "everyone"})
      refute valid?.(%{"chat.read" => []})
      refute valid?.(%{"chat.read" => ["all", "all"]})
      assert valid?.(%{"chat.read" => "all"})
      assert valid?.(%{"canvas.read" => ["participant_spaces", "membership_org"]})
    end
  end
end
