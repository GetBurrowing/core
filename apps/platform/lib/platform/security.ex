defmodule Platform.Security do
  @moduledoc """
  Context module for the security-guard responsibility bundle
  (task `019f3e8e-4406`, ADR-0043).

  The security bundle is four `security.*` responsibility keys owned
  by the `security_guard` role:

    * `security.cve_scan` — lockfile scan → OSV.dev query (stage 3)
    * `security.code_audit` — source-tree pattern rubric (stage 4)
    * `security.deploy_audit` — Traefik / .container / env-diff (stage 4)
    * `security.secret_leak` — working-tree + git-log secret scan (stage 5)

  All four are driven by `Platform.Security.Sweeper` — a periodic
  GenServer that walks the responsibility rows on a fixed check
  interval, resolves each key's cadence from its metadata, and
  invokes the matching scanner module. The Router never fires these
  rows (they register a null `event_topic`; see ADR-0043 §Rationale).

  ## Progressive-enhancement contract

  If no agent is assigned to the `security_guard` role, the Sweeper
  tick emits `[:platform, :responsibility, :unfilled]` telemetry per
  key and returns. No scanner runs. No task is filed. No DB write
  happens. This is the load-bearing contract for stage 2 — the
  runtime plumbing exists but stays dormant until an operator flips
  the role in Control Center → Roles.

  ## Public API

  This module is deliberately thin — it delegates the runtime work
  to `Platform.Security.Sweeper` and `Platform.Security.FindingFiler`
  and only exposes the small surface tests + IEx sessions need to
  drive them.
  """

  alias Platform.Security.Sweeper

  @responsibility_keys ~w(
    security.cve_scan
    security.code_audit
    security.deploy_audit
    security.secret_leak
  )

  @doc """
  Canonical list of `security.*` responsibility keys, ordered the way
  the Sweeper walks them each tick.

  The order matches `Platform.Responsibilities.Handlers.Security*` and
  the ADR-0043 roster — cve → code → deploy → secret. Callers should
  not depend on the order for correctness; it exists so telemetry
  timelines read left-to-right in the order operators expect.
  """
  @spec list_responsibility_keys() :: [String.t()]
  def list_responsibility_keys, do: @responsibility_keys

  @doc """
  Force a Sweeper tick to run synchronously. Test seam + the IEx
  handle a review-agent uses to drive the e2e_behavior contract
  without waiting for the default 1-hour cadence.

  Returns `{:ok, results}` where `results` is a list of
  `%{key, assigned?, findings_filed}` — one entry per responsibility
  key the Sweeper walked. When no default Sweeper is running,
  returns `{:error, :sweeper_not_started}`.
  """
  @spec sweep_now() :: {:ok, [map()]} | {:error, :sweeper_not_started}
  def sweep_now, do: Sweeper.sweep_now()
end
