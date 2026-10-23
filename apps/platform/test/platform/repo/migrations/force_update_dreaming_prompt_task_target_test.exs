defmodule Platform.Repo.Migrations.ForceUpdateDreamingPromptTaskTargetTest do
  @moduledoc """
  Coverage for `20261021160000_force_update_dreaming_prompt_task_target`
  (task 01a15ee1 stage 2), the same three-way guard as
  `20261018000200_force_update_dreaming_prompt_insights`.

  As in the Burrow-rename force-update test: a seeded row already equals the
  current descriptor, so every test writes a body of its own and asserts
  the delta.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.ForceUpdateDreamingPromptTaskTarget

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261021160000_force_update_dreaming_prompt_task_target.exs"
                  ])

  @slugs ["historian.dreaming", "memory.dreaming.v1"]

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok = PromptTemplates.seed_defaults()
    :ok
  end

  defp md5(content), do: :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

  defp write_row!(slug, content) do
    template = PromptTemplates.get_template_by_slug(slug)
    {:ok, written} = PromptTemplates.update_template(template, %{content: content})
    assert written.content == content
  end

  defp row(slug), do: PromptTemplates.get_template_by_slug(slug).content

  test "the migration names exactly the two dreaming slugs, at the measured md5" do
    assert apply(@migration_module, :pre_change_md5, []) == %{
             "historian.dreaming" => "24c2a2deb548681d274c779d76d02ec6",
             "memory.dreaming.v1" => "24c2a2deb548681d274c779d76d02ec6"
           }
  end

  test "undoing this task's edits on the descriptor rebuilds the measured pre-change body" do
    for slug <- @slugs do
      descriptor = PromptTemplates.default_content_for_slug(slug)

      for {_before, after_edit} <- apply(@migration_module, :edits, []) do
        assert length(String.split(descriptor, after_edit)) == 2
      end

      rebuilt = apply(@migration_module, :undo_edits, [descriptor])
      assert md5(rebuilt) == apply(@migration_module, :pre_change_md5, [])[slug]
    end
  end

  test "the new descriptor is not the measured pre-change body, so a live row at that md5 is rewritten" do
    for slug <- @slugs do
      refute md5(PromptTemplates.default_content_for_slug(slug)) ==
               apply(@migration_module, :pre_change_md5, [])[slug]
    end
  end

  for slug <- @slugs do
    test "#{slug}: a row at the pre-change md5 is rewritten to the descriptor" do
      slug = unquote(slug)
      stale = "STALE dreaming body with <synthesis-proposal> for #{slug}"
      write_row!(slug, stale)

      pre =
        apply(@migration_module, :pre_change_md5, [])
        |> Map.take([slug])
        |> Map.put(slug, md5(stale))

      assert :ok = apply(@migration_module, :run, [pre])
      assert row(slug) == PromptTemplates.default_content_for_slug(slug)
    end

    test "#{slug}: an operator edit is preserved and logged" do
      slug = unquote(slug)
      write_row!(slug, "operator edit")

      log = capture_log(fn -> assert :ok = apply(@migration_module, :up, []) end)

      assert row(slug) == "operator edit"
      assert log =~ "skipping #{slug}"
    end
  end

  test "a row already at the descriptor is left alone" do
    for slug <- @slugs, do: assert(row(slug) == PromptTemplates.default_content_for_slug(slug))
    assert :ok = apply(@migration_module, :up, [])
    for slug <- @slugs, do: assert(row(slug) == PromptTemplates.default_content_for_slug(slug))
  end
end
