defmodule Platform.Social.Secrets do
  @moduledoc """
  Social's ONLY reads of secrets (task 01a140a9, Social 2/7), following
  `Platform.Mail`'s accessor pattern: `Platform.Vault.get_unique/2` (which
  refuses an ambiguous slug) with the EXACT scope and the integration-owner
  accessor, both `{:integration, owner_id}`. No grant is created or widened,
  and nothing is ever read from config, env, the DB or a struct field.

    * an account's vendor API key: slug `account.secret_slug`
      (`"social:<account_id>"`, set by `Platform.Social`), owner the account;
    * a profile's webhook secret: slug `"social:webhook:<profile_id>"`,
      owner the profile.

  A missing, empty or undecryptable secret is `{:error, :secret_unavailable}`
  (or the Vault's own refusal): callers fail closed.
  """

  alias Platform.Social.{Account, Profile}
  alias Platform.Vault

  @doc "The Vault slug of a profile's webhook secret."
  @spec webhook_slug(Profile.t() | Ecto.UUID.t()) :: String.t()
  def webhook_slug(%Profile{id: id}), do: webhook_slug(id)
  def webhook_slug(profile_id) when is_binary(profile_id), do: "social:webhook:#{profile_id}"

  @doc "The vault scope (and accessor) owning an account's or profile's secret."
  @spec scope(Account.t() | Profile.t() | Ecto.UUID.t()) :: {:integration, Ecto.UUID.t()}
  def scope(%{id: id}), do: {:integration, id}
  def scope(id) when is_binary(id), do: {:integration, id}

  @doc "An account's vendor API key."
  @spec account_key(Account.t()) :: {:ok, binary()} | {:error, term()}
  def account_key(%Account{secret_slug: slug} = account) when is_binary(slug),
    do: read(slug, account.id)

  def account_key(%Account{}), do: {:error, :secret_unavailable}

  @doc "A profile's webhook secret."
  @spec webhook_secret(Profile.t() | Ecto.UUID.t()) :: {:ok, binary()} | {:error, term()}
  def webhook_secret(%Profile{id: id}), do: webhook_secret(id)

  def webhook_secret(profile_id) when is_binary(profile_id),
    do: read(webhook_slug(profile_id), profile_id)

  defp read(slug, owner_id) do
    case Vault.get_unique(slug, scope: scope(owner_id), accessor: scope(owner_id)) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _undecryptable_or_empty} -> {:error, :secret_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end
end
