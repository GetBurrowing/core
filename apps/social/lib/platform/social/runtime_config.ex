defmodule Platform.Social.RuntimeConfig do
  @moduledoc """
  Social's runtime settings, read from the OS environment at boot by
  `Platform.Social.Application.start/2` (ADR 0055 section 8, task 01a14722).

  Not a `config/runtime.exs` block: the prod image is `apps/burrow_release`,
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

  ## `SOCIAL_YOUTUBE_PUBLICATIONS_ENABLED`

  Installation-wide opt-in for publication-list work only. Trimmed,
  case-insensitive `true` enables it; every other value, including unset,
  disables it on startup. Other analytics and persisted progress are untouched.
  Operators must persist changes in the installation environment; changing
  application env alone lasts only until the next restart.

  ## The key

  No env var holds the Zernio key, and nothing here reads one. The key lives
  only in the Vault (`Platform.Social.Secrets`).

  ## Trends (`config :social, :trends` and `:trends_wikimedia`)

  Read by `Platform.Social.Trends.Refresher`, which fetches only when
  `enabled` is true, `source` is `"wikimedia_pageviews"` and a contact is set,
  and only while some profile has Studio on. Each value below is merged into
  the existing keyword list; unset or empty touches nothing, so Trends stays
  off. A `SOCIAL_TRENDS_ENABLED` or `SOCIAL_TRENDS_SOURCE` value that is not
  understood switches fetching off (`enabled: false` or `source: nil`), even
  over an earlier setting, and logs a warning; any other value that is not
  understood touches nothing and logs a warning.

    * `SOCIAL_TRENDS_ENABLED`: `true` (trimmed, case-insensitive) sets
      `enabled: true`; `false`, or any other non-empty value, sets
      `enabled: false`.
    * `SOCIAL_TRENDS_SOURCE`: exactly `wikimedia_pageviews` (trimmed) sets
      `source`. Any other non-empty value, Hacker News included, sets
      `source: nil`.
    * `SOCIAL_TRENDS_REFRESH_INTERVAL_MS`: a positive integer sets
      `refresh_interval_ms` (the refresher never waits less than 15 minutes).
    * `SOCIAL_TRENDS_WIKIMEDIA_CONTACT`: the operator contact sent in the
      Wikimedia User-Agent, as `:trends_wikimedia, contact:`. Never logged.
      There is no default; without it the refresher refuses to fetch.
  """

  require Logger

  @zernio Platform.Social.Publisher.Zernio
  @trends_sources ["wikimedia_pageviews"]

  @doc """
  The settings `env` (an OS-environment map, `System.get_env/0`'s shape)
  describes. Pure. `:publisher` is `{:ok, module}`, `:unset` or
  `{:unknown, value}`; `:zernio_base_url` is a string or `nil`.
  """
  @spec read(%{optional(String.t()) => String.t()}) :: keyword()
  def read(env) when is_map(env) do
    [
      publisher: publisher(Map.get(env, "SOCIAL_PUBLISHER")),
      zernio_base_url: trimmed_or_nil(Map.get(env, "SOCIAL_ZERNIO_BASE_URL")),
      trends_enabled: trends_enabled(Map.get(env, "SOCIAL_TRENDS_ENABLED")),
      trends_source: trends_source(Map.get(env, "SOCIAL_TRENDS_SOURCE")),
      trends_refresh_interval_ms: positive_int(Map.get(env, "SOCIAL_TRENDS_REFRESH_INTERVAL_MS")),
      trends_wikimedia_contact: trimmed_or_nil(Map.get(env, "SOCIAL_TRENDS_WIKIMEDIA_CONTACT"))
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

    publication_setting =
      env
      |> Map.get("SOCIAL_YOUTUBE_PUBLICATIONS_ENABLED", "")
      |> String.trim()
      |> String.downcase()

    Application.put_env(:social, :youtube_publications_enabled, publication_setting == "true")

    if publication_setting not in ["", "true", "false"] do
      Logger.warning(
        "[social] SOCIAL_YOUTUBE_PUBLICATIONS_ENABLED is invalid; publication list work is disabled"
      )
    end

    apply_trends(settings)
    :ok
  end

  defp apply_trends(settings) do
    # Fail closed: an explicit value that is not understood switches fetching
    # off (enabled: false, source: nil) instead of keeping an earlier setting.
    put_setting(:trends, :enabled, "SOCIAL_TRENDS_ENABLED", settings[:trends_enabled],
      fail_closed: false
    )

    put_setting(:trends, :source, "SOCIAL_TRENDS_SOURCE", settings[:trends_source],
      fail_closed: nil
    )

    put_setting(
      :trends,
      :refresh_interval_ms,
      "SOCIAL_TRENDS_REFRESH_INTERVAL_MS",
      settings[:trends_refresh_interval_ms]
    )

    case settings[:trends_wikimedia_contact] do
      nil -> :ok
      contact -> merge_env(:trends_wikimedia, :contact, contact)
    end
  end

  defp put_setting(app_key, key, name, setting, opts \\ [])

  defp put_setting(_app_key, _key, _name, :unset, _opts), do: :ok

  defp put_setting(app_key, key, _name, {:ok, value}, _opts),
    do: merge_env(app_key, key, value)

  defp put_setting(app_key, key, name, {:unknown, value}, opts) do
    case Keyword.fetch(opts, :fail_closed) do
      {:ok, closed} ->
        Logger.warning(
          "[social] #{name}=#{inspect(value)} is not understood; Trends fetching is switched off"
        )

        merge_env(app_key, key, closed)

      :error ->
        Logger.warning("[social] #{name}=#{inspect(value)} is not understood; left as configured")
    end
  end

  defp merge_env(app_key, key, value) do
    current = Application.get_env(:social, app_key, [])
    Application.put_env(:social, app_key, Keyword.put(current, key, value))
  end

  defp trends_enabled(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> :unset
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:unknown, value}
    end
  end

  defp trends_enabled(_), do: :unset

  defp trends_source(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :unset
      source when source in @trends_sources -> {:ok, source}
      _ -> {:unknown, value}
    end
  end

  defp trends_source(_), do: :unset

  defp positive_int(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        :unset

      trimmed ->
        case Integer.parse(trimmed) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:unknown, value}
        end
    end
  end

  defp positive_int(_), do: :unset

  defp publisher(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> :unset
      "zernio" -> {:ok, @zernio}
      _ -> {:unknown, value}
    end
  end

  defp publisher(_), do: :unset

  defp trimmed_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      url -> url
    end
  end

  defp trimmed_or_nil(_), do: nil
end
