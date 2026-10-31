defmodule PlatformWeb.AuthController do
  use PlatformWeb, :controller

  alias Platform.Accounts.ExternalAdmission
  alias Platform.Access.IdpGroupRoles
  alias Platform.Mobile
  alias Platform.OIDC
  alias PlatformWeb.ExternalRedirect
  alias PlatformWeb.ExternalSurface
  alias PlatformWeb.LoginOrigin

  # Native app login (task 01a10882). The app opens this route in an
  # `ASWebAuthenticationSession` with `app_challenge=<PKCE S256 challenge>`;
  # it rides the signed session to the callback, which then hands the app an
  # exchange code instead of landing a web page. A malformed challenge is
  # refused up front. Without the param this is today's login, except that a
  # challenge left behind by an abandoned app login is cleared so it cannot
  # turn a later web login into an app redirect.
  def login(conn, %{"app_challenge" => challenge}) do
    case Mobile.begin_app_login(challenge) do
      {:ok, challenge} ->
        conn
        |> put_session(:app_challenge, challenge)
        |> start_login()

      {:error, :invalid_challenge} ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid app_challenge")
    end
  end

  def login(conn, _params) do
    conn
    |> delete_session(:app_challenge)
    |> start_login()
  end

  # Task 01a10315 stage 6 round 2: the hand-over sign-in link of a new
  # install. bootstrap-admin points it HERE, at the install's own host, with
  # pocket-id's one-time code: `/auth/handover?code=<code>` (query string, so
  # the request log's `code` filter covers it). Burrow starts its ordinary
  # OIDC login (state, nonce and PKCE in this signed session), opens the
  # matching pocket-id sign-in interaction server-side
  # (`OIDC.begin_interaction/1`) and sends the browser to pocket-id's
  # `/lc/<code>` with `redirect=` that interaction's relative path. pocket-id
  # signs the owner in with the code and shows "Sign in to Burrow"; one click
  # completes the interaction (the client is registered with `skipConsent`,
  # so no consent step follows) and pocket-id returns to
  # `/auth/oidc/callback`, which lands on `/setup/connect-ai` instead of `/`.
  # The code is never echoed, and only ever placed on the issuer's host.
  @handover_code ~r/\A[A-Za-z0-9]{6,64}\z/
  @handover_landing "/setup/connect-ai"

  def handover(conn, %{"code" => code}) when is_binary(code) do
    with true <- Regex.match?(@handover_code, code),
         [] <- OIDC.missing_settings(),
         {:ok, %{url: url, session_params: session_params}} <- OIDC.authorize_url(),
         {:ok, interaction} <- OIDC.begin_interaction(url) do
      conn
      |> delete_session(:app_challenge)
      |> put_session(:oidc_session_params, session_params)
      |> put_session(:post_login_path, @handover_landing)
      |> put_session(:signed_in_with_link, true)
      |> LoginOrigin.capture()
      |> redirect(external: handover_url(url, code, interaction))
    else
      false ->
        handover_invalid(conn)

      missing when is_list(missing) ->
        login_unavailable(conn, missing_settings_message(missing))

      {:error, error} ->
        require Logger

        Logger.warning(
          "[auth_handover] could not open the sign-in: #{handover_error_kind(error)}"
        )

        login_unavailable(conn, provider_unreachable_message())
    end
  end

  def handover(conn, _params), do: handover_invalid(conn)

  defp handover_invalid(conn) do
    conn
    |> put_status(:bad_request)
    |> text("Sign-in link is invalid or has expired")
  end

  defp handover_error_kind(error) when is_atom(error), do: inspect(error)
  defp handover_error_kind({kind, _detail}) when is_atom(kind), do: inspect(kind)
  defp handover_error_kind(error), do: error_kind(error)

  @doc false
  # pocket-id's one-time login on the authorize URL's own origin, redirecting
  # (a relative path to one of pocket-id's own pages: it refuses anything
  # else) to the sign-in interaction `OIDC.begin_interaction/1` opened.
  def handover_url(authorize_url, code, interaction_path) do
    authorize = URI.parse(authorize_url)

    %URI{
      scheme: authorize.scheme,
      host: authorize.host,
      port: authorize.port,
      path: "/lc/" <> code,
      query: URI.encode_query(%{"redirect" => interaction_path})
    }
    |> URI.to_string()
  end

  defp start_login(conn) do
    # An ordinary login never inherits an abandoned hand-over's landing.
    conn = delete_session(conn, :post_login_path)

    :telemetry.execute(
      [:platform, :auth, :login],
      %{system_time: System.system_time()},
      %{action: "redirect", ip_address: format_ip(conn.remote_ip)}
    )

    case OIDC.missing_settings() do
      [] -> redirect_to_provider(conn)
      missing -> login_unavailable(conn, missing_settings_message(missing))
    end
  end

  # Task 01a10322 stage 6: a fresh install with no OIDC settings, or one that
  # cannot reach its provider, answers with a readable 503 instead of a raise
  # or an inspected exception struct. The provider's error is logged by kind
  # only; its fields can carry request details.
  @doc false
  def missing_settings_message(missing) do
    "Sign-in is not set up on this install. Set #{Enum.join(missing, ", ")} " <>
      "in the install's environment, then restart it."
  end

  @doc false
  def provider_unreachable_message do
    "Sign-in is unavailable: this install could not reach its sign-in provider. " <>
      "Check that OIDC_ISSUER points at a provider this server can reach, then try again."
  end

  defp login_unavailable(conn, message) do
    conn
    |> put_status(:service_unavailable)
    |> text(message)
  end

  defp redirect_to_provider(conn) do
    case OIDC.authorize_url() do
      {:ok, %{url: url, session_params: session_params}} ->
        # task 019ffec0: remember WHICH surface this login started on, in the
        # same chain and the same signed session as `:oidc_session_params` —
        # the callback's `state` check already depends on that session
        # surviving the sibling-host -> IdP -> app-host round trip, so the
        # origin rides a cookie we already trust. `capture/1` resolves it
        # server-side from `conn.host`; nothing client-supplied is stored.
        conn
        |> put_session(:oidc_session_params, session_params)
        |> LoginOrigin.capture()
        |> redirect(external: url)

      {:error, error} ->
        require Logger
        Logger.warning("[auth_login] OIDC authorize_url failed: #{error_kind(error)}")
        login_unavailable(conn, provider_unreachable_message())
    end
  end

  defp error_kind(%{__struct__: module}), do: inspect(module)
  defp error_kind(_error), do: "unknown error"

  def callback(conn, %{"state" => state, "code" => _code} = params) do
    session_params = get_session(conn, :oidc_session_params)

    require Logger

    Logger.debug(
      "[auth_callback] session_params=#{inspect(session_params, limit: 5)} " <>
        "params_state=#{String.slice(state, 0, 8)}... " <>
        "session_state=#{inspect(session_params && String.slice(to_string(session_params[:state] || ""), 0, 8))}..."
    )

    # rbac-external-users M2 stage 3: derive the admission surface from the
    # request host. M4 owns the live `chat.` live_session/router/layout — this
    # host-prefix check only picks the admission INPUT and does not tread on
    # that route work.
    surface = login_surface(conn)

    with true <- is_map(session_params) and session_params[:state] == state,
         {:ok, auth} <- OIDC.callback(params, session_params),
         {:ok, oidc_user} <- extract_oidc_user(auth),
         {:ok, %ExternalAdmission.Result{} = result} <-
           admit_capturing_email(oidc_user, surface) do
      user = result.user

      :telemetry.execute(
        [:platform, :auth, :callback],
        %{system_time: System.system_time()},
        %{
          action: "success",
          actor_id: user.id,
          actor_type: "user",
          resource_type: "session",
          resource_id: user.id,
          ip_address: format_ip(conn.remote_ip),
          email: user.email
        }
      )

      conn
      # task 019ffec0: the login-origin key is cleared inside `land_admission/3`,
      # NOT here. It must be read before it is dropped, and `land_admission/3`
      # both reads it and sends the response — clearing it in this chain would
      # wipe the key one step before the only function that consumes it, and
      # clearing it after would be a `put_session` on an already-sent conn.
      |> delete_session(:oidc_session_params)
      |> delete_session(:post_login_path)
      |> put_session(:current_user_id, user.id)
      |> maybe_put_id_token(auth)
      |> maybe_put_end_session_endpoint(session_params)
      |> land_callback(result, post_login_path(conn))
    else
      false ->
        emit_callback_failure(conn, :invalid_state)
        invalid_state(conn)

      {:error, {:user_archived, email}} ->
        emit_access_blocked(conn, :user_archived, email)
        user_archived(conn)

      {:error, reason} ->
        emit_callback_failure(conn, reason)

        conn
        |> put_status(:unauthorized)
        |> text("OIDC callback failed: #{inspect(reason)}")
    end
  end

  def callback(conn, _params) do
    emit_callback_failure(conn, :missing_params)
    invalid_state(conn)
  end

  # Where a full internal user lands: `/`, or `/setup/connect-ai` when the
  # login began at `handover/2`. A closed set read from the signed session,
  # never from a parameter, so this is not an open redirect.
  defp post_login_path(conn) do
    case get_session(conn, :post_login_path) do
      @handover_landing -> @handover_landing
      _ -> ~p"/"
    end
  end

  # Task 01a10882: an app login (an `:app_challenge` in the session, put there
  # by `login/2`) by a FULL user lands in the app, not on a web page: mint a
  # single-use exchange code bound to the challenge and redirect to the app's
  # custom scheme. The scheme and path are fixed here, never taken from a
  # parameter, so this is not an open redirect. Anything else, including a
  # holding user, lands exactly as before.
  @app_callback_url "burrow://auth/callback"

  defp land_callback(
         conn,
         %ExternalAdmission.Result{state: :full, user: user} = result,
         full_path
       ) do
    with challenge when is_binary(challenge) <- get_session(conn, :app_challenge),
         {:ok, code} <- Mobile.issue_exchange_code(user, challenge) do
      conn
      |> delete_session(:app_challenge)
      |> LoginOrigin.clear()
      |> redirect(external: @app_callback_url <> "?" <> URI.encode_query(%{code: code}))
    else
      _ -> land_admission(conn, result, full_path)
    end
  end

  defp land_callback(conn, result, full_path), do: land_admission(conn, result, full_path)

  @doc """
  Redeem a one-time app handoff code (task 01a10882) and sign this browser
  in as its user, writing the same `:current_user_id` session key
  `callback/2` writes. The app's WKWebView calls this right after
  `POST /api/app/session`, so it gets an ordinary browser session without
  any cookie crossing from the system browser, and again after
  `POST /api/app/handoff` on a cold start. An optional `to` lands on that
  local path (`Mobile.safe_return_path/1`; anything else lands on `/`). The
  code is never echoed.
  """
  def app_handoff(conn, params) do
    case Mobile.consume_handoff_code(params["code"]) do
      {:ok, user} ->
        conn
        |> configure_session(renew: true)
        |> delete_session(:app_challenge)
        |> put_session(:current_user_id, user.id)
        |> redirect(to: Mobile.safe_return_path(params["to"]))

      {:error, :invalid_code} ->
        conn
        |> put_status(:unauthorized)
        |> text("Sign-in link is invalid or has expired")
    end
  end

  # Wrap `ExternalAdmission.admit/2` so the archived-user rejection carries
  # the OIDC-claim email through the `with` chain into the telemetry emitter.
  # The email isn't on the (nonexistent) session yet, and the OIDC callback
  # params don't include it — the OIDC exchange did — so we bind it here.
  # `admit/2` returns a `%Result{}` on success (full OR holding), or an
  # `{:error, _}` straight from `find_or_create_from_oidc/1` (archived etc).
  defp admit_capturing_email(%{email: email} = oidc_user, surface) do
    case ExternalAdmission.admit(oidc_user, surface: surface) do
      %ExternalAdmission.Result{} = result -> {:ok, result}
      {:error, :user_archived} -> {:error, {:user_archived, email}}
      {:error, reason} -> {:error, reason}
    end
  end

  # rbac-external-users M2 stage 3: `:external` when the request arrives on
  # the `chat.` host, else `:app`. (M4 owns the real external live_session.)
  defp login_surface(conn) do
    if String.starts_with?(to_string(conn.host), "chat."), do: :external, else: :app
  end

  # Land the session on the right surface. `:full` keeps the caller's normal
  # redirect (`/` for callback, `/chat` for dev_login) UNCHANGED. `:holding`
  # STILL establishes the session — the user IS authenticated; access is
  # fenced downstream (M6/M7), not by withholding the session — plants the
  # `:external_admission` seam key M3 reads, and redirects to a valid route.
  defp land_admission(conn, %ExternalAdmission.Result{state: :full} = result, full_path) do
    # task 019f9257: PIN external full users to the chat host. OIDC login is
    # anchored to the suite host (runtime.exs OIDC redirect), so a host-relative
    # redirect lands an external user on suite. — where the internal
    # `:authenticated` live_session previously leaked every channel. Send them to
    # the ABSOLUTE chat-host external surface instead. Internal full users keep
    # today's EXACT host-relative redirect (`/` for callback, `/chat` for
    # dev_login); when CHAT_HOST is unconfigured (dev/test) external users also
    # fall back to host-relative so local flows are unchanged.
    #
    # task 019ffec0: an EXTERNAL full user who started this login on the meet
    # host goes back to the meet host. The origin is read from the signed
    # session (`LoginOrigin`), never from anything the client supplied, and it
    # is a closed set of three atoms — a stored value outside that set reads
    # `:app` and takes the branch below.
    #
    # `result.external?` gates the new branch as well as the old one, so an
    # INTERNAL user's destination is unchanged whatever the origin says. That
    # is deliberate: this function is the shared landing for every sign-in on
    # every surface, and the internal host-relative path (`/` for callback,
    # `/chat` for dev_login) must stay unreachable from here.
    #
    # The origin is read INSIDE this clause rather than threaded in as an
    # argument, which keeps `land_admission/3`'s arity and therefore keeps
    # `dev_login/2` exercising this identical branch as a test harness.
    origin = LoginOrigin.read(conn)

    # Clearing lives HERE, not in the `callback/2` chain: this clause is the
    # only consumer of the key AND it sends the response, so a clear upstream
    # would drop the value one step before the read, and a clear downstream
    # would be a `put_session` on an already-sent conn.
    conn = LoginOrigin.clear(conn)

    cond do
      result.external? and origin == :meet and ExternalSurface.meet_host_configured?() ->
        redirect(conn, external: ExternalRedirect.meet_url("/meetings"))

      result.external? and ExternalRedirect.chat_host_configured?() ->
        redirect(conn, external: ExternalRedirect.chat_url("/chat"))

      true ->
        redirect(conn, to: full_path)
    end
  end

  # task 019ffec0: DELIBERATELY UNCHANGED. A holding user still lands on the
  # host-relative `post_login_path(result)` whatever surface they started on.
  # Sending a holding user to the meet host is a separate decision about what
  # a not-yet-admitted external user may see there, and this ticket does not
  # make it.
  defp land_admission(conn, %ExternalAdmission.Result{state: :holding} = result, _full_path) do
    conn
    |> put_session(:external_admission, %{
      state: :holding,
      reason: result.reason,
      user_id: result.user.id
    })
    |> redirect(to: ExternalAdmission.post_login_path(result))
  end

  # Task 01a14d12: `app_challenge` makes dev_login the app sign-in that
  # `login/2` starts, without OIDC, so the Burrow desktop e2e can sign in on
  # a dev server with no passkey. Same validation as `login/2`, then the same
  # `land_callback/3` landing as the OIDC callback. Without the param this is
  # unchanged.
  def dev_login(conn, %{"app_challenge" => challenge} = params) do
    case Mobile.begin_app_login(challenge) do
      {:ok, challenge} ->
        conn
        |> put_session(:app_challenge, challenge)
        |> dev_admit(params, &land_callback(&1, &2, ~p"/chat"))

      {:error, :invalid_challenge} ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid app_challenge")
    end
  end

  def dev_login(conn, params), do: dev_admit(conn, params, &land_admission(&1, &2, ~p"/chat"))

  defp dev_admit(conn, params, land) do
    # `?as=<slug>` lets E2E tests log in as distinct users in parallel
    # browser contexts without touching OIDC. The default "dev-local-user"
    # is preserved for the interactive `/dev/login` link.
    {sub, email, name} =
      case Map.get(params, "as") do
        nil ->
          {"dev-local-user", "dev@localhost", "Dev User"}

        slug when is_binary(slug) ->
          slug = String.downcase(slug)
          {"dev-#{slug}", "#{slug}@localhost", "Dev #{String.capitalize(slug)}"}
      end

    # Mirror the OIDC callback: route through admission so the dev/e2e path
    # stays honest for holding + archived, not only for the happy path.
    surface = login_surface(conn)

    case ExternalAdmission.admit(%{sub: sub, email: email, name: name}, surface: surface) do
      %ExternalAdmission.Result{} = result ->
        user = result.user

        # Add to `general` ONLY for a full INTERNAL dev user. Holding users get
        # zero scoped content; a full EXTERNAL user's spaces come from the grant.
        if result.state == :full and not result.external? do
          space = Platform.Chat.get_space_by_slug("general")

          if space do
            Platform.Chat.add_participant(space.id, %{
              participant_type: "user",
              participant_id: user.id,
              display_name: user.name || name,
              joined_at: DateTime.utc_now()
            })
          end
        end

        conn
        |> put_session(:current_user_id, user.id)
        |> put_session(:oidc_id_token, "dev-id-token")
        |> land.(result)

      {:error, :user_archived} ->
        # Same interstitial the OIDC callback renders — dev_login
        # exercises the identical `find_or_create_from_oidc/1` code
        # path, so it must refuse identically to keep the e2e archived
        # user check honest.
        emit_access_blocked(conn, :user_archived, email)
        user_archived(conn)
    end
  end

  def logout(conn, _params) do
    id_token_hint = get_session(conn, :oidc_id_token)
    end_session_endpoint = get_session(conn, :oidc_end_session_endpoint)
    user_id = get_session(conn, :current_user_id)

    :telemetry.execute(
      [:platform, :auth, :logout],
      %{system_time: System.system_time()},
      %{
        action: "logout",
        actor_id: user_id,
        actor_type: if(user_id, do: "user", else: "anonymous"),
        ip_address: format_ip(conn.remote_ip)
      }
    )

    conn
    |> configure_session(drop: true)
    |> redirect(external: OIDC.logout_url(id_token_hint, end_session_endpoint))
  end

  # -- Telemetry helpers --

  defp emit_callback_failure(conn, reason) do
    :telemetry.execute(
      [:platform, :auth, :callback],
      %{system_time: System.system_time()},
      %{
        action: "failure",
        ip_address: format_ip(conn.remote_ip),
        reason: inspect(reason)
      }
    )
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: to_string(ip)

  # -- OIDC helpers --

  defp invalid_state(conn) do
    conn
    |> configure_session(drop: true)
    |> put_status(:unauthorized)
    |> text("Invalid OIDC state")
  end

  # Stage 5: archived-user interstitial. Drops any session bleed-through
  # (defensive — the OIDC + dev_login paths shouldn't have set
  # `current_user_id` yet, but a stale session cookie can be lingering),
  # then renders 403 with the message the plan pins. The product name is the
  # install's own (Platform.Branding.app_name/0), never a compiled one
  # (task 01a120c5 stage 3).
  defp user_archived(conn) do
    conn
    |> configure_session(drop: true)
    |> put_status(:forbidden)
    |> text(
      "This account has been archived. Contact your #{Platform.Branding.app_name()} administrator."
    )
  end

  defp emit_access_blocked(conn, reason, email) do
    :telemetry.execute(
      [:platform, :auth, :access_blocked],
      %{system_time: System.system_time()},
      %{
        action: "blocked",
        ip_address: format_ip(conn.remote_ip),
        reason: to_string(reason),
        email: email
      }
    )
  end

  defp maybe_put_id_token(conn, auth) do
    case extract_id_token(auth) do
      nil -> delete_session(conn, :oidc_id_token)
      id_token -> put_session(conn, :oidc_id_token, id_token)
    end
  end

  # Store the provider's end_session_endpoint from the OIDC discovery doc so
  # logout_url/2 doesn't need to guess the path (works for any OIDC provider).
  defp maybe_put_end_session_endpoint(conn, session_params) do
    endpoint =
      get_in(session_params, [:openid_configuration, "end_session_endpoint"]) ||
        get_in(session_params, ["openid_configuration", "end_session_endpoint"])

    case endpoint do
      nil -> conn
      url -> put_session(conn, :oidc_end_session_endpoint, url)
    end
  end

  defp extract_oidc_user(auth) when is_map(auth) do
    user_claims = oidc_claims(auth, :user)
    userinfo_claims = oidc_claims(auth, :userinfo)
    id_token_claims = oidc_claims(auth, :id_token)

    if Enum.all?([user_claims, userinfo_claims, id_token_claims], &(map_size(&1) == 0)) do
      {:error, :missing_oidc_user}
    else
      claims =
        id_token_claims
        |> Map.merge(user_claims)
        |> Map.merge(userinfo_claims)
        |> Map.put(
          "picture",
          id_token_claims["picture"] || userinfo_claims["picture"] || user_claims["picture"]
        )

      normalize_oidc_user(claims)
    end
  end

  defp extract_oidc_user(_auth), do: {:error, :missing_oidc_user}

  defp normalize_oidc_user(user) do
    user = oidc_claims(user)

    name =
      user["name"] ||
        [user["given_name"], user["family_name"]]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" ")
        |> then(fn s -> if s == "", do: nil, else: s end) ||
        user["preferred_username"] ||
        user["email"]

    picture = normalize_optional_string(user["picture"])

    # rbac-external-users M2 stage 1: READ (never fetch) the external-user
    # marker claim so downstream admission can distinguish an external login
    # from an internal one. Orthogonal to the admin|member role axis —
    # `find_or_create_from_oidc/1` ignores this extra key.
    # Task 019ff7ff stage 2: carry the claim's VALUES through as well, so
    # admission can resolve which org an external login names. Purely
    # additive — `external_claim?` keeps its own callers and its meaning.
    external_groups = OIDC.claim_groups(user)
    external_claim? = OIDC.external_claim?(user) or IdpGroupRoles.guest_group?(external_groups)
    groups_claim_present? = Map.has_key?(user, OIDC.external_claim())

    case {user["sub"], user["email"], name} do
      {sub, email, n} when is_binary(sub) and is_binary(email) and is_binary(n) ->
        {:ok,
         %{
           sub: sub,
           email: email,
           name: n,
           avatar_url: picture,
           external_claim?: external_claim?,
           external_groups: external_groups,
           groups_claim_present?: groups_claim_present?
         }}

      _ ->
        {:error, :invalid_oidc_user}
    end
  end

  defp oidc_claims(claims) when is_map(claims) do
    for {key, value} <- claims, into: %{}, do: {to_string(key), value}
  end

  defp oidc_claims(_claims), do: %{}

  defp oidc_claims(auth, key) when is_map(auth),
    do: oidc_claims(Map.get(auth, key) || Map.get(auth, Atom.to_string(key)))

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp extract_id_token(%{token: token}), do: extract_id_token(token)
  defp extract_id_token(%{"token" => token}), do: extract_id_token(token)
  defp extract_id_token(%{id_token: id_token}) when is_binary(id_token), do: id_token
  defp extract_id_token(%{"id_token" => id_token}) when is_binary(id_token), do: id_token
  defp extract_id_token(_auth), do: nil
end
