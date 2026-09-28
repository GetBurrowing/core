defmodule Platform.Repo.Migrations.ForceUpdateHistorianMeetingEndedTemplateTest do
  @moduledoc """
  Coverage for `20260928020000_force_update_historian_meeting_ended_template`
  (task 01a0a12e stage 4).

  In the test database the `historian.meeting_ended` row is seeded from the
  CURRENT descriptor, so `row == descriptor` holds with the migration file
  deleted, and the migration reads its own comparand from the descriptor.
  Every test therefore STALES THE ROW FIRST to the pre-change body (the one
  both live installs served when this stage was written) and asserts the
  delta `up/0` produces.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @slug "historian.meeting_ended"

  @migration_module Platform.Repo.Migrations.ForceUpdateHistorianMeetingEndedTemplate

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260928020000_force_update_historian_meeting_ended_template.exs"
                  ])

  # The pre-change shape: filter instruction, decisions.md step, and the
  # unroutable `<meeting_id>-ended.md` journal path.
  @stale_content """
  A meeting just ended. Read the transcript via `memory_search` filtered to `meeting_id={{meeting_id}}`.

  ## Summary (provisional — verify against the transcript)

  {{meeting_summary}}

  2. Update `project/{{project_id}}/page/decisions.md` with any durable decisions.
  4. Append at `project/{{project_id}}/journal/{{meeting_id}}-ended.md`.
  """

  @stale_description "Carries meeting + project + space scope so the Historian can update decisions / action-item pages."

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok = PromptTemplates.seed_defaults()
    :ok
  end

  defp stale_the_row! do
    template = PromptTemplates.get_template_by_slug(@slug)
    refute is_nil(template), "#{@slug} must be seeded before this test can stale it"

    {:ok, _} =
      PromptTemplates.update_template(template, %{
        content: @stale_content,
        description: @stale_description,
        variables: ~w(meeting_id project_id chat_space_id meeting_summary)
      })

    requeried = PromptTemplates.get_template_by_slug(@slug)
    assert requeried.content == @stale_content
    assert requeried.content =~ "page/decisions.md"
    assert requeried.content =~ "meeting_id="
    requeried
  end

  test "the migration declares exactly this slug" do
    assert @migration_module.slugs() == [@slug]
  end

  test "up/0 rewrites a stale row's content AND description to the shipped descriptor" do
    stale_the_row!()

    assert :ok = @migration_module.up()

    reloaded = PromptTemplates.get_template_by_slug(@slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    assert reloaded.content == descriptor.content
    assert reloaded.description == descriptor.description
    assert reloaded.variables == descriptor.variables
    assert "date" in reloaded.variables
    refute reloaded.content =~ "page/decisions.md"
    refute reloaded.content =~ "meeting_id="
    refute reloaded.content =~ "-ended.md"
  end

  test "seed_defaults/0 does NOT repair the stale row — the migration is load-bearing" do
    staled = stale_the_row!()

    :ok = PromptTemplates.seed_defaults()
    assert PromptTemplates.get_template_by_slug(@slug).content == staled.content

    assert :ok = @migration_module.up()
    refute PromptTemplates.get_template_by_slug(@slug).content == staled.content
  end

  test "is idempotent" do
    stale_the_row!()
    assert :ok = @migration_module.up()
    first = PromptTemplates.get_template_by_slug(@slug)
    assert :ok = @migration_module.up()
    assert PromptTemplates.get_template_by_slug(@slug).content == first.content
  end

  test "leaves the historian.threshold and historian.scheduled rows alone" do
    for slug <- ~w(historian.threshold historian.scheduled) do
      row = PromptTemplates.get_template_by_slug(slug)
      {:ok, _} = PromptTemplates.update_template(row, %{content: "SENTINEL #{slug}"})
    end

    stale_the_row!()
    assert :ok = @migration_module.up()

    for slug <- ~w(historian.threshold historian.scheduled) do
      assert PromptTemplates.get_template_by_slug(slug).content == "SENTINEL #{slug}"
    end
  end

  test "skips without raising when the row is absent" do
    template = PromptTemplates.get_template_by_slug(@slug)
    {:ok, _} = Platform.Repo.delete(template)
    assert PromptTemplates.get_template_by_slug(@slug) == nil

    assert :ok = @migration_module.up()
    assert PromptTemplates.get_template_by_slug(@slug) == nil
  end
end
