defmodule Platform.Repo.Migrations.ForceUpdateDispatchTemplatesDesignFidelityTest do
  @moduledoc """
  Coverage for `20261014180000_force_update_dispatch_templates_design_fidelity`
  (task 01a13ae7).

  READ THIS BEFORE ADDING AN ASSERTION HERE: asserting that the
  `dispatch.planning` row carries the new section is vacuous. In the test
  database that row is seeded by `seed_defaults/0` from the CURRENT code, so it
  already equals this branch's descriptor before the migration runs, and the
  assertion would pass with the migration file deleted (see
  `force_update_in_review_template_stage_description_test.exs`).

  Every test below models a DEPLOYED environment instead: it writes a body of
  its own into the row, hands `run/1` the md5 map that body implies, and
  asserts the delta.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.ForceUpdateDispatchTemplatesDesignFidelity

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261014180000_force_update_dispatch_templates_design_fidelity.exs"
                  ])

  # The slugs this task edits, written down rather than read back from the
  # migration: a test that derived them from `pre_change_md5/0` could not fail.
  @edited_slugs ["dispatch.planning", "dispatch.in_progress", "dispatch.review_e2e"]

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp md5(content), do: :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

  defp write_row!(slug, content) do
    template = PromptTemplates.get_template_by_slug(slug)
    refute is_nil(template), "#{slug} must be seeded before this test can rewrite it"
    {:ok, written} = PromptTemplates.update_template(template, %{content: content})
    # Before-state, asserted rather than assumed.
    assert written.content == content
    written
  end

  defp row_content(slug), do: PromptTemplates.get_template_by_slug(slug).content

  for slug <- @edited_slugs do
    describe "run/1 for #{slug}" do
      test "a stale row whose md5 is in the map is rewritten to the descriptor" do
        slug = unquote(slug)
        stale = "STALE #{slug} BODY {{task_title}}"
        write_row!(slug, stale)

        # The KEY comes from the migration's own map and only the md5 VALUE is
        # replaced (the real pre-change body is not available here), so a slug
        # dropped from `@pre_change_md5` fails this test with a KeyError
        # rather than passing on a map the test built for itself.
        pre_change =
          apply(@migration_module, :pre_change_md5, [])
          |> Map.take([slug])
          |> Map.replace!(slug, md5(stale))

        assert :ok = apply(@migration_module, :run, [pre_change])

        assert row_content(slug) == PromptTemplates.default_content_for_slug(slug)
        refute row_content(slug) == stale
      end

      test "an operator row whose md5 is NOT in the map is left unchanged, with a warning" do
        slug = unquote(slug)
        operator = "OPERATOR EDIT of #{slug} {{task_title}}"
        write_row!(slug, operator)

        log =
          capture_log(fn ->
            assert :ok = apply(@migration_module, :run, [%{slug => md5("some other body")}])
          end)

        assert row_content(slug) == operator
        assert log =~ slug
        assert log =~ md5(operator)
      end

      test "a row already equal to the descriptor is unchanged" do
        slug = unquote(slug)
        descriptor = PromptTemplates.default_content_for_slug(slug)
        written = write_row!(slug, descriptor)

        # The map names a DIFFERENT md5, so the only reason this is not the
        # warning branch is the descriptor-equality skip.
        log =
          capture_log(fn ->
            assert :ok = apply(@migration_module, :run, [%{slug => md5("x")}])
          end)

        reloaded = PromptTemplates.get_template_by_slug(slug)
        assert reloaded.content == descriptor
        assert reloaded.updated_at == written.updated_at
        refute log =~ "skipping #{slug}"
      end
    end
  end

  test "the pre-change md5 keys are exactly the slugs this task edits" do
    assert apply(@migration_module, :pre_change_md5, []) |> Map.keys() |> Enum.sort() ==
             Enum.sort(@edited_slugs)
  end

  # Measured read-only on both installs (legacy core-platform, rivera
  # core-platform-beta), image revision 18c1f549, 2026-10-14.
  for {slug, measured} <- [
        {"dispatch.planning", "907e72e9a10990cfaaacad81025be5cd"},
        {"dispatch.in_progress", "9239973ef0a842177565e1b4eb40c491"},
        {"dispatch.review_e2e", "e75607564b0fcfbb16a925d210a8002a"}
      ] do
    test "#{slug} carries the md5 measured on both installs" do
      assert apply(@migration_module, :pre_change_md5, [])[unquote(slug)] == unquote(measured)
    end
  end

  test "the stage-3 descriptors carry the design fidelity sections the migration ships" do
    # Guards the other half of the force-update: the body it writes must be
    # the new one, or the migration ships the old text under a new md5 guard.
    assert PromptTemplates.default_content_for_slug("dispatch.in_progress") =~
             "Design deviations — stage"

    assert PromptTemplates.default_content_for_slug("dispatch.review_e2e") =~
             "Fidelity case — canvas"
  end

  test "up/0 preserves a foreign body rather than overwriting it" do
    # `up/0` goes through the same guard as `run/1`: the production pre-change
    # body is not available here, so this proves the guard is wired into
    # `up/0` from the other side: a body matching neither md5 survives it.
    slug = "dispatch.planning"
    foreign = "FOREIGN #{slug}"
    write_row!(slug, foreign)

    log = capture_log(fn -> assert :ok = apply(@migration_module, :up, []) end)

    assert row_content(slug) == foreign
    assert log =~ "skipping #{slug}"
  end

  test "an absent row is skipped and not created" do
    slug = "dispatch.planning"
    {:ok, _} = PromptTemplates.delete_template(PromptTemplates.get_template_by_slug(slug))

    assert :ok = apply(@migration_module, :run, [%{slug => md5("anything")}])
    assert is_nil(PromptTemplates.get_template_by_slug(slug))
  end
end
