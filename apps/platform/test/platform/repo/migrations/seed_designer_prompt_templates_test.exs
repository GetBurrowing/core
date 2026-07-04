defmodule Platform.Repo.Migrations.SeedDesignerPromptTemplatesTest do
  @moduledoc """
  Regression coverage for `20260703120000_seed_designer_prompt_templates`
  (task 019f2455 stage 1).

  Migrations run to `:up` before ExUnit boots, so we assert the
  post-state: all three Designer bundle prompt templates
  (`design.critique.v1`, `design.spec_writer.v1`, `design.brand_check.v1`)
  are present with non-empty content and match the handler's
  `template_slug/0`.

  This is the smoke gate against a future drift where a handler renames
  its template slug but the migration content doesn't catch up — the
  first router-fired dispatch would hit
  `Orchestration.PromptTemplates.render_template/2` and get
  `{:error, :not_found}`, and there would be no test to catch it
  until a real agent tries to run the responsibility.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Handlers.DesignBrandCheck
  alias Platform.Responsibilities.Handlers.DesignCritique
  alias Platform.Responsibilities.Handlers.DesignSpecWriter

  describe "seeded Designer prompt templates" do
    test "design.critique.v1 exists with non-empty content" do
      assert %{content: content} = PromptTemplates.get_template_by_slug("design.critique.v1")
      assert is_binary(content)
      assert String.trim(content) != ""
      assert content =~ "Vega"
      assert content =~ "design.critique"
    end

    test "design.spec_writer.v1 exists with non-empty content" do
      assert %{content: content} = PromptTemplates.get_template_by_slug("design.spec_writer.v1")
      assert is_binary(content)
      assert String.trim(content) != ""
      assert content =~ "Vega"
      assert content =~ "design.spec_writer"
    end

    test "design.brand_check.v1 exists with non-empty content" do
      assert %{content: content} = PromptTemplates.get_template_by_slug("design.brand_check.v1")
      assert is_binary(content)
      assert String.trim(content) != ""
      assert content =~ "Vega"
      assert content =~ "design.brand_check"
    end

    test "seeded slugs match every Designer handler's template_slug/0" do
      # Drift guard: if a handler renames its slug without a matching
      # migration content update, the router would 404 at render time.
      for handler <- [DesignCritique, DesignSpecWriter, DesignBrandCheck] do
        slug = handler.template_slug()

        assert PromptTemplates.get_template_by_slug(slug) != nil,
               "handler #{inspect(handler)}.template_slug/0 = #{inspect(slug)} " <>
                 "has no matching prompt_templates row — seed migration drift"
      end
    end
  end
end
