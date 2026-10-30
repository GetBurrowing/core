defmodule Platform.Experiments.Surfaces.MeetingBriefSynthesisTest do
  use Platform.DataCase

  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.MeetingBriefSynthesis, as: Surface
  alias Platform.Orchestration.PromptTemplates

  test "registered meeting subject and bounded synthesis payload" do
    assert Surfaces.get("meetings.brief_synthesis") == Surface
    assert Surface.subject_type() == "meeting"
    assert Surface.path() == :draft
    assert Surface.targets() == ["meetings.brief_synthesis"]

    assert {:ok, payload} = Surface.validate_payload(%{provider: "openai"})
    assert payload["lookback_days"] == 14
    assert payload["max_sources"] == 60
    assert payload["min_confidence"] == "medium"

    assert {:ok, %{"model" => "model", "system_prompt" => "directive"}} =
             Surface.validate_payload(%{
               provider: "ollama",
               model: " model ",
               system_prompt: " directive ",
               lookback_days: 90,
               max_sources: 200,
               min_confidence: "low"
             })
  end

  test "rejects invalid arms and unbounded context" do
    for invalid <- [
          %{},
          %{provider: "none"},
          %{provider: "openai", lookback_days: 0},
          %{provider: "openai", lookback_days: 91},
          %{provider: "openai", max_sources: 0},
          %{provider: "openai", max_sources: 201},
          %{provider: "openai", min_confidence: "certain"},
          %{provider: "openai", system_prompt: String.duplicate("x", 4001)},
          %{provider: "openai", surprise: true},
          "openai"
        ] do
      assert {:error, _} = Surface.validate_payload(invalid)
    end
  end

  test "control snapshots meeting configuration and refuses provider none" do
    old = Application.fetch_env(:platform, :meetings_summary)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:platform, :meetings_summary, value)
        :error -> Application.delete_env(:platform, :meetings_summary)
      end
    end)

    Application.put_env(:platform, :meetings_summary, %{provider: :none})
    assert Surface.control_payload("meetings.brief_synthesis") == {:error, :not_configured}

    Application.put_env(:platform, :meetings_summary, %{provider: :openai, model: "meeting-model"})

    assert {:ok, %{"provider" => "openai", "model" => "meeting-model"}} =
             Surface.control_payload("meetings.brief_synthesis")
  end

  test "DB-backed synthesis prompt can be edited without reseeding over it" do
    PromptTemplates.seed_defaults()
    slug = "meetings.brief_synthesis.v1"
    template = PromptTemplates.get_template_by_slug(slug)
    assert template.content =~ "<meeting-finding"
    assert template.content =~ "<cite ref="

    assert {:ok, _} =
             PromptTemplates.update_template(template, %{content: "Install-specific instructions"})

    PromptTemplates.seed_defaults()
    assert {:ok, "Install-specific instructions"} = PromptTemplates.render_template(slug, %{})
  end
end
