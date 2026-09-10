defmodule Platform.Telemetry.HandlerGuardianTest do
  @moduledoc """
  Task 01a08b49 stage 1.

  ## Why the failure is forced, not raced

  The condition in the field is a supervised write already enqueued in
  `DBConnection` when the sandbox owner exits, which arrives as a process exit
  and makes `:telemetry` detach `"platform-audit-telemetry"` VM-wide. That is
  timing-dependent — task 01a089ee measured it at 10 detaches out of 10
  attempts for the queued shape, but reproducing it here would mean racing a
  connection teardown on every run.

  So these cases produce the *same* input to the guardian by a deterministic
  route: install a handler that calls `exit/1` under the real handler's id and
  event list, emit, and read `:telemetry.list_handlers/1`. `:telemetry`'s catch
  is `T:R:S` with no class filter (`deps/telemetry/src/telemetry.hrl`), so an
  `exit` from a stub and an `exit` from a torn-down `DBConnection` reach
  `do_execute/4`'s catch identically. What the guardian sees is a
  `[:telemetry, :handler, :failure]` event with `kind: :exit`, which is exactly
  what the real shape produces.

  ## Why every assertion is on `:telemetry.list_handlers/1`

  Never on downstream audit-row counts. "Expected one audit row, got none"
  measures the amplifier one step removed from the defect and reads as N
  independent failures rather than one detach — which is the whole reason this
  bug was misdiagnosed for as long as it was.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Platform.Telemetry.HandlerGuardian

  @audit_id "platform-audit-telemetry"
  @audit_module Platform.Audit.TelemetryHandler
  @login_event [:platform, :auth, :login]
  @failure_event [:telemetry, :handler, :failure]

  # A test-owned id and a test-owned event, so the negative control cannot
  # collide with a real handler or a real emitter.
  #
  # NOTE: the stage brief specified `Platform.TelemetryHelpers.scoped_prefix()
  # <> "guardian-negative"` here. That function is NOT on `main` at the base of
  # this branch (`6a11f37a`) — it lives on the unmerged
  # `task/01a08b5f-9d25-...`, where only `ensure_boot_handler!/1` has landed on
  # main. A literal is used instead. The property the case needs is only that
  # the id is absent from `HandlerGuardian.boot_handlers/0`, and that is
  # asserted below rather than assumed.
  @negative_id "platform-test-guardian-negative-control"
  @negative_event [:platform, :test, :guardian_negative_control]

  setup do
    # Attaches now and re-attaches unconditionally in `on_exit`, so no case in
    # this file can leak a detached audit handler into the rest of the run —
    # including a case that fails between its detach and its restore.
    Platform.TelemetryHelpers.ensure_boot_handler!(@audit_module)
    :ok = HandlerGuardian.attach()
    :ok = HandlerGuardian.reset_restore_counts()

    # Captured while the real handler is known-attached, because a case that
    # drives past the bound leaves it detached and can no longer read its
    # event list back off `list_handlers/1`.
    audit_events = handler_event_names(@audit_id)

    refute audit_events == [],
           "the audit handler must be attached for these cases to mean anything"

    on_exit(fn ->
      :telemetry.detach(@negative_id)
      HandlerGuardian.reset_restore_counts()
      HandlerGuardian.attach()
    end)

    {:ok, audit_events: audit_events}
  end

  describe "restoring a guarded boot handler that failed" do
    test "the real handler function is back after an exiting emission", %{
      audit_events: audit_events
    } do
      assert find_handler(@login_event, @audit_id).function ==
               (&@audit_module.handle_event/4)

      install_exiting_stub!(@audit_id, audit_events)

      # Non-vacuity: the thing that is about to fail is the stub, not the real
      # handler. Without this the case could pass having never replaced
      # anything.
      assert find_handler(@login_event, @audit_id).function ==
               (&__MODULE__.exiting_handler/4)

      log = capture_log(fn -> :telemetry.execute(@login_event, %{}, %{}) end)

      restored = find_handler(@login_event, @audit_id)

      assert restored,
             "#{@audit_id} should have been re-attached by the guardian, but no handler " <>
               "with that id is attached to #{inspect(@login_event)}"

      # Assert on the FUNCTION, not the id. A guardian that simply re-attached
      # the stub it just saw fail would satisfy an id-only check, restore
      # nothing useful, and loop forever.
      assert restored.function == (&@audit_module.handle_event/4)
      refute restored.function == (&__MODULE__.exiting_handler/4)

      # The restore is announced, and it is honest about the row being gone.
      assert log =~ "[HandlerGuardian]"
      assert log =~ "is LOST"
      assert log =~ ":exit"
    end

    test "the restore is complete before :telemetry.execute/3 returns", %{
      audit_events: audit_events
    } do
      install_exiting_stub!(@audit_id, audit_events)

      assert find_handler(@login_event, @audit_id).function ==
               (&__MODULE__.exiting_handler/4)

      # The strongest claim this stage makes: a handler on
      # [:telemetry, :handler, :failure] re-attaches the casualty BEFORE
      # execute/3 returns to the emitter. `:telemetry` detaches first, then
      # emits the failure event synchronously on the emitter's own stack
      # (deps/telemetry/src/telemetry.erl do_execute/4), so the read below
      # needs no sleep and must not be given one — a sleep would make this
      # case pass against an asynchronous restore, and stage 3 depends on the
      # synchronous guarantee.
      {handlers, _log} =
        with_log(fn ->
          :telemetry.execute(@login_event, %{}, %{})
          :telemetry.list_handlers(@login_event)
        end)

      restored = Enum.find(handlers, &(&1.id == @audit_id))

      assert restored,
             "the guardian restored #{@audit_id} too late: it was still detached on the " <>
               "expression immediately after :telemetry.execute/3 returned"

      assert restored.function == (&@audit_module.handle_event/4)
    end
  end

  describe "handler ids the guardian does not guard" do
    test "an exiting test-owned handler is left detached and the guardian says nothing" do
      # Premise, asserted rather than assumed.
      refute Map.has_key?(HandlerGuardian.boot_handlers(), @negative_id)

      :ok =
        :telemetry.attach(
          @negative_id,
          @negative_event,
          &__MODULE__.exiting_handler/4,
          %{}
        )

      assert @negative_id in handler_ids(@negative_event)

      log = capture_log(fn -> :telemetry.execute(@negative_event, %{}, %{}) end)

      # This single refutation carries two claims at once, which is what makes
      # it a real negative control rather than a hopeful one: the id is gone,
      # so `:telemetry` genuinely ran its failure path (the emission was not a
      # no-op), AND the guardian did not put it back.
      refute @negative_id in handler_ids(@negative_event),
             "the guardian re-attached a handler id it does not guard — a guardian that " <>
               "restores anything that fails is not a guardian"

      # Catches a guardian that reacts to an unguarded id at all, including one
      # that logs a restore and then attaches some default module under its own
      # id (where the id check above would still pass).
      refute log =~ "[HandlerGuardian]"

      # Discriminating: this counter CAN move, and a guardian that fell back to
      # a default module for unknown ids would move it.
      assert HandlerGuardian.restore_count(@audit_id) == 0
    end
  end

  describe "the bound" do
    test "restores stop at the bound, the handler is left detached, and that is logged once",
         %{audit_events: audit_events} do
      bound = HandlerGuardian.restore_bound()
      assert HandlerGuardian.restore_count(@audit_id) == 0

      for n <- 1..bound do
        install_exiting_stub!(@audit_id, audit_events)
        capture_log(fn -> :telemetry.execute(@login_event, %{}, %{}) end)

        assert find_handler(@login_event, @audit_id),
               "restore #{n} of #{bound} is within the bound and should have happened"

        assert find_handler(@login_event, @audit_id).function ==
                 (&@audit_module.handle_event/4)
      end

      assert HandlerGuardian.restore_count(@audit_id) == bound

      # One past the bound.
      install_exiting_stub!(@audit_id, audit_events)
      log = capture_log(fn -> :telemetry.execute(@login_event, %{}, %{}) end)

      refute find_handler(@login_event, @audit_id),
             "past the bound the handler must be LEFT detached — restoring forever turns a " <>
               "permanently broken handler into a hot loop that also hides itself"

      assert log =~ "LEFT DETACHED"
      assert occurrences(log, "LEFT DETACHED") == 1

      # Two past the bound: still refused, and NOT logged a second time.
      install_exiting_stub!(@audit_id, audit_events)
      later_log = capture_log(fn -> :telemetry.execute(@login_event, %{}, %{}) end)

      refute find_handler(@login_event, @audit_id)
      assert occurrences(later_log, "LEFT DETACHED") == 0

      # Leave the run as we found it. `ensure_boot_handler!/1`'s `on_exit` also
      # covers this; doing it here as well means a later assertion added to
      # this case does not run against a disarmed audit handler.
      :ok = @audit_module.attach()
      :ok = HandlerGuardian.reset_restore_counts()
    end
  end

  describe "the guardian's own survival" do
    test "a restore that raises does not detach the guardian", %{audit_events: audit_events} do
      counters_key = {HandlerGuardian, :restore_counters}

      # Instrument check. `:persistent_term.get/1` RAISES on a missing key, so
      # if the guardian's internal counter key is ever renamed this case fails
      # loudly instead of quietly poisoning nothing and asserting a guardian
      # that never raised is still attached.
      original = :persistent_term.get(counters_key)

      assert HandlerGuardian.handler_id() in handler_ids(@failure_event)

      log =
        try do
          # Make the guardian's own body blow up on a real emission: a term
          # that is not a `:counters` reference makes `:counters.add/3` raise
          # inside `handle_event/4`.
          :persistent_term.put(counters_key, :not_a_counters_reference)
          install_exiting_stub!(@audit_id, audit_events)
          capture_log(fn -> :telemetry.execute(@login_event, %{}, %{}) end)
        after
          :persistent_term.put(counters_key, original)
        end

      # Non-vacuity, and the reason the instrument check above matters: this
      # proves the guardian really did raise and really did swallow it. Without
      # it, a poisoning that failed to take would leave a guardian that never
      # raised, and "still attached" would assert nothing.
      assert log =~ "RAISED and was swallowed",
             "the guardian was expected to raise internally and log the swallow; got: #{log}"

      assert HandlerGuardian.handler_id() in handler_ids(@failure_event),
             ":telemetry detached the guardian itself. From this point no detach is " <>
               "repaired and nothing signals that, which is strictly worse than having no " <>
               "guardian at all"

      # The raise happened before the re-attach, so audit is still detached.
      # That is the documented consequence, not a defect.
      refute find_handler(@login_event, @audit_id)
      :ok = @audit_module.attach()
    end
  end

  describe "the guarded map itself" do
    # The handler id is the ONE thing written down twice — once as the guarded
    # module's own `@handler_id`, once as a key in the guardian's map. A typo in
    # the guardian's copy does not fail to compile, does not warn, and does not
    # show up in any of the cases above: it silently leaves that handler
    # unguarded, which is the exact condition this whole stage exists to remove.
    test "every guarded id really is the id its module attaches under" do
      for {handler_id, module} <- HandlerGuardian.boot_handlers() do
        :ok = module.attach()

        attached =
          []
          |> :telemetry.list_handlers()
          |> Enum.filter(&(&1.id == handler_id))

        refute attached == [],
               "the guardian maps #{inspect(handler_id)} to #{inspect(module)}, but after " <>
                 "#{inspect(module)}.attach/0 no handler is attached under that id — the id " <>
                 "in the guardian's map does not match the module's own @handler_id, so " <>
                 "#{inspect(module)} is silently UNGUARDED"

        for handler <- attached do
          assert handler.function == Function.capture(module, :handle_event, 4),
                 "#{inspect(handler_id)} is attached, but to #{inspect(handler.function)} " <>
                   "rather than #{inspect(module)}.handle_event/4 — the guardian's map pairs " <>
                   "this id with the wrong module, so a failure of one would restore the other"
        end
      end
    end

    # A drift guard. Adding an eighth boot handler to `Application.start/2` and
    # forgetting the guardian's map is silent in exactly the same way, and the
    # only place the intended set is written down is that function.
    test "every *.attach() in Platform.Application.start/2 is guarded, or is the guardian" do
      source = File.read!("lib/platform/application.ex")

      attached =
        ~r/^\s{4}(Platform(?:\.[A-Z][A-Za-z0-9_]*)+)\.attach\(\)$/m
        |> Regex.scan(source)
        |> Enum.map(fn [_line, module_name] -> Module.concat([module_name]) end)

      # Non-vacuity, and worth asserting on its own account: it proves the regex
      # matched real attach lines rather than nothing, AND it fails if someone
      # deletes the guardian's own attach call, which no other case here covers.
      assert HandlerGuardian in attached,
             "Platform.Telemetry.HandlerGuardian.attach/0 is not called in " <>
               "Platform.Application.start/2 — the guardian is dead code and every case " <>
               "in this file is passing only because `setup` attaches it by hand"

      assert Platform.Audit.TelemetryHandler in attached,
             "the source scan did not find the audit handler's attach call, so it is not " <>
               "reading the boot block and this case is measuring nothing"

      guarded = HandlerGuardian.boot_handlers() |> Map.values() |> MapSet.new()

      unguarded =
        Enum.reject(attached, &(&1 == HandlerGuardian or MapSet.member?(guarded, &1)))

      assert unguarded == [],
             """
             These handlers are attached at boot but are NOT in
             HandlerGuardian.boot_handlers/0, so :telemetry detaching one on failure would
             go unrepaired and unlogged:

             #{Enum.map_join(unguarded, "\n", &"  * #{inspect(&1)}")}

             Add each to the map in lib/platform/telemetry/handler_guardian.ex, keyed by
             the @handler_id it attaches under.
             """
    end
  end

  # A named capture, not an anonymous fun: `:telemetry` warns about anonymous
  # handler functions, and a named one is comparable by `==` in the assertions
  # above.
  def exiting_handler(_event, _measurements, _metadata, _config), do: exit(:boom)

  defp install_exiting_stub!(handler_id, events) do
    # Not matched on `:ok` — the id is already detached once the bound has been
    # reached, and `detach/1` reports `{:error, :not_found}` for that.
    _ = :telemetry.detach(handler_id)
    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.exiting_handler/4, %{})
    :ok
  end

  defp handler_event_names(handler_id) do
    [:platform]
    |> :telemetry.list_handlers()
    |> Enum.filter(&(&1.id == handler_id))
    |> Enum.map(& &1.event_name)
  end

  defp handler_ids(event) do
    event |> :telemetry.list_handlers() |> Enum.map(& &1.id)
  end

  defp find_handler(event, handler_id) do
    event |> :telemetry.list_handlers() |> Enum.find(&(&1.id == handler_id))
  end

  defp occurrences(string, substring) do
    length(String.split(string, substring)) - 1
  end
end
