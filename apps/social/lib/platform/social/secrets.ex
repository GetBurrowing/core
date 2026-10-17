defmodule Platform.Social.Secrets do
  @moduledoc """
  Social's ONLY reads and writes of secrets (task 01a140a9, Social 2/7;
  task 01a14722 for the install-level Zernio key), following
  `Platform.Mail`'s accessor pattern: `Platform.Vault.get_unique/2` (which
  refuses an ambiguous slug) with the EXACT scope and the integration-owner
  accessor. No grant is created or widened, and nothing is ever read from
  config, env, the DB or a struct field.

    * the install's Zernio API key: ONE key for every profile and account,
      slug `"social:zernio:api_key"`, scope and accessor `{:integration, nil}`
      (`scope_id` NULL). The unique index is NULLS NOT DISTINCT, so at most
      one row exists, and `check_access` grants the owner on
      `scope_id == accessor_id` (nil == nil). An `{:agent, _}` accessor falls
      to the cross-type clause and needs an explicit grant, so agents cannot
      read it. Per-account and per-profile Zernio ids
      (`provider_account_ref`, `provider_profile_ref`) are data, not secrets;
      `Account.secret_slug` is inert and no longer read;
    * a profile's webhook secret: slug `"social:webhook:<profile_id>"`,
      scope and accessor `{:integration, profile_id}`.

  The Zernio key is written ONLY by `put_zernio_api_key/2`, and only for a
  non-archived human user: the first save is `Vault.put/4`, every later one
  `Vault.rotate/3`, so there is never a second row. Who saved it is an
  access-log `"update"` row carrying `set_by_user_id` and nothing else (never
  the value or its fingerprint). `zernio_key_status/0` reads metadata only
  and never decrypts.

  A missing, empty or undecryptable secret is `{:error, :secret_unavailable}`
  (or the Vault's own refusal): callers fail closed.
  """

  alias Platform.Accounts.User
  alias Platform.Social.Profile
  alias Platform.Vault

  @zernio_slug "social:zernio:api_key"
  @zernio_scope {:integration, nil}

  @doc "The Vault slug of a profile's webhook secret."
  @spec webhook_slug(Profile.t() | Ecto.UUID.t()) :: String.t()
  def webhook_slug(%Profile{id: id}), do: webhook_slug(id)
  def webhook_slug(profile_id) when is_binary(profile_id), do: "social:webhook:#{profile_id}"

  @doc "The vault scope (and accessor) owning an account's or profile's secret."
  @spec scope(Account.t() | Profile.t() | Ecto.UUID.t()) :: {:integration, Ecto.UUID.t()}
  def scope(%{id: id}), do: {:integration, id}
  def scope(id) when is_binary(id), do: {:integration, id}

  @doc "The Vault slug of the install's Zernio API key."
  @spec zernio_slug() :: String.t()
  def zernio_slug, do: @zernio_slug

  @doc "The Vault scope (and accessor) owning the install's Zernio API key."
  @spec zernio_scope() :: {:integration, nil}
  def zernio_scope, do: @zernio_scope

  @doc "The install's Zernio API key, used by every profile and account."
  @spec zernio_api_key() :: {:ok, binary()} | {:error, term()}
  def zernio_api_key, do: read(@zernio_slug, @zernio_scope)

  @doc """
  Whether the install's Zernio key is set, from Vault metadata ONLY (nothing
  is decrypted). `changed_by_user_id` is the user named by the latest
  `"update"` access-log row for this credential, or nil.
  """
  @spec zernio_key_status() ::
          :not_set
          | {:set, %{changed_at: DateTime.t(), changed_by_user_id: Ecto.UUID.t() | nil}}
  def zernio_key_status do
    case zernio_credential_meta() do
      nil ->
        :not_set

      meta ->
        {:set,
         %{
           changed_at: meta.rotated_at || meta.inserted_at,
           changed_by_user_id: last_setter(meta)
         }}
    end
  end

  @doc """
  Store or replace the install's Zernio API key on behalf of a human user.

  The value is trimmed; a blank one is `{:error, :blank}`. Anything but a
  non-archived `%Platform.Accounts.User{}` is `{:error, :not_a_human}` and
  writes nothing.
  """
  @spec put_zernio_api_key(term(), term()) ::
          {:ok, Vault.Credential.t()} | {:error, :blank | :not_a_human | term()}
  def put_zernio_api_key(value, %User{archived_at: nil, id: user_id}) when is_binary(user_id) do
    case if(is_binary(value), do: String.trim(value), else: "") do
      "" ->
        {:error, :blank}

      key ->
        with {:ok, cred} <- write_zernio_key(key, zernio_credential_meta()) do
          Vault.record_access(cred, @zernio_scope, "update", %{"set_by_user_id" => user_id})
          {:ok, cred}
        end
    end
  end

  def put_zernio_api_key(_value, _not_a_human), do: {:error, :not_a_human}

  defp write_zernio_key(key, nil) do
    Vault.put(@zernio_slug, :api_key, key,
      scope: @zernio_scope,
      provider: "social",
      name: "Zernio API key"
    )
  end

  defp write_zernio_key(key, _existing) do
    Vault.rotate(@zernio_slug, key, scope: @zernio_scope, accessor: @zernio_scope)
  end

  defp zernio_credential_meta do
    [scope: @zernio_scope]
    |> Vault.list()
    |> Enum.find(&(&1.slug == @zernio_slug))
  end

  defp last_setter(%{id: id, slug: slug}) do
    %Vault.Credential{id: id, slug: slug}
    |> Vault.access_log()
    |> Enum.find_value(fn
      %{credential_id: ^id, action: "update", metadata: %{"set_by_user_id" => uid}} -> uid
      _ -> nil
    end)
  end

  @doc "A profile's webhook secret."
  @spec webhook_secret(Profile.t() | Ecto.UUID.t()) :: {:ok, binary()} | {:error, term()}
  def webhook_secret(%Profile{id: id}), do: webhook_secret(id)

  def webhook_secret(profile_id) when is_binary(profile_id),
    do: read(webhook_slug(profile_id), scope(profile_id))

  defp read(slug, scope) do
    case Vault.get_unique(slug, scope: scope, accessor: scope) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _undecryptable_or_empty} -> {:error, :secret_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end
end
