defmodule Platform.Design.UiSurfaceTest do
  @moduledoc """
  Corpus regression suite for the pre-plan UI-surface heuristic (ADR 0046).

  Every corpus entry below is **real** — a task title/description from this
  project's board or a commit subject from this repo's own git log, cited in
  `:source`. Nothing here is a synthetic fixture chosen to flatter the detector,
  including the deliberately hard `:not_ui` entries that do fire.

  The two bounds asserted here (zero false negatives, ≤25% false positives) and
  the corpus itself are **not** tunable. The vocabulary in
  `Platform.Design.UiSurface` is. See that module's `@moduledoc`.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.UiSurface
  alias Platform.Tasks.PlanEngine

  doctest Platform.Design.UiSurface

  @module_path "lib/platform/design/ui_surface.ex"

  @false_positive_cap 0.25

  # ── The corpus ────────────────────────────────────────────────────────────
  #
  # `:ui` entries carrying no file-path token are the ones layer A alone cannot
  # see; they are the subject of the layer-A detector run recorded in the stage
  # evidence. `path_token: true` marks the single entry that layer A *should*
  # catch.

  @ui_corpus [
    %{
      source: "task 019f9282 / PR #599",
      title: "Build /org_memory mobile surface — segmented tabs, path chip, drawer",
      description: nil
    },
    %{
      source: "task 019f9257-752d / PR #597",
      title: "External-grant multiselect (bug #2)",
      description: nil
    },
    %{
      source: "task 019f70b8 / PR #612",
      title:
        "intents-collapse bar in MeetingLive — live-tuning strip over the per-meeting intent queue",
      description: nil
    },
    %{
      source: "commit bce6f18",
      title: "Add an epic-create FAB above the board",
      description: nil
    },
    %{
      source: "commit f612756",
      title: "Badges render as a mobile card",
      description: nil
    },
    %{
      source:
        "task 019f9b29-9c47 (ADR 0046 member 8) — description verbatim, first two paragraphs",
      title: "Render planning_step on the task card as an above-card extension",
      description: """
      ADR 0046 — the UI surface. Pure render concern reading `planning_step`; no lifecycle logic here.

      Extension above the task card showing the active planning sub-step ("Designing", "Architecting"). Render **nothing** when the step is `not_applicable` — an org with no designer or architect assigned must see the board exactly as it does today.\
      """
    },
    %{
      source: "task 019f9257-a83e / PR #595",
      title: "Make external chat surface mobile-responsive",
      description: nil
    },
    %{
      source: "task 019f923b / PR #596",
      title: "chat mobile: mobile Pinned strip + 44px task-detail tap targets",
      description: nil
    },
    %{
      source: "task 019f9790 / PR #602",
      title: "Collapse the three agent header controls into one mutex eye",
      description: nil
    },
    %{
      source: "PR #583",
      title: "Fix: Admin gear lands on /admin (route-resume TTL + module breadcrumbs)",
      description: nil
    },
    %{
      source: "task 019f70b8 / PR #612",
      title:
        "Intent-queue live-tuning UI: ETS-backed queue, click-to-correct, few-shot corpus, role-gated visibility",
      description: nil
    },
    %{
      source: "ADR 0046 member 8 — the rare pre-plan description that names a file",
      path_token: true,
      title: "Task card extension for planning_step",
      description:
        "The markup lands in `lib/platform_web/live/tasks_live.html.heex`; keep the new component under `components/` rather than inlining it."
    }
  ]

  @not_ui_corpus [
    %{
      source: "task 019f9b27 / commit 'Give fire_trigger/3 a real return contract'",
      title: "Fix fire_trigger/3 return contract to distinguish unfilled from failed",
      description: nil
    },
    %{
      source: "task 019f9b28 stage 1",
      title: "Add Providers.Architecture shim so architecture.* stops black-holing",
      description: nil
    },
    %{
      source: "task 019f9b28-6ca7 stages 3-5",
      title: "Context resolvers for plan_payload / sibling_tasks / adr_index",
      description: nil
    },
    %{
      source: "task 019f9b28-6ca7",
      title: "Forward message_id and responsibility keys on chat-path signals",
      description: nil
    },
    %{
      source: "task 019f9b34",
      title: "TaskRouter deploying → done is edge-triggered with no level re-check",
      description: nil
    },
    %{
      source: "PR #613",
      title: "Coerce or reject a non-UUID space_id at the RuntimeChannel boundary",
      description: nil
    },
    %{
      # KNOWN-HARD. Kept verbatim and allowed to count against the cap rather
      # than swapped for a flattering fixture: its real prose says "the UI and
      # the gates both read" and "pure render concern" while the work is a
      # schema migration.
      source:
        "task 019f9b28-ab82 (ADR 0046 member 4) — title + description verbatim, first four paragraphs",
      known_hard: true,
      title: "Add planning_step field and per-step outcome persistence",
      description: """
      Add planning_step field and per-step outcome persistence — ADR 0046 — the state model the UI and the gates both read.

      Add a `planning_step` field to `Platform.Tasks.Task` (`:designing | :planning | :architecting`) plus per-step outcome persistence.

      ⚠️ DO NOT ADD A TASK STATUS. "Architecting" must NOT become a `task.status` value.

      `Task.changeset/2` casts `:status`, which makes `update_task/2` a fully unguarded status writer. Adding a status to that surface means reasoning about four gate sets. `planning_step` keeps the transition table untouched and makes the card extension a pure render concern.\
      """
    },
    %{
      # KNOWN-HARD. A schema/dispatch deletion whose prose quotes the planner
      # instruction it is deleting — which is itself about design.
      source:
        "task 019f9b29-e447 (ADR 0046 member 9) — title + description verbatim, first two paragraphs",
      known_hard: true,
      title: "Strip stage-level responsibility from the planning dispatch and Stage schema",
      description: """
      ADR 0046 — lands LAST, once nothing depends on it. This is the cleanup that makes the whole change worth doing.

      WHAT COMES OUT:
      - The planning dispatch template's instruction to author a "Design direction (Saru)" stage with `responsibility: "designer"` on the stage payload. Designer involvement now comes from the design step, not from a planner-authored stage — so the planner should no longer be told to tag it as a needful step.
      - `Stage.responsibility` and its resolution path.
      - `resolve_stage_dispatch_assignee/3` and its `:role_unresolvable` telemetry.\
      """
    },
    %{
      source: "task 019f9b11-3bde / PR #609",
      title: "Fix GitHub webhook signature bypass — enforce X-Hub-Signature-256",
      description: nil
    },
    %{
      source: "PR #588",
      title: "Move memory.dreaming cron to 05:00 America/Chicago",
      description: nil
    },
    %{
      source: "PR #608",
      title:
        "Fix task-id prefix collision that mis-attributed changelog rows and passed the wrong task's deploy gate",
      description: nil
    },
    %{
      source: "task 019f8837 M8",
      title: "Enforce per-org DM allowlist at create and send seams",
      description: nil
    },
    %{
      source: "PR #610",
      title: "Vault: gate rotate/delete on explicit access checks and retain access logs",
      description: nil
    },
    %{
      source: "PR #590",
      title:
        "fix(auth): request `groups` OIDC scope so external-user group claim is released (Pocket-ID)",
      description: nil
    },
    %{
      source: "task 019f9b14-26da / PR #607",
      title: "Scope MeetingLive's meeting lookup to the viewer's org",
      description: nil
    },
    %{
      source: "task 019f9b28 stage 2",
      title: "Replace camelised provider lookup with an explicit compile-time registry",
      description: nil
    },
    %{
      source: "task 019f9b28-6ca7 stage 1",
      title: "Collapse the two context materialisers onto one per-slot resolver",
      description: nil
    },
    %{
      source: "task 019f9b34-a23c / PR #606",
      title: "Stop tasks flipping to done before their deploy lands",
      description: nil
    },
    %{
      source: "task 019f9b28-ab82 stage 4",
      title: "Surface a failed planning gate at merge time",
      description: nil
    },
    %{
      source: "task 019f9b11-97d7 / PR #604",
      title: "Enforce the capability model on RuntimeChannel",
      description: nil
    }
  ]

  # The named positive control. An always-true implementation dies here, which
  # the ratio assertion alone would not guarantee.
  @named_negative_control "Fix fire_trigger/3 return contract to distinguish unfilled from failed"

  describe "error budget — false negatives" do
    test "zero false negatives across the entire :ui corpus" do
      false_negatives =
        for entry <- @ui_corpus, UiSurface.ui_task?(entry) == false do
          "#{entry.title} (#{entry.source})"
        end

      assert [] == false_negatives,
             """
             A false negative is a DEFECT, not a tuning outcome: the design step
             silently records `not_applicable`, indistinguishable from "no
             designer assigned". Fix the vocabulary in #{@module_path} — do NOT
             drop the corpus entry and do NOT widen the bound.

             Missed:
             #{Enum.map_join(false_negatives, "\n", &("  - " <> &1))}
             """
    end

    test "the path-token :ui entry is caught by layer A, not by prose" do
      entry = Enum.find(@ui_corpus, & &1[:path_token])

      assert {true, %{layer: :path_token, matched: ["PlanEngine.ui_touching?/1"]}} =
               UiSurface.ui_task?(entry)
    end
  end

  describe "error budget — false positives" do
    test "false positives on the :not_ui corpus stay at or under 25%" do
      fired =
        for entry <- @not_ui_corpus,
            {true, evidence} = _verdict <- [UiSurface.ui_task?(entry)],
            do: {entry.title, evidence}

      rate = length(fired) / length(@not_ui_corpus)

      assert rate <= @false_positive_cap,
             """
             False-positive rate #{Float.round(rate * 100, 1)}% exceeds the #{trunc(@false_positive_cap * 100)}% cap
             (#{length(fired)} of #{length(@not_ui_corpus)} non-UI entries fired).

             The cap is NOT the tunable part. Narrow the vocabulary in
             #{@module_path} instead — and never at the cost of a false negative.

             Fired:
             #{Enum.map_join(fired, "\n", fn {title, ev} -> "  - #{title} => #{ev.layer} #{inspect(ev.matched)}" end)}
             """
    end

    test "named positive control: a pure contract fix returns exactly false" do
      assert false ==
               UiSurface.ui_task?(%{title: @named_negative_control, description: nil}),
             "an always-true `ui_task?/1` must not survive this assertion"
    end

    test "the majority of the :not_ui corpus does not fire" do
      # Guards against the cap being met by a corpus that is mostly noise: at
      # least three quarters of these must come back a clean `false`.
      clean = Enum.count(@not_ui_corpus, &(UiSurface.ui_task?(&1) == false))
      assert clean >= 15, "only #{clean}/#{length(@not_ui_corpus)} non-UI entries came back false"
    end
  end

  describe "layer A is delegated, never copied" do
    test "the module source holds no copy of PlanEngine's path-token list" do
      source = File.read!(@module_path)

      for token <- [".heex", "assets/js/", "_web/live/"] do
        refute String.contains?(source, token),
               "#{@module_path} contains #{inspect(token)} — the path-token list has exactly one home, #{inspect(PlanEngine)}"
      end

      # Positive control for the grep above: a grep is satisfied by a rename as
      # easily as by a genuine delegation, so pin the seam itself.
      assert Code.ensure_loaded?(PlanEngine)
      assert function_exported?(PlanEngine, :ui_touching?, 1)
    end

    test "layer A tracks PlanEngine.ui_touching?/1 exactly, hit and miss" do
      probes = [
        "the markup lands in lib/platform_web/live/tasks_live.html.heex",
        "touches tasks_live.ex only",
        "rebuild assets/js/app.js",
        "restyle assets/css/app.css",
        "extend the compose_input hook",
        # near-misses PlanEngine deliberately does NOT match
        "restyle assets/img/logo.svg",
        "refactor lib/platform/tasks.ex",
        "regenerate priv/static/app.scss",
        "no paths at all in this sentence"
      ]

      for probe <- probes do
        expected = PlanEngine.ui_touching?(probe <> "\n")
        actual = match?({true, %{layer: :path_token}}, UiSurface.ui_task?(%{title: probe}))

        assert actual == expected,
               "layer A disagreed with PlanEngine.ui_touching?/1 on #{inspect(probe)} " <>
                 "(PlanEngine: #{expected}, UiSurface: #{actual}) — a private token copy has drifted"
      end
    end
  end

  describe "word-boundary matching" do
    test "cardinality, discard and scoreboard do not match card/board" do
      for text <- ["cardinality of the join", "discard the stale lease", "scoreboard rollup"] do
        assert false == UiSurface.ui_task?(%{title: text, description: nil}),
               "#{inspect(text)} matched a weak token on a substring"
      end
    end

    test "two distinct weak substring near-misses still do not fire" do
      assert false ==
               UiSurface.ui_task?(%{
                 title: "Discard the scoreboard cardinality estimate",
                 description: nil
               })
    end

    test "plural forms match — a missed plural would be a false negative" do
      assert {true, %{layer: :weak_prose, matched: matched}} =
               UiSurface.ui_task?(%{title: "segmented tabs and icons", description: nil})

      assert "tab" in matched
      assert "icon" in matched
    end

    test "a11y matches as a whole word and not as a fragment" do
      assert {true, %{layer: :weak_prose, matched: matched}} =
               UiSurface.ui_task?(%{title: "a11y audit of the nav", description: nil})

      assert "a11y" in matched
      assert false == UiSurface.ui_task?(%{title: "bump to a11yz-1 and reindex"})
    end

    test "hyphenated multiword tokens match across the hyphen" do
      for {text, token} <- [
            {"add a dark-mode palette", "dark-mode"},
            {"design the empty-state illustration", "empty-state"},
            {"raise the bottom-sheet on tap", "bottom-sheet"}
          ] do
        assert {true, %{layer: :strong_prose, matched: matched}} =
                 UiSurface.ui_task?(%{title: text, description: nil})

        assert token in matched, "#{inspect(text)} did not match #{inspect(token)}"
      end
    end

    test "spaced multiword phrases match" do
      assert {true, %{layer: :strong_prose, matched: matched}} =
               UiSurface.ui_task?(%{title: "Author a design direction canvas"})

      assert "design direction" in matched
    end
  end

  describe "two-list arithmetic" do
    test "one strong hit fires" do
      assert {true, %{layer: :strong_prose, matched: ["fab"]}} =
               UiSurface.ui_task?(%{title: "Add an epic-create FAB", description: nil})
    end

    test "one weak hit alone does not fire" do
      assert false == UiSurface.ui_task?(%{title: "Surface the failure at merge time"})
      assert false == UiSurface.ui_task?(%{title: "Collapse the two context materialisers"})
    end

    test "the same weak token twice is one hit, not two" do
      assert false ==
               UiSurface.ui_task?(%{title: "Render the prompt, then render it again"})
    end

    test "two DISTINCT weak hits fire" do
      assert {true, %{layer: :weak_prose, matched: matched}} =
               UiSurface.ui_task?(%{title: "Render the badge", description: nil})

      assert Enum.sort(matched) == ["badge", "render"]
    end
  end

  describe "input shapes" do
    test "nil description" do
      assert {true, %{layer: :strong_prose}} =
               UiSurface.ui_task?(%{title: "Mobile board polish", description: nil})
    end

    test "empty description" do
      assert {true, %{layer: :strong_prose}} =
               UiSurface.ui_task?(%{title: "Mobile board polish", description: ""})
    end

    test "absent description key" do
      assert {true, %{layer: :strong_prose}} = UiSurface.ui_task?(%{title: "Mobile board polish"})
    end

    test "title-only UI task still classifies as UI" do
      assert {true, _} = UiSurface.ui_task?(%{title: "Badges render as a mobile card"})
    end

    test "description-only signal still classifies" do
      assert {true, %{layer: :strong_prose}} =
               UiSurface.ui_task?(%{
                 title: "Follow-up from the audit",
                 description: "The empty state needs a real illustration."
               })
    end

    test "nil title and nil description are inert, not a crash" do
      assert false == UiSurface.ui_task?(%{title: nil, description: nil})
      assert false == UiSurface.ui_task?(%{})
    end

    test "accepts a Task struct" do
      task = %Platform.Tasks.Task{
        title: "Badges render as a mobile card",
        description: "Board cards need a stacked layout under 375px."
      }

      assert {true, _} = UiSurface.ui_task?(task)
    end
  end

  describe "matched payload" do
    test "matched names the tokens a human needs to audit the fire" do
      assert {true, %{layer: :strong_prose, matched: matched}} =
               UiSurface.ui_task?(%{
                 title: "Build /org_memory mobile surface — segmented tabs, path chip, drawer"
               })

      assert "mobile" in matched
    end

    test "matched is deduplicated" do
      {true, %{matched: matched}} =
        UiSurface.ui_task?(%{title: "mobile mobile mobile", description: "mobile"})

      assert matched == Enum.uniq(matched)
    end

    test "classification_text/1 is title newline description" do
      assert UiSurface.classification_text(%{title: "a", description: "b"}) == "a\nb"
      assert UiSurface.classification_text(%{title: "a", description: nil}) == "a\n"
    end

    test "vocabulary/0 exposes both lists with no overlap between them" do
      %{strong: strong, weak: weak} = UiSurface.vocabulary()

      refute Enum.empty?(strong)
      refute Enum.empty?(weak)

      assert [] == Enum.filter(strong, &(&1 in weak)),
             "a token in both lists makes the strong/weak distinction meaningless"
    end
  end
end
