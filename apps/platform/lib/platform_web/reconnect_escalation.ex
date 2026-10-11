defmodule PlatformWeb.ReconnectEscalation do
  @moduledoc """
  Runtime thresholds for the quiet-reconnect escalation (task 01a12b10).

  The client shows a quiet "Reconnecting…" state for a dropped LiveView
  connection and raises the red `#client-error` / `#server-error` toast only
  after `attempts` failed reconnect attempts or `seconds` seconds, whichever
  comes first (`assets/js/lib/reconnect_escalation.js`, whose doc comment
  carries the Phoenix backoff table behind the 11/10 defaults).

  The values come from `RECONNECT_ESCALATE_ATTEMPTS` /
  `RECONNECT_ESCALATE_SECONDS` via `config/runtime.exs` into
  `config :platform, :reconnect_escalation`, and reach the browser through
  `<meta name="reconnect-escalation">` in the root layout. `config/0` reads
  the application env on every call (no compile-time capture), so the next
  full page load sees a changed value.

  The defaults and clamps here are the same as the JS `parseThresholds/1`:
  missing, non-integer, zero or negative values fall back to 11/10; attempts
  is clamped to 1..100 and seconds to 1..300. Keep the two in step.
  """

  @default_attempts 11
  @default_seconds 10
  @max_attempts 100
  @max_seconds 300

  @doc "The defaults, `%{attempts: 11, seconds: 10}`."
  @spec defaults() :: %{attempts: pos_integer(), seconds: pos_integer()}
  def defaults, do: %{attempts: @default_attempts, seconds: @default_seconds}

  @doc "The current thresholds, read from the application env per call."
  @spec config() :: %{attempts: pos_integer(), seconds: pos_integer()}
  def config do
    env = Application.get_env(:platform, :reconnect_escalation, [])
    env = if Keyword.keyword?(env), do: env, else: []

    %{
      attempts: threshold(Keyword.get(env, :attempts), @default_attempts, @max_attempts),
      seconds: threshold(Keyword.get(env, :seconds), @default_seconds, @max_seconds)
    }
  end

  defp threshold(n, _default, max) when is_integer(n) and n > 0, do: min(n, max)
  defp threshold(_, default, _max), do: default
end
