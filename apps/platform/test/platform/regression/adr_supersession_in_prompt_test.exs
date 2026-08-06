defmodule Platform.Regression.ADRSupersessionInPromptTest do
  @moduledoc """
  **The end-to-end detector for task `019fd00f-28ef` — "the architect's
  adr_drift check is unrunnable".**

  Both architecture prompts must carry, for a superseded ADR, all three
  of: the filename, the parsed title, and a line naming the document
  that superseded it. This file asserts the third one *specifically*,
  on the FULLY RENDERED prompt, for both handlers.

  ## Why non-emptiness is not the assertion

  The obvious end-to-end check — "`adr_index` is a list of maps with
  `:title`, `:status` and `:superseded_by` keys" — is a SHAPE assertion.
  It passes in any dev checkout that has `docs/decisions/` on disk,
  which is exactly the environment where the defect does not occur. It
  cannot go red for the reason this task exists.

  So the assertions here are:

    * on the **rendered prompt string**, not on the gathered map — the
      map is well-shaped whether or not the supersession survived
      rendering; and
    * on the **supersession line**, not on the presence of entries. An
      index that renders non-empty is NECESSARY AND NOT SUFFICIENT: a
      model handed a bare list of live-looking filenames cannot tell a
      current decision from a retired one, which is the drift check
      being unrunnable in the precise sense that matters.

  The filename assertion and the supersession assertion are deliberately
  kept as separate `assert`s over separate substrings so a renderer
  change that drops supersession lines reds the supersession assertion
  and leaves the filename assertion green. A single combined match would
  fire on both and tell the next reader nothing about which fact was
  lost. (Verified by mutation: removing the supersession lines from
  `ADRIndexRenderer.adr_entry_flags/1` reds only the supersession
  assertions.)

  ## The title is READ FROM THE FIXTURE, not hardcoded

  `expected_title/0` parses the `# ` heading out of
  `0098-old-decision.md` at run time and strips the `ADR NNNN` prefix.
  A hardcoded `"Old Decision"` would keep passing if the provider
  stopped parsing titles and the fixture were edited to match, and it
  would fail for the wrong reason if the fixture's wording changed. The
  claim under test is "the title the corpus carries reaches the prompt",
  so the corpus has to supply the expected value.

  ## Corpus

  `test/support/fixtures/adr_decisions/`, bound through
  `config :platform, :adr_dir` — which `ContextProviders.adr_dir/0`
  consults first. The fixture corpus is used rather than the live
  `docs/decisions/` because the shipped `architecture.review_plan.v1`
  template body itself cites real ADR filenames, so an assertion naming
  a real ADR could pass on template text no slot produced.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Handlers.ArchitectureCronSweep
  alias Platform.Responsibilities.Handlers.ArchitectureReviewPlan
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks

  # The superseded fixture ADR and the document that retires it.
  @superseded_file "0098-old-decision.md"
  @superseding_file "0100-supersedes-ninety-eight.md"

  # `# ADR 0098: Old Decision` / `# ADR 0100 — Supersedes Ninety Eight`.
  @heading ~r/^#\s+\S/u
  @number_prefix ~r/^(?:ADR[-\s–—]*)?\d{4}\s*(?:[-:.–—]\s*)?/u

  setup do
    Application.put_env(:platform, :adr_dir, fixture_adr_dir())
    on_exit(fn -> Application.delete_env(:platform, :adr_dir) end)

    :ok = PromptTemplates.seed_defaults()

    :ok
  end

  defp fixture_adr_dir, do: Path.expand("../../support/fixtures/adr_decisions", __DIR__)

  # Parsed from the fixture on every run. See the moduledoc.
  defp expected_title do
    title =
      fixture_adr_dir()
      |> Path.join(@superseded_file)
      |> File.stream!()
      |> Enum.take(20)
      |> Enum.find(&Regex.match?(@heading, &1))
      |> to_string()
      |> String.trim()
      |> String.replace_leading("#", "")
      |> String.trim()
      |> String.replace(@number_prefix, "", global: false)
      |> String.trim()

    # A blank expectation would make every title assertion below vacuous
    # (`=~ ""` is true of any string), so the fixture read is itself
    # checked before it is used as an oracle.
    refute title == "", "could not parse a title out of #{@superseded_file}"

    title
  end

  defp responsibility(key) do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: key,
      feature: "architecture",
      trigger_kind: "event_topic",
      trigger_config: %{},
      scope: "per_project",
      context_provided: ["adr_index"],
      enabled: true
    }
  end

  defp review_plan_prompt do
    {:ok, project} = Tasks.create_project(%{name: "ADR Supersession Regression"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "A plan the architect must review",
        status: "planning"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, gathered} =
      ArchitectureReviewPlan.gather_context(
        responsibility(ArchitectureReviewPlan.key()),
        %{plan: plan}
      )

    {:ok, %{user: user}} = ArchitectureReviewPlan.build_prompt(gathered)
    user
  end

  defp cron_sweep_prompt do
    {:ok, gathered} =
      ArchitectureCronSweep.gather_context(
        responsibility(ArchitectureCronSweep.key()),
        %{}
      )

    {:ok, %{user: user}} = ArchitectureCronSweep.build_prompt(gathered)
    user
  end

  describe "architecture.review_plan" do
    test "the rendered prompt names the superseded ADR's file and title" do
      prompt = review_plan_prompt()

      assert prompt =~ @superseded_file
      assert prompt =~ expected_title()
    end

    test "the rendered prompt says WHICH document superseded it" do
      # THE assertion. A prompt that lists 0098 without this line tells
      # the model a retired decision is live — the drift check reads as
      # runnable and answers wrongly, which is worse than refusing.
      prompt = review_plan_prompt()

      assert prompt =~ "superseded by #{@superseding_file}"
    end
  end

  describe "architecture.cron_sweep" do
    test "the rendered prompt names the superseded ADR's file and title" do
      prompt = cron_sweep_prompt()

      assert prompt =~ @superseded_file
      assert prompt =~ expected_title()
    end

    test "the rendered prompt says WHICH document superseded it" do
      prompt = cron_sweep_prompt()

      assert prompt =~ "superseded by #{@superseding_file}"
    end
  end
end
