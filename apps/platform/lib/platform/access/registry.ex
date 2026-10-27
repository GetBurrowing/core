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

  ## What reads it for a decision

  The rail entry's required permission is read by
  `Platform.Access.module_access?/3` (task `01a1386d-fb6e` stage 1), which
  the shell rail filters through. Per-tool authorization is a later stack
  member: the `mcp.<bundle>`
  permissions are the transitional per-bundle vocabulary the shadow
  `Scope.for_runtime/1` and the equivalence test use, which a per-tool map
  supersedes (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Agents`).

  ## Install-level and module-admin permissions

  `install.admin` is flagged `install_level: true`: no role carries it and no
  grant may name it. `tasks.manage` and `prompts.manage` are module-admin
  permissions: no built-in role carries them either, and with no grants they
  are held only through the root-admin rule
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles`).

  ## Derived permissions

  `orgs.read` is flagged `derived: true`. It is org visibility, the quantity
  `Platform.Tenancy.visibility/1` answers, and it is produced only by the
  root-org widening rule in `Platform.Access.Scope` (`:all` for a member of a
  root org at any role, otherwise the membership org ids). It is code, not
  role data (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles`,
  "Two rules are code, not role data"), so no role may carry it. The ADR's
  vocabulary has no name for org visibility; this one was added by task
  `01a1386d-cb5c` stage 2 so the widening has a permission to land on.

  ## Guest-admissible rail entries

  A rail entry may carry `guest_admissible: true` (task `01a1386d-fb6e`
  stage 1;
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Permission model`,
  "Rail rule"). A guest scope is shown an entry only when it carries
  the flag AND holds the entry's permission anywhere
  (`Platform.Access.module_access?/3`). It exists because a guest admitted
  into a module whose LiveView reads are not yet Scope-filtered would see
  everything in it. Only `:chat` carries it; an entry that omits the flag,
  including every extension's, is `false`.

  ## Modules the ADR vocabulary does not name

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
          module_admin: boolean(),
          derived: boolean()
        }

  @typedoc """
  A normalized rail entry: the destination key, the permission it requires,
  and whether a guest scope may be shown it (`guest_admissible`, default
  `false`; see "Guest-admissible rail entries" in the moduledoc).
  """
  @type rail_entry :: %{
          key: atom(),
          permission: String.t(),
          module: String.t(),
          guest_admissible: boolean()
        }

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
    "prototype" => "mcp.prototype",
    "access" => "mcp.access",
    "admin" => "mcp.admin"
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

  @doc """
  The `:module` name declaring `permission` (`"tasks.read"` -> `"tasks"`),
  or nil for an undeclared permission. Read by the module lock
  (`Platform.Access.locked?/2`, task 01a14721 stage 2).
  """
  @spec module_of(String.t()) :: String.t() | nil
  def module_of(permission) when is_binary(permission),
    do: Enum.find_value(permissions(), fn p -> p.name == permission && p.module end)

  def module_of(_), do: nil

  @doc "The permissions `module` declares, normalized, in declaration order."
  @spec module_permissions(String.t()) :: [permission()]
  def module_permissions(module) when is_binary(module),
    do: Enum.filter(permissions(), &(&1.module == module))

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

  @doc "Permission names flagged `derived: true` (produced by a Scope rule, never by a role)."
  @spec derived_permissions() :: [String.t()]
  def derived_permissions,
    do: for(p <- permissions(), p.derived, do: p.name)

  @doc "Is `name` a derived permission?"
  @spec derived?(String.t()) :: boolean()
  def derived?(name), do: name in derived_permissions()

  @doc "Every rail entry with the permission it requires and its `guest_admissible` flag."
  @spec rail_entries() :: [rail_entry()]
  def rail_entries do
    for mod <- modules(), entry <- Map.get(mod, :rail, []) do
      %{
        key: entry.key,
        permission: entry.permission,
        module: mod.module,
        guest_admissible: Map.get(entry, :guest_admissible, false) == true
      }
    end
  end

  @doc "The rail entry for destination `key`, or nil when no module declares one."
  @spec rail_entry(atom()) :: rail_entry() | nil
  def rail_entry(key), do: Enum.find(rail_entries(), &(&1.key == key))

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
    do: %{name: name, module: module, install_level: false, module_admin: false, derived: false}

  defp normalize_permission(%{name: name} = entry, module) do
    %{
      name: name,
      module: module,
      install_level: Map.get(entry, :install_level, false) == true,
      module_admin: Map.get(entry, :module_admin, false) == true,
      derived: Map.get(entry, :derived, false) == true
    }
  end

  defp core_modules do
    [
      %{
        module: "chat",
        permissions: ~w(chat.read chat.write chat.manage),
        # The only guest-admissible entry (task 01a1386d-fb6e stage 1): Chat
        # reads are already participant-scoped for a guest (ExternalScope).
        rail: [%{key: :chat, permission: "chat.read", guest_admissible: true}]
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
      # The `activity` module, its `activity.read` permission and this rail
      # entry outlived the Activity page (retired by task 01a1557a-7a71 stage
      # 4). They now gate /changelog: `PlatformWeb.ModuleGate` maps
      # ChangelogLive to {:activity, nil} and `Access.module_access?/3`
      # resolves it through `rail_entry(:activity)`, failing CLOSED without
      # it. `activity.read` is also persisted in role grants. Do not remove.
      %{
        module: "activity",
        permissions: ~w(activity.read),
        # `:changelog` (task 01a1557a-807f stage 2) is the More sheet's
        # Changelog row. Same permission ModuleGate asks of ChangelogLive
        # (`{:activity, nil}`), so the row shows exactly when /changelog
        # mounts. `:activity` stays: ModuleGate resolves ChangelogLive
        # through it (see above).
        rail: [
          %{key: :activity, permission: "activity.read"},
          %{key: :changelog, permission: "activity.read"}
        ]
      },
      %{
        module: "files",
        permissions: ~w(files.read files.write),
        # `:canvases` (task 01a1557a-b5f9 stage 3) is the More sheet's
        # Canvases row, which opens the Files browser filtered to canvases
        # (`/files?tab=browse&type=canvas`, FilesLive). Same permission as the
        # page it opens, so the row shows exactly when /files mounts.
        # `:games` (task 01a1557a-efdd stage 1) is the same browser filtered
        # to games (`/files?tab=browse&type=game`).
        rail: [
          %{key: :files, permission: "files.read"},
          %{key: :canvases, permission: "files.read"},
          %{key: :games, permission: "files.read"}
        ]
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
        # `:voice` (task 01a1557a-eab7 stage 2): the Voice tab rides the
        # meetings LiveKit + transcription pipeline, so it asks the same
        # permission ModuleGate asks of VoiceLive (`{:voice, nil}`).
        rail: [
          %{key: :meetings, permission: "meetings.join"},
          %{key: :voice, permission: "meetings.join"}
        ]
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
      %{
        module: "agents",
        permissions: ~w(agents.manage_own agents.manage_all),
        rail: [%{key: :agents, permission: "agents.manage_own"}]
      },
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
      # Task 01a17b10 stage 3: the `admin` MCP bundle's tools. A module-admin
      # permission, like `prompts.manage`: no role carries it, and root admins
      # hold it through `Scope.grant_root_admin/3`, so an agent (capped at its
      # owner) holds it only when its owner is a root admin. No role migration.
      %{module: "admin", permissions: [%{name: "admin.use", module_admin: true}]},
      %{module: "orgs", permissions: [%{name: "orgs.read", derived: true}]},
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
