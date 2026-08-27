defmodule Platform.Mix.Tasks.IntentEvalPrelabelTest do
  @moduledoc """
  The pre-labelling task must run a STRONG model, not the ~2B classifier under
  test (task `01a03fbb` stage 3). Both halves of that guard are exercised: it
  refuses the agent assigned to `meetings.intent_classify`, and it accepts any
  other agent. Only the refusal would be satisfied by an implementation that
  refuses everything.
  """
  use Platform.DataCase, async: false

  alias Mix.Tasks.Platform.IntentEval.Prelabel
  alias Platform.Agents.Agent
  alias Platform.Meetings.IntentEval
  alias Platform.Repo
  alias Platform.Roles

  describe "refuse_classifier!/1" do
    test "refuses the meetings.intent_classify assignee and accepts any other agent" do
      classifier = insert_agent!("tiny-classifier")
      strong = insert_agent!("strong-labeller")

      {:ok, _} = Roles.set_override("meetings.intent_classify", classifier.id)
      # Prove the setup actually took — otherwise the refusal below would be
      # testing an unassigned responsibility.
      assert %Agent{id: assigned} = Roles.assignee_for("meetings.intent_classify")
      assert assigned == classifier.id

      assert_raise Mix.Error, ~r/model under test/, fn ->
        Prelabel.refuse_classifier!(classifier)
      end

      # Positive control — same code path, different agent.
      assert :ok = Prelabel.refuse_classifier!(strong)
    end
  end

  describe "fetch_agent!/1" do
    test "resolves a slug and fails loudly on an unknown one" do
      agent = insert_agent!("resolvable")

      assert %Agent{id: id} = Prelabel.fetch_agent!("resolvable")
      assert id == agent.id

      assert_raise Mix.Error, ~r/no agent with slug/, fn ->
        Prelabel.fetch_agent!("no-such-agent")
      end
    end
  end

  describe "prelabel/4" do
    test "records label, confidence and rationale from the strong model" do
      agent = insert_agent!("strong")

      row =
        Prelabel.prelabel(
          %{"id" => "abc", "text" => "Designer, make it teal.", "prior" => []},
          agent,
          "2026-08-27T00:00:00Z",
          stub(
            {:ok,
             %{
               content:
                 Jason.encode!(%{
                   "label" => "visual_adjust",
                   "confidence" => 0.93,
                   "rationale" => "addressed to the designer role"
                 })
             }}
          )
        )

      assert row["label"] == "visual_adjust"
      assert row["confidence"] == 0.93
      assert row["rationale"] =~ "designer"
      assert row["agent_slug"] == "strong"
    end

    test "a model failure becomes an explicit null label, not a missing row" do
      # A row absent from the pre-labels is indistinguishable from a row
      # nobody looked at. Keep it, with no confidence, so `open_rows/2` routes
      # it to a human.
      agent = insert_agent!("strong")

      row =
        Prelabel.prelabel(
          %{"id" => "abc", "text" => "…", "prior" => []},
          agent,
          "2026-08-27T00:00:00Z",
          stub({:error, :timeout})
        )

      assert row["label"] == nil
      assert row["confidence"] == 0.0
      assert row["rationale"] =~ "pre-label failed"

      # And it does reach the open set.
      root = Path.join(System.tmp_dir!(), "prelabel_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)

      slice_path = IntentEval.slice_path(root, "sample")

      IntentEval.write_jsonl!(slice_path, nil, [
        %{
          "id" => "abc",
          "text" => "…",
          "label" => "off_topic",
          "slice" => "sample",
          "prior" => []
        }
      ])

      IntentEval.write_jsonl!(IntentEval.prelabels_path(root), nil, [row])

      IntentEval.write_manifest!(root, %{
        "slices" => [
          %{
            "name" => "sample",
            "file" => "slices/sample.jsonl",
            "sha256" => IntentEval.digest(slice_path)
          }
        ]
      })

      assert [%{"id" => "abc"}] = IntentEval.open_rows(root)
    end
  end

  defp stub(result) do
    Module.create(
      :"Elixir.PrelabelStub#{System.unique_integer([:positive])}",
      quote do
        def chat(_credentials, _messages, _opts), do: unquote(Macro.escape(result))
      end,
      Macro.Env.location(__ENV__)
    )
    |> elem(1)
  end

  defp insert_agent!(slug) do
    %Agent{}
    |> Agent.changeset(%{
      slug: slug,
      name: "Prelabel Test #{slug}",
      status: "active",
      kind: "native"
    })
    |> Repo.insert!()
  end
end
