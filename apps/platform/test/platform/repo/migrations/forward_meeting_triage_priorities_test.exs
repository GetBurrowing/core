defmodule Platform.Repo.Migrations.ForwardMeetingTriagePrioritiesTest do
  use Platform.DataCase, async: false

  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20261030153000_forward_meeting_triage_priorities.exs",
      __DIR__
    )
  )

  alias Platform.Repo.Migrations.ForwardMeetingTriagePriorities, as: Migration
  alias Platform.Orchestration.PromptTemplates

  test "persisted defaults and customized live bodies retain unrelated text on repeat" do
    PromptTemplates.seed_defaults()
    Platform.Skills.seed_defaults()
    prompt = PromptTemplates.get_template_by_slug("dispatch.triage_dispatch")
    skill = Platform.Skills.get_skill_by_slug("meeting-triage-officer")

    for customized <- [false, true] do
      prefix = if customized, do: "HUMAN tenant escalation policy stays.\n", else: ""
      # Full audited live bodies match across kobo and milv; keep run identity.
      old_prompt =
        File.read!(
          Path.expand("../../../fixtures/meetings/triage_prompt_live_20261030.md", __DIR__)
        )

      old_skill =
        File.read!(
          Path.expand("../../../fixtures/meetings/triage_skill_live_20261030.md", __DIR__)
        )

      assert {:ok, _} = PromptTemplates.update_template(prompt, %{content: prefix <> old_prompt})
      assert {:ok, _} = Platform.Skills.update_skill(skill, %{content: prefix <> old_skill})
      assert :ok = Migration.up()
      first_prompt = PromptTemplates.get_template_by_slug(prompt.slug)
      first_skill = Platform.Skills.get_skill_by_slug(skill.slug)

      for body <- [first_prompt.content, first_skill.content] do
        for value <- ["low", "medium", "high", "critical"],
            do: assert(body =~ "`#{value}` → `#{value}`")

        assert body =~ "note priorities default to `medium`"
        assert body =~ "invalid explicit API priority is refused"
        assert body =~ "server owns the single batch junk control"
        assert body =~ prefix
      end

      assert first_prompt.content =~ "## This run"
      assert first_prompt.content =~ "{{run_id}}"

      assert String.replace(first_prompt.content, block(first_prompt.content), "") ==
               prefix <> old_prompt

      assert first_skill.content =~ "# Meeting Triage Officer"

      [skill_before, skill_after] =
        String.split(first_skill.content, "## Priority forwarding and batch control", parts: 2)

      [_, skill_tail] = String.split(skill_after, "### Idempotency contract", parts: 2)

      original_skill =
        (skill_before <> "### Idempotency contract" <> skill_tail)
        |> String.replace(
          ~S(`"low" | "medium" | "high" | "critical"`),
          ~S(`"high" | "medium" | "low"`)
        )
        |> String.replace("`low|medium|high|critical`", "`high|medium|low`")
        |> String.replace(~S(- `"critical"` → `critical`) <> "\n", "")

      assert original_skill == prefix <> old_skill
      assert :ok = Migration.up()
      assert PromptTemplates.get_template_by_slug(prompt.slug) == first_prompt
      assert Platform.Skills.get_skill_by_slug(skill.slug) == first_skill
    end
  end

  defp block(content) do
    [_, rest] = String.split(content, "## Priority forwarding and batch control", parts: 2)
    [body, _] = String.split(rest, "## Idempotency", parts: 2)
    "## Priority forwarding and batch control" <> body
  end

  test "additive rewrite preserves customized bodies byte for byte and guards duplicates" do
    for original <- ["Human prefix\n{{skills_reference}}\nHuman suffix", "Unusual human text\n\n"] do
      updated = Migration.rewrite(original)
      assert Migration.rewrite(updated) == updated
      assert length(String.split(updated, "## Priority forwarding and batch control")) == 2
      assert updated =~ "Human" or updated =~ "Unusual"
    end
  end
end
