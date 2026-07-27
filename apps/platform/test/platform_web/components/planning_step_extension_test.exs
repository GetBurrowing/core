defmodule PlatformWeb.Components.PlanningStepExtensionTest do
  @moduledoc """
  Unit tests for the ADR-0046 planning-step card extension (task
  `019f9b29-9c47`, stack member 8, stage 1).

  Follows the precedent in `scope_pill_test.exs`: assert against rendered DOM
  strings rather than driving a LiveView.

  Every test here is a **GUARD**, not a detector — this is a brand-new module,
  so nothing in this file can detonate against unfixed `main`. The detectors for
  this task live in stage 4, against the rendered board.

  `use ExUnit.Case, async: true` with **no `DataCase`** is load-bearing, not
  incidental: it is the mechanical proof that `entries/1` is a pure function of
  `%Task{}` fields. There is no checked-out database connection in this file, so
  a `Repo` call inside the component cannot pass here.

  ## The vacuity problem this file is written against

  A component that renders nothing under all inputs passes every absence
  assertion. So each absence guard is **paired in the same `test` block** with
  the byte-identical positive control that must render. Both halves in one block
  means neither can be deleted alone.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.PlanningStepExtension

  alias Platform.Design.PreplanStep
  alias Platform.Tasks.Task

  @source_path "lib/platform_web/components/planning_step_extension.ex"

  # A bare in-memory struct. No Repo, no changeset, no preloads.
  defp task(attrs) do
    struct!(
      %Task{
        id: "019f9b29-9c47-7b66-b863-641b50d09eff",
        title: "A task",
        status: "planning",
        planning_step: "planning",
        planning_step_outcomes: %{}
      },
      attrs
    )
  end

  defp render_extension(task, opts \\ []) do
    assigns = %{
      task: task,
      variant: Keyword.get(opts, :variant, :extension),
      data_role: Keyword.get(opts, :data_role, "planning-step-extension")
    }

    rendered_to_string(~H"""
    <.planning_step_extension task={@task} variant={@variant} data_role={@data_role} />
    """)
    |> String.trim()
  end

  defp all_steps(record) do
    Map.new(Task.planning_step_keys(), &{&1, record})
  end

  defp source, do: File.read!(@source_path)

  # ── the paired absence/presence guard ─────────────────────────────────────

  describe "not_applicable renders nothing" do
    # THE most important test in this stage. The absence half alone passes
    # vacuously against a component that never renders anything at all; the
    # presence half uses BYTE-IDENTICAL assigns with only the outcome value
    # changed, so the only thing that can explain the difference is the
    # not_applicable rule itself. Both halves live in one `test` block so
    # neither can be deleted without the other.
    test "an org with no designer and no architect gets an empty render, but a failed one does not" do
      absent =
        task(
          planning_step_outcomes:
            all_steps(%{"outcome" => "not_applicable", "reason" => "no_designer"})
        )

      present =
        task(
          planning_step_outcomes: all_steps(%{"outcome" => "failed", "reason" => "no_designer"})
        )

      # ABSENCE — nothing at all, achieved by producing nothing.
      assert render_extension(absent) == ""
      assert entries(absent) == []
      refute visible?(absent)

      # POSITIVE CONTROL — same struct, same reason, same everything but the
      # outcome string. Without this the assertions above are meaningless.
      html = render_extension(present)
      assert html =~ ~s(data-planning-outcome="failed")
      assert entries(present) != []
      assert visible?(present)
    end

    # The migration backfills every pre-existing row to exactly this shape, so
    # this is the state of the overwhelming majority of tasks on every board.
    test "a pre-migration-shaped task renders nothing, but the same struct with a cursor does" do
      quiet = task(planning_step: "planning", planning_step_outcomes: %{})
      active = %{quiet | planning_step: "designing"}

      # ABSENCE
      assert render_extension(quiet) == ""
      assert entries(quiet) == []

      # POSITIVE CONTROL — the pulsing active-cursor chip on the same struct.
      html = render_extension(active)
      assert html =~ ~s(data-planning-cursor="designing")
      assert html =~ "motion-safe:animate-pulse"
      assert html =~ "Designing"
    end
  end

  # ── the conflation guard ──────────────────────────────────────────────────

  describe "not_applicable and failed never collapse (ADR-0046:83)" do
    # Stated as DIRECT INEQUALITIES rather than pairs of equality assertions, so
    # a refactor that collapses two outcomes fails one named test rather than
    # quietly satisfying two independently-plausible expectations.
    #
    # MEASURED, 2026-07-27: the whole-entry inequality on its own is NOT
    # sufficient, and this is worth stating because it is the form the stage
    # description specified. Mutating `kind_for/2` so that EVERY
    # `not_applicable` is treated as `:failed` — the exact collapse this guard
    # names — left `entries(not_applicable) != entries(failed)` PASSING, because
    # each entry still carries the raw `outcome` string it was built from, and
    # `"not_applicable" != "failed"` regardless of how identically the two are
    # treated. The whole-entry form can only detect a collapse in which the
    # underlying DATA is also identical, which cannot happen.
    #
    # So the load-bearing assertion is the one over the TREATMENT projection:
    # kind, icon, tone and copy — everything a human actually sees. That one
    # does fail under the mutation. The whole-entry form is kept because it is
    # cheap and catches a different class of collapse, but it is the weaker of
    # the two and is deliberately not the only one here.
    test "entries/1 for a not_applicable task is not equal to entries/1 for a failed task" do
      not_applicable = task(planning_step_outcomes: all_steps(%{"outcome" => "not_applicable"}))
      failed = task(planning_step_outcomes: all_steps(%{"outcome" => "failed"}))

      assert entries(not_applicable) != entries(failed)
      assert treatments(not_applicable) != treatments(failed)
    end

    test "complete and failed do not collapse either" do
      complete = task(planning_step_outcomes: all_steps(%{"outcome" => "complete"}))
      failed = task(planning_step_outcomes: all_steps(%{"outcome" => "failed"}))

      assert entries(complete) != entries(failed)
      assert treatments(complete) != treatments(failed)
    end

    test "the contradicted warning does not collapse into failed either" do
      contradicted =
        task(
          planning_step_outcomes:
            all_steps(%{"outcome" => "not_applicable", "reason" => contradicted_reason()})
        )

      failed = task(planning_step_outcomes: all_steps(%{"outcome" => "failed"}))

      assert treatments(contradicted) != treatments(failed)
      # Control: both DO render, so the inequality above is between two visible
      # things rather than between something and silence.
      refute Enum.empty?(treatments(contradicted))
      refute Enum.empty?(treatments(failed))
    end
  end

  # Everything a human actually sees, with the raw outcome string stripped out.
  defp treatments(task) do
    Enum.map(entries(task), &{&1.kind, &1.icon, &1.tone, &1.chip, &1.label})
  end

  # ── the persistence rules, made falsifiable ───────────────────────────────

  describe "persistence across task status" do
    test "failed persists through to merge; complete does not survive the start of work" do
      failed_record = all_steps(%{"outcome" => "failed"})
      complete_record = all_steps(%{"outcome" => "complete"})

      # `failed` renders at EVERY status, forever. No dismiss, no expiry.
      for status <- Task.statuses() do
        html = render_extension(task(status: status, planning_step_outcomes: failed_record))

        assert html =~ ~s(data-planning-outcome="failed"),
               "failed marker vanished at status=#{status}"
      end

      # `complete` renders only while the task is still pre-execution.
      assert render_extension(task(status: "deploying", planning_step_outcomes: complete_record)) ==
               ""

      assert render_extension(task(status: "done", planning_step_outcomes: complete_record)) == ""

      # POSITIVE CONTROL for the two refutations above.
      html = render_extension(task(status: "planning", planning_step_outcomes: complete_record))
      assert html =~ ~s(data-planning-outcome="complete")
      assert html =~ "hero-check-badge"
    end

    test "the gate statuses are drawn from Task.statuses/0, so a typo cannot silently disable them" do
      assert complete_statuses() -- Task.statuses() == []
      assert active_statuses() -- Task.statuses() == []
      # Non-empty, or the subset assertions above pass vacuously.
      refute Enum.empty?(complete_statuses())
      refute Enum.empty?(active_statuses())
    end

    test "the active cursor renders while planning and not once work has started" do
      designing = task(planning_step: "designing")

      assert render_extension(%{designing | status: "planning"}) =~ "Designing"
      assert render_extension(%{designing | status: "in_progress"}) == ""
    end
  end

  # ── the one not_applicable that renders ───────────────────────────────────

  describe "member 7's false-negative annotation" do
    test "no_ui_surface_contradicted renders a warning chip; no_ui_surface renders nothing" do
      base = %{"outcome" => "not_applicable"}

      contradicted =
        task(
          planning_step_outcomes: %{
            "design" => Map.put(base, "reason", contradicted_reason())
          }
        )

      quiet =
        task(
          planning_step_outcomes: %{
            "design" => Map.put(base, "reason", PreplanStep.reasons().no_ui_surface)
          }
        )

      # ABSENCE — the ordinary skip is silent.
      assert render_extension(quiet) == ""

      # POSITIVE CONTROL — otherwise-identical entry, only the reason differs.
      html = render_extension(contradicted)
      assert html =~ ~s(data-planning-reason="#{contradicted_reason()}")
      assert html =~ ~s(data-planning-outcome="not_applicable")
      assert html =~ "text-warning"
      assert html =~ "plan says otherwise"

      # Visually distinct from `failed`, which is the whole point of the third
      # treatment — a warning is neither an error nor silence.
      refute html =~ "text-error"
    end

    test "every other not_applicable reason renders nothing" do
      render_reason = fn outcome, reason ->
        render_extension(
          task(
            planning_step_outcomes: %{
              "design" => %{"outcome" => outcome, "reason" => reason}
            }
          )
        )
      end

      others = Enum.reject(Map.values(PreplanStep.reasons()), &(&1 == contradicted_reason()))

      # Control: there are other reasons to check, and the harness above CAN
      # produce output — without this the loop below passes trivially both when
      # `reasons/0` is empty and when the component renders nothing at all.
      refute Enum.empty?(others)
      assert render_reason.("failed", hd(others)) != ""

      for reason <- others do
        assert render_reason.("not_applicable", reason) == "",
               "reason #{inspect(reason)} rendered a chip on a not_applicable step"
      end
    end
  end

  # ── contract bindings to members 4 and 7 ──────────────────────────────────

  describe "upstream contract binding" do
    test "member 4 still exposes the accessors this module iterates" do
      assert function_exported?(Task, :planning_step_keys, 0)
      assert function_exported?(Task, :planning_steps, 0)
      assert function_exported?(Task, :planning_step_outcomes, 0)
      refute Enum.empty?(Task.planning_step_keys())
    end

    test "member 7 still ships the reason string this module branches on" do
      # Bind to the accessor AND pin the wire value: the string is persisted in
      # `planning_step_outcomes` rows, so a rename upstream is a data migration,
      # not just a code change, and this test should be the thing that says so.
      assert contradicted_reason() == "no_ui_surface_contradicted"
      assert PreplanStep.reasons().contradicted == contradicted_reason()
      assert File.read!("lib/platform/design/preplan_step.ex") =~ "no_ui_surface_contradicted"
    end

    test "this module holds no private copy of the step-key list" do
      # `["design", "architecture"]` must not appear here in any spelling — a
      # guard that hardcodes its own copy of a list is how the class comes back.
      for key <- Task.planning_step_keys() do
        refute source() =~ ~s("#{key}"),
               "step key #{inspect(key)} is restated in #{@source_path}; iterate Task.planning_step_keys/0"
      end
    end

    test "the cursor treatments cover exactly Task.planning_steps/0" do
      # The cursor icons must be whole literals, so this module unavoidably
      # holds a map keyed by cursor value. This binds that map back to member
      # 4's list: a new cursor value upstream fails here loudly instead of
      # silently rendering no chip.
      rendering =
        Enum.filter(Task.planning_steps(), fn step ->
          entries(task(planning_step: step)) != []
        end)

      assert Enum.sort(rendering) == Enum.sort(Task.planning_steps() -- ["planning"])
      refute Enum.empty?(rendering)
    end
  end

  # ── Tailwind v4: the classes must be literals in the SOURCE ───────────────

  describe "Tailwind v4 scanner safety" do
    # `html =~ "hero-x"` passes when the class is in the HTML and absent from
    # the compiled CSS — which is exactly how `hero-bug-ant` and
    # `hero-queue-list` shipped in this repo as empty boxes with a green suite.
    # The scanner reads the SOURCE, so the assertion has to read the source too.
    test "every icon this component can emit appears as a whole string literal in its own source" do
      icons = reachable_icons()

      # Control: the assertion form below can fail. Without this, an empty
      # `icons` set would make the whole test pass vacuously.
      assert MapSet.size(icons) >= 4
      refute source() =~ ~s("hero-definitely-not-a-real-icon")

      for icon <- icons do
        assert source() =~ ~s("#{icon}"),
               "#{icon} is not a whole string literal in #{@source_path} — Tailwind cannot see it"
      end
    end

    test "every colour class this component can emit appears verbatim in its own source" do
      classes = reachable_tones()

      # Control: the assertion form below can fail, and there is something to
      # check. The scanner extracts candidate class names from raw source text,
      # so verbatim presence — not quoting — is the property that matters; what
      # defeats it is interpolation, which is exactly what this catches.
      assert MapSet.size(classes) >= 3
      refute source() =~ "text-definitely-not-a-real-token"

      for class <- classes do
        assert source() =~ class,
               "#{class} is assembled rather than written literally in #{@source_path}"
      end
    end
  end

  describe "design-token discipline" do
    test "the source contains no hex literal and no raw palette-name class" do
      src = source()

      # Control first: prove there ARE colour classes here to get wrong, so a
      # module with no colours at all cannot pass this test.
      assert src =~ "text-error"
      assert src =~ "bg-warning/10"
      assert src =~ "text-base-content/60"

      refute src =~ ~r/#[0-9a-fA-F]{6}\b/
      refute src =~ "oklch("
      refute src =~ ~r/\b(violet|cyan|red|amber|emerald|slate|zinc)-\d{3}\b/
    end
  end

  describe "shared component library" do
    test "icons go through <.icon>, never a raw hero span" do
      src = source()

      # Control: prove icons are rendered at all.
      assert src =~ "<.icon"
      refute src =~ ~s(<span class="hero-)
    end
  end

  # ── DOM discipline ────────────────────────────────────────────────────────

  describe "DOM discipline" do
    test "the component emits no id attribute on any branch" do
      failed = task(planning_step_outcomes: all_steps(%{"outcome" => "failed"}))

      for variant <- [:extension, :compact] do
        html = render_extension(failed, variant: variant)

        # Control: there IS output to inspect.
        refute html == ""
        # `phx-value-id=` is preceded by `-`, so the word-boundary form here
        # only matches a real `id` attribute.
        refute html =~ ~r/\sid=/
      end
    end

    test "both steps failed render two chips inside one root, ordered by Task.planning_step_keys/0" do
      failed = task(planning_step_outcomes: all_steps(%{"outcome" => "failed"}))
      html = render_extension(failed)

      assert length(String.split(html, "<button")) == 2, "expected exactly one root element"

      positions =
        Enum.map(Task.planning_step_keys(), fn key ->
          index = :binary.match(html, ~s(data-planning-step-key="#{key}"))
          assert index != :nomatch, "no chip for step key #{key}"
          elem(index, 0)
        end)

      assert positions == Enum.sort(positions),
             "chips are not in Task.planning_step_keys/0 order"

      assert length(positions) == length(Task.planning_step_keys())
    end

    test "the root carries the highest-severity outcome so a caller can select without walking children" do
      mixed =
        task(
          planning_step_outcomes: %{
            "design" => %{"outcome" => "complete"},
            "architecture" => %{"outcome" => "failed"}
          }
        )

      html = render_extension(mixed)
      [root | _] = String.split(html, ">", parts: 2)

      assert root =~ ~s(data-planning-outcome="failed")
      # Control: the muted chip IS present further down, so the root is
      # summarising rather than the complete entry simply being absent.
      assert html =~ "hero-check-badge"
    end

    test "the root is a button and carries an aria-label composed from its entries" do
      failed =
        task(
          planning_step_outcomes: %{
            "architecture" => %{"outcome" => "failed", "detail" => "econnrefused"}
          }
        )

      html = render_extension(failed)

      assert html =~ ~s(type="button")
      assert html =~ ~s(aria-label="Architecture gate did not run — econnrefused")
      assert html =~ ~s(title="Architecture gate did not run — econnrefused")
      # The visual chips repeat the label verbatim, so they are hidden from the
      # accessibility tree rather than announced twice.
      assert html =~ ~s(aria-hidden="true")
    end

    test "the caller-supplied data_role is the only thing identifying the root" do
      failed = task(planning_step_outcomes: all_steps(%{"outcome" => "failed"}))

      assert render_extension(failed, data_role: "mobile-planning-step-extension") =~
               ~s(data-role="mobile-planning-step-extension")

      assert render_extension(failed, data_role: "planning-step-extension") =~
               ~s(data-role="planning-step-extension")
    end
  end

  # ── variants ──────────────────────────────────────────────────────────────

  describe "variant branching" do
    # Proves the compact path actually branches rather than being dead code
    # that stage 3 will discover is unreachable.
    test "compact suppresses complete and the active cursor; extension does not" do
      complete = task(planning_step_outcomes: all_steps(%{"outcome" => "complete"}))
      active = task(planning_step: "architecting")

      assert render_extension(complete, variant: :compact) == ""
      assert render_extension(active, variant: :compact) == ""

      # POSITIVE CONTROL — identical structs through the extension variant.
      assert render_extension(complete, variant: :extension) =~ "hero-check-badge"
      assert render_extension(active, variant: :extension) =~ "hero-cube-transparent"
    end

    test "compact renders failures as a span, not a nested button" do
      failed = task(planning_step_outcomes: all_steps(%{"outcome" => "failed"}))
      html = render_extension(failed, variant: :compact, data_role: "stack-member-planning-step")

      assert html =~ ~s(data-role="stack-member-planning-step")
      assert html =~ ~s(data-planning-outcome="failed")
      assert html =~ "shrink-0"
      # A stack-member row is itself clickable; a nested button is invalid HTML.
      refute html =~ "<button"
    end

    test "visible?/2 agrees with what actually renders, per variant" do
      complete = task(planning_step_outcomes: all_steps(%{"outcome" => "complete"}))

      assert visible?(complete, :extension)
      refute visible?(complete, :compact)
    end
  end

  # ── purity ────────────────────────────────────────────────────────────────

  describe "purity" do
    test "entries/1 reads only %Task{} fields — no Repo, no preloads, no connection" do
      # This module has no `DataCase`, so there is no checked-out connection in
      # this process. A Repo call inside `entries/1` would raise here.
      bare = %Task{
        status: "done",
        planning_step: "planning",
        planning_step_outcomes: %{"architecture" => %{"outcome" => "failed"}}
      }

      assert [%{kind: :failed, step_key: "architecture"}] = entries(bare)
    end

    test "a nil outcomes map is treated as nothing recorded" do
      assert entries(task(planning_step_outcomes: nil)) == []
    end

    test "an unrecognised outcome value renders nothing rather than raising" do
      assert render_extension(task(planning_step_outcomes: %{"design" => %{"outcome" => "wat"}})) ==
               ""

      assert render_extension(task(planning_step_outcomes: %{"design" => "not-a-map"})) == ""
    end
  end

  # Collect the icon/tone values reachable through the public API, rather than
  # restating the private treatment map.
  defp reachable_entries do
    outcome_tasks =
      for outcome <- Task.planning_step_outcomes() do
        task(status: "planning", planning_step_outcomes: all_steps(%{"outcome" => outcome}))
      end

    contradicted =
      task(
        planning_step_outcomes:
          all_steps(%{"outcome" => "not_applicable", "reason" => contradicted_reason()})
      )

    cursor_tasks = for step <- Task.planning_steps(), do: task(planning_step: step)

    Enum.flat_map([contradicted | outcome_tasks] ++ cursor_tasks, &entries/1)
  end

  defp reachable_icons, do: reachable_entries() |> MapSet.new(& &1.icon)

  defp reachable_tones,
    do:
      reachable_entries() |> Enum.flat_map(&String.split("#{&1.tone} #{&1.chip}")) |> MapSet.new()
end
