defmodule Platform.Responsibilities.PromptTemplateCoverageTest do
  @moduledoc """
  Characterisation test for task `01a0a74d` stage 1: every responsibility
  that declares a `default_prompt_template` must have a row carrying that
  slug, and today exactly one does not.

  ## What is measured, and against which identifier

  The orphan is the TEMPLATE SLUG `memory.daily_summary.v1` — the value of
  `default_prompt_template` in `Handlers.DailySummary.register/0` — not the
  responsibility KEY `memory.daily_summary`, which is a different string in
  the same map. The ticket that opened this work searched the key and found
  an absence that was real but was about the wrong identifier.

  Measured at `origin/main` sha `f8e0d6392e7d9874a2040dc3f574654518d90add`
  via the Suite `prompt_template_list` tool against the beta install: 41
  slugs returned, `memory.daily_summary.v1` absent. Positive control in the
  same listing: `memory.dreaming.v1`, `memory.propose_long_term.v1`,
  `historian.scheduled` and `historian.dreaming` all present, so the absence
  is a fact about the slug and not about an instrument that filters
  `memory.*`.

  ## The stage-1 prediction was REFUTED: there are TWO orphans, not one

  The prediction stated before the run was that the orphan list held exactly
  one entry. It holds two. `meetings.summarize.v1`, declared by
  `Handlers.MeetingSummarize.register/0`, has no descriptor in
  `PromptTemplates.do_default_templates/0`, no seeding migration, and is
  absent from the live beta install's `prompt_template_list` (which DOES
  return its eight `meetings.*` siblings, so that absence is about the slug
  and not about the listing). It is a second, independent instance of the
  same defect, found by the sweep rather than by the ticket.

  It is recorded here rather than folded in silently: the expected list below
  names it with this comment attached, and the finding is reported on the task
  row. Its trigger is `event` (`meeting_finished`), not `cron`, so unlike
  `memory.daily_summary.v1` it does not fire unattended on a clock — and it
  carries a legacy `fallback` MFA. Deciding what body it should get is NOT
  this task's stage 2; it is the input to stage 3's cron-key sweep.

  ## This assertion FLIPPED at stage 2

  It was GREEN at stage 1 as `["meetings.summarize.v1", "memory.daily_summary.v1"]`,
  describing the defect. Stage 2 seeded `memory.daily_summary.v1` — descriptor
  plus `20260916103000_seed_memory_daily_summary_prompt.exs` — and the
  expectation below dropped to `["meetings.summarize.v1"]`. Revert either half
  of that fix and this line goes red, which is the point: the fix had a red
  line to turn, rather than being covered by a test that only ever passed.

  It did NOT flip to `[]`. The second orphan is a real finding, not noise to
  be tidied away.

  ## Why the list is exact rather than a membership check

  `assert "memory.daily_summary.v1" in orphans` would stay green if a second
  responsibility lost its template, which is precisely the regression this
  file should catch. The equality also means the list itself is the
  ticket's sweep output.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  # Mirrors the PRIVATE `Router.template_assigns/1` (router.ex), which is
  # what actually stands between the gathered context and
  # `PromptTemplates.render_template/2` on the dispatch path. Rendering the
  # raw context instead would not merely be unrepresentative — it FAILS:
  # `interpolate/2` hands each assign to `Regex.replace/3`, which raises on
  # a non-binary, and `render_template/2` rescues that into
  # `{:error, :not_found}`. So a nested assign (`org_identity` is a map)
  # reports as a MISSING TEMPLATE for a row that is sitting right there,
  # which is the lie router.ex's own comment above `template_assigns/1`
  # describes. Duplicated rather than made public because this file is
  # asserting the descriptor, not the Router's API.
  defp template_assigns(context) do
    context
    |> Map.delete(:__responsibility__)
    |> Map.new(fn
      {k, v} when is_binary(v) -> {k, v}
      {k, v} when is_number(v) or is_atom(v) -> {k, to_string(v)}
      {k, v} -> {k, inspect(v)}
    end)
  end

  defp declared_slugs do
    :platform
    |> Application.get_env(Platform.Responsibilities, [])
    |> Keyword.get(:providers, [])
    |> Enum.flat_map(fn provider ->
      Code.ensure_loaded!(provider)
      provider.register()
    end)
    |> Enum.map(&Map.get(&1, :default_prompt_template))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  describe "every declared default_prompt_template resolves to a row" do
    test "the orphan set is exactly the known gap" do
      PromptTemplates.seed_defaults()

      slugs = declared_slugs()

      # Positive control: an absence-shaped assertion needs proof the
      # enumeration found anything at all. A provider list that failed to
      # load would satisfy an empty-orphan assertion by being broken, and
      # would satisfy this one by producing an empty slug set — so pin both
      # that the set is non-empty and that it contains the slug under test.
      refute slugs == []
      assert "memory.daily_summary.v1" in slugs

      # Control on the read side: the resolver must be able to return a row
      # at all, or "nothing resolves" would look like "everything is an
      # orphan".
      assert PromptTemplates.get_template_by_slug("memory.dreaming.v1")

      orphans = Enum.reject(slugs, &PromptTemplates.get_template_by_slug/1)

      # FLIPPED BY STAGE 2. "memory.daily_summary.v1" now resolves: it has a
      # descriptor in `do_default_templates/0` and
      # `20260916103000_seed_memory_daily_summary_prompt.exs` puts the row on
      # a live install. "meetings.summarize.v1" is deliberately STILL HERE —
      # see the moduledoc; it is a separate finding with a separate owner and
      # is stage 3's sweep input. Flattening this to `[]` to make the run
      # green would delete a real result.
      assert orphans == ["meetings.summarize.v1"]
    end
  end

  describe "memory.daily_summary.v1 declares no variable its context cannot fill" do
    # THE HOLE THIS CATCHES. `PromptTemplates.interpolate/2` substitutes ""
    # for an assign nobody supplied, and `Router.template_assigns/1` passes
    # the gathered context straight through. So a `{{workspace_id}}` declared
    # in the descriptor while `gather_context/2` omits it does not error, does
    # not warn, and does not render a placeholder — it renders a blank that
    # reads as content. That is the same failure mode as the missing row this
    # stage seeded, one layer in, and it is invisible to the orphan sweep
    # above because the row exists.
    test "every declared variable is a key the handler's gather_context/2 returns" do
      descriptor =
        Enum.find(PromptTemplates.default_templates(), &(&1.slug == "memory.daily_summary.v1"))

      assert descriptor, "no descriptor for memory.daily_summary.v1 in default_templates/0"
      refute descriptor.variables == [], "descriptor declares no variables — nothing is proven"

      {:ok, context} =
        Platform.Responsibilities.Handlers.DailySummary.gather_context(
          %Platform.Responsibilities.Responsibility{
            key: "memory.daily_summary",
            feature: "memory",
            context_provided: ["recent_journal", "org_identity"]
          },
          %{}
        )

      supplied = context |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

      # Positive control: a context that gathered nothing would satisfy a
      # subset check only if the descriptor also declared nothing, but it
      # would satisfy the "no {{ survives" check below by rendering a body
      # with no placeholders at all. Pin that the context is real first.
      assert "recent_journal" in supplied
      assert "org_identity" in supplied

      unfillable = Enum.reject(descriptor.variables, &MapSet.member?(supplied, &1))

      assert unfillable == [],
             """
             memory.daily_summary.v1 declares variable(s) its handler never supplies:

               #{Enum.join(unfillable, ", ")}

             These interpolate as the empty string at dispatch — a blank in
             the prompt that reads as content rather than as a hole. Either
             return the key from `Handlers.DailySummary.gather_context/2` or
             drop it from the descriptor's `variables`.
             """
    end

    test "rendering with the handler's own context leaves no placeholder behind" do
      PromptTemplates.seed_defaults()

      {:ok, context} =
        Platform.Responsibilities.Handlers.DailySummary.gather_context(
          %Platform.Responsibilities.Responsibility{
            key: "memory.daily_summary",
            feature: "memory",
            context_provided: ["recent_journal", "org_identity"]
          },
          %{}
        )

      assert {:ok, body} =
               PromptTemplates.render_template(
                 "memory.daily_summary.v1",
                 template_assigns(context)
               )

      # The deliverable, stated directly: the row resolves and renders.
      refute body == ""
      refute body =~ "{{"

      # And the body carries the instruction the ticket exists for. A
      # template that silently accepts an empty record re-creates the defect
      # one layer in, so the refusal sentence is load-bearing, not prose.
      assert body =~ "RETURN NO SUMMARY"
    end
  end
end
