defmodule Platform.SignInAdmin.PocketId do
  @moduledoc """
  Server-to-server client for the pocket-id admin API, used by the native
  sign-in users page (task 01a113ea-3ef4-7001-b3fc-5d0a1bafc5df).

  Every request goes to `Platform.SignInAdmin.Config.url/0` and carries the
  install's static API key in `X-API-Key`. On pocket-id v2.18.0 that key maps
  to a synthetic admin user, and every `/api/users*` route accepts it
  (verified live against `ghcr.io/pocket-id/pocket-id:v2.18.0` on the test rig:
  200 with the key, 401 with a wrong one).

  `config :platform, :pocket_id_req_options` is merged into every request;
  `config/test.exs` routes it to the `Req.Test` stub named after this module,
  the house convention shared with peer federation, APNs and FCM.

  ## What never leaves this module

  Errors are `{:error, atom}` or `{:error, {:http, status}}` only. No
  function returns or logs a `Req.Request`, a `Req.Response`, a header list,
  a response body or an inspected exception, because each can carry the API
  key or a minted sign-in token (the same "error text is built from atoms
  only" rule as `PlatformWeb.EmailLive`). The single log line per request
  names the method, the path without its query string, and the status:

      pocket_id.request method=GET path=/api/users status=200

  The key is held as a `Platform.SignInAdmin.Config.Key` and a minted
  one-time token is returned as a `Platform.SignInAdmin.PocketId.Token`; both
  print as `<redacted>` under `inspect/1`.

  ## Sign-in link lifetime

  `one_time_token/1` always asks for `ttl: "30m"`. pocket-id mints a
  6-character code for a TTL of 15 minutes or less and a 12-character one
  above it, and a 6-character code never auto-submits from `/lc/<code>` on
  the default configuration, which is why the installer pins `LOGIN_TTL` to
  30m as well (`deployment/installer/burrow_install/setup/pocketid.py`).
  """

  require Logger

  alias Platform.SignInAdmin.Config

  # pocket-id creates this synthetic admin for the static API key. It is
  # listed by `GET /api/users` and is never a person to manage.
  @static_api_user_id "00000000-0000-0000-0000-000000000000"
  @page_limit 100
  @max_pages 1_000
  @max_username_attempts 20
  @username_max 50
  @token_ttl "30m"

  defmodule User do
    @moduledoc "A pocket-id user, as returned by `GET /api/users/:id`."
    defstruct [
      :id,
      :username,
      :email,
      :email_verified,
      :first_name,
      :last_name,
      :display_name,
      :is_admin,
      :disabled,
      :locale
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Token do
    @moduledoc """
    A pocket-id one-time access token. It is a credential: anyone holding it
    can sign in as the user until it expires, so `inspect/1` never prints it.
    Read it with `token.value` where the sign-in link is built.
    """
    @enforce_keys [:value]
    defstruct [:value]

    @type t :: %__MODULE__{value: String.t()}

    defimpl Inspect do
      def inspect(_token, _opts), do: "#SignInAdmin.Token<redacted>"
    end
  end

  @type error :: {:error, atom() | {:http, pos_integer()}}

  @doc "The id pocket-id gives the synthetic static-API-key user."
  @spec static_api_user_id() :: String.t()
  def static_api_user_id, do: @static_api_user_id

  @doc """
  Every pocket-id user, all pages, without the static API user.
  """
  @spec list_users() :: {:ok, [User.t()]} | error()
  def list_users, do: fetch_all([])

  @doc """
  The pocket-id user whose email matches `email` (trimmed, case-insensitive),
  or `{:ok, nil}` when there is none.
  """
  @spec find_by_email(String.t()) :: {:ok, User.t() | nil} | error()
  def find_by_email(email) when is_binary(email) do
    wanted = normalize_email(email)

    with {:ok, users} <- fetch_all([{"search", wanted}]) do
      {:ok, Enum.find(users, &(is_binary(&1.email) and normalize_email(&1.email) == wanted))}
    end
  end

  @doc """
  Creates a non-admin, email-verified pocket-id user.

  `attrs` carries `:email` (required) and `:name` (optional display name).
  The username is derived from the email's local part the way the installer
  derives the admin's (`pocketid.py` `default_username/1`), with a numeric
  suffix when pocket-id reports the username already in use. An email already
  in use returns `{:error, :email_taken}`.
  """
  @spec create_user(%{required(:email) => String.t(), optional(:name) => String.t() | nil}) ::
          {:ok, User.t()} | error()
  def create_user(%{email: email} = attrs) when is_binary(email) do
    email = normalize_email(email)
    name = attrs |> Map.get(:name) |> blank_to_nil() || local_part(email)
    base = default_username(email)

    do_create(email, name, base, 1)
  end

  @doc "How many passkeys (WebAuthn credentials) the user has registered."
  @spec passkey_count(String.t()) :: {:ok, non_neg_integer()} | error()
  def passkey_count(id) when is_binary(id) do
    case request(:get, user_path(id) <> "/webauthn-credentials") do
      {:ok, 200, list} when is_list(list) -> {:ok, length(list)}
      {:ok, 200, _} -> {:error, :bad_response}
      {:ok, status, _} -> http_error(status)
      {:error, _} = error -> error
    end
  end

  @doc """
  Mints a one-time access token (30 minute TTL) for the user and returns it
  wrapped in a redacting `Token`.
  """
  @spec one_time_token(String.t()) :: {:ok, Token.t()} | error()
  def one_time_token(id) when is_binary(id) do
    case request(:post, user_path(id) <> "/one-time-access-token", json: %{"ttl" => @token_ttl}) do
      {:ok, status, %{"token" => token}} when status in [200, 201] and is_binary(token) ->
        {:ok, %Token{value: token}}

      {:ok, status, _} when status in [200, 201] ->
        {:error, :bad_response}

      {:ok, status, _} ->
        http_error(status)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Disables or re-enables the user. `PUT /api/users/:id` takes the full user
  DTO and overwrites every field, so the current user is read first and every
  field is sent back unchanged except `disabled`.
  """
  @spec set_disabled(String.t(), boolean()) :: {:ok, User.t()} | error()
  def set_disabled(id, disabled) when is_binary(id) and is_boolean(disabled) do
    with {:ok, user} <- get_user(id) do
      case request(:put, user_path(id), json: update_body(user, disabled)) do
        {:ok, 200, body} -> decode_user(body)
        {:ok, status, _} -> http_error(status)
        {:error, _} = error -> error
      end
    end
  end

  @doc "Deletes the user and their passkeys from pocket-id."
  @spec delete_user(String.t()) :: :ok | error()
  def delete_user(id) when is_binary(id) do
    case request(:delete, user_path(id)) do
      {:ok, status, _} when status in [200, 204] -> :ok
      {:ok, status, _} -> http_error(status)
      {:error, _} = error -> error
    end
  end

  @doc "Reads one pocket-id user."
  @spec get_user(String.t()) :: {:ok, User.t()} | error()
  def get_user(id) when is_binary(id) do
    case request(:get, user_path(id)) do
      {:ok, 200, body} -> decode_user(body)
      {:ok, status, _} -> http_error(status)
      {:error, _} = error -> error
    end
  end

  # -- create ---------------------------------------------------------------

  defp do_create(_email, _name, _base, attempt) when attempt > @max_username_attempts,
    do: {:error, :username_taken}

  defp do_create(email, name, base, attempt) do
    {first, last} = split_name(name)

    body = %{
      "username" => username_for(base, attempt),
      "email" => email,
      "emailVerified" => true,
      "firstName" => first,
      "lastName" => last,
      "displayName" => String.slice(name, 0, 100),
      "isAdmin" => false
    }

    case request(:post, "/api/users", json: body) do
      {:ok, status, body} when status in [200, 201] ->
        decode_user(body)

      {:ok, 409, %{"details" => %{"property" => "username"}}} ->
        do_create(email, name, base, attempt + 1)

      {:ok, 409, %{"details" => %{"property" => "email"}}} ->
        {:error, :email_taken}

      {:ok, status, _} ->
        http_error(status)

      {:error, _} = error ->
        error
    end
  end

  # `pocketid.py` default_username/1: the email's local part, lowercased,
  # restricted to [a-z0-9_.-], at most 50 characters. The installer's fallback
  # is "admin" because it only ever creates the admin; an invitee falls back
  # to "user".
  defp default_username(email) do
    email
    |> local_part()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]/, "")
    |> String.slice(0, @username_max)
    |> case do
      "" -> "user"
      name -> name
    end
  end

  defp username_for(base, 1), do: base

  defp username_for(base, attempt) do
    suffix = Integer.to_string(attempt)
    String.slice(base, 0, @username_max - String.length(suffix)) <> suffix
  end

  defp split_name(name) do
    case String.split(String.trim(name), ~r/\s+/, parts: 2) do
      [first, last] -> {String.slice(first, 0, 50), String.slice(last, 0, 50)}
      [first] -> {String.slice(first, 0, 50), ""}
    end
  end

  defp update_body(%User{} = user, disabled) do
    %{
      "username" => user.username,
      "email" => user.email,
      "emailVerified" => user.email_verified,
      "firstName" => user.first_name,
      "lastName" => user.last_name,
      "displayName" => user.display_name,
      "isAdmin" => user.is_admin,
      "locale" => user.locale,
      "disabled" => disabled
    }
  end

  # -- list -----------------------------------------------------------------

  defp fetch_all(params), do: fetch_page(params, 1, [])

  defp fetch_page(_params, page, _acc) when page > @max_pages, do: {:error, :too_many_pages}

  defp fetch_page(params, page, acc) do
    query = [{"pagination[limit]", @page_limit}, {"pagination[page]", page} | params]

    case request(:get, "/api/users", params: query) do
      {:ok, 200, %{"data" => data} = body} when is_list(data) ->
        with {:ok, users} <- decode_users(data) do
          acc = acc ++ Enum.reject(users, &(&1.id == @static_api_user_id))

          case get_in(body, ["pagination", "totalPages"]) do
            total when is_integer(total) and page < total -> fetch_page(params, page + 1, acc)
            _ -> {:ok, acc}
          end
        end

      {:ok, 200, _} ->
        {:error, :bad_response}

      {:ok, status, _} ->
        http_error(status)

      {:error, _} = error ->
        error
    end
  end

  defp decode_users(data) do
    Enum.reduce_while(data, {:ok, []}, fn entry, {:ok, acc} ->
      case decode_user(entry) do
        {:ok, user} -> {:cont, {:ok, [user | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, users} -> {:ok, Enum.reverse(users)}
      error -> error
    end
  end

  defp decode_user(%{"id" => id} = body) when is_binary(id) do
    {:ok,
     %User{
       id: id,
       username: body["username"],
       email: body["email"],
       email_verified: body["emailVerified"] == true,
       first_name: body["firstName"],
       last_name: body["lastName"],
       display_name: body["displayName"],
       is_admin: body["isAdmin"] == true,
       disabled: body["disabled"] == true,
       locale: body["locale"]
     }}
  end

  defp decode_user(_), do: {:error, :bad_response}

  # -- transport ------------------------------------------------------------

  defp request(method, path, opts \\ []) do
    with {:ok, base, key} <- connection() do
      req_opts =
        [
          method: method,
          url: base <> path,
          headers: [{"x-api-key", key.value}],
          retry: false,
          redirect: false,
          receive_timeout: 10_000
        ]
        |> put_opt(:json, Keyword.get(opts, :json))
        |> put_opt(:params, Keyword.get(opts, :params))
        |> Keyword.merge(Application.get_env(:platform, :pocket_id_req_options, []))

      result =
        try do
          Req.request(req_opts)
        rescue
          _ -> {:error, :exception}
        catch
          _, _ -> {:error, :exception}
        end

      case result do
        {:ok, %Req.Response{status: status, body: body}} ->
          log(method, path, Integer.to_string(status))
          {:ok, status, body}

        {:error, reason} ->
          # The reason atom only: a transport exception can carry the
          # request it failed on, and the request holds the key.
          log(method, path, "transport_error reason=#{reason_atom(reason)}")
          {:error, :transport}
      end
    end
  end

  defp connection do
    case {Config.url(), Config.api_key()} do
      {base, %Config.Key{} = key} when is_binary(base) -> {:ok, base, key}
      _ -> {:error, :not_configured}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp log(method, path, status) do
    Logger.info(
      "pocket_id.request method=#{method |> Atom.to_string() |> String.upcase()} " <>
        "path=#{path} status=#{status}"
    )
  end

  defp reason_atom(%{__struct__: struct, reason: reason})
       when struct in [Req.TransportError, Req.HTTPError] and is_atom(reason),
       do: Atom.to_string(reason)

  defp reason_atom(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_atom(_), do: "unknown"

  defp http_error(404), do: {:error, :not_found}
  defp http_error(status), do: {:error, {:http, status}}

  defp user_path(id), do: "/api/users/" <> URI.encode(id, &URI.char_unreserved?/1)

  defp normalize_email(email), do: email |> String.trim() |> String.downcase()

  defp local_part(email), do: email |> String.split("@", parts: 2) |> hd()

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
