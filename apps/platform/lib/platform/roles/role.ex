defmodule Platform.Roles.Role do
  @moduledoc """
  Schema for the `roles` table — the platform-fixed registry of agent
  roles (M4 stage 1 of task 019ef65b-a361).

  A role pins together a stable identifier, presentation metadata, and
  (via `role_responsibilities`) the bundle of responsibility keys the
  role fulfills.

    * `key` — the natural primary key. One of the closed enum
      `designer | historian | meeting_scribe |
      triage_officer | security_guard | architect | agents_leader |
      scientist | janitor | showrunner | doctor | relationship_steward`
      (stack decision #2:
      role roster is fixed by the platform, not user-extensible).
      Enforced by both the changeset and a DB CHECK constraint,
      mirroring `org_memberships.role`. `architect` was added in
      ADR-0044 stage 1 (task `019f3da3`) as the closed-roster owner of
      the three `architecture.*` responsibility keys. `agents_leader`
      was added in task `01a0b491` stage 1 as the owner of
      `agents.goal_heartbeat`. `scientist` was added in task `01a0d415`
      stage 3 (the experimentation-layer ADR-0052) as the owner of
      `experiments.label_signal`. `janitor` was added in task `019fa1ac-6685`
      stage 1 as the owner of `janitor.cron_drain`, the weekly chore drain.
      `showrunner` was added in task `01a1eaf6` stage 3 as the owner of the
      How to Computer `showrunner.*` keys. `meeting_producer` was merged
      into `meeting_scribe` in the super agents restructure; see
      `retired_keys/0`. `doctor` (`doctor.checkup`) and
      `relationship_steward` (`relationships.follow_up_sweep`) are the two
      super-agent roles the sponsor approved on 2026-11-18.
    * `name` — human-presentable label.
    * `description` — one-line explanation of what the role owns.
    * `icon` — hero-icon slug (e.g. `hero-paint-brush`).

  `has_many :role_responsibilities` exposes the bundle for callers that
  want the join rows directly; the `Platform.Roles` context (Stage 3)
  is the canonical surface for `bundle_for/1` lookups.

  Only the schema and changeset live here — the context module,
  resolver, and seeding all land in later stages of M4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Roles.RoleResponsibility

  @primary_key {:key, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :key}
  @foreign_key_type :string

  @valid_keys ~w(designer historian meeting_scribe triage_officer security_guard architect agents_leader scientist janitor showrunner doctor relationship_steward)

  # Role keys that no longer exist, mapped to the role that absorbed them.
  # Read paths (`Platform.Roles.get_role/1`, `bundle_for/1`,
  # `agent_id_for_role/1`, ...) resolve a retired key through
  # `canonical_key/1`, so a caller or persisted reference still holding the
  # old key reads the absorbing role instead of an empty one.
  @retired_keys %{"meeting_producer" => "meeting_scribe"}

  schema "roles" do
    field(:name, :string)
    field(:description, :string)
    field(:icon, :string)

    has_many(:role_responsibilities, RoleResponsibility,
      foreign_key: :role_key,
      references: :key
    )

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid `key` values. Exposed for use by stage 4's
  seed module so the canonical roster isn't string-duplicated.
  """
  def valid_keys, do: @valid_keys

  @doc "Retired role keys mapped to the role that absorbed each one."
  @spec retired_keys() :: %{String.t() => String.t()}
  def retired_keys, do: @retired_keys

  @doc """
  The live role key for `key`: the absorbing role for a retired key, `key`
  itself otherwise.

      iex> Platform.Roles.Role.canonical_key("meeting_producer")
      "meeting_scribe"

      iex> Platform.Roles.Role.canonical_key("designer")
      "designer"
  """
  @spec canonical_key(String.t()) :: String.t()
  def canonical_key(key) when is_binary(key), do: Map.get(@retired_keys, key, key)

  @cast_fields ~w(key name description icon)a
  @required_fields ~w(key name description icon)a

  @doc """
  Changeset for inserting or updating a role.

  Validates required fields, `key` membership in the closed enum, and
  attaches a unique constraint on `key` so duplicate inserts surface as
  a changeset error rather than a Postgrex raise.
  """
  def changeset(role, attrs) do
    role
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:key, @valid_keys)
    |> unique_constraint(:key, name: :roles_pkey)
  end
end
