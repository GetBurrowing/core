defmodule Platform.Federation.ReviewReadToolsTest do
  @moduledoc """
  Tests for the review read-back MCP surface — `review_request_get` and
  `review_item_list`.

  Both live in the existing `review` bundle: anything that can file evidence
  can read the verdict on it. Authorization mirrors `authorize_file_access/2`
  exactly (task → project → `project.org_id` → `authorize_org_filter/2`), and
  runs BEFORE serialization — a review item can carry a human's private
  assessment, so a denied caller must never see a label, a feedback string, or
  item content. The sibling-org tests assert that absence directly.

  ## Mutations these tests are known to catch (task `01a00570` stage 3)

  Every entry below was OBSERVED failing against the stated break, then
  reverted. A test here that stops catching its mutation is no longer a check.

    * **Status-filtering the read path** — a `status != "needs_revision"` filter
      in `list_items_for_task/1` fails "returns every item on the task with its
      ruling and parent status" (`result.count` 1 → 0), plus the root-pinned and
      agentless variants. This module is the ONLY place that catches it: the
      context-level `ReviewRequestsReadTest` stays green, because its fixtures
      approve rather than reject. That is why the fixture here rejects its item
      and the test asserts the exact feedback string
      ("FAB overlaps the bottom nav at 375px") rather than the row's shape.

    * **`list_items_for_task/1` returning `[]`** — fails the same three
      `count == 1` assertions. An emptied read path must not read as success.

    * **Dropping `authorize_review_access/2` from the `review_request_get`
      handler** — fails "sibling-org agent is denied on review_request_get and
      sees no evidence"; the call returns `{:ok, ...}` where `{:error, _}` is
      required. Denial is proven by a DENIED CALL, not by reading the policy.

    * **Authorizing AFTER serializing** (merging the serialized request into the
      denial envelope) — passes the `{:error, _}` and `recoverable == false`
      assertions and is caught only by `assert_no_evidence_leak/1`, on
      `refute blob =~ "Mobile nav"`. Observed leaking the label, the feedback
      string, the content and the canvas_id into the denial body. The refutes
      scan the WHOLE envelope for this reason — narrowing them to the `error`
      string would make the check pass while the leak persists.

    * **Removing both names from `review_tools/0`** — fails "both read tools are
      registered under the review bundle", "both descriptions carry the
      item-over-validation precedence rule", and the `ToolAuthorization`
      bundle-holder test (`{:error, :forbidden}`). It also fails three
      baseline-inventory guards outside this module, by design:
      `ToolSurfaceTest` (94 tools), the T6 scope-creep guard in
      `SystemEventSchedulerT6E2ETest` (94), and `ToolArgumentsTest`'s
      `@surveyed_required_count` (131). Those counts are the intended tripwire,
      not collateral — bump them only alongside a real tool-surface change.

  ## Reproduced against the real incident (task `01a00570` stage 5)

  These unit tests are backed by a live end-to-end reproduction, run against a
  dev server booted from this worktree with a DB seeded to the production row
  shape of the agent-avatars incident (task `01a00122-553c-78c0-bcc5-fd8c359069c7`):
  `review_items.status = needs_revision`, `review_requests.status = resolved`,
  and — the point of the exercise — `validations.status = pending`. The
  contradiction is present in the data under test on purpose. A fixture where
  the two surfaces agree cannot exercise the precedence rule, which is the only
  reason these tools exist.

  Four legs were run and OBSERVED, all against feedback whose sha256 matched
  the production string byte for byte
  (`2814b1f56262ae616efad4a2d68e05e3bf1cedff4dc2df3432b81a9ccf83a379`):

    * **Discovery from `task_id` alone** — an agent that did not create the
      request, holding no request id, called `review_item_list(task_id)` over
      `/mcp` and got `count: 1`, `status: "needs_revision"`, the exact feedback,
      `reviewed_by`, `reviewed_at`, and `request_status: "resolved"`. Feeding the
      returned `review_request_id` back into `review_request_get` returned the
      identical item. Neither returned `pending` for the item; neither returned
      an empty list. Those two outcomes are the bug this ticket removes.

    * **Through the openclaw channel plugin** — all four registered names
      (`suite_review_item_list`, `review_item_list`, `suite_review_request_get`,
      `review_request_get`) were invoked through the BUILT plugin's own
      `execute` path and its WebSocket `tool_call` frame, NOT through `/mcp`,
      and NOT by reading the registration. All four returned the seeded ruling.
      The harness's ability to detect the half-registered failure was proven by
      a negative control: the same path with a deliberately mistyped name
      returned `tool 'review_item_list_TYPO' not in allowed bundles`. That is
      the exact error a missing registration produces, and the four real names
      did not produce it.

    * **Sibling-org denial** — a tenant-pinned agent whose home org differs from
      the task's project org was refused on BOTH tools with `recoverable: false`.
      The denial bodies were scanned for the label, the feedback, the content,
      the `canvas_id`, `reviewed_by` and the status string; all absent. The scan
      was positive-controlled against a successful response to prove it fires.

    * **Read-only** — after every call above, the request, item and validation
      rows were byte-identical to their seeded values, contradiction intact.

  Out of scope, filed for its own ticket: `plan_get` resolves approved plans
  only, so plan-REJECTION notes have exactly the same no-read-path problem this
  ticket fixes for review feedback — a rejected plan's feedback is written
  somewhere no agent can read it back.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Federation.{ToolAuthorization, ToolSurface}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewRequests}
  alias Platform.Tenancy

  @read_tools ~w(review_request_get review_item_list)

  setup do
    acme = ensure_root_org()
    sxi = ensure_tenant_org("sxi-review-#{u()}", acme)
    wayne_tech = ensure_tenant_org("wayne-tech-review-#{u()}", acme)

    {:ok, project} = Tasks.create_project(%{name: "Review Proj #{u()}", org_id: sxi.id})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Review Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI Stage"})
    {:ok, _} = PlanEngine.start_stage(stage.id)
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    {:ok, request} =
      ReviewRequests.create_review_request(%{
        validation_id: validation.id,
        task_id: task.id,
        submitted_by: "test-agent",
        items: [
          %{label: "Mobile nav", canvas_id: "canvas-123", content: "Mobile screenshot"}
        ]
      })

    [item] = request.items

    {:ok, ruled} =
      ReviewRequests.reject_item(item.id, "alex", "FAB overlaps the bottom nav at 375px")

    %{
      acme: acme,
      sxi: sxi,
      wayne_tech: wayne_tech,
      task: task,
      validation: validation,
      request: request,
      item: ruled,
      agent_sxi: create_agent("sxi-agent", %{"org_id" => sxi.id}),
      agent_pt: create_agent("pt-agent", %{"org_id" => wayne_tech.id}),
      agent_root: create_agent("root-agent", %{"org_id" => acme.id})
    }
  end

  # ── Bundle registration ─────────────────────────────────────────────────

  describe "bundle registration" do
    test "both read tools are registered under the review bundle" do
      names = ToolSurface.list_tools(["review"]) |> MapSet.new(& &1.name)

      for tool <- @read_tools, do: assert(tool in names)
    end

    test "neither tool appears in any other bundle" do
      others = ~w(canvas messaging task plan space context_read federation memory
                  skill attachment files)

      for bundle <- others do
        names = ToolSurface.list_tools([bundle]) |> MapSet.new(& &1.name)

        for tool <- @read_tools do
          refute tool in names, "#{tool} leaked into the #{bundle} bundle"
        end
      end
    end

    test "both descriptions carry the item-over-validation precedence rule" do
      tools = ToolSurface.list_tools(["review"])

      for name <- @read_tools do
        tool = Enum.find(tools, &(&1.name == name))
        assert tool.description =~ "PRECEDENCE RULE"
        assert tool.description =~ "review_items"
        assert tool.description =~ "gate"
      end
    end
  end

  # ── ToolAuthorization ───────────────────────────────────────────────────

  describe "ToolAuthorization.authorize/2" do
    test "a runtime holding the review bundle may call both tools" do
      runtime = Platform.RuntimeProfileFixtures.runtime!(root_admin!().id, ["review"])

      for tool <- @read_tools, do: assert(ToolAuthorization.authorize(tool, runtime) == :ok)
    end

    test "a runtime without the review bundle is forbidden on both tools" do
      runtime = Platform.RuntimeProfileFixtures.runtime!(root_admin!().id, ["task", "plan"])

      for tool <- @read_tools do
        assert ToolAuthorization.authorize(tool, runtime) == {:error, :forbidden}
      end
    end
  end

  # ── Happy path ──────────────────────────────────────────────────────────

  describe "review_request_get/execute" do
    test "returns the request with the human's status and feedback", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "review_request_get",
                 %{"review_request_id" => ctx.request.id},
                 context_for(ctx.agent_sxi)
               )

      assert result.id == ctx.request.id
      assert result.task_id == ctx.task.id
      assert [item] = result.items
      assert item.label == "Mobile nav"
      assert item.status == "needs_revision"
      assert item.feedback == "FAB overlaps the bottom nav at 375px"
      assert item.reviewed_by == "alex"
      assert item.reviewed_at
      assert item.canvas_id == "canvas-123"
      assert item.content == "Mobile screenshot"
    end

    test "unknown id returns a non-recoverable envelope rather than raising", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "review_request_get",
                 %{"review_request_id" => Ecto.UUID.generate()},
                 context_for(ctx.agent_sxi)
               )

      assert envelope.recoverable == false
      assert envelope.error =~ "not found"
    end

    test "malformed id returns a non-recoverable envelope rather than raising", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "review_request_get",
                 %{"review_request_id" => "not-a-uuid"},
                 context_for(ctx.agent_sxi)
               )

      assert envelope.recoverable == false
    end
  end

  describe "review_item_list/execute" do
    test "returns every item on the task with its ruling and parent status", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "review_item_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_sxi)
               )

      assert result.task_id == ctx.task.id
      assert result.count == 1
      assert [item] = result.items
      assert item.status == "needs_revision"
      assert item.feedback == "FAB overlaps the bottom nav at 375px"
      assert item.review_request_id == ctx.request.id
      assert item.validation_id == ctx.validation.id
      assert item.request_status
    end

    test "root-pinned agent reads a tenant task", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "review_item_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_root)
               )

      assert result.count == 1
    end

    test "unknown task id is denied rather than raising", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "review_item_list",
                 %{"task_id" => Ecto.UUID.generate()},
                 context_for(ctx.agent_sxi)
               )

      assert envelope.recoverable == false
    end

    test "agentless context permits — bare-call convention", ctx do
      assert {:ok, result} =
               ToolSurface.execute("review_item_list", %{"task_id" => ctx.task.id}, %{})

      assert result.count == 1
    end

    # `authorize_review_access/2` keeps the nil-org_id permit branch to mirror
    # `authorize_file_access/2` verbatim, but that branch is unreachable
    # through the DB today: `projects.org_id` carries a NOT NULL constraint and
    # `create_project/1` backfills the root org. Assert the constraint so the
    # branch's dead-ness is a recorded fact rather than an untested guess — if
    # the column is ever made nullable again this test fails and the branch
    # needs real coverage.
    test "projects.org_id is NOT NULL, so the pre-ADR-0042 permit branch is unreachable" do
      {:ok, legacy_project} = Tasks.create_project(%{name: "Legacy #{u()}"})

      assert legacy_project.org_id != nil

      assert_raise Postgrex.Error, fn ->
        Repo.update_all(
          from(p in Platform.Tasks.Project, where: p.id == ^legacy_project.id),
          set: [org_id: nil]
        )
      end
    end
  end

  # ── Sibling-org isolation (the security-relevant case) ──────────────────

  describe "tenant isolation" do
    test "sibling-org agent is denied on review_request_get and sees no evidence", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "review_request_get",
                 %{"review_request_id" => ctx.request.id},
                 context_for(ctx.agent_pt)
               )

      assert envelope.recoverable == false
      assert envelope.error =~ "unauthorized"
      assert_no_evidence_leak(envelope)
    end

    test "sibling-org agent is denied on review_item_list and sees no evidence", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "review_item_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_pt)
               )

      assert envelope.recoverable == false
      assert envelope.error =~ "unauthorized"
      assert_no_evidence_leak(envelope)
    end
  end

  # The denial must not leak the thing it is protecting. Assert the absence of
  # the label, the feedback and the content anywhere in the envelope, not just
  # in the `error` string.
  defp assert_no_evidence_leak(envelope) do
    blob = inspect(envelope)

    refute blob =~ "Mobile nav"
    refute blob =~ "FAB overlaps the bottom nav"
    refute blob =~ "Mobile screenshot"
    refute blob =~ "canvas-123"
    refute Map.has_key?(envelope, :items)
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp ensure_root_org do
    case Repo.get_by(Tenancy.Org, slug: "acme") do
      nil ->
        {:ok, org} =
          %Tenancy.Org{}
          |> Tenancy.Org.changeset(%{slug: "acme", name: "Acme", parent_org_id: nil})
          |> Repo.insert()

        org

      org ->
        org
    end
  end

  defp ensure_tenant_org(slug, root) do
    {:ok, org} =
      %Tenancy.Org{}
      |> Tenancy.Org.changeset(%{slug: slug, name: slug, parent_org_id: root.id})
      |> Repo.insert()

    org
  end

  defp create_agent(slug_prefix, metadata) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "#{slug_prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: String.capitalize(slug_prefix),
        status: "active",
        metadata: metadata
      })
      |> Repo.insert()

    agent
  end

  defp context_for(%Agent{id: id}), do: %{agent_id: id}
end
