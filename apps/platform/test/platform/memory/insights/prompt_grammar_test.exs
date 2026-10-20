defmodule Platform.Memory.Insights.PromptGrammarTest do
  @moduledoc """
  Task 01a13867 stage 4: the dreaming prompt's `source` grammar agrees with
  `Platform.Memory.Insights.Grounding`.

  The refs are read OUT OF THE PROMPT TEXT, so the test is about what the
  model is told to write. Mutation probe (grammar): put the stage-1 sentence
  (`query:<memory_search query>`) back into `@dreaming_content` and the
  first test goes red, because the prompt then names no citable query.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Grounding
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Org.Wiki
  alias Platform.Repo

  @journal "org/journal/2026-10-18.md"

  setup do
    _root = acme_org_id()
    :ok
  end

  defp descriptor, do: PromptTemplates.default_content_for_slug("historian.dreaming")

  # Every concrete `query:` ref the prompt spells in backticks. A placeholder
  # (`query:<name>`) is an instruction, not a ref, so it is not counted.
  defp prompt_query_refs do
    ~r/`(query:[^`<>\s]+)`/
    |> Regex.scan(descriptor(), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  test "a source line written as the prompt instructs grounds a page_edit and is not downgraded" do
    refs = prompt_query_refs()
    assert refs != [], "the dreaming prompt names no citable query: ref"

    for ref <- refs do
      Repo.delete_all(Insight)
      target = "org/page/agents-#{System.unique_integer([:positive])}.md"
      {:ok, _} = Wiki.upsert_page(target, %{content: "Agents: Pixel, Scout."})

      content =
        ~s(<synthesis-insight action="page_edit" confidence="high" evidence="#{ref}" source="#{ref}" target="#{target}">
      Scout has not connected in 60 days.
      <old>Pixel, Scout.</old><new>Pixel.</new>
      </synthesis-insight>)

      assert {:ok, 1} = Insights.ingest_from_journal(nil, @journal, content, nil)
      assert [%Insight{} = insight] = Repo.all(Insight)
      assert insight.action_type == "page_edit", "#{ref} was downgraded"
      assert insight.downgraded_from == nil
      assert insight.source_ref == ref
    end
  end

  test "every named grounding query is spelled in the prompt, and the free-text form is gone" do
    for name <- Grounding.queries() do
      assert ("query:" <> name) in prompt_query_refs()
    end

    refute descriptor() =~ "query:<memory_search"
    # Free-text search evidence is pointed at refs that do ground.
    assert descriptor() =~ "`page:<path>` or `journal:<path>`), never the search text"
  end

  test "both dreaming slugs carry the same grammar" do
    assert PromptTemplates.default_content_for_slug("memory.dreaming.v1") == descriptor()
  end
end
