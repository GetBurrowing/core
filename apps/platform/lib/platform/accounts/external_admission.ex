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
    * `:suggested_org_id` — (task 019ff7ff stage 2) the org the login's IdP
      group claim names, when EXACTLY ONE distinct org matched. `nil` in every
      other case, including `:ambiguous` — an ambiguous match is not a match,
      and there is deliberately no fallback to a default/first org.
    * `:group_match` — `:one` | `:none` | `:ambiguous`; how the group-claim
      resolution went. `:none` on any non-external result.

  The suggestion is a SUGGESTION: it changes nothing about what admission
  *does*. A holding login still lands `state: :holding, reason: :awaiting_grant`
  and still writes ZERO scoped rows (no membership, no participant, no
  allowlist) whatever `group_match` says. Nothing auto-grants off the back of
  it — an admin still applies a grant via `recover/3`.

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
  `%{action: "full" | "holding" | "recovered", reason:, email:, actor_id:,
  external?:, group_match:}` plus `external_groups` (the raw group values,
  possibly `[]`) and `suggested_org_id` when one is resolved (`suggested_org_id`
  is OMITTED rather than set to nil — the audit handler stringifies atoms and
  would persist nil as `"nil"`).
  This is the admin-notification signal M3/M13 bridge; M2 only emits.
  """

  alias Platform.Accounts
  alias Platform.Accounts.ExternalAdmission.Result
  alias Platform.Access.IdpGroupRoles
  alias Platform.Tenancy
  alias Platform.Tenancy.ExternalGrants
  alias Platform.Tenancy.PendingExternalGrant

  @telemetry_event [:platform, :auth, :external_admission]

  # Lookback window + scan cap for `awaiting_setup/0`. Holding logins are
  # rare; a 30-day window at 500 rows comfortably covers a live queue
  # without an unbounded scan.
  @awaiting_lookback_days 30
  @awaiting_scan_limit 500

  defmodule Result do
    @moduledoc "The admission decision M3 consumes. See `ExternalAdmission`."
    @enforce_keys [:user, :state, :external?]
    defstruct [
      :user,
      :state,
      :reason,
      :external?,
      :suggested_org_id,
      :external_groups,
      group_match: :none
    ]

    @type state :: :full | :holding
    @type reason :: nil | :awaiting_grant | :missing_claim | :unknown
    @type group_match :: :one | :none | :ambiguous

    @type t :: %__MODULE__{
            user: Platform.Accounts.User.t(),
            state: state(),
            reason: reason(),
            external?: boolean(),
            suggested_org_id: binary() | nil,
            external_groups: [String.t()] | nil,
            group_match: group_match()
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
      {:ok, user} ->
        result = decide(user, oidc_user, surface)

        case maybe_sync_idp_roles(result, oidc_user) do
          {:ok, counts} -> emit(result, nil, counts)
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} = error -> error
    end
  end

  @doc """
  Post-login redirect target for a result. `:full` lands on `"/chat"`;
  `:holding` lands on `"/welcome"` — the dedicated holding surface M3
  ships (`PlatformWeb.ExternalHoldingLive`). M2 built this fn as the seam
  M3 flips; the `:holding` clause was a `/chat` placeholder until M3 stood
  up the holding landing. The holding LiveView branches on the
  `:external_admission` session key and, for a non-holding session, bounces
  an ordinary internal user straight to `/chat`.
  """
  @spec post_login_path(Result.t()) :: String.t()
  def post_login_path(%Result{state: :full}), do: "/chat"
  def post_login_path(%Result{state: :holding}), do: "/welcome"

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

  @doc """
  The admin recovery queue's backing rows: external logins still awaiting
  setup (M3 stage 4 consumes this).

  Reads the DURABLE queue source stage 3 established — recent
  `platform.auth.external_admission` / action `"holding"` `Audit.Event`
  rows — dedups by `actor_id` (keeping the most-recent login per user),
  resolves each to a `%User{}`, and DROPS any user who is now provisioned
  (holds an external `org_membership` via `Tenancy.external_user?/1`, i.e.
  a grant already applied). What remains is genuinely-still-holding logins.

  Returns a list of
  `%{user:, user_id:, email:, reason:, last_seen_at:, suggested_org_id:,
  suggested_org:, group_match:}` maps, newest login first.

  ## The group-claim suggestion (task 019ff7ff stage 3)

  `suggested_org_id` / `group_match` are read back off the SAME audit
  metadata stage 2 wrote (string or atom keys — audit persistence
  stringifies). Rows written before stage 2 carry neither key and degrade to
  `nil` / `:none`; there is no default org and no first-org fallback at this
  layer any more than at stage 2's. `suggested_org` is the resolved
  `%Org{}`, or `nil` when the suggested org has since been archived or
  deleted — see `attach_org_suggestions/1`, the single shared tail both this
  function and the LiveView's live-append path run their rows through.
  """
  @spec awaiting_setup() :: [
          %{
            user: Accounts.User.t(),
            user_id: binary(),
            email: String.t() | nil,
            reason: String.t() | nil,
            last_seen_at: DateTime.t(),
            suggested_org_id: binary() | nil,
            suggested_org: Platform.Tenancy.Org.t() | nil,
            group_match: Result.group_match(),
            group_values: [String.t()] | nil
          }
        ]
  def awaiting_setup do
    since =
      DateTime.add(DateTime.utc_now(), -@awaiting_lookback_days * 24 * 60 * 60, :second)

    Platform.Audit.list(
      event_type: "platform.auth.external_admission",
      since: since,
      limit: @awaiting_scan_limit
    )
    |> Enum.filter(&(&1.action == "holding"))
    # `Audit.list/1` orders ascending by id; reverse so the most-recent
    # holding login per user wins the `uniq_by` dedup below.
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.actor_id)
    |> Enum.map(&build_awaiting_row/1)
    |> Enum.reject(fn
      nil -> true
      # Drop users already provisioned by an applied grant — they've been
      # recovered and are no longer awaiting setup.
      row -> Tenancy.external_user?(row.user)
    end)
    |> attach_org_suggestions()
  end

  @doc """
  Resolve each queue row's `:suggested_org_id` to a live `%Org{}` on
  `:suggested_org` — in ONE query for the whole batch, not a `get_org/1` per
  row (task 019ff7ff stage 3).

  A row whose suggested org has since been archived or deleted comes back
  with BOTH keys `nil`: the id is cleared alongside the struct, so a caller
  can never render a dangling id as a form option. A row with no suggestion
  passes through untouched.

  Public because it is the seam that keeps the two row-construction sites —
  `awaiting_setup/0` and `ExternalRecoveryLive`'s
  `{:external_admission_holding, _}` live-append — producing the SAME shape.
  A suggestion that only appears after a reload is the regression this
  exists to prevent, so BOTH callers end in this function; the LiveView
  passes a one-element list.
  """
  @spec attach_org_suggestions([map()]) :: [map()]
  def attach_org_suggestions(rows) when is_list(rows) do
    orgs_by_id =
      rows
      |> Enum.map(& &1.suggested_org_id)
      |> Enum.reject(&is_nil/1)
      |> Tenancy.live_orgs_by_id()

    Enum.map(rows, fn row ->
      case row.suggested_org_id && Map.get(orgs_by_id, row.suggested_org_id) do
        nil -> %{row | suggested_org_id: nil, suggested_org: nil}
        org -> %{row | suggested_org_id: org.id, suggested_org: org}
      end
    end)
  end

  @doc """
  Build ONE queue row from a user plus the loose `reason` /
  `suggested_org_id` / `group_match` values (task 019ff7ff stage 3).

  The single definition of a queue row's shape. `awaiting_setup/0` feeds it
  audit metadata; the LiveView feeds it a notifier payload. Neither builds a
  map literal of its own, so the two cannot drift — a key added here appears
  on both paths at once, and the tests compare `Map.keys/1` across them.

  `suggested_org` is always `nil` here; `attach_org_suggestions/1` fills it.
  """
  @spec build_row(Accounts.User.t(), keyword()) :: map()
  def build_row(%{id: user_id} = user, opts) do
    %{
      user: user,
      user_id: user_id,
      email: user.email,
      reason: normalize_reason(Keyword.get(opts, :reason)),
      last_seen_at: Keyword.fetch!(opts, :last_seen_at),
      suggested_org_id: normalize_org_id(Keyword.get(opts, :suggested_org_id)),
      suggested_org: nil,
      group_match: normalize_group_match(Keyword.get(opts, :group_match)),
      # Task 019ff7ff stage 5: the group values the login actually carried,
      # so an unmapped row can be mapped without guessing. `nil` means the
      # login predates group capture — NOT that it carried none; `[]` means
      # it carried none. The admin surface says which.
      group_values: normalize_group_values(Keyword.get(opts, :group_values))
    }
  end

  # -- internals --

  defp build_awaiting_row(%{actor_id: actor_id, metadata: metadata, inserted_at: at}) do
    case Accounts.get_user(actor_id) do
      nil ->
        nil

      user ->
        build_row(user,
          reason: metadata_get(metadata, "reason"),
          last_seen_at: at,
          # Absent on every row written before stage 2 — `metadata_get/2`
          # returns nil and the normalizers degrade to nil / `:none`.
          suggested_org_id: metadata_get(metadata, "suggested_org_id"),
          group_match: metadata_get(metadata, "group_match"),
          group_values: metadata_get(metadata, "external_groups")
        )
    end
  end

  defp build_awaiting_row(_), do: nil

  # Audit metadata is persisted as JSON (string keys), but an in-memory
  # metadata map arrives with atom keys — tolerate both, as the original
  # `metadata_reason/1` did.
  defp metadata_get(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, String.to_existing_atom(key))

  defp metadata_get(_metadata, _key), do: nil

  defp normalize_reason(nil), do: nil
  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(_), do: nil

  defp normalize_org_id(id) when is_binary(id), do: id
  defp normalize_org_id(_), do: nil

  # `:one` only ever accompanies a real suggestion; anything unrecognised —
  # including a pre-stage-2 row's missing key — is `:none`, never a guess.
  defp normalize_group_match(match) when match in [:one, :none, :ambiguous], do: match
  defp normalize_group_match("one"), do: :one
  defp normalize_group_match("ambiguous"), do: :ambiguous
  defp normalize_group_match(_), do: :none

  # A recorded-but-empty list stays `[]`; anything else (a missing key on a
  # pre-stage-5 row, a stray scalar) is `nil` — "not recorded", which the
  # admin surface renders differently from "carried none".
  defp normalize_group_values(values) when is_list(values),
    do: Enum.filter(values, &is_binary/1)

  defp normalize_group_values(_), do: nil

  defp decide(user, oidc_user, surface) do
    external_claim? = Map.get(oidc_user, :external_claim?, false)

    case ExternalGrants.lookup_by_email_or_sub(%{email: user.email, sub: user.oidc_sub}) do
      %PendingExternalGrant{} = grant ->
        # Optimistic full provisioning. apply_grant/2 is idempotent (M1
        # `applied_at` guard + upserts), so a double login never
        # double-provisions.
        {:ok, _applied} = ExternalGrants.apply_grant(grant, user)
        %Result{user: user, state: :full, reason: nil, external?: true}

      nil ->
        cond do
          # Already-provisioned external user returning. The grant that
          # provisioned them is invisible to lookup (`applied_at` stamped), so
          # we recognize them via the M1 marker instead — a repeat login stays
          # :full and never re-provisions (idempotent) and never black-holes a
          # user we already admitted.
          Tenancy.external_user?(user) ->
            %Result{user: user, state: :full, reason: nil, external?: true}

          # Flagged external but nothing staged — fail-closed: establish ZERO
          # scoped rows and wait for a grant (admin can `recover/3`).
          external_claim? ->
            # Task 019ff7ff stage 2: resolve — but do NOT act on — the org the
            # login's group claim names. The outcome rides along on the Result
            # (and the audit row) as a suggestion for the admin recovery
            # surface. NO rows are written here and NO grant is applied; the
            # branch still returns :holding / :awaiting_grant exactly as before.
            groups = Map.get(oidc_user, :external_groups, [])
            {suggested_org_id, group_match} = resolve_group_suggestion(groups)

            %Result{
              user: user,
              state: :holding,
              reason: :awaiting_grant,
              external?: true,
              suggested_org_id: suggested_org_id,
              group_match: group_match,
              external_groups: groups
            }

          # Arrived on the external surface with no marker — misconfiguration,
          # hold. (`:unknown` is reserved in the Result type for M3; M2 uses
          # `:missing_claim` for the surface-external no-marker case.)
          surface == :external ->
            %Result{user: user, state: :holding, reason: :missing_claim, external?: false}

          # Ordinary internal login — UNCHANGED. NEVER black-hole an internal
          # user; role is governed entirely by `derive_role_from_email/1`.
          true ->
            %Result{user: user, state: :full, reason: nil, external?: false}
        end
    end
  end

  defp maybe_sync_idp_roles(
         %Result{state: :full, external?: false, user: user},
         %{groups_claim_present?: true, external_groups: groups}
       ) do
    case IdpGroupRoles.sync_user(user, groups) do
      {:ok, counts} -> {:ok, counts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_sync_idp_roles(_result, _claims), do: {:ok, %{applied: 0, revoked: 0}}

  # `{suggested_org_id, group_match}`. Exactly one distinct org => a
  # suggestion; nothing and ambiguity BOTH yield nil — never guess a tenant.
  defp resolve_group_suggestion(groups) do
    case Tenancy.resolve_org_from_groups(groups) do
      {:ok, %{id: org_id}} -> {org_id, :one}
      :none -> {nil, :none}
      {:ambiguous, _orgs} -> {nil, :ambiguous}
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
  defp emit(result, action, counts \\ %{applied: 0, revoked: 0})

  defp emit(
         %Result{
           state: state,
           reason: reason,
           external?: external?,
           user: user,
           suggested_org_id: suggested_org_id,
           group_match: group_match,
           external_groups: external_groups
         } = result,
         action,
         counts
       ) do
    metadata =
      %{
        action: action || Atom.to_string(state),
        reason: reason,
        email: user.email,
        actor_id: user.id,
        external?: external?,
        group_match: group_match,
        idp_roles_applied: counts.applied,
        idp_roles_revoked: counts.revoked
      }
      # `TelemetryHandler` does NOT whitelist metadata keys — it drops the
      # top-level column keys and persists the rest verbatim — but its
      # `ensure_json_safe/1` stringifies atoms, and `nil` IS an atom, so a nil
      # suggestion would land as the string "nil". Omit it instead (same idiom
      # as the canvas `runtime_id` key).
      |> maybe_put(:suggested_org_id, suggested_org_id)
      # Task 019ff7ff stage 5: persist the VALUES too, so the admin queue can
      # show an unmapped login what to map. An empty list is written as `[]`
      # (this login carried no groups); the key is absent only on rows
      # written before this stage, which is how the surface can say
      # "not recorded" instead of lying with an empty list.
      |> maybe_put_groups(external_groups)

    :telemetry.execute(
      @telemetry_event,
      %{system_time: System.system_time()},
      metadata
    )

    result
  end

  defp maybe_put_groups(map, groups) when is_list(groups),
    do: Map.put(map, :external_groups, Enum.filter(groups, &is_binary/1))

  defp maybe_put_groups(map, _groups), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
