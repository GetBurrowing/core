defmodule Platform.Config do
  @moduledoc """
  Boot-time configuration validation.

  Raises at startup in production if any required environment variable is
  missing, so misconfigured deploys fail immediately rather than at the
  first request that hits the missing value.
  """

  @required_in_prod ~w(
    DATABASE_URL
    SECRET_KEY_BASE
    OIDC_ISSUER
    OIDC_CLIENT_ID
    OIDC_CLIENT_SECRET
    APP_URL
  )

  @doc """
  Validates required environment variables. Raises with a clear message
  for each missing variable. No-ops outside of production.
  """
  def validate! do
    if Application.get_env(:platform, :env) == :prod do
      missing =
        @required_in_prod
        |> Enum.reject(&System.get_env/1)

      unless missing == [] do
        vars = Enum.map_join(missing, "\n", &"  - #{&1}")

        raise """
        Missing required environment variables:
        #{vars}

        Set these before starting the application.
        """
      end
    end

    :ok
  end
end
