defmodule Platform.Social.RuntimeConfig do
  @moduledoc """
  Social's runtime settings, read from the OS environment at boot by
  `Platform.Social.Application.start/2` (ADR 0055 section 8, task 01a14722).

  Not a `config/runtime.exs` block: the prod image is `apps/suite_release`,
  whose release runs core's `config/runtime.exs`, and core never names
  Social. A module reads its own env in its own `Application.start/2`, the
  way Play does (`Platform.GameStream.RuntimeConfig`).

  ## `SOCIAL_PUBLISHER`

  `zernio` (trimmed, case-insensitive) selects
  `Platform.Social.Publisher.Zernio` as `config :social, :publisher`.
  Unset or empty touches nothing: prod stays
  `{:error, :publisher_not_configured}` and dev/test keep the Fake that
  `config/config.exs` selects. Any other value touches nothing and logs a
  warning naming the value.

  ## `SOCIAL_ZERNIO_BASE_URL`

  Optional. Merged into `config :social, Platform.Social.Publisher.Zernio,
  base_url:`. Unset leaves the adapter's default.

  ## The key

  No env var holds the Zernio key, and nothing here reads one. The key lives
  only in the Vault (`Platform.Social.Secrets`).
  """

  require Logger

  @zernio Platform.Social.Publisher.Zernio

  @doc """
  The settings `env` (an OS-environment map, `System.get_env/0`'s shape)
  describes. Pure. `:publisher` is `{:ok, module}`, `:unset` or
  `{:unknown, value}`; `:zernio_base_url` is a string or `nil`.
  """
  @spec read(%{optional(String.t()) => String.t()}) :: keyword()
  def read(env) when is_map(env) do
    [
      publisher: publisher(Map.get(env, "SOCIAL_PUBLISHER")),
      zernio_base_url: base_url(Map.get(env, "SOCIAL_ZERNIO_BASE_URL"))
    ]
  end

  @doc "Reads `env` and puts what it selects in the `:social` app env."
  @spec apply(%{optional(String.t()) => String.t()}) :: :ok
  def apply(env) do
    settings = read(env)

    case Keyword.fetch!(settings, :publisher) do
      {:ok, module} ->
        Application.put_env(:social, :publisher, module)

      :unset ->
        :ok

      {:unknown, value} ->
        Logger.warning(
          "[social] SOCIAL_PUBLISHER=#{inspect(value)} is not a known publisher " <>
            "(known: \"zernio\"); the publisher is left as configured"
        )
    end

    case Keyword.fetch!(settings, :zernio_base_url) do
      nil ->
        :ok

      url ->
        current = Application.get_env(:social, @zernio, [])
        Application.put_env(:social, @zernio, Keyword.put(current, :base_url, url))
    end

    :ok
  end

  defp publisher(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> :unset
      "zernio" -> {:ok, @zernio}
      _ -> {:unknown, value}
    end
  end

  defp publisher(_), do: :unset

  defp base_url(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      url -> url
    end
  end

  defp base_url(_), do: nil
end
