defmodule Platform.Orchestration.InReviewDispatchToolPairingTest do
  @moduledoc """
  Pairs the tool names the `dispatch.in_review` template SAYS with the tool
  names a runtime the dispatcher can address for that dispatch actually SEES
  (task 019fed8d stage 1).

  ## The defect this exists to prevent

  `20260809220000_force_update_in_review_template_design_critique_tool.exs`
  pointed the design-review paragraph at a real, fully-implemented tool and
  then named it in the bare surface form, `design_critique_request`, inside a
  body where every other tool is written `suite_review_request_create`,
  `suite_task_get`, `suite_plan_get`, `suite_validation_list`. A federated
  client namespaces the Suite surface under `suite_`, so a runtime looking up
  the bare token finds nothing and reports the tool absent. Three runtimes
  reported exactly that. The tool was never missing; the instruction was
  unaddressable.

  ## Why both sides are derived, never typed

  A test that asserts "`design_critique_request` is a registered tool" passes
  against the defect — the tool WAS registered. A test carrying a literal list
  of tool names, or a literal list of runtime slugs, passes while the real
  pairing drifts underneath it. So:

    * the template side is extracted by regex from the RENDERED body that
      `PromptTemplates.render_template/2` produces (the same call the
      dispatcher makes), never from a copy of the string in this file;
    * the catalogue side comes from `ToolSurface.list_tools/1` over
      `ToolSurface.all_bundles/0`;
    * the runtime side comes from `PhaseRuntime.resolve/1` — the dispatcher's
      own resolution function — driven by a task in `status: "in_review"` with
      a pending `manual_approval` validation, which is the exact state
      `TaskRouter.runtime_phase_for_task/1` maps to the `"review"` phase;
    * the runtime's visible surface comes from
      `ToolAuthorization.tool_names/1`, the same projection the WebSocket
      `tools/list` handler maps over.

  ## What each assertion can and cannot see

  `naming convention` is the assertion that detonates on the shipped defect.
  It says: any backticked token in the rendered body that names a registered
  tool (with or without the `suite_` prefix) must carry the prefix. Reverting
  the paragraph to the bare `design_critique_request` reddens it by name.

  `resolvability` says every prefixed tool the body names resolves inside the
  addressed runtime's surface. The fixture runtime is granted the full bundle
  set on purpose, and this is a real limit worth stating rather than hiding:
  no test-database runtime can stand in for production's `allowed_bundles`
  rows, so this assertion detects a template naming a tool that NO bundle
  carries (a typo, or a tool deleted out from under the instruction) but
  cannot detect a production grant gap. The grant question was answered
  against production data and recorded in the PR body; every runtime the
  dispatcher can address for a review-phase dispatch already carries the
  `review` bundle, so no `allowed_bundles` migration ships with this stage.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.PhaseRuntime
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @slug "dispatch.in_review"

  # Backticked lowercase snake_case tokens. Tool names in these templates are
  # always written inside backticks; parameter names and file tokens share the
  # shape, which is why membership in the catalogue — not the shape — decides
  # whether a token is a tool reference.
  @token_regex ~r/`([a-z][a-z0-9_]{2,})`/

  setup do
    :ok = PromptTemplates.seed_defaults()
    {:ok, body} = PromptTemplates.render_template(@slug, %{})

    catalogue =
      ToolSurface.all_bundles()
      |> ToolSurface.list_tools()
      |> MapSet.new(& &1.name)

    refute MapSet.size(catalogue) == 0

    %{body: body, catalogue: catalogue}
  end

  describe "naming convention" do
    test "every tool the rendered body names is written in the federated form",
         %{body: body, catalogue: catalogue} do
      bare =
        body
        |> tokens()
        |> Enum.filter(&MapSet.member?(catalogue, &1))

      assert bare == [],
             "the #{@slug} template names #{length(bare)} tool(s) in the BARE surface form " <>
               "while the rest of the same body uses the `suite_` prefix a federated client " <>
               "applies: #{inspect(bare)}. A runtime looking those up finds nothing and " <>
               "reports the tool absent."
    end

    test "the body does name at least one tool, so the assertion above is not vacuous",
         %{body: body, catalogue: catalogue} do
      prefixed = prefixed_tools(body, catalogue)

      assert length(prefixed) >= 4,
             "expected the in_review body to name several federated tools; got #{inspect(prefixed)}"
    end
  end

  describe "resolvability" do
    test "every tool the body names resolves inside the addressed runtime's surface",
         %{body: body, catalogue: catalogue} do
      {:ok, %{type: :federated, id: runtime_id}} = PhaseRuntime.resolve(in_review_task())

      runtime = Federation.get_runtime_by_runtime_id(runtime_id)
      visible = MapSet.new(ToolAuthorization.tool_names(runtime))

      named = prefixed_tools(body, catalogue)
      refute named == []

      missing = Enum.reject(named, &MapSet.member?(visible, &1))

      assert missing == [],
             "the #{@slug} template tells the reviewer to call #{inspect(missing)}, which no " <>
               "bundle on the addressed runtime carries. Either the template names a tool that " <>
               "does not exist, or the tool left the surface while the instruction stayed."
    end
  end

  # ── Extraction ──────────────────────────────────────────────────────────

  defp tokens(body) do
    @token_regex
    |> Regex.scan(body)
    |> Enum.map(fn [_, token] -> token end)
    |> Enum.uniq()
  end

  # Tokens written `suite_<name>` whose `<name>` is a registered tool, mapped
  # back to the surface name the authorization layer speaks.
  defp prefixed_tools(body, catalogue) do
    body
    |> tokens()
    |> Enum.flat_map(fn
      "suite_" <> name -> [name]
      _ -> []
    end)
    |> Enum.filter(&MapSet.member?(catalogue, &1))
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  # A task in the exact state the dispatcher reads when it sends the
  # in_review dispatch: `status: "in_review"` with a pending
  # `manual_approval` validation and a review-phase agent assignee.
  defp in_review_task do
    {:ok, project} =
      Tasks.create_project(%{
        name: "InReview Pairing #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/in-review-pairing"
      })

    agent = linked_agent_runtime()

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "InReview Pairing Task #{System.unique_integer([:positive])}",
        description: "Sits at a manual_approval gate"
      })

    task
    |> Ecto.Changeset.change(%{
      status: "in_review",
      assignee_id: agent.id,
      assignee_type: "agent",
      phase_assignees: %{
        "review" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
      }
    })
    |> Repo.update!()
    |> then(fn %TaskSchema{} = t -> t end)
  end

  defp linked_agent_runtime do
    suffix = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "in_review_pairing_#{suffix}@example.com",
        name: "In Review Pairing User",
        oidc_sub: "oidc-in-review-pairing-#{suffix}"
      })

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "in-review-pairing-#{suffix}",
        name: "In Review Pairing Agent",
        status: "active"
      })
      |> Repo.insert()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{runtime_id: "in-review-pairing-rt-#{suffix}"})

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    # Intersected with the schema's own `valid_bundles/0`: `ToolSurface`
    # currently registers a `files` bundle that `AgentRuntime`'s
    # `validate_subset` rejects, so the raw `all_bundles/0` list cannot be
    # persisted. Both sides stay derived — no bundle name is typed here.
    grant =
      Enum.filter(ToolSurface.all_bundles(), &(&1 in Platform.Access.RuntimeProfiles.valid_modules()))

    {:ok, _profile} = Platform.Access.RuntimeProfiles.set_tool_profile(activated, grant)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    agent
  end
end
