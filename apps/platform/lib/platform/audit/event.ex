defmodule Platform.Audit.Event do
  @moduledoc """
  An immutable audit event. Append-only — never updated or deleted.

  Events are the primary data in the audit stream. Current state is
  always derivable by folding (`Enum.reduce/3`) over a sequence of events.

  ## Actor types

  `actor_type` is an application-side enum (no DB enum) with these
  canonical values (see `actor_types/0`):

    * `"system"` — the platform itself (default for unattributed events)
    * `"user"` — an authenticated end-user in this org
    * `"agent"` — an AI agent invocation (intra-org)
    * `"anonymous"` — an unauthenticated request (access-blocked events,
      pre-auth diagnostic events)
    * `"federated_user"` — a user invoking from a peer org via federation,
      typically referenced by an opaque `Platform.Federation.OwnerHandle`
      rather than a real user_id (see ADR 0040 §D4)

  When `actor_type` is `"federated_user"`, `actor_id` carries the pseudonymous
  handle, NOT a `users.id`.

  ## Org scoping

  `actor_org_id` (added per ADR 0040) identifies the org owning the actor.
  NULL for legacy rows and intra-org events where the org is implicit. For
  federated events it identifies the peer org that originated the invocation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  # Application-side enum for actor_type. Validated by changeset.
  # See @moduledoc for semantics.
  @actor_types ~w(system user agent anonymous federated_user)

  schema "audit_events" do
    field(:event_type, :string)
    field(:actor_id, Ecto.UUID)
    field(:actor_type, :string, default: "system")
    field(:actor_org_id, Ecto.UUID)
    field(:resource_type, :string)
    field(:resource_id, :string)
    field(:action, :string)
    field(:metadata, :map, default: %{})
    field(:session_id, :string)
    field(:ip_address, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields ~w(event_type actor_type action)a
  @optional_fields ~w(actor_id actor_org_id resource_type resource_id metadata session_id ip_address)a

  def actor_types, do: @actor_types

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:actor_type, @actor_types)
  end
end
