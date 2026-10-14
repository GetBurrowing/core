defmodule Platform.Mobile do
  @moduledoc """
  The server half of the native apps (iOS task 01a10882, Android task
  01a10d8e): app bearer sessions, the app login codes that mint them, push
  device registration (APNs for iOS in `apns_devices`, FCM for Android in
  `fcm_devices`, PushKit VoIP for iOS call ringing in `apns_voip_devices`),
  and the badge counts the app shows.

  ## Login flow

  The app opens `/auth/login?app_challenge=<S256>` in an
  `ASWebAuthenticationSession` (pocket-id is passkey-first, and a WKWebView in
  a third-party app cannot complete WebAuthn for an RP it has no associated
  domain for). On a successful OIDC callback, `issue_exchange_code/2` mints a
  60-second, single-use code bound to that challenge and the browser is sent
  to `burrow://auth/callback?code=...`. The app then calls
  `POST /api/app/session` with the code and its PKCE `code_verifier`;
  `exchange_code/3` checks S256, returns the raw bearer token once, and a
  one-time handoff code the app's WKWebView redeems at
  `GET /auth/app/handoff?code=...` to get an ordinary browser session.

  ## Secrets

  Bearer tokens and login codes are stored only as SHA-256 hashes. APNs,
  FCM and VoIP device tokens are stored raw (the push services need them) under
  `redact: true`. None of them is ever logged, put in telemetry, or echoed in an error. Every
  failure of `exchange_code/3` returns the same `{:error, :invalid_code}`, so
  the API is not an oracle for which check failed.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Inbox
  alias Platform.Mobile.ApnsDevice
  alias Platform.Mobile.ApnsVoipDevice
  alias Platform.Mobile.AppLoginCode
  alias Platform.Mobile.AppSession
  alias Platform.Mobile.FcmDevice
  alias Platform.Repo
  alias Platform.Tasks.Task

  @code_ttl_seconds 60
  @touch_interval_seconds 60
  @approval_kinds ~w(task_plan_review review_request_pending)
  @terminal_task_statuses ~w(done cancelled)

  # A PKCE S256 challenge is base64url(SHA-256(verifier)) without padding:
  # always exactly 43 characters from the URL-safe alphabet.
  @challenge_format ~r/\A[A-Za-z0-9_-]{43}\z/
  # RFC 7636 section 4.1.
  @verifier_format ~r/\A[A-Za-z0-9._~-]{43,128}\z/

  @doc "Seconds a login code (exchange or handoff) stays redeemable."
  def code_ttl_seconds, do: @code_ttl_seconds

  @doc """
  Validate an app login's PKCE S256 `code_challenge` before it is stored in
  the browser session by `AuthController.login/2`.
  """
  @spec begin_app_login(term()) :: {:ok, String.t()} | {:error, :invalid_challenge}
  def begin_app_login(challenge) when is_binary(challenge) do
    if Regex.match?(@challenge_format, challenge),
      do: {:ok, challenge},
      else: {:error, :invalid_challenge}
  end

  def begin_app_login(_), do: {:error, :invalid_challenge}

  @doc """
  Mint the single-use exchange code for `user`, bound to `challenge`.
  Returns the raw code; only its hash is stored.
  """
  @spec issue_exchange_code(User.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_challenge | Ecto.Changeset.t()}
  def issue_exchange_code(%User{id: user_id}, challenge) do
    with {:ok, challenge} <- begin_app_login(challenge) do
      insert_code(user_id, "exchange", challenge)
    end
  end

  @doc """
  Redeem an exchange code with the app's PKCE `code_verifier`.

  The code is consumed atomically BEFORE the verifier is checked, so a wrong
  verifier burns the code: an intercepted code cannot be retried. On success,
  returns the raw bearer token (this is the only time it exists outside the
  app), the new session, and a raw one-time handoff code for the web view.
  """
  @spec exchange_code(term(), term(), map()) ::
          {:ok, %{token: String.t(), session: AppSession.t(), handoff_code: String.t()}}
          | {:error, :invalid_code}
  def exchange_code(code, verifier, attrs \\ %{})

  def exchange_code(code, verifier, attrs) when is_binary(code) and is_binary(verifier) do
    with {:ok, %AppLoginCode{} = login_code} <- consume_code(code, "exchange"),
         true <- verifier_matches?(verifier, login_code.code_challenge),
         %User{archived_at: nil} = user <- Accounts.get_user(login_code.user_id),
         {:ok, result} <- create_session(user, attrs) do
      {:ok, result}
    else
      _ -> {:error, :invalid_code}
    end
  end

  def exchange_code(_code, _verifier, _attrs), do: {:error, :invalid_code}

  @doc """
  Mint a fresh one-time handoff code for a live app session, so the app can
  sign its web view back in after WKWebView dropped the session-only cookie
  (a cold start, or switching back to an install). Same 60-second,
  single-use, hashed `"handoff"` code `exchange_code/3` mints. Returns the
  raw code; only its hash is stored.
  """
  @spec issue_handoff_code(AppSession.t()) :: {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def issue_handoff_code(%AppSession{user_id: user_id}), do: insert_code(user_id, "handoff", nil)

  @doc """
  The local path a handoff may land on: an absolute path on this host
  (`/chat/design`, `/tasks/<id>?x=1`), never a scheme-relative `//host` or a
  backslash form a browser could read as one, and never an `/auth/` route (a
  handoff that lands on `/auth/logout` would sign straight back out).
  Anything else is `"/"`, so the parameter cannot be used as an open
  redirect.
  """
  @spec safe_return_path(term()) :: String.t()
  def safe_return_path("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\", "auth/"]) or
         String.contains?(path, ["\\", "\r", "\n", "\t"]) or URI.parse(path).host != nil,
       do: "/",
       else: path
  end

  def safe_return_path(_), do: "/"

  @doc """
  Redeem a one-time handoff code. Returns the user to sign the web view in as.
  """
  @spec consume_handoff_code(term()) :: {:ok, User.t()} | {:error, :invalid_code}
  def consume_handoff_code(code) when is_binary(code) do
    with {:ok, %AppLoginCode{user_id: user_id}} <- consume_code(code, "handoff"),
         %User{archived_at: nil} = user <- Accounts.get_user(user_id) do
      {:ok, user}
    else
      _ -> {:error, :invalid_code}
    end
  end

  def consume_handoff_code(_), do: {:error, :invalid_code}

  @doc """
  Resolve a raw bearer token to its live session and user.

  Refuses an unknown token, a revoked session, and an archived (or deleted)
  user. The user is returned with `org_memberships: :org` preloaded, as
  `Accounts.get_user/1` returns it.
  """
  @spec verify_bearer(term()) :: {:ok, User.t(), AppSession.t()} | :error
  def verify_bearer(token) when is_binary(token) and token != "" do
    with %AppSession{revoked_at: nil} = session <-
           Repo.get_by(AppSession, token_hash: hash(token)),
         %User{archived_at: nil} = user <- Accounts.get_user(session.user_id) do
      {:ok, user, session}
    else
      _ -> :error
    end
  end

  def verify_bearer(_), do: :error

  @doc """
  Bump `last_used_at`, at most once per #{@touch_interval_seconds} seconds per
  session. The guard is in the UPDATE's WHERE clause, so concurrent requests
  cannot each write.
  """
  @spec touch_session(AppSession.t()) :: :ok
  def touch_session(%AppSession{id: id}) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@touch_interval_seconds, :second)

    from(s in AppSession,
      where: s.id == ^id and (is_nil(s.last_used_at) or s.last_used_at < ^cutoff)
    )
    |> Repo.update_all(set: [last_used_at: now])

    :ok
  end

  @doc """
  Revoke a session and delete every push device it registered: APNs alert
  (`apns_devices`), FCM (`fcm_devices`) and PushKit VoIP
  (`apns_voip_devices`). Revocation stamps `revoked_at` and keeps the session
  row, so the tables' `ON DELETE CASCADE` never fires here: each table is
  deleted from explicitly.
  """
  @spec revoke_session(AppSession.t()) :: {:ok, AppSession.t()} | {:error, term()}
  def revoke_session(%AppSession{id: id} = session) do
    Multi.new()
    |> Multi.delete_all(:devices, from(d in ApnsDevice, where: d.app_session_id == ^id))
    |> Multi.delete_all(:fcm_devices, from(d in FcmDevice, where: d.app_session_id == ^id))
    |> Multi.delete_all(:voip_devices, from(d in ApnsVoipDevice, where: d.app_session_id == ^id))
    |> Multi.update(:session, Ecto.Changeset.change(session, revoked_at: DateTime.utc_now()))
    |> Repo.transaction()
    |> case do
      {:ok, %{session: session}} -> {:ok, session}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Register (or refresh) the push device token for the session's install.

  `attrs["platform"]` picks the table: `"android"` registers an FCM token in
  `fcm_devices` (with `package_name`); absent or `"ios"` registers an APNs
  token in `apns_devices` (with `environment` and `bundle_id`). Absent MUST
  stay iOS: the shipped iOS TestFlight build 1 sends no platform field. Any
  other platform is refused with a `:platform` changeset error.

  Both upsert on `token`: a token already registered (to this user or
  another) is reassigned to this user and session rather than duplicated. A
  previous token for the same `(user, app_install_id)` is replaced.

  An optional `push_public_key` (task 01a1261e) is the install's X25519
  public key for sealed previews (`Platform.Push.Seal`), base64url without
  padding. It is optional: a build that sends none (TestFlight build 1)
  registers exactly as before. A re-registration replaces the stored key
  with whatever the device sends now, so a build that stops sending one
  stops getting sealed previews rather than keeping a key it discarded.
  """
  @spec register_device(AppSession.t(), map()) ::
          {:ok, ApnsDevice.t() | FcmDevice.t()} | {:error, Ecto.Changeset.t()}
  def register_device(%AppSession{} = session, attrs) when is_map(attrs) do
    case Map.get(attrs, :platform, Map.get(attrs, "platform")) do
      nil -> register_apns_device(session, attrs)
      "ios" -> register_apns_device(session, attrs)
      "android" -> register_fcm_device(session, attrs)
      _other -> {:error, invalid_platform()}
    end
  end

  defp invalid_platform do
    {%{}, %{platform: :string}}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:platform, "is not supported")
  end

  defp register_apns_device(%AppSession{} = session, attrs) do
    now = DateTime.utc_now()

    changeset =
      ApnsDevice.changeset(%ApnsDevice{}, %{
        user_id: session.user_id,
        app_session_id: session.id,
        app_install_id: fetch(attrs, :app_install_id) || session.app_install_id,
        token: fetch(attrs, :token),
        environment: fetch(attrs, :environment),
        bundle_id: fetch(attrs, :bundle_id),
        push_public_key: fetch(attrs, :push_public_key),
        last_registered_at: now
      })

    if changeset.valid? do
      token = Ecto.Changeset.get_field(changeset, :token)
      install_id = Ecto.Changeset.get_field(changeset, :app_install_id)

      Repo.transaction(fn ->
        # `log: false` on both statements: the device token is a query
        # parameter here, and Ecto's debug query log prints parameters.
        from(d in ApnsDevice,
          where:
            d.user_id == ^session.user_id and d.app_install_id == ^install_id and
              d.token != ^token
        )
        |> Repo.delete_all(log: false)

        case Repo.insert(changeset,
               log: false,
               on_conflict:
                 {:replace,
                  [
                    :user_id,
                    :app_session_id,
                    :app_install_id,
                    :environment,
                    :bundle_id,
                    :push_public_key,
                    :last_registered_at,
                    :updated_at
                  ]},
               conflict_target: :token,
               returning: true
             ) do
          {:ok, device} -> device
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    else
      {:error, changeset}
    end
  end

  # The FCM twin of the APNs branch above, same reassignment semantics:
  # inside one transaction, the install's previous token is deleted, then the
  # insert upserts on `token`, so a token held by another user's row moves to
  # this user and session instead of being duplicated.
  defp register_fcm_device(%AppSession{} = session, attrs) do
    changeset =
      FcmDevice.changeset(%FcmDevice{}, %{
        user_id: session.user_id,
        app_session_id: session.id,
        app_install_id: fetch(attrs, :app_install_id) || session.app_install_id,
        token: fetch(attrs, :token),
        package_name: fetch(attrs, :package_name),
        push_public_key: fetch(attrs, :push_public_key),
        last_registered_at: DateTime.utc_now()
      })

    if changeset.valid? do
      token = Ecto.Changeset.get_field(changeset, :token)
      install_id = Ecto.Changeset.get_field(changeset, :app_install_id)

      Repo.transaction(fn ->
        # `log: false` on both statements: the registration token is a query
        # parameter here, and Ecto's debug query log prints parameters.
        from(d in FcmDevice,
          where:
            d.user_id == ^session.user_id and d.app_install_id == ^install_id and
              d.token != ^token
        )
        |> Repo.delete_all(log: false)

        case Repo.insert(changeset,
               log: false,
               on_conflict:
                 {:replace,
                  [
                    :user_id,
                    :app_session_id,
                    :app_install_id,
                    :package_name,
                    :push_public_key,
                    :last_registered_at,
                    :updated_at
                  ]},
               conflict_target: :token,
               returning: true
             ) do
          {:ok, device} -> device
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    else
      {:error, changeset}
    end
  end

  @doc """
  Remove the user's device rows (APNs alert, FCM and PushKit VoIP) for one
  app install. Idempotent.
  """
  @spec unregister_device(User.t() | AppSession.t(), String.t()) :: :ok
  def unregister_device(%AppSession{user_id: user_id}, install_id),
    do: unregister_device(%User{id: user_id}, install_id)

  def unregister_device(%User{id: user_id}, install_id) when is_binary(install_id) do
    Repo.transaction(fn ->
      from(d in ApnsDevice, where: d.user_id == ^user_id and d.app_install_id == ^install_id)
      |> Repo.delete_all()

      from(d in FcmDevice, where: d.user_id == ^user_id and d.app_install_id == ^install_id)
      |> Repo.delete_all()

      from(d in ApnsVoipDevice,
        where: d.user_id == ^user_id and d.app_install_id == ^install_id
      )
      |> Repo.delete_all()
    end)

    :ok
  end

  @doc "The user's registered APNs devices."
  @spec list_devices(User.t()) :: [ApnsDevice.t()]
  def list_devices(%User{id: user_id}) do
    Repo.all(from(d in ApnsDevice, where: d.user_id == ^user_id, order_by: d.inserted_at))
  end

  @doc """
  Register (or refresh) the PushKit VoIP token for the session's install
  (task 01a10db7), in `apns_voip_devices`. The VoIP twin of the APNs alert
  registration in `register_device/2`, with the same semantics: inside one
  transaction the install's previous VoIP token is deleted, then the insert
  upserts on `token`, so a token held by another user's row moves to this
  user and session instead of being duplicated.

  `attrs`: `token` (hex), `environment` (`sandbox` | `production`),
  `bundle_id`, and optionally `app_install_id` (defaults to the session's).
  """
  @spec register_voip_device(AppSession.t(), map()) ::
          {:ok, ApnsVoipDevice.t()} | {:error, Ecto.Changeset.t()}
  def register_voip_device(%AppSession{} = session, attrs) when is_map(attrs) do
    changeset =
      ApnsVoipDevice.changeset(%ApnsVoipDevice{}, %{
        user_id: session.user_id,
        app_session_id: session.id,
        app_install_id: fetch(attrs, :app_install_id) || session.app_install_id,
        token: fetch(attrs, :token),
        environment: fetch(attrs, :environment),
        bundle_id: fetch(attrs, :bundle_id),
        last_registered_at: DateTime.utc_now()
      })

    if changeset.valid? do
      token = Ecto.Changeset.get_field(changeset, :token)
      install_id = Ecto.Changeset.get_field(changeset, :app_install_id)

      Repo.transaction(fn ->
        # `log: false` on both statements: the VoIP token is a query
        # parameter here, and Ecto's debug query log prints parameters.
        from(d in ApnsVoipDevice,
          where:
            d.user_id == ^session.user_id and d.app_install_id == ^install_id and
              d.token != ^token
        )
        |> Repo.delete_all(log: false)

        case Repo.insert(changeset,
               log: false,
               on_conflict:
                 {:replace,
                  [
                    :user_id,
                    :app_session_id,
                    :app_install_id,
                    :environment,
                    :bundle_id,
                    :last_registered_at,
                    :updated_at
                  ]},
               conflict_target: :token,
               returning: true
             ) do
          {:ok, device} -> device
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    else
      {:error, changeset}
    end
  end

  @doc "The user's registered PushKit VoIP devices."
  @spec list_voip_devices(User.t()) :: [ApnsVoipDevice.t()]
  def list_voip_devices(%User{id: user_id}) do
    Repo.all(from(d in ApnsVoipDevice, where: d.user_id == ^user_id, order_by: d.inserted_at))
  end

  @doc "The user's registered FCM (Android) devices."
  @spec list_fcm_devices(User.t()) :: [FcmDevice.t()]
  def list_fcm_devices(%User{id: user_id}) do
    Repo.all(from(d in FcmDevice, where: d.user_id == ^user_id, order_by: d.inserted_at))
  end

  @doc """
  The numbers the app badges.

    * `approvals`: inbox items of kind `task_plan_review` or
      `review_request_pending` in `Inbox.reachable_badge_scope/1`, the same
      scope the web Inbox badge counts: undismissed and not yet opened. An
      approval the user has opened stays in `AppEntities.list_approvals/1` and
      leaves this count.
    * `tasks`: tasks assigned to the user (`assignee_type: "user"`) that are
      open: not `done`, not `cancelled`, not soft-deleted.
    * `unread` (task 01a1261e): the Chat unread total,
      `Platform.Chat.total_unread_for_viewer/1`, the same number the web
      rail badge shows and the push payload's `unread_count` carries. The
      app reconciles its per-install count with it on open. Composed, never
      recounted here: that function is the single definition.

  `as_of` is read BEFORE the counts, so every count reflects at least every
  change up to it; the app keeps the value with the newest `as_of`.
  """
  @spec counts_for_user(User.t()) :: %{
          approvals: non_neg_integer(),
          tasks: non_neg_integer(),
          unread: non_neg_integer(),
          as_of: DateTime.t()
        }
  def counts_for_user(%User{id: user_id} = user) do
    as_of = DateTime.utc_now()

    approvals =
      user_id
      |> Inbox.reachable_badge_scope()
      |> where([i], i.kind in @approval_kinds)
      |> Repo.aggregate(:count)

    tasks =
      from(t in Task,
        where:
          t.assignee_type == "user" and t.assignee_id == ^user_id and
            t.status not in @terminal_task_statuses and is_nil(t.deleted_at)
      )
      |> Repo.aggregate(:count)

    unread = Platform.Chat.total_unread_for_viewer(user)

    %{approvals: approvals, tasks: tasks, unread: unread, as_of: as_of}
  end

  @doc "SHA-256 of a raw token or code, as stored."
  @spec hash(String.t()) :: binary()
  def hash(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw)

  # ── internals ──────────────────────────────────────────────────────────

  defp create_session(%User{} = user, attrs) do
    token = random_secret()

    Multi.new()
    |> Multi.insert(
      :session,
      AppSession.changeset(%AppSession{}, %{
        user_id: user.id,
        token_hash: hash(token),
        app_install_id: fetch(attrs, :app_install_id),
        device_name: fetch(attrs, :device_name),
        last_used_at: DateTime.utc_now()
      })
    )
    |> Multi.run(:handoff, fn _repo, _ -> insert_code(user.id, "handoff", nil) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{session: session, handoff: handoff_code}} ->
        {:ok, %{token: token, session: session, handoff_code: handoff_code}}

      {:error, _step, _reason, _changes} ->
        {:error, :session_not_created}
    end
  end

  defp insert_code(user_id, purpose, challenge) do
    code = random_secret()

    %AppLoginCode{}
    |> AppLoginCode.changeset(%{
      user_id: user_id,
      code_hash: hash(code),
      code_challenge: challenge,
      purpose: purpose,
      expires_at: DateTime.add(DateTime.utc_now(), @code_ttl_seconds, :second)
    })
    |> Repo.insert()
    |> case do
      {:ok, _row} -> {:ok, code}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Single-use and expiry in ONE conditional UPDATE: two concurrent
  # redemptions of one code cannot both see it unconsumed.
  defp consume_code(code, purpose) when code != "" do
    now = DateTime.utc_now()

    from(c in AppLoginCode,
      where:
        c.code_hash == ^hash(code) and c.purpose == ^purpose and is_nil(c.consumed_at) and
          c.expires_at > ^now,
      select: c
    )
    |> Repo.update_all(set: [consumed_at: now])
    |> case do
      {1, [row]} -> {:ok, row}
      _ -> {:error, :invalid_code}
    end
  end

  defp consume_code(_code, _purpose), do: {:error, :invalid_code}

  defp verifier_matches?(verifier, challenge) when is_binary(challenge) do
    Regex.match?(@verifier_format, verifier) and
      Plug.Crypto.secure_compare(
        :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false),
        challenge
      )
  end

  defp verifier_matches?(_verifier, _challenge), do: false

  defp random_secret, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp fetch(attrs, key) when is_atom(key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
