defmodule Platform.Tasks.StageArchitectureAuditChangesetTest do
  @moduledoc """
  Task 019fa61c stage 1 — `stages.architecture_audit` and its narrow
  write surface.

  ## What these tests are, honestly

  Every test here is a GUARD, not a fix detector. The column, the field
  and `Stage.architecture_audit_changeset/2` do not exist on `main`, so
  none of these could detonate against unfixed `main` in the interesting
  sense — the module simply would not compile. The RED-FIRST run for
  this file is therefore an existence red (`UndefinedFunctionError:
  Platform.Tasks.Stage.architecture_audit_changeset/2 is undefined`), and
  it is recorded in the stage report rather than being dressed up as a
  behavioural detonation. The mandatory fix detector for this TASK — the
  one that fails against `main` for the real reason (a federated
  `audit_diff` fire leaves no artefact) — lives in stage 2.

  Guards still have to earn their keep. Two rules are applied throughout,
  both lifted from `architecture_gate_test.exs`:

    * every ABSENCE assertion is paired, in the same test, with a
      POSITIVE CONTROL proving the same input DOES move through some
      other surface. `refute changeset moved X` passes vacuously against
      a changeset that casts nothing at all;
    * every REJECTION assertion is paired with an ACCEPTANCE of a valid
      value in the same position, so a validator that rejects everything
      fails here rather than passing.

  TEN VACUITY CONTROLS were run by deliberately weakening
  `lib/platform/tasks/stage.ex` one change at a time and re-running this
  module; the measured counts and the specific failing assertion are
  recorded on each guard. Every control detonated, and every one
  detonated on the test that claims to guard it.

  One control REFUTED THIS MODULE'S OWN DESIGN and changed it: deleting
  `"findings"` from `@architecture_audit_required_keys` does not fail the
  per-key loop, because the loop iterates the same accessor the
  implementation consults and so cannot see its own vocabulary shrink.
  That is why `test "the required set names the subject ids"` spells the
  eleven keys out as a literal — see the note there.
  """
  # `async: true` is safe: nothing here writes through `Tasks.update_task/3`
  # or otherwise broadcasts on `tasks:board`, so the singleton
  # `TaskRouterWatcher` never wakes holding a connection it does not own.
  # Fixtures go through `Repo.insert!` for the same reason (019fa003-091a).
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Stage Audit Project #{u()}"})

    task = Repo.insert!(%Task{project_id: project.id, title: "Audit subject", status: "planning"})
    plan = Repo.insert!(%Plan{task_id: task.id, version: 1, status: "approved"})

    stage =
      Repo.insert!(%Stage{
        plan_id: plan.id,
        position: 1,
        name: "Subject stage",
        status: "running"
      })

    %{project: project, task: task, plan: plan, stage: stage}
  end

  defp u, do: System.unique_integer([:positive])

  defp stored(stage), do: Repo.get(Stage, stage.id).architecture_audit

  # The canonical open-audit shape. Every REQUIRED key is present with an
  # explicit value — including the ones that are `nil` at fire time. See
  # the "required keys" describe block for why nil-present and
  # key-absent must not be the same thing.
  defp pending_audit(ctx, opts \\ []) do
    now = DateTime.utc_now()
    offset_s = Keyword.get(opts, :deadline_offset_s, 1800)

    %{
      "state" => "pending",
      "stage_id" => ctx.stage.id,
      "task_id" => ctx.task.id,
      "plan_id" => ctx.plan.id,
      "dispatched_at" => DateTime.to_iso8601(now),
      "deadline_at" => now |> DateTime.add(offset_s, :second) |> DateTime.to_iso8601(),
      "resolved_at" => nil,
      "source" => nil,
      "reason" => nil,
      "summary" => nil,
      "findings" => []
    }
  end

  defp put_audit!(stage, audit) do
    stage
    |> Stage.architecture_audit_changeset(%{architecture_audit: audit})
    |> Repo.update!()
  end

  # `Platform.DataCase` does not define `errors_on/1`; every module in
  # this suite carries its own copy (`architecture_gate_test.exs:78`,
  # `planning_step_test.exs:41`, ~20 others). Following the local
  # convention rather than hoisting it.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "the narrow write surface" do
    # THE SMUGGLING GUARD, both directions, with paired positive
    # controls. This is the whole reason `:architecture_audit` is absent
    # from `changeset/2`'s cast list.
    #
    # Direction 1: `architecture_audit_changeset/2` cannot move
    # `:status`. Alone that is vacuous — a changeset casting nothing at
    # all passes it — so the same test asserts the audit DID move.
    #
    # Direction 2: `changeset/2` cannot write the audit. Alone THAT is
    # vacuous too, so the same test proves those exact attrs DO move
    # `:status` through the wide changeset. The wide changeset is the
    # unguarded status writer — `PlanEngine.transition_stage/2` calls it
    # on every stage transition — which is exactly why an audit write
    # must not travel on it.
    #
    # VACUITY CONTROL A, RUN — replaced the narrow cast list with
    # `cast(attrs, [])`: 15/17 tests in this module failed, this one on
    # `assert {:ok, %{"state" => "pending"}} = fetch_change(narrow,
    # :architecture_audit)` (right: `:error`). The two `refute` halves
    # still passed, trivially — which is why neither stands alone.
    test "audit changeset refuses :status, wide changeset refuses the audit", ctx do
      attrs = %{status: "failed", architecture_audit: pending_audit(ctx)}

      narrow = Stage.architecture_audit_changeset(ctx.stage, attrs)

      assert narrow.valid?

      assert {:ok, %{"state" => "pending"}} =
               Ecto.Changeset.fetch_change(narrow, :architecture_audit)

      assert :error == Ecto.Changeset.fetch_change(narrow, :status)

      # The other direction of the same property, with its control.
      wide = Stage.changeset(ctx.stage, attrs)

      assert {:ok, "failed"} = Ecto.Changeset.fetch_change(wide, :status)
      assert :error == Ecto.Changeset.fetch_change(wide, :architecture_audit)
    end

    # The smuggling guard at the DATABASE, not just at the changeset.
    # `fetch_change/2` proves what the changeset carries; this proves
    # what Postgres ends up holding, which is what every later reader
    # actually sees.
    test "neither surface writes the other's column through to the row", ctx do
      attrs = %{status: "failed", architecture_audit: pending_audit(ctx)}

      {:ok, after_wide} = ctx.stage |> Stage.changeset(attrs) |> Repo.update()

      assert after_wide.status == "failed"
      assert is_nil(stored(ctx.stage)), "Stage.changeset/2 must not write architecture_audit"

      {:ok, after_narrow} =
        after_wide |> Stage.architecture_audit_changeset(attrs) |> Repo.update()

      reloaded = Repo.get(Stage, ctx.stage.id)

      assert %{"state" => "pending"} = reloaded.architecture_audit
      assert after_narrow.status == "failed", "the narrow surface must not move :status"

      # POSITIVE CONTROL that the row-level probe can observe a status
      # move at all — otherwise the assertion above is indistinguishable
      # from a probe that reads the wrong column.
      {:ok, _} = reloaded |> Stage.changeset(%{status: "passed"}) |> Repo.update()
      assert Repo.get(Stage, ctx.stage.id).status == "passed"
    end
  end

  describe "the closed state vocabulary" do
    # GUARD + PAIRED CONTROL. A validator that rejects every state would
    # pass the `refute` half; the `assert` half in the same position
    # fails against it.
    #
    # VACUITY CONTROLS B AND C, RUN — (b) relaxed the membership test to
    # `is_binary(state)`: 1/17 failed, this one, on `refute
    # passed.valid?`. (c) shrank `@architecture_audit_states` to
    # `~w(pending)`: 3/17 failed and this one failed on
    # `assert noted.valid?`. Both halves bite.
    test "rejects a state outside the set and accepts one inside it", ctx do
      passed =
        Stage.architecture_audit_changeset(ctx.stage, %{
          architecture_audit: %{pending_audit(ctx) | "state" => "passed"}
        })

      refute passed.valid?
      assert [msg | _] = errors_on(passed).architecture_audit
      assert msg =~ "invalid state"

      noted =
        Stage.architecture_audit_changeset(ctx.stage, %{
          architecture_audit:
            pending_audit(ctx)
            |> Map.merge(%{
              "state" => "noted",
              "source" => "mcp",
              "resolved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "summary" => "Checked the diff; boundaries hold."
            })
        })

      assert noted.valid?
    end

    # `"expired"` IS DELIBERATELY UNREPRESENTABLE. Stage 2's
    # `StageAudit.read/1` PROJECTS a past-deadline `"pending"` row as
    # expired without persisting, so a persistable `"expired"` would give
    # the same fact two representations that could disagree — the
    # projection says expired, the row says expired-as-of-some-earlier-
    # sweep — and the level check would stop being the single source of
    # truth. `tasks.ex:2316-2349` makes the same argument for the plan
    # gate: the level check is the correctness guarantee, a persisted
    # eager state is at best an optimisation.
    #
    # PAIRED CONTROL in the same test: the three other terminal states
    # ARE representable, so this is the vocabulary excluding one value
    # on purpose, not the validator refusing terminal states in general.
    #
    # VACUITY CONTROL I, RUN — added `"expired"` to
    # `@architecture_audit_states` AND deleted the dedicated refusal
    # clause, i.e. made the projection's value persistable after all:
    # 1/17 failed, this one, on `refute expired.valid?`. Control C
    # (vocabulary shrunk to `~w(pending)`) failed the OTHER half of this
    # same test, on `assert changeset.valid?` for `noted` — so neither
    # half of the pair can be removed without the guard going quiet.
    test "\"expired\" is not persistable, while the other terminal states are", ctx do
      expired =
        Stage.architecture_audit_changeset(ctx.stage, %{
          architecture_audit: %{pending_audit(ctx) | "state" => "expired"}
        })

      refute expired.valid?
      assert [msg | _] = errors_on(expired).architecture_audit
      assert msg =~ "expired"
      assert msg =~ "projected"

      for state <- ~w(noted skipped failed) do
        changeset =
          Stage.architecture_audit_changeset(ctx.stage, %{
            architecture_audit: %{pending_audit(ctx) | "state" => state}
          })

        assert changeset.valid?, "#{state} must be persistable"
      end

      refute "expired" in Stage.architecture_audit_states()
      assert "pending" in Stage.architecture_audit_states()
    end

    test "a missing or non-string state is rejected", ctx do
      for bad <- [Map.delete(pending_audit(ctx), "state"), %{pending_audit(ctx) | "state" => 7}] do
        changeset = Stage.architecture_audit_changeset(ctx.stage, %{architecture_audit: bad})
        refute changeset.valid?
      end

      assert Stage.architecture_audit_changeset(ctx.stage, %{
               architecture_audit: pending_audit(ctx)
             }).valid?
    end
  end

  describe "the closed source vocabulary" do
    # GUARD + PAIRED CONTROL. `nil` is a real value (no channel answered
    # yet), which is why it is permitted alongside the two named
    # channels rather than being an absence.
    #
    # VACUITY CONTROL D, RUN — replaced the membership test with
    # `is_binary(source)`: 1/17 failed, this one, inside the
    # `for bad <- ~w(deadline human architect)` loop.
    test "rejects an unnamed channel and accepts both named ones plus nil", ctx do
      # `"deadline"` and `"human"` are `Plan.architecture_verdict_sources/0`
      # values that this column deliberately does NOT share: nothing
      # writes an audit on a deadline (the expiry is projected, never
      # persisted) and there is no human-override surface for an audit.
      for bad <- ~w(deadline human architect) do
        changeset =
          Stage.architecture_audit_changeset(ctx.stage, %{
            architecture_audit: %{pending_audit(ctx) | "source" => bad}
          })

        refute changeset.valid?, "#{bad} must not be a source"
        assert [msg | _] = errors_on(changeset).architecture_audit
        assert msg =~ "invalid source"
      end

      for good <- ["mcp", "handle_output", nil] do
        changeset =
          Stage.architecture_audit_changeset(ctx.stage, %{
            architecture_audit: %{pending_audit(ctx) | "source" => good}
          })

        assert changeset.valid?, "#{inspect(good)} must be a source"
      end
    end

    # The two named sources are exactly the two write paths this task
    # converges (stage 3's MCP tool, stage 4's `handle_output/3`), and
    # they are drawn from `Plan.architecture_verdict_sources/0` rather
    # than invented — one vocabulary for one distinction.
    test "the audit sources are a subset of the plan verdict sources", _ctx do
      assert Stage.architecture_audit_sources() == ~w(mcp handle_output)

      assert Enum.all?(
               Stage.architecture_audit_sources(),
               &(&1 in Plan.architecture_verdict_sources())
             )
    end
  end

  describe "required keys" do
    # THE POINT OF THIS BLOCK: a reader must never have to distinguish
    # "key absent" from "key present and nil". `audit["resolved_at"]`
    # returning `nil` should mean not-yet-resolved, not
    # maybe-the-writer-forgot. Every required key is written at fire
    # time, explicitly nil where it has no value yet.
    #
    # VACUITY CONTROLS E AND F, RUN. Control E deleted the required-key
    # check entirely: 2/17 failed, both in this block — the per-key loop
    # and the explicit-nil test.
    #
    # CONTROL F REFUTED MY OWN PREDICTION, and the correction is why
    # there are three tests here rather than one. I expected that
    # deleting `"findings"` from `@architecture_audit_required_keys`
    # would fail the per-key loop. It does NOT: the loop iterates
    # `Stage.architecture_audit_required_keys()`, so a key removed from
    # the accessor is also removed from the loop, and the loop cannot
    # see its own vocabulary shrinking. 1/17 failed under control F and
    # it was "the required set names the subject ids" — the test that
    # spells the eleven keys out as a LITERAL. That is the only reason
    # the literal duplication earns its place: an accessor-driven loop
    # and an accessor-driven implementation agree with each other no
    # matter what either says.
    test "each required key is individually required", ctx do
      full = pending_audit(ctx)

      # POSITIVE CONTROL FIRST: the complete map is accepted. Without
      # this, a validator rejecting everything would pass the loop.
      assert Stage.architecture_audit_changeset(ctx.stage, %{architecture_audit: full}).valid?

      for key <- Stage.architecture_audit_required_keys() do
        changeset =
          Stage.architecture_audit_changeset(ctx.stage, %{
            architecture_audit: Map.delete(full, key)
          })

        refute changeset.valid?, "dropping #{key} must be rejected"

        assert Enum.any?(
                 errors_on(changeset).architecture_audit,
                 &(&1 =~ "missing required key #{inspect(key)}")
               ),
               "the error for a dropped #{key} must NAME the key — a generic " <>
                 "\"invalid audit\" would pass this loop for every key at once"
      end
    end

    test "an explicit nil satisfies a required key — absence is the thing refused", ctx do
      nils = %{pending_audit(ctx) | "resolved_at" => nil, "summary" => nil, "reason" => nil}

      assert Stage.architecture_audit_changeset(ctx.stage, %{architecture_audit: nils}).valid?

      refute Stage.architecture_audit_changeset(ctx.stage, %{
               architecture_audit: Map.delete(nils, "resolved_at")
             }).valid?
    end

    # THE ONLY TEST HERE THAT SPELLS THE KEYS OUT AS A LITERAL, and the
    # duplication is deliberate rather than sloppy: control F proved the
    # accessor-driven loop above is BLIND to a key being deleted from
    # the accessor, because it iterates the same list the implementation
    # consults. A literal is the only thing that can notice the
    # vocabulary shrinking. The three subject ids are named explicitly
    # because a row that cannot say which stage it belongs to is not
    # evidence of anything.
    test "the required set names the subject ids", ctx do
      required = Stage.architecture_audit_required_keys()

      for key <- ~w(state stage_id task_id plan_id dispatched_at deadline_at resolved_at
                    source reason summary findings) do
        assert key in required
      end

      # Extra keys are permitted — stage 3 adds `resolved_by` and
      # `noted_after_deadline` on the note path, and forbidding unknown
      # keys here would force a schema change for every later addition.
      extra = Map.put(pending_audit(ctx), "noted_after_deadline", true)
      assert Stage.architecture_audit_changeset(ctx.stage, %{architecture_audit: extra}).valid?
    end
  end

  describe "findings" do
    defp finding(constraint, detail \\ "Move the query into the context module."),
      do: %{"constraint" => constraint, "detail" => detail}

    # GUARD + PAIRED CONTROL. The constraint vocabulary is REUSED from
    # `Plan.architecture_constraints/0` — a second copy is how the two
    # architect surfaces drift apart, which is the class of defect this
    # whole task is about.
    #
    # VACUITY CONTROL G, RUN — relaxed the constraint check to
    # `is_binary(constraint)`: 1/17 failed, this one, on
    # `refute style.valid?`.
    test "rejects a constraint outside Plan.architecture_constraints/0", ctx do
      style =
        Stage.architecture_audit_changeset(ctx.stage, %{
          architecture_audit: %{pending_audit(ctx) | "findings" => [finding("naming")]}
        })

      refute style.valid?
      assert [msg | _] = errors_on(style).architecture_audit
      assert msg =~ "invalid constraint"

      for constraint <- Plan.architecture_constraints() do
        changeset =
          Stage.architecture_audit_changeset(ctx.stage, %{
            architecture_audit: %{pending_audit(ctx) | "findings" => [finding(constraint)]}
          })

        assert changeset.valid?, "#{constraint} must be accepted"
      end
    end

    # VACUITY CONTROL H, RUN — short-circuited the blank check so any
    # detail passes: 1/17 failed, this one, inside the
    # `for blank <- ["", "   ", "\\n"]` loop. A whitespace-only detail is
    # the shape that matters: it satisfies `is_binary/1` and reads as a
    # finding to every count, while telling the executor nothing.
    test "a blank detail is rejected and a non-blank one accepted", ctx do
      for blank <- ["", "   ", "\n"] do
        changeset =
          Stage.architecture_audit_changeset(ctx.stage, %{
            architecture_audit: %{
              pending_audit(ctx)
              | "findings" => [finding("module_boundary", blank)]
            }
          })

        refute changeset.valid?, "#{inspect(blank)} must be rejected as a detail"
        assert [msg | _] = errors_on(changeset).architecture_audit
        assert msg =~ "detail"
      end

      assert Stage.architecture_audit_changeset(ctx.stage, %{
               architecture_audit: %{
                 pending_audit(ctx)
                 | "findings" => [finding("module_boundary", "Split the context.")]
               }
             }).valid?
    end

    test "findings must be a list of maps carrying both keys", ctx do
      bad_shapes = [
        "not a list",
        [%{"constraint" => "module_boundary"}],
        [%{"detail" => "no constraint"}],
        ["a string finding"]
      ]

      for bad <- bad_shapes do
        changeset =
          Stage.architecture_audit_changeset(ctx.stage, %{
            architecture_audit: %{pending_audit(ctx) | "findings" => bad}
          })

        refute changeset.valid?, "#{inspect(bad)} must be rejected"
      end

      assert Stage.architecture_audit_changeset(ctx.stage, %{
               architecture_audit: %{pending_audit(ctx) | "findings" => []}
             }).valid?
    end
  end

  describe "structural refusals" do
    # VACUITY CONTROL J, RUN — removed the string-key check from the
    # validation pipeline: 1/17 failed, this one, on the `Enum.any?`
    # assertion. Note what did NOT fail: `refute changeset.valid?` still
    # passed, because an atom-keyed map also trips the required-key
    # check. Asserting only on validity would have left this guard
    # green against its own deletion.
    test "atom keys are refused so the JSONB round trip is identity", ctx do
      changeset =
        Stage.architecture_audit_changeset(ctx.stage, %{
          architecture_audit: %{state: "pending", stage_id: ctx.stage.id}
        })

      refute changeset.valid?

      # `Enum.any?` rather than the head of the list: an atom-keyed map
      # also trips the required-key and state checks, and which error
      # `traverse_errors/2` returns first is an ordering detail this test
      # has no business pinning.
      assert Enum.any?(errors_on(changeset).architecture_audit, &(&1 =~ "string keys"))

      # PAIRED CONTROL: the string-keyed equivalent is accepted, so the
      # refusal is about the keys and not about the map.
      assert Stage.architecture_audit_changeset(ctx.stage, %{
               architecture_audit: pending_audit(ctx)
             }).valid?
    end

    test "a non-map is refused", ctx do
      changeset =
        Stage.architecture_audit_changeset(ctx.stage, %{architecture_audit: "pending"})

      refute changeset.valid?
    end

    # The persisted map round-trips through JSONB unchanged. If the
    # writer emitted atom keys, Postgres would hand back strings and the
    # two halves of the round trip would differ — which is the reason
    # for the string-key refusal above, proved rather than asserted.
    test "what goes in is what comes back out", ctx do
      audit =
        pending_audit(ctx)
        |> Map.merge(%{
          "state" => "noted",
          "source" => "mcp",
          "summary" => "Boundaries hold.",
          "findings" => [finding("cross_context_coupling")]
        })

      put_audit!(ctx.stage, audit)

      assert stored(ctx.stage) == audit
    end
  end

  describe "the audit is keyed to its own subject" do
    # An artefact that exists but points at the wrong stage is not
    # evidence. The changeset cannot verify the ids against the row it
    # is updating — that is stage 2's writer's job — but it CAN refuse a
    # shape that omits them, and this test pins that the ids survive the
    # round trip so stage 2's assertions have something real to check.
    test "the subject ids persist verbatim", ctx do
      put_audit!(ctx.stage, pending_audit(ctx))

      audit = stored(ctx.stage)

      assert audit["stage_id"] == ctx.stage.id
      assert audit["task_id"] == ctx.task.id
      assert audit["plan_id"] == ctx.plan.id

      # POSITIVE CONTROL that the probe discriminates: a DIFFERENT
      # stage's row is untouched and still nil, so the assertions above
      # are not reading a value that would be there regardless.
      other =
        Repo.insert!(%Stage{plan_id: ctx.plan.id, position: 2, name: "Other", status: "pending"})

      assert is_nil(stored(other))
      refute audit["stage_id"] == other.id
    end
  end
end
