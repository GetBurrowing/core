defmodule Platform.Switcher do
  @moduledoc """
  Badge keys for the web install switcher (task 01a1ccd4 stage 2).

  The install list of the web switcher lives in each browser (localStorage on
  each install's origin), as the native app's device-held list does. No
  install's server learns which other installs a user belongs to.

  For the closed switcher's unread dot, install A needs one number from
  install B. B's session cookie is `SameSite=Lax` and `httpOnly`, so A cannot
  ride it. Instead B mints a BADGE KEY at a first-party consent visit
  (`GET /switcher/connect?origin=<A>`), bound to A's origin. The key:

    * is random, stored only as a SHA-256 (`token_hash`), revocable, and
      expires 90 days after minting;
    * is accepted by exactly one route, `GET /api/switcher/unread`, and only
      when the request's `Origin` equals `bound_origin`;
    * lives in its own table. It is never an `app_sessions` bearer, so it
      cannot post, read messages or sign anyone in.

  Origins are normalized to `scheme://host[:port]` by `normalize_origin/1`.
  """

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Switcher.BadgeKey

  @ttl_days 90
  @touch_interval_seconds 60
  @max_origin_bytes 300
  @token_prefix "bk_"

  @host_label ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/

  @doc "How long a badge key lives, in days."
  @spec ttl_days() :: pos_integer()
  def ttl_days, do: @ttl_days

  @doc """
  Normalize a browser origin to `scheme://host[:port]`.

  `https` for any host; `http` only for `localhost`, `*.localhost` and
  `127.0.0.1` (in every environment, so the dev rig works). Refuses a path
  (even a bare `/`), a query, a fragment, userinfo, any other scheme,
  whitespace, control characters and backslashes. The scheme and host are
  lower-cased and a default port is dropped.
  """
  @spec normalize_origin(term()) :: {:ok, String.t()} | {:error, :invalid_origin}
  def normalize_origin(value) when is_binary(value) and byte_size(value) <= @max_origin_bytes do
    with false <- String.contains?(value, "\\"),
         false <- String.match?(value, ~r/[\x00-\x20\x7f]/),
         {:ok, %URI{} = uri} <- URI.new(value),
         scheme when scheme in ["https", "http"] <- uri.scheme && String.downcase(uri.scheme),
         true <- String.starts_with?(String.downcase(value), scheme <> "://"),
         nil <- uri.userinfo,
         nil <- uri.path,
         nil <- uri.query,
         nil <- uri.fragment,
         host when is_binary(host) and host != "" <- uri.host && String.downcase(uri.host),
         true <- valid_host?(host),
         true <- scheme == "https" or local_host?(host) do
      {:ok, scheme <> "://" <> host <> port_suffix(scheme, uri.port)}
    else
      _ -> {:error, :invalid_origin}
    end
  end

  def normalize_origin(_), do: {:error, :invalid_origin}

  defp valid_host?(host) do
    labels = String.split(host, ".")
    labels != [] and Enum.all?(labels, &Regex.match?(@host_label, &1))
  end

  defp local_host?(host),
    do: host in ["localhost", "127.0.0.1"] or String.ends_with?(host, ".localhost")

  defp port_suffix("https", 443), do: ""
  defp port_suffix("http", 80), do: ""
  defp port_suffix(_scheme, nil), do: ""
  defp port_suffix(_scheme, port), do: ":" <> Integer.to_string(port)

  @doc """
  Mint a badge key for `user`, bound to `origin`. Any live key the user
  already has for the same origin is revoked in the same transaction, so a
  reconnect leaves one key per origin.

  Returns the raw key exactly once; only its hash is stored.

  Options: `:label` (shown in Settings; defaults to the origin's host),
  `:now`.
  """
  @spec mint(User.t(), String.t(), keyword()) ::
          {:ok, %{token: String.t(), key: BadgeKey.t()}}
          | {:error, :invalid_origin | Ecto.Changeset.t()}
  def mint(%User{id: user_id}, origin, opts \\ []) do
    with {:ok, origin} <- normalize_origin(origin) do
      now = Keyword.get(opts, :now) || DateTime.utc_now()

      token =
        @token_prefix <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))

      label = Keyword.get(opts, :label) || URI.parse(origin).host

      Repo.transaction(fn ->
        from(k in BadgeKey,
          where: k.user_id == ^user_id and k.bound_origin == ^origin and is_nil(k.revoked_at)
        )
        |> Repo.update_all(set: [revoked_at: now])

        %BadgeKey{}
        |> BadgeKey.changeset(%{
          user_id: user_id,
          token_hash: hash(token),
          bound_origin: origin,
          label: label,
          expires_at: DateTime.add(now, @ttl_days * 86_400, :second)
        })
        |> Repo.insert()
        |> case do
          {:ok, key} -> %{token: token, key: key}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Resolve a raw badge key presented with a request `Origin`.

  Refuses an unknown key, a revoked or expired key, an archived user, and an
  `origin` that does not normalize to the key's `bound_origin`. Every refusal
  is the same `:error`.
  """
  @spec verify(term(), term(), keyword()) :: {:ok, User.t(), BadgeKey.t()} | :error
  def verify(token, origin, opts \\ [])

  def verify(token, origin, opts) when is_binary(token) and token != "" do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    with {:ok, origin} <- normalize_origin(origin),
         %BadgeKey{revoked_at: nil} = key <- Repo.get_by(BadgeKey, token_hash: hash(token)),
         true <- DateTime.compare(key.expires_at, now) == :gt,
         true <- key.bound_origin == origin,
         %User{archived_at: nil} = user <- Accounts.get_user(key.user_id) do
      {:ok, user, key}
    else
      _ -> :error
    end
  end

  def verify(_token, _origin, _opts), do: :error

  @doc """
  Bump `last_used_at`, at most once per #{@touch_interval_seconds} seconds per
  key (the guard is in the UPDATE's WHERE clause).
  """
  @spec touch(BadgeKey.t()) :: :ok
  def touch(%BadgeKey{id: id}) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@touch_interval_seconds, :second)

    from(k in BadgeKey,
      where: k.id == ^id and (is_nil(k.last_used_at) or k.last_used_at < ^cutoff)
    )
    |> Repo.update_all(set: [last_used_at: now])

    :ok
  end

  @doc """
  Revoke one of `user`'s keys by id. Another user's key, an unknown id and an
  already-revoked key are all `{:error, :not_found}`.
  """
  @spec revoke(User.t(), term()) :: {:ok, BadgeKey.t()} | {:error, :not_found}
  def revoke(%User{id: user_id}, key_id) when is_binary(key_id) do
    with true <- Platform.UUID.valid?(key_id),
         %BadgeKey{revoked_at: nil} = key <-
           Repo.get_by(BadgeKey, id: key_id, user_id: user_id) do
      key
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
      |> Repo.update()
    else
      _ -> {:error, :not_found}
    end
  end

  def revoke(_user, _key_id), do: {:error, :not_found}

  @doc """
  Revoke the key a request presented (`DELETE /api/switcher/key`, task
  01a1ccd4 stage 3): install A's switcher removing this install calls it with
  the key it is dropping. Idempotent: an already-revoked key stays revoked.
  """
  @spec revoke_key(BadgeKey.t()) :: :ok
  def revoke_key(%BadgeKey{id: id}) do
    from(k in BadgeKey, where: k.id == ^id and is_nil(k.revoked_at))
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])

    :ok
  end

  @doc "The user's live (unrevoked, unexpired) keys, newest first."
  @spec list_for_user(User.t(), keyword()) :: [BadgeKey.t()]
  def list_for_user(%User{id: user_id}, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    from(k in BadgeKey,
      where: k.user_id == ^user_id and is_nil(k.revoked_at) and k.expires_at > ^now,
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  The whole body of `GET /api/switcher/unread`: the unread total from
  `Platform.Mobile.counts_for_user/1` and its `as_of`, nothing else (no
  approvals, tasks, names or ids).
  """
  @spec unread_payload(User.t()) :: %{unread: non_neg_integer(), as_of: String.t()}
  def unread_payload(%User{} = user) do
    %{unread: unread, as_of: as_of} = Platform.Mobile.counts_for_user(user)
    %{unread: unread, as_of: DateTime.to_iso8601(as_of)}
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)
end
