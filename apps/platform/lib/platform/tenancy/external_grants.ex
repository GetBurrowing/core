defmodule Platform.Tenancy.ExternalGrants do
  @moduledoc """
  Context for `pending_external_grants` (stack member 1, rbac-external-users,
  stage 3).

  An operator pre-stages a grant before an external user's first login; M2
  (login provisioning) consumes it via `apply_grant/2` after
  `Platform.Accounts.find_or_create_from_oidc/1` resolves the user.

  This module owns **how** a staged grant becomes state; M2 owns **when**
  (it calls `lookup_by_email_or_sub/1` with the OIDC claims, then
  `apply_grant/2`). The write is self-contained here and reuses the stage-1
  external-membership helper (`Platform.Tenancy.mark_membership_external/1`),
  the stage-2 DM-allowlist helper (`Platform.Tenancy.allow_dm/2`), and
  `Platform.Chat.Participant.changeset/2`.
  """

  import Ecto.Query

  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.PendingExternalGrant

  @doc """
  Create a pending external grant. Accepts an attrs map (see
  `Platform.Tenancy.PendingExternalGrant.changeset/2`). At least one of
  `:email` / `:oidc_sub` and a `:target_org_id` are required.
  """
  @spec create_grant(map()) ::
          {:ok, PendingExternalGrant.t()} | {:error, Ecto.Changeset.t()}
  def create_grant(attrs) when is_map(attrs) do
    %PendingExternalGrant{}
    |> PendingExternalGrant.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Look up the unapplied grant matching an OIDC identity.

  Accepts `%{email: e, sub: s}` — either may be `nil`. Matches
  `email == e OR oidc_sub == s`, but **only for values that are present**:
  a `nil`/blank identity contributes no condition, so a NULL column is
  never matched against a NULL claim. When neither identity is present, or
  nothing matches, returns `nil`.

  Only grants with `applied_at IS NULL` are considered — an already-applied
  grant is invisible to lookup.
  """
  @spec lookup_by_email_or_sub(map()) :: PendingExternalGrant.t() | nil
  def lookup_by_email_or_sub(ident) when is_map(ident) do
    email = ident |> fetch_ident(:email) |> presence()
    sub = ident |> fetch_ident(:sub) |> presence()

    base = from(g in PendingExternalGrant, where: is_nil(g.applied_at))

    query =
      cond do
        email && sub -> where(base, [g], g.email == ^email or g.oidc_sub == ^sub)
        email -> where(base, [g], g.email == ^email)
        sub -> where(base, [g], g.oidc_sub == ^sub)
        # Neither identity present — match nothing (never NULL == NULL).
        true -> where(base, [g], false)
      end

    query |> limit(1) |> Repo.one()
  end

  @doc """
  Apply a pending grant for a resolved user, materializing all of its
  state in a single transaction:

    1. upsert an `external: true` org_membership at `target_org_id`
       (role `"member"`) via `Platform.Tenancy.mark_membership_external/1`;
    2. insert a `chat_participants` row per `space_grants` entry
       (`Platform.Chat.Participant.changeset/2`, idempotent on the
       `chat_participants_unique` index);
    3. seed a per-org DM allowlist entry per `dm_allowlist_org_ids` via
       `Platform.Tenancy.allow_dm/2`;
    4. stamp `applied_at`.

  **Idempotent.** The grant row is locked `FOR UPDATE` and re-read inside
  the transaction; if `applied_at` is already set the whole call is a
  no-op that returns `{:ok, grant}` — a double login can't double-provision.

  Returns `{:ok, grant}` (with `applied_at` set) or `{:error, reason}`.
  """
  @spec apply_grant(PendingExternalGrant.t(), %{:id => binary(), optional(atom()) => any()}) ::
          {:ok, PendingExternalGrant.t()} | {:error, any()}
  def apply_grant(%PendingExternalGrant{id: grant_id}, %{id: user_id})
      when is_binary(user_id) do
    Repo.transaction(fn ->
      grant =
        PendingExternalGrant
        |> where([g], g.id == ^grant_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if grant.applied_at do
        # Already applied — idempotent no-op.
        grant
      else
        apply_all(grant, user_id)
      end
    end)
  end

  @doc "Delete a pending grant."
  @spec delete_grant(PendingExternalGrant.t()) ::
          {:ok, PendingExternalGrant.t()} | {:error, Ecto.Changeset.t()}
  def delete_grant(%PendingExternalGrant{} = grant), do: Repo.delete(grant)

  # ── internals ─────────────────────────────────────────────────────────

  # Runs every provisioning step; on the first failure `Repo.rollback/1`
  # aborts the transaction so nothing is half-applied.
  defp apply_all(grant, user_id) do
    with {:ok, _membership} <-
           Tenancy.mark_membership_external(%{
             user_id: user_id,
             org_id: grant.target_org_id,
             role: "member"
           }),
         :ok <- add_participants(grant.space_grants, user_id),
         :ok <- add_dm_allowlist(grant.dm_allowlist_org_ids, user_id),
         {:ok, applied} <- stamp_applied(grant) do
      applied
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp add_participants(space_grants, user_id) when is_list(space_grants) do
    now = DateTime.utc_now()

    Enum.reduce_while(space_grants, :ok, fn entry, :ok ->
      space_id = map_get(entry, "space_id")
      role = map_get(entry, "role") || "member"

      attrs = %{
        space_id: space_id,
        participant_type: "user",
        participant_id: user_id,
        role: role,
        joined_at: now
      }

      %Participant{}
      |> Participant.changeset(attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:space_id, :participant_type, :participant_id]
      )
      |> case do
        {:ok, _participant} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp add_participants(_, _), do: :ok

  defp add_dm_allowlist(org_ids, user_id) when is_list(org_ids) do
    Enum.reduce_while(org_ids, :ok, fn org_id, :ok ->
      case Tenancy.allow_dm(user_id, org_id) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp add_dm_allowlist(_, _), do: :ok

  defp stamp_applied(grant) do
    grant
    |> Ecto.Changeset.change(applied_at: DateTime.utc_now())
    |> Repo.update()
  end

  # jsonb round-trips with string keys; tolerate atom keys too for
  # in-process callers.
  defp map_get(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp map_get(_, _), do: nil

  defp fetch_ident(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp presence(nil), do: nil
  defp presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp presence(_), do: nil
end
