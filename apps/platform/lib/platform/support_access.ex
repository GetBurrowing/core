defmodule Platform.SupportAccess do
  @moduledoc """
  Vendor support access on hosted installs (task 01a1b362 stage 1, ADR 0059).

  The install owner's switch (`Platform.SupportAccess.Settings`) decides
  whether vendor support may enter this install at all. While it is on, the
  vendor's support system (which holds the grant-signing private key; the
  install holds only public keys) may request a time-boxed session:

    * **admin**: a browser session as an install admin, signed in through a
      single-use code (`consume_sign_in_code/2`, `GET /auth/support`);
    * **repair**: a root shell on the host. Core only records the session and
      publishes it in the host state file (`StateFile`); the host's sshd
      decides from that file.

  ## Off means off, on the install

    * the grant endpoint refuses while the switch is off;
    * turning it off ends every active session in the same transaction, and
      `session_allows?/3`, checked by `PlatformWeb.LiveAuth` and the
      `:require_auth` / `:require_auth_api` plugs on every mount and request,
      bounces an ended session on its next contact;
    * the state file shows `enabled: false` and no repair sessions before
      `Settings.update/2` returns.

  ## Audit

  Every support row goes through `audit/2`, which hash-chains `support.*`
  rows (`metadata["chain"]`) so an edit or deletion is evident to anyone who
  kept an earlier chain head (`verify_audit_chain/0`). That is tamper-evident,
  not tamper-proof: a repair session is root on the host and can rewrite the
  whole chain. No audit row or log line carries a sign-in code, a sign-in URL,
  key material or request parameter values.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Access
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Audit
  alias Platform.Audit.Event
  alias Platform.Repo
  alias Platform.SupportAccess.Config
  alias Platform.SupportAccess.Grant
  alias Platform.SupportAccess.Session
  alias Platform.SupportAccess.SignInCode
  alias Platform.SupportAccess.StateFile
  alias Platform.Tenancy

  # pg_advisory_xact_lock key serialising the support audit chain.
  @chain_lock 0x5355_5050_4F52_54
  @genesis String.duplicate("0", 64)

  # ── Audit ────────────────────────────────────────────────────────────

  @doc """
  Records a `support.*` audit row, chained to the previous one. `attrs` are
  `Platform.Audit.Event` fields; `metadata` must not carry secrets.
  """
  @spec audit(String.t(), map()) :: {:ok, Event.t()} | {:error, term()}
  def audit("support." <> _ = event_type, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@chain_lock])

      prev =
        case Repo.one(
               from(e in Event,
                 where: like(e.event_type, "support.%"),
                 order_by: [desc: e.id],
                 limit: 1,
                 select: e.metadata
               )
             ) do
          %{"chain" => %{"digest" => digest}} when is_binary(digest) -> digest
          _ -> @genesis
        end

      metadata = Map.get(attrs, :metadata, %{}) |> stringify()

      fields = %{
        "event_type" => event_type,
        "actor_id" => Map.get(attrs, :actor_id),
        "action" => Map.get(attrs, :action) || event_type,
        "resource_type" => Map.get(attrs, :resource_type),
        "resource_id" => Map.get(attrs, :resource_id),
        "metadata" => metadata
      }

      digest = chain_digest(prev, fields)

      attrs
      |> Map.merge(%{
        event_type: event_type,
        actor_type: Map.get(attrs, :actor_type, "system"),
        action: fields["action"],
        metadata: Map.put(metadata, "chain", %{"prev" => prev, "digest" => digest})
      })
      |> Audit.record()
      |> case do
        {:ok, event} -> event
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  defp chain_digest(prev, fields) do
    :crypto.hash(:sha256, prev <> canonical(fields)) |> Base.encode16(case: :lower)
  end

  # Deterministic JSON: maps with sorted keys, recursively.
  defp canonical(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical(v) end)

    "{" <> inner <> "}"
  end

  defp canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"

  defp canonical(value), do: Jason.encode!(value)

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(v), do: v

  @doc """
  Re-walks the `support.*` chain. `:ok`, or `{:error, {:broken_at, id}}` for
  the first row whose link or digest does not match.
  """
  @spec verify_audit_chain() :: :ok | {:error, {:broken_at, integer()}}
  def verify_audit_chain do
    from(e in Event, where: like(e.event_type, "support.%"), order_by: [asc: e.id])
    |> Repo.all()
    |> Enum.reduce_while(@genesis, fn e, prev ->
      chain = e.metadata["chain"] || %{}

      fields = %{
        "event_type" => e.event_type,
        "actor_id" => e.actor_id,
        "action" => e.action,
        "resource_type" => e.resource_type,
        "resource_id" => e.resource_id,
        "metadata" => Map.delete(e.metadata, "chain")
      }

      if chain["prev"] == prev and chain["digest"] == chain_digest(prev, fields),
        do: {:cont, chain["digest"]},
        else: {:halt, {:error, {:broken_at, e.id}}}
    end)
    |> case do
      {:error, _} = error -> error
      _head -> :ok
    end
  end

  # ── Grants ───────────────────────────────────────────────────────────

  @doc """
  Handles one grant request: verifies it (`Grant.verify/3`), audits it if it
  was validly signed, and issues the session. Returns `{:ok, response}` with
  the JSON response map, or `{:error, reason}`.
  """
  @spec request_grant(binary(), [{String.t(), String.t()}], DateTime.t()) ::
          {:ok, map()} | {:error, atom()}
  def request_grant(raw, headers, now \\ DateTime.utc_now()) do
    case Grant.verify(raw, headers, now) do
      {:ok, grant} ->
        audit_requested(grant)

        case issue(grant, now) do
          {:ok, response, session} ->
            audit("support.grant_issued", %{
              action: "grant_issued",
              resource_type: "support_session",
              resource_id: session.id,
              metadata: %{
                "kind" => session.kind,
                "operator_email" => session.operator_email,
                "not_after" => DateTime.to_iso8601(session.not_after)
              }
            })

            StateFile.write(now)
            {:ok, response}

          {:error, reason} ->
            audit_refused(grant, reason)
            {:error, reason}
        end

      {:error, reason, grant} ->
        audit_requested(grant)
        audit_refused(grant, reason)
        {:error, reason}

      {:error, reason} ->
        Logger.info("[support_access] grant refused reason=#{reason}")
        {:error, reason}
    end
  end

  defp audit_requested(grant) do
    audit("support.grant_requested", %{
      action: "grant_requested",
      resource_type: "support_grant",
      metadata: grant_metadata(grant)
    })
  end

  defp audit_refused(grant, reason) do
    audit("support.grant_refused", %{
      action: "grant_refused",
      resource_type: "support_grant",
      metadata: Map.put(grant_metadata(grant), "reason", to_string(reason))
    })
  end

  # What the vendor asked for, minus the nonce (a replay token, useless to a
  # reader) and the signature. No secret is in a grant body.
  defp grant_metadata(grant) when map_size(grant) == 0, do: %{}

  defp grant_metadata(grant) do
    %{
      "kind" => grant.kind,
      "operator_name" => grant.operator_name,
      "operator_email" => grant.operator_email,
      "duration_s" => grant.duration_s,
      "kid" => grant.kid,
      "issued_at" => grant.issued_at,
      "expires_at" => grant.expires_at
    }
  end

  defp issue(%{kind: "repair"} = grant, now) do
    attrs = session_attrs(grant, now, nil)

    case Repo.insert(Session.create_changeset(attrs)) do
      {:ok, session} ->
        {:ok,
         %{
           session_id: session.id,
           principal: Config.principal(),
           not_after: DateTime.to_iso8601(session.not_after)
         }, session}

      {:error, _} ->
        {:error, :malformed_grant}
    end
  end

  defp issue(%{kind: "admin"} = grant, now) do
    Repo.transaction(fn ->
      with {:ok, user} <- support_user(grant),
           {:ok, _} <- Tenancy.promote_to_admin(user, reason: "support_session"),
           {:ok, session} <-
             Repo.insert(Session.create_changeset(session_attrs(grant, now, user.id))),
           {:ok, code} <- mint_code(session, now) do
        {%{
           session_id: session.id,
           sign_in_url: PlatformWeb.Endpoint.url() <> "/auth/support?code=" <> code,
           not_after: DateTime.to_iso8601(session.not_after)
         }, session}
      else
        {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
        {:error, _} -> Repo.rollback(:malformed_grant)
      end
    end)
    |> case do
      {:ok, {response, session}} -> {:ok, response, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_attrs(grant, now, user_id) do
    %{
      kind: grant.kind,
      operator_name: grant.operator_name,
      operator_email: grant.operator_email,
      user_id: user_id,
      not_before: now,
      not_after: DateTime.add(now, grant.duration_s, :second)
    }
  end

  # ONE support user per operator email. A real user already holding that
  # email is never taken over.
  defp support_user(%{operator_email: email, operator_name: name}) do
    display = support_display_name(name)

    case Repo.get_by(User, email: email) do
      nil ->
        %User{}
        |> User.support_changeset(%{
          email: email,
          name: display,
          oidc_sub:
            "support-vendor:" <> (:crypto.hash(:sha256, email) |> Base.encode16(case: :lower))
        })
        |> Repo.insert()

      %User{support_vendor: true} = user ->
        user
        |> User.support_changeset(%{
          name: display,
          archived_at: nil,
          archived_by_user_id: nil,
          archived_reason: nil
        })
        |> Repo.update()

      %User{} ->
        {:error, :operator_email_taken}
    end
  end

  defp support_display_name(name) do
    case Config.vendor_name() do
      nil -> "#{name} (vendor support)"
      vendor -> "#{name} (#{vendor} support)"
    end
  end

  defp mint_code(session, now) do
    code = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %SignInCode{
      support_session_id: session.id,
      code_hash: hash(code),
      expires_at: DateTime.add(now, Config.sign_in_code_ttl_s(), :second)
    }
    |> Repo.insert()
    |> case do
      {:ok, _} -> {:ok, code}
      {:error, _} = error -> error
    end
  end

  defp hash(code), do: :crypto.hash(:sha256, code)

  @doc """
  Redeems a sign-in code, once. Returns `{:ok, user, session}`, or
  `{:error, :invalid_code}` for EVERY failure (unknown, used, expired, ended
  session, archived user), so a refusal reveals nothing.
  """
  @spec consume_sign_in_code(term(), DateTime.t()) ::
          {:ok, User.t(), Session.t()} | {:error, :invalid_code}
  def consume_sign_in_code(code, now \\ DateTime.utc_now())

  def consume_sign_in_code(code, now) when is_binary(code) and code != "" do
    query =
      from(c in SignInCode,
        where: c.code_hash == ^hash(code) and is_nil(c.used_at) and c.expires_at > ^now,
        select: c.support_session_id
      )

    with {1, [session_id]} <- Repo.update_all(query, set: [used_at: now]),
         %Session{kind: "admin", user_id: user_id} = session when is_binary(user_id) <-
           Repo.get(Session, session_id),
         true <- Session.active?(session, now),
         %User{archived_at: nil, support_vendor: true} = user <- Accounts.get_user(user_id) do
      {:ok, user, session}
    else
      _ -> {:error, :invalid_code}
    end
  end

  def consume_sign_in_code(_, _), do: {:error, :invalid_code}

  # ── Session checks ───────────────────────────────────────────────────

  @doc """
  Whether `user` may act with the support session id from its browser
  session. Always true for a user who is not a vendor support user. A support
  user needs an ACTIVE admin session that is its own; checked against the
  database every time, never cached.
  """
  @spec session_allows?(term(), term(), DateTime.t()) :: boolean()
  def session_allows?(user, support_session_id, now \\ DateTime.utc_now())

  def session_allows?(%User{support_vendor: true, id: user_id}, session_id, now)
      when is_binary(session_id) do
    if Platform.UUID.valid?(session_id) do
      case Repo.get(Session, session_id) do
        %Session{kind: "admin", user_id: ^user_id} = session -> Session.active?(session, now)
        _ -> false
      end
    else
      false
    end
  end

  def session_allows?(%User{support_vendor: true}, _session_id, _now), do: false
  def session_allows?(_user, _session_id, _now), do: true

  @doc "The live socket id the admin session's LiveViews connect under."
  @spec live_socket_id(String.t()) :: String.t()
  def live_socket_id(session_id), do: "support_session:" <> session_id

  @doc "Active sessions of `kind` at `now`."
  @spec active_sessions(String.t(), DateTime.t()) :: [Session.t()]
  def active_sessions(kind, now \\ DateTime.utc_now()) do
    from(s in Session,
      where: s.kind == ^kind and is_nil(s.ended_at) and s.not_after > ^now,
      order_by: [asc: s.not_after]
    )
    |> Repo.all()
  end

  @doc "A support session by id, or nil (also for a malformed id)."
  @spec get_session(term()) :: Session.t() | nil
  def get_session(id) do
    if Platform.UUID.valid?(id), do: Repo.get(Session, id), else: nil
  end

  # ── Ending sessions ──────────────────────────────────────────────────

  @doc """
  Ends one session for the owner (stage 2's End session button). Install
  admin only, and never a vendor support user.
  """
  @spec end_session(term(), String.t()) ::
          {:ok, Session.t()} | {:error, :unauthorized | :not_found | :already_ended}
  def end_session(actor, id) do
    with :ok <- refuse_support_vendor(actor),
         :ok <- Access.authorize_install(actor),
         %Session{} = session <- get_session(id) || {:error, :not_found} do
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        case end_in_transaction(session, :ended_by_owner, now, actor) do
          {:ok, ended} -> ended
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, ended} ->
          after_sessions_ended([ended])
          StateFile.write(now)
          {:ok, ended}

        error ->
          error
      end
    end
  end

  defp refuse_support_vendor(%User{support_vendor: true}), do: {:error, :unauthorized}
  defp refuse_support_vendor(_), do: :ok

  @doc false
  # Ends every active session with `reason`. Must run inside a transaction
  # (`Settings.update/2` calls it in the toggle-off transaction). Returns the
  # ended sessions for `after_sessions_ended/1`.
  def end_all_in_transaction(reason, now) do
    from(s in Session, where: is_nil(s.ended_at), lock: "FOR UPDATE")
    |> Repo.all()
    |> Enum.flat_map(fn session ->
      case end_in_transaction(session, reason, now, nil) do
        {:ok, ended} -> [ended]
        {:error, _} -> []
      end
    end)
  end

  @doc """
  Ends every session past its `not_after` (reason `expired`). Returns the
  ended sessions; their sockets are already disconnected.
  """
  @spec end_expired(DateTime.t()) :: [Session.t()]
  def end_expired(now \\ DateTime.utc_now()) do
    ids =
      from(s in Session, where: is_nil(s.ended_at) and s.not_after <= ^now, select: s.id)
      |> Repo.all()

    ended =
      Enum.flat_map(ids, fn id ->
        Repo.transaction(fn ->
          case Repo.one(from(s in Session, where: s.id == ^id, lock: "FOR UPDATE")) do
            %Session{ended_at: nil} = session ->
              case end_in_transaction(session, :expired, now, nil) do
                {:ok, ended} -> ended
                {:error, reason} -> Repo.rollback(reason)
              end

            _ ->
              Repo.rollback(:already_ended)
          end
        end)
        |> case do
          {:ok, ended} -> [ended]
          _ -> []
        end
      end)

    after_sessions_ended(ended)
    ended
  end

  defp end_in_transaction(%Session{ended_at: nil} = session, reason, now, actor) do
    reason = to_string(reason)

    {count, _} =
      from(s in Session, where: s.id == ^session.id and is_nil(s.ended_at))
      |> Repo.update_all(set: [ended_at: now, end_reason: reason, updated_at: now])

    if count == 1 do
      ended = %{session | ended_at: now, end_reason: reason}
      retire_support_user(ended, now)

      audit("support.session_ended", %{
        actor_id: actor_id(actor),
        actor_type: if(actor_id(actor), do: "user", else: "system"),
        action: "session_ended",
        resource_type: "support_session",
        resource_id: session.id,
        metadata: %{"kind" => session.kind, "reason" => reason}
      })

      {:ok, ended}
    else
      {:error, :already_ended}
    end
  end

  defp end_in_transaction(_session, _reason, _now, _actor), do: {:error, :already_ended}

  # The admin role and the account live only as long as the support user's
  # last active admin session.
  defp retire_support_user(%Session{kind: "admin", user_id: user_id} = session, now)
       when is_binary(user_id) do
    others =
      from(s in Session,
        where:
          s.user_id == ^user_id and s.kind == "admin" and s.id != ^session.id and
            is_nil(s.ended_at) and s.not_after > ^now
      )
      |> Repo.exists?()

    with false <- others,
         %User{support_vendor: true} = user <- Repo.get(User, user_id) do
      {:ok, _} = Tenancy.revoke_admin(user, reason: "support_session_ended")
      {:ok, _} = Accounts.archive_user(user, reason: "support_session_ended")
    end

    :ok
  end

  defp retire_support_user(_session, _now), do: :ok

  @doc false
  # After the commit: disconnect every LiveView of each ended admin session.
  def after_sessions_ended(sessions) do
    Enum.each(sessions, fn
      %Session{kind: "admin", id: id} ->
        PlatformWeb.Endpoint.broadcast(live_socket_id(id), "disconnect", %{})

      _ ->
        :ok
    end)
  end

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_), do: nil

  # ── Per-action audit ─────────────────────────────────────────────────

  @doc """
  Records `support.action` for a support user's state-changing request or
  LiveView event. `params` is hashed, never stored: `params_sha256` is the
  sha256 of the params' deterministic term encoding.
  """
  @spec record_action(User.t(), term(), map()) :: :ok
  def record_action(%User{id: user_id}, support_session_id, %{params: params} = attrs) do
    metadata =
      attrs
      |> Map.delete(:params)
      |> Map.put(:params_sha256, params_hash(params))
      |> Map.put(:support_session_id, support_session_id)

    audit("support.action", %{
      actor_id: user_id,
      actor_type: "user",
      action: "action",
      resource_type: "support_session",
      resource_id: support_session_id,
      metadata: metadata
    })

    :ok
  end

  @doc false
  def params_hash(params) do
    :crypto.hash(:sha256, :erlang.term_to_binary(params, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  # ── Sweep ────────────────────────────────────────────────────────────

  @doc """
  One sweeper tick: ends expired sessions, rewrites the state file (the retry
  for a failed write), ingests new shell events, and prunes used nonces and
  sign-in codes past their expiry.
  """
  @spec sweep(DateTime.t()) :: :ok
  def sweep(now \\ DateTime.utc_now()) do
    end_expired(now)
    StateFile.write(now)
    Platform.SupportAccess.ShellEvents.ingest()
    Grant.prune_nonces(now)
    Repo.delete_all(from(c in SignInCode, where: c.expires_at <= ^now))
    :ok
  end
end
