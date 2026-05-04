defmodule Platform.Federation.InvocationVisibilityGrant do
  @moduledoc """
  Cross-party visibility grant for a federated agent invocation.

  Per ADR 0040 §D2 (delegated visibility). Reserves the schema slot for a
  future case where org A delegates visibility into a specific invocation
  back to a user in org B (for example: a guest collaborator from another
  org observing an agent's reasoning in our space).

  Stage 1: schema declared, no callers. The Stage 2 visibility filter
  consults this table via:

      WHERE (re.invoked_by_user_id, re.owner_org_id) = subscriber_tuple
        OR EXISTS (
          SELECT 1 FROM invocation_visibility_grants g
          WHERE g.invocation_id = re.id
            AND g.grantee_user_id = subscriber.user_id
            AND g.revoked_at IS NULL
            AND (g.expires_at IS NULL OR g.expires_at > now())
        )

  Stage 2 wires the filter — the EXISTS always returns false in Stage 1.
  Stage 3 or beyond decides governance for who can grant.

  ## Grant scopes

  `scope` is an application-side enum (see `grant_scopes/0`):

    * `"read_thinking_stream"` — grantee can subscribe to the thinking-stream
      PubSub topic for this invocation
    * `"read_audit"` — grantee can read the audit-log entries scoped to this
      invocation

  Future scopes (configuration read, kill rights, etc.) require their own
  governance review per ADR 0040 §D2.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @grant_scopes ~w(read_thinking_stream read_audit)

  schema "invocation_visibility_grants" do
    field(:invocation_id, :binary_id)
    field(:grantee_user_id, Ecto.UUID)
    field(:grantee_org_id, :binary_id)
    field(:granted_by_user_id, Ecto.UUID)
    field(:granted_by_org_id, :binary_id)
    field(:scope, :string)
    field(:granted_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:revocation_reason, :string)
    field(:expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def grant_scopes, do: @grant_scopes

  @required_fields ~w(invocation_id grantee_user_id grantee_org_id granted_by_user_id granted_by_org_id scope)a
  @optional_fields ~w(granted_at revoked_at revocation_reason expires_at)a

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:scope, @grant_scopes)
    |> unique_constraint([:invocation_id, :grantee_user_id, :scope],
      name: :invocation_visibility_grants_unique_active_idx,
      message: "an active grant already exists for this (invocation, grantee, scope) tuple"
    )
  end
end
