defmodule Platform.Repo.Migrations.RewriteTaskAckPreambleStructuralClaimTest do
  @moduledoc """
  Coverage for `20260923120000_rewrite_task_ack_preamble_structural_claim`
  (task 01a0ac55-37e7-7001-9aec-051688ef7b07 stage 2).

  READ THIS BEFORE ADDING AN ASSERTION — the obvious migration test is vacuous
  by construction. In the test database the four dispatch rows are created by
  the seed migration running `PromptTemplates.seed_defaults/0` against the
  CURRENT code, so they already carry the reworded spawn paragraph before
  anything here runs; `refute row.content =~ "structurally impossible"` passes
  with the migration file deleted. Every test below therefore STALES THE ROWS
  FIRST — swaps the new paragraph back to the frozen old literal and adds a
  unique marker line — asserts the old sentence is present BY QUERY, and only
  then reads the delta.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.RewriteTaskAckPreambleStructuralClaim

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260923120000_rewrite_task_ack_preamble_structural_claim.exs"
                  ])

  @slugs [
    "dispatch.deploying",
    "dispatch.in_progress",
    "dispatch.in_review",
    "dispatch.scribe_completion"
  ]

  # Duplicated from the migration on purpose: if the migration's literal
  # drifted from what origin/main shipped, a test reading it from the module
  # would drift with it.
  @old_paragraph "Spawn the subagent FIRST, then include its returned agent id in the ack. Empty or missing subagent_id will fail validation — this ordering makes it structurally impossible to ack a dispatch you never spawned a subagent for. Without a successful ack the router will fire a no-ack alert in 5 minutes."

  @old_sentence "structurally impossible to ack"

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp marker(slug), do: "HAND-PATCHED MARKER LINE for #{slug} — must survive byte-identical."

  # Drives each row STALE and asserts the before-state BY QUERY. Returns
  # %{slug => stale_content}. Without this, every assertion below would hold
  # with `up/0` replaced by `:ok`.
  defp stale_the_rows! do
    new_paragraph = PromptTemplates.task_ack_spawn_paragraph()

    Map.new(@slugs, fn slug ->
      template = PromptTemplates.get_template_by_slug(slug)
      refute is_nil(template), "#{slug} must be seeded before this test can stale it"

      # The scribe default is stage-less now; construct the historical deployed
      # shape explicitly so this historical migration still proves its fourth row.
      deployed_content =
        if slug == "dispatch.scribe_completion" do
          new_paragraph <> "\n\nHistorical scribe meeting body: preserve this text.\n"
        else
          assert String.contains?(template.content, new_paragraph),
                 "#{slug} seeded row must carry the current spawn paragraph to be staled"

          template.content
        end

      stale =
        marker(slug) <>
          "\n\n" <> String.replace(deployed_content, new_paragraph, @old_paragraph)

      {:ok, _} = PromptTemplates.update_template(template, %{content: stale})

      requeried = PromptTemplates.get_template_by_slug(slug)
      assert requeried.content == stale
      assert requeried.content =~ @old_sentence
      refute String.contains?(requeried.content, new_paragraph)

      {slug, stale}
    end)
  end

  test "the frozen literal matches the migration's literal" do
    assert @migration_module.old_paragraph() == @old_paragraph
    assert @migration_module.slugs() == @slugs
  end

  test "the stale-first setup genuinely reinstates the old sentence in all four rows" do
    stales = stale_the_rows!()

    for slug <- @slugs do
      assert PromptTemplates.get_template_by_slug(slug).content == Map.fetch!(stales, slug)
      assert PromptTemplates.get_template_by_slug(slug).content =~ @old_sentence
    end
  end

  describe "up/0 against deployed-shaped (stale) rows" do
    test "replaces only the old paragraph; the marker and everything else survive" do
      stales = stale_the_rows!()
      new_paragraph = PromptTemplates.task_ack_spawn_paragraph()

      assert :ok = @migration_module.up()

      for slug <- @slugs do
        content = PromptTemplates.get_template_by_slug(slug).content

        refute content =~ @old_sentence, "#{slug} still carries the old sentence"
        assert String.contains?(content, new_paragraph), "#{slug} lacks the new paragraph"
        assert String.starts_with?(content, marker(slug) <> "\n\n")

        # Surgical: the row is exactly the stale row with one paragraph swapped.
        assert content ==
                 String.replace(Map.fetch!(stales, slug), @old_paragraph, new_paragraph)
      end
    end

    test "is idempotent — a second up/0 changes nothing, byte-identical" do
      stale_the_rows!()
      assert :ok = @migration_module.up()

      first = Map.new(@slugs, &{&1, PromptTemplates.get_template_by_slug(&1).content})

      # Without this, a no-op up/0 satisfies "the second run changes nothing".
      for {slug, content} <- first, do: refute(content =~ @old_sentence, slug)

      assert :ok = @migration_module.up()

      for slug <- @slugs do
        assert PromptTemplates.get_template_by_slug(slug).content == Map.fetch!(first, slug)
      end
    end

    test "leaves a row that no longer contains the old literal untouched" do
      stale_the_rows!()
      template = PromptTemplates.get_template_by_slug("dispatch.in_review")
      hand_edited = "HAND EDITED BODY without the frozen paragraph.\n"
      {:ok, _} = PromptTemplates.update_template(template, %{content: hand_edited})

      assert :ok = @migration_module.up()

      assert PromptTemplates.get_template_by_slug("dispatch.in_review").content == hand_edited
      refute PromptTemplates.get_template_by_slug("dispatch.in_progress").content =~ @old_sentence
    end

    test "seed_defaults/0 does NOT repair a stale row — the migration is load-bearing" do
      stales = stale_the_rows!()

      :ok = PromptTemplates.seed_defaults()

      for slug <- @slugs do
        assert PromptTemplates.get_template_by_slug(slug).content == Map.fetch!(stales, slug)
      end
    end

    test "after up/0 the render path no longer serves the claim" do
      stale_the_rows!()

      for slug <- @slugs do
        assert {:ok, rendered} = PromptTemplates.render_template(slug, %{})

        assert rendered =~ "structurally impossible",
               "the stale row must reach the render path, or the refute below is about the constant"
      end

      assert :ok = @migration_module.up()

      for slug <- @slugs do
        assert {:ok, rendered} = PromptTemplates.render_template(slug, %{})
        refute rendered =~ "structurally impossible"
      end
    end
  end

  describe "up/0 when a row is absent" do
    test "skips without raising and does not create the row" do
      stale_the_rows!()
      template = PromptTemplates.get_template_by_slug("dispatch.scribe_completion")
      {:ok, _} = PromptTemplates.delete_template(template)

      assert :ok = @migration_module.up()

      assert is_nil(PromptTemplates.get_template_by_slug("dispatch.scribe_completion"))
      refute PromptTemplates.get_template_by_slug("dispatch.deploying").content =~ @old_sentence
    end
  end

  describe "down/0" do
    test "is an explicit no-op and leaves the migrated rows in place" do
      stale_the_rows!()
      assert :ok = @migration_module.up()
      migrated = Map.new(@slugs, &{&1, PromptTemplates.get_template_by_slug(&1).content})

      # Without this, a no-op up/0 leaves the stale rows and down/0 "keeps" them.
      for {slug, content} <- migrated, do: refute(content =~ @old_sentence, slug)

      assert :ok = @migration_module.down()

      for slug <- @slugs do
        assert PromptTemplates.get_template_by_slug(slug).content == Map.fetch!(migrated, slug)
      end
    end
  end
end
