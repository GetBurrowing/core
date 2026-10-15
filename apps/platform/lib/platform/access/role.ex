defmodule Platform.Access.Role do
  @moduledoc """
  Ecto schema for `access_roles`: a role is a named permission set, stored as
  data (task `01a1386d-cb5c`, `0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles`).

  Not `Platform.Roles.Role`: that is the agent responsibility system (the
  Historian pin). This table is human and agent authorization.

  ## Fields

    * `key` — unique. The built-in rows are `admin`, `member` and `guest`;
      `org_memberships.access_role_key` references this column.
    * `name` — display name.
    * `builtin` — true for the three rows the migration seeds.
    * `permissions` — `%{permission => grant_rule}`.
    * `org_id` — NULL on the built-in rows; the owning org of a custom role
      (task `01a1386e-59d1` stage 1).

  ## Custom roles

  A custom role is a row with `builtin: false`, an `org_id` and the key
  `"custom:" <> uuidv7` (minted by `Platform.Access.Roles`, never by a
  caller). `custom_changeset/2` validates it: every permission must be
  registered, none install-level or derived, and every rule one of `all`,
  `membership_org` and `participant_spaces` (or a list of them).
  `implicit_or_participant` is the built-in `member` role's kind admission
  and is not offered to custom roles.

  ## Grant rules are data, never a resource id

  A grant rule is one of `Platform.Access.Registry.grant_rules/0`:
  `"all"`, `"membership_org"`, `"participant_spaces"` or
  `"implicit_or_participant"`. A role cannot store a resource id, because
  `admin` and `member` are relative to the org of the membership that carries
  them; the Scope builder resolves each rule against that membership.

  A rule may also be a list of those values, meaning their union. The ADR's
  `member` holds `canvas.read` "under participation or `membership_org` org
  reach", which no single rule expresses; it is stored as
  `["participant_spaces", "membership_org"]` rather than inventing a fifth
  rule value.

  A role carries no deny, and no role may carry an install-level permission
  (`Platform.Access.Registry.install_level_permissions/0`) or a derived one
  (`Platform.Access.Registry.derived_permissions/0`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Access.Registry

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "access_roles" do
    field(:key, :string)
    field(:name, :string)
    field(:builtin, :boolean, default: false)
    field(:permissions, :map, default: %{})
    belongs_to(:org, Platform.Tenancy.Org, type: :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset. Validates every permission against the registry and every rule's shape."
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:key, :name, :builtin, :permissions])
    |> validate_required([:key, :name])
    |> validate_permissions()
    |> unique_constraint(:key)
  end

  @custom_rules ~w(all membership_org participant_spaces)

  @doc "The grant-rule values a custom role may use."
  @spec custom_rules() :: [String.t()]
  def custom_rules, do: @custom_rules

  @doc """
  Changeset for a CUSTOM role. `key`, `org_id` and `builtin: false` are set
  by `Platform.Access.Roles`, never cast from caller attrs; only `name` and
  `permissions` are cast.
  """
  def custom_changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :permissions])
    |> validate_required([:key, :name, :org_id])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_change(:builtin, fn :builtin, builtin ->
      if builtin, do: [builtin: "a custom role cannot be built-in"], else: []
    end)
    |> validate_permissions()
    |> validate_custom_rules()
    |> unique_constraint(:key)
    |> unique_constraint(:name, name: :access_roles_org_name_index)
    |> check_constraint(:org_id, name: :access_roles_custom_org_check)
    |> foreign_key_constraint(:org_id)
  end

  defp validate_custom_rules(changeset) do
    validate_change(changeset, :permissions, fn :permissions, permissions ->
      Enum.flat_map(permissions, fn {permission, rule} ->
        rules = if is_list(rule), do: rule, else: [rule]

        if Enum.all?(rules, &(&1 in @custom_rules)),
          do: [],
          else: [permissions: "#{permission} has a rule a custom role may not use"]
      end)
    end)
  end

  @doc "Is `rule` a valid grant rule value (one rule, or a non-empty list of distinct rules)?"
  @spec valid_rule?(term()) :: boolean()
  def valid_rule?(rule) when is_binary(rule), do: rule in Registry.grant_rules()

  def valid_rule?([_ | _] = rules),
    do: Enum.all?(rules, &(&1 in Registry.grant_rules())) and Enum.uniq(rules) == rules

  def valid_rule?(_), do: false

  defp validate_permissions(changeset) do
    validate_change(changeset, :permissions, fn :permissions, permissions ->
      Enum.flat_map(permissions, fn {permission, rule} ->
        cond do
          not Registry.permission?(permission) ->
            [permissions: "#{inspect(permission)} is not a registered permission"]

          Registry.install_level?(permission) ->
            [permissions: "#{permission} is install-level and no role may carry it"]

          Registry.derived?(permission) ->
            [permissions: "#{permission} is derived by a Scope rule and no role may carry it"]

          not valid_rule?(rule) ->
            [permissions: "#{permission} has an invalid grant rule #{inspect(rule)}"]

          true ->
            []
        end
      end)
    end)
  end
end
