defmodule Platform.Repo.Migrations.ForceUpdatePromptTemplatesSyncLiveRows20260910Test do
  @moduledoc """
  Coverage for `20260911003000_force_update_prompt_templates_sync_live_rows_2026_09_10`.

  In the test database every row is created by `seed_defaults/0` against the
  CURRENT code, so `row.content == default_content_for_slug(slug)` holds with
  this migration file deleted. Every test therefore stales the rows first
  (modelling a deployment whose rows predate the change) and asserts the delta
  `up/0` produces.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.ForceUpdatePromptTemplatesSyncLiveRows20260910

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260911003000_force_update_prompt_templates_sync_live_rows_2026_09_10.exs"
                  ])

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok = PromptTemplates.seed_defaults()
    :ok
  end

  defp stale!(slug) do
    template = PromptTemplates.get_template_by_slug(slug)
    refute is_nil(template), "#{slug} must be seeded before this test can stale it"

    {:ok, staled} = PromptTemplates.update_template(template, %{content: "STALE #{slug}"})

    # Before-state asserted, not assumed.
    refute staled.content == PromptTemplates.default_content_for_slug(slug)
    staled
  end

  test "covers exactly the five rows patched live on 2026-09-10" do
    assert Enum.sort(@migration_module.slugs()) ==
             Enum.sort([
               "dispatch.planning",
               "dispatch.review_e2e",
               "federation.preamble",
               "nudge",
               "dispatch.deploying"
             ])
  end

  test "up/0 rewrites every stale row to the shipped descriptor body" do
    for slug <- @migration_module.slugs(), do: stale!(slug)

    assert :ok = @migration_module.up()

    for slug <- @migration_module.slugs() do
      assert PromptTemplates.get_template_by_slug(slug).content ==
               PromptTemplates.default_content_for_slug(slug),
             "#{slug}: up/0 must write default_content_for_slug/1"
    end
  end

  test "up/0 normalises the trailing-newline drift on dispatch.planning" do
    template = PromptTemplates.get_template_by_slug("dispatch.planning")
    default = PromptTemplates.default_content_for_slug("dispatch.planning")
    assert String.ends_with?(default, "\n")

    # The milv row: same text, no trailing newline.
    {:ok, drifted} =
      PromptTemplates.update_template(template, %{content: String.trim_trailing(default, "\n")})

    refute drifted.content == default

    assert :ok = @migration_module.up()
    assert PromptTemplates.get_template_by_slug("dispatch.planning").content == default
  end

  test "up/0 is idempotent" do
    for slug <- @migration_module.slugs(), do: stale!(slug)

    assert :ok = @migration_module.up()
    first = Enum.map(@migration_module.slugs(), &PromptTemplates.get_template_by_slug(&1).content)

    assert :ok = @migration_module.up()

    assert Enum.map(@migration_module.slugs(), &PromptTemplates.get_template_by_slug(&1).content) ==
             first
  end

  test "up/0 leaves rows outside the five alone" do
    before = PromptTemplates.get_template_by_slug("dispatch.in_review")
    refute is_nil(before)

    {:ok, _} =
      PromptTemplates.update_template(before, %{content: "IN_REVIEW SENTINEL {{task_title}}"})

    assert :ok = @migration_module.up()

    assert PromptTemplates.get_template_by_slug("dispatch.in_review").content ==
             "IN_REVIEW SENTINEL {{task_title}}"
  end

  test "up/0 skips an absent row without creating it" do
    template = PromptTemplates.get_template_by_slug("nudge")
    {:ok, _} = PromptTemplates.delete_template(template)

    assert :ok = @migration_module.up()
    assert is_nil(PromptTemplates.get_template_by_slug("nudge"))
  end
end
