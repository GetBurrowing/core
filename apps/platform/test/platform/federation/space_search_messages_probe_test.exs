defmodule Platform.Federation.SpaceSearchMessagesProbeTest do
  @moduledoc """
  Task 01a006c2 stage 4 — reproduction harness for the report that
  `space_search_messages` returned `[]` on a channel that demonstrably
  contained the search terms.

  The probe seeds one space with (a) ordinary-word content, (b) a UUID, and
  (c) punctuation-heavy content, then runs each class of query through both
  `Platform.Chat.search_messages/3` and
  `ToolSurface.execute("space_search_messages", ...)`, comparing the outcome
  against `space_get_messages` over the same space (which is the ground truth
  for "is the term present at all").
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  @uuid "01a006c2-6c88-7f15-86b6-828cb10f1642"

  setup do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "probe-#{System.unique_integer([:positive])}",
        name: "ProbeAgent",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert()

    {:ok, space} =
      Chat.create_space(%{
        name: "Probe Space",
        slug: "probe-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    for content <- [
          "Rowan asked about the deployment pipeline on 2026-08-15",
          "Task #{@uuid} is the federation gap ticket",
          "--- ??? !!! ---"
        ] do
      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: content
        })
    end

    %{
      space: space,
      context: %{agent_id: agent.id, agent_participant_id: participant.id}
    }
  end

  describe "step 1 — reproduce" do
    test "records which query classes return rows and which return []", ctx do
      {:ok, %{messages: all}} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      # Ground truth: every probe term below is literally present in the space.
      corpus = all |> Enum.map(& &1.content) |> Enum.join("\n")

      rows =
        for {label, query} <- [
              {"ordinary word", "Rowan"},
              {"ordinary phrase", "deployment pipeline"},
              {"date token", "2026-08-15"},
              {"uuid", @uuid},
              {"punctuation only", "--- ??? !!!"}
            ] do
          assert corpus =~ query or label in ["ordinary phrase", "punctuation only"],
                 "probe term #{inspect(query)} should be literally present in the corpus"

          ctx_count = length(Chat.search_messages(ctx.space.id, query, limit: 10))

          tool_result =
            ToolSurface.execute(
              "space_search_messages",
              %{"space_id" => ctx.space.id, "query" => query},
              ctx.context
            )

          tool_desc =
            case tool_result do
              {:ok, list} when is_list(list) -> "#{length(list)} rows"
              {:ok, %{no_searchable_terms: true}} -> "no_searchable_terms envelope"
              {:ok, other} -> inspect(other)
              {:error, e} -> "error #{inspect(e)}"
            end

          [label, query, ctx_count, tool_desc]
        end

      IO.puts("\n=== STEP 1 PROBE TABLE (space_get_messages returned #{length(all)} rows) ===")

      for [label, query, ctx_count, tool_desc] <- rows do
        IO.puts(
          String.pad_trailing(label, 20) <>
            String.pad_trailing(inspect(query), 42) <>
            "search_messages=#{ctx_count}  tool=#{tool_desc}"
        )
      end

      IO.puts("=== END STEP 1 PROBE TABLE ===\n")

      # The acceptance criterion: ordinary-word terms that space_get_messages
      # shows are present MUST be findable. This is the assertion that decides
      # reproduce vs non-reproduce.
      assert length(Chat.search_messages(ctx.space.id, "Rowan", limit: 10)) > 0
      assert length(Chat.search_messages(ctx.space.id, "deployment pipeline", limit: 10)) > 0
    end

    test "UUID and ISO-date terms tokenize and are findable — the report's terms were not the problem",
         ctx do
      assert [hit] = Chat.search_messages(ctx.space.id, @uuid, limit: 10)
      assert hit.content =~ @uuid

      assert [dated] = Chat.search_messages(ctx.space.id, "2026-08-15", limit: 10)
      assert dated.content =~ "2026-08-15"
    end
  end

  describe "step 3 — no_searchable_terms guard" do
    test "searchable_query?/1 separates real terms from empty-tsquery input" do
      assert Chat.searchable_query?("Rowan")
      assert Chat.searchable_query?(@uuid)
      assert Chat.searchable_query?("2026-08-15")

      refute Chat.searchable_query?("--- ??? !!!")
      refute Chat.searchable_query?("???")
      refute Chat.searchable_query?("   ")
      refute Chat.searchable_query?(nil)
    end

    # THE GUARD FIRING TRUE. Without this the flag is unobserved and proves
    # nothing.
    test "punctuation-only query returns the envelope with no_searchable_terms TRUE", ctx do
      {:ok, result} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => ctx.space.id, "query" => "--- ??? !!!"},
          ctx.context
        )

      assert is_map(result)
      refute is_list(result)
      assert result.no_searchable_terms == true
      assert result.results == []
      assert result.note =~ "no searchable terms"
      assert result.note =~ "space_get_messages"
    end

    # Stage 5 mutation M1 SURVIVED here: emptying the TOOL's read path
    # (`search_hits/3`) broke nothing, because every content assertion above
    # went through `Chat.search_messages/3` directly and the tool itself was
    # only ever asserted on the punctuation branch. That is shape-not-content —
    # the exact failure this ticket exists to close. These two assert the
    # tool's own hit path carries the matching row.
    test "the TOOL returns the matching row for an ordinary word, not just the context function",
         ctx do
      {:ok, results} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => ctx.space.id, "query" => "Rowan"},
          ctx.context
        )

      assert is_list(results)
      assert [hit] = results
      assert hit.content =~ "Rowan"
      assert hit.content =~ "deployment pipeline"
      assert hit.id
    end

    test "the TOOL returns the matching row for a UUID term", ctx do
      {:ok, results} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => ctx.space.id, "query" => @uuid},
          ctx.context
        )

      assert [hit] = results
      assert hit.content =~ @uuid
    end

    test "a genuine miss on real terms still returns a plain empty ARRAY, not the envelope",
         ctx do
      {:ok, result} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => ctx.space.id, "query" => "aardvark xylophone"},
          ctx.context
        )

      assert result == []
    end

    test "the guard does not leak across the authorization boundary" do
      {:ok, other_agent} =
        %Agent{}
        |> Agent.changeset(%{
          slug: "outsider-#{System.unique_integer([:positive])}",
          name: "Outsider",
          status: "active",
          max_concurrent: 1,
          sandbox_mode: "off",
          model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
        })
        |> Repo.insert()

      {:ok, closed} =
        Chat.create_space(%{
          name: "Closed",
          slug: "closed-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:error, error} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => closed.id, "query" => "--- ??? !!!"},
          %{agent_id: other_agent.id, agent_participant_id: Ecto.UUID.generate()}
        )

      assert error.error =~ "Access denied"
    end
  end
end
