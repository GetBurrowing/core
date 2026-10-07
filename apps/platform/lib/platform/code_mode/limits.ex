defmodule Platform.CodeMode.Limits do
  @moduledoc """
  The resource limits of one `suite_run` (task 01a114a8 stage 2).

  Every value is configurable in app env under `config :platform,
  Platform.CodeMode, [...]`; `get/0` merges that over the defaults below and
  clamps what a caller may ask for.

    * `:wall_ms` (10 s) and `:max_wall_ms` (30 s): the wall-clock bound. A
      `suite_run` may ask for a different `timeout_ms`, clamped to
      `1..max_wall_ms`. Enforced natively: Wasmex interrupts the call at its
      deadline through wasmtime epoch interruption.
    * `:fuel_per_ms`: wasm fuel granted per millisecond of wall budget. Fuel
      counts executed wasm instructions, so it bounds CPU independently of
      the wall clock (a run that waits in host calls burns no fuel). Sized
      so a pure CPU loop exhausts its fuel at roughly the wall limit.
      Measured on moon (x86_64, wasmtime 47 via Wasmex 0.15.1, cranelift
      `:speed`): 1e10 fuel in about 430 ms, i.e. about 2.3e7 per ms, and an
      empty JS `for` iteration costs about 510 fuel. 1.5e7 per ms puts a
      10 s budget's fuel at about 6.5 to 7.5 s of CPU there; a slower host reaches
      the wall limit first, which is also a bound.
    * `:memory_bytes` (64 MB): `Wasmex.StoreLimits{memory_size}`, the cap on
      the instance's linear memory. QuickJS gets no internal limit of its
      own, so this is the single memory bound (and is mutation-tested).
    * `:max_calls` (50): inner tool calls per run. Store operations are
      counted separately against `:max_store_ops` (1000).
    * `:max_result_bytes`: the script's JSON result, defaulting to
      `ResultBound.max_result_bytes/0`, the same cap the MCP transport fits
      every result to.
    * `:inner_result_bytes` (1 MB): each inner call's JSON result as the
      script sees it. Past that the call fails recoverably.
    * `:log_bytes` (8 KB): `console.log` output kept per run.
    * `:per_runtime_concurrency` (2) and `:global_concurrency` (8).
    * Store: `:store_ttl_ms` (30 min), `:store_max_ttl_ms` (6 h),
      `:store_value_bytes` (256 KB), `:store_agent_bytes` (4 MB).
  """

  alias Platform.Federation.ResultBound

  @defaults %{
    wall_ms: 10_000,
    max_wall_ms: 30_000,
    fuel_per_ms: 15_000_000,
    memory_bytes: 64 * 1024 * 1024,
    max_calls: 50,
    max_store_ops: 1_000,
    inner_result_bytes: 1_048_576,
    log_bytes: 8_192,
    per_runtime_concurrency: 2,
    global_concurrency: 8,
    store_ttl_ms: 30 * 60 * 1000,
    store_max_ttl_ms: 6 * 60 * 60 * 1000,
    store_value_bytes: 256 * 1024,
    store_agent_bytes: 4 * 1024 * 1024
  }

  @type t :: %{atom() => non_neg_integer()}

  @doc "The defaults, before app env."
  @spec defaults() :: t()
  def defaults, do: Map.put(@defaults, :max_result_bytes, ResultBound.max_result_bytes())

  @doc "The effective limits: app env over the defaults."
  @spec get() :: t()
  def get do
    overrides =
      :platform
      |> Application.get_env(Platform.CodeMode, [])
      |> Map.new()
      |> Map.take(Map.keys(defaults()))

    Map.merge(defaults(), overrides)
  end

  @doc """
  The wall budget for a run that asked for `requested` milliseconds (or nil
  for the default), clamped to `1..max_wall_ms`.
  """
  @spec wall_ms(t(), term()) :: pos_integer()
  def wall_ms(limits, requested) when is_integer(requested),
    do: requested |> max(1) |> min(limits.max_wall_ms)

  def wall_ms(limits, _requested), do: min(limits.wall_ms, limits.max_wall_ms)

  @doc "The fuel granted to a run with `wall_ms` of wall budget."
  @spec fuel(t(), pos_integer()) :: pos_integer()
  def fuel(limits, wall_ms), do: max(limits.fuel_per_ms * wall_ms, 1)
end
