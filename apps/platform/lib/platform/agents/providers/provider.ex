defmodule Platform.Agents.Providers.Provider do
  @moduledoc """
  Behaviour for model provider adapters used by the Agent Runtime.

  Providers encapsulate provider-specific authentication, request formatting,
  response normalization, and model catalog metadata. Router/fallback logic
  arrives in a later task; this behaviour defines the common contract the
  Router will call.
  """

  @type credentials :: String.t() | map()
  @type message :: %{required(String.t()) => term()} | %{required(atom()) => term()}
  @type response :: map()
  @type model_info :: map()

  @callback chat(credentials(), [message()], keyword()) :: {:ok, response()} | {:error, term()}
  @callback stream(credentials(), [message()], keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
  @callback models(credentials()) :: {:ok, [model_info()]} | {:error, term()}
  @callback validate_credentials(credentials()) :: :ok | {:error, term()}
end
