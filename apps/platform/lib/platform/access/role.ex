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
