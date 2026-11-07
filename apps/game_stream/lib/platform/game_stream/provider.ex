defmodule Platform.GameStream.Provider do
  @moduledoc "Play runtime provider contract. Native builds are immutable; no build-on-Play."
  @callback start(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  @callback status(map()) :: :ok | {:error, term()}
  @callback stop(map(), String.t()) :: :ok | {:error, term()}
  @callback reconcile(String.t()) :: :ok | {:error, term()}
  def native,
    do: Application.get_env(:game_stream, :native_provider, Platform.GameStream.Providers.Native)
end
