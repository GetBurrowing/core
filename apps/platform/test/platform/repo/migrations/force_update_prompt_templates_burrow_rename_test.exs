defmodule Platform.Repo.Migrations.ForceUpdatePromptTemplatesBurrowRenameTest do
  @moduledoc """
  Coverage for `20261017230000_force_update_prompt_templates_burrow_rename`
  (task 01a14b9e-50a4-7000-996c-429bca872907, stage 3).

  READ THIS BEFORE ADDING AN ASSERTION HERE: asserting that a seeded row says
  "Burrow" is vacuous. In the test database every row is seeded by
  `seed_defaults/0` from the CURRENT code, so it already equals this branch's
  descriptor before the migration runs, and the assertion would pass with the
  migration file deleted.

  Every test below models a DEPLOYED environment instead: it writes a body of
  its own into the row, hands `run/1` the md5 map that body implies, and
  asserts the delta.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.ForceUpdatePromptTemplatesBurrowRename

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261017230000_force_update_prompt_templates_burrow_rename.exs"
                  ])

  # The slugs this stage edits, written down rather than read back from the
  # migration: a test that derived them from `pre_change_md5/0` could not fail.
  @edited_slugs [
    "federation.preamble",
    "dispatch.review_e2e",
    "feedback.intake.v1",
    "janitor.cron_drain.v1"
  ]

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
      test "a row at the pre-change md5 is rewritten to the descriptor" do
        slug = unquote(slug)
        stale = "STALE #{slug} BODY filed against Startup Suite"
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

      test "an edited row whose md5 is NOT in the map is left unchanged, with a warning" do
        slug = unquote(slug)
        operator = "OPERATOR EDIT of #{slug}"
        write_row!(slug, operator)

        log =
          capture_log(fn ->
            assert :ok = apply(@migration_module, :run, [%{slug => md5("some other body")}])
          end)

        assert row_content(slug) == operator
        assert log =~ "skipping #{slug}"
        assert log =~ md5(operator)
      end

      test "a rerun after the rewrite is a no-op" do
        slug = unquote(slug)
        stale = "STALE #{slug} BODY for the rerun"
        write_row!(slug, stale)
        pre_change = %{slug => md5(stale)}

        assert :ok = apply(@migration_module, :run, [pre_change])
        rewritten = PromptTemplates.get_template_by_slug(slug)
        assert rewritten.content == PromptTemplates.default_content_for_slug(slug)

        log = capture_log(fn -> assert :ok = apply(@migration_module, :run, [pre_change]) end)

        reloaded = PromptTemplates.get_template_by_slug(slug)
        assert reloaded.content == rewritten.content
        assert reloaded.updated_at == rewritten.updated_at
        refute log =~ "skipping #{slug}"
      end

      test "a missing row is skipped and not created" do
        slug = unquote(slug)
        {:ok, _} = PromptTemplates.delete_template(PromptTemplates.get_template_by_slug(slug))

        assert :ok = apply(@migration_module, :run, [%{slug => md5("anything")}])
        assert is_nil(PromptTemplates.get_template_by_slug(slug))
      end

      test "the descriptor the migration writes names Burrow, not Suite" do
        content = PromptTemplates.default_content_for_slug(unquote(slug))
        assert content =~ "Burrow"
        refute content =~ ~r/(?<![-\w])Suite(?!\w)/
        refute content =~ "Startup Suite"
      end
    end
  end

  test "the pre-change md5 keys are exactly the slugs this stage edits" do
    assert apply(@migration_module, :pre_change_md5, []) |> Map.keys() |> Enum.sort() ==
             Enum.sort(@edited_slugs)
  end

  # Measured read-only 2026-10-17 22:30Z on core-platform, core-platform-beta
  # and core-platform-gamma (image revision 95040921), equal to md5 of the
  # origin/main 95040921 descriptor.
  for {slug, measured} <- [
        {"federation.preamble", "cd5c8e47b27fc6419cad360e956056b2"},
        {"dispatch.review_e2e", "0ec878e34edf00088bac0d4594ca45af"},
        {"feedback.intake.v1", "6e1913735fb549661be6224de70009d8"},
        {"janitor.cron_drain.v1", "10680d2c9880882f884b2bc675ff6760"}
      ] do
    test "#{slug} carries the md5 measured on the live installs" do
      assert apply(@migration_module, :pre_change_md5, [])[unquote(slug)] == unquote(measured)
    end

    test "#{slug}'s new descriptor is not the pre-change body" do
      refute md5(PromptTemplates.default_content_for_slug(unquote(slug))) == unquote(measured)
    end
  end

  test "up/0 preserves a foreign body rather than overwriting it" do
    slug = "federation.preamble"
    foreign = "FOREIGN #{slug}"
    write_row!(slug, foreign)

    log = capture_log(fn -> assert :ok = apply(@migration_module, :up, []) end)

    assert row_content(slug) == foreign
    assert log =~ "skipping #{slug}"
  end
end
