defmodule Platform.Accounts.ExternalAdmission do
  @moduledoc """
  The single backend that decides, on EVERY login, whether a user is fully
  provisioned or must fall into the graceful **holding** state — the
  fail-closed-on-ACCESS core of stack member 2 (`rbac-external-users`).

  Optimistic full provisioning: if a pre-staged grant matches the login, the
  user is materialized (external membership + chat participants + per-org DM
  allowlist) via the M1 seam and admitted `:full`. ANY shortfall degrades to
  `:holding` — never a dead-end refuse. A holding admission writes **zero**
  scoped rows (membership/participant/allowlist). The only real refusal is
  `{:error, :user_archived}`, which propagates straight through from the
  accounts seam (archived is an access decision, not a black-hole).

  ## The `%Result{}` seam (consumed by M3)

  `admit/2` and `recover/3` return a `%Platform.Accounts.ExternalAdmission.Result{}`:

    * `:user`      — the resolved `%Platform.Accounts.User{}`
    * `:state`     — `:full` | `:holding`
    * `:reason`    — `nil` (full) | `:awaiting_grant` | `:missing_claim` | `:unknown`
    * `:external?` — whether this login is an external one

  The OIDC callback stores `%{state: :holding, reason:, user_id:}` under the
  `:external_admission` session key; M3 branches on that to render the holding
  surface. Keep this struct small — it is a public contract.

  ## Live-recovery seam (consumed by M3)

  An admin who forgot to stage a grant can call `recover/3` to live-apply it.
  On success this BROADCASTS, on `Platform.PubSub`:

      {:external_admission, :recovered, target_user_id, %Result{state: :full, external?: true}}

  on the topic `external_admission_topic(target_user_id)`, i.e.
  `"external_admission:\#{target_user_id}"`. M3's holding LiveView subscribes to
  that topic on mount and, on the `:recovered` message, live-navigates to the
  full surface — no re-auth, no new `find_or_create_from_oidc`.

  ## Telemetry

  Emits `[:platform, :auth, :external_admission]` with metadata
  `%{action: "full" | "holding" | "recovered", reason:, email:, actor_id:, external?:}`.
  This is the admin-notification signal M3/M13 bridge; M2 only emits.
  """

  alias Platform.Accounts
  alias Platform.Accounts.ExternalAdmission.Result
  alias Platform.Tenancy
  alias Platform.Tenancy.ExternalGrants
  alias Platform.Tenancy.PendingExternalGrant

  @telemetry_event [:platform, :auth, :external_admission]

  defmodule Result do
    @moduledoc "The admission decision M3 consumes. See `ExternalAdmission`."
    @enforce_keys [:user, :state, :external?]
    defstruct [:user, :state, :reason, :external?]

    @type state :: :full | :holding
    @type reason :: nil | :awaiting_grant | :missing_claim | :unknown

    @type t :: %__MODULE__{
            user: Platform.Accounts.User.t(),
            state: state(),
            reason: reason(),
            external?: boolean()
          }
  end

  @doc """
  Admit a login. `oidc_user` is the normalized claims map from the auth
  controller (`%{sub:, email:, name:, external_claim?:}`). `opts` carries
  `surface: :app | :external` (default `:app`); the callback derives
  `:external` from a `chat.`-host check.

  Returns a `%Result{}` on success, or propagates `{:error, reason}` from
  `find_or_create_from_oidc/1` (e.g. `{:error, :user_archived}`) unchanged.
  """
  @spec admit(map(), keyword()) :: Result.t() | {:error, any()}
  def admit(oidc_user, opts \\ []) when is_map(oidc_user) do
    surface = Keyword.get(opts, :surface, :app)

    case Accounts.find_or_create_from_oidc(oidc_user) do
      {:ok, user} -> decide(user, oidc_user, surface)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Post-login redirect target for a result. `:full` and `:holding` both land
  on `"/chat"` (a valid existing route) for now — no dead-end even before M3
  ships the dedicated holding surface. M3 branches on the `:external_admission`
  session key to render the holding UI on whatever route it owns.
  """
  @spec post_login_path(Result.t()) :: String.t()
  def post_login_path(%Result{state: :full}), do: "/chat"
  def post_login_path(%Result{state: :holding}), do: "/chat"

  @doc """
  PubSub topic for a target user's admission events. Single source of truth
  for both the `recover/3` broadcast and M3's subscribe.
  """
  @spec external_admission_topic(binary()) :: String.t()
  def external_admission_topic(user_id) when is_binary(user_id),
    do: "external_admission:#{user_id}"

  @doc """
  Admin-invoked live re-entry for a holding (black-holed) user. Accepts either
  a `%PendingExternalGrant{}` or an attrs map (from which a grant is created via
  `ExternalGrants.create_grant/1`). Applies the grant (idempotent — a double
  recover is a harmless no-op) and BROADCASTS
  `{:external_admission, :recovered, target_user.id, %Result{state: :full}}`
  on `external_admission_topic(target_user.id)` so a waiting tab upgrades
  without re-auth. NEVER calls back into `find_or_create_from_oidc/1` — the
  user id is stable; recovery is not a re-login.

  Returns `{:ok, %Result{state: :full}}`.
  """
  @spec recover(map(), map(), PendingExternalGrant.t() | map()) ::
          {:ok, Result.t()} | {:error, any()}
  def recover(_admin_user, %{id: _} = target_user, %PendingExternalGrant{} = grant) do
    do_recover(target_user, grant)
  end

  def recover(_admin_user, %{id: _} = target_user, attrs) when is_map(attrs) do
    case ExternalGrants.create_grant(attrs) do
      {:ok, grant} -> do_recover(target_user, grant)
      {:error, _reason} = error -> error
    end
  end

  # -- internals --

  defp decide(user, oidc_user, surface) do
    external_claim? = Map.get(oidc_user, :external_claim?, false)

    case ExternalGrants.lookup_by_email_or_sub(%{email: user.email, sub: user.oidc_sub}) do
      %PendingExternalGrant{} = grant ->
        # Optimistic full provisioning. apply_grant/2 is idempotent (M1
        # `applied_at` guard + upserts), so a double login never
        # double-provisions.
        {:ok, _applied} = ExternalGrants.apply_grant(grant, user)
        emit(%Result{user: user, state: :full, reason: nil, external?: true})

      nil ->
        cond do
          # Already-provisioned external user returning. The grant that
          # provisioned them is invisible to lookup (`applied_at` stamped), so
          # we recognize them via the M1 marker instead — a repeat login stays
          # :full and never re-provisions (idempotent) and never black-holes a
          # user we already admitted.
          Tenancy.external_user?(user) ->
            emit(%Result{user: user, state: :full, reason: nil, external?: true})

          # Flagged external but nothing staged — fail-closed: establish ZERO
          # scoped rows and wait for a grant (admin can `recover/3`).
          external_claim? ->
            emit(%Result{user: user, state: :holding, reason: :awaiting_grant, external?: true})

          # Arrived on the external surface with no marker — misconfiguration,
          # hold. (`:unknown` is reserved in the Result type for M3; M2 uses
          # `:missing_claim` for the surface-external no-marker case.)
          surface == :external ->
            emit(%Result{user: user, state: :holding, reason: :missing_claim, external?: false})

          # Ordinary internal login — UNCHANGED. NEVER black-hole an internal
          # user; role is governed entirely by `derive_role_from_email/1`.
          true ->
            emit(%Result{user: user, state: :full, reason: nil, external?: false})
        end
    end
  end

  defp do_recover(target_user, grant) do
    {:ok, _applied} = ExternalGrants.apply_grant(grant, target_user)

    result = %Result{user: target_user, state: :full, reason: nil, external?: true}

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      external_admission_topic(target_user.id),
      {:external_admission, :recovered, target_user.id, result}
    )

    emit(result, "recovered")
    {:ok, result}
  end

  # Emit telemetry and return the result (so callers can tail-return it).
  defp emit(result, action \\ nil)

  defp emit(
         %Result{state: state, reason: reason, external?: external?, user: user} = result,
         action
       ) do
    :telemetry.execute(
      @telemetry_event,
      %{system_time: System.system_time()},
      %{
        action: action || Atom.to_string(state),
        reason: reason,
        email: user.email,
        actor_id: user.id,
        external?: external?
      }
    )

    result
  end
end
