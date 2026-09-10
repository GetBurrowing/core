defmodule Platform.TelemetryHelpers do
  @moduledoc """
  Test helpers for the `:telemetry` handlers that `Platform.Application`
  attaches once at boot (`application.ex:12-27`).

  ## Why this module exists

  Those handlers are **VM-global**: `:telemetry` keys them by a fixed
  `@handler_id` in ETS, not per-process and not per-test. A test that
  detaches one and does not put it back leaves every later test in the
  same BEAM running with that bridge silently missing — and the symptom
  is not an error, it is an audit assertion that passes because nothing
  is listening. Task 019f9d80 traced exactly that: five test files
  detached a boot-attached handler and never restored it, which made
  `Platform.Accounts.ExternalAdmissionNotifierTest`'s durable-queue
  assertion fail 10/10 whenever `Platform.Audit.HistorianLatencyTest`
  was scheduled ahead of it, and that failure was written off as a flake
  across roughly eight briefs.

  ## Why calling `attach/0` is the whole restore

  Every boot-attached handler's `attach/0` is the single definition of
  its handler id, its event list, and its config. Restoring by calling
  that same function therefore cannot install the handler under a
  different configuration than boot installed — the "restored with drifted
  config" failure mode does not exist by construction. And since task
  019f9d80 stage 2 every `attach/0` is idempotent, so calling it when the
  handler is already attached is a no-op rather than an error.

  ## Why the `on_exit` is unconditional

  It runs whether or not the test detached anything, and whether or not
  the test passed. That is the point: it also covers a test that detaches
  **mid-body** to exercise the lifecycle (see
  `test/platform/meetings/telemetry_handler_test.exs`), where a failure
  between the detach and the manual re-attach would otherwise leak a
  detached global handler for the remainder of the run. The
  copy-pasted `on_exit(fn -> detach(); attach() end)` idiom this replaces
  does not cover that case, and having five independent copies of it with
  no enforcement is how the five offenders drifted off it in the first
  place.

      setup do
        Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)
        :ok
      end

  ## Scoped forwarders: why the discriminator is mandatory

  The second hazard is the mirror image of the first. A test that attaches
  its own handler to forward an event into its mailbox is also VM-global:
  the handler fires for **every** emission of that event in the BEAM,
  including those from sibling `async: true` modules running at the same
  moment. An unfiltered forwarder plus a `refute_receive` on the forwarded
  shape is therefore a false red waiting for the scheduler — CI showed it
  in `StackTest` (a sibling's `status_regression_blocked`) and twice in
  `GithubWebhookDeliveredButOpenTest` (a `task_id` the test never
  created), with six more files of the same shape found by inventory
  (task 01a08b5f).

  `attach_scoped/4` closes that by refusing to forward without a
  discriminator:

    * `{key, value}` — forward when `metadata[key] == value` (the per-test
      id the test created: `{:stack_id, stack.id}`, `{:task_id, task.id}`).
    * a `fun/1` over the metadata — for anything a key/value cannot express.
    * `:caller` — forward when the emitting process is the test process or
      has it in `$callers` (`Task`/`Task.Supervisor` children inherit it; a
      bare `spawn` does not). This is for events like
      `[:platform, :responsibility, :fired]` whose metadata carries no
      per-test id at all, so the only thing that distinguishes "mine" from
      "a sibling's" is the process that emitted it.

  A discriminator fun that raises is NOT allowed to fail silently:
  `:telemetry` would otherwise detach the handler on the first exception
  and every later assertion in the test would pass by absence — the exact
  class of bug this module exists to stop. The exception is forwarded as
  `{tag, :discriminator_raised, event, exception}` so the next
  `assert_receive` fails loudly, and the handler stays attached.

  ## `on_exit` and the detach

  The detach is registered with `ExUnit.Callbacks.on_exit/1` immediately
  after a successful attach, unconditionally, and tolerates a handler that
  is already gone. `attach_scoped/4` must therefore be called from the
  test process or a `setup` block (ExUnit's `on_exit` requirement — the
  same one `ensure_boot_handler!/1` has). ExUnit runs `on_exit` callbacks
  in reverse registration order (LIFO): a callback registered BEFORE the
  attach runs AFTER the helper's detach, which is how the helper's own
  test observes that the handler is gone.

      test "only my stack's regression is forwarded", %{stack: stack} do
        Platform.TelemetryHelpers.attach_scoped(
          [:platform, :stacks, :status_regression_blocked],
          {:stack_id, stack.id},
          self(),
          tag: :regression_blocked
        )

        # ...
        assert_receive {:regression_blocked, _event, %{count: 1}, %{stack_id: ^stack_id}}
      end
  """

  @scoped_prefix "telemetry-helpers-scoped-"

  @typedoc """
  What must hold for an emission to be forwarded to the test process.
  """
  @type discriminator ::
          {key :: atom(), value :: term()}
          | (metadata :: map() -> boolean())
          | :caller

  @doc """
  Ensure `module` — a boot-attached telemetry handler — is attached for
  this test, and re-attach it unconditionally when the test exits.

  Raises if `module` does not export `attach/0`, which is the contract a
  boot-attached handler satisfies.
  """
  @spec ensure_boot_handler!(module()) :: :ok
  def ensure_boot_handler!(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    unless function_exported?(module, :attach, 0) do
      raise ArgumentError,
            "#{inspect(module)} does not export attach/0 — " <>
              "ensure_boot_handler!/1 takes a boot-attached telemetry handler module"
    end

    :ok = module.attach()
    ExUnit.Callbacks.on_exit(fn -> :ok = module.attach() end)

    :ok
  end

  @doc """
  The literal prefix every `attach_scoped/4` handler id starts with.

  Public contract: a leak check can grep `:telemetry.list_handlers([])`
  for it after a run.
  """
  @spec scoped_prefix() :: String.t()
  def scoped_prefix, do: @scoped_prefix

  @doc """
  Attach a test-scoped forwarder for `events` that sends
  `{tag, event, measurements, metadata}` to `pid` only when
  `discriminator` matches (see the moduledoc), and detach it
  unconditionally when the calling test exits.

  Must be called from the test process or a `setup` block. Returns the
  handler id.

  Options:

    * `:tag` — first element of the forwarded tuple (default `:telemetry`).
  """
  @spec attach_scoped(
          :telemetry.event_name() | [:telemetry.event_name()],
          discriminator(),
          pid(),
          keyword()
        ) :: String.t()
  def attach_scoped(events, discriminator, pid, opts \\ [])
      when is_pid(pid) and is_list(opts) do
    validate_discriminator!(discriminator)

    id = @scoped_prefix <> "#{inspect(pid)}-#{System.unique_integer([:positive])}"
    tag = Keyword.get(opts, :tag, :telemetry)
    config = %{pid: pid, discriminator: discriminator, tag: tag}

    :ok = :telemetry.attach_many(id, event_list(events), &__MODULE__.handle_scoped/4, config)

    ExUnit.Callbacks.on_exit(fn ->
      case :telemetry.detach(id) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    end)

    id
  end

  # A single event name is itself a list of atoms, so `List.wrap/1` would
  # hand `attach_many/4` one "event" per atom. Wrap by shape instead.
  defp event_list([atom | _] = event) when is_atom(atom), do: [event]
  defp event_list(events) when is_list(events), do: events

  defp validate_discriminator!({key, _value}) when is_atom(key), do: :ok
  defp validate_discriminator!(fun) when is_function(fun, 1), do: :ok
  defp validate_discriminator!(:caller), do: :ok

  defp validate_discriminator!(other) do
    raise ArgumentError,
          "attach_scoped/4 discriminator must be {key, value}, a fun/1 over the " <>
            "metadata, or :caller — got #{inspect(other)}"
  end

  @doc false
  # Public so the captured `&__MODULE__.handle_scoped/4` is an external fun:
  # telemetry warns about (and is slower with) local/anonymous handlers.
  def handle_scoped(event, measurements, metadata, %{pid: pid, discriminator: d, tag: tag}) do
    case matches?(d, metadata, pid) do
      true -> send(pid, {tag, event, measurements, metadata})
      false -> :ok
      {:raised, exception} -> send(pid, {tag, :discriminator_raised, event, exception})
    end

    :ok
  end

  defp matches?({key, value}, metadata, _pid), do: Map.get(metadata, key) == value

  defp matches?(:caller, _metadata, pid),
    do: self() == pid or pid in Process.get(:"$callers", [])

  defp matches?(fun, metadata, _pid) when is_function(fun, 1) do
    fun.(metadata) == true
  rescue
    exception -> {:raised, exception}
  end
end
