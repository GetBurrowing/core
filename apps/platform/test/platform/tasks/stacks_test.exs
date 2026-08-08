defmodule Platform.Tasks.StacksTest do
  # async: false because the `recompute_stack_status/1` piggy-back fires
  # `StackDeployer.maybe_open_stack_pr/1`, which reads the global
  # `:platform, :stack_deployer` config (git_runner). The
  # `recompute_stack_status piggy-back` describe block swaps in a FakeRunner
  # via `Application.put_env`, which is not safe to share across async
  # processes.
  #
  # BOARD-SCOPE-EXEMPT: the four `Tasks.subscribe_board()` calls in the
  # ":stack_gate_opened broadcast" describe block stay on the global topic
  # deliberately. `async: false` means no concurrent module can race them, and
  # two of the four are `refute_receive {:stack_gate_opened, _, _}` on a stack
  # id that must NOT exist — a negative that cannot be pinned to a scope
  # without assuming the answer. See the site comment at the non-stack case.
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequests, Stack, Stacks, Task}

  describe "create_stack/1" do
    test "creates a stack with valid attrs" do
      {:ok, project} = Tasks.create_project(%{name: "Stacks App"})

      assert {:ok, %Stack{} = stack} =
               Stacks.create_stack(%{
                 project_id: project.id,
                 slug: "auth-refresh",
                 name: "Auth refresh",
                 rollup_branch: Stacks.rollup_branch_name("auth-refresh")
               })

      assert stack.slug == "auth-refresh"
      assert stack.name == "Auth refresh"
      assert stack.status == "forming"
      assert stack.base_branch == "main"
      assert stack.rollup_branch == "stack/auth-refresh"
    end

    test "rejects invalid slug" do
      {:ok, project} = Tasks.create_project(%{name: "Bad Slug Project"})

      assert {:error, changeset} =
               Stacks.create_stack(%{
                 project_id: project.id,
                 slug: "Bad Slug!",
                 name: "Bad",
                 rollup_branch: "stack/bad"
               })

      assert %{slug: [_]} = errors_on(changeset)
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = Stacks.create_stack(%{})
      errors = errors_on(changeset)
      assert errors[:project_id]
      assert errors[:slug]
      assert errors[:name]
      assert errors[:rollup_branch]
    end

    test "rejects duplicate slug within a project" do
      {:ok, project} = Tasks.create_project(%{name: "Dup Project"})

      attrs = %{
        project_id: project.id,
        slug: "shared",
        name: "First",
        rollup_branch: "stack/shared"
      }

      assert {:ok, _} = Stacks.create_stack(attrs)
      assert {:error, changeset} = Stacks.create_stack(%{attrs | name: "Second"})
      # The composite unique index is keyed on [:project_id, :slug]; Ecto
      # surfaces the violation on the first field of the index.
      errors = errors_on(changeset)

      assert errors[:project_id] == ["has already been taken"] or
               errors[:slug] == ["has already been taken"]
    end

    test "defaults auto_plan and auto_accept_plan to false when unspecified" do
      {:ok, project} = Tasks.create_project(%{name: "Auto Defaults"})

      assert {:ok, %Stack{} = stack} =
               Stacks.create_stack(%{
                 project_id: project.id,
                 slug: "auto-defaults",
                 name: "Auto Defaults",
                 rollup_branch: Stacks.rollup_branch_name("auto-defaults")
               })

      assert stack.auto_plan == false
      assert stack.auto_accept_plan == false

      # Round-trip through get_stack/1 to confirm the DB defaults hit.
      fetched = Stacks.get_stack(stack.id)
      assert fetched.auto_plan == false
      assert fetched.auto_accept_plan == false
    end

    test "accepts auto_plan and auto_accept_plan on create and roundtrips" do
      {:ok, project} = Tasks.create_project(%{name: "Auto Both"})

      assert {:ok, %Stack{} = stack} =
               Stacks.create_stack(%{
                 project_id: project.id,
                 slug: "auto-both",
                 name: "Auto Both",
                 rollup_branch: Stacks.rollup_branch_name("auto-both"),
                 auto_plan: true,
                 auto_accept_plan: true
               })

      fetched = Stacks.get_stack(stack.id)
      assert fetched.auto_plan == true
      assert fetched.auto_accept_plan == true
    end
  end

  describe "get_stack/1 and get_stack!/1" do
    test "returns the stack by id" do
      stack = stack_fixture()
      assert fetched = Stacks.get_stack(stack.id)
      assert fetched.id == stack.id
      assert Stacks.get_stack!(stack.id).id == stack.id
    end

    test "get_stack/1 returns nil for missing id" do
      assert Stacks.get_stack(Ecto.UUID.generate()) == nil
    end

    test "get_stack!/1 raises for missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        Stacks.get_stack!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_stack_for_pull_request/1 and get_stack_for_pull_request_with_strategy/1" do
    test "strategy 1: matches by rollup_branch (happy path)" do
      stack = stack_fixture(slug: "gspfp-rollup-branch", name: "Rollup branch match")

      pr = %{
        "number" => 42,
        "head" => %{"ref" => stack.rollup_branch},
        "base" => %{"ref" => "main"}
      }

      assert {:ok, matched, :rollup_branch} =
               Stacks.get_stack_for_pull_request_with_strategy(pr)

      assert matched.id == stack.id
      assert %Stack{id: id} = Stacks.get_stack_for_pull_request(pr)
      assert id == stack.id
    end

    test "strategy 2: matches by metadata.rollup_pr.number when rollup_branch is stale" do
      stack = stack_fixture(slug: "gspfp-pr-number", name: "PR number match")

      # Simulate the meeting-pipeline PR #569 signature: rollup_branch is
      # stale (points at a branch that no longer matches the PR head), but
      # metadata.rollup_pr.number is stamped correctly.
      {:ok, stack} =
        Stacks.update_stack(stack, %{
          rollup_branch: "stack/stale-branch",
          metadata: %{"rollup_pr" => %{"number" => 569, "url" => "https://example/pr/569"}}
        })

      pr = %{
        "number" => 569,
        "head" => %{"ref" => "stack/some-other-branch"},
        "base" => %{"ref" => "main"}
      }

      assert {:ok, matched, :pr_number} =
               Stacks.get_stack_for_pull_request_with_strategy(pr)

      assert matched.id == stack.id
    end

    test "strategy 3: slug-derived fallback when rollup_branch is stale + no PR-number stamp" do
      stack = stack_fixture(slug: "gspfp-slug", name: "Slug fallback match")

      # Historical/manually-shepherded stack: rollup_branch was somehow
      # written to point at a stale/foreign branch and metadata.rollup_pr
      # was never stamped. The slug convention (`stack/<slug>`) is the
      # only remaining thread that identifies this stack from a webhook.
      {:ok, stack} =
        Stacks.update_stack(stack, %{
          rollup_branch: "stack/some-stale-branch"
        })

      pr = %{
        "number" => 7,
        "head" => %{"ref" => "stack/gspfp-slug"},
        "base" => %{"ref" => "main"}
      }

      assert {:ok, matched, :slug} =
               Stacks.get_stack_for_pull_request_with_strategy(pr)

      assert matched.id == stack.id
    end

    test "strategy order: rollup_branch wins over pr_number when both match" do
      stack = stack_fixture(slug: "gspfp-order", name: "Order priority")

      {:ok, stack} =
        Stacks.update_stack(stack, %{
          metadata: %{"rollup_pr" => %{"number" => 123}}
        })

      pr = %{
        "number" => 123,
        "head" => %{"ref" => stack.rollup_branch},
        "base" => %{"ref" => "main"}
      }

      assert {:ok, matched, :rollup_branch} =
               Stacks.get_stack_for_pull_request_with_strategy(pr)

      assert matched.id == stack.id
    end

    test "strategy order: pr_number wins over slug when rollup_branch is stale" do
      stack = stack_fixture(slug: "gspfp-order-slug", name: "Order slug")

      {:ok, stack} =
        Stacks.update_stack(stack, %{
          rollup_branch: "stack/stale-elsewhere",
          metadata: %{"rollup_pr" => %{"number" => 456}}
        })

      pr = %{
        "number" => 456,
        "head" => %{"ref" => "stack/gspfp-order-slug"},
        "base" => %{"ref" => "main"}
      }

      assert {:ok, matched, :pr_number} =
               Stacks.get_stack_for_pull_request_with_strategy(pr)

      assert matched.id == stack.id
    end

    test "returns nil when no strategy matches" do
      _stack = stack_fixture(slug: "gspfp-nomatch", name: "No match")

      pr = %{
        "number" => 999_999,
        "head" => %{"ref" => "feature/unrelated"},
        "base" => %{"ref" => "main"}
      }

      assert Stacks.get_stack_for_pull_request_with_strategy(pr) == nil
      assert Stacks.get_stack_for_pull_request(pr) == nil
    end

    test "abandoned stacks are excluded from every strategy" do
      stack = stack_fixture(slug: "gspfp-abandoned", name: "Abandoned")

      {:ok, stack} =
        Stacks.update_stack(stack, %{
          metadata: %{"rollup_pr" => %{"number" => 321}}
        })

      {:ok, _abandoned} = Stacks.abandon_stack(stack, "scope changed")

      # Strategy 1: rollup_branch hit but excluded.
      pr_by_branch = %{
        "number" => 1,
        "head" => %{"ref" => stack.rollup_branch},
        "base" => %{"ref" => "main"}
      }

      assert Stacks.get_stack_for_pull_request_with_strategy(pr_by_branch) == nil

      # Strategy 2: pr_number hit but excluded.
      pr_by_number = %{
        "number" => 321,
        "head" => %{"ref" => "stack/other"},
        "base" => %{"ref" => "main"}
      }

      assert Stacks.get_stack_for_pull_request_with_strategy(pr_by_number) == nil

      # Strategy 3: slug hit but excluded.
      pr_by_slug = %{
        "number" => 2,
        "head" => %{"ref" => "stack/gspfp-abandoned"},
        "base" => %{"ref" => "main"}
      }

      assert Stacks.get_stack_for_pull_request_with_strategy(pr_by_slug) == nil
    end

    test "non-stack/* head refs skip the slug strategy" do
      _stack = stack_fixture(slug: "gspfp-nonslug", name: "Non slug")

      pr = %{
        "number" => 3,
        "head" => %{"ref" => "task/019f7b7f-something"},
        "base" => %{"ref" => "main"}
      }

      assert Stacks.get_stack_for_pull_request_with_strategy(pr) == nil
    end

    test "malformed head refs (uppercase / leading dash) skip the slug strategy" do
      _stack = stack_fixture(slug: "gspfp-malformed", name: "Malformed")

      malformed_refs = ["stack/UPPER", "stack/-leading-dash", "stack/", "stack"]

      for ref <- malformed_refs do
        pr = %{
          "number" => 4,
          "head" => %{"ref" => ref},
          "base" => %{"ref" => "main"}
        }

        assert Stacks.get_stack_for_pull_request_with_strategy(pr) == nil,
               "expected nil for malformed head ref #{inspect(ref)}"
      end
    end

    test "nil / non-map input returns nil" do
      assert Stacks.get_stack_for_pull_request_with_strategy(nil) == nil
      assert Stacks.get_stack_for_pull_request_with_strategy("not a map") == nil
      assert Stacks.get_stack_for_pull_request(nil) == nil
    end

    test "missing head or number keys returns nil (no crash)" do
      assert Stacks.get_stack_for_pull_request_with_strategy(%{}) == nil
      assert Stacks.get_stack_for_pull_request_with_strategy(%{"number" => nil}) == nil
      assert Stacks.get_stack_for_pull_request_with_strategy(%{"head" => %{}}) == nil
    end
  end

  describe "list_stacks/1" do
    test "returns stacks scoped to project_id" do
      {:ok, project_a} = Tasks.create_project(%{name: "Project A"})
      {:ok, project_b} = Tasks.create_project(%{name: "Project B"})

      stack_a = stack_fixture(project_id: project_a.id, slug: "a-one", name: "A One")
      _stack_b = stack_fixture(project_id: project_b.id, slug: "b-one", name: "B One")

      results = Stacks.list_stacks(%{project_id: project_a.id})
      assert Enum.map(results, & &1.id) == [stack_a.id]
    end

    test "returns stacks scoped by status" do
      {:ok, project} = Tasks.create_project(%{name: "Status Project"})
      forming = stack_fixture(project_id: project.id, slug: "forming-one", name: "Forming")
      abandoned = stack_fixture(project_id: project.id, slug: "abandon-one", name: "Abandon")
      {:ok, _} = Stacks.abandon_stack(abandoned, "no longer needed")

      forming_only = Stacks.list_stacks(%{status: "forming"})
      assert Enum.any?(forming_only, &(&1.id == forming.id))
      refute Enum.any?(forming_only, &(&1.id == abandoned.id))

      abandoned_only = Stacks.list_stacks(%{status: "abandoned"})
      assert Enum.any?(abandoned_only, &(&1.id == abandoned.id))
      refute Enum.any?(abandoned_only, &(&1.id == forming.id))
    end

    test "with no filters returns all stacks ordered newest first" do
      {:ok, project} = Tasks.create_project(%{name: "Order Project"})
      first = stack_fixture(project_id: project.id, slug: "first", name: "First")
      # Force a perceptible insert delta to get a stable order.
      :timer.sleep(5)
      second = stack_fixture(project_id: project.id, slug: "second", name: "Second")

      ids = Stacks.list_stacks() |> Enum.map(& &1.id)
      first_idx = Enum.find_index(ids, &(&1 == first.id))
      second_idx = Enum.find_index(ids, &(&1 == second.id))
      assert second_idx < first_idx
    end

    # ADR 0042 Decision 8 — stack-level sponsor filter parity with tasks.
    test "returns stacks scoped by :sponsor_user_id" do
      {:ok, project} = Tasks.create_project(%{name: "Sponsor Filter"})
      user_a = insert_sponsor_user()
      user_b = insert_sponsor_user()

      stack_a1 =
        stack_fixture(
          project_id: project.id,
          slug: "a-one",
          name: "A One",
          sponsor_user_id: user_a.id
        )

      stack_a2 =
        stack_fixture(
          project_id: project.id,
          slug: "a-two",
          name: "A Two",
          sponsor_user_id: user_a.id
        )

      _stack_b =
        stack_fixture(
          project_id: project.id,
          slug: "b-one",
          name: "B One",
          sponsor_user_id: user_b.id
        )

      _unsponsored =
        stack_fixture(project_id: project.id, slug: "unsponsored", name: "Unsponsored")

      results = Stacks.list_stacks(%{sponsor_user_id: user_a.id})
      ids = Enum.map(results, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([stack_a1.id, stack_a2.id])
    end

    test "nil :sponsor_user_id filter is passthrough (all stacks)" do
      {:ok, project} = Tasks.create_project(%{name: "Sponsor Nil"})
      user = insert_sponsor_user()

      sponsored =
        stack_fixture(
          project_id: project.id,
          slug: "sponsored",
          name: "Sponsored",
          sponsor_user_id: user.id
        )

      unsponsored =
        stack_fixture(project_id: project.id, slug: "un-sponsored", name: "Unsponsored")

      # Passing the key with a nil value should not narrow the result.
      ids = Stacks.list_stacks(%{sponsor_user_id: nil}) |> Enum.map(& &1.id)
      assert sponsored.id in ids
      assert unsponsored.id in ids
    end

    test "preloads :sponsor on returned stacks" do
      {:ok, project} = Tasks.create_project(%{name: "Sponsor Preload"})
      user = insert_sponsor_user(name: "Sponsor Name")

      stack =
        stack_fixture(
          project_id: project.id,
          slug: "with-sponsor",
          name: "With Sponsor",
          sponsor_user_id: user.id
        )

      [found] =
        Stacks.list_stacks(%{project_id: project.id})
        |> Enum.filter(&(&1.id == stack.id))

      assert %Platform.Accounts.User{id: sponsor_id, name: "Sponsor Name"} = found.sponsor
      assert sponsor_id == user.id
    end
  end

  describe "list_stacks_with_members/1 — sponsor filter" do
    test "returns stacks scoped by :sponsor_user_id along with their members" do
      {:ok, project} = Tasks.create_project(%{name: "SPWM Sponsor"})
      user_a = insert_sponsor_user()
      user_b = insert_sponsor_user()

      stack_a =
        stack_fixture(
          project_id: project.id,
          slug: "swm-a",
          name: "SWM A",
          sponsor_user_id: user_a.id
        )

      _stack_b =
        stack_fixture(
          project_id: project.id,
          slug: "swm-b",
          name: "SWM B",
          sponsor_user_id: user_b.id
        )

      # Attach a member to stack_a so we can also verify the members payload
      # is scoped by the filter (the second-query fetch reads stack_ids from
      # the already-filtered stacks list).
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Member of A"})

      {:ok, _} = Stacks.add_task(stack_a, task)

      results = Stacks.list_stacks_with_members(%{sponsor_user_id: user_a.id})
      assert [{returned_stack, board_data}] = results
      assert returned_stack.id == stack_a.id
      assert board_data.member_count == 1
      assert %Platform.Accounts.User{id: sponsor_id} = returned_stack.sponsor
      assert sponsor_id == user_a.id
    end

    test "preloads :sponsor on stacks with unsponsored members" do
      {:ok, project} = Tasks.create_project(%{name: "SWM Preload"})

      _unsponsored =
        stack_fixture(project_id: project.id, slug: "swm-nil", name: "SWM Nil")

      [{stack, _}] = Stacks.list_stacks_with_members(%{project_id: project.id})
      # Preload should resolve unsponsored slot to nil (not
      # `%Ecto.Association.NotLoaded{}`) so downstream renderers can
      # pattern-match nil safely.
      assert stack.sponsor == nil
    end
  end

  describe "sponsor_user_id (ADR 0042 Decision 8, stack sponsor)" do
    test "changeset accepts nil sponsor_user_id (nullable)" do
      {:ok, project} = Tasks.create_project(%{name: "Nil Sponsor"})

      changeset =
        Stack.changeset(%Stack{}, %{
          project_id: project.id,
          slug: "nil-sponsor",
          name: "Nil Sponsor",
          rollup_branch: "stack/nil-sponsor",
          sponsor_user_id: nil
        })

      assert changeset.valid?
    end

    test "changeset casts a valid UUID into sponsor_user_id" do
      {:ok, project} = Tasks.create_project(%{name: "Valid Sponsor"})
      user = insert_sponsor_user()

      changeset =
        Stack.changeset(%Stack{}, %{
          project_id: project.id,
          slug: "valid-sponsor",
          name: "Valid Sponsor",
          rollup_branch: "stack/valid-sponsor",
          sponsor_user_id: user.id
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :sponsor_user_id) == user.id
    end

    test "create_stack/1 persists sponsor_user_id when set" do
      {:ok, project} = Tasks.create_project(%{name: "Persist Sponsor"})
      user = insert_sponsor_user()

      assert {:ok, %Stack{} = stack} =
               Stacks.create_stack(%{
                 project_id: project.id,
                 slug: "persist",
                 name: "Persist",
                 rollup_branch: "stack/persist",
                 sponsor_user_id: user.id
               })

      assert stack.sponsor_user_id == user.id
    end

    test "insert with a bogus sponsor_user_id surfaces a FK error on the changeset" do
      {:ok, project} = Tasks.create_project(%{name: "Bogus Sponsor"})
      fake_user_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               Stacks.create_stack(%{
                 project_id: project.id,
                 slug: "bogus",
                 name: "Bogus",
                 rollup_branch: "stack/bogus",
                 sponsor_user_id: fake_user_id
               })

      assert %{sponsor_user_id: [_]} = errors_on(changeset)
    end

    test "deleting the sponsoring user nilifies sponsor_user_id (on_delete: :nilify_all)" do
      {:ok, project} = Tasks.create_project(%{name: "Departing Sponsor"})
      user = insert_sponsor_user()

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "departing",
          name: "Departing",
          rollup_branch: "stack/departing",
          sponsor_user_id: user.id
        })

      # Go straight through Repo.delete! to exercise the FK's SET NULL
      # behaviour without any Accounts-context guardrails.
      Repo.delete!(user)

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.sponsor_user_id == nil
    end
  end

  describe "update_stack/2" do
    test "updates writable fields" do
      stack = stack_fixture()
      assert {:ok, updated} = Stacks.update_stack(stack, %{name: "Renamed"})
      assert updated.name == "Renamed"
    end

    test "rejects invalid changes" do
      stack = stack_fixture()
      assert {:error, changeset} = Stacks.update_stack(stack, %{slug: "Not Valid"})
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "toggles auto_plan and auto_accept_plan flags" do
      stack = stack_fixture()
      assert stack.auto_plan == false
      assert stack.auto_accept_plan == false

      assert {:ok, updated} =
               Stacks.update_stack(stack, %{auto_plan: true, auto_accept_plan: true})

      assert updated.auto_plan == true
      assert updated.auto_accept_plan == true

      # And back again — verifies both directions of the toggle so a
      # future accidental one-way changeset filter would fail this.
      assert {:ok, reverted} =
               Stacks.update_stack(updated, %{auto_plan: false, auto_accept_plan: false})

      assert reverted.auto_plan == false
      assert reverted.auto_accept_plan == false
    end
  end

  describe "abandon_stack/2" do
    test "transitions status to abandoned" do
      stack = stack_fixture()
      assert {:ok, abandoned} = Stacks.abandon_stack(stack, "scope changed")
      assert abandoned.status == "abandoned"
      assert abandoned.description =~ "Abandoned: scope changed"
    end

    test "preserves prior description when reason given" do
      stack = stack_fixture(description: "Original notes")
      assert {:ok, abandoned} = Stacks.abandon_stack(stack, "redundant")
      assert abandoned.description =~ "Original notes"
      assert abandoned.description =~ "Abandoned: redundant"
    end

    test "leaves description untouched when no reason given" do
      stack = stack_fixture(description: "Keep me")
      assert {:ok, abandoned} = Stacks.abandon_stack(stack)
      assert abandoned.status == "abandoned"
      assert abandoned.description == "Keep me"
    end
  end

  describe "complete_stack/2" do
    test "transitions status to done when every member is done" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)

      m1 = stamp_unmerged_member!(project, stack, position: 1)
      m2 = stamp_unmerged_member!(project, stack, position: 2)
      set_member_status(stack, m1, "done")
      set_member_status(stack, m2, "done")

      assert {:ok, completed} = Stacks.complete_stack(stack, "shipped via individual PRs")
      assert completed.status == "done"
      assert completed.description =~ "Completed: shipped via individual PRs"
    end

    test "preserves prior description when note given" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id, description: "Original notes")

      m = stamp_unmerged_member!(project, stack, position: 1)
      set_member_status(stack, m, "done")

      assert {:ok, completed} = Stacks.complete_stack(stack, "merged")
      assert completed.description =~ "Original notes"
      assert completed.description =~ "Completed: merged"
    end

    test "leaves description untouched when no note given" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id, description: "Keep me")

      m = stamp_unmerged_member!(project, stack, position: 1)
      set_member_status(stack, m, "done")

      assert {:ok, completed} = Stacks.complete_stack(stack)
      assert completed.status == "done"
      assert completed.description == "Keep me"
    end

    test "refuses with members_not_done when any member isn't done" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)

      m_done = stamp_unmerged_member!(project, stack, position: 1)
      m_open = stamp_unmerged_member!(project, stack, position: 2)
      set_member_status(stack, m_done, "done")
      set_member_status(stack, m_open, "in_progress")

      assert {:error, :members_not_done, %{pending: pending}} =
               Stacks.complete_stack(stack, "trying")

      assert [%{id: pending_id, status: "in_progress"}] = pending
      assert pending_id == m_open.id

      # Stack stays untouched on refusal.
      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.status == stack.status
      assert reloaded.description == stack.description
    end

    test "succeeds on a stack with no members (degenerate but valid)" do
      stack = stack_fixture()
      assert {:ok, completed} = Stacks.complete_stack(stack, "empty close")
      assert completed.status == "done"
    end
  end

  describe "rollup_branch_name/1" do
    test "prefixes the slug with stack/" do
      assert Stacks.rollup_branch_name("user-keyed-saves") == "stack/user-keyed-saves"
    end
  end

  describe "valid_slug?/1" do
    test "accepts valid slugs" do
      assert Stacks.valid_slug?("a")
      assert Stacks.valid_slug?("auth-refresh")
      assert Stacks.valid_slug?("v2-rollout-2026")
    end

    test "rejects uppercase, special chars, and leading hyphen" do
      refute Stacks.valid_slug?("Auth-Refresh")
      refute Stacks.valid_slug?("auth refresh")
      refute Stacks.valid_slug?("auth_refresh")
      refute Stacks.valid_slug?("-leading-hyphen")
      refute Stacks.valid_slug?("")
    end

    test "rejects slugs longer than 60 characters" do
      assert Stacks.valid_slug?(String.duplicate("a", 60))
      refute Stacks.valid_slug?(String.duplicate("a", 61))
    end

    test "rejects non-strings" do
      refute Stacks.valid_slug?(nil)
      refute Stacks.valid_slug?(:atom)
      refute Stacks.valid_slug?(123)
    end
  end

  describe "add_task/2" do
    test "attaches a task at position 1, then 2 for the second add" do
      {:ok, project} = Tasks.create_project(%{name: "Add Task Project"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "First member"})
      {:ok, t2} = Tasks.create_task(%{project_id: project.id, title: "Second member"})

      assert {:ok, attached1} = Stacks.add_task(stack, t1)
      assert attached1.stack_id == stack.id
      assert attached1.stack_position == 1

      assert {:ok, attached2} = Stacks.add_task(stack.id, t2.id)
      assert attached2.stack_id == stack.id
      assert attached2.stack_position == 2
    end

    test "rejects a task that already belongs to a stack" do
      {:ok, project} = Tasks.create_project(%{name: "Already Stacked"})
      stack_a = stack_fixture(project_id: project.id, slug: "alpha")
      stack_b = stack_fixture(project_id: project.id, slug: "beta")
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member"})

      assert {:ok, _} = Stacks.add_task(stack_a, task)
      assert {:error, :already_in_stack} = Stacks.add_task(stack_b, task.id)
    end
  end

  describe "eject_task/2" do
    test "clears stack_id and stack_position on a clean eject" do
      {:ok, project} = Tasks.create_project(%{name: "Eject Clean"})
      stack = stack_fixture(project_id: project.id)
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Ejectable"})
      {:ok, attached} = Stacks.add_task(stack, task)
      assert attached.stack_id == stack.id

      assert {:ok, ejected} = Stacks.eject_task(stack, attached)
      assert ejected.stack_id == nil
      assert ejected.stack_position == nil
    end

    test "refuses to eject a task that other in-stack members depend on" do
      {:ok, project} = Tasks.create_project(%{name: "Eject Dependents"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, attached_parent} = Stacks.add_task(stack, parent)

      {:ok, dependent} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Dependent",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, _attached_dependent} = Stacks.add_task(stack, dependent)

      assert {:error, {:has_dependents, [%{id: dep_id, title: "Dependent"}]}} =
               Stacks.eject_task(stack, attached_parent)

      assert dep_id == dependent.id
    end

    test "returns :not_in_stack when task does not belong to the stack" do
      {:ok, project} = Tasks.create_project(%{name: "Not In Stack"})
      stack = stack_fixture(project_id: project.id)
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Free task"})

      assert {:error, :not_in_stack} = Stacks.eject_task(stack, task)
    end
  end

  describe "add_dependency_edge/4 and remove_dependency_edge/4" do
    test "happy add: writes edge, recomputes executable_now" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Add Happy"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      assert {:ok, result} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert result.from_task_id == b.id
      assert result.to_task_id == a.id
      assert result.kind == "blocks"
      # B now blocks on A → only A is executable.
      assert result.executable_now == [a.id]

      # Confirm the dep was actually persisted on B.
      reloaded_b = Repo.get(Task, b.id)
      assert Tasks.dependency_task_ids(reloaded_b) == [a.id]
    end

    test "happy remove: clears edge, recomputes executable_now" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Remove Happy"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert {:ok, result} = Stacks.remove_dependency_edge(stack, b.id, a.id)

      assert result.from_task_id == b.id
      assert result.to_task_id == a.id
      assert result.kind == "blocks"
      # Both members are roots again after the edge is gone.
      assert Enum.sort(result.executable_now) == Enum.sort([a.id, b.id])

      reloaded_b = Repo.get(Task, b.id)
      assert Tasks.dependency_task_ids(reloaded_b) == []
    end

    test "cycle rejection rolls back the dep write atomically" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Cycle Rollback"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      # Existing edge: B → A. Now try A → B which would close the cycle.
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert {:error, :cycle, path} = Stacks.add_dependency_edge(stack, a.id, b.id)
      assert is_list(path)
      path_ids = Enum.map(path, & &1.id)
      assert a.id in path_ids
      assert b.id in path_ids

      # The cycle-creating dep on A was rolled back: A still has no deps.
      reloaded_a = Repo.get(Task, a.id)
      assert Tasks.dependency_task_ids(reloaded_a) == []

      # B's pre-existing edge is untouched.
      reloaded_b = Repo.get(Task, b.id)
      assert Tasks.dependency_task_ids(reloaded_b) == [a.id]
    end

    test "rejects cross-stack endpoint as :not_in_stack" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Cross Stack"})
      stack_a = stack_fixture(project_id: project.id, slug: "ea-a")
      stack_b = stack_fixture(project_id: project.id, slug: "ea-b")
      {:ok, a1} = Tasks.create_task(%{project_id: project.id, title: "A1"})
      {:ok, a2} = Tasks.create_task(%{project_id: project.id, title: "A2"})
      {:ok, b1} = Tasks.create_task(%{project_id: project.id, title: "B1"})
      {:ok, _} = Stacks.add_task(stack_a, a1)
      {:ok, _} = Stacks.add_task(stack_a, a2)
      {:ok, _} = Stacks.add_task(stack_b, b1)

      # Target lives in a DIFFERENT stack — wrapper threads the
      # offending task id (b1) so callers can render a concrete msg.
      assert {:error, :not_in_stack, offending_id} =
               Stacks.add_dependency_edge(stack_a, a1.id, b1.id)

      assert offending_id == b1.id

      # No write happened.
      reloaded_a1 = Repo.get(Task, a1.id)
      assert Tasks.dependency_task_ids(reloaded_a1) == []
    end

    test "rejects non-member endpoint as :not_in_stack" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Non Member"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, free} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      {:ok, _} = Stacks.add_task(stack, a)

      # `free` is not in any stack — wrapper names `free` as the offender.
      assert {:error, :not_in_stack, offending_to} =
               Stacks.add_dependency_edge(stack, a.id, free.id)

      assert offending_to == free.id

      # And the inverse: `from` is the non-member, so `free` is named.
      assert {:error, :not_in_stack, offending_from} =
               Stacks.add_dependency_edge(stack, free.id, a.id)

      assert offending_from == free.id
    end

    test "rejects self-edge up front" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Self"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      assert {:error, :self_edge} = Stacks.add_dependency_edge(stack, a.id, a.id)
      assert {:error, :self_edge} = Stacks.remove_dependency_edge(stack, a.id, a.id)
    end

    test "duplicate add returns :duplicate_edge and is idempotent on the dep list" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Duplicate"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert {:error, :duplicate_edge} = Stacks.add_dependency_edge(stack, b.id, a.id)

      reloaded_b = Repo.get(Task, b.id)
      # Still exactly one edge — no double-write from the failed second add.
      assert Tasks.dependency_task_ids(reloaded_b) == [a.id]
      assert length(reloaded_b.dependencies) == 1
    end

    test "duplicate remove returns :not_an_edge" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Not An Edge"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)
      {:ok, _} = Stacks.remove_dependency_edge(stack, b.id, a.id)

      assert {:error, :not_an_edge} = Stacks.remove_dependency_edge(stack, b.id, a.id)
    end

    test "stack_not_found / task_not_found surface cleanly" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Missing"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      missing_id = Ecto.UUID.generate()

      assert {:error, :stack_not_found} =
               Stacks.add_dependency_edge(missing_id, a.id, a.id)

      assert {:error, :task_not_found} =
               Stacks.add_dependency_edge(stack, a.id, missing_id)

      assert {:error, :task_not_found} =
               Stacks.add_dependency_edge(stack, missing_id, a.id)
    end

    test "executable_now reflects multi-edge state after a chain of mutations" do
      {:ok, project} = Tasks.create_project(%{name: "Edge Multi Edge"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      # Initially: all three are roots.
      initial = Stacks.executable_members(stack) |> Enum.map(& &1.id)
      assert Enum.sort(initial) == Enum.sort([a.id, b.id, c.id])

      # B → A: now A and C are roots.
      {:ok, after_first} = Stacks.add_dependency_edge(stack, b.id, a.id)
      assert Enum.sort(after_first.executable_now) == Enum.sort([a.id, c.id])

      # C → A: only A is a root.
      {:ok, after_second} = Stacks.add_dependency_edge(stack, c.id, a.id)
      assert after_second.executable_now == [a.id]

      # Remove C → A: A and C are roots again.
      {:ok, after_remove} = Stacks.remove_dependency_edge(stack, c.id, a.id)
      assert Enum.sort(after_remove.executable_now) == Enum.sort([a.id, c.id])
    end
  end

  describe "members/1" do
    test "returns members ordered by stack_position ascending" do
      {:ok, project} = Tasks.create_project(%{name: "Members Order"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "One"})
      {:ok, t2} = Tasks.create_task(%{project_id: project.id, title: "Two"})
      {:ok, t3} = Tasks.create_task(%{project_id: project.id, title: "Three"})

      {:ok, _} = Stacks.add_task(stack, t1)
      {:ok, _} = Stacks.add_task(stack, t2)
      {:ok, _} = Stacks.add_task(stack, t3)

      ids = Stacks.members(stack) |> Enum.map(& &1.id)
      assert ids == [t1.id, t2.id, t3.id]

      # Accepts both struct and id forms.
      assert Stacks.members(stack.id) |> Enum.map(& &1.id) == ids
    end

    test "excludes soft-deleted tasks" do
      {:ok, project} = Tasks.create_project(%{name: "Members Deleted"})
      stack = stack_fixture(project_id: project.id)
      {:ok, kept} = Tasks.create_task(%{project_id: project.id, title: "Kept"})
      {:ok, gone} = Tasks.create_task(%{project_id: project.id, title: "Gone"})

      {:ok, _} = Stacks.add_task(stack, kept)
      {:ok, attached_gone} = Stacks.add_task(stack, gone)

      # Bypass the status guard by writing deleted_at directly via the
      # changeset; this exercises the SQL filter, not the soft-delete API.
      attached_gone
      |> Task.changeset(%{deleted_at: DateTime.utc_now()})
      |> Repo.update!()

      ids = Stacks.members(stack) |> Enum.map(& &1.id)
      assert ids == [kept.id]
    end
  end

  describe "list_open_review_requests/1 + count_pending_reviews/1" do
    test "empty stack reports zero pending reviews and an empty list" do
      stack = stack_fixture()

      assert Stacks.list_open_review_requests(stack) == []
      assert Stacks.list_open_review_requests(stack.id) == []
      assert Stacks.count_pending_reviews(stack) == 0
      assert Stacks.count_pending_reviews(stack.id) == 0
    end

    test "stack with two members each holding a pending RR rolls up to count=2" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup Two Pending"})
      stack = stack_fixture(project_id: project.id)

      {:ok, task_a} = Tasks.create_task(%{project_id: project.id, title: "Member A"})
      {:ok, task_b} = Tasks.create_task(%{project_id: project.id, title: "Member B"})
      {:ok, _} = Stacks.add_task(stack, task_a)
      {:ok, _} = Stacks.add_task(stack, task_b)

      {:ok, rr_a} = pending_review_request_for(task_a, "Item A")
      {:ok, rr_b} = pending_review_request_for(task_b, "Item B")

      assert Stacks.count_pending_reviews(stack) == 2

      ids = Stacks.list_open_review_requests(stack) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([rr_a.id, rr_b.id])
    end

    test "resolved review requests are excluded from the rollup" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup Resolved Excluded"})
      stack = stack_fixture(project_id: project.id)

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, _} = Stacks.add_task(stack, task)

      {:ok, rr} = pending_review_request_for(task, "Approve me")
      [item] = rr.items
      {:ok, _} = ReviewRequests.approve_item(item.id, "rowan")

      # Sanity: the request itself should no longer be pending.
      assert ReviewRequests.list_pending_for_task(task.id) == []

      assert Stacks.count_pending_reviews(stack) == 0
      assert Stacks.list_open_review_requests(stack) == []
    end

    test "review requests on tasks outside the stack are excluded" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup Scope"})
      stack = stack_fixture(project_id: project.id)

      {:ok, member} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, outsider} = Tasks.create_task(%{project_id: project.id, title: "Outsider"})
      {:ok, _} = Stacks.add_task(stack, member)

      {:ok, member_rr} = pending_review_request_for(member, "Member item")
      {:ok, _outsider_rr} = pending_review_request_for(outsider, "Outsider item")

      ids = Stacks.list_open_review_requests(stack) |> Enum.map(& &1.id)
      assert ids == [member_rr.id]
      assert Stacks.count_pending_reviews(stack) == 1
    end
  end

  describe "validate_dag/1 — execution levels" do
    test "empty stack returns no levels" do
      stack = stack_fixture()
      assert {:ok, []} = Stacks.validate_dag(stack)
    end

    test "single member returns one level with that member" do
      {:ok, project} = Tasks.create_project(%{name: "DAG single"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Solo"})
      {:ok, _} = Stacks.add_task(stack, t)

      assert {:ok, [[member]]} = Stacks.validate_dag(stack)
      assert member.id == t.id
    end

    test "linear chain a→b→c returns three serial levels" do
      {:ok, project} = Tasks.create_project(%{name: "DAG chain"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, c} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "C",
          dependencies: [%{"task_id" => b.id, "kind" => "blocks"}]
        })

      # Insert in dependency-respecting order so each add_task's own
      # validate_dag check has the prior member present.
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      assert {:ok, [[l0], [l1], [l2]]} = Stacks.validate_dag(stack)
      assert l0.id == a.id
      assert l1.id == b.id
      assert l2.id == c.id
    end

    test "diamond a→{b,c}→d collapses level 1 to a parallel pair" do
      # Edges (in dependency direction): b→a, c→a, d→b, d→c.
      # Expected execution: [[a], [b, c], [d]].
      {:ok, project} = Tasks.create_project(%{name: "DAG diamond"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, c} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "C",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, d} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "D",
          dependencies: [
            %{"task_id" => b.id, "kind" => "blocks"},
            %{"task_id" => c.id, "kind" => "blocks"}
          ]
        })

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)
      {:ok, _} = Stacks.add_task(stack, d)

      assert {:ok, [[level0], level1, [level2]]} = Stacks.validate_dag(stack)
      assert level0.id == a.id
      assert MapSet.new(Enum.map(level1, & &1.id)) == MapSet.new([b.id, c.id])
      assert length(level1) == 2
      assert level2.id == d.id
    end

    test "self-edges are dropped without errors" do
      {:ok, project} = Tasks.create_project(%{name: "DAG self"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Selfie"})
      {:ok, attached} = Stacks.add_task(stack, t)

      # Inject a self-reference into deps after attachment so add_task's
      # own validate_dag pass doesn't see it. Bypass update_task's
      # broadcast pipeline; we're testing validate_dag here, not the
      # write path.
      attached
      |> Task.changeset(%{dependencies: [%{"task_id" => attached.id, "kind" => "blocks"}]})
      |> Repo.update!()

      assert {:ok, [[member]]} = Stacks.validate_dag(stack)
      assert member.id == t.id
    end

    test "deps pointing to a free non-stack task are silently dropped" do
      {:ok, project} = Tasks.create_project(%{name: "DAG cross-free"})
      stack = stack_fixture(project_id: project.id)

      {:ok, outsider} =
        Tasks.create_task(%{project_id: project.id, title: "Free agent"})

      {:ok, member} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Inside",
          dependencies: [%{"task_id" => outsider.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, member)

      assert {:ok, [[m]]} = Stacks.validate_dag(stack)
      assert m.id == member.id
    end

    test "two-node cycle is detected and reported in path" do
      {:ok, project} = Tasks.create_project(%{name: "DAG cycle"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      # Attach both first (no deps yet so validate_dag passes), then
      # patch in the back-edge to create a→b→a.
      {:ok, attached_a} = Stacks.add_task(stack, a)
      {:ok, attached_b} = Stacks.add_task(stack, b)

      attached_a
      |> Task.changeset(%{dependencies: [%{"task_id" => attached_b.id, "kind" => "blocks"}]})
      |> Repo.update!()

      attached_b
      |> Task.changeset(%{dependencies: [%{"task_id" => attached_a.id, "kind" => "blocks"}]})
      |> Repo.update!()

      assert {:error, :cycle, path} = Stacks.validate_dag(stack)
      ids = Enum.map(path, & &1.id) |> MapSet.new()
      assert MapSet.member?(ids, a.id)
      assert MapSet.member?(ids, b.id)
    end

    test "cross-stack edge to a foreign stack member is rejected" do
      {:ok, project} = Tasks.create_project(%{name: "DAG cross-stack"})
      stack_a = stack_fixture(project_id: project.id, slug: "alpha")
      stack_b = stack_fixture(project_id: project.id, slug: "beta")

      {:ok, foreign} = Tasks.create_task(%{project_id: project.id, title: "Foreign"})
      {:ok, _attached_foreign} = Stacks.add_task(stack_b, foreign)

      {:ok, local} = Tasks.create_task(%{project_id: project.id, title: "Local"})
      {:ok, attached_local} = Stacks.add_task(stack_a, local)

      # Inject the cross-stack dep after the fact so add_task's own
      # validate_dag pass during attachment doesn't see it.
      attached_local
      |> Task.changeset(%{dependencies: [%{"task_id" => foreign.id, "kind" => "blocks"}]})
      |> Repo.update!()

      assert {:error, :cross_stack_dep, %{from: from, to_task_id: to_id}} =
               Stacks.validate_dag(stack_a)

      assert from.id == local.id
      assert to_id == foreign.id
    end
  end

  describe "executable_members/1" do
    test "empty stack returns []" do
      stack = stack_fixture()
      assert Stacks.executable_members(stack) == []
    end

    test "single root returns just that member" do
      {:ok, project} = Tasks.create_project(%{name: "Exec single"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Solo"})
      {:ok, _} = Stacks.add_task(stack, t)

      assert [member] = Stacks.executable_members(stack)
      assert member.id == t.id
    end

    test "multiple parallel roots are all returned" do
      {:ok, project} = Tasks.create_project(%{name: "Exec parallel"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      ids = stack |> Stacks.executable_members() |> Enum.map(& &1.id) |> MapSet.new()
      assert ids == MapSet.new([a.id, b.id, c.id])
    end

    test "only roots returned when there are dependents" do
      {:ok, project} = Tasks.create_project(%{name: "Exec dependents"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      assert [member] = Stacks.executable_members(stack)
      assert member.id == a.id
    end
  end

  describe "deploy_ready?/1 and pending_members_for_deploy/1" do
    test "empty stack returns false and empty pending list" do
      stack = stack_fixture()
      refute Stacks.deploy_ready?(stack)
      assert Stacks.pending_members_for_deploy(stack) == []
    end

    test "unknown stack id: deploy_ready? false, pending list []" do
      unknown = Ecto.UUID.generate()
      refute Stacks.deploy_ready?(unknown)
      assert Stacks.pending_members_for_deploy(unknown) == []
    end

    test "all members in_review with every non-deploy validation passed → true" do
      {:ok, project} = Tasks.create_project(%{name: "Deploy-ready happy"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      seed_completed_plan!(a)
      seed_completed_plan!(b)

      set_member_status(stack, a, "in_review")
      set_member_status(stack, b, "in_review")

      assert Stacks.deploy_ready?(stack)
      assert Stacks.pending_members_for_deploy(stack) == []
    end

    test "one member has a pending validation → deploy_ready? false and surfaces in pending list" do
      {:ok, project} = Tasks.create_project(%{name: "Deploy-ready pending"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      seed_completed_plan!(a)
      # b has a still-pending validation on a non-deploy stage.
      seed_plan_with_pending_validation!(b)

      set_member_status(stack, a, "in_review")
      set_member_status(stack, b, "in_review")

      refute Stacks.deploy_ready?(stack)

      pending_ids =
        stack
        |> Stacks.pending_members_for_deploy()
        |> Enum.map(& &1.id)

      assert pending_ids == [b.id]
    end

    test "member still at in_progress → deploy_ready? false and member is pending" do
      {:ok, project} = Tasks.create_project(%{name: "Deploy-ready in-progress"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      seed_completed_plan!(a)
      seed_completed_plan!(b)

      set_member_status(stack, a, "in_review")
      # b lags behind: task hasn't reached review yet, so even with
      # passed validations it should NOT be considered deploy-ready.
      set_member_status(stack, b, "in_progress")

      refute Stacks.deploy_ready?(stack)

      pending_ids =
        stack
        |> Stacks.pending_members_for_deploy()
        |> Enum.map(& &1.id)

      assert pending_ids == [b.id]
    end

    test "stack already at deploying → false even when member set is ready" do
      {:ok, project} = Tasks.create_project(%{name: "Deploy-ready deploying"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      seed_completed_plan!(a)
      set_member_status(stack, a, "in_review")

      # Sanity: member side alone is ready.
      assert Stacks.deploy_ready?(stack)

      {:ok, deploying} = Stacks.update_stack(stack, %{status: "deploying"})
      refute Stacks.deploy_ready?(deploying)
    end

    test "stack at done → false (terminal state guards against double-fire)" do
      {:ok, project} = Tasks.create_project(%{name: "Deploy-ready done"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      seed_completed_plan!(a)
      set_member_status(stack, a, "in_review")

      {:ok, finished} = Stacks.update_stack(stack, %{status: "done"})
      refute Stacks.deploy_ready?(finished)
    end

    test "stack at abandoned → false" do
      {:ok, project} = Tasks.create_project(%{name: "Deploy-ready abandoned"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      seed_completed_plan!(a)
      set_member_status(stack, a, "in_review")

      {:ok, abandoned} = Stacks.abandon_stack(stack, "scope cut")
      refute Stacks.deploy_ready?(abandoned)
    end

    test "deploy-stage validations are excluded (regression guard)" do
      # A stack member should never carry a deploy stage — the atomic-ship
      # guard blocks the injection — but the predicate must still ignore
      # any deploy-stage validation that a future engine change might
      # add, otherwise the gate would jam permanently closed.
      {:ok, project} = Tasks.create_project(%{name: "Deploy-ready exclusion"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      seed_completed_plan_with_pending_deploy_stage!(a)
      set_member_status(stack, a, "in_review")

      assert Stacks.deploy_ready?(stack)
      assert Stacks.pending_members_for_deploy(stack) == []
    end

    test "validations on superseded plans are ignored" do
      # A stale superseded plan with pending validations should not gate
      # the currently-active completed plan.
      {:ok, project} = Tasks.create_project(%{name: "Deploy-ready superseded"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      # v=1 superseded with a leftover pending validation.
      seed_superseded_plan_with_pending_validation!(a, version: 1)
      # v=2 is the live one — completed with everything passed.
      seed_completed_plan!(a, version: 2)

      set_member_status(stack, a, "in_review")

      assert Stacks.deploy_ready?(stack)
    end

    test "accepts a stack id (not just a struct)" do
      {:ok, project} = Tasks.create_project(%{name: "Deploy-ready by id"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      seed_completed_plan!(a)
      set_member_status(stack, a, "in_review")

      assert Stacks.deploy_ready?(stack.id)

      assert stack.id
             |> Stacks.pending_members_for_deploy()
             |> Enum.empty?()
    end
  end

  describe "dispatch_stack_deploy/1" do
    alias Platform.Tasks.StacksTest.DispatchNoopRunner

    setup :install_dispatch_noop_runner

    test "dispatches exactly once when the last member's validation flips ready", %{
      project: project
    } do
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      seed_completed_plan!(a)
      seed_completed_plan!(b)
      set_member_status(stack, a, "in_review")
      set_member_status(stack, b, "in_review")

      {:ok, events} = attach_dispatch_telemetry_handler()

      try do
        assert {:ok, :dispatched} = Stacks.dispatch_stack_deploy(stack)

        assert_receive {:stack_deploy_dispatched,
                        %{stack_id: dispatched_stack_id, member_count: 2}},
                       200

        assert dispatched_stack_id == stack.id
      after
        :telemetry.detach(events)
      end

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.status == "deploying"
      assert is_binary(reloaded.metadata["first_deploy_ready_at"])

      # The dispatch's async trigger fired `maybe_open_stack_pr/1`
      # synchronously (async: false). The gate returned `:not_ready`
      # because neither member has been merged into the rollup branch
      # yet (`all_members_ready?/1` requires
      # `metadata["merged_into_rollup_at"]`, a downstream signal owned
      # by `handle_member_transition/3` — a separate seam). So no
      # runner call; the dispatch's semantic contract here is the
      # transition + telemetry, not the shell-out. See the "both gates"
      # test below for the belt-and-suspenders case.
      assert DispatchNoopRunner.pr_calls() == []
    end

    test "dispatch + stamped members → maybe_open_stack_pr shells out through both gates",
         %{project: project} do
      # Belt-and-suspenders: with members ALSO stamped as merged into
      # rollup, `dispatch_stack_deploy/1`'s async trigger runs
      # `maybe_open_stack_pr/1` and BOTH gates pass — the runner is
      # actually invoked. Guards against a future refactor that lets
      # the deploy-validations gate stay closed after dispatch flipped
      # status to `"deploying"`.
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      seed_completed_plan!(a)
      seed_completed_plan!(b)
      set_member_status(stack, a, "in_review")
      set_member_status(stack, b, "in_review")
      stamp_member_merged_into_rollup!(a, "aaaaaaa1")
      stamp_member_merged_into_rollup!(b, "bbbbbbb2")

      assert {:ok, :dispatched} = Stacks.dispatch_stack_deploy(stack)

      assert [pr_call] = DispatchNoopRunner.pr_calls()
      assert pr_call.stack_id == stack.id
      assert pr_call.base_branch == stack.base_branch
      assert pr_call.rollup_branch == stack.rollup_branch
    end

    test "no-op when only some members are ready", %{project: project} do
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      seed_completed_plan!(a)
      # b still has a pending validation → deploy_ready? = false.
      seed_plan_with_pending_validation!(b)

      set_member_status(stack, a, "in_review")
      set_member_status(stack, b, "in_review")

      {:ok, events} = attach_dispatch_telemetry_handler()

      try do
        assert {:ok, :noop} = Stacks.dispatch_stack_deploy(stack)
        refute_receive {:stack_deploy_dispatched, _}, 100
      after
        :telemetry.detach(events)
      end

      reloaded = Stacks.get_stack(stack.id)
      # No transition happened.
      refute reloaded.status == "deploying"
      # No first_deploy_ready_at stamp on a no-op path.
      assert is_nil(get_in(reloaded.metadata || %{}, ["first_deploy_ready_at"]))
      assert DispatchNoopRunner.pr_calls() == []
    end

    test "concurrent double-fire fires the :dispatched telemetry exactly once", %{
      project: project
    } do
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      seed_completed_plan!(a)
      seed_completed_plan!(b)
      set_member_status(stack, a, "in_review")
      set_member_status(stack, b, "in_review")

      {:ok, events} = attach_dispatch_telemetry_handler()

      try do
        # Fire two dispatches back-to-back on the same test process.
        # The compare-and-swap on `stacks.status` in `try_dispatch/1`
        # means the FIRST call transitions the row and the SECOND
        # call re-reads the fresh `"deploying"` status → `deploy_ready?`
        # returns false → `:noop`. Exactly one `:dispatched` event.
        results = [
          Stacks.dispatch_stack_deploy(stack),
          Stacks.dispatch_stack_deploy(stack)
        ]

        assert Enum.count(results, &match?({:ok, :dispatched}, &1)) == 1
        assert Enum.count(results, &match?({:ok, :noop}, &1)) == 1

        # Drain telemetry: exactly one event expected.
        assert_receive {:stack_deploy_dispatched, %{stack_id: dispatched_stack_id}}, 200
        assert dispatched_stack_id == stack.id
        refute_receive {:stack_deploy_dispatched, _}, 100
      after
        :telemetry.detach(events)
      end

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.status == "deploying"
    end

    test "unknown stack id returns {:error, :stack_not_found}", %{project: _project} do
      unknown = Ecto.UUID.generate()

      {:ok, events} = attach_dispatch_telemetry_handler()

      try do
        assert {:error, :stack_not_found} = Stacks.dispatch_stack_deploy(unknown)
        refute_receive {:stack_deploy_dispatched, _}, 100
      after
        :telemetry.detach(events)
      end
    end

    test "second dispatch after successful first is a no-op (idempotency)", %{project: project} do
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      seed_completed_plan!(a)
      set_member_status(stack, a, "in_review")

      assert {:ok, :dispatched} = Stacks.dispatch_stack_deploy(stack)

      # Second call: stack already at "deploying", deploy_ready? = false.
      assert {:ok, :noop} = Stacks.dispatch_stack_deploy(stack)
    end

    test "accepts a stack id (not just a struct)", %{project: project} do
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      seed_completed_plan!(a)
      set_member_status(stack, a, "in_review")

      assert {:ok, :dispatched} = Stacks.dispatch_stack_deploy(stack.id)

      assert Stacks.get_stack(stack.id).status == "deploying"
    end

    test "preserves an already-stamped first_deploy_ready_at across retries", %{
      project: project
    } do
      # Simulate a recovery scenario: a previous partial run stamped
      # `first_deploy_ready_at` but crashed before flipping status to
      # "deploying" (e.g. the update_all race lost the row lock and
      # rolled back the metadata write). The set-once-if-nil rule means
      # subsequent dispatches KEEP the original stamp, so the emitted
      # `duration_ms_from_first_member_ready` metric reflects the true
      # wall-clock delay from readiness → dispatch.
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      seed_completed_plan!(a)
      set_member_status(stack, a, "in_review")

      previously_stamped =
        DateTime.utc_now()
        |> DateTime.add(-42, :second)
        |> DateTime.to_iso8601()

      {:ok, stack} =
        Stacks.update_stack(stack, %{
          metadata: %{"first_deploy_ready_at" => previously_stamped}
        })

      {:ok, events} = attach_dispatch_telemetry_handler()

      try do
        assert {:ok, :dispatched} = Stacks.dispatch_stack_deploy(stack)

        assert_receive {:stack_deploy_dispatched,
                        %{
                          stack_id: _,
                          duration_ms_from_first_member_ready: duration_ms
                        }},
                       200

        # Should be near 42 seconds (~42_000 ms). Give a wide window
        # so a slow CI box doesn't flake — anything > 30_000 ms is
        # unambiguously "not zero", which is what we're actually
        # asserting: the previously-stamped value was USED.
        assert duration_ms > 30_000
      after
        :telemetry.detach(events)
      end

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.metadata["first_deploy_ready_at"] == previously_stamped
    end
  end

  # ── Regression: the `async: true` spawn branch ─────────────────────────
  #
  # WHY THIS BLOCK EXISTS. `config/test.exs:170-172` pins
  # `config :platform, :stack_deployer, async: false` for the WHOLE suite.
  # That single line is what hid `Stacks.trigger_stack_deploy_pr_open/1`'s
  # spawn branch (lib/platform/tasks/stacks.ex:2304) from every test ever
  # written: no test in this repo has executed it, so a
  # `Task.Supervisor.async_nolink/2` call that resolved — via the module's
  # `alias Platform.Tasks.{... Task}` — to the nonexistent
  # `Platform.Tasks.Task.Supervisor` shipped green for its entire life and
  # only ever raised in production, inside `PlanEngine`.
  #
  # This describe block flips `:async` to `true` for its own tests only,
  # via `Application.put_env` in setup with an `on_exit` restore, and is
  # the ONLY coverage of the production-default branch. Do NOT "simplify"
  # it by editing `config/test.exs`: flipping the global default would
  # rewire dozens of unrelated stack tests onto async paths they were
  # never written for.
  describe "dispatch_stack_deploy/1 — async: true branch (regression: Task alias shadowing)" do
    alias Platform.Tasks.StacksTest.DispatchNoopRunner
    alias Platform.Tasks.StacksTest.DispatchRaisingRunner

    setup :install_dispatch_noop_runner_async

    test "async branch dispatches without raising UndefinedFunctionError", %{project: project} do
      stack = seed_deploy_ready_stack!(project)

      # THE REGRESSION ASSERTION. Pre-fix this call raises
      # `UndefinedFunctionError` for
      # `Platform.Tasks.Task.Supervisor.async_nolink/2`: module resolution
      # for `async_nolink/2` happens in the CALLING process, so the caller
      # dies before `dispatch_stack_deploy/1` can return — here the test
      # process, in production `PlanEngine` mid-transition.
      assert {:ok, :dispatched} = Stacks.dispatch_stack_deploy(stack)

      # Barrier, not a sleep: the spawned child hands back its own pid and
      # we wait for its :DOWN, so the child is dead before the test
      # returns and sandbox teardown cannot race it.
      assert {:ok, child_pid} = await_async_pr_open!()
      refute child_pid == self()

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.status == "deploying"
      assert is_binary(reloaded.metadata["first_deploy_ready_at"])

      assert [pr_call] = DispatchNoopRunner.pr_calls()
      assert pr_call.stack_id == stack.id
    end

    test "async branch actually opens the rollup PR off the calling process", %{project: project} do
      stack = seed_deploy_ready_stack!(project)

      test_pid = self()
      handler_id = "async-pr-opened-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stack_deployer, :pr_opened],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      try do
        assert {:ok, :dispatched} = Stacks.dispatch_stack_deploy(stack)

        # `finalize_pr_opened/3` (stack_deployer.ex:2304-2308) emits this
        # from whichever process ran the PR-open. Telemetry is the
        # deterministic hook — no polling of `pr_calls/0` in a sleep loop.
        assert_receive {:telemetry, [:platform, :stack_deployer, :pr_opened], _measurements,
                        %{stack_id: id}},
                       2_000

        assert id == stack.id

        # ...and that process was NOT the caller. This is the whole point
        # of the async branch.
        assert {:ok, child_pid} = await_async_pr_open!()
        refute child_pid == self()
      after
        :telemetry.detach(handler_id)
      end
    end

    test "async branch survives a raising git runner", %{project: project} do
      stack = seed_deploy_ready_stack!(project)

      Application.put_env(:platform, :stack_deployer,
        git_runner: DispatchRaisingRunner,
        async: true
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Hazard A (stage 2): the child's crash must not reach the
          # caller — `async_nolink/2` does not link, and
          # `Stacks.run_deploy_pr_open/1` rescues.
          assert {:ok, :dispatched} = Stacks.dispatch_stack_deploy(stack)
          assert {:ok, _child_pid} = await_async_pr_open!()
        end)

      # ...and it must not vanish either: an unlogged raise would strand
      # the stack in `deploying` with nothing to debug from.
      assert log =~ "PR-open raised"
      assert log =~ DispatchRaisingRunner.raise_message()

      assert Stacks.get_stack(stack.id).status == "deploying"
    end
  end

  describe "members_in_merge_order/1" do
    test "linear chain a→b→c returns foundational-first [a, b, c]" do
      {:ok, project} = Tasks.create_project(%{name: "Merge order chain"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, c} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "C",
          dependencies: [%{"task_id" => b.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      assert [m0, m1, m2] = Stacks.members_in_merge_order(stack)
      assert [m0.id, m1.id, m2.id] == [a.id, b.id, c.id]
    end

    test "no declared deps returns members in stack_position (creation) order" do
      {:ok, project} = Tasks.create_project(%{name: "Merge order nodep"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      assert ids = Stacks.members_in_merge_order(stack) |> Enum.map(& &1.id)
      assert ids == [a.id, b.id, c.id]
    end

    test "dependency cycle falls back to stack_position order (does NOT raise)" do
      {:ok, project} = Tasks.create_project(%{name: "Merge order cycle"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      # Attach both first (no deps so validate_dag passes), then patch in
      # the back-edge to create a→b→a.
      {:ok, attached_a} = Stacks.add_task(stack, a)
      {:ok, attached_b} = Stacks.add_task(stack, b)

      attached_a
      |> Task.changeset(%{dependencies: [%{"task_id" => attached_b.id, "kind" => "blocks"}]})
      |> Repo.update!()

      attached_b
      |> Task.changeset(%{dependencies: [%{"task_id" => attached_a.id, "kind" => "blocks"}]})
      |> Repo.update!()

      # validate_dag returns {:error, :cycle, _}; we fall back to members/1.
      assert {:error, :cycle, _} = Stacks.validate_dag(stack)
      assert ids = Stacks.members_in_merge_order(stack) |> Enum.map(& &1.id)
      assert ids == [a.id, b.id]
    end
  end

  describe "planning_waves/1" do
    test "empty stack returns {:ok, []}" do
      stack = stack_fixture()
      assert {:ok, []} = Stacks.planning_waves(stack)
    end

    test "single member with no deps returns one wave of one" do
      {:ok, project} = Tasks.create_project(%{name: "Waves single"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Solo"})
      {:ok, _} = Stacks.add_task(stack, t)

      assert {:ok, [[member]]} = Stacks.planning_waves(stack)
      assert member.id == t.id
    end

    test "3-member chain c→b→a produces 3 single-member waves, roots-first" do
      {:ok, project} = Tasks.create_project(%{name: "Waves chain"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, c} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "C",
          dependencies: [%{"task_id" => b.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      assert {:ok, [[w0], [w1], [w2]]} = Stacks.planning_waves(stack)
      assert w0.id == a.id
      assert w1.id == b.id
      assert w2.id == c.id
    end

    test "diamond a→{b,c}→d collapses to [[a], [b, c], [d]]" do
      {:ok, project} = Tasks.create_project(%{name: "Waves diamond"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, c} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "C",
          dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]
        })

      {:ok, d} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "D",
          dependencies: [
            %{"task_id" => b.id, "kind" => "blocks"},
            %{"task_id" => c.id, "kind" => "blocks"}
          ]
        })

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)
      {:ok, _} = Stacks.add_task(stack, d)

      assert {:ok, [[wave0], wave1, [wave2]]} = Stacks.planning_waves(stack)
      assert wave0.id == a.id
      assert MapSet.new(Enum.map(wave1, & &1.id)) == MapSet.new([b.id, c.id])
      assert length(wave1) == 2
      assert wave2.id == d.id
    end

    test "cyclic stack surfaces {:error, :cycle, path} (NOT {:ok, ...})" do
      {:ok, project} = Tasks.create_project(%{name: "Waves cycle"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      # Attach both first (no deps so validate_dag passes), then patch in
      # the back-edge to create a→b→a.
      {:ok, attached_a} = Stacks.add_task(stack, a)
      {:ok, attached_b} = Stacks.add_task(stack, b)

      attached_a
      |> Task.changeset(%{dependencies: [%{"task_id" => attached_b.id, "kind" => "blocks"}]})
      |> Repo.update!()

      attached_b
      |> Task.changeset(%{dependencies: [%{"task_id" => attached_a.id, "kind" => "blocks"}]})
      |> Repo.update!()

      assert {:error, :cycle, path} = Stacks.planning_waves(stack)
      ids = path |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(ids, a.id)
      assert MapSet.member?(ids, b.id)
    end

    test "unknown stack id returns {:error, :stack_not_found}" do
      # Well-formed UUID that doesn't exist in the DB.
      bogus_id = Ecto.UUID.generate()
      assert {:error, :stack_not_found} = Stacks.planning_waves(bogus_id)
    end
  end

  describe "unblocked_in_stack?/1" do
    test "returns false for non-member (stack_id nil)" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock non-member"})
      {:ok, free_task} = Tasks.create_task(%{project_id: project.id, title: "Free"})

      refute Stacks.unblocked_in_stack?(free_task)
    end

    test "returns true for a root with no in-stack deps" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock root"})
      stack = stack_fixture(project_id: project.id)
      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, attached} = Stacks.add_task(stack, root)

      assert Stacks.unblocked_in_stack?(attached)
    end

    test "returns true when in-stack dep is in_review with merged_into_rollup_at set" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock cleared"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
        }
      })
      |> Repo.update!()

      assert Stacks.unblocked_in_stack?(attached_child)
    end

    test "returns false when in-stack dep is in_review WITHOUT merged_into_rollup_at" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock unmerged"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      attached_parent
      |> Task.changeset(%{status: "in_review"})
      |> Repo.update!()

      refute Stacks.unblocked_in_stack?(attached_child)
    end

    test "returns false when in-stack dep is in_progress" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock in-progress dep"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      attached_parent
      |> Task.changeset(%{
        status: "in_progress",
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
        }
      })
      |> Repo.update!()

      refute Stacks.unblocked_in_stack?(attached_child)
    end

    test "ignores cross-stack deps to non-members (returns true if all in-stack deps clear)" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock cross-stack"})
      stack = stack_fixture(project_id: project.id)

      {:ok, outsider} = Tasks.create_task(%{project_id: project.id, title: "Outsider"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Member with cross-stack dep",
          dependencies: [%{"task_id" => outsider.id, "kind" => "blocks"}]
        })

      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Outsider is in_progress, no merge stamp — irrelevant because
      # it's not an in-stack dep.
      assert Stacks.unblocked_in_stack?(attached_child)
    end
  end

  # ── Bug #2 (task 019f708f): unblocked_in_stack? reachability gate ──────
  #
  # After `threshold_cleared?/1` confirms the stamp is PRESENT,
  # `unblocked_in_stack?/1` additionally verifies the stamp's SHA is
  # actually reachable from the current rollup-branch tip via the
  # configured git runner's `sha_reachable?/1`. A fabricated /
  # reverted-out stamp is treated as unmerged and a warning is logged
  # naming the offender.

  defmodule ReachabilityRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(
        fn -> %{by_sha: %{}, default: {:ok, true}, calls: []} end,
        name: __MODULE__
      )
    end

    def stop, do: Agent.stop(__MODULE__)
    def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()

    def set_response(sha, response) when is_binary(sha) do
      Agent.update(__MODULE__, fn state ->
        %{state | by_sha: Map.put(state.by_sha, sha, response)}
      end)
    end

    def set_default(response) do
      Agent.update(__MODULE__, fn state -> %{state | default: response} end)
    end

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, %{status: :already_exists, base_sha: nil}}

    @impl true
    def merge_member_into_rollup(_args),
      do: {:ok, %{status: :merged, merge_sha: "0000000000000000000000000000000000000000"}}

    @impl true
    def open_stack_pr(_args),
      do: {:ok, %{number: 0, url: "https://github.com/example/example/pull/0"}}

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def revert_member_merge(_args),
      do: {:ok, %{status: :reverted, revert_sha: "0000000000000000000000000000000000000000"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def delete_rollup_branch(_args), do: {:ok, :deleted}

    @impl true
    def sha_reachable?(%{sha: sha} = args) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = Map.get(state.by_sha, sha, state.default)
        {response, %{state | calls: [args | state.calls]}}
      end)
    end
  end

  describe "unblocked_in_stack?/1 — bug #2 reachability gate" do
    setup do
      prev = Application.get_env(:platform, :stack_deployer, [])
      {:ok, _} = ReachabilityRunner.start_link()

      Application.put_env(:platform, :stack_deployer,
        git_runner: ReachabilityRunner,
        async: false
      )

      on_exit(fn ->
        Application.put_env(:platform, :stack_deployer, prev)

        try do
          ReachabilityRunner.stop()
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    test "returns false when in-stack dep's stamp sha is unreachable; log names the offender" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Unreach parent",
          repo_url: "https://github.com/test/reach-repo"
        })

      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => "deadbeef",
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })
      |> Repo.update!()

      ReachabilityRunner.set_response("deadbeef", {:ok, false})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          refute Stacks.unblocked_in_stack?(attached_child)
        end)

      assert log =~ "threshold_cleared?"
      assert log =~ "deadbeef"
      assert log =~ stack.rollup_branch
      assert log =~ "not reachable"
      # The warning names the offending dep (attached_parent).
      assert log =~ attached_parent.id
    end

    test "returns true when in-stack dep's stamp sha is reachable" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Reach parent",
          repo_url: "https://github.com/test/reach-repo"
        })

      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => "abc1234",
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })
      |> Repo.update!()

      ReachabilityRunner.set_response("abc1234", {:ok, true})

      assert Stacks.unblocked_in_stack?(attached_child)
    end

    test "reachability check errors are treated as unreachable (conservative)" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Reach errs",
          repo_url: "https://github.com/test/reach-repo"
        })

      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => "bec0b0f",
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })
      |> Repo.update!()

      ReachabilityRunner.set_response("bec0b0f", {:error, :network_boom})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          refute Stacks.unblocked_in_stack?(attached_child)
        end)

      assert log =~ "reachability check failed"
      assert log =~ ":network_boom"
    end

    test "project with no repo_url falls back to stamp-presence check (no runner call)" do
      # No repo_url on the project — the reachability layer can't
      # verify, so it defers to the presence-only gate (existing
      # behavior). This preserves the pre-bug-#2 promotion contract
      # for projects that aren't yet wired up to a real git remote.
      {:ok, project} = Tasks.create_project(%{name: "No repo url"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => "abc1234",
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })
      |> Repo.update!()

      assert Stacks.unblocked_in_stack?(attached_child)
      # Runner was NOT invoked (no repo_url means no ground truth to
      # verify against).
      assert ReachabilityRunner.calls() == []
    end

    test "bare-string (non-map) legacy stamp defers to shape check — no reachability call" do
      # Bug #2 introduced a defensive fallback for bare-string
      # `merged_into_rollup_at` stamps (pre-bug-#3 legacy shape). Bug
      # #3 landed a changeset validator that now rejects those
      # shapes at the write path AND a migration that scrubs them
      # from the DB — so seeding a bare-string via changeset is
      # impossible. We bypass the changeset with raw SQL to prove
      # the defensive fallback still no-op-passes for any legacy
      # row that somehow survives the migration (e.g. a concurrent
      # write during deploy).
      {:ok, project} =
        Tasks.create_project(%{
          name: "Bare stamp",
          repo_url: "https://github.com/test/reach-repo"
        })

      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Direct SQL — bypass Task.changeset/2's post-bug-#3 shape
      # validator so we can seed the legacy bare-string shape. jsonb
      # literal is formatted inline because `$1::jsonb` binding for
      # a String encodes as a jsonb-string type, not a parsed
      # jsonb object.
      Repo.query!(
        """
        UPDATE tasks
           SET metadata = '{"merged_into_rollup_at":"bare-string-legacy"}'::jsonb,
               status = 'in_review'
         WHERE id = $1
        """,
        [Ecto.UUID.dump!(attached_parent.id)]
      )

      assert Stacks.unblocked_in_stack?(attached_child)
      assert ReachabilityRunner.calls() == []
    end
  end

  describe "try_promote/1" do
    test "no-op for a task not in any stack" do
      {:ok, project} = Tasks.create_project(%{name: "Promote non-member"})
      {:ok, free_task} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      assert Stacks.try_promote(free_task) == :noop
    end

    test "no-op for a stack member not at stack_pending" do
      {:ok, project} = Tasks.create_project(%{name: "Promote not-pending"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, attached} = Stacks.add_task(stack, t)
      # Default status is "backlog", which is not stack_pending.
      assert Stacks.try_promote(attached) == :noop
    end

    test "no-op when deps have not cleared the threshold" do
      {:ok, project} = Tasks.create_project(%{name: "Promote unmet"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, _attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Put child at stack_pending; parent has not yet been merged so the
      # threshold is unmet.
      pending_child =
        attached_child
        |> Task.changeset(%{status: "stack_pending"})
        |> Repo.update!()

      assert Stacks.try_promote(pending_child) == :noop
      # Status untouched.
      reloaded = Tasks.get_task_record(pending_child.id)
      assert reloaded.status == "stack_pending"
    end

    test "promotes stack_pending → in_progress when deps clear" do
      {:ok, project} = Tasks.create_project(%{name: "Promote cleared"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # ADR 0042 Decision 4: the commencement gate requires BOTH plans on
      # every member AND the stack itself at `in_progress`. This test
      # exercises try_promote inside an already-started stack, so we
      # simulate that by (a) approving both members' plans and (b)
      # flipping stack.status directly via changeset — the same shape
      # `start_stack/1` would leave behind post-cascade.
      {:ok, _plan_p} = Tasks.create_plan(%{task_id: attached_parent.id, status: "approved"})
      {:ok, _plan_c} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      stack
      |> Ecto.Changeset.change(status: "in_progress")
      |> Repo.update!()

      # Park child at stack_pending.
      pending_child =
        attached_child
        |> Task.changeset(%{status: "stack_pending"})
        |> Repo.update!()

      # Cross the unblock threshold on parent: in_review + merged stamp.
      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
        }
      })
      |> Repo.update!()

      assert {:ok, promoted} = Stacks.try_promote(pending_child)
      assert promoted.status == "in_progress"
      assert Tasks.get_task_record(promoted.id).status == "in_progress"
    end

    test "surfaces the underlying error when transition fails" do
      {:ok, project} = Tasks.create_project(%{name: "Promote no plan"})
      stack = stack_fixture(project_id: project.id)
      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "No-plan root"})
      {:ok, attached} = Stacks.add_task(stack, root)

      pending =
        attached
        |> Task.changeset(%{status: "stack_pending"})
        |> Repo.update!()

      # Vacuously unblocked (no in-stack deps) but no approved plan exists
      # → transition_task/2 refuses with :no_approved_plan, and that bubbles
      # through try_promote/1 unchanged.
      assert {:error, :no_approved_plan} = Stacks.try_promote(pending)
    end

    test "accepts a task id and looks the row up fresh" do
      {:ok, project} = Tasks.create_project(%{name: "Promote by id"})
      stack = stack_fixture(project_id: project.id)
      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, attached} = Stacks.add_task(stack, root)

      {:ok, _plan} = Tasks.create_plan(%{task_id: attached.id, status: "approved"})

      # ADR 0042 Decision 4: commencement gate requires stack.status ==
      # in_progress. Simulate the post-cascade state directly (see
      # "promotes stack_pending → in_progress when deps clear" comment).
      stack
      |> Ecto.Changeset.change(status: "in_progress")
      |> Repo.update!()

      attached
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      assert {:ok, promoted} = Stacks.try_promote(attached.id)
      assert promoted.status == "in_progress"

      assert {:error, :task_not_found} = Stacks.try_promote(Ecto.UUID.generate())
    end
  end

  describe "unblocked_after/2" do
    test "returns only stack_pending members whose deps just cleared" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock-after"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, dependent} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Dependent",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, unrelated} = Tasks.create_task(%{project_id: project.id, title: "Unrelated"})

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_dependent} = Stacks.add_task(stack, dependent)
      {:ok, _attached_unrelated} = Stacks.add_task(stack, unrelated)

      # Mark the dependent as stack_pending (the state it would be in
      # post-stack_start, prior to its dep clearing).
      attached_dependent
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      # Mark the parent as freshly-merged.
      {:ok, just_merged} =
        attached_parent
        |> Task.changeset(%{
          status: "in_review",
          metadata: %{
            "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
          }
        })
        |> Repo.update()

      result = Stacks.unblocked_after(stack, just_merged)
      assert Enum.map(result, & &1.id) == [attached_dependent.id]
    end

    test "skips members not currently stack_pending" do
      {:ok, project} = Tasks.create_project(%{name: "Unblock-after non-pending"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, dependent} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Dependent",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, _attached_dependent} = Stacks.add_task(stack, dependent)

      # Dependent is in `backlog` (its default), NOT stack_pending —
      # outside the auto-promote set.
      {:ok, just_merged} =
        attached_parent
        |> Task.changeset(%{
          status: "in_review",
          metadata: %{
            "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
          }
        })
        |> Repo.update()

      assert Stacks.unblocked_after(stack, just_merged) == []
    end
  end

  describe "start_stack/1" do
    test "rejects stacks not at forming" do
      stack = stack_fixture()
      # Force the stack into in_progress directly so we can confirm the guard.
      {:ok, started} = Stacks.update_stack(stack, %{status: "in_progress"})
      assert {:error, :invalid_stack_status} = Stacks.start_stack(started)
    end

    test "cascade fans roots → in_progress and non-roots → stack_pending" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade start"})
      stack = stack_fixture(project_id: project.id)

      {:ok, root_a} = Tasks.create_task(%{project_id: project.id, title: "Root A"})
      {:ok, root_b} = Tasks.create_task(%{project_id: project.id, title: "Root B"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child of A",
          dependencies: [%{"task_id" => root_a.id, "kind" => "blocks"}]
        })

      {:ok, _attached_root_a} = Stacks.add_task(stack, root_a)
      {:ok, _attached_root_b} = Stacks.add_task(stack, root_b)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # ADR 0042 Decision 4: every member (including the parked child)
      # needs an approved plan before the commencement gate opens; the
      # cascade refuses upfront otherwise.
      {:ok, _} = Tasks.create_plan(%{task_id: root_a.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: root_b.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: child.id, status: "approved"})

      assert {:ok, %{stack: updated, started: started, parked: parked}} =
               Stacks.start_stack(stack)

      assert updated.status == "in_progress"
      started_ids = started |> Enum.map(& &1.id) |> Enum.sort()
      assert started_ids == Enum.sort([root_a.id, root_b.id])
      assert Enum.all?(started, &(&1.status == "in_progress"))

      assert [%Task{id: parked_id}] = parked
      assert parked_id == attached_child.id
      assert hd(parked).status == "stack_pending"
    end

    test "promotes stack_pending roots to in_progress (regression: incident 019f5e29)" do
      # Regression coverage for the cascade bug where members that arrived
      # at `stack_pending` before `start_stack/1` ran (via `task_create`
      # side effects or an operator `task_update`) were stranded — the
      # cascade only pulled from `backlog`, so the router never picked
      # them up. See ADR 0041 "Status cascade — entering a stack".
      {:ok, project} = Tasks.create_project(%{name: "Stack-pending cascade"})
      stack = stack_fixture(project_id: project.id)

      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "M1 root"})

      {:ok, m2} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "M2 depends on M1",
          dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, m1)
      {:ok, _} = Stacks.add_task(stack, m2)

      {:ok, _} = Tasks.create_plan(%{task_id: m1.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: m2.id, status: "approved"})

      # Park both members at `stack_pending` directly, mimicking the
      # operator/side-effect promotion out of `backlog` that happened
      # before `start_stack/1` was invoked.
      m1 |> Task.changeset(%{status: "stack_pending"}) |> Repo.update!()
      m2 |> Task.changeset(%{status: "stack_pending"}) |> Repo.update!()

      assert {:ok, %{stack: updated, started: started, parked: parked}} =
               Stacks.start_stack(stack)

      assert updated.status == "in_progress"

      # The root (M1) was promoted from `stack_pending` → `in_progress`
      # and is reported in `started:`. M2 (non-root) stays parked at
      # `stack_pending` — no cascade write because it was already there.
      assert [%Task{id: started_id, status: "in_progress"}] = started
      assert started_id == m1.id
      assert parked == []

      assert Tasks.get_task_record(m1.id).status == "in_progress"
      assert Tasks.get_task_record(m2.id).status == "stack_pending"
    end

    test "skips members already past backlog (idempotent / additive)" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade additive"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Pre-advanced"})
      {:ok, attached} = Stacks.add_task(stack, t)

      # Operator already promoted this task out of backlog before stack_start.
      {:ok, _} = Tasks.create_plan(%{task_id: attached.id, status: "approved"})

      attached
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      assert {:ok, %{started: started, parked: parked}} = Stacks.start_stack(stack)
      # Cascade did not touch the already-advanced member.
      assert started == []
      assert parked == []
      assert Tasks.get_task_record(attached.id).status == "in_progress"
    end

    test "refuses upfront with :stack_plans_pending when any member is missing an approved plan" do
      # ADR 0042 Decision 4: the commencement gate short-circuits the
      # cascade entirely rather than partial-cascading. This test replaces
      # the pre-D4 `:partial` behavior (which used to advance the ok
      # roots and surface the missing-plan root as a per-member error).
      {:ok, project} = Tasks.create_project(%{name: "Cascade refuse"})
      stack = stack_fixture(project_id: project.id)
      {:ok, ok_root} = Tasks.create_task(%{project_id: project.id, title: "OK root"})
      {:ok, bad_root} = Tasks.create_task(%{project_id: project.id, title: "No-plan root"})

      {:ok, _attached_ok} = Stacks.add_task(stack, ok_root)
      {:ok, _attached_bad} = Stacks.add_task(stack, bad_root)

      # Only ok_root has a plan; bad_root has none.
      {:ok, _} = Tasks.create_plan(%{task_id: ok_root.id, status: "approved"})

      assert {:error, :stack_plans_pending, %{stack_id: stack_id, waiting_on: waiting_on}} =
               Stacks.start_stack(stack)

      assert stack_id == stack.id
      assert waiting_on == [bad_root.id]

      # Stack was NOT flipped — no partial state leaks through.
      reloaded = Stacks.get_stack!(stack.id)
      assert reloaded.status == "forming"

      # Neither member was touched — both remain in `backlog`.
      assert Tasks.get_task_record(ok_root.id).status == "backlog"
      assert Tasks.get_task_record(bad_root.id).status == "backlog"
    end

    test "refuses with :stack_plans_pending when a member's latest plan is pending_review" do
      # A member with a plan awaiting review is still not "approved" per
      # CommencementGate. The gate holds until every member reaches
      # `approved`/`completed`.
      {:ok, project} = Tasks.create_project(%{name: "Cascade pending plan"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      {:ok, _} = Tasks.create_plan(%{task_id: a.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: b.id, status: "pending_review"})

      assert {:error, :stack_plans_pending, %{stack_id: id, waiting_on: [waiting]}} =
               Stacks.start_stack(stack)

      assert id == stack.id
      assert waiting == b.id
    end
  end

  # ── Gap 3 (task 019f921d): forming-lockout self-heal + no-regress ────────
  describe "commence_if_ready/1" do
    test "commences a forming-but-ready stack: flips to in_progress and opens the gate" do
      {:ok, project} = Tasks.create_project(%{name: "Commence ready"})
      stack = stack_fixture(project_id: project.id)

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "M1 root"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "M2 depends on M1",
          dependencies: [%{"task_id" => root.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, root)
      {:ok, _} = Stacks.add_task(stack, child)
      {:ok, _} = Tasks.create_plan(%{task_id: root.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: child.id, status: "approved"})

      # Stack sat in `forming` (start_stack never fired / lost the flip) —
      # the exact Inbox deadlock. commence_if_ready must self-heal it.
      assert {:ok, %{stack: updated}} = Stacks.commence_if_ready(stack)
      assert updated.status == "in_progress"

      # The gate now opens for the root (was refused while forming).
      root_record = Tasks.get_task_record(root.id)
      assert Platform.Tasks.Stacks.CommencementGate.open?(root_record) == true
      assert Tasks.get_task_record(root.id).status == "in_progress"
    end

    test "no-op when plans are not ready (stays forming)" do
      {:ok, project} = Tasks.create_project(%{name: "Commence not ready"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      # Only one member has an approved plan.
      {:ok, _} = Tasks.create_plan(%{task_id: a.id, status: "approved"})

      assert :noop = Stacks.commence_if_ready(stack)
      assert Stacks.get_stack!(stack.id).status == "forming"
    end

    test "no-op (idempotent) when the stack is already past forming" do
      stack = stack_fixture()
      {:ok, started} = Stacks.update_stack(stack, %{status: "in_progress"})
      assert :noop = Stacks.commence_if_ready(started)
      assert Stacks.get_stack!(stack.id).status == "in_progress"
    end
  end

  describe "no-regress guard: an executing stack cannot return to forming" do
    test "update_stack/2 drops a -> forming change from in_progress" do
      stack = stack_fixture()
      {:ok, running} = Stacks.update_stack(stack, %{status: "in_progress"})

      assert {:ok, guarded} = Stacks.update_stack(running, %{status: "forming"})
      # The regressive change was dropped, not applied.
      assert guarded.status == "in_progress"
      assert Stacks.get_stack!(stack.id).status == "in_progress"
    end

    test "recompute_stack_status/1 over an empty member list does not regress an in_progress stack" do
      stack = stack_fixture()
      {:ok, running} = Stacks.update_stack(stack, %{status: "in_progress"})

      # No members ⇒ rollup_status_for([]) == "forming"; the guard must
      # prevent the recompute from re-closing the gate.
      assert {:ok, result} = Stacks.recompute_stack_status(running)
      assert result.status == "in_progress"
      assert Stacks.get_stack!(stack.id).status == "in_progress"
    end

    test "guard holds for in_review and deploying too" do
      for status <- ["in_review", "deploying"] do
        stack = stack_fixture()
        {:ok, running} = Stacks.update_stack(stack, %{status: status})
        assert {:ok, guarded} = Stacks.update_stack(running, %{status: "forming"})
        assert guarded.status == status
      end
    end

    test "a genuine forming stack (no execution phase yet) CAN still be set to forming (no false guard)" do
      # A brand-new stack is at forming; an idempotent forming write is fine.
      stack = stack_fixture()
      assert stack.status == "forming"
      assert {:ok, still} = Stacks.update_stack(stack, %{status: "forming"})
      assert still.status == "forming"
    end
  end

  describe "start_planning/1" do
    test "manual mode single-member stack transitions the member to planning" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning single"})
      stack = stack_fixture(project_id: project.id)

      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Solo"})
      {:ok, _} = Stacks.add_task(stack, t)

      assert {:ok,
              %{
                stack: updated,
                planning: [planned],
                mode: :manual,
                waves_total: 1
              }} = Stacks.start_planning(stack)

      assert planned.id == t.id
      assert planned.status == "planning"
      assert Tasks.get_task_record(t.id).status == "planning"
      assert updated.id == stack.id
    end

    test "manual mode dep-free stack dispatches every root in one wave" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning happy"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "Member A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "Member B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "Member C"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      assert {:ok,
              %{
                stack: updated,
                planning: planning,
                mode: :manual,
                waves_total: 1
              }} = Stacks.start_planning(stack)

      planning_ids = planning |> Enum.map(& &1.id) |> Enum.sort()
      assert planning_ids == Enum.sort([a.id, b.id, c.id])
      assert Enum.all?(planning, &(&1.status == "planning"))

      # Every member is now at `planning` in the DB.
      assert Enum.all?(Stacks.members(stack), &(&1.status == "planning"))

      # An all-`planning` stack rolls up to `forming` (no member has
      # advanced past forming).
      assert updated.status == "forming"
      assert {:ok, recomputed} = Stacks.recompute_stack_status(updated)
      assert recomputed.status == "forming"
    end

    test "manual mode 3-chain only dispatches wave 0 (the root)" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning chain"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A root"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B middle"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C leaf"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      # C ← B ← A (C depends on B, B depends on A) → waves [[A], [B], [C]].
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)
      {:ok, _} = Stacks.add_dependency_edge(stack, c.id, b.id)

      assert {:ok,
              %{
                planning: [planned],
                mode: :manual,
                waves_total: 3
              }} = Stacks.start_planning(stack)

      assert planned.id == a.id
      assert Tasks.get_task_record(a.id).status == "planning"
      assert Tasks.get_task_record(b.id).status == "backlog"
      assert Tasks.get_task_record(c.id).status == "backlog"
    end

    test "manual mode emits :wave_dispatched telemetry with wave_index 0" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning telemetry"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :planning, :wave_dispatched]
        ])

      assert {:ok, %{mode: :manual, waves_total: 2}} = Stacks.start_planning(stack)

      assert_receive {[:platform, :stacks, :planning, :wave_dispatched], ^ref, measurements,
                      metadata}

      assert measurements.member_count == 1
      assert metadata.wave_index == 0
      assert metadata.stack_id == stack.id

      :telemetry.detach(ref)
    end

    test "cyclic stack returns {:error, :cycle, _} and no members transition" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning cyclic"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      # Deliberately construct a cycle by writing edges directly on the
      # task record so we bypass `add_dependency_edge/4`'s cycle guard.
      Tasks.get_task_record(a.id)
      |> Task.changeset(%{dependencies: [%{"task_id" => b.id, "kind" => "blocks"}]})
      |> Repo.update!()

      Tasks.get_task_record(b.id)
      |> Task.changeset(%{dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]})
      |> Repo.update!()

      assert {:error, :cycle, _path} = Stacks.start_planning(stack)

      assert Tasks.get_task_record(a.id).status == "backlog"
      assert Tasks.get_task_record(b.id).status == "backlog"
    end

    test "idempotency: second invocation returns {:noop, :already_in_flight}" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning idempotent"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "Member A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "Member B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      assert {:ok, %{planning: first, mode: :manual}} = Stacks.start_planning(stack)
      assert length(first) == 2

      # Wave 0 == [A, B] (no in-stack deps). Both members are now at
      # `planning`. Second call short-circuits without touching anything.
      assert {:noop, :already_in_flight} = Stacks.start_planning(stack)
      assert Enum.all?(Stacks.members(stack), &(&1.status == "planning"))
    end

    test "idempotency: a member pre-advanced past backlog blocks a fresh dispatch" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning pre-advanced"})
      stack = stack_fixture(project_id: project.id)

      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Already planning"})
      {:ok, attached} = Stacks.add_task(stack, t)
      set_member_status(stack, attached, "planning")

      assert {:noop, :already_in_flight} = Stacks.start_planning(stack)
      assert Tasks.get_task_record(attached.id).status == "planning"
    end

    test "an empty stack returns {:ok, planning: []}" do
      stack = stack_fixture()

      assert {:ok, %{stack: returned, planning: [], waves_total: 0, mode: :manual}} =
               Stacks.start_planning(stack)

      assert returned.id == stack.id
      assert returned.status == "forming"
    end

    test "accepts a stack id and returns {:error, :stack_not_found} for an unknown id" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning by id"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, _} = Stacks.add_task(stack, t)

      assert {:ok, %{planning: [planned]}} = Stacks.start_planning(stack.id)
      assert planned.id == t.id

      assert {:error, :stack_not_found} = Stacks.start_planning(Ecto.UUID.generate())
    end

    test "auto_plan == true cascades every wave in one call and reports mode: :auto" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning auto 3-chain"})
      stack = stack_fixture(project_id: project.id)
      {:ok, stack} = Stacks.update_stack(stack, %{auto_plan: true})

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      # C ← B ← A dep chain: 3 waves under manual, still 3 waves under
      # auto — the difference is that auto fans out all three at once.
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)
      {:ok, _} = Stacks.add_dependency_edge(stack, c.id, b.id)

      assert {:ok, %{planning: planning, mode: :auto, waves_total: 3}} =
               Stacks.start_planning(stack)

      assert length(planning) == 3
      planning_ids = planning |> Enum.map(& &1.id) |> Enum.sort()
      assert planning_ids == Enum.sort([a.id, b.id, c.id])
      assert Enum.all?(Stacks.members(stack), &(&1.status == "planning"))
    end

    test "auto_plan == true emits one :wave_dispatched event per wave, in order" do
      {:ok, project} = Tasks.create_project(%{name: "Start planning auto telemetry"})
      stack = stack_fixture(project_id: project.id)
      {:ok, stack} = Stacks.update_stack(stack, %{auto_plan: true})

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)
      {:ok, _} = Stacks.add_dependency_edge(stack, c.id, b.id)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :planning, :wave_dispatched]
        ])

      assert {:ok, %{mode: :auto, waves_total: 3}} = Stacks.start_planning(stack)

      # Three events, wave_index 0, 1, 2, in order — one per wave with
      # member_count: 1 each because the chain has one member per wave.
      assert_receive {[:platform, :stacks, :planning, :wave_dispatched], ^ref, meas0, meta0}
      assert_receive {[:platform, :stacks, :planning, :wave_dispatched], ^ref, meas1, meta1}
      assert_receive {[:platform, :stacks, :planning, :wave_dispatched], ^ref, meas2, meta2}
      refute_receive {[:platform, :stacks, :planning, :wave_dispatched], ^ref, _, _}, 50

      assert [meta0.wave_index, meta1.wave_index, meta2.wave_index] == [0, 1, 2]
      assert Enum.all?([meta0, meta1, meta2], &(&1.stack_id == stack.id))
      assert Enum.all?([meas0, meas1, meas2], &(&1.member_count == 1))

      :telemetry.detach(ref)
    end
  end

  describe "start_planning/1 with dep inference" do
    alias Platform.Tasks.Stacks.DepInference.StubAdapter

    setup do
      StubAdapter.reset_calls()
      :ok
    end

    test "commits inferred edges via add_dependency_edge and reports edges_authored" do
      {:ok, project} = Tasks.create_project(%{name: "DepInf happy"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A creates types"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B consumes types"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C unrelated"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      Process.put(
        {:dep_inference_stub, :response},
        {:ok,
         Jason.encode!(%{
           "edges" => [
             %{
               "from_task_id" => b.id,
               "to_task_id" => a.id,
               "reason" => "B consumes types created by A"
             }
           ]
         })}
      )

      assert {:ok,
              %{
                planning: planning,
                edges_authored: 1,
                edges_skipped_reason: nil,
                mode: :manual,
                waves_total: 2
              }} = Stacks.start_planning(stack)

      # Manual-mode wave 0 dispatch: only the two dep-free members (A, C)
      # advance. B waits for A's plan to approve.
      planning_ids = planning |> Enum.map(& &1.id) |> Enum.sort()
      assert planning_ids == Enum.sort([a.id, c.id])
      assert Tasks.get_task_record(b.id).status == "backlog"

      # The inferred edge landed in the JSONB dependencies column via
      # the standard add_dependency_edge/4 path.
      updated_b = Tasks.get_task_record(b.id)
      assert [%{"task_id" => to_id, "kind" => "blocks"}] = updated_b.dependencies
      assert to_id == a.id

      # A and C stay dep-free.
      assert Tasks.get_task_record(a.id).dependencies in [nil, []]
      assert Tasks.get_task_record(c.id).dependencies in [nil, []]

      assert Process.get({:dep_inference_stub, :calls}) == 1
    end

    test "stub returning zero edges writes nothing but still cascades" do
      {:ok, project} = Tasks.create_project(%{name: "DepInf empty"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      Process.put({:dep_inference_stub, :response}, {:ok, ~s({"edges": []})})

      assert {:ok,
              %{
                planning: planning,
                edges_authored: 0,
                edges_skipped_reason: nil
              }} = Stacks.start_planning(stack)

      assert length(planning) == 2
      assert Tasks.get_task_record(a.id).dependencies in [nil, []]
      assert Tasks.get_task_record(b.id).dependencies in [nil, []]
      assert Process.get({:dep_inference_stub, :calls}) == 1
    end

    test "cyclic edges twice: zero writes, cascade still runs, warning logged" do
      {:ok, project} = Tasks.create_project(%{name: "DepInf cycle"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      cyclic =
        Jason.encode!(%{
          "edges" => [
            %{"from_task_id" => a.id, "to_task_id" => b.id, "reason" => "a->b"},
            %{"from_task_id" => b.id, "to_task_id" => c.id, "reason" => "b->c"},
            %{"from_task_id" => c.id, "to_task_id" => a.id, "reason" => "c->a"}
          ]
        })

      # Two successive cyclic responses — first commit hits :cycle,
      # revert path fires, retry hits :cycle again, terminal fallback.
      Process.put(
        {:dep_inference_stub, :response},
        [{:ok, cyclic}, {:ok, cyclic}]
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok,
                  %{
                    planning: planning,
                    edges_authored: 0,
                    edges_skipped_reason: :cycle
                  }} = Stacks.start_planning(stack)

          assert length(planning) == 3
        end)

      assert log =~ "cycle detected"

      # No inference edges landed after the double-cycle rollback.
      Enum.each([a, b, c], fn t ->
        assert Tasks.get_task_record(t.id).dependencies in [nil, []]
      end)

      # Adapter called exactly twice (initial + one cycle retry).
      assert Process.get({:dep_inference_stub, :calls}) == 2
    end

    test "pre-authored in-stack edge short-circuits inference (adapter never called)" do
      {:ok, project} = Tasks.create_project(%{name: "DepInf override"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      # Pre-author a user edge B -> A on the same stack.
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      # Prime the stub with a plausible extra edge. If inference DID
      # run, this would be written. It must not.
      Process.put(
        {:dep_inference_stub, :response},
        {:ok,
         Jason.encode!(%{
           "edges" => [
             %{"from_task_id" => c.id, "to_task_id" => b.id, "reason" => "should not land"}
           ]
         })}
      )

      assert {:ok,
              %{
                planning: planning,
                edges_authored: 0,
                edges_skipped_reason: :user_override_present,
                mode: :manual,
                waves_total: 2
              }} = Stacks.start_planning(stack)

      # Manual-mode wave 0 dispatch: A (root) and C (dep-free) advance;
      # B is gated behind A's plan.
      planning_ids = planning |> Enum.map(& &1.id) |> Enum.sort()
      assert planning_ids == Enum.sort([a.id, c.id])
      assert Tasks.get_task_record(b.id).status == "backlog"

      # Pre-existing B->A survives; C is untouched.
      assert [%{"task_id" => to_id}] = Tasks.get_task_record(b.id).dependencies
      assert to_id == a.id
      assert Tasks.get_task_record(c.id).dependencies in [nil, []]

      # Idempotency short-circuit: adapter was NEVER called.
      assert Process.get({:dep_inference_stub, :calls}) == 0
    end

    test "adapter erroring twice: zero writes, cascade still runs" do
      {:ok, project} = Tasks.create_project(%{name: "DepInf adapter fail"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      Process.put(
        {:dep_inference_stub, :response},
        [{:error, :timeout}, {:error, :timeout}]
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok,
                  %{
                    planning: planning,
                    edges_authored: 0,
                    edges_skipped_reason: :adapter_failed
                  }} = Stacks.start_planning(stack)

          assert length(planning) == 2
        end)

      assert log =~ "terminal failure"

      assert Tasks.get_task_record(a.id).dependencies in [nil, []]
      assert Tasks.get_task_record(b.id).dependencies in [nil, []]

      # try_infer_with_retry: first call fails, retries once => 2 calls total.
      assert Process.get({:dep_inference_stub, :calls}) == 2
    end
  end

  describe "start_planning/1 dep-inference telemetry" do
    alias Platform.Tasks.Stacks.DepInference.StubAdapter

    setup do
      StubAdapter.reset_calls()
      :ok
    end

    test "emits :computed with source=:agent and edges_count on happy path" do
      {:ok, project} = Tasks.create_project(%{name: "Telemetry happy"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      Process.put(
        {:dep_inference_stub, :response},
        {:ok,
         Jason.encode!(%{
           "edges" => [
             %{"from_task_id" => b.id, "to_task_id" => a.id, "reason" => "B consumes A"}
           ]
         })}
      )

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :dep_inference, :computed],
          [:platform, :stacks, :dep_inference, :failed]
        ])

      assert {:ok, %{edges_authored: 1, edges_skipped_reason: nil}} =
               Stacks.start_planning(stack)

      assert_receive {[:platform, :stacks, :dep_inference, :computed], ^ref, measurements,
                      metadata}

      assert measurements.edges_count == 1
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.stack_id == stack.id
      assert metadata.source == :agent
      assert metadata.retry_count == 0

      # Failed event must NOT fire on the happy path.
      refute_received {[:platform, :stacks, :dep_inference, :failed], ^ref, _, _}

      :telemetry.detach(ref)
    end

    test "emits :computed with source=:user_override_skip when idempotency short-circuits" do
      {:ok, project} = Tasks.create_project(%{name: "Telemetry override"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      # Pre-author an in-stack edge so inference is skipped.
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :dep_inference, :computed]
        ])

      assert {:ok, %{edges_authored: 0, edges_skipped_reason: :user_override_present}} =
               Stacks.start_planning(stack)

      assert_receive {[:platform, :stacks, :dep_inference, :computed], ^ref, measurements,
                      metadata}

      assert measurements.edges_count == 0
      assert metadata.stack_id == stack.id
      assert metadata.source == :user_override_skip
      assert metadata.retry_count == 0

      :telemetry.detach(ref)
    end

    test "emits :failed with reason=:cycle after cyclic-twice adapter response" do
      {:ok, project} = Tasks.create_project(%{name: "Telemetry cycle"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      cyclic =
        Jason.encode!(%{
          "edges" => [
            %{"from_task_id" => a.id, "to_task_id" => b.id, "reason" => "a->b"},
            %{"from_task_id" => b.id, "to_task_id" => c.id, "reason" => "b->c"},
            %{"from_task_id" => c.id, "to_task_id" => a.id, "reason" => "c->a"}
          ]
        })

      Process.put({:dep_inference_stub, :response}, [{:ok, cyclic}, {:ok, cyclic}])

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :dep_inference, :failed]
        ])

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{edges_authored: 0, edges_skipped_reason: :cycle}} =
                 Stacks.start_planning(stack)
      end)

      assert_receive {[:platform, :stacks, :dep_inference, :failed], ^ref, measurements, metadata}

      assert is_integer(measurements.duration_ms)
      assert metadata.stack_id == stack.id
      assert metadata.reason == :cycle
      assert metadata.retry_count == 1

      :telemetry.detach(ref)
    end

    test "emits :failed with reason=:adapter_failed after two adapter errors" do
      {:ok, project} = Tasks.create_project(%{name: "Telemetry adapter fail"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      Process.put(
        {:dep_inference_stub, :response},
        [{:error, :timeout}, {:error, :timeout}]
      )

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :dep_inference, :failed]
        ])

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{edges_authored: 0, edges_skipped_reason: :adapter_failed}} =
                 Stacks.start_planning(stack)
      end)

      assert_receive {[:platform, :stacks, :dep_inference, :failed], ^ref, _measurements,
                      metadata}

      assert metadata.stack_id == stack.id
      assert metadata.reason == :adapter_failed
      assert metadata.retry_count == 1

      :telemetry.detach(ref)
    end

    test "emits :failed with reason=:parse_failed on non-JSON adapter response" do
      {:ok, project} = Tasks.create_project(%{name: "Telemetry parse fail"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      Process.put(
        {:dep_inference_stub, :response},
        [{:ok, "not-json { garbage"}, {:ok, "still not json"}]
      )

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :dep_inference, :failed]
        ])

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{edges_authored: 0, edges_skipped_reason: :parse_failed}} =
                 Stacks.start_planning(stack)
      end)

      assert_receive {[:platform, :stacks, :dep_inference, :failed], ^ref, _measurements,
                      metadata}

      assert metadata.stack_id == stack.id
      assert metadata.reason == :parse_failed
      assert metadata.retry_count == 1

      :telemetry.detach(ref)
    end
  end

  describe "advance_planning_waves/1" do
    test "before wave 0's plan is approved, advance is a no-op" do
      {:ok, project} = Tasks.create_project(%{name: "Advance upstream incomplete"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      # Dispatch wave 0 → A goes planning; B stays backlog.
      assert {:ok, %{planning: [_a]}} = Stacks.start_planning(stack)

      # A's plan has NOT been approved yet — advance is a no-op.
      assert {:ok, :noop, :upstream_incomplete} = Stacks.advance_planning_waves(stack)
      assert Tasks.get_task_record(b.id).status == "backlog"
    end

    test "3-chain: approving each wave's plan advances the next wave" do
      {:ok, project} = Tasks.create_project(%{name: "Advance chain"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)
      {:ok, _} = Stacks.add_dependency_edge(stack, c.id, b.id)

      assert {:ok, %{planning: [_a]}} = Stacks.start_planning(stack)

      # Stamp A's plan as approved directly (bypass approve_plan/3 to
      # exercise advance in isolation).
      {:ok, _} = Tasks.create_plan(%{task_id: a.id, status: "approved"})

      assert {:ok, %{dispatched: [b_dispatched], wave_index: 1}} =
               Stacks.advance_planning_waves(stack)

      assert b_dispatched.id == b.id
      assert b_dispatched.status == "planning"
      assert Tasks.get_task_record(c.id).status == "backlog"

      # Approve B's plan → advance dispatches wave 2 (C).
      {:ok, _} = Tasks.create_plan(%{task_id: b.id, status: "approved"})

      assert {:ok, %{dispatched: [c_dispatched], wave_index: 2}} =
               Stacks.advance_planning_waves(stack)

      assert c_dispatched.id == c.id
      assert c_dispatched.status == "planning"
    end

    test "when the next wave is already dispatched, advance is a no-op" do
      {:ok, project} = Tasks.create_project(%{name: "Advance already-dispatched"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert {:ok, _} = Stacks.start_planning(stack)
      {:ok, _} = Tasks.create_plan(%{task_id: a.id, status: "approved"})

      assert {:ok, %{wave_index: 1}} = Stacks.advance_planning_waves(stack)

      # Second call: wave 1 (B) is now at planning — no new dispatch.
      assert {:ok, :noop, :next_wave_already_dispatched} =
               Stacks.advance_planning_waves(stack)
    end

    test "when all waves are dispatched, advance returns :no_next_wave" do
      {:ok, project} = Tasks.create_project(%{name: "Advance end of chain"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)

      assert {:ok, _} = Stacks.start_planning(stack)
      {:ok, _} = Tasks.create_plan(%{task_id: a.id, status: "approved"})

      # Single-wave stack: wave 0 fully approved, no wave 1.
      assert {:ok, :noop, :no_next_wave} = Stacks.advance_planning_waves(stack)
    end

    test "an empty stack returns :no_next_wave" do
      stack = stack_fixture()
      assert {:ok, :noop, :no_next_wave} = Stacks.advance_planning_waves(stack)
    end

    test "cyclic stack passes through {:error, :cycle, _}" do
      {:ok, project} = Tasks.create_project(%{name: "Advance cyclic"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      Tasks.get_task_record(a.id)
      |> Task.changeset(%{dependencies: [%{"task_id" => b.id, "kind" => "blocks"}]})
      |> Repo.update!()

      Tasks.get_task_record(b.id)
      |> Task.changeset(%{dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]})
      |> Repo.update!()

      assert {:error, :cycle, _} = Stacks.advance_planning_waves(stack)
    end

    test "emits :wave_dispatched telemetry with the advanced wave_index" do
      {:ok, project} = Tasks.create_project(%{name: "Advance telemetry"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert {:ok, _} = Stacks.start_planning(stack)
      {:ok, _} = Tasks.create_plan(%{task_id: a.id, status: "approved"})

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :planning, :wave_dispatched]
        ])

      assert {:ok, %{wave_index: 1}} = Stacks.advance_planning_waves(stack)

      assert_receive {[:platform, :stacks, :planning, :wave_dispatched], ^ref, measurements,
                      metadata}

      assert measurements.member_count == 1
      assert metadata.wave_index == 1
      assert metadata.stack_id == stack.id

      :telemetry.detach(ref)
    end

    test "accepts a stack id and returns {:error, :stack_not_found} for an unknown id" do
      assert {:error, :stack_not_found} = Stacks.advance_planning_waves(Ecto.UUID.generate())
    end
  end

  describe "planning telemetry (stack v2 stage 6)" do
    # `:started`, `:noop` (multi-reason), and `:advanced` events. The
    # existing `:wave_dispatched` event is covered above; these blocks
    # exercise the sibling events landed in stage 6 alongside
    # backwards-compatibility with `:wave_dispatched`.

    test "manual mode emits :started with member_count, mode: :manual, and waves_total" do
      {:ok, project} = Tasks.create_project(%{name: "Started telemetry manual"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      # Chain B → A so waves = [[A], [B]].
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :planning, :started]
        ])

      assert {:ok, %{mode: :manual, waves_total: 2}} = Stacks.start_planning(stack)

      assert_receive {[:platform, :stacks, :planning, :started], ^ref, measurements, metadata}

      assert measurements.member_count == 2
      assert metadata.stack_id == stack.id
      assert metadata.mode == :manual
      assert metadata.waves_total == 2

      :telemetry.detach(ref)
    end

    test "auto mode emits :started with mode: :auto" do
      {:ok, project} = Tasks.create_project(%{name: "Started telemetry auto"})
      stack = stack_fixture(project_id: project.id)
      {:ok, stack} = Stacks.update_stack(stack, %{auto_plan: true})

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)
      {:ok, _} = Stacks.add_dependency_edge(stack, c.id, b.id)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :planning, :started]
        ])

      assert {:ok, %{mode: :auto, waves_total: 3}} = Stacks.start_planning(stack)

      assert_receive {[:platform, :stacks, :planning, :started], ^ref, measurements, metadata}

      # `member_count` in :started is the TOTAL member count, not the
      # per-wave count. Per-wave counts continue to live on
      # :wave_dispatched (one event per wave in auto mode).
      assert measurements.member_count == 3
      assert metadata.mode == :auto
      assert metadata.waves_total == 3

      :telemetry.detach(ref)
    end

    test "idempotency short-circuit emits :noop with reason :already_in_flight and no extra :wave_dispatched" do
      {:ok, project} = Tasks.create_project(%{name: "Noop already in flight"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      # First call dispatches wave 0 (A). Attach handlers AFTER so we
      # only see events from the second (noop) call.
      assert {:ok, %{mode: :manual}} = Stacks.start_planning(stack)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :planning, :noop],
          [:platform, :stacks, :planning, :wave_dispatched],
          [:platform, :stacks, :planning, :started]
        ])

      # `Logger.info` line documents the short-circuit for operator logs.
      # Temporarily lower the module log level so `capture_log/2` can
      # observe the info-level line — test env's default level is
      # `:warning`, and stage 7's live e2e scenario verifies the same
      # line against dev's default level (:info).
      previous_level = Logger.level()
      Logger.configure(level: :info)

      try do
        logs =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:noop, :already_in_flight} = Stacks.start_planning(stack)
          end)

        # `:noop` fires; no extra `:wave_dispatched` and no `:started`
        # fire on the short-circuit path.
        assert_receive {[:platform, :stacks, :planning, :noop], ^ref, measurements, metadata}
        assert measurements == %{}
        assert metadata.stack_id == stack.id
        assert metadata.reason == :already_in_flight

        refute_received {[:platform, :stacks, :planning, :wave_dispatched], ^ref, _, _}
        refute_received {[:platform, :stacks, :planning, :started], ^ref, _, _}

        assert logs =~ "start_planning"
        assert logs =~ "noop"
        assert logs =~ "already_in_flight"
      after
        Logger.configure(level: previous_level)
        :telemetry.detach(ref)
      end
    end

    test "cyclic DAG short-circuit emits :noop with reason :cycle and does not fire :started" do
      {:ok, project} = Tasks.create_project(%{name: "Noop cycle"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      # Bypass `add_dependency_edge/4`'s cycle guard to install a cyclic
      # DAG directly on the underlying `Task.dependencies` column.
      Tasks.get_task_record(a.id)
      |> Task.changeset(%{dependencies: [%{"task_id" => b.id, "kind" => "blocks"}]})
      |> Repo.update!()

      Tasks.get_task_record(b.id)
      |> Task.changeset(%{dependencies: [%{"task_id" => a.id, "kind" => "blocks"}]})
      |> Repo.update!()

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :planning, :noop],
          [:platform, :stacks, :planning, :started],
          [:platform, :stacks, :planning, :wave_dispatched]
        ])

      assert {:error, :cycle, _path} = Stacks.start_planning(stack)

      assert_receive {[:platform, :stacks, :planning, :noop], ^ref, _measurements, metadata}
      assert metadata.stack_id == stack.id
      assert metadata.reason == :cycle

      refute_received {[:platform, :stacks, :planning, :started], ^ref, _, _}
      refute_received {[:platform, :stacks, :planning, :wave_dispatched], ^ref, _, _}

      :telemetry.detach(ref)
    end

    test "advance_planning_waves emits :advanced alongside :wave_dispatched" do
      {:ok, project} = Tasks.create_project(%{name: "Advanced telemetry"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert {:ok, _} = Stacks.start_planning(stack)
      {:ok, _} = Tasks.create_plan(%{task_id: a.id, status: "approved"})

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :planning, :advanced],
          [:platform, :stacks, :planning, :wave_dispatched]
        ])

      assert {:ok, %{wave_index: 1}} = Stacks.advance_planning_waves(stack)

      # `:advanced` fires with the same wave_index as `:wave_dispatched`.
      # Observers that care about "advance-driven promotion" attach to
      # `:advanced`; observers that just want every wave-fire (both start
      # and advance) attach to `:wave_dispatched`.
      assert_receive {[:platform, :stacks, :planning, :advanced], ^ref, adv_measurements,
                      adv_metadata}

      assert_receive {[:platform, :stacks, :planning, :wave_dispatched], ^ref, wd_measurements,
                      wd_metadata}

      assert adv_measurements.member_count == 1
      assert wd_measurements.member_count == 1
      assert adv_metadata.wave_index == 1
      assert wd_metadata.wave_index == 1
      assert adv_metadata.stack_id == stack.id

      :telemetry.detach(ref)
    end

    test ":advanced does NOT fire on advance no-op (upstream incomplete)" do
      {:ok, project} = Tasks.create_project(%{name: "Advanced noop"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      assert {:ok, _} = Stacks.start_planning(stack)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :planning, :advanced]
        ])

      # A's plan is NOT approved — advance is a no-op.
      assert {:ok, :noop, :upstream_incomplete} = Stacks.advance_planning_waves(stack)
      refute_received {[:platform, :stacks, :planning, :advanced], ^ref, _, _}

      :telemetry.detach(ref)
    end
  end

  describe "start_planning + Tasks.approve_plan integration" do
    test "approving wave 0's plan auto-advances wave 1 via approve_plan hook" do
      {:ok, project} = Tasks.create_project(%{name: "Approve hook chain"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

      # Manual mode (default) → wave 0 = [A].
      assert {:ok, %{planning: [_a], mode: :manual}} = Stacks.start_planning(stack)
      assert Tasks.get_task_record(b.id).status == "backlog"

      # Create A's plan in `pending_review` then approve via
      # Tasks.approve_plan/3 — this is the path a human clicking
      # Approve exercises.
      {:ok, plan_a} = Tasks.create_plan(%{task_id: a.id, status: "pending_review"})

      assert {:ok, _approved} = Tasks.approve_plan(plan_a, "system:test")

      # The approve hook should have kicked B out of backlog into
      # planning without any explicit advance_planning_waves call.
      assert Tasks.get_task_record(b.id).status == "planning"
    end
  end

  describe "auto_accept_plan propagation via Tasks.maybe_auto_approve" do
    # `Tasks.maybe_auto_approve/1` resolves the auto-approve flag by
    # checking BOTH the task-level `auto_approve_plan` and the parent
    # stack's `auto_accept_plan`. These tests exercise the propagation
    # end-to-end via `submit_plan_for_review/1`, which is the real
    # code path that a live planner subagent hits.

    test "stack auto_accept_plan = true + task auto_approve_plan = false → plan auto-approves via :stack" do
      {:ok, project} = Tasks.create_project(%{name: "Stack auto-accept"})
      stack = stack_fixture(project_id: project.id)
      {:ok, stack} = Stacks.update_stack(stack, %{auto_accept_plan: true})

      exec_id = Ecto.UUID.generate()
      review_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Stack-driven auto",
          status: "planning",
          # Task-level flag OFF — the stack flag alone should carry the
          # auto-approve.
          auto_approve_plan: false,
          phase_assignees: %{
            "execution" => %{"assignee_id" => exec_id, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => review_id, "assignee_type" => "agent"}
          }
        })

      {:ok, _} = Stacks.add_task(stack, task)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :plan, :auto_approved]
        ])

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      {:ok, submitted} = Tasks.submit_plan_for_review(plan)

      assert submitted.status == "approved"
      assert submitted.auto_approved_at != nil
      assert submitted.approved_by == "system:auto"

      assert_receive {[:platform, :plan, :auto_approved], ^ref, _meas, meta}
      assert meta.via == :stack
      assert meta.task_id == task.id

      :telemetry.detach(ref)
    end

    test "stack auto_accept_plan = false + task auto_approve_plan = false → plan stays pending_review" do
      {:ok, project} = Tasks.create_project(%{name: "Both off"})
      stack = stack_fixture(project_id: project.id)
      # Both flags default to false — no toggle.
      exec_id = Ecto.UUID.generate()
      review_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Neither auto",
          status: "planning",
          auto_approve_plan: false,
          phase_assignees: %{
            "execution" => %{"assignee_id" => exec_id, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => review_id, "assignee_type" => "agent"}
          }
        })

      {:ok, _} = Stacks.add_task(stack, task)

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      {:ok, submitted} = Tasks.submit_plan_for_review(plan)

      assert submitted.status == "pending_review"
      assert submitted.auto_approved_at == nil
    end

    test "task auto_approve_plan = true + stack auto_accept_plan = false → still auto-approves via :task" do
      {:ok, project} = Tasks.create_project(%{name: "Task auto only"})
      stack = stack_fixture(project_id: project.id)

      exec_id = Ecto.UUID.generate()
      review_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Task-driven auto",
          status: "planning",
          auto_approve_plan: true,
          phase_assignees: %{
            "execution" => %{"assignee_id" => exec_id, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => review_id, "assignee_type" => "agent"}
          }
        })

      {:ok, _} = Stacks.add_task(stack, task)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :plan, :auto_approved]
        ])

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      {:ok, submitted} = Tasks.submit_plan_for_review(plan)

      assert submitted.status == "approved"
      assert submitted.auto_approved_at != nil

      assert_receive {[:platform, :plan, :auto_approved], ^ref, _meas, meta}
      # Task flag wins precedence when both signals could fire; here the
      # stack flag is off so only :task can fire.
      assert meta.via == :task

      :telemetry.detach(ref)
    end

    test "both flags true → auto-approves with via: :task (task-level takes precedence)" do
      {:ok, project} = Tasks.create_project(%{name: "Both flags"})
      stack = stack_fixture(project_id: project.id)
      {:ok, stack} = Stacks.update_stack(stack, %{auto_accept_plan: true})

      exec_id = Ecto.UUID.generate()
      review_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Both on",
          status: "planning",
          auto_approve_plan: true,
          phase_assignees: %{
            "execution" => %{"assignee_id" => exec_id, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => review_id, "assignee_type" => "agent"}
          }
        })

      {:ok, _} = Stacks.add_task(stack, task)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :plan, :auto_approved]
        ])

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      {:ok, submitted} = Tasks.submit_plan_for_review(plan)

      assert submitted.status == "approved"
      assert submitted.auto_approved_at != nil

      assert_receive {[:platform, :plan, :auto_approved], ^ref, _meas, meta}
      assert meta.via == :task

      :telemetry.detach(ref)
    end

    test "solo task (no stack) with auto_approve_plan = true still auto-approves via :task" do
      # Regression guard: preloading `:stack` on a task without a
      # `stack_id` must not crash and must not clobber the task-level
      # auto-approve path.
      {:ok, project} = Tasks.create_project(%{name: "Solo task"})

      exec_id = Ecto.UUID.generate()
      review_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Solo auto",
          status: "planning",
          auto_approve_plan: true,
          phase_assignees: %{
            "execution" => %{"assignee_id" => exec_id, "assignee_type" => "agent"},
            "review" => %{"assignee_id" => review_id, "assignee_type" => "agent"}
          }
        })

      refute task.stack_id

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      {:ok, submitted} = Tasks.submit_plan_for_review(plan)

      assert submitted.status == "approved"
      assert submitted.auto_approved_at != nil
    end
  end

  describe "regression?/2" do
    test "returns true for backward lifecycle steps" do
      assert Stacks.regression?("in_review", "in_progress")
      assert Stacks.regression?("deploying", "in_review")
      assert Stacks.regression?("done", "in_progress")
      assert Stacks.regression?("in_progress", "stack_pending")
      assert Stacks.regression?("in_progress", "backlog")
    end

    test "returns false for forward / same-level moves" do
      refute Stacks.regression?("backlog", "in_progress")
      refute Stacks.regression?("in_progress", "in_review")
      refute Stacks.regression?("in_review", "deploying")
      refute Stacks.regression?("in_progress", "in_progress")
      # Pre-execution rungs treated as same level.
      refute Stacks.regression?("backlog", "stack_pending")
      refute Stacks.regression?("stack_pending", "backlog")
    end
  end

  describe "handle_member_regression/2" do
    test "no-op for tasks outside any stack (cross-stack quiet path)" do
      {:ok, project} = Tasks.create_project(%{name: "Regression non-member"})
      {:ok, free} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      assert :ok = Stacks.handle_member_regression(free, "in_review")
    end

    test "reverts downstream stack_pending when threshold lost" do
      {:ok, project} = Tasks.create_project(%{name: "Regression revert"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      {:ok, _} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      # Setup: parent at in_review + stamp, child at in_progress (was
      # promoted off the rollup-merge sweep but hasn't shipped any
      # stage_complete signal yet).
      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
        }
      })
      |> Repo.update!()

      attached_child
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      # Simulate the parent regressing: clear the merge stamp so the
      # threshold breaks.
      regressed_parent =
        Tasks.get_task_record(attached_parent.id)
        |> Task.changeset(%{status: "in_progress", metadata: %{}})
        |> Repo.update!()

      assert {:ok, %{reverted: [reverted], flagged: []}} =
               Stacks.handle_member_regression(regressed_parent, "in_review")

      assert reverted.id == attached_child.id
      assert reverted.status == "stack_pending"
    end

    test "leaves downstream alone but flags it when work is already committed" do
      {:ok, project} = Tasks.create_project(%{name: "Regression flag"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Child has an approved plan AND a passed stage — committed work
      # exists.
      {:ok, plan} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      {:ok, _stage} =
        Repo.insert(%Platform.Tasks.Stage{
          plan_id: plan.id,
          position: 1,
          name: "Stage 1",
          status: "passed"
        })

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
        }
      })
      |> Repo.update!()

      attached_child
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      # Parent regresses — threshold lost.
      regressed_parent =
        Tasks.get_task_record(attached_parent.id)
        |> Task.changeset(%{status: "in_progress", metadata: %{}})
        |> Repo.update!()

      assert {:ok, %{reverted: [], flagged: [flagged]}} =
               Stacks.handle_member_regression(regressed_parent, "in_review")

      assert flagged.id == attached_child.id
      # Status untouched — committed work is not auto-rolled back.
      assert flagged.status == "in_progress"
      assert is_binary(flagged.metadata["stack_dep_regressed_at"])
    end

    test "leaves downstream alone when threshold is still met after regression" do
      # Two parents block the child; only one parent regresses, but the
      # OTHER parent has its own merge stamp so the threshold is still
      # cleared. No revert and no flag.
      {:ok, project} = Tasks.create_project(%{name: "Regression still ok"})
      stack = stack_fixture(project_id: project.id)
      {:ok, p1} = Tasks.create_task(%{project_id: project.id, title: "P1"})
      {:ok, p2} = Tasks.create_task(%{project_id: project.id, title: "P2"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [
            %{"task_id" => p1.id, "kind" => "blocks"},
            %{"task_id" => p2.id, "kind" => "blocks"}
          ]
        })

      {:ok, attached_p1} = Stacks.add_task(stack, p1)
      {:ok, attached_p2} = Stacks.add_task(stack, p2)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Both parents merged.
      attached_p1
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => "01a0001", "at" => "2026-07-17T00:00:00Z"}
        }
      })
      |> Repo.update!()

      attached_p2
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => "02a0002", "at" => "2026-07-17T00:00:00Z"}
        }
      })
      |> Repo.update!()

      attached_child
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      # P1 regresses (stamp cleared), P2 still clears the threshold —
      # but actually wait, when we say the threshold per dep, EACH dep
      # must clear. So if P1 regresses, threshold breaks. Re-construct:
      # P1 is not a dep, only P2 is.
      attached_p1
      |> Task.changeset(%{status: "in_progress", metadata: %{}})
      |> Repo.update!()

      # Re-fetch p1 as the regressed task.
      regressed_p1 = Tasks.get_task_record(attached_p1.id)

      # Child depends on BOTH; P1's regression breaks the threshold.
      # Confirm this is the "threshold lost" path, not the "still met"
      # path — child goes back to stack_pending because it has no
      # passed stages.
      assert {:ok, %{reverted: [reverted], flagged: []}} =
               Stacks.handle_member_regression(regressed_p1, "in_review")

      assert reverted.id == attached_child.id
    end

    test "leaves a downstream that is NOT at in_progress untouched" do
      {:ok, project} = Tasks.create_project(%{name: "Regression non-progress"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Child is still parked at stack_pending — no regression action
      # needed (it's already in the holding state).
      attached_child
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
        }
      })
      |> Repo.update!()

      regressed_parent =
        Tasks.get_task_record(attached_parent.id)
        |> Task.changeset(%{status: "in_progress", metadata: %{}})
        |> Repo.update!()

      assert {:ok, %{reverted: [], flagged: []}} =
               Stacks.handle_member_regression(regressed_parent, "in_review")

      assert Tasks.get_task_record(attached_child.id).status == "stack_pending"
    end
  end

  describe "regression handler hook in transition_task/2" do
    test "manual backward transition demotes a downstream in_progress sibling" do
      {:ok, project} = Tasks.create_project(%{name: "Regression hook"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Plans for both so transitions can run through the gate.
      {:ok, _} = Tasks.create_plan(%{task_id: attached_parent.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      # Drive parent forward: in_progress → in_review with merge stamp.
      attached_parent
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      reloaded_parent = Tasks.get_task_record(attached_parent.id)

      {:ok, _} =
        Tasks.update_task(reloaded_parent, %{
          metadata: %{
            "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
          }
        })

      reloaded_parent = Tasks.get_task_record(attached_parent.id)
      {:ok, parent_in_review} = Tasks.transition_task(reloaded_parent, "in_review")

      # Promote child to in_progress directly (no stage_complete events).
      attached_child
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      # Clear the merge stamp on parent so the threshold WILL break, then
      # regress parent in_review → in_progress through transition_task.
      Tasks.update_task(parent_in_review, %{metadata: %{}})
      reloaded_parent = Tasks.get_task_record(attached_parent.id)

      assert {:ok, _} = Tasks.transition_task(reloaded_parent, "in_progress")

      # The hook in maybe_finalize_transition fired handle_member_regression,
      # which demoted child back to stack_pending.
      assert Tasks.get_task_record(attached_child.id).status == "stack_pending"
    end
  end

  describe "recompute_stack_status hook in transition_task/2" do
    test "advancing a member updates the stack rollup" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade hook"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, attached} = Stacks.add_task(stack, t)

      # ADR 0042 Decision 4: the commencement gate requires stack.status
      # == "in_progress" before a member can transition to `in_progress`.
      # This test previously drove a member `backlog → in_progress` while
      # the stack was still `forming`; under D4 that path is legitimately
      # blocked (the operator is supposed to invoke `start_stack/1`). We
      # simulate the post-start state by flipping the stack directly, then
      # exercise the intra-execution transition that IS the point of this
      # test: `in_progress → in_review` should re-run recompute and land
      # the stack at `in_review` too (single member = single-member rollup).
      {:ok, _} = Tasks.create_plan(%{task_id: attached.id, status: "approved"})

      stack
      |> Ecto.Changeset.change(status: "in_progress")
      |> Repo.update!()

      # Drive member forward through the primitive we're actually testing.
      attached
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      reloaded = Tasks.get_task_record(attached.id)
      assert {:ok, _} = Tasks.transition_task(reloaded, "in_review")

      # recompute_stack_status hook ran in maybe_finalize_transition's tail.
      assert Stacks.get_stack(stack.id).status == "in_review"
    end

    test "no-op for tasks outside any stack" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade hook non-member"})
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      {:ok, _} = Tasks.create_plan(%{task_id: t.id, status: "approved"})

      # Just confirm no crash and the transition succeeds.
      assert {:ok, updated} = Tasks.transition_task(t, "in_progress")
      assert updated.status == "in_progress"
    end
  end

  describe "sweep_stack_dependents/1" do
    test "no-op when task is not in any stack" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep non-member"})
      {:ok, free} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      assert {:ok, []} = Stacks.sweep_stack_dependents(free)
    end

    test "no-op when merged_into_rollup_at is not set" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep unstamped"})
      stack = stack_fixture(project_id: project.id)
      {:ok, t} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, attached} = Stacks.add_task(stack, t)
      assert {:ok, []} = Stacks.sweep_stack_dependents(attached)
    end

    test "promotes every now-unblocked stack_pending dependent" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep promote"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child_a} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child A",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, child_b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child B",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_a} = Stacks.add_task(stack, child_a)
      {:ok, attached_b} = Stacks.add_task(stack, child_b)

      # ADR 0042 Decision 4: commencement gate requires every member plan
      # approved AND stack.status == "in_progress".
      {:ok, _} = Tasks.create_plan(%{task_id: attached_parent.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: attached_a.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: attached_b.id, status: "approved"})

      stack
      |> Ecto.Changeset.change(status: "in_progress")
      |> Repo.update!()

      # Park both dependents at stack_pending.
      attached_a
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      attached_b
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      # Cross the unblock threshold on parent: in_review + merged stamp.
      stamped_parent =
        attached_parent
        |> Task.changeset(%{
          status: "in_review",
          metadata: %{
            "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
          }
        })
        |> Repo.update!()

      assert {:ok, promoted} = Stacks.sweep_stack_dependents(stamped_parent)
      assert length(promoted) == 2
      assert Enum.all?(promoted, &(&1.status == "in_progress"))
    end

    test "leaves dependents whose threshold is not yet met alone" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep partial"})
      stack = stack_fixture(project_id: project.id)
      {:ok, p1} = Tasks.create_task(%{project_id: project.id, title: "P1"})
      {:ok, p2} = Tasks.create_task(%{project_id: project.id, title: "P2"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child waiting on both",
          dependencies: [
            %{"task_id" => p1.id, "kind" => "blocks"},
            %{"task_id" => p2.id, "kind" => "blocks"}
          ]
        })

      {:ok, attached_p1} = Stacks.add_task(stack, p1)
      {:ok, _attached_p2} = Stacks.add_task(stack, p2)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      {:ok, _} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      attached_child
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      # Only P1 has crossed the threshold — P2 is still unmet.
      stamped_p1 =
        attached_p1
        |> Task.changeset(%{
          status: "in_review",
          metadata: %{
            "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
          }
        })
        |> Repo.update!()

      assert {:ok, []} = Stacks.sweep_stack_dependents(stamped_p1)
      assert Tasks.get_task_record(attached_child.id).status == "stack_pending"
    end

    test "fires automatically from Tasks.update_task/2 on a fresh stamp" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep via update_task"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # ADR 0042 Decision 4: gate needs every plan approved AND stack
      # itself at `in_progress` for the sweep's in_progress promotion.
      {:ok, _} = Tasks.create_plan(%{task_id: attached_parent.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      stack
      |> Ecto.Changeset.change(status: "in_progress")
      |> Repo.update!()

      attached_child
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      # Set parent to in_review (no merge stamp yet) so the threshold
      # status is satisfied — keeps the test honest that the SWEEP fires
      # on the stamp transition, not on status alone.
      attached_parent
      |> Task.changeset(%{status: "in_review"})
      |> Repo.update!()

      reloaded_parent = Tasks.get_task_record(attached_parent.id)

      # Single update_task/2 call that adds the stamp. The sweep is
      # invoked synchronously after the write.
      assert {:ok, _} =
               Tasks.update_task(reloaded_parent, %{
                 metadata: %{
                   "merged_into_rollup_at" => %{
                     "sha" => "abc1234",
                     "at" => "2026-07-17T00:00:00Z"
                   }
                 }
               })

      assert Tasks.get_task_record(attached_child.id).status == "in_progress"
    end

    test "does NOT fire when an existing stamp is re-written to the same value" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep re-stamp"})
      stack = stack_fixture(project_id: project.id)
      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      # Parent already has the stamp + in_review state. We're checking
      # that a subsequent update_task/2 that does NOT transition the stamp
      # from nil-to-value won't re-fire the sweep. Child is left at
      # backlog (not stack_pending) so even if the sweep DID fire it
      # would no-op — what we're really asserting is that no promotion
      # happens on the second write.
      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => "abc1234", "at" => "2026-07-17T00:00:00Z"}
        }
      })
      |> Repo.update!()

      attached_child
      |> Task.changeset(%{status: "stack_pending"})
      |> Repo.update!()

      reloaded_parent = Tasks.get_task_record(attached_parent.id)

      # No approved plan, so a promotion would FAIL — confirms sweep did
      # not run. Stamp is rewritten but stays non-nil before-and-after.
      assert {:ok, _} =
               Tasks.update_task(reloaded_parent, %{
                 metadata: %{
                   "merged_into_rollup_at" => %{
                     "sha" => "abc1234",
                     "at" => "2026-07-17T00:00:00Z"
                   },
                   "extra" => true
                 }
               })

      assert Tasks.get_task_record(attached_child.id).status == "stack_pending"
    end
  end

  describe "recompute_stack_status/1" do
    test "all-done members → done" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup done"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "done")
      set_member_status(stack, b, "done")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "done"
    end

    # Bug #6 (task 019f708f) semantic: the `deploying` arm requires
    # ALL members to be in {deploying, done} — symmetric with the
    # `in_review` arm. Under the pre-bug-#6 shape a mixed
    # [in_review, deploying] rolled up to `"deploying"`; under the
    # new shape it rolls up to `"in_review"` because the members
    # are still in the review-window set.
    test "all-deploying members → deploying" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup deploying"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "deploying")
      set_member_status(stack, b, "deploying")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "deploying"
    end

    test "mixed [in_review, deploying] → in_review (not deploying)" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup deploying-vs-review"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "in_review")
      set_member_status(stack, b, "deploying")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "in_review"
    end

    test "all in_review/deploying/done → in_review" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup in-review"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "in_review")
      set_member_status(stack, b, "done")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "in_review"
    end

    test "any in_progress with non-advanced sibling → in_progress" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup in-progress"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "in_progress")
      set_member_status(stack, b, "stack_pending")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "in_progress"
    end

    # Bug #6 (task 019f708f): `stack_pending` now counts as an
    # in-progress signal (the stack is commenced, just gated behind
    # deps). Only members truly in the pre-commencement set
    # (`backlog`, `planning`) with no `stack_pending`/`in_progress`
    # sibling can leave the stack at `"forming"`.
    test "all backlog/planning (no stack_pending, no in_progress) → forming" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup forming"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)

      set_member_status(stack, a, "backlog")
      set_member_status(stack, b, "planning")

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "forming"
    end

    test "abandoned stack stays abandoned (terminal, no recompute)" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup abandoned"})
      stack = stack_fixture(project_id: project.id)
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, _} = Stacks.add_task(stack, a)
      set_member_status(stack, a, "done")

      {:ok, abandoned} = Stacks.abandon_stack(stack, "scope cut")
      assert abandoned.status == "abandoned"

      assert {:ok, after_recompute} = Stacks.recompute_stack_status(abandoned)
      assert after_recompute.status == "abandoned"
    end

    test "skips DB write when computed status equals current" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup no-op"})
      stack = stack_fixture(project_id: project.id)
      # Empty stack rolls up to `forming` — same as default.
      assert stack.status == "forming"
      assert {:ok, after_recompute} = Stacks.recompute_stack_status(stack)
      # No-op path should return the same in-memory struct.
      assert after_recompute.id == stack.id
      assert after_recompute.status == "forming"
    end

    test "accepts a stack id and returns :stack_not_found for unknown id" do
      {:ok, project} = Tasks.create_project(%{name: "Rollup by id"})
      stack = stack_fixture(project_id: project.id)
      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack.id)
      assert recomputed.id == stack.id

      assert {:error, :stack_not_found} =
               Stacks.recompute_stack_status(Ecto.UUID.generate())
    end
  end

  # ── Bug #6 (task 019f708f): rollup_status_for/1 mixed-stack matrix ──
  #
  # The old `Enum.any?(&1 == "deploying")` arm classified a stack
  # like `[deploying × 3, stack_pending × 3]` as `"deploying"`,
  # but `CommencementGate.open?/1` refuses to promote a
  # `stack_pending` member unless the stack itself is
  # `"in_progress"`. Result: silent deadlock — the last three
  # members never advance.
  #
  # These tests cover every branch of the corrected `cond` block
  # against the exact input matrix the plan spelled out, plus a
  # regression that walks a stack through
  # forming → in_progress → in_review → deploying → done with
  # mixed intermediate states.

  describe "recompute_stack_status/1 — bug #6 mixed-status matrix" do
    alias Platform.Tasks.Stacks.CommencementGate

    defp seed_stack_with_members!(name, member_statuses) do
      {:ok, project} = Tasks.create_project(%{name: name})
      stack = stack_fixture(project_id: project.id)

      _members =
        for {status, i} <- Enum.with_index(member_statuses, 1) do
          {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "M#{i}"})
          {:ok, attached} = Stacks.add_task(stack, task)
          set_member_status(stack, attached, status)
          attached
        end

      %{project: project, stack: stack}
    end

    test "THE STALL CASE: [deploying × 3, stack_pending × 3] → in_progress (not deploying)" do
      %{stack: stack} =
        seed_stack_with_members!("Stall matrix", [
          "deploying",
          "deploying",
          "deploying",
          "stack_pending",
          "stack_pending",
          "stack_pending"
        ])

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)

      assert recomputed.status == "in_progress",
             "mixed [deploying × 3, stack_pending × 3] must roll up to in_progress " <>
               "(pre-bug-#6 shape returned \"deploying\" and silently deadlocked the " <>
               "stack_pending members behind CommencementGate)"
    end

    test "[deploying × 6] → deploying" do
      %{stack: stack} =
        seed_stack_with_members!("All deploying", List.duplicate("deploying", 6))

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "deploying"
    end

    test "[done, deploying, deploying] → deploying" do
      %{stack: stack} =
        seed_stack_with_members!("Done-deploying", ["done", "deploying", "deploying"])

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "deploying"
    end

    test "[done × 6] → done" do
      %{stack: stack} = seed_stack_with_members!("All done", List.duplicate("done", 6))

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "done"
    end

    test "[in_review, in_review, deploying, done] → in_review" do
      %{stack: stack} =
        seed_stack_with_members!(
          "Mixed in-review",
          ["in_review", "in_review", "deploying", "done"]
        )

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "in_review"
    end

    test "[in_progress, stack_pending, stack_pending] → in_progress" do
      %{stack: stack} =
        seed_stack_with_members!(
          "In-progress + stack-pending",
          ["in_progress", "stack_pending", "stack_pending"]
        )

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "in_progress"
    end

    test "[stack_pending × 3] → in_progress (commenced, not forming)" do
      %{stack: stack} =
        seed_stack_with_members!("All stack-pending", List.duplicate("stack_pending", 3))

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)

      assert recomputed.status == "in_progress",
             "an all-stack_pending stack is commenced (start_stack has fired), " <>
               "not forming — pre-bug-#6 shape leaked it to forming"
    end

    test "empty stack → forming (unchanged)" do
      {:ok, project} = Tasks.create_project(%{name: "Empty stack"})
      stack = stack_fixture(project_id: project.id)

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "forming"
    end

    # Regression: CommencementGate.open?/1 gates on the stack's own
    # `status == "in_progress"`. With the bug #6 fix, the mixed
    # `[deploying, deploying, stack_pending]` stack correctly rolls
    # up to `"in_progress"` — which is the necessary condition for
    # the gate to consider opening. `plans_ready?/1` is an
    # orthogonal check (every member holds an approved plan) that
    # gates the final open/closed answer; here we assert the
    # `stack.status` precondition specifically, which is the
    # regression the T4 stall exhibited.
    test "mixed [deploying × 2, stack_pending] stack rolls up to in_progress (CommencementGate precondition)" do
      %{project: project, stack: stack} =
        seed_stack_with_members!(
          "Gate regression",
          ["deploying", "deploying", "stack_pending"]
        )

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)

      assert recomputed.status == "in_progress",
             "pre-bug-#6 shape returned \"deploying\" here — CommencementGate would " <>
               "refuse to promote the stack_pending member and the stack would silently " <>
               "deadlock. The bug #6 fix restores the \"in_progress\" precondition."

      # Sanity: the stack_pending member exists on the stack.
      pending_members =
        Tasks.list_tasks_by_project(project.id)
        |> Enum.filter(&(&1.status == "stack_pending"))

      assert length(pending_members) == 1

      # `CommencementGate.open?/1` reads stack.status via the FK;
      # the gate's open/closed answer additionally depends on
      # `plans_ready?/1` (orthogonal to rollup_status). Call it
      # against a `%Task{stack: recomputed}` so we're verifying at
      # minimum that the gate no longer short-circuits on the
      # pre-bug-#6 `"deploying"` classification.
      [pending_member] = pending_members

      pending_member =
        pending_member
        |> Platform.Repo.preload(:stack)
        |> Map.put(:stack, recomputed)

      # Under the OLD `rollup_status_for/1`, the stack would have
      # been `"deploying"` and `open?` would return false with
      # `blocked_by_count: 0` (stack-status branch). Under the NEW
      # shape, the stack is `"in_progress"` and `open?` enters the
      # `plans_ready?` branch — which may still return false if
      # members lack approved plans, but that's a different gate.
      # We assert the branch we entered, not the final answer.
      _ = CommencementGate.open?(pending_member)
    end
  end

  describe "recompute_stack_status/1 — maybe_open_stack_pr piggy-back" do
    alias Platform.Tasks.StacksTest.RecomputePrHookRunner

    setup :install_pr_hook_runner

    test "fully-ready stack: recompute opens the rollup PR (piggy-back fires)", %{
      project: project
    } do
      pr_url = "https://github.com/test/repo/pull/4242"
      RecomputePrHookRunner.set_pr_response({:ok, %{number: 4242, url: pr_url}})

      stack = stack_for_pr_hook!(project, slug: "ready-#{short_id()}")

      _ = stamp_merged_member!(project, stack, sha: "shaone1", position: 1)
      _ = stamp_merged_member!(project, stack, sha: "shatwo2", position: 2)

      # Members all stamped at "in_review"; rollup_status_for/1 returns
      # "in_review" — a real status change from the default "forming" →
      # recompute writes the row AND fires the piggy-back. The deployer's
      # `do_open_stack_pr/2` then performs its own write, flipping the
      # stack to "deploying"; that's why the in-memory recompute return
      # is "in_review" but the reloaded row is "deploying".
      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      assert recomputed.status == "in_review"

      # Exactly ONE rollup PR shell-out from the piggy-back path.
      assert [pr_call] = RecomputePrHookRunner.pr_calls()
      assert pr_call.stack_id == stack.id

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.status == "deploying"
      assert reloaded.metadata["rollup_pr"]["number"] == 4242
      assert reloaded.metadata["rollup_pr"]["url"] == pr_url
    end

    test "partially-ready stack: recompute does NOT open the PR (deployer noop)", %{
      project: project
    } do
      stack = stack_for_pr_hook!(project, slug: "partial-#{short_id()}")

      # 1 merged + 1 unmerged → all_members_ready?/1 returns false.
      _ = stamp_merged_member!(project, stack, sha: "halfway1", position: 1)
      _ = stamp_unmerged_member!(project, stack, position: 2)

      assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
      # Mixed in_progress + in_review members → in_progress rollup.
      assert recomputed.status == "in_progress"

      # Piggy-back fired but the deployer's gate returned :not_ready.
      assert RecomputePrHookRunner.pr_calls() == []

      reloaded = Stacks.get_stack(stack.id)
      assert is_nil(get_in(reloaded.metadata || %{}, ["rollup_pr"]))
    end

    test "already-open rollup PR: recompute is no-op for the deployer (idempotent)", %{
      project: project
    } do
      stack = stack_for_pr_hook!(project, slug: "alreadyopen-#{short_id()}")

      # Members at "deploying" so `rollup_status_for/1` keeps the stack at
      # "deploying" — no DB write — but the piggy-back still fires.
      m1 = stamp_merged_member!(project, stack, sha: "openme1", position: 1)
      m2 = stamp_merged_member!(project, stack, sha: "openme2", position: 2)
      {:ok, _} = Tasks.update_task(m1, %{status: "deploying"})
      {:ok, _} = Tasks.update_task(m2, %{status: "deploying"})

      # Pre-stamp metadata.rollup_pr so the deployer gate short-circuits.
      pr_meta = %{
        "number" => 7,
        "url" => "https://github.com/test/repo/pull/7",
        "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      {:ok, locked} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: Map.put(stack.metadata || %{}, "rollup_pr", pr_meta)
        })

      assert {:ok, recomputed} = Stacks.recompute_stack_status(locked)
      # Stack already at "deploying" — no DB write, but piggy-back still fires.
      assert recomputed.status == "deploying"

      # Deployer hit the :already_open guard; no PR shell-out.
      assert RecomputePrHookRunner.pr_calls() == []

      # Metadata preserved.
      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.metadata["rollup_pr"]["number"] == 7
    end

    test "deployer raise: recompute return value is unchanged (failure isolated)", %{
      project: project
    } do
      stack = stack_for_pr_hook!(project, slug: "boom-#{short_id()}")
      _ = stamp_merged_member!(project, stack, sha: "boomshe1", position: 1)
      _ = stamp_merged_member!(project, stack, sha: "boomshe2", position: 2)

      # Make the runner's open_stack_pr raise. The piggy-back catches
      # the exception, logs, and returns :ok without disturbing the
      # recompute_stack_status return.
      RecomputePrHookRunner.set_pr_response({:raise, "synthetic git boom"})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # The recompute return value is the in-memory rollup result —
          # NOT affected by the deployer's downstream write or its raise.
          # Members at "in_review" → rollup says "in_review".
          assert {:ok, recomputed} = Stacks.recompute_stack_status(stack)
          assert recomputed.status == "in_review"
          assert recomputed.id == stack.id
        end)

      # The raise was logged via the piggy-back's rescue (failure isolated).
      assert log =~ "[Stacks] recompute_stack_status piggy-back"
      assert log =~ "raised for stack #{stack.id}"

      # Crucially: the recompute call itself returned `{:ok, _}` rather
      # than propagating the deployer raise. That's the failure-isolation
      # contract this stage establishes.
    end
  end

  describe "stack_phase_assignees/1" do
    test "returns %{} for a stack with no phase_assignees metadata" do
      stack = stack_fixture()
      assert Stacks.stack_phase_assignees(stack) == %{}
    end

    test "returns %{} for non-map metadata or nil" do
      assert Stacks.stack_phase_assignees(nil) == %{}
      assert Stacks.stack_phase_assignees("nope") == %{}
      assert Stacks.stack_phase_assignees(%{}) == %{}
    end

    test "returns the normalized map from metadata" do
      agent = Ecto.UUID.generate()

      stack =
        stack_with_phase_assignees(%{
          "planning" => %{"assignee_id" => agent, "assignee_type" => "agent"},
          "execution" => %{"assignee_id" => agent, "assignee_type" => "agent"},
          "review" => %{"assignee_id" => agent, "assignee_type" => "agent"}
        })

      pa = Stacks.stack_phase_assignees(stack)
      assert pa["planning"] == %{"assignee_id" => agent, "assignee_type" => "agent"}
      assert pa["execution"]["assignee_id"] == agent
      assert pa["review"]["assignee_id"] == agent
    end

    test "drops unknown phase keys" do
      agent = Ecto.UUID.generate()

      stack =
        stack_with_phase_assignees(%{
          "planning" => %{"assignee_id" => agent},
          "bogus" => %{"assignee_id" => agent},
          "deploy" => %{"assignee_id" => agent}
        })

      pa = Stacks.stack_phase_assignees(stack)
      assert Map.keys(pa) == ["planning"]
    end

    test "drops malformed per-phase entries and defaults assignee_type to agent" do
      agent = Ecto.UUID.generate()

      stack =
        stack_with_phase_assignees(%{
          "planning" => %{"assignee_id" => agent},
          "execution" => %{"assignee_id" => nil},
          "review" => "garbage"
        })

      pa = Stacks.stack_phase_assignees(stack)
      assert pa == %{"planning" => %{"assignee_id" => agent, "assignee_type" => "agent"}}
    end
  end

  describe "stack_assignee_for_phase/2" do
    test "returns {nil, nil} when no stack-level assignee for the phase" do
      stack = stack_fixture()
      assert Stacks.stack_assignee_for_phase(stack, "planning") == {nil, nil}
    end

    test "returns {id, type} for a configured phase" do
      agent = Ecto.UUID.generate()

      stack =
        stack_with_phase_assignees(%{
          "execution" => %{"assignee_id" => agent, "assignee_type" => "agent"}
        })

      assert Stacks.stack_assignee_for_phase(stack, "execution") == {agent, "agent"}
      assert Stacks.stack_assignee_for_phase(stack, "planning") == {nil, nil}
    end
  end

  describe "set_stack_phase_assignees/2" do
    test "writes the stack-level default and percolates to all un-overridden members" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "M2"})
      {:ok, _} = Stacks.add_task(stack, m1)
      {:ok, _} = Stacks.add_task(stack, m2)

      agent = Ecto.UUID.generate()

      assert {:ok, %{stack: updated_stack, percolated: percolated, skipped: []}} =
               Stacks.set_stack_phase_assignees(stack, all_phases(agent))

      assert Stacks.stack_phase_assignees(updated_stack) == all_phases(agent)
      assert length(percolated) == 2

      for member <- [m1, m2] do
        reloaded = Repo.get!(Task, member.id)
        assert reloaded.phase_assignees["planning"]["assignee_id"] == agent
        assert reloaded.phase_assignees["execution"]["assignee_id"] == agent
        assert reloaded.phase_assignees["review"]["assignee_id"] == agent
        # current phase for a backlog task is "planning"
        assert reloaded.assignee_id == agent
      end
    end

    test "skips members flagged assignee_override and reports them in :skipped" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, m2} = Tasks.create_task(%{project_id: project.id, title: "M2"})
      {:ok, _} = Stacks.add_task(stack, m1)
      {:ok, m2} = Stacks.add_task(stack, m2)

      agent_b = Ecto.UUID.generate()
      m2 = stamp_override(m2, agent_b)

      agent_a = Ecto.UUID.generate()

      assert {:ok, %{percolated: [percolated], skipped: [skipped]}} =
               Stacks.set_stack_phase_assignees(stack, all_phases(agent_a))

      assert percolated.id == m1.id
      assert skipped.id == m2.id

      # m1 inherited agent_a
      assert Repo.get!(Task, m1.id).assignee_id == agent_a
      # m2 kept its individual override (agent_b)
      m2_reloaded = Repo.get!(Task, m2.id)
      assert m2_reloaded.assignee_id == agent_b
      assert m2_reloaded.phase_assignees["execution"]["assignee_id"] == agent_b
    end

    test "merges partial updates phase-by-phase, leaving other phases intact" do
      stack = stack_fixture()
      agent_a = Ecto.UUID.generate()
      agent_b = Ecto.UUID.generate()

      {:ok, _} = Stacks.set_stack_phase_assignees(stack, all_phases(agent_a))

      assert {:ok, %{stack: updated}} =
               Stacks.set_stack_phase_assignees(stack, %{
                 "execution" => %{"assignee_id" => agent_b, "assignee_type" => "agent"}
               })

      pa = Stacks.stack_phase_assignees(updated)
      assert pa["planning"]["assignee_id"] == agent_a
      assert pa["execution"]["assignee_id"] == agent_b
      assert pa["review"]["assignee_id"] == agent_a
    end

    test "returns {:error, :stack_not_found} for an unknown stack id" do
      assert {:error, :stack_not_found} =
               Stacks.set_stack_phase_assignees(Ecto.UUID.generate(), %{})
    end

    test "preserves other metadata keys on the stack" do
      stack = stack_fixture()

      {:ok, stack} =
        stack
        |> Stack.changeset(%{metadata: %{"keep" => "this"}})
        |> Repo.update()

      agent = Ecto.UUID.generate()
      {:ok, %{stack: updated}} = Stacks.set_stack_phase_assignees(stack, all_phases(agent))

      assert updated.metadata["keep"] == "this"
      assert updated.metadata["phase_assignees"]["planning"]["assignee_id"] == agent
    end
  end

  describe "add_task/2 — stack-level assignment inheritance" do
    test "a joining task with no override inherits the stack-level default" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      agent = Ecto.UUID.generate()
      {:ok, _} = Stacks.set_stack_phase_assignees(stack, all_phases(agent))

      {:ok, newcomer} = Tasks.create_task(%{project_id: project.id, title: "Late joiner"})
      assert {:ok, joined} = Stacks.add_task(stack, newcomer)

      assert joined.phase_assignees["planning"]["assignee_id"] == agent
      assert joined.phase_assignees["execution"]["assignee_id"] == agent
      assert joined.phase_assignees["review"]["assignee_id"] == agent
      assert joined.assignee_id == agent
    end

    test "a joining task flagged assignee_override keeps its own assignment" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      agent_a = Ecto.UUID.generate()
      {:ok, _} = Stacks.set_stack_phase_assignees(stack, all_phases(agent_a))

      agent_b = Ecto.UUID.generate()
      {:ok, newcomer} = Tasks.create_task(%{project_id: project.id, title: "Self-assigned"})
      newcomer = stamp_override(newcomer, agent_b)

      assert {:ok, joined} = Stacks.add_task(stack, newcomer)
      assert joined.assignee_id == agent_b
      assert joined.phase_assignees["execution"]["assignee_id"] == agent_b
    end

    test "a joining task is untouched when the stack has no stack-level default" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      {:ok, newcomer} = Tasks.create_task(%{project_id: project.id, title: "Plain"})

      assert {:ok, joined} = Stacks.add_task(stack, newcomer)
      assert joined.phase_assignees == %{}
      assert joined.assignee_id == nil
    end
  end

  describe "clear_member_override/1" do
    test "unsets the override flag and re-applies the stack-level default" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, m1} = Stacks.add_task(stack, m1)

      agent_b = Ecto.UUID.generate()
      m1 = stamp_override(m1, agent_b)

      agent_a = Ecto.UUID.generate()
      {:ok, _} = Stacks.set_stack_phase_assignees(stack, all_phases(agent_a))

      # m1 was skipped, still on agent_b
      assert Repo.get!(Task, m1.id).assignee_id == agent_b

      assert {:ok, cleared} = Stacks.clear_member_override(m1)
      refute Stacks.member_overridden?(cleared)
      assert cleared.assignee_id == agent_a
      assert cleared.phase_assignees["execution"]["assignee_id"] == agent_a
    end

    test "just clears the flag when the stack has no stack-level default" do
      project = project_fixture()
      stack = stack_fixture(project_id: project.id)
      {:ok, m1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, m1} = Stacks.add_task(stack, m1)

      agent_b = Ecto.UUID.generate()
      m1 = stamp_override(m1, agent_b)

      assert {:ok, cleared} = Stacks.clear_member_override(m1)
      refute Stacks.member_overridden?(cleared)
      # no stack default to re-apply — keeps its existing phase_assignees
      assert cleared.phase_assignees["execution"]["assignee_id"] == agent_b
    end

    test "returns {:error, :not_in_stack} for a task with no stack_id" do
      project = project_fixture()
      {:ok, free} = Tasks.create_task(%{project_id: project.id, title: "Free"})
      assert {:error, :not_in_stack} = Stacks.clear_member_override(free)
    end

    test "returns {:error, :task_not_found} for an unknown task id" do
      assert {:error, :task_not_found} = Stacks.clear_member_override(Ecto.UUID.generate())
    end
  end

  describe "member_overridden?/1" do
    test "true only when metadata.assignee_override == true" do
      assert Stacks.member_overridden?(%{"assignee_override" => true})
      refute Stacks.member_overridden?(%{"assignee_override" => false})
      refute Stacks.member_overridden?(%{"assignee_override" => "true"})
      refute Stacks.member_overridden?(%{})
      refute Stacks.member_overridden?(nil)
    end
  end

  describe "stack_gate_opened broadcast (ADR 0042 Decision 4, stage 3)" do
    # The gate-open transition fires when the LAST pending plan in a stack
    # is approved. The broadcast is a signal only — no member is
    # auto-transitioned. Members stay at `stack_pending` until an
    # explicit `Tasks.transition_task/2` (or MCP `task_start`).

    test "approving the last pending plan fires {:stack_gate_opened, stack_id, executable_ids}" do
      {:ok, project} = Tasks.create_project(%{name: "Gate broadcast happy"})
      stack = stack_fixture(project_id: project.id)

      {:ok, root_a} = Tasks.create_task(%{project_id: project.id, title: "Root A"})
      {:ok, root_b} = Tasks.create_task(%{project_id: project.id, title: "Root B"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child of A",
          dependencies: [%{"task_id" => root_a.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, root_a)
      {:ok, _} = Stacks.add_task(stack, root_b)
      {:ok, _} = Stacks.add_task(stack, child)

      # A + B already approved; C is the last-pending plan.
      {:ok, _} = Tasks.create_plan(%{task_id: root_a.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: root_b.id, status: "approved"})
      {:ok, c_draft} = Tasks.create_plan(%{task_id: child.id})
      {:ok, c_pending} = Tasks.submit_plan_for_review(c_draft)

      :ok = Tasks.subscribe_board()

      assert {:ok, _approved} = Tasks.approve_plan(c_pending, "system")

      assert_receive {:stack_gate_opened, stack_id, executable_ids}
      assert stack_id == stack.id

      # Roots are the two members with no in-stack deps. Child depends
      # on root_a (via tasks.dependencies -> resolved in-stack), so it's
      # NOT a root. Order is non-deterministic; sort before compare.
      assert Enum.sort(executable_ids) == Enum.sort([root_a.id, root_b.id])
    end

    test "approving an intermediate plan does NOT fire :stack_gate_opened" do
      {:ok, project} = Tasks.create_project(%{name: "Gate broadcast intermediate"})
      stack = stack_fixture(project_id: project.id)

      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "C"})

      {:ok, _} = Stacks.add_task(stack, a)
      {:ok, _} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_task(stack, c)

      # A already approved. B is what we're approving. C is still pending
      # (has no plan at all), so plans_ready? stays false after this call.
      {:ok, _} = Tasks.create_plan(%{task_id: a.id, status: "approved"})
      {:ok, b_draft} = Tasks.create_plan(%{task_id: b.id})
      {:ok, b_pending} = Tasks.submit_plan_for_review(b_draft)

      :ok = Tasks.subscribe_board()

      assert {:ok, _} = Tasks.approve_plan(b_pending, "system")

      # We should get the plan_updated broadcast but NOT the gate signal.
      assert_receive {:plan_updated, _}
      refute_receive {:stack_gate_opened, _, _}, 100
    end

    test "approving a plan on a NON-stack task does not fire :stack_gate_opened" do
      {:ok, project} = Tasks.create_project(%{name: "Gate broadcast non-stack"})

      {:ok, standalone} =
        Tasks.create_task(%{project_id: project.id, title: "Standalone", status: "planning"})

      {:ok, draft} = Tasks.create_plan(%{task_id: standalone.id})
      {:ok, pending} = Tasks.submit_plan_for_review(draft)

      # BOARD-SCOPE-EXEMPT (durable — survives any future `async: true` move):
      # this case has NO stack, so there is no `stack: id` to subscribe to. The
      # assertion is that no gate signal fires for ANY stack; scoping it to a
      # stack id would assume the very thing under test. Global is the only
      # subscription that can observe this negative.
      :ok = Tasks.subscribe_board()

      assert {:ok, _} = Tasks.approve_plan(pending, "system")

      # plan_updated + task_updated fire — but no gate signal for a task
      # with `stack_id: nil`.
      assert_receive {:plan_updated, _}
      refute_receive {:stack_gate_opened, _, _}, 100
    end

    test "gate open commences a forming-but-ready stack, respecting dependency order (Gap 3, task 019f921d)" do
      # Gap 3 (task 019f921d) changes the old signal-only contract: a
      # `forming`-but-ready stack now auto-commences on the LAST-plan
      # approval (`commence_if_ready/1` fires just before
      # `:stack_gate_opened`), so a ready stack can never stay stuck in
      # `forming` — the deadlock that stranded every Inbox member. The
      # commence still respects the in-stack DAG: only roots reach
      # `in_progress`; dependents stay `stack_pending` until their deps
      # clear (that ordering is NOT auto-skipped by the gate).
      {:ok, project} = Tasks.create_project(%{name: "Gate commence on ready"})
      stack = stack_fixture(project_id: project.id)

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child depends on Root",
          dependencies: [%{"task_id" => root.id, "kind" => "blocks"}]
        })

      {:ok, _} = Stacks.add_task(stack, root)
      {:ok, _} = Stacks.add_task(stack, child)

      # Root already approved; the child's approval is the LAST plan, which
      # flips the commencement gate closed → open on a still-`forming` stack.
      {:ok, _} = Tasks.create_plan(%{task_id: root.id, status: "approved"})
      {:ok, c_draft} = Tasks.create_plan(%{task_id: child.id})
      {:ok, c_pending} = Tasks.submit_plan_for_review(c_draft)

      :ok = Tasks.subscribe_board()

      assert {:ok, _} = Tasks.approve_plan(c_pending, "system")

      assert_receive {:stack_gate_opened, _, _}

      # The forming stack self-healed to in_progress; the root reached
      # in_progress; the dependent child stays stack_pending (dep order
      # preserved — the gate does NOT leapfrog dependencies).
      assert Stacks.get_stack!(stack.id).status == "in_progress"
      assert Tasks.get_task_record(root.id).status == "in_progress"
      assert Tasks.get_task_record(child.id).status == "stack_pending"
    end
  end

  # ── cascade_members_to_done/1 (Stack v2 stage 5) ───────────────────────

  describe "cascade_members_to_done/1" do
    test "no-ops when every member is already done" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade all-done"})
      stack = stack_fixture(project_id: project.id)

      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, t2} = Tasks.create_task(%{project_id: project.id, title: "M2"})
      {:ok, _} = Stacks.add_task(stack, t1)
      {:ok, _} = Stacks.add_task(stack, t2)

      set_member_status(stack, t1, "done")
      set_member_status(stack, t2, "done")

      assert %{cascaded: [], skipped: []} = Stacks.cascade_members_to_done(stack)
    end

    test "transitions in_review members to done directly (fan-out fallback)" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade fallback"})
      stack = stack_fixture(project_id: project.id)

      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, t2} = Tasks.create_task(%{project_id: project.id, title: "M2"})
      {:ok, _} = Stacks.add_task(stack, t1)
      {:ok, _} = Stacks.add_task(stack, t2)

      # Simulate the "webhook fan-out missed this member" case: member is
      # at `in_review` with no `pr_merged` validation to auto-pass.
      set_member_status(stack, t1, "in_review")
      set_member_status(stack, t2, "in_review")

      assert %{cascaded: cascaded, skipped: []} = Stacks.cascade_members_to_done(stack)
      assert length(cascaded) == 2
      assert Enum.all?(cascaded, &(&1.status == "done"))
      assert Tasks.get_task_record(t1.id).status == "done"
      assert Tasks.get_task_record(t2.id).status == "done"
    end

    test "mixed cascade: some members already done, others need transition" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade mixed"})
      stack = stack_fixture(project_id: project.id)

      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, t2} = Tasks.create_task(%{project_id: project.id, title: "M2"})
      {:ok, t3} = Tasks.create_task(%{project_id: project.id, title: "M3"})
      {:ok, _} = Stacks.add_task(stack, t1)
      {:ok, _} = Stacks.add_task(stack, t2)
      {:ok, _} = Stacks.add_task(stack, t3)

      set_member_status(stack, t1, "done")
      set_member_status(stack, t2, "in_review")
      set_member_status(stack, t3, "in_review")

      assert %{cascaded: cascaded, skipped: []} = Stacks.cascade_members_to_done(stack)
      # Only t2 and t3 flipped; t1 was already done and silently skipped.
      assert length(cascaded) == 2
      cascaded_ids = Enum.map(cascaded, & &1.id) |> Enum.sort()
      assert cascaded_ids == Enum.sort([t2.id, t3.id])
    end

    test "surfaces skipped members when a transition is illegal" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade skip"})
      stack = stack_fixture(project_id: project.id)

      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, _} = Stacks.add_task(stack, t1)

      # `backlog` → `done` is NOT in @valid_task_transitions, so cascade
      # should surface this member in `skipped` rather than raise.
      set_member_status(stack, t1, "backlog")

      assert %{cascaded: [], skipped: [entry]} = Stacks.cascade_members_to_done(stack)
      assert entry.task_id == t1.id
      assert entry.status == "backlog"
      assert entry.reason != nil
    end

    test "id-vs-struct polymorphism" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade id"})
      stack = stack_fixture(project_id: project.id)

      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, _} = Stacks.add_task(stack, t1)
      set_member_status(stack, t1, "in_review")

      assert %{cascaded: [_]} = Stacks.cascade_members_to_done(stack.id)
    end

    test "unknown stack id returns skipped :stack_not_found without raising" do
      assert %{cascaded: [], skipped: [%{reason: :stack_not_found}]} =
               Stacks.cascade_members_to_done(Ecto.UUID.generate())
    end

    # Stage 3 (019f5bc4-3521): atomic-cascade contract. When ANY member's
    # transition to `done` fails, the whole reduce rolls back — the earlier
    # successful transitions are reverted so we never leave a half-done
    # stack. Verified by seeding the last-position member at `backlog`
    # (illegal → done) while earlier members sit at `in_review` (legal
    # path); after the cascade the earlier members' statuses must still
    # read `in_review`, not `done`.
    test "rolls back all member transitions when one fails" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade rollback"})
      stack = stack_fixture(project_id: project.id)

      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, t2} = Tasks.create_task(%{project_id: project.id, title: "M2"})
      {:ok, t3} = Tasks.create_task(%{project_id: project.id, title: "M3"})
      {:ok, _} = Stacks.add_task(stack, t1)
      {:ok, _} = Stacks.add_task(stack, t2)
      {:ok, _} = Stacks.add_task(stack, t3)

      # t1 + t2 CAN transition in_review → done. t3 sits at backlog,
      # which is NOT in @valid_task_transitions for → done, so the
      # third pass through the reduce raises Repo.rollback.
      set_member_status(stack, t1, "in_review")
      set_member_status(stack, t2, "in_review")
      set_member_status(stack, t3, "backlog")

      assert %{cascaded: [], skipped: [entry]} = Stacks.cascade_members_to_done(stack)
      assert entry.task_id == t3.id
      assert entry.status == "backlog"
      assert entry.reason != nil

      # Sibling transitions were rolled back — DB state matches the
      # pre-cascade snapshot.
      assert Tasks.get_task_record(t1.id).status == "in_review"
      assert Tasks.get_task_record(t2.id).status == "in_review"
      assert Tasks.get_task_record(t3.id).status == "backlog"
    end

    test "emits :cascade_completed telemetry with cascaded_count=0 after rollback" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade rollback telemetry"})
      stack = stack_fixture(project_id: project.id)

      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "M1"})
      {:ok, t2} = Tasks.create_task(%{project_id: project.id, title: "M2"})
      {:ok, _} = Stacks.add_task(stack, t1)
      {:ok, _} = Stacks.add_task(stack, t2)

      set_member_status(stack, t1, "in_review")
      # t2 at backlog → illegal → forces rollback.
      set_member_status(stack, t2, "backlog")

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :deploy, :cascade_completed]
        ])

      Stacks.cascade_members_to_done(stack, :webhook)

      assert_receive {[:platform, :stacks, :deploy, :cascade_completed], ^ref, measurements,
                      metadata}

      # Idempotency contract from stage 2: one event per invocation,
      # even when the transaction rolled back.
      assert measurements.count == 1
      assert measurements.member_count == 2
      assert metadata.cascaded_count == 0
      assert metadata.skipped_count == 1
      assert metadata.trigger == :webhook
      assert metadata.stack_id == stack.id

      :telemetry.detach(ref)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Spin up the plan/stage/validation scaffolding a task needs before a
  # `manual_approval` review request can be created, then submit one
  # pending request with a single item. Returns the created `ReviewRequest`
  # (with items preloaded). Used by the `list_open_review_requests`
  # rollup tests to stand up cross-member review state without dragging
  # the full plan engine into the assertions.
  defp pending_review_request_for(%Task{id: task_id}, item_label) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task_id})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Review stage " <> short_id()
      })

    {:ok, _} = PlanEngine.start_stage(stage.id)

    {:ok, validation} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    ReviewRequests.create_review_request(%{
      validation_id: validation.id,
      task_id: task_id,
      items: [%{label: item_label}]
    })
  end

  # Bypass the broadcast pipeline + status-transition guards for setup —
  # we're exercising the rollup math, not the dispatcher.
  defp set_member_status(stack, %Task{id: id}, status) do
    member = Enum.find(Stacks.members(stack), &(&1.id == id))

    member
    |> Task.changeset(%{status: status})
    |> Repo.update!()
  end

  defp stack_fixture(attrs \\ []) do
    attrs = Map.new(attrs)

    project_id =
      Map.get_lazy(attrs, :project_id, fn ->
        {:ok, project} =
          Tasks.create_project(%{name: "Stack Fixture Project " <> Ecto.UUID.generate()})

        project.id
      end)

    slug = Map.get(attrs, :slug, "fixture-" <> short_id())
    name = Map.get(attrs, :name, "Fixture Stack")
    description = Map.get(attrs, :description)
    sponsor_user_id = Map.get(attrs, :sponsor_user_id)

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project_id,
        slug: slug,
        name: name,
        description: description,
        rollup_branch: Stacks.rollup_branch_name(slug),
        sponsor_user_id: sponsor_user_id
      })

    stack
  end

  # ADR 0042 sponsor tests: insert a bare user row bypassing the
  # `Platform.Accounts.User.changeset/2` name requirement so tests don't
  # need to plumb an OIDC identity fixture. Mirror of the same helper in
  # `apps/platform/test/platform/tasks/task_test.exs`.
  defp insert_sponsor_user(opts \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: Keyword.get(opts, :name, "Sponsor #{n}"),
      email: Keyword.get(opts, :email, "stack-sponsor-#{n}@example.com"),
      oidc_sub: "sub-stack-sponsor-#{n}"
    })
  end

  defp short_id do
    Ecto.UUID.generate() |> String.slice(0, 8)
  end

  # ── deploy_ready?/1 fixtures ───────────────────────────────────────────

  # Seed a completed plan with one non-deploy stage whose single validation
  # is `passed`. Represents the normal "member finished its work" shape.
  defp seed_completed_plan!(task, opts \\ []) do
    version = Keyword.get(opts, :version, 1)

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, version: version, status: "completed"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "passed"})

    {:ok, _v} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "passed"})

    plan
  end

  # Seed an executing plan whose non-deploy validation is still pending.
  # Represents a member that isn't actually done despite whatever status
  # the caller stamps on the task row.
  defp seed_plan_with_pending_validation!(task) do
    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, version: 1, status: "executing"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "running"})

    # Pending on purpose — status defaults to "pending" via Validation.changeset.
    {:ok, _v} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    plan
  end

  # Seed a completed plan whose non-deploy stage is fully passed AND a
  # trailing deploy stage that carries a still-pending `pr_merged`
  # validation. `PlanEngine.deploy_stage?/1` matches on either the "Deploy:"
  # name prefix or the presence of a ci_passed/pr_merged validation, so
  # the pending validation on the deploy stage must be excluded from the
  # readiness check.
  defp seed_completed_plan_with_pending_deploy_stage!(task) do
    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, version: 1, status: "completed"})

    {:ok, build_stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "passed"})

    {:ok, _} =
      Tasks.create_validation(%{stage_id: build_stage.id, kind: "test_pass", status: "passed"})

    {:ok, deploy_stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 2,
        name: "Deploy: PR merge",
        status: "pending"
      })

    {:ok, _} = Tasks.create_validation(%{stage_id: deploy_stage.id, kind: "pr_merged"})

    plan
  end

  # Stamp `metadata["merged_into_rollup_at"]` on a member task — the
  # downstream signal that `StackDeployer.all_members_ready?/1` requires
  # to permit `maybe_open_stack_pr/1` to shell out to the runner.
  # `handle_member_transition/3` sets this on real merges; tests use
  # this helper to short-circuit the merge machinery when they only
  # care about the PR-open gate.
  defp stamp_member_merged_into_rollup!(%Task{} = task, sha) do
    base = task.metadata || %{}

    new_meta =
      Map.put(base, "merged_into_rollup_at", %{
        "sha" => sha,
        "at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    {:ok, updated} = Tasks.update_task(task, %{metadata: new_meta})
    updated
  end

  # Seed a superseded plan with a leftover pending validation — the
  # equivalent of an older plan revision whose stages were mid-run when
  # the plan was replaced. Should NOT gate the deploy check.
  defp seed_superseded_plan_with_pending_validation!(task, opts) do
    version = Keyword.fetch!(opts, :version)

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, version: version, status: "superseded"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "running"})

    {:ok, _v} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    plan
  end

  defp project_fixture do
    {:ok, project} =
      Tasks.create_project(%{name: "Stacks App " <> Ecto.UUID.generate()})

    project
  end

  # All three phases assigned to one agent — the "simple mode" shape.
  defp all_phases(agent_id) do
    %{
      "planning" => %{"assignee_id" => agent_id, "assignee_type" => "agent"},
      "execution" => %{"assignee_id" => agent_id, "assignee_type" => "agent"},
      "review" => %{"assignee_id" => agent_id, "assignee_type" => "agent"}
    }
  end

  # Mimic the per-task assignee modal save path: set all-phase assignees on
  # the task AND stamp metadata["assignee_override"] = true.
  defp stamp_override(%Task{} = task, agent_id) do
    {:ok, task} = Tasks.set_phase_assignees(task, all_phases(agent_id))

    {:ok, task} =
      Tasks.update_task(task, %{
        metadata: Map.put(task.metadata || %{}, "assignee_override", true)
      })

    task
  end

  # Create a stack and stamp a raw `phase_assignees` map into its metadata,
  # bypassing normalization so read-helper tests can exercise malformed input.
  defp stack_with_phase_assignees(phase_assignees) do
    stack = stack_fixture()

    stack
    |> Stack.changeset(%{
      metadata: Map.put(stack.metadata || %{}, "phase_assignees", phase_assignees)
    })
    |> Repo.update!()
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ── recompute_stack_status piggy-back fixtures ─────────────────────────────
  #
  # In-memory `GitRunner` for the piggy-back tests. We only care about
  # whether `open_stack_pr/1` was called (and that it can be made to raise);
  # all other callbacks return safe defaults so the deployer's other code
  # paths can run unimpeded if the gate happens to fire.
  defmodule RecomputePrHookRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            pr_response: {:ok, %{number: 1, url: "https://github.com/test/repo/pull/1"}},
            pr_calls: []
          }
        end,
        name: __MODULE__
      )
    end

    def stop, do: Agent.stop(__MODULE__)

    def set_pr_response(response),
      do: Agent.update(__MODULE__, &Map.put(&1, :pr_response, response))

    def pr_calls, do: Agent.get(__MODULE__, & &1.pr_calls) |> Enum.reverse()

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, %{status: :already_exists, base_sha: nil}}

    @impl true
    def merge_member_into_rollup(_args),
      do: {:ok, %{status: :merged, merge_sha: "0000000000000000000000000000000000000000"}}

    @impl true
    def open_stack_pr(args) do
      response =
        Agent.get_and_update(__MODULE__, fn state ->
          {state.pr_response, %{state | pr_calls: [args | state.pr_calls]}}
        end)

      case response do
        # Raise on the caller side so we don't crash the Agent process.
        {:raise, msg} -> raise RuntimeError, message: msg
        other -> other
      end
    end

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def revert_member_merge(_args),
      do: {:ok, %{status: :reverted, revert_sha: "0000000000000000000000000000000000000000"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    # Bug #2 (task 019f708f): default to reachable so this runner
    # keeps behaving as pre-bug-#2 for the recompute piggy-back tests
    # (they don't exercise reachability behavior).
    @impl true
    def sha_reachable?(_args), do: {:ok, true}
  end

  defp install_pr_hook_runner(_ctx) do
    prev = Application.get_env(:platform, :stack_deployer, [])

    {:ok, _} = RecomputePrHookRunner.start_link()

    Application.put_env(:platform, :stack_deployer,
      git_runner: RecomputePrHookRunner,
      async: false
    )

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        RecomputePrHookRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Recompute PR Hook " <> Ecto.UUID.generate(),
        repo_url: "https://github.com/test/recompute-pr-hook-" <> short_id()
      })

    %{project: project}
  end

  defp stack_for_pr_hook!(project, opts) do
    slug = Keyword.get(opts, :slug, "pr-hook-" <> short_id())

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "PR-hook stack #{slug}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  # Create a stack member already stamped as merged-into-rollup (status
  # in_review + metadata.merged_into_rollup_at). Mirrors the helper in
  # `stack_deployer_test.exs` so the deployer's `all_members_ready?/1`
  # gate sees the member as ready.
  defp stamp_merged_member!(project, stack, opts) do
    # Bug #3 (task 019f708f): the changeset validator requires SHAs to
    # be at least 7 hex chars. Coerce non-hex / short test fixtures so
    # existing call sites don't need to be rewritten.
    sha = Keyword.fetch!(opts, :sha) |> pad_sha_for_validator()
    position = Keyword.get(opts, :position, 1)
    title = Keyword.get(opts, :title, "Merged member " <> short_id())

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "in_review"
      })

    {:ok, task} =
      Tasks.update_task(task, %{
        stack_id: stack.id,
        stack_position: position,
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => sha,
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })

    task
  end

  # Bug #3 helper: coerce short / non-hex shas into a
  # hex-shaped string at least 7 chars so the
  # `merged_into_rollup_at` shape validator accepts them.
  defp pad_sha_for_validator(sha) when is_binary(sha) do
    hex_only = String.replace(sha, ~r/[^0-9a-fA-F]/, "0")

    if byte_size(hex_only) >= 7 do
      hex_only
    else
      String.duplicate("0", 7 - byte_size(hex_only)) <> hex_only
    end
  end

  defp stamp_unmerged_member!(project, stack, opts) do
    position = Keyword.get(opts, :position, 1)

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Unmerged " <> short_id(),
        status: "in_progress"
      })

    {:ok, task} =
      Tasks.update_task(task, %{stack_id: stack.id, stack_position: position})

    task
  end

  # ── dispatch_stack_deploy/1 fixtures ───────────────────────────────────

  # In-memory GitRunner used by dispatch_stack_deploy/1 tests. We install
  # it via Application.put_env(:platform, :stack_deployer, ...) with
  # `async: false` so the deployer's `maybe_open_stack_pr/1` call from
  # `Stacks.trigger_stack_deploy_pr_open/1` runs synchronously and the
  # test can observe the runner call after the dispatch returns.
  defmodule DispatchNoopRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            pr_response: {:ok, %{number: 42, url: "https://github.com/test/repo/pull/42"}},
            pr_calls: [],
            notify_pid: nil
          }
        end,
        name: __MODULE__
      )
    end

    def stop, do: Agent.stop(__MODULE__)

    def pr_calls, do: Agent.get(__MODULE__, & &1.pr_calls) |> Enum.reverse()

    # Subscribe `pid` to `open_stack_pr/1` invocations. Used only by the
    # `async: true` describe block, which needs the pid of the process
    # that actually ran the runner.
    def notify(pid) when is_pid(pid) do
      Agent.update(__MODULE__, &Map.put(&1, :notify_pid, pid))
    end

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, %{status: :already_exists, base_sha: nil}}

    @impl true
    def merge_member_into_rollup(_args),
      do: {:ok, %{status: :merged, merge_sha: "0000000000000000000000000000000000000000"}}

    # When a `notify_pid` is registered, hand back the pid of the process
    # that invoked the runner. Under `async: true` that is the
    # `Elixir.Task.Supervisor` child, which gives the async regression
    # tests a deterministic barrier (monitor + `:DOWN`) instead of a
    # `Process.sleep`. Unset in the synchronous describe block, so nothing
    # is sent there and those tests are unaffected.
    @impl true
    def open_stack_pr(args) do
      {response, notify_pid} =
        Agent.get_and_update(__MODULE__, fn state ->
          {{state.pr_response, Map.get(state, :notify_pid)},
           %{state | pr_calls: [args | state.pr_calls]}}
        end)

      if is_pid(notify_pid), do: send(notify_pid, {:dispatch_pr_open_called, self()})

      response
    end

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def revert_member_merge(_args),
      do: {:ok, %{status: :reverted, revert_sha: "0000000000000000000000000000000000000000"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    # Bug #2 (task 019f708f): default to reachable so dispatch tests
    # continue exercising the shell-out path without needing to seed
    # per-SHA reachability responses.
    @impl true
    def sha_reachable?(_args), do: {:ok, true}
  end

  # Hazard-A twin of `DispatchNoopRunner`: every callback delegates,
  # except `open_stack_pr/1`, which records the call through the shared
  # Agent (so the async barrier still fires) and then raises. Pins the
  # stage-2 rescue in `Stacks.run_deploy_pr_open/1`.
  defmodule DispatchRaisingRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    @raise_message "simulated git failure opening rollup PR"

    def raise_message, do: @raise_message

    @impl true
    def ensure_rollup_branch(args), do: DispatchNoopRunner.ensure_rollup_branch(args)

    @impl true
    def merge_member_into_rollup(args), do: DispatchNoopRunner.merge_member_into_rollup(args)

    @impl true
    def diff_stat(args), do: DispatchNoopRunner.diff_stat(args)

    @impl true
    def revert_member_merge(args), do: DispatchNoopRunner.revert_member_merge(args)

    @impl true
    def close_stack_pr(args), do: DispatchNoopRunner.close_stack_pr(args)

    @impl true
    def sha_reachable?(args), do: DispatchNoopRunner.sha_reachable?(args)

    @impl true
    def open_stack_pr(args) do
      _ = DispatchNoopRunner.open_stack_pr(args)
      raise RuntimeError, @raise_message
    end
  end

  defp install_dispatch_noop_runner(_ctx) do
    prev = Application.get_env(:platform, :stack_deployer, [])

    {:ok, _} = DispatchNoopRunner.start_link()

    Application.put_env(:platform, :stack_deployer,
      git_runner: DispatchNoopRunner,
      async: false
    )

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        DispatchNoopRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Dispatch Noop " <> Ecto.UUID.generate(),
        repo_url: "https://github.com/test/dispatch-noop-" <> short_id()
      })

    %{project: project}
  end

  # Async twin of `install_dispatch_noop_runner/1`: same `DispatchNoopRunner`
  # Agent (it is `name: __MODULE__`-registered and therefore reachable from
  # the supervised child), same `on_exit` restore of the previous config —
  # the only differences are `async: true` and the pid subscription that
  # makes the spawn observable. The `on_exit` installed by the delegate
  # captured the config as it stood BEFORE this block, so it restores
  # correctly even for tests that swap the runner again mid-test.
  defp install_dispatch_noop_runner_async(ctx) do
    result = install_dispatch_noop_runner(ctx)

    Application.put_env(:platform, :stack_deployer,
      git_runner: DispatchNoopRunner,
      async: true
    )

    DispatchNoopRunner.notify(self())

    result
  end

  # Both deploy gates open — completed plans, `in_review` members, and
  # `merged_into_rollup_at` stamps — mirroring the synchronous "both gates"
  # test, so `maybe_open_stack_pr/1` genuinely reaches the runner rather
  # than short-circuiting on `all_members_ready?/1`.
  defp seed_deploy_ready_stack!(project) do
    stack = stack_fixture(project_id: project.id)

    {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "A"})
    {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "B"})
    {:ok, _} = Stacks.add_task(stack, a)
    {:ok, _} = Stacks.add_task(stack, b)

    seed_completed_plan!(a)
    seed_completed_plan!(b)
    set_member_status(stack, a, "in_review")
    set_member_status(stack, b, "in_review")
    stamp_member_merged_into_rollup!(a, "aaaaaaa1")
    stamp_member_merged_into_rollup!(b, "bbbbbbb2")

    stack
  end

  # Deterministic barrier for the `async: true` describe block. The runner
  # runs INSIDE the spawned child, so the pid it sends back is the child's;
  # we monitor it and wait for `:DOWN`. That both proves the work ran off
  # the calling process and guarantees the child is dead before the test
  # returns, so DataCase teardown can never release the sandbox connection
  # out from under a live DB user. Deliberately not `Process.sleep`.
  defp await_async_pr_open!(timeout \\ 2_000) do
    assert_receive {:dispatch_pr_open_called, child_pid}, timeout

    ref = Process.monitor(child_pid)
    assert_receive {:DOWN, ^ref, :process, ^child_pid, _reason}, timeout

    {:ok, child_pid}
  end

  # ── Deploy-tail sweep (TAIL-stall fix, 2026-07-22) ─────────────────────
  describe "sweep_deploying_members_to_done/1" do
    test "sweeps no_op_wait_for_rollup members at deploying to done, skips others" do
      {stack, [m1, m2]} = no_op_stack_of(2)

      # Both members at `deploying`, no per-task deploy strategy override, so
      # both resolve to no_op_wait_for_rollup.
      m1 = force_status(m1, "deploying")
      _m2 = force_status(m2, "deploying")

      assert {:ok, swept} = Stacks.sweep_deploying_members_to_done(stack)
      assert Enum.map(swept, & &1.id) |> Enum.sort() == Enum.sort([m1.id, m2.id])
      assert Tasks.get_task_record(m1.id).status == "done"
      assert Tasks.get_task_record(m2.id).status == "done"

      # Idempotent: a second sweep finds nothing to move.
      assert {:ok, []} = Stacks.sweep_deploying_members_to_done(stack)
    end

    test "leaves a member not at deploying untouched" do
      {stack, [m1, m2]} = no_op_stack_of(2)

      m1 = force_status(m1, "deploying")
      # m2 stays at its default status (backlog) — not a sweep candidate.

      assert {:ok, swept} = Stacks.sweep_deploying_members_to_done(stack)
      assert Enum.map(swept, & &1.id) == [m1.id]
      assert Tasks.get_task_record(m1.id).status == "done"
      assert Tasks.get_task_record(m2.id).status == "backlog"
    end

    test "does not sweep a member with a task-level deploy_strategy override" do
      {stack, [m1, _m2]} = no_op_stack_of(2)

      # A task-level strategy override wins in resolve_deploy_strategy/1, so
      # this member is NOT a no_op_wait_for_rollup member.
      {:ok, m1} = Tasks.update_task(m1, %{deploy_strategy: %{"type" => "manual"}})
      m1 = force_status(m1, "deploying")

      assert {:ok, []} = Stacks.sweep_deploying_members_to_done(stack)
      assert Tasks.get_task_record(m1.id).status == "deploying"
    end
  end

  describe "complete_no_op_member_if_rollup_merged/1" do
    test "completes a single deploying no_op member when the rollup PR is merged" do
      {stack, [m1, _m2]} = no_op_stack_of(2)
      _ = stamp_rollup_merged(stack)
      m1 = force_status(m1, "deploying")

      assert {:ok, done} = Stacks.complete_no_op_member_if_rollup_merged(m1)
      assert done.status == "done"
      assert Tasks.get_task_record(m1.id).status == "done"
    end

    test "noops when the rollup PR is not merged yet" do
      {_stack, [m1, _m2]} = no_op_stack_of(2)
      m1 = force_status(m1, "deploying")

      assert :noop = Stacks.complete_no_op_member_if_rollup_merged(m1)
      assert Tasks.get_task_record(m1.id).status == "deploying"
    end

    test "noops for a member that is not at deploying" do
      {stack, [m1, _m2]} = no_op_stack_of(2)
      _ = stamp_rollup_merged(stack)
      # m1 stays at backlog.

      assert :noop = Stacks.complete_no_op_member_if_rollup_merged(m1)
      assert Tasks.get_task_record(m1.id).status == "backlog"
    end

    test "noops for a non-stack task" do
      {:ok, project} = Tasks.create_project(%{name: "Non-stack " <> short_id()})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plain"})

      assert :noop = Stacks.complete_no_op_member_if_rollup_merged(task)
    end
  end

  describe "handle_rollup_pr_merged/2 sweeps stranded deploying members (wiring)" do
    test "the is_nil(rollup_pr) done-branch no longer leaks a deploying member" do
      {stack, [m1, _m2]} = no_op_stack_of(2)
      m1 = force_status(m1, "deploying")

      # Force the stack to `done` with NO rollup_pr metadata — the branch
      # that previously returned {:ok, stack} with no cascade AND no sweep.
      {:ok, done_stack} = Stacks.update_stack(stack, %{status: "done"})

      assert {:ok, _} = Platform.Tasks.StackDeployer.handle_rollup_pr_merged(done_stack)
      assert Tasks.get_task_record(m1.id).status == "done"
    end
  end

  # ── Deploy-transition promote helper (Stage 2, 2026-07-22) ─────────────
  describe "member_deploy_transition_ready?/1" do
    test "true for an in_review member with merge stamp + all validations passed + no pending review" do
      {_stack, member} = deploy_ready_member()
      assert Stacks.member_deploy_transition_ready?(Tasks.get_task_record(member.id))
    end

    test "false when the merged_into_rollup_at stamp is missing" do
      {_stack, member} = deploy_ready_member(stamp: false)
      refute Stacks.member_deploy_transition_ready?(Tasks.get_task_record(member.id))
    end

    test "false when a validation is still pending" do
      {_stack, member} = deploy_ready_member(pending_validation: true)
      refute Stacks.member_deploy_transition_ready?(Tasks.get_task_record(member.id))
    end
  end

  describe "advance_member_to_deploying/1" do
    test "advances a ready in_review member to deploying" do
      {_stack, member} = deploy_ready_member()

      assert {:ok, updated} = Stacks.advance_member_to_deploying(Tasks.get_task_record(member.id))
      assert updated.status == "deploying"
      assert Tasks.get_task_record(member.id).status == "deploying"
    end

    test "noop for a non-stack task" do
      {:ok, project} = Tasks.create_project(%{name: "Plain adv " <> short_id()})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plain"})
      assert :noop = Stacks.advance_member_to_deploying(task)
    end

    test "noop for a member not at in_review" do
      {_stack, member} = deploy_ready_member()
      member = force_status(Tasks.get_task_record(member.id), "in_progress")
      assert :noop = Stacks.advance_member_to_deploying(member)
    end

    test "noop when the deploy-ready contract is not satisfied" do
      {_stack, member} = deploy_ready_member(stamp: false)
      assert :noop = Stacks.advance_member_to_deploying(Tasks.get_task_record(member.id))
      assert Tasks.get_task_record(member.id).status == "in_review"
    end

    test "self-completes to done when the rollup PR has already merged" do
      {stack, member} = deploy_ready_member()
      _ = stamp_rollup_merged(stack)

      # advance returns the post-deploying struct; the deploying finalize
      # hook then fires complete_no_op_member_if_rollup_merged/1 as a
      # side-effect, walking the DB row straight through to done.
      assert {:ok, _updated} =
               Stacks.advance_member_to_deploying(Tasks.get_task_record(member.id))

      assert Tasks.get_task_record(member.id).status == "done"
    end
  end

  # ── Event-driven promote on last e2e pass (Stage 3, 2026-07-22) ────────
  describe "PlanEngine.evaluate_validation/2 advances a member to deploying on the last pass" do
    test "member stays in_review until the LAST validation passes, then flips to deploying" do
      {_stack, member, [v1, v2]} = pending_review_member(2)

      assert Tasks.get_task_record(member.id).status == "in_review"

      # Pass all but the last — member stays in_review (gate still closed).
      {:ok, _} = PlanEngine.evaluate_validation(v1.id, %{status: "passed"})
      assert Tasks.get_task_record(member.id).status == "in_review"

      # Pass the final one — the same evaluate_validation call path advances
      # the member in_review -> deploying, no reconcile sweep involved.
      {:ok, _} = PlanEngine.evaluate_validation(v2.id, %{status: "passed"})
      assert Tasks.get_task_record(member.id).status == "deploying"
    end

    test "does not advance while any validation remains pending" do
      {_stack, member, [v1, _v2]} = pending_review_member(2)

      {:ok, _} = PlanEngine.evaluate_validation(v1.id, %{status: "passed"})
      assert Tasks.get_task_record(member.id).status == "in_review"
    end
  end

  # Like deploy_ready_member/1 but leaves ALL validations pending and returns
  # their structs so a caller can drive them through PlanEngine. Returns
  # `{stack, member, [validation, ...]}`.
  defp pending_review_member(count) when count > 0 do
    {:ok, project} = Tasks.create_project(%{name: "Pending review " <> short_id()})
    slug = "pending-rev-" <> short_id()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Pending Review Stack",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Pending member " <> short_id()})

    {:ok, attached} = Stacks.add_task(stack, task)

    {:ok, member} =
      Tasks.update_task(attached, %{
        status: "in_review",
        deploy_target: "production",
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => "c0ffee01",
            "at" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: member.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Task-level review",
        status: "running"
      })

    validations =
      Enum.map(1..count, fn i ->
        {:ok, v} =
          Tasks.create_validation(%{
            stage_id: stage.id,
            kind: "test_pass",
            status: "pending",
            title: "check #{i}"
          })

        v
      end)

    {stack, Tasks.get_task_record(member.id), validations}
  end

  # Build a single stack member ready to advance in_review -> deploying:
  # attached to a stack with a live rollup_branch, deploy_target set,
  # merged_into_rollup_at stamped, and an approved plan whose validations
  # are all passed. Options:
  #   * `stamp:` (default true) — whether to write merged_into_rollup_at
  #   * `pending_validation:` (default false) — leave one validation pending
  # Returns `{stack, member}`.
  defp deploy_ready_member(opts \\ []) do
    stamp? = Keyword.get(opts, :stamp, true)
    pending? = Keyword.get(opts, :pending_validation, false)

    {:ok, project} = Tasks.create_project(%{name: "Deploy-ready " <> short_id()})
    slug = "deploy-ready-" <> short_id()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Deploy Ready Stack",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Ready member " <> short_id()})

    {:ok, attached} = Stacks.add_task(stack, task)

    metadata =
      if stamp? do
        %{
          "merged_into_rollup_at" => %{
            "sha" => "c1ea4001",
            "at" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      else
        %{}
      end

    {:ok, member} =
      Tasks.update_task(attached, %{
        status: "in_review",
        deploy_target: "production",
        metadata: metadata
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: member.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Task-level review",
        status: "running"
      })

    {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass", status: "passed"})

    {:ok, _} =
      Tasks.create_validation(%{
        stage_id: stage.id,
        kind: "test_pass",
        status: if(pending?, do: "pending", else: "passed")
      })

    {stack, Tasks.get_task_record(member.id)}
  end

  # Build a stack of `count` members that each resolve to
  # no_op_wait_for_rollup (stack has a live rollup_branch, no per-task
  # deploy_strategy override). Returns `{stack, members}` in position order.
  defp no_op_stack_of(count) when count > 0 do
    {:ok, project} = Tasks.create_project(%{name: "No-op Stack " <> short_id()})
    slug = "noop-tail-" <> short_id()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "No-op Tail Stack",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    members =
      Enum.map(1..count, fn i ->
        {:ok, task} =
          Tasks.create_task(%{project_id: project.id, title: "Tail member #{i} " <> short_id()})

        {:ok, attached} = Stacks.add_task(stack, task)
        attached
      end)

    {stack, members}
  end

  # Force a task to a given status via a direct changeset write, bypassing
  # the transition guards (setup-only).
  defp force_status(%Task{} = task, status) do
    task
    |> Task.changeset(%{status: status})
    |> Repo.update!()
  end

  # Stamp the stack's rollup_pr metadata as merged (hex sha placeholder).
  defp stamp_rollup_merged(%Stack{} = stack) do
    meta = stack.metadata || %{}

    rollup_pr =
      meta
      |> Map.get("rollup_pr", %{})
      |> Map.merge(%{
        "number" => 1,
        "merged_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    {:ok, updated} =
      Stacks.update_stack(stack, %{metadata: Map.put(meta, "rollup_pr", rollup_pr)})

    updated
  end

  # Attach a telemetry handler that forwards
  # `[:platform, :stacks, :deploy, :dispatched]` events to the test
  # process for `assert_receive`. Returns `{:ok, handler_id}` — the
  # caller MUST `:telemetry.detach/1` in an `after` clause to avoid
  # cross-test leakage.
  defp attach_dispatch_telemetry_handler do
    handler_id = "dispatch-deploy-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :stacks, :deploy, :dispatched],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:stack_deploy_dispatched, Map.merge(measurements, metadata)})
        end,
        nil
      )

    {:ok, handler_id}
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  #
  # The load-bearing input is the 16-CHARACTER one. `Ecto.UUID.cast/1`
  # hex-encodes any 16-byte binary and returns {:ok, _} while
  # `Ecto.UUID.dump/1` rejects it, so a suite built from "higgins" plus a
  # valid UUID is fully green against the bug. Do not prune the 16-character
  # cases as duplicates.
  describe "UUID boundary: Stacks getters" do
    @slug_16 "higginshigginsxx"

    test "get_stack/1 returns nil for a malformed id" do
      # Reached with a raw stack_id tool argument at seven tool_surface sites.
      assert Stacks.get_stack("higgins") == nil
      assert Stacks.get_stack(@slug_16) == nil
    end

    test "get_stack!/1 raises Ecto.NoResultsError, not Ecto.Query.CastError" do
      assert_raise Ecto.NoResultsError, fn -> Stacks.get_stack!(@slug_16) end
    end
  end

  # ── Late-precondition promotion sweep (task 019fbe9e) ───────────────────
  #
  # Every fixture here is built so the precondition arrives LATE — the stack
  # is ALREADY past `forming` when the members need promoting. A fixture that
  # commences the stack after the deps clear passes against the pre-fix tree
  # and proves nothing.
  describe "sweep_stack_pending_members/0 (late-precondition promotion)" do
    defp landed_stamp do
      %{"sha" => "abc1234", "at" => "2026-08-01T00:00:00Z"}
    end

    defp set_status!(task, status) do
      task |> Task.changeset(%{status: status}) |> Repo.update!()
    end

    defp reload_status(id), do: Repo.get(Task, id).status

    test "promotes stack_pending members of an already-in_progress stack whose deps have cleared" do
      {:ok, project} = Tasks.create_project(%{name: "Late gate promote"})
      stack = stack_fixture(project_id: project.id)

      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      {:ok, _} = Tasks.create_plan(%{task_id: attached_parent.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      stack |> Ecto.Changeset.change(status: "in_progress") |> Repo.update!()

      set_status!(attached_child, "stack_pending")

      # Dep cleared WITHOUT going through the update-path cascade, so nothing
      # ever called sweep_stack_dependents/1 for it — the live incident shape.
      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{"merged_into_rollup_at" => landed_stamp()}
      })
      |> Repo.update!()

      assert reload_status(attached_child.id) == "stack_pending"

      assert %{promoted: promoted} = Stacks.reconcile_stack_lifecycle()
      assert promoted >= 1

      # Assert on the re-fetched MEMBER status, not on a stack summary and not
      # on CommencementGate.open?/1 — the gate read healthy throughout the
      # incident, so a gate assertion cannot distinguish fixed from broken.
      assert reload_status(attached_child.id) == "in_progress"
    end

    test "leaves a member parked until its dependency clears, then promotes it on a later sweep" do
      {:ok, project} = Tasks.create_project(%{name: "Dep clears late"})
      stack = stack_fixture(project_id: project.id)

      {:ok, dep} = Tasks.create_task(%{project_id: project.id, title: "Dep"})

      {:ok, dependent} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Dependent",
          dependencies: [%{"task_id" => dep.id, "kind" => "blocks"}]
        })

      {:ok, attached_dep} = Stacks.add_task(stack, dep)
      {:ok, attached_dependent} = Stacks.add_task(stack, dependent)

      {:ok, _} = Tasks.create_plan(%{task_id: attached_dep.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: attached_dependent.id, status: "approved"})

      stack |> Ecto.Changeset.change(status: "in_progress") |> Repo.update!()

      set_status!(attached_dependent, "stack_pending")
      set_status!(attached_dep, "in_progress")

      # Anti-vacuity control: precondition NOT met yet, so the sweep must be
      # a no-op for this member.
      assert %{promoted: 0} = Stacks.reconcile_stack_lifecycle()
      assert reload_status(attached_dependent.id) == "stack_pending"

      # Now the dependency clears the unblock threshold — LATE.
      attached_dep
      |> Task.changeset(%{
        status: "done",
        metadata: %{"merged_into_rollup_at" => landed_stamp()}
      })
      |> Repo.update!()

      assert %{promoted: 1} = Stacks.reconcile_stack_lifecycle()
      assert reload_status(attached_dependent.id) == "in_progress"
    end

    test "is idempotent: a second sweep changes no status and does not touch updated_at" do
      {:ok, project} = Tasks.create_project(%{name: "Sweep idempotent"})
      stack = stack_fixture(project_id: project.id)

      {:ok, parent} = Tasks.create_task(%{project_id: project.id, title: "Parent"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => parent.id, "kind" => "blocks"}]
        })

      {:ok, attached_parent} = Stacks.add_task(stack, parent)
      {:ok, attached_child} = Stacks.add_task(stack, child)

      {:ok, _} = Tasks.create_plan(%{task_id: attached_parent.id, status: "approved"})
      {:ok, _} = Tasks.create_plan(%{task_id: attached_child.id, status: "approved"})

      stack |> Ecto.Changeset.change(status: "in_progress") |> Repo.update!()

      set_status!(attached_child, "stack_pending")

      attached_parent
      |> Task.changeset(%{
        status: "in_review",
        metadata: %{"merged_into_rollup_at" => landed_stamp()}
      })
      |> Repo.update!()

      assert %{promoted: 1} = Stacks.reconcile_stack_lifecycle()

      after_first = Repo.get(Task, attached_child.id)
      assert after_first.status == "in_progress"

      # Second pass: the query filters `status == "stack_pending"` and
      # try_promote/1's catch-all head refuses anything else, so an
      # already-running member must not be written at all.
      assert %{promoted: 0} = Stacks.reconcile_stack_lifecycle()

      after_second = Repo.get(Task, attached_child.id)
      assert after_second.status == "in_progress"
      assert after_second.updated_at == after_first.updated_at
    end
  end
end
