defmodule Platform.SignInAdmin.EmailLoginCodeBoot do
  @moduledoc """
  Turns on pocket-id's unauthenticated email login code
  (`emailOneTimeAccessAsUnauthenticatedEnabled`) on an install that already
  exists, ONCE per install (task 01a1e65e stage 2).

  ## Why at boot, in core

  The updater only swaps the core image digest and holds no pocket-id key,
  and it is rendered once per install, so an existing install would never
  receive a new updater step. Core already holds `POCKET_ID_ADMIN_URL` and
  `POCKET_ID_API_KEY` wherever the installer turned the sign-in admin on, and
  every auto-update reboots core. An install where
  `Platform.SignInAdmin.Config.enabled?/0` is false cannot use the email-code
  sign-in path either (`Platform.SignIn.EmailSetup.enabled?/0` requires it),
  so it is skipped without a request.

  ## Once per install, never forced

  The step turns the flag on; it does not keep it on. After
  `PocketId.ensure_email_login_code/0` answers `{:ok, :enabled}` or
  `{:ok, :present}`, the step writes the `:pocket_id_email_login_code` marker
  (`Platform.Install.BootMarkers`). Every later boot sees the marker and sends
  no request at all, so an admin who turns email login codes off in pocket-id
  keeps them off across updates. That is what keeps the installer's
  `LOGIN_TTL` rationale ("an admin can still turn the flag off") true. Any
  error leaves the marker unset, so the next boot tries again.

  ## Retries

  pocket-id may still be starting when core boots, so `run/1` retries only on
  `{:error, :transport}` and `{:error, {:http, status}}` with status >= 500.
  401, 403, `:config_locked`, `:not_saved`, `:bad_response` and
  `:not_configured` are answers, not outages, and are never retried.

  ## One line per boot

  `run_at_boot/0` logs exactly one summary line, built from atoms and
  integers only:

      pocket_id.email_login_code result=skipped
      pocket_id.email_login_code result=present
      pocket_id.email_login_code result=enabled
      pocket_id.email_login_code result=failed reason=transport

  The per-request `pocket_id.request ...` lines from `PocketId` are separate.
  It rescues and catches everything and always returns `:ok`, so boot never
  fails on it; `Platform.Application` starts it as an async `Task`, so boot
  never waits on it either.
  """

  require Logger

  alias Platform.Install.BootMarkers
  alias Platform.SignInAdmin.Config
  alias Platform.SignInAdmin.PocketId

  @marker :pocket_id_email_login_code
  @default_attempts 6
  @default_delay_ms 10_000

  @doc """
  Calls `PocketId.ensure_email_login_code/0`, retrying on transport errors
  and 5xx only. `opts`: `attempts` (default 6) and `delay_ms` between
  attempts (default 10_000). Returns the last result. Does not read or write
  the marker.
  """
  @spec run(keyword()) :: {:ok, :present | :enabled} | PocketId.error()
  def run(opts \\ []) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)
    delay_ms = Keyword.get(opts, :delay_ms, @default_delay_ms)
    attempt(attempts, delay_ms)
  end

  defp attempt(left, delay_ms) do
    result = PocketId.ensure_email_login_code()

    if left > 1 and retryable?(result) do
      Process.sleep(delay_ms)
      attempt(left - 1, delay_ms)
    else
      result
    end
  end

  defp retryable?({:error, :transport}), do: true
  defp retryable?({:error, {:http, status}}) when is_integer(status) and status >= 500, do: true
  defp retryable?(_), do: false

  @doc """
  The supervised boot entry point. Returns `:ok` for every outcome. `opts`
  go to `run/1`.
  """
  @spec run_at_boot(keyword()) :: :ok
  def run_at_boot(opts \\ []) do
    if Config.enabled?() do
      opts |> outcome() |> log_summary()
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp outcome(opts) do
    if BootMarkers.set?(@marker) do
      :skipped
    else
      case run(opts) do
        {:ok, result} when result in [:present, :enabled] -> mark(result)
        {:error, reason} -> {:failed, reason}
      end
    end
  rescue
    _ -> {:failed, :exception}
  catch
    _, _ -> {:failed, :exception}
  end

  defp mark(result) do
    case BootMarkers.put(@marker) do
      :ok -> result
      {:error, _} -> {:failed, :marker_not_saved}
    end
  end

  defp log_summary({:failed, reason}),
    do: Logger.warning("pocket_id.email_login_code result=failed reason=#{reason_text(reason)}")

  defp log_summary(result) when result in [:skipped, :present, :enabled],
    do: Logger.info("pocket_id.email_login_code result=#{result}")

  defp reason_text({:http, status}) when is_integer(status), do: "http_#{status}"
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(_), do: "unknown"
end
