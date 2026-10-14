defmodule Platform.Access.Registry do
  @moduledoc """
  The permission registry for RBAC v2 (task `01a1386d-cb5c`, stack `rbac-roles`).

  Every module declares, as data:

    * its permissions, each a `module.action` string matching
      `^[a-z_]+\\.[a-z_]+$` (vocabulary from
      `0058-rbac-v2-roles-scopes-and-agent-capping.md § Permission model`);
    * its rail entries, keyed by the `:key` atoms of
      `PlatformWeb.Components.IconRail.destinations/1`, each with the
      permission that entry requires;
    * the MCP capability bundles it owns, each mapped to exactly one
      permission.

  Core's modules are declared here. A build-time module (ADR 0055) declares
  its own through the optional `c:Platform.Extension.permissions/0` callback,
  read per call through `Platform.Extensions.permissions/0`, so nothing here
  is captured at compile time.

  ## Nothing reads this for a decision yet

  The rail entry's required permission is DECLARED only. Rail gating is a
  later stack member, and so is per-tool authorization: the `mcp.<bundle>`
  permissions are the transitional per-bundle vocabulary the shadow
  `Scope.for_runtime/1` and the equivalence test use, which a per-tool map
  supersedes (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Agents`).

  ## Install-level and module-admin permissions

  `install.admin` is flagged `install_level: true`: no role carries it and no
  grant may name it. `tasks.manage` and `prompts.manage` are module-admin
  permissions: no built-in role carries them either, and with no grants they
  are held only through the root-admin rule
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles`).

  ## Two modules the ADR vocabulary does not name

  The ADR's table has no entry for the Inbox and Activity rail destinations,
  but each rail entry must name a required permission. They are declared here
  as `inbox.read` and `activity.read`, which every internal built-in role
  carries at `"all"`, so the mapping changes nothing.
  """

  alias Platform.Federation.ToolSurface

  @grant_rules ~w(all membership_org participant_spaces implicit_or_participant)
  @builtin_role_keys ~w(admin member guest)
  @permission_shape ~r/^[a-z_]+\.[a-z_]+$/

  @typedoc "A normalized permission declaration."
  @type permission :: %{
          name: String.t(),
          module: String.t(),
          install_level: boolean(),
          module_admin: boolean()
        }

  @typedoc "A normalized rail entry: the destination key and the permission it requires."
  @type rail_entry :: %{key: atom(), permission: String.t(), module: String.t()}

  # Core MCP bundles → their one transitional permission. A literal map, not a
  # function of `ToolSurface.core_bundles/0`, so a bundle added to the catalogue
  # without a declaration here turns `registry_test.exs` red.
  @core_bundle_permissions %{
    "canvas" => "mcp.canvas",
    "messaging" => "mcp.messaging",
    "task" => "mcp.task",
    "plan" => "mcp.plan",
    "review" => "mcp.review",
    "space" => "mcp.space",
    "context_read" => "mcp.context_read",
    "federation" => "mcp.federation",
    "memory" => "mcp.memory",
    "skill" => "mcp.skill",
    "attachment" => "mcp.attachment",
    "files" => "mcp.files",
    "meetings" => "mcp.meetings",
    "mail" => "mcp.mail",
    "experiments" => "mcp.experiments",
    "code_mode" => "mcp.code_mode",
    "prototype" => "mcp.prototype"
  }

  @doc "The grant-rule values a role may map a permission to."
  @spec grant_rules() :: [String.t()]
  def grant_rules, do: @grant_rules

  @doc "The keys of the three built-in roles."
  @spec builtin_role_keys() :: [String.t()]
  def builtin_role_keys, do: @builtin_role_keys

  @doc "Every module declaration, core first, then each extension's, as declared."
  @spec modules() :: [map()]
  def modules, do: core_modules() ++ Platform.Extensions.permissions()

  @doc "Every declared permission, normalized, in declaration order."
  @spec permissions() :: [permission()]
  def permissions do
    for mod <- modules(), entry <- Map.get(mod, :permissions, []) do
      normalize_permission(entry, mod.module)
    end
  end

  @doc "Every declared permission name."
  @spec permission_names() :: [String.t()]
  def permission_names, do: Enum.map(permissions(), & &1.name)

  @doc "Is `name` a declared permission?"
  @spec permission?(String.t()) :: boolean()
  def permission?(name) when is_binary(name), do: name in permission_names()
  def permission?(_), do: false

  @doc "Permission names flagged `install_level: true`."
  @spec install_level_permissions() :: [String.t()]
  def install_level_permissions,
    do: for(p <- permissions(), p.install_level, do: p.name)

  @doc "Is `name` an install-level permission?"
  @spec install_level?(String.t()) :: boolean()
  def install_level?(name), do: name in install_level_permissions()

  @doc "Permission names flagged `module_admin: true` (held through root admin when ungranted)."
  @spec module_admin_permissions() :: [String.t()]
  def module_admin_permissions,
    do: for(p <- permissions(), p.module_admin, do: p.name)

  @doc "Every rail entry with the permission it requires."
  @spec rail_entries() :: [rail_entry()]
  def rail_entries do
    for mod <- modules(), entry <- Map.get(mod, :rail, []) do
      %{key: entry.key, permission: entry.permission, module: mod.module}
    end
  end

  @doc "The permission rail destination `key` requires, or nil."
  @spec rail_permission(atom()) :: String.t() | nil
  def rail_permission(key) do
    Enum.find_value(rail_entries(), fn entry -> entry.key == key && entry.permission end)
  end

  @doc "Every bundle → permission mapping, core and extension."
  @spec bundle_permissions() :: %{String.t() => String.t()}
  def bundle_permissions do
    Enum.reduce(modules(), %{}, fn mod, acc -> Map.merge(acc, Map.get(mod, :bundles, %{})) end)
  end

  @doc "The one permission bundle `name` maps to, or nil for an undeclared bundle."
  @spec bundle_permission(String.t()) :: String.t() | nil
  def bundle_permission(name), do: Map.get(bundle_permissions(), name)

  @doc "Does `name` match the `module.action` shape?"
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@permission_shape, name)
  def valid_name?(_), do: false

  @doc "Every bundle `ToolSurface.all_bundles/0` lists that no module maps to a permission."
  @spec undeclared_bundles() :: [String.t()]
  def undeclared_bundles do
    declared = bundle_permissions()
    Enum.reject(ToolSurface.all_bundles(), &Map.has_key?(declared, &1))
  end

  defp normalize_permission(name, module) when is_binary(name),
    do: %{name: name, module: module, install_level: false, module_admin: false}

  defp normalize_permission(%{name: name} = entry, module) do
    %{
      name: name,
      module: module,
      install_level: Map.get(entry, :install_level, false) == true,
      module_admin: Map.get(entry, :module_admin, false) == true
    }
  end

  defp core_modules do
    [
      %{
        module: "chat",
        permissions: ~w(chat.read chat.write chat.manage),
        rail: [%{key: :chat, permission: "chat.read"}]
      },
      %{
        module: "tasks",
        permissions: [
          "tasks.read",
          "tasks.write",
          %{name: "tasks.manage", module_admin: true},
          "tasks.promote"
        ],
        rail: [%{key: :tasks, permission: "tasks.read"}]
      },
      %{
        module: "inbox",
        permissions: ~w(inbox.read),
        rail: [%{key: :inbox, permission: "inbox.read"}]
      },
      %{
        module: "activity",
        permissions: ~w(activity.read),
        rail: [%{key: :activity, permission: "activity.read"}]
      },
      %{
        module: "files",
        permissions: ~w(files.read files.write),
        rail: [%{key: :files, permission: "files.read"}]
      },
      %{
        module: "memory",
        permissions: ~w(memory.read memory.write memory.journal),
        # The Org Memory destination's key is `:context` (its route is /org_memory).
        rail: [%{key: :context, permission: "memory.read"}]
      },
      %{module: "canvas", permissions: ~w(canvas.read canvas.write)},
      %{
        module: "meetings",
        permissions: ~w(meetings.join),
        rail: [%{key: :meetings, permission: "meetings.join"}]
      },
      %{
        module: "mail",
        permissions: ~w(mail.use mail.manage),
        rail: [%{key: :email, permission: "mail.use"}]
      },
      %{module: "prototypes", permissions: ~w(prototypes.read prototypes.publish)},
      %{
        module: "experiments",
        permissions: ~w(experiments.read experiments.propose),
        rail: [%{key: :experiments, permission: "experiments.read"}]
      },
      %{module: "agents", permissions: ~w(agents.manage_own agents.manage_all)},
      %{
        module: "skills",
        permissions: ~w(skills.read skills.write),
        rail: [%{key: :skills, permission: "skills.read"}]
      },
      %{module: "vault", permissions: ~w(vault.use)},
      %{
        module: "prompts",
        permissions: ["prompts.read", %{name: "prompts.manage", module_admin: true}],
        rail: [%{key: :prompts, permission: "prompts.manage"}]
      },
      %{module: "access", permissions: ~w(access.manage)},
      %{
        module: "install",
        permissions: [%{name: "install.admin", install_level: true}],
        rail: [%{key: :admin, permission: "install.admin"}]
      },
      %{
        module: "mcp",
        permissions: @core_bundle_permissions |> Map.values() |> Enum.sort(),
        bundles: @core_bundle_permissions
      }
    ]
  end
end
