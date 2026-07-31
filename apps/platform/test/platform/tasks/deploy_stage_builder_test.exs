defmodule Platform.Tasks.DeployStageBuilderTest do
  use ExUnit.Case, async: true

  alias Platform.Tasks.DeployStageBuilder

  describe "build_stage/2 — none" do
    test "returns :skip" do
      assert DeployStageBuilder.build_stage(%{"type" => "none"}, 3) == :skip
    end
  end

  # Bug #5 (task 019f708f): stack members with a live rollup branch
  # resolve to `no_op_wait_for_rollup`. `build_stage/2` must emit NO
  # stage — the stack sweep opens ONE rollup PR for the whole stack
  # via `StackDeployer.maybe_open_stack_pr/1`, so a per-member deploy
  # stage would either shatter the rollup (pr_merge) or dispatch a
  # deploy subagent with nothing to do.
  describe "build_stage/2 — no_op_wait_for_rollup (bug #5)" do
    test "returns :skip at any position" do
      assert DeployStageBuilder.build_stage(%{"type" => "no_op_wait_for_rollup"}, 3) == :skip
      assert DeployStageBuilder.build_stage(%{"type" => "no_op_wait_for_rollup"}, 99) == :skip
    end

    test "validate_strategy accepts no_op_wait_for_rollup" do
      assert :ok = DeployStageBuilder.validate_strategy(%{"type" => "no_op_wait_for_rollup"})
    end

    test "type appears in valid_strategy_types/0" do
      assert "no_op_wait_for_rollup" in DeployStageBuilder.valid_strategy_types()
    end
  end

  describe "build_stage/2 — pr_merge" do
    test "auto_merge false: emits a single pr_merged validation" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{
          "require_review_approval" => false,
          "auto_merge" => false
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 4)

      assert result.name == "Deploy: PR merge"
      assert result.position == 4
      assert result.validations == [%{kind: "pr_merged"}]
      assert result.description =~ "PR merge flow"
      assert result.description =~ "pr_merged validation"
      assert result.description =~ "Auto-merge is disabled"
      refute result.description =~ "manual_approval"
      refute result.description =~ "ci_passed"
    end

    test "auto_merge true: still emits a single pr_merged validation" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true, "merge_method" => "squash"}
      }

      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.validations == [%{kind: "pr_merged"}]
      assert result.description =~ "Auto-merge is enabled"
      assert result.description =~ "merge method: squash"
      refute result.description =~ "ci_check"
      refute result.description =~ "manual_approval"
    end

    test "auto_merge true defaults merge_method to squash" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true}
      }

      result = DeployStageBuilder.build_stage(strategy, 1)
      assert result.description =~ "merge method: squash"
    end

    test "description reflects require_review_approval" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"require_review_approval" => true}
      }

      result = DeployStageBuilder.build_stage(strategy, 1)
      assert result.description =~ "PR review approval is required"
    end

    test "works with empty config (defaults to single pr_merged validation)" do
      strategy = %{"type" => "pr_merge"}
      result = DeployStageBuilder.build_stage(strategy, 2)

      assert result.name == "Deploy: PR merge"
      assert result.position == 2
      # Always a single pr_merged validation regardless of auto_merge
      assert result.validations == [%{kind: "pr_merged"}]
    end
  end

  describe "build_stage/2 — docker_deploy" do
    test "returns stage with ci_passed and test_pass validations" do
      strategy = %{
        "type" => "docker_deploy",
        "config" => %{
          "host" => "dev@192.0.2.234",
          "image" => "ghcr.io/org/app:latest"
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 5)

      assert result.name == "Deploy: Docker deploy"
      assert result.position == 5
      assert result.validations == [%{kind: "ci_passed"}, %{kind: "test_pass"}]
      assert result.description =~ "Docker"
      assert result.description =~ "dev@192.0.2.234"
      assert result.description =~ "ghcr.io/org/app:latest"
    end

    test "works without host/image in config" do
      strategy = %{"type" => "docker_deploy", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.name == "Deploy: Docker deploy"
      assert result.validations == [%{kind: "ci_passed"}, %{kind: "test_pass"}]
      refute result.description =~ "Target host:"
      refute result.description =~ "Image:"
    end
  end

  describe "build_stage/2 — fly" do
    test "returns stage with ci_passed and test_pass validations" do
      strategy = %{
        "type" => "fly",
        "config" => %{"app" => "my-fly-app"}
      }

      result = DeployStageBuilder.build_stage(strategy, 3)

      assert result.name == "Deploy: Fly deploy"
      assert result.position == 3
      assert result.validations == [%{kind: "ci_passed"}, %{kind: "test_pass"}]
      assert result.description =~ "Fly.io"
      assert result.description =~ "my-fly-app"
    end

    test "works without app in config" do
      strategy = %{"type" => "fly", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.name == "Deploy: Fly deploy"
      refute result.description =~ "Fly app:"
    end
  end

  describe "build_stage/2 — skill_driven" do
    test "returns stage with manual_approval validation" do
      strategy = %{
        "type" => "skill_driven",
        "skill_id" => "abc-123",
        "config" => %{}
      }

      result = DeployStageBuilder.build_stage(strategy, 3)

      assert result.name == "Deploy: Skill execution"
      assert result.position == 3
      assert result.validations == [%{kind: "manual_approval"}]
      assert result.description =~ "abc-123"
    end

    test "handles missing skill_id" do
      strategy = %{"type" => "skill_driven", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.description =~ "No skill ID specified"
    end

    test "includes additional context from config" do
      strategy = %{
        "type" => "skill_driven",
        "config" => %{"context" => "Deploy to staging first"}
      }

      result = DeployStageBuilder.build_stage(strategy, 1)
      assert result.description =~ "Deploy to staging first"
    end
  end

  describe "build_stage/2 — manual" do
    test "returns stage with manual_approval validation" do
      strategy = %{"type" => "manual"}
      result = DeployStageBuilder.build_stage(strategy, 2)

      assert result.name == "Deploy: Manual"
      assert result.position == 2
      assert result.validations == [%{kind: "manual_approval"}]
      assert result.description =~ "Manual deployment"
    end
  end

  describe "build_stage/2 — project_files" do
    test "returns stage with test_pass validation and description mentions the folder" do
      strategy = %{
        "type" => "project_files",
        "config" => %{
          "project_id" => "019f0000-0000-7000-8000-000000000000",
          "folder" => "Deliverables",
          "deliverable_canvas_id" => "019f0000-0000-7000-8000-000000000001"
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 3)

      assert result.name == "Deploy: Project files"
      assert result.position == 3
      assert result.validations == [%{kind: "test_pass"}]
      assert result.description =~ "Files module"
      assert result.description =~ "Deliverables"
      assert result.description =~ "019f0000-0000-7000-8000-000000000000"
      assert result.description =~ "019f0000-0000-7000-8000-000000000001"
      refute result.description =~ "manual_approval"
      refute result.description =~ "ci_passed"
    end

    test "defaults folder to Deliverables when config omits it" do
      strategy = %{"type" => "project_files", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.name == "Deploy: Project files"
      assert result.validations == [%{kind: "test_pass"}]
      assert result.description =~ "Deliverables"
      # No explicit canvas → falls back to newest exec-space canvas
      assert result.description =~ "newest canvas in the task's execution space"
    end

    test "works with empty strategy (no config key)" do
      strategy = %{"type" => "project_files"}
      result = DeployStageBuilder.build_stage(strategy, 2)

      assert result.name == "Deploy: Project files"
      assert result.position == 2
      assert result.validations == [%{kind: "test_pass"}]
    end
  end

  describe "build_stage/2 — position" do
    test "uses the provided position for all strategy types" do
      for {type, pos} <- [
            {"pr_merge", 1},
            {"docker_deploy", 7},
            {"fly", 10},
            {"manual", 42},
            {"project_files", 6}
          ] do
        result = DeployStageBuilder.build_stage(%{"type" => type}, pos)
        assert result.position == pos, "Expected position #{pos} for type #{type}"
      end
    end
  end

  describe "validate_strategy/1" do
    test "returns :ok for all valid strategy types" do
      for type <- DeployStageBuilder.valid_strategy_types() do
        assert :ok == DeployStageBuilder.validate_strategy(%{"type" => type}),
               "Expected :ok for type #{type}"
      end
    end

    test "returns error for unknown type" do
      assert {:error, msg} = DeployStageBuilder.validate_strategy(%{"type" => "bogus"})
      assert msg =~ "unknown strategy type"
      assert msg =~ "bogus"
    end

    test "returns error when type key is missing" do
      assert {:error, _} = DeployStageBuilder.validate_strategy(%{})
    end

    test "returns error for non-map input" do
      assert {:error, _} = DeployStageBuilder.validate_strategy("not a map")
    end
  end

  # A `pr_merge` strategy may declare the repository set the task lands
  # in — the only place in the system where that fact can be stated,
  # since a task carries a `project_id` and the project carries exactly
  # one `repo_url`.
  describe "validate_strategy/1 — pr_merge repo set" do
    test "accepts a valid two-repo set" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => false},
        "repos" => [
          %{"repo_url" => "https://github.com/Startup-Suite/core", "ci" => "required"},
          %{"repo_url" => "Startup-Suite/claude-code-suite-channel", "ci" => "none"}
        ]
      }

      assert :ok == DeployStageBuilder.validate_strategy(strategy)
    end

    test "accepts an entry with no explicit ci (defaults to required)" do
      strategy = %{
        "type" => "pr_merge",
        "repos" => [%{"repo_url" => "Startup-Suite/core"}]
      }

      assert :ok == DeployStageBuilder.validate_strategy(strategy)
    end

    test "a pr_merge strategy with no repos key is still valid" do
      assert :ok == DeployStageBuilder.validate_strategy(%{"type" => "pr_merge"})
      assert :ok == DeployStageBuilder.validate_strategy(%{"type" => "pr_merge", "config" => %{}})
    end

    test "refuses an unrecognizable repo_url, naming the index and the value" do
      strategy = %{
        "type" => "pr_merge",
        "repos" => [
          %{"repo_url" => "https://github.com/Startup-Suite/core"},
          %{"repo_url" => "not a repo"}
        ]
      }

      assert {:error, msg} = DeployStageBuilder.validate_strategy(strategy)
      assert msg =~ "repos[1].repo_url is not a recognizable GitHub repository"
      assert msg =~ "not a repo"
    end

    test "refuses a missing repo_url" do
      strategy = %{"type" => "pr_merge", "repos" => [%{"ci" => "required"}]}

      assert {:error, msg} = DeployStageBuilder.validate_strategy(strategy)
      assert msg =~ "repos[0].repo_url"
    end

    test "refuses an unknown ci state" do
      strategy = %{
        "type" => "pr_merge",
        "repos" => [%{"repo_url" => "Startup-Suite/core", "ci" => "optional"}]
      }

      assert {:error, msg} = DeployStageBuilder.validate_strategy(strategy)
      assert msg =~ "Startup-Suite/core"
      assert msg =~ "invalid ci"
      assert msg =~ "optional"
    end

    test "refuses an empty repos list rather than reading it as no-repos" do
      assert {:error, msg} =
               DeployStageBuilder.validate_strategy(%{"type" => "pr_merge", "repos" => []})

      assert msg =~ "non-empty"
    end

    test "refuses a non-list repos value" do
      assert {:error, _} =
               DeployStageBuilder.validate_strategy(%{
                 "type" => "pr_merge",
                 "repos" => "Startup-Suite/core"
               })
    end

    test "refuses a non-map entry" do
      assert {:error, msg} =
               DeployStageBuilder.validate_strategy(%{
                 "type" => "pr_merge",
                 "repos" => ["Startup-Suite/core"]
               })

      assert msg =~ "repos[0] must be a map"
    end

    # The honest refusal: refuse the CONFIG that is a fiction, not the
    # task. `Startup-Suite/claude-code-suite-channel` has zero workflows
    # and an unprotected `main`, so a CLEAN mergeStateStatus there means
    # zero checks ran — auto_merge has nothing to wait for.
    test "refuses auto_merge: true on a ci: none repo, naming the repo" do
      strategy = %{
        "type" => "pr_merge",
        "repos" => [
          %{
            "repo_url" => "https://github.com/Startup-Suite/claude-code-suite-channel",
            "ci" => "none",
            "config" => %{"auto_merge" => true}
          }
        ]
      }

      assert {:error, msg} = DeployStageBuilder.validate_strategy(strategy)
      assert msg =~ "auto_merge is not expressible for Startup-Suite/claude-code-suite-channel"
      assert msg =~ "zero checks ran, not checks passed"
    end

    test "refuses strategy-level auto_merge inherited onto a ci: none repo" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true},
        "repos" => [
          %{"repo_url" => "Startup-Suite/core", "ci" => "required"},
          %{"repo_url" => "Startup-Suite/openclaw-suite-channel", "ci" => "none"}
        ]
      }

      assert {:error, msg} = DeployStageBuilder.validate_strategy(strategy)
      assert msg =~ "Startup-Suite/openclaw-suite-channel"
    end

    test "allows a ci: none repo to opt out of an inherited auto_merge" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true},
        "repos" => [
          %{"repo_url" => "Startup-Suite/core", "ci" => "required"},
          %{
            "repo_url" => "Startup-Suite/openclaw-suite-channel",
            "ci" => "none",
            "config" => %{"auto_merge" => false}
          }
        ]
      }

      assert :ok == DeployStageBuilder.validate_strategy(strategy)
    end

    test "refuses require_ci_pass: true on a ci: none repo" do
      strategy = %{
        "type" => "pr_merge",
        "repos" => [
          %{
            "repo_url" => "Startup-Suite/openclaw-suite-channel",
            "ci" => "none",
            "config" => %{"require_ci_pass" => true}
          }
        ]
      }

      assert {:error, msg} = DeployStageBuilder.validate_strategy(strategy)
      assert msg =~ "require_ci_pass is not expressible for Startup-Suite/openclaw-suite-channel"
    end

    # `ci: "none"` and `require_ci_pass: false` are DIFFERENT facts —
    # "there is no CI to gate on" vs "there is CI and we choose not to
    # gate". Both are storable; neither collapses into the other.
    test "auto_merge: true is fine on a ci: required repo" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true},
        "repos" => [%{"repo_url" => "Startup-Suite/core", "ci" => "required"}]
      }

      assert :ok == DeployStageBuilder.validate_strategy(strategy)
    end

    test "require_ci_pass: false is fine on a ci: none repo" do
      strategy = %{
        "type" => "pr_merge",
        "repos" => [
          %{
            "repo_url" => "Startup-Suite/openclaw-suite-channel",
            "ci" => "none",
            "config" => %{"require_ci_pass" => false, "auto_merge" => false}
          }
        ]
      }

      assert :ok == DeployStageBuilder.validate_strategy(strategy)
      assert DeployStageBuilder.valid_repo_ci_states() == ["required", "none"]
    end

    # Stage 1 pinned the inverse of this ("declaring a repo set changes
    # NOTHING about the stage that gets built") as its own boundary marker.
    # Stage 2 IS the boundary move: a declared repo set now changes the
    # stage. The assertion is kept, flipped, rather than deleted, so the
    # transition is visible in the file's history.
    test "build_stage/2 IS changed by the presence of a repo set" do
      with_repos =
        DeployStageBuilder.build_stage(
          %{
            "type" => "pr_merge",
            "config" => %{},
            "repos" => [
              %{"repo_url" => "Startup-Suite/core"},
              %{"repo_url" => "Startup-Suite/openclaw-suite-channel", "ci" => "none"}
            ]
          },
          4
        )

      without = DeployStageBuilder.build_stage(%{"type" => "pr_merge", "config" => %{}}, 4)

      refute with_repos == without
      assert length(with_repos.validations) == 2
      assert without.validations == [%{kind: "pr_merged"}]
    end
  end

  # ── One `pr_merged` gate per resolved repository ────────────────────────
  #
  # `PlanEngine.stage_verdict/1` already requires EVERY validation on a
  # stage to be `passed` before the stage advances, so N gates gives
  # all-must-merge with no engine change — and, more importantly, makes
  # the partial state a row you can look at (one `passed`, one `pending`)
  # instead of a counter hidden inside a single gate that is neither.
  describe "build_stage/2 — pr_merge repo-scoped gates" do
    @core %{
      "repo_url" => "https://github.com/Startup-Suite/core",
      "slug" => "Startup-Suite/core",
      "ci" => "required",
      "role" => "primary",
      "config" => %{}
    }

    @channel %{
      "repo_url" => "https://github.com/Startup-Suite/claude-code-suite-channel",
      "slug" => "Startup-Suite/claude-code-suite-channel",
      "ci" => "none",
      "role" => "secondary",
      "config" => %{"auto_merge" => false}
    }

    test "a one-repo set emits exactly ONE pr_merged, carrying that repo's identity" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"require_review_approval" => false, "auto_merge" => false},
        "repos" => [@core]
      }

      result = DeployStageBuilder.build_stage(strategy, 4)

      # Everything the unscoped stage asserted still holds.
      assert result.name == "Deploy: PR merge"
      assert result.position == 4
      assert result.description =~ "PR merge flow"
      assert result.description =~ "pr_merged"
      assert result.description =~ "Auto-merge is disabled — a human merges the PR via GitHub"
      refute result.description =~ "manual_approval"
      refute result.description =~ "ci_passed"

      # Regression 019fa63a. A ONE-repo set reads exactly as an undeclared
      # repo set does — one repository is one repository however the set was
      # arrived at. This assertion used to expect the enumerating renderer's
      # per-repo sentence ("Startup-Suite/core: CI is required…; auto-merge
      # is disabled…"), which is how the enumerating text reached every
      # ordinary task once `PlanEngine` started resolving the repo set:
      # `resolve_deploy_strategy_with_repos/1` synthesizes a one-entry list
      # from `project.repo_url`, so "one declared repo" became the shape
      # EVERY task has. Pinned as an equality, not a substring, so nothing
      # can satisfy it by appending single-repo phrasing to enumerated text.
      assert result.description ==
               DeployStageBuilder.build_stage(Map.delete(strategy, "repos"), 4).description,
             "a one-repo set must render the same description as no declared repo set"

      refute result.description =~ "This deploy covers"
      refute result.description =~ "is a partial deploy"

      # ...and the single gate now names the repository it watches.
      assert [validation] = result.validations
      assert validation.kind == "pr_merged"

      assert validation.evaluation_payload == %{
               "repo" => "Startup-Suite/core",
               "repo_url" => "https://github.com/Startup-Suite/core",
               "ci" => "required",
               "auto_merge" => false,
               "merge_method" => "squash"
             }
    end

    test "a two-repo set emits TWO pr_merged gates, in declaration order" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => false},
        "repos" => [@core, @channel]
      }

      result = DeployStageBuilder.build_stage(strategy, 7)

      assert length(result.validations) == 2
      assert Enum.all?(result.validations, &(&1.kind == "pr_merged"))

      assert Enum.map(result.validations, & &1.evaluation_payload["repo"]) == [
               "Startup-Suite/core",
               "Startup-Suite/claude-code-suite-channel"
             ]

      # Reversing the declaration reverses the gates — the order is the
      # declared order, not an incidental sort.
      reversed =
        DeployStageBuilder.build_stage(%{strategy | "repos" => [@channel, @core]}, 7)

      assert Enum.map(reversed.validations, & &1.evaluation_payload["repo"]) == [
               "Startup-Suite/claude-code-suite-channel",
               "Startup-Suite/core"
             ]
    end

    test "the description enumerates every repository in the set" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core, @channel]},
          1
        )

      assert result.description =~ "Startup-Suite/core"
      assert result.description =~ "Startup-Suite/claude-code-suite-channel"
      # And says plainly that ALL of them must merge — one passed gate is
      # not a deploy.
      assert result.description =~ "2 repositories"
      assert result.description =~ "per repository"
    end

    test "a ci: none entry carries auto_merge false regardless of strategy-level auto_merge" do
      # `validate_strategy/1` refuses this combination at write time, but a
      # raw write can still produce it — and the payload must not record an
      # auto-merge that has nothing to wait for.
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true, "merge_method" => "rebase"},
        "repos" => [
          @core,
          %{
            "repo_url" => "https://github.com/Startup-Suite/openclaw-suite-channel",
            "slug" => "Startup-Suite/openclaw-suite-channel",
            "ci" => "none",
            "role" => "secondary",
            "config" => %{"auto_merge" => true}
          }
        ]
      }

      result = DeployStageBuilder.build_stage(strategy, 1)

      [core_gate, channel_gate] = result.validations

      assert core_gate.evaluation_payload["auto_merge"] == true
      assert core_gate.evaluation_payload["merge_method"] == "rebase"

      assert channel_gate.evaluation_payload["ci"] == "none"

      assert channel_gate.evaluation_payload["auto_merge"] == false,
             "a repo with zero required checks has nothing for auto-merge to wait for"
    end

    test "the description says plainly what CLEAN means on a ci: none repo" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core, @channel]},
          1
        )

      assert result.description =~
               "Startup-Suite/claude-code-suite-channel has no required status checks"

      assert result.description =~ "a CLEAN merge state means zero checks ran, not checks passed"
      assert result.description =~ "merged by hand; a human must look at it"

      # The sentence is about the ci: none repo ONLY — it must not be
      # attached to the repo that does have checks.
      refute result.description =~ "Startup-Suite/core has no required status checks"
    end

    # `Tasks.resolve_deploy_repos/1` KEEPS a declared entry whose
    # `repo_url` will not normalize, with `slug: nil`, rather than dropping
    # it. Dropping it would shrink the repo set back to the bug this
    # feature exists to fix: a gate that can never match is a task that
    # hangs, which is visible; a dropped repo is a task that reports a
    # success it did not earn, which is not.
    test "an unresolvable declared repo still gets a gate, with a nil repo identity" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{},
        "repos" => [
          @core,
          %{
            "repo_url" => "not a repo",
            "slug" => nil,
            "ci" => "required",
            "role" => "secondary",
            "config" => %{}
          }
        ]
      }

      result = DeployStageBuilder.build_stage(strategy, 1)

      assert length(result.validations) == 2,
             "an unresolvable repo must not be silently dropped from the gate set"

      [_core_gate, unresolved] = result.validations
      assert unresolved.kind == "pr_merged"

      assert unresolved.evaluation_payload["repo"] == nil,
             "a nil slug must stay nil so nothing can match this gate by accident"

      assert unresolved.evaluation_payload["repo_url"] == "not a repo"
      assert result.description =~ "not a repo"
      assert result.description =~ "did not resolve to a GitHub owner/name"
    end

    test "derives the slug when an entry carries only repo_url" do
      # The normalized shape written by `resolve_deploy_strategy_with_repos/1`
      # always carries `"slug"`, but a hand-written strategy map (the shape
      # `validate_strategy/1` accepts) does not.
      result =
        DeployStageBuilder.build_stage(
          %{
            "type" => "pr_merge",
            "config" => %{},
            "repos" => [%{"repo_url" => "git@github.com:Startup-Suite/core.git"}]
          },
          1
        )

      assert [gate] = result.validations
      assert gate.evaluation_payload["repo"] == "Startup-Suite/core"
      assert gate.evaluation_payload["ci"] == "required"
    end

    test "a per-entry config overrides the strategy-level config in the payload" do
      result =
        DeployStageBuilder.build_stage(
          %{
            "type" => "pr_merge",
            "config" => %{"auto_merge" => true, "merge_method" => "squash"},
            "repos" => [
              %{"repo_url" => "Startup-Suite/core"},
              %{
                "repo_url" => "Startup-Suite/wiki-infra",
                "config" => %{"merge_method" => "merge", "auto_merge" => false}
              }
            ]
          },
          1
        )

      [core_gate, wiki_gate] = result.validations

      assert core_gate.evaluation_payload["auto_merge"] == true
      assert core_gate.evaluation_payload["merge_method"] == "squash"
      assert wiki_gate.evaluation_payload["auto_merge"] == false
      assert wiki_gate.evaluation_payload["merge_method"] == "merge"
    end

    # BACKWARD-COMPAT PIN. `resolve_deploy_strategy_with_repos/1` leaves
    # `"repos"` ABSENT (not `[]`) when the set resolves empty, precisely so
    # that "nothing was declared" keeps meaning today's single unscoped
    # gate. Every caller not yet routed through the new helper lands here.
    test "a strategy with no repos key is byte-identical to today's output" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"require_review_approval" => false, "auto_merge" => false}
      }

      result = DeployStageBuilder.build_stage(strategy, 4)

      assert result.validations == [%{kind: "pr_merged"}],
             "an undeclared repo set must still emit exactly one unscoped gate, " <>
               "with NO evaluation_payload key at all"

      assert result.name == "Deploy: PR merge"
      assert result.position == 4
      refute result.description =~ "repositories"
    end

    # The failure mode `resolve_deploy_strategy_with_repos/1` refuses to
    # create, defended a second time at the consumer: a deploy stage with
    # ZERO validations is `:all_passed` per `PlanEngine.stage_verdict/1`,
    # i.e. it auto-passes. Nothing may produce one.
    test "a present-but-empty repos list never yields a validation-free stage" do
      result = DeployStageBuilder.build_stage(%{"type" => "pr_merge", "repos" => []}, 1)

      refute result.validations == [],
             "a deploy stage with zero validations auto-passes (stage_verdict/1 " <>
               "returns :all_passed for []) — an empty repo set must never build one"

      assert result.validations == [%{kind: "pr_merged"}]
    end

    test "every emitted gate is a pr_merged — no other kind leaks in" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core, @channel]},
          1
        )

      assert Enum.map(result.validations, & &1.kind) == ["pr_merged", "pr_merged"]
    end
  end

  # Task 019fa469 stage 2: `Platform.Orchestration.DispatchPhase` uses
  # `deploy_stage_name?/1` to recognise a system-injected deploy stage,
  # because three of the six stage-producing strategies emit validation kinds
  # (`manual_approval`, `test_pass`) that are indistinguishable from a review
  # or implementation stage. If a new strategy ever mints a name outside the
  # prefix, those deploy dispatches would silently route to the wrong template
  # — so assert the invariant over EVERY valid strategy type rather than over
  # a hand-listed subset.
  describe "deploy_stage_name?/1 — the prefix invariant DispatchPhase relies on" do
    test "every strategy that builds a stage names it with the deploy prefix" do
      built =
        for type <- DeployStageBuilder.valid_strategy_types(),
            stage = DeployStageBuilder.build_stage(%{"type" => type, "config" => %{}}, 3),
            stage != :skip do
          assert DeployStageBuilder.deploy_stage_name?(stage.name),
                 "strategy #{type} minted stage name #{inspect(stage.name)} which does not " <>
                   "start with #{inspect(DeployStageBuilder.deploy_stage_name_prefix())} — " <>
                   "DispatchPhase would misroute its deploy dispatch"

          type
        end

      # Guard the guard: if `build_stage/2` ever starts returning `:skip` for
      # everything the loop above would be vacuously true.
      assert length(built) >= 5,
             "expected most strategies to build a stage, got #{inspect(built)}"
    end

    test "is an exact prefix match, not a substring search" do
      # `TaskRouter.infer_stage_type/1` downcases and calls `String.contains?`
      # on the same field; that is the defect class this predicate replaces.
      refute DeployStageBuilder.deploy_stage_name?("Rework the deploy strategy resolver")
      refute DeployStageBuilder.deploy_stage_name?("deploy: pr merge")
      refute DeployStageBuilder.deploy_stage_name?("Redeploy: PR merge")
      refute DeployStageBuilder.deploy_stage_name?(nil)
      assert DeployStageBuilder.deploy_stage_name?("Deploy: PR merge")
    end
  end

  describe "valid_merge_method?/1" do
    test "returns true for squash, merge, rebase" do
      assert DeployStageBuilder.valid_merge_method?("squash")
      assert DeployStageBuilder.valid_merge_method?("merge")
      assert DeployStageBuilder.valid_merge_method?("rebase")
    end

    test "returns false for unknown method" do
      refute DeployStageBuilder.valid_merge_method?("fast-forward")
      refute DeployStageBuilder.valid_merge_method?("")
    end
  end
end
