defmodule Platform.Orchestration.DispatchFallbackParityTest do
  @moduledoc """
  Relationship test between the DB-served dispatch templates and the hardcoded
  fallbacks in `HeartbeatScheduler` (task 019ff10f).

  ## Why a relationship and not a list of expected tool names

  The defect this file exists to prevent is drift: somebody adds a paragraph to
  a `dispatch.*` template row telling the agent to call a tool, and the
  hardcoded fallback — which is what actually renders when the row is missing
  or the DB is unreachable — never learns about it. An agent taking the
  fallback then works from a prompt that is silently a capability behind.

  A test that asserted `body =~ "design_critique_request"` would close today's
  instance and pass forever afterwards, including for the next tool added to
  the next template. So this file asserts a RELATION instead: for every phase
  that has both a rendered template and a fallback, the set of tool names the
  fallback mentions must be a SUPERSET of the set the template mentions. No
  tool name is written down here, and the phase list is derived rather than
  enumerated, so a phase added later is covered without editing this file.

  ## Why the template side comes from `render_template/2`

  Deliberately not `default_content_for_slug/1`. Rows are written by
  migrations, and a row can diverge from the source descriptor it was seeded
  from (a later migration can rewrite content the descriptor never learned
  about). The body that matters is the one an agent is actually served, which
  is the row — so this reads the row, through the same function every dispatch
  caller funnels through.

  ## Why the fallback direction only

  The fallback is allowed to say MORE than the template: it carries defaults
  for the degraded case (e.g. a readable sentinel for an unset subagent id) and
  anchor headings other code splices against. Equality would forbid that. The
  hazard is one-directional — the template gaining a tool the fallback lacks.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates

  # Slugs that are dispatch-adjacent but deliberately out of the relation.
  #
  # `nudge` is a short-form poke by design (ADR-0025 amendment): its template is
  # intentionally terse while its hardcoded fallback carries more operational
  # detail, so the fallback naming MORE tools than the template is the intended
  # shape, not drift — and the reverse direction is not a hazard for a body that
  # is not a full dispatch. `heartbeat` is the same shape for the same reason.
  # Both are excluded rather than special-cased so their exclusion is visible.
  @excluded_slugs ~w(nudge heartbeat)

  # Slugs under `dispatch.*` that are rendered by other dispatchers and have NO
  # hardcoded fallback in `HeartbeatScheduler` — there is no second body to
  # compare against, so there is nothing to drift. Listed so that a NEWLY added
  # `dispatch.*` slug that is in neither this list nor `drivers/0` fails the
  # coverage test below instead of being silently skipped.
  @no_fallback_slugs ~w(
    dispatch.scribe_completion
    dispatch.triage_dispatch
    dispatch.intent_attention
  )

  setup do
    # Idempotent: fills any slug the migrations did not seed in this database
    # and leaves migrated rows exactly as they are, so the comparison still
    # reads the row an agent would be served.
    :ok = PromptTemplates.seed_defaults()
    :ok
  end

  # Each driver produces the `{task, plan, stage}` triple that makes
  # `dispatch_prompt/3` route to that phase (see `DispatchPhase.resolve/3`:
  # stage contract first, `task.status` last).
  defp drivers do
    task = fn status ->
      %{
        id: "00000000-0000-0000-0000-0000000000aa",
        title: "Parity fixture task",
        description: "Parity fixture description",
        status: status,
        priority: "high"
      }
    end

    plan = %{id: "00000000-0000-0000-0000-0000000000bb", version: 1, stages: []}

    stage = fn name, kind ->
      %{
        id: "00000000-0000-0000-0000-0000000000cc",
        name: name,
        description: "Parity fixture stage description",
        position: 1,
        status: "running",
        validations: [%{id: "val-1", kind: kind, status: "pending"}]
      }
    end

    %{
      "dispatch.planning" => {task.("planning"), nil, nil},
      "dispatch.in_progress" => {task.("in_progress"), plan, stage.("Implement", "test_pass")},
      "dispatch.in_review" => {task.("in_review"), plan, stage.("Review", "manual_approval")},
      "dispatch.review_e2e" => {task.("in_review"), plan, stage.("Review", "e2e_behavior")},
      "dispatch.deploying" => {task.("deploying"), plan, stage.("Deploy: pr_merge", "pr_merged")},
      "dispatch.fallback" => {task.("todo"), nil, nil}
    }
  end

  defp candidate_slugs do
    PromptTemplates.default_templates()
    |> Enum.map(& &1.slug)
    |> Enum.filter(&String.starts_with?(&1, "dispatch."))
    |> Enum.reject(&(&1 in @excluded_slugs))
    |> Enum.sort()
  end

  # A tool mention as these bodies write one: a backticked snake_case
  # identifier, optionally followed by a call's open paren.
  @tool_regex ~r/`([a-z][a-z0-9]*(?:[._][a-z0-9]+)+)\(?/

  # The vocabulary is DERIVED from the live tool registry rather than written
  # down here. Shape alone is not enough: `failure_feedback` and
  # `evaluation_payload` are backticked snake_case too, and a template naming a
  # payload FIELD the fallback happens not to name is not the drift this test
  # is about. Intersecting with the registry keeps the discriminator honest —
  # a tool added tomorrow enters the vocabulary with no edit here, and a field
  # renamed tomorrow never does.
  defp known_tool_names do
    Platform.Federation.ToolSurface.tool_definitions()
    |> Enum.map(& &1.name)
    |> Enum.map(&normalize_tool_name/1)
    |> MapSet.new()
  end

  # The registry spells some tools with a dot (`canvas_describe`) while the MCP
  # client surface — and therefore every prompt body — spells them with an
  # underscore, and agent-facing prompts prefix some with `suite_`. Normalize
  # both sides through here so the same tool compares equal whichever
  # convention the body used.
  defp normalize_tool_name(name) do
    name
    |> String.replace(".", "_")
    |> String.replace_prefix("suite_", "")
  end

  defp tool_names(body) do
    vocabulary = known_tool_names()

    @tool_regex
    |> Regex.scan(body)
    |> Enum.map(fn [_full, name] -> normalize_tool_name(name) end)
    |> Enum.filter(&MapSet.member?(vocabulary, &1))
    |> MapSet.new()
  end

  defp rendered_template!(slug) do
    {:ok, body} = PromptTemplates.render_template(slug, %{})
    body
  end

  defp fallback_body!(slug) do
    {task, plan, stage} = Map.fetch!(drivers(), slug)

    # Force the fallback the way production takes it: no row for the slug. The
    # sandbox rolls this back, and `seed_defaults/0` in setup re-seeds anyway.
    Platform.Repo.delete_all(from(t in PromptTemplate, where: t.slug == ^slug))

    HeartbeatScheduler.dispatch_prompt(task, plan, stage)
  end

  # The comparison itself, shared by the parity assertion and the detonation
  # test below so both exercise the SAME code path — including the DB read.
  defp missing_tools(slug) do
    template_tools = slug |> rendered_template!() |> tool_names()
    fallback_tools = slug |> fallback_body!() |> tool_names()

    MapSet.difference(template_tools, fallback_tools)
  end

  describe "dispatch fallback / template tool parity" do
    test "every dispatch.* slug is classified as having a fallback or not" do
      classified = Map.keys(drivers()) ++ @no_fallback_slugs

      unclassified = candidate_slugs() -- classified

      assert unclassified == [],
             """
             New dispatch template slug(s) with no parity classification: #{inspect(unclassified)}

             Add each to `drivers/0` (if `HeartbeatScheduler` has a hardcoded fallback
             for it, giving the task/plan/stage triple that routes there) or to
             @no_fallback_slugs (if it is rendered elsewhere with no second body).
             Leaving it unclassified would let its fallback drift unobserved.
             """
    end

    test "the tool-name extraction is not vacuous" do
      # A superset assertion over two empty sets passes for the wrong reason, so
      # prove the extractor actually finds names. Asserted on the FALLBACK side
      # per phase (every fallback is a long body that names tools) and on the
      # aggregate template side — an individual template legitimately names no
      # tool: `dispatch.fallback` is a generic "you have an assignment" body.
      aggregate_template_tools =
        candidate_slugs()
        |> Enum.filter(&Map.has_key?(drivers(), &1))
        |> Enum.reduce(MapSet.new(), fn slug, acc ->
          MapSet.union(acc, slug |> rendered_template!() |> tool_names())
        end)

      assert MapSet.size(aggregate_template_tools) > 1,
             "extracted #{MapSet.size(aggregate_template_tools)} tool names across all " <>
               "served dispatch templates — the extraction regex is broken, which would " <>
               "make the parity assertion pass vacuously."

      for slug <- candidate_slugs(), Map.has_key?(drivers(), slug) do
        assert MapSet.size(slug |> fallback_body!() |> tool_names()) > 0,
               "#{slug}: extracted no tool names from the hardcoded fallback."
      end
    end

    test "each fallback names a superset of the tools its served template names" do
      # Every phase is compared before asserting, so a failure reports EVERY
      # drifted phase at once. Asserting inside the loop aborts on the first
      # one and hides the rest, which is how a second instance survives a fix
      # aimed at the first.
      drift =
        candidate_slugs()
        |> Enum.filter(&Map.has_key?(drivers(), &1))
        |> Enum.map(fn slug -> {slug, MapSet.to_list(missing_tools(slug))} end)
        |> Enum.reject(fn {_slug, missing} -> missing == [] end)
        |> Map.new()

      assert drift == %{},
             """
             The served template names tool(s) the hardcoded fallback does not:

             #{inspect(drift, pretty: true)}

             The fallback is what renders when the template row is missing or the DB is
             unreachable. An agent on that path would never be told about these tools.
             Add the guidance to the fallback body in
             apps/platform/lib/platform/orchestration/heartbeat_scheduler.ex — do not
             relax this assertion.
             """
    end

    test "the parity check detonates when the SERVED ROW gains a tool the fallback lacks" do
      # Anti-vacuity in the direction that matters, and it crosses the seam the
      # check is supposed to watch: the mutation is applied to the
      # `prompt_templates` ROW, not to a body handed straight to the comparison.
      # A check that read `default_content_for_slug/1` instead would stay green
      # through this mutation — which is exactly why it reads the row.
      slug = "dispatch.in_review"
      original = Repo.get_by(PromptTemplate, slug: slug)
      refute is_nil(original), "expected a seeded #{slug} row to mutate"

      fallback_names = slug |> fallback_body!() |> tool_names()

      # Derived, not chosen by hand: any registered tool the fallback does not
      # already name. Picking a literal here would re-introduce the text pin
      # this file exists to avoid.
      unused_tool =
        known_tool_names()
        |> MapSet.difference(fallback_names)
        |> Enum.sort()
        |> List.first()

      refute is_nil(unused_tool)

      mutated = original.content <> "\n\nCall `#{unused_tool}` before finishing.\n"

      original
      |> Ecto.put_meta(state: :built)
      |> Ecto.Changeset.change(content: mutated)
      |> Repo.insert!()

      # Confirm the mutation actually landed before drawing any conclusion from
      # the result — an unapplied mutation scores as a false kill.
      assert Repo.get_by(PromptTemplate, slug: slug).content =~ "`#{unused_tool}`"

      missing = missing_tools(slug)

      assert MapSet.member?(missing, unused_tool),
             "parity check did not report `#{unused_tool}` after it was added to the " <>
               "served #{slug} row — the check cannot see row-side drift. Reported: " <>
               inspect(MapSet.to_list(missing))
    end
  end
end
