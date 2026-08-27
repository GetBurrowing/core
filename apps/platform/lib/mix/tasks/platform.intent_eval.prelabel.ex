defmodule Mix.Tasks.Platform.IntentEval.Prelabel do
  @moduledoc """
  Pre-label evaluation candidates with a STRONG model (task `01a03fbb` stage 3).

      mix platform.intent_eval.prelabel \\
        --in priv/intent_eval/candidates.jsonl \\
        --out priv/intent_eval/prelabels.jsonl \\
        --agent <slug>

  ## The pre-labeller is not the classifier

  `--agent` names a row in the `agents` table and its `base_url`/`model` is
  what gets called. It must NOT be the agent assigned to
  `meetings.intent_classify` — that is the ~2B model under test, and asking it
  to pre-label its own benchmark produces a set that agrees with it by
  construction and measures nothing. The task refuses that agent outright, and
  writes the slug it DID use into `manifest.json` so a later reader can see
  which model's opinion is baked into the open set.

  Output is one JSON object per candidate:

      {"id": .., "text": .., "label": .., "confidence": .., "rationale": ..,
       "agent_slug": .., "model": .., "prelabelled_at": ..}

  A candidate the model fails on is written with `label: null` and
  `confidence: 0.0` rather than dropped — a row missing from the pre-labels is
  indistinguishable from a row nobody looked at, and both must reach a human.
  Any row with no numeric confidence lands in the open set regardless.
  """

  use Mix.Task

  alias Platform.Agents.Agent
  alias Platform.Meetings.IntentEval
  alias Platform.Repo
  alias Platform.Roles

  @shortdoc "Pre-label intent-eval candidates with a strong model"

  @classifier_responsibility "meetings.intent_classify"

  @switches [in: :string, out: :string, agent: :string, root: :string, limit: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    slug = parsed[:agent] || Mix.raise("--agent <slug> is required")
    root = IntentEval.root(Keyword.take(parsed, [:root]))
    input = parsed[:in] || Path.join(root, "candidates.jsonl")
    output = parsed[:out] || IntentEval.prelabels_path(root)

    agent = fetch_agent!(slug)
    refuse_classifier!(agent)

    {_header, candidates} = IntentEval.read_jsonl(input)
    candidates = maybe_limit(candidates, parsed[:limit])

    at = DateTime.utc_now() |> DateTime.to_iso8601()
    rows = Enum.map(candidates, &prelabel(&1, agent, at))

    IntentEval.write_jsonl!(
      output,
      %{
        "header" => true,
        "kind" => "prelabels",
        "agent_slug" => agent.slug,
        "model" => agent.model,
        "count" => length(rows),
        "at" => at
      },
      rows
    )

    record_in_manifest(root, agent, at, length(rows))

    Mix.shell().info(
      "INTENT_EVAL_PRELABEL out=#{output} rows=#{length(rows)} agent=#{agent.slug} " <>
        "model=#{agent.model}"
    )

    :ok
  end

  defp maybe_limit(rows, nil), do: rows
  defp maybe_limit(rows, limit), do: Enum.take(rows, limit)

  @doc "Resolve the pre-labelling agent by slug, or fail loudly."
  def fetch_agent!(slug) do
    case Repo.get_by(Agent, slug: slug) do
      nil -> Mix.raise("no agent with slug #{inspect(slug)}")
      agent -> agent
    end
  end

  @doc """
  Refuse the agent currently assigned to `meetings.intent_classify`. Exposed so
  a test can exercise the refusal without a live model behind it.
  """
  def refuse_classifier!(agent) do
    classifier_id =
      case Roles.assignee_for(@classifier_responsibility) do
        %{id: id} -> id
        _ -> nil
      end

    if not is_nil(classifier_id) and classifier_id == agent.id do
      Mix.raise(
        "agent #{agent.slug} is the #{@classifier_responsibility} assignee — that is the " <>
          "model under test. Pre-labelling must use a larger, different model."
      )
    end

    :ok
  end

  @doc """
  Pre-label one candidate. Failures become an explicit null label rather than a
  missing row, so nothing silently escapes review.
  """
  def prelabel(candidate, agent, at, provider_module \\ Platform.Agents.Providers.Ollama) do
    base = %{
      "id" => candidate["id"],
      "text" => candidate["text"],
      "prior" => candidate["prior"] || [],
      "agent_slug" => agent.slug,
      "model" => agent.model,
      "prelabelled_at" => at
    }

    case ask(provider_module, agent, candidate) do
      {:ok, %{"label" => label} = decoded} ->
        Map.merge(base, %{
          "label" => label,
          "confidence" => confidence(decoded["confidence"]),
          "rationale" => to_string(decoded["rationale"] || "")
        })

      {:error, reason} ->
        Map.merge(base, %{
          "label" => nil,
          "confidence" => 0.0,
          "rationale" => "pre-label failed: #{inspect(reason)}"
        })
    end
  end

  defp confidence(value) when is_number(value), do: value * 1.0
  defp confidence(_), do: 0.0

  defp ask(provider_module, agent, candidate) do
    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: user_prompt(candidate)}
    ]

    opts =
      [base_url: agent.base_url, model: agent.model, temperature: 0.0, max_tokens: 512]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    credentials =
      case agent.vault_key do
        key when is_binary(key) and key != "" -> %{api_key: key}
        _ -> %{}
      end

    with {:ok, result} <- provider_module.chat(credentials, messages, opts),
         {:ok, content} <- content(result),
         {:ok, decoded} <- Jason.decode(content) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  end

  defp content(%{content: content}) when is_binary(content), do: {:ok, content}
  defp content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp content(other), do: {:error, {:unexpected_shape, other}}

  @doc false
  def system_prompt do
    """
    You are labelling utterances from a meeting transcript for an intent
    classifier's evaluation set. Answer with a single JSON object and nothing
    else:

      {"label": "<intent name or off_topic>", "confidence": <0.0-1.0>, "rationale": "<one sentence>"}

    Use "off_topic" when the utterance is not an addressed request to an agent —
    disfluent chatter, an aside, a half-abandoned sentence, or a request aimed at
    a person rather than a role. Otherwise name the intent the speaker is asking
    an agent to act on. Be conservative: a low confidence is far more useful than
    a confident guess, because low-confidence rows are routed to a human.
    """
  end

  @doc false
  def user_prompt(candidate) do
    prior =
      (candidate["prior"] || [])
      |> Enum.map(fn
        %{"text" => text} -> text
        other when is_binary(other) -> other
        other -> inspect(other)
      end)
      |> Enum.join("\n")

    """
    Preceding utterances:
    #{prior}

    Utterance to label:
    #{candidate["text"]}
    """
  end

  defp record_in_manifest(root, agent, at, count) do
    if File.exists?(IntentEval.manifest_path(root)) do
      manifest = IntentEval.read_manifest!(root)

      prelabel =
        manifest
        |> Map.get("prelabel", %{})
        |> Map.merge(%{
          "run" => true,
          "agent_slug" => agent.slug,
          "model" => agent.model,
          "at" => at,
          "count" => count
        })

      IntentEval.write_manifest!(root, Map.put(manifest, "prelabel", prelabel))
    end
  end
end
