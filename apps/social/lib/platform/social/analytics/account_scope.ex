defmodule Platform.Social.Analytics.AccountScope do
  @moduledoc """
  Provider selection shared by post analytics and follower reads.

  Connection writers historically leave account.provider unset and select
  their adapter through Publisher.impl/0. An untagged account belongs to
  that configured adapter's namespace only when it is Zernio; reference
  strings alone are not evidence. Explicit other providers stay excluded.
  Rebuild this predicate for each current/locked query, not once at boot.
  """
  import Ecto.Query
  alias Platform.Social.Publisher

  @doc "The same current provider namespace check for a previously loaded account."
  def zernio_account?(%{provider: provider}),
    do: provider == "zernio" or (is_nil(provider) and zernio_configured?())

  defp zernio_configured?, do: Publisher.impl() == Platform.Social.Publisher.Zernio

  def provider_filter do
    untagged_zernio? = zernio_configured?()

    dynamic(
      [analytics_account: account],
      account.provider == "zernio" or (is_nil(account.provider) and ^untagged_zernio?)
    )
  end
end
