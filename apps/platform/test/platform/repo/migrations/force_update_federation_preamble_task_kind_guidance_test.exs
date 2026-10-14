defmodule Platform.Repo.Migrations.ForceUpdateFederationPreambleTaskKindGuidanceTest do
  @moduledoc """
  Proves the force-update is load-bearing by making the served row stale first.
  Without the migration, the new source constant would not reach an install
  whose prompt row already exists.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  @slug "federation.preamble"
  @heading "## Choosing a task kind"
  @migration Platform.Repo.Migrations.ForceUpdateFederationPreambleTaskKindGuidance
  @path Path.join([
          __ENV__.file
          |> Path.dirname()
          |> Path.dirname()
          |> Path.dirname()
          |> Path.dirname()
          |> Path.dirname(),
          "priv/repo/migrations/20261009073500_force_update_federation_preamble_task_kind_guidance.exs"
        ])

  setup do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    :ok
  end

  test "rewrites an existing stale row with the taxonomy guidance" do
    template = PromptTemplates.get_template_by_slug(@slug)
    refute is_nil(template)

    stale = "## Execution posture — close the ticket

STALE WITHOUT TAXONOMY"
    {:ok, _} = PromptTemplates.update_template(template, %{content: stale})
    refute PromptTemplates.get_template_by_slug(@slug).content =~ @heading

    assert :ok = apply(@migration, :up, [])

    content = PromptTemplates.get_template_by_slug(@slug).content
    assert content =~ @heading
    assert content =~ "task_create"
    assert content =~ "feature"
    assert content =~ "chore"
    assert content =~ "bug"
    assert content =~ "research"
    assert content =~ "ops"
    assert content == PromptTemplates.default_content_for_slug(@slug)
  end
end
