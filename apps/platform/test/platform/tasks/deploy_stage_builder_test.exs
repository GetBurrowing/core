defmodule Platform.Tasks.DeployStageBuilderTest do
  # DB-backed since task 019fba18 stage 1: the recorded-branch tests build
  # REAL task rows with pinned ids so the value the gate records is the value
  # a task in the database produces, not a value a hand-built struct produces.
  # Everything else in this file stays a pure map → map assertion.
  use Platform.DataCase, async: true

  alias Platform.Tasks
  alias Platform.Tasks.DeployStageBuilder
  alias Platform.Tasks.StackDeployer
  alias Platform.Tasks.Stacks
  alias Platform.Tasks.Task

  # The branch every scoped `pr_merged` gate records. A literal here, not
  # `StackDeployer.member_branch_for/1`: these tests assert what the builder
  # WRITES, so the input must be a value this file controls outright.
  @recorded_branch "task/019fba18-d074-7185-8e0e-032ee6d02fbe"

  describe "build_stage/3 — none" do
    test "returns :skip" do
      assert DeployStageBuilder.build_stage(%{"type" => "none"}, 3, @recorded_branch) == :skip
    end
  end

  # Bug #5 (task 019f708f): stack members with a live rollup branch
  # resolve to `no_op_wait_for_rollup`. `build_stage/3` must emit NO
  # stage — the stack sweep opens ONE rollup PR for the whole stack
  # via `StackDeployer.maybe_open_stack_pr/1`, so a per-member deploy
  # stage would either shatter the rollup (pr_merge) or dispatch a
  # deploy subagent with nothing to do.
  describe "build_stage/3 — no_op_wait_for_rollup (bug #5)" do
    test "returns :skip at any position" do
      assert DeployStageBuilder.build_stage(
               %{"type" => "no_op_wait_for_rollup"},
               3,
               @recorded_branch
             ) ==
               :skip

      assert DeployStageBuilder.build_stage(
               %{"type" => "no_op_wait_for_rollup"},
               99,
               @recorded_branch
             ) ==
               :skip
    end

    test "validate_strategy accepts no_op_wait_for_rollup" do
      assert :ok = DeployStageBuilder.validate_strategy(%{"type" => "no_op_wait_for_rollup"})
    end

    test "type appears in valid_strategy_types/0" do
      assert "no_op_wait_for_rollup" in DeployStageBuilder.valid_strategy_types()
    end
  end

  describe "build_stage/3 — pr_merge" do
    test "auto_merge false: emits a single pr_merged validation" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{
          "require_review_approval" => false,
          "auto_merge" => false
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 4, @recorded_branch)

      assert result.name == "Deploy: PR merge"
      assert result.position == 4
      assert result.validations == [%{kind: "pr_merged"}]
      assert result.description =~ "PR merge flow"
      assert result.description =~ "pr_merged validation"
      assert result.description =~ "Strategy config declares auto_merge: false"
      assert result.description =~ "merges the PR by hand via GitHub"
      refute result.description =~ "will be merged automatically"
      refute result.description =~ "manual_approval"
      refute result.description =~ "ci_passed"
    end

    test "auto_merge true: still emits a single pr_merged validation" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true, "merge_method" => "squash"}
      }

      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)

      assert result.validations == [%{kind: "pr_merged"}]
      assert result.description =~ "Strategy config declares auto_merge: true"
      assert result.description =~ "merge method: squash"
      # 01a08d81: `auto_merge: true` is a declaration, not an armed state. The
      # description must send a distrusting reader to the check whose safe
      # branch is the hand-merge, never assert the merge will happen by itself.
      assert result.description =~ "That is a declaration, not an armed state"
      assert result.description =~ "gh pr view <n> --json autoMergeRequest"
      assert result.description =~ "merge by hand and verify `mergedAt`"
      refute result.description =~ "will be merged automatically"
      refute result.description =~ "Auto-merge is enabled"
      refute result.description =~ "ci_check"
      refute result.description =~ "manual_approval"
    end

    test "auto_merge true defaults merge_method to squash" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true}
      }

      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)
      assert result.description =~ "merge method: squash"
    end

    test "description reflects require_review_approval" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"require_review_approval" => true}
      }

      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)
      assert result.description =~ "PR review approval is required"
    end

    test "works with empty config (defaults to single pr_merged validation)" do
      strategy = %{"type" => "pr_merge"}
      result = DeployStageBuilder.build_stage(strategy, 2, @recorded_branch)

      assert result.name == "Deploy: PR merge"
      assert result.position == 2
      # Always a single pr_merged validation regardless of auto_merge
      assert result.validations == [%{kind: "pr_merged"}]
    end
  end

  describe "build_stage/3 — docker_deploy" do
    test "returns stage with ci_passed and test_pass validations" do
      strategy = %{
        "type" => "docker_deploy",
        "config" => %{
          "host" => "dev@192.0.2.234",
          "image" => "ghcr.io/org/app:latest"
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 5, @recorded_branch)

      assert result.name == "Deploy: Docker deploy"
      assert result.position == 5
      assert result.validations == [%{kind: "ci_passed"}, %{kind: "test_pass"}]
      assert result.description =~ "Docker"
      assert result.description =~ "dev@192.0.2.234"
      assert result.description =~ "ghcr.io/org/app:latest"
    end

    test "works without host/image in config" do
      strategy = %{"type" => "docker_deploy", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)

      assert result.name == "Deploy: Docker deploy"
      assert result.validations == [%{kind: "ci_passed"}, %{kind: "test_pass"}]
      refute result.description =~ "Target host:"
      refute result.description =~ "Image:"
    end
  end

  describe "build_stage/3 — fly" do
    test "returns stage with ci_passed and test_pass validations" do
      strategy = %{
        "type" => "fly",
        "config" => %{"app" => "my-fly-app"}
      }

      result = DeployStageBuilder.build_stage(strategy, 3, @recorded_branch)

      assert result.name == "Deploy: Fly deploy"
      assert result.position == 3
      assert result.validations == [%{kind: "ci_passed"}, %{kind: "test_pass"}]
      assert result.description =~ "Fly.io"
      assert result.description =~ "my-fly-app"
    end

    test "works without app in config" do
      strategy = %{"type" => "fly", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)

      assert result.name == "Deploy: Fly deploy"
      refute result.description =~ "Fly app:"
    end
  end

  describe "build_stage/3 — skill_driven" do
    test "returns stage with manual_approval validation" do
      strategy = %{
        "type" => "skill_driven",
        "skill_id" => "abc-123",
        "config" => %{}
      }

      result = DeployStageBuilder.build_stage(strategy, 3, @recorded_branch)

      assert result.name == "Deploy: Skill execution"
      assert result.position == 3
      assert result.validations == [%{kind: "manual_approval"}]
      assert result.description =~ "abc-123"
    end

    test "handles missing skill_id" do
      strategy = %{"type" => "skill_driven", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)

      assert result.description =~ "No skill ID specified"
    end

    test "includes additional context from config" do
      strategy = %{
        "type" => "skill_driven",
        "config" => %{"context" => "Deploy to staging first"}
      }

      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)
      assert result.description =~ "Deploy to staging first"
    end
  end

  describe "build_stage/3 — manual" do
    test "returns stage with manual_approval validation" do
      strategy = %{"type" => "manual"}
      result = DeployStageBuilder.build_stage(strategy, 2, @recorded_branch)

      assert result.name == "Deploy: Manual"
      assert result.position == 2
      assert result.validations == [%{kind: "manual_approval"}]
      assert result.description =~ "Manual deployment"
    end
  end

  describe "build_stage/3 — project_files" do
    test "returns stage with test_pass validation and description mentions the folder" do
      strategy = %{
        "type" => "project_files",
        "config" => %{
          "project_id" => "019f0000-0000-7000-8000-000000000000",
          "folder" => "Deliverables",
          "deliverable_canvas_id" => "019f0000-0000-7000-8000-000000000001"
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 3, @recorded_branch)

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
      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)

      assert result.name == "Deploy: Project files"
      assert result.validations == [%{kind: "test_pass"}]
      assert result.description =~ "Deliverables"
      # No explicit canvas → falls back to newest exec-space canvas
      assert result.description =~ "newest canvas in the task's execution space"
    end

    test "works with empty strategy (no config key)" do
      strategy = %{"type" => "project_files"}
      result = DeployStageBuilder.build_stage(strategy, 2, @recorded_branch)

      assert result.name == "Deploy: Project files"
      assert result.position == 2
      assert result.validations == [%{kind: "test_pass"}]
    end
  end

  describe "build_stage/3 — email (task 01a0cf21 stage 6)" do
    test "one test_pass validation, named Deploy: Email, describing account/sender/recipients" do
      strategy = %{
        "type" => "email",
        "config" => %{
          "account_id" => "019f0000-0000-7000-8000-0000000000aa",
          "sender_key" => "reports",
          "recipients" => ["a@example.test", "b@example.test"],
          "recipient_user_ids" => ["019f0000-0000-7000-8000-0000000000bb"]
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 4, @recorded_branch)

      assert result.name == "Deploy: Email"
      assert result.position == 4
      assert result.validations == [%{kind: "test_pass"}]
      assert result.description =~ "019f0000-0000-7000-8000-0000000000aa"
      assert result.description =~ "Sender key: reports."
      assert result.description =~ "Recipients: 3."
      assert result.description =~ "do NOT push evidence"
      refute result.description =~ "manual_approval"
    end

    test "with no strategy-level config it points at the task's deploy_target_config" do
      result = DeployStageBuilder.build_stage(%{"type" => "email"}, 2, @recorded_branch)

      assert result.name == "Deploy: Email"
      assert result.validations == [%{kind: "test_pass"}]
      assert result.description =~ "deploy_target_config"
    end
  end

  describe "validate_strategy/1 — email (task 01a0cf21 stage 6)" do
    test "email is a registered strategy type" do
      assert "email" in DeployStageBuilder.valid_strategy_types()
      assert :ok = DeployStageBuilder.validate_strategy(%{"type" => "email"})
    end

    test "accepts a string-valued config and refuses a malformed one, without the database" do
      assert :ok =
               DeployStageBuilder.validate_strategy(%{
                 "type" => "email",
                 "config" => %{"account_id" => "any-string", "sender_key" => "ops"}
               })

      assert {:error, msg} =
               DeployStageBuilder.validate_strategy(%{"type" => "email", "config" => "nope"})

      assert msg =~ "map"

      assert {:error, msg} =
               DeployStageBuilder.validate_strategy(%{
                 "type" => "email",
                 "config" => %{"account_id" => 7}
               })

      assert msg =~ "account_id"

      assert {:error, msg} =
               DeployStageBuilder.validate_strategy(%{
                 "type" => "email",
                 "config" => %{"sender_key" => ["x"]}
               })

      assert msg =~ "sender_key"
    end
  end

  describe "build_stage/3 — position" do
    test "uses the provided position for all strategy types" do
      for {type, pos} <- [
            {"pr_merge", 1},
            {"docker_deploy", 7},
            {"fly", 10},
            {"manual", 42},
            {"project_files", 6},
            {"email", 9}
          ] do
        result = DeployStageBuilder.build_stage(%{"type" => type}, pos, @recorded_branch)
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

    # `ci: "unenforced"` (Stark Industries/orion's actual live state:
    # `gh api repos/Stark Industries/orion/branches/main` reports
    # `protected: false`, `required_status_checks.contexts: []`, while its
    # CI workflows genuinely run and pass) mirrors `ci: "none"` here for the
    # same reason: nothing is REQUIRED, so nothing exists for auto-merge or
    # a CI gate to wait on, whether or not checks happen to run.
    test "refuses auto_merge: true on a ci: unenforced repo, naming the repo" do
      strategy = %{
        "type" => "pr_merge",
        "repos" => [
          %{
            "repo_url" => "https://github.com/Stark Industries/orion",
            "ci" => "unenforced",
            "config" => %{"auto_merge" => true}
          }
        ]
      }

      assert {:error, msg} = DeployStageBuilder.validate_strategy(strategy)
      assert msg =~ "auto_merge is not expressible for Stark Industries/orion"
      assert msg =~ "nothing was required to pass, not that checks passed"
    end

    test "refuses require_ci_pass: true on a ci: unenforced repo" do
      strategy = %{
        "type" => "pr_merge",
        "repos" => [
          %{
            "repo_url" => "Stark Industries/orion",
            "ci" => "unenforced",
            "config" => %{"require_ci_pass" => true}
          }
        ]
      }

      assert {:error, msg} = DeployStageBuilder.validate_strategy(strategy)
      assert msg =~ "require_ci_pass is not expressible for Stark Industries/orion"
      assert msg =~ "nothing was required to pass, not that checks passed"
    end

    test "allows a ci: unenforced repo to opt out of an inherited auto_merge" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true},
        "repos" => [
          %{"repo_url" => "Startup-Suite/core", "ci" => "required"},
          %{
            "repo_url" => "Stark Industries/orion",
            "ci" => "unenforced",
            "config" => %{"auto_merge" => false}
          }
        ]
      }

      assert :ok == DeployStageBuilder.validate_strategy(strategy)
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
      assert DeployStageBuilder.valid_repo_ci_states() == ["required", "none", "unenforced"]
    end

    # Stage 1 pinned the inverse of this ("declaring a repo set changes
    # NOTHING about the stage that gets built") as its own boundary marker.
    # Stage 2 IS the boundary move: a declared repo set now changes the
    # stage. The assertion is kept, flipped, rather than deleted, so the
    # transition is visible in the file's history.
    test "build_stage/3 IS changed by the presence of a repo set" do
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
          4,
          @recorded_branch
        )

      without =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}},
          4,
          @recorded_branch
        )

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
  describe "build_stage/3 — pr_merge repo-scoped gates" do
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

    # `ci: "unenforced"` (Stark Industries/orion's actual live state:
    # workflows genuinely run and pass, but `branches/main` reports
    # `protected: false` and `required_status_checks.contexts: []`).
    @orion %{
      "repo_url" => "https://github.com/Stark Industries/orion",
      "slug" => "Stark Industries/orion",
      "ci" => "unenforced",
      "role" => "secondary",
      "config" => %{}
    }

    test "a one-repo set emits exactly ONE pr_merged, carrying that repo's identity" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"require_review_approval" => false, "auto_merge" => false},
        "repos" => [@core]
      }

      result = DeployStageBuilder.build_stage(strategy, 4, @recorded_branch)

      # Everything the unscoped stage asserted still holds.
      assert result.name == "Deploy: PR merge"
      assert result.position == 4
      assert result.description =~ "PR merge flow"
      assert result.description =~ "pr_merged"
      assert result.description =~ "Strategy config declares auto_merge: false"
      assert result.description =~ "merges the PR by hand via GitHub"
      refute result.description =~ "will be merged automatically"
      refute result.description =~ "manual_approval"
      refute result.description =~ "ci_passed"

      # Regression 019fa63a, still true: a ONE-repo set reads as a SINGULAR
      # deploy, not as the enumerating multi-repo renderer's "this deploy
      # covers N repositories" list framing — one repository is one
      # repository however the set was arrived at.
      refute result.description =~ "This deploy covers"
      refute result.description =~ "is a partial deploy"

      # It is NOT required to be byte-identical to the undeclared-repo-set
      # description any more (task 01a0e5f6 stage 2). That used to be true
      # only because the single-repo path DISCARDED the resolved entry and
      # fell back to the same config-only renderer the undeclared-repo-set
      # path uses — which has no per-repo `ci` and can never say anything
      # but "CI is enforced by branch protection", true or not. This entry
      # DOES carry a resolved identity (`ci: "required"`, `@core`'s shape),
      # and the single-repo path now makes the claim that identity is
      # entitled to, through the same helper the multi-repo renderer uses.
      # See the "The actual bug (task 01a0e5f6 stage 2)" tests below for the
      # case where that claim actually differs (ci: none / unenforced) from
      # the undeclared-repo-set path's unconditional text.
      assert result.description =~ "CI is required and enforced by branch protection"

      # ...and the single gate now names the repository it watches.
      assert [validation] = result.validations
      assert validation.kind == "pr_merged"

      # `branch_tip_sha` is nil here because this call passes no tips map —
      # the key is WRITTEN regardless, so a gate minted today is
      # distinguishable at a glance from a genuinely legacy one that predates
      # the key. See `build_stage/4 \u2014 the recorded branch tip` below for the
      # populated case.
      assert validation.evaluation_payload == %{
               "repo" => "Startup-Suite/core",
               "repo_url" => "https://github.com/Startup-Suite/core",
               "branch" => @recorded_branch,
               "branch_tip_sha" => nil,
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

      result = DeployStageBuilder.build_stage(strategy, 7, @recorded_branch)

      assert length(result.validations) == 2
      assert Enum.all?(result.validations, &(&1.kind == "pr_merged"))

      assert Enum.map(result.validations, & &1.evaluation_payload["repo"]) == [
               "Startup-Suite/core",
               "Startup-Suite/claude-code-suite-channel"
             ]

      # Reversing the declaration reverses the gates — the order is the
      # declared order, not an incidental sort.
      reversed =
        DeployStageBuilder.build_stage(
          %{strategy | "repos" => [@channel, @core]},
          7,
          @recorded_branch
        )

      assert Enum.map(reversed.validations, & &1.evaluation_payload["repo"]) == [
               "Startup-Suite/claude-code-suite-channel",
               "Startup-Suite/core"
             ]
    end

    test "the description enumerates every repository in the set" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core, @channel]},
          1,
          @recorded_branch
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

      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)

      [core_gate, channel_gate] = result.validations

      assert core_gate.evaluation_payload["auto_merge"] == true
      assert core_gate.evaluation_payload["merge_method"] == "rebase"

      assert channel_gate.evaluation_payload["ci"] == "none"

      assert channel_gate.evaluation_payload["auto_merge"] == false,
             "a repo with zero required checks has nothing for auto-merge to wait for"
    end

    # `repo_gate/2` used to collapse anything non-"none" into "required",
    # which would have swallowed "unenforced" the moment it was added as a
    # valid state. This pins that the pass-through is explicit per value.
    test "a ci: unenforced entry is preserved, not collapsed into required" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{},
        "repos" => [
          @core,
          %{
            "repo_url" => "https://github.com/Stark Industries/orion",
            "slug" => "Stark Industries/orion",
            "ci" => "unenforced",
            "role" => "secondary",
            "config" => %{}
          }
        ]
      }

      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)

      [core_gate, orion_gate] = result.validations

      assert core_gate.evaluation_payload["ci"] == "required"
      assert orion_gate.evaluation_payload["ci"] == "unenforced"

      assert orion_gate.evaluation_payload["auto_merge"] == false,
             "a repo with nothing required has nothing for auto-merge to wait on"
    end

    test "the description says plainly what CLEAN means on a ci: none repo" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core, @channel]},
          1,
          @recorded_branch
        )

      assert result.description =~
               "Startup-Suite/claude-code-suite-channel has no required status checks"

      assert result.description =~ "a CLEAN merge state means zero checks ran, not checks passed"
      assert result.description =~ "merged by hand; a human must look at it"

      # The sentence is about the ci: none repo ONLY — it must not be
      # attached to the repo that does have checks.
      refute result.description =~ "Startup-Suite/core has no required status checks"
    end

    # ── The actual bug (task 01a0e5f6 stage 2) ──────────────────────────
    #
    # `pr_merge_description(config, [_single])` used to DISCARD the resolved
    # single-repo entry (with its computed `ci`) and fall back to the
    # config-only renderer, which has no per-repo `ci` and can never say
    # anything but "CI is enforced by branch protection". This is the COMMON
    # case — `Tasks.resolve_deploy_strategy_with_repos/1` synthesizes a
    # one-entry `"repos"` list from `project.repo_url` for every ordinary
    # task — so the single-repo path never reached ci-aware code at all.
    # Every test below exercises BOTH renderers: a test exercising only
    # `repo_sentence/1` (the multi-repo enumerator) would not catch this,
    # since that renderer was already correct-ish.
    test "ci: required single-repo gate (core's shape) renders the required claim via the single-repo path" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core]},
          1,
          @recorded_branch
        )

      assert result.description =~ "CI is required and enforced by branch protection"
    end

    test "ci: unenforced single-repo gate (orion's shape) renders the NEW claim via the single-repo path, and neither the none nor the required claim" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@orion]},
          1,
          @recorded_branch
        )

      assert result.description =~
               "CI runs on this repo but is NOT required — MERGEABLE/CLEAN means nothing " <>
                 "blocks the merge, not that checks passed or even finished"

      assert result.description =~ "gh run watch <id> --exit-status"

      refute result.description =~ "has no required status checks"
      refute result.description =~ "CI is required and enforced"
    end

    test "ci: required and ci: unenforced both render their claims via repo_sentence/1 in a two-repo scenario" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core, @orion]},
          1,
          @recorded_branch
        )

      assert result.description =~
               "Startup-Suite/core: CI is required and enforced by branch protection"

      assert result.description =~
               "Stark Industries/orion: CI runs on this repo but is NOT required"

      refute result.description =~ "Stark Industries/orion has no required status checks"
      refute result.description =~ "Stark Industries/orion: CI is required and enforced"
    end

    test "ci: none still renders unchanged in both the single-repo path and repo_sentence/1 (regression guard)" do
      single =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@channel]},
          1,
          @recorded_branch
        )

      multi =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core, @channel]},
          1,
          @recorded_branch
        )

      for result <- [single, multi] do
        assert result.description =~ "has no required status checks"

        assert result.description =~
                 "a CLEAN merge state means zero checks ran, not checks passed"
      end
    end

    test "the enforcement claim matches between the single-repo path and repo_sentence/1, for all three ci states" do
      required_claim = "CI is required and enforced by branch protection"

      none_claim =
        "has no required status checks — a CLEAN merge state means zero checks ran, not " <>
          "checks passed"

      unenforced_claim =
        "CI runs on this repo but is NOT required — MERGEABLE/CLEAN means nothing blocks " <>
          "the merge, not that checks passed or even finished. Watch the run to conclusion " <>
          "(`gh run watch <id> --exit-status`) before merging by hand."

      single_required =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core]},
          1,
          @recorded_branch
        ).description

      single_none =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@channel]},
          1,
          @recorded_branch
        ).description

      single_unenforced =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@orion]},
          1,
          @recorded_branch
        ).description

      multi =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core, @channel, @orion]},
          1,
          @recorded_branch
        ).description

      # Same claim, extracted from BOTH renderers — NOT asserting the two
      # renderers produce byte-identical strings, since their surrounding
      # prose (repo-count language, list framing, merge-method wording)
      # legitimately differs.
      assert single_required =~ required_claim
      assert multi =~ required_claim

      assert single_none =~ none_claim
      assert multi =~ none_claim

      assert single_unenforced =~ unenforced_claim
      assert multi =~ unenforced_claim
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

      result = DeployStageBuilder.build_stage(strategy, 1, @recorded_branch)

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
          1,
          @recorded_branch
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
          1,
          @recorded_branch
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

      result = DeployStageBuilder.build_stage(strategy, 4, @recorded_branch)

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
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "repos" => []},
          1,
          @recorded_branch
        )

      refute result.validations == [],
             "a deploy stage with zero validations auto-passes (stage_verdict/1 " <>
               "returns :all_passed for []) — an empty repo set must never build one"

      assert result.validations == [%{kind: "pr_merged"}]
    end

    test "every emitted gate is a pr_merged — no other kind leaks in" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core, @channel]},
          1,
          @recorded_branch
        )

      assert Enum.map(result.validations, & &1.kind) == ["pr_merged", "pr_merged"]
    end
  end

  # ── The recorded branch (task 019fba18 stage 1) ─────────────────────────
  #
  # The gate RECORDS the branch this task pushes instead of leaving the
  # consumer to re-derive one. Every expectation below is a STRING LITERAL.
  # It is deliberately NOT `StackDeployer.member_branch_for(task)` on both
  # sides: `origin/task/019fb949` commit `4849cbd1` rewrote
  # `deploy_merge_reconciler_test.exs:183` into exactly that shape — an
  # expectation computed by the function under test — which silenced a
  # helper that had gone red for the right reason. An assertion that moves
  # with the code it checks cannot fail.
  #
  # The derivation appears only as the INPUT to `build_stage/3`, which is
  # what production does; the output is pinned against a literal typed out by
  # hand from the fixture's pinned id.
  # ── The recorded branch TIP (task 01a06d6d stage 2) ──────────────────────
  #
  # `"branch"` says which branch to watch. `"branch_tip_sha"` says which TREE
  # the gate was minted for, and `DeployMergeReconciler` requires the merged
  # PR's head to equal it. Recorded per REPOSITORY, because one branch name
  # lands in N repositories as N unrelated refs with N unrelated tips.
  describe "build_stage/4 — the recorded branch tip" do
    @tip_core_entry %{
      "repo_url" => "https://github.com/Startup-Suite/core",
      "slug" => "Startup-Suite/core",
      "ci" => "required",
      "role" => "primary",
      "config" => %{}
    }

    @tip_bridge_entry %{
      "repo_url" => "https://github.com/Startup-Suite/claude-code-suite-channel",
      "slug" => "Startup-Suite/claude-code-suite-channel",
      "ci" => "none",
      "role" => "secondary",
      "config" => %{}
    }

    @core_tip "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    @bridge_tip "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    defp two_repo_strategy do
      %{
        "type" => "pr_merge",
        "config" => %{},
        "repos" => [@tip_core_entry, @tip_bridge_entry]
      }
    end

    defp gate_for(result, slug),
      do: Enum.find(result.validations, &(&1.evaluation_payload["repo"] == slug))

    # The whole point of the map. Two DIFFERENT shas, and each must land on
    # its own repository's gate — a stage-wide sha would match one repository
    # and hang the other forever.
    test "each repo-scoped gate records ITS OWN repository's tip" do
      result =
        DeployStageBuilder.build_stage(two_repo_strategy(), 4, @recorded_branch, %{
          "Startup-Suite/core" => @core_tip,
          "Startup-Suite/claude-code-suite-channel" => @bridge_tip
        })

      assert gate_for(result, "Startup-Suite/core").evaluation_payload["branch_tip_sha"] ==
               @core_tip

      assert gate_for(result, "Startup-Suite/claude-code-suite-channel").evaluation_payload[
               "branch_tip_sha"
             ] == @bridge_tip

      # Stated as a non-equality too. Two lookups that both returned the same
      # value would satisfy the pair above if the builder ignored the key and
      # wrote one sha everywhere.
      refute @core_tip == @bridge_tip
    end

    # A repository whose tip could not be resolved — no `gh`, a branch nobody
    # pushed, a repository we cannot read — records nil while its SIBLING
    # still records a real sha. Partial resolution must degrade one gate, not
    # the stage.
    test "a repository missing from the map records nil, and does not disturb its sibling" do
      result =
        DeployStageBuilder.build_stage(two_repo_strategy(), 4, @recorded_branch, %{
          "Startup-Suite/core" => @core_tip
        })

      assert gate_for(result, "Startup-Suite/core").evaluation_payload["branch_tip_sha"] ==
               @core_tip

      assert gate_for(result, "Startup-Suite/claude-code-suite-channel").evaluation_payload[
               "branch_tip_sha"
             ] == nil
    end

    # The key is PRESENT and nil, not absent. `DeployMergeReconciler` treats
    # the two identically, but only a present key says "this gate was minted
    # after the check existed and the lookup failed" rather than "this gate
    # predates the check". Operators read payloads.
    test "the key is written even when no tips are known at all" do
      result = DeployStageBuilder.build_stage(two_repo_strategy(), 4, @recorded_branch, %{})

      for validation <- result.validations do
        assert Map.has_key?(validation.evaluation_payload, "branch_tip_sha")
        assert validation.evaluation_payload["branch_tip_sha"] == nil
      end
    end

    # The UNSCOPED gate — no declared repo set — keeps its ABSENT payload.
    # Giving it one would move it out of `DeployMergeReconciler.gate_repo/1`'s
    # nil-payload clause, which is a routing change dressed up as a field
    # addition. Same reasoning the moduledoc gives for `"branch"`.
    test "an undeclared repo set still emits ONE gate with no payload at all" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}},
          4,
          @recorded_branch,
          %{"Startup-Suite/core" => @core_tip}
        )

      assert [%{kind: "pr_merged"} = validation] = result.validations
      refute Map.has_key?(validation, :evaluation_payload)
    end
  end

  describe "build_stage/3 — the recorded branch" do
    @core_entry %{
      "repo_url" => "https://github.com/Startup-Suite/core",
      "slug" => "Startup-Suite/core",
      "ci" => "required",
      "role" => "primary",
      "config" => %{}
    }

    @bridge_entry %{
      "repo_url" => "https://github.com/Startup-Suite/claude-code-suite-channel",
      "slug" => "Startup-Suite/claude-code-suite-channel",
      "ci" => "none",
      "role" => "secondary",
      "config" => %{"auto_merge" => false}
    }

    test "every scoped gate carries the branch, and all of them carry the SAME one" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => false},
        "repos" => [@core_entry, @bridge_entry]
      }

      result = DeployStageBuilder.build_stage(strategy, 7, @recorded_branch)

      assert [core_gate, bridge_gate] = result.validations

      assert core_gate.evaluation_payload["branch"] == @recorded_branch
      assert bridge_gate.evaluation_payload["branch"] == @recorded_branch

      # One branch, N repositories. A per-repo branch would mean the task
      # pushed different code to each remote, which it does not.
      assert core_gate.evaluation_payload["branch"] ==
               bridge_gate.evaluation_payload["branch"],
             "one task pushes ONE branch — every gate on the stage records it"

      # The key is present, not merely non-nil-when-asked. `Map.get/2`
      # answers nil for an absent key too, and the stage-2 consumer
      # distinguishes "recorded as nil" from "never recorded".
      assert Map.has_key?(core_gate.evaluation_payload, "branch")
      assert Map.has_key?(bridge_gate.evaluation_payload, "branch")
    end

    test "records the full-uuid branch for a NON-stack task with a pinned id" do
      id = "019fba18-d074-7185-8e0e-032ee6d02fbe"
      task = task_with_pinned_id!(id)

      assert is_nil(task.stack_id)

      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core_entry]},
          1,
          StackDeployer.member_branch_for(task)
        )

      assert [gate] = result.validations

      # Typed out by hand from `id` above. Not a call, not an interpolation
      # of `member_slug/1`.
      assert gate.evaluation_payload["branch"] ==
               "task/019fba18-d074-7185-8e0e-032ee6d02fbe"
    end

    test "records the full-uuid branch for a STACK MEMBER with a pinned id" do
      id = "019fba18-d074-7185-8e0e-032ee6d02fbf"
      task = task_with_pinned_id!(id, stacked?: true)

      refute is_nil(task.stack_id)

      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}, "repos" => [@core_entry]},
          1,
          StackDeployer.member_branch_for(task)
        )

      assert [gate] = result.validations

      assert gate.evaluation_payload["branch"] ==
               "task/019fba18-d074-7185-8e0e-032ee6d02fbf"
    end

    # THE defect this whole task exists to close, pinned at the layer that
    # mints the value. The first eight hex characters of a UUIDv7 are the
    # high 32 bits of its 48-bit millisecond timestamp — a ~65-second
    # bucket, not an identifier. Live on 2026-07-31: `019fb90f-36e3-…` and
    # `019fb90f-6226-…` both truncate to `019fb90f`, and `task/019fb90f`
    # carries merged PR #648. If the recorded values ever collapse, one
    # task's deploy gate can be closed by another task's merge — and the
    # consumer cannot see the collision, because `gh pr list --head` answers
    # about a branch and GitHub returns one PR per branch.
    test "two tasks sharing a first hyphen-segment record DIFFERENT branches" do
      id_a = "019fb90f-36e3-7fd6-a416-f128f4c0190f"
      id_b = "019fb90f-6226-7fd6-a416-f128f4c0190f"

      task_a = task_with_pinned_id!(id_a)
      task_b = task_with_pinned_id!(id_b)

      strategy = %{"type" => "pr_merge", "config" => %{}, "repos" => [@core_entry]}

      [gate_a] =
        DeployStageBuilder.build_stage(
          strategy,
          1,
          StackDeployer.member_branch_for(task_a)
        ).validations

      [gate_b] =
        DeployStageBuilder.build_stage(
          strategy,
          1,
          StackDeployer.member_branch_for(task_b)
        ).validations

      branch_a = gate_a.evaluation_payload["branch"]
      branch_b = gate_b.evaluation_payload["branch"]

      refute branch_a == branch_b,
             "two tasks minted in the same ~65s UUIDv7 bucket recorded the same " <>
               "branch #{inspect(branch_a)} — one merge would close both gates"

      # Literals, hand-copied from `id_a` / `id_b`.
      assert branch_a == "task/019fb90f-36e3-7fd6-a416-f128f4c0190f"
      assert branch_b == "task/019fb90f-6226-7fd6-a416-f128f4c0190f"

      # And neither is the truncated form the code used to produce.
      refute branch_a == "task/019fb90f"
      refute branch_b == "task/019fb90f"
    end

    # The unscoped gate is NOT given a payload. `DeployMergeReconciler`'s
    # nil-payload clause skips exactly these rows and
    # `GithubWebhookController.select_unscoped_validation/3` owns them;
    # handing one a payload would silently move it between owners.
    test "the unscoped gate is left with NO payload at all" do
      result =
        DeployStageBuilder.build_stage(
          %{"type" => "pr_merge", "config" => %{}},
          1,
          @recorded_branch
        )

      assert result.validations == [%{kind: "pr_merged"}],
             "an undeclared repo set must still emit a payload-free gate — giving " <>
               "it a branch would move it out of gate_repo/1's nil-payload clause"
    end
  end

  # Real rows, not hand-built structs: `member_branch_for/1` reads
  # `tasks.stack_id`, which only a persisted row carries honestly.
  # `Task.changeset/2` does not cast `:id`, so `put_change/3` is the route —
  # same shape as `stack_deployer_test.exs`'s literal-pinned fixtures.
  defp task_with_pinned_id!(id, opts \\ []) do
    uniq = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: "Recorded Branch Project #{uniq}",
        repo_url: "https://github.com/Startup-Suite/core"
      })

    stack_id =
      if Keyword.get(opts, :stacked?, false) do
        {:ok, stack} =
          Stacks.create_stack(%{
            project_id: project.id,
            slug: "recorded-branch-#{uniq}",
            name: "Recorded Branch Stack #{uniq}",
            base_branch: "main",
            rollup_branch: "stack/recorded-branch-#{uniq}"
          })

        stack.id
      end

    %Task{}
    |> Task.changeset(%{
      project_id: project.id,
      title: "Recorded branch task #{uniq}",
      status: "in_progress",
      stack_id: stack_id
    })
    |> Ecto.Changeset.put_change(:id, id)
    |> Repo.insert!()
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
            stage =
              DeployStageBuilder.build_stage(
                %{"type" => type, "config" => %{}},
                3,
                @recorded_branch
              ),
            stage != :skip do
          assert DeployStageBuilder.deploy_stage_name?(stage.name),
                 "strategy #{type} minted stage name #{inspect(stage.name)} which does not " <>
                   "start with #{inspect(DeployStageBuilder.deploy_stage_name_prefix())} — " <>
                   "DispatchPhase would misroute its deploy dispatch"

          type
        end

      # Guard the guard: if `build_stage/3` ever starts returning `:skip` for
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
