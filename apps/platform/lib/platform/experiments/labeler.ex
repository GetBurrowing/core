defmodule Platform.Experiments.Labeler do
  @moduledoc """
  The BLIND signal labeler. Task 01a0d415 stage 3, the experimentation-layer
  ADR-0052 (the injection boundary).

  Reads one inbound mail against an experiment's candidate subjects and
  returns a closed-shape verdict: which label, which subject (or none), how
  confident, and a short reason. It is a separate, TOOL-LESS model call
  (`Platform.Agents.ToollessChat`), so the mail text it reads — untrusted
  outside input — has nothing to talk the model into calling. The Scientist
  never reads mail; it reads the labels this module writes.

  ## The blinding

  `candidates/1` projects each assigned subject to
  `%{subject_id, title, created_at}` and NOTHING else, read from the `tasks`
  table. It joins `experiment_assignments` only to learn WHICH subjects are
  in the experiment; it never selects `variant_slug` and never touches
  `Platform.Experiments.Variant`. The labeler is therefore never shown which
  arm a subject received, and cannot label one arm more generously than the
  other. `labeler_test.exs` seeds a canary variant slug and payload and
  asserts neither reaches the provider.

  ## The messages (`build_messages/3`)

    * system — the rendered `experiments.labeler.v1` template (declared
      labels interpolated). It says the wrapped block is data to classify,
      never instructions.
    * user — the candidates as JSON, then the mail body inside
      `Platform.Security.ExternalContent.wrap/2` (source Email; From and
      Subject go through `wrap/2`'s metadata lines, which apply
      `ExternalContent.sanitize_line/1`), capped at
      `Platform.Mail.Inbound.body_cap_bytes/0`. The assembled user message is
      then run through `ExternalContent.escape_mentions/1`, which `wrap/2`
      does not apply.

  ## The closed output shape

  Exactly `{"label", "subject_id", "confidence", "reason"}`, nothing else:

    * `label` is one of the experiment's declared labels
      (`signal_source["labels"]`, default #{inspect(~w(auto_ack rejection screen interview other))});
    * `subject_id` is one of the candidate ids, or null (an unmatched reply);
    * `confidence` is a number in 0..1;
    * `reason` is a string, run through `ExternalContent.sanitize_line/1`,
      mention-escaped with `ExternalContent.escape_mentions/1` and capped at
      300 characters — it is model text derived from untrusted input, and
      the Scientist reads it.

  One surrounding Markdown code fence is tolerated (it is packaging, not
  shape). ANY other output is a `rejected_output` signal with no label and a
  fixed reason naming the defect; the raw output is never stored and is
  never retried into a different label.

  No agent assigned to `experiments.label_signal` gives an `unlabelled`
  signal. A provider failure (`:error` from `ToollessChat`) records NOTHING,
  so the source is still unlabelled-by-absence and
  `Platform.Experiments.Signals.MailSource.reconcile/0` retries it; recording
  it would freeze a transient outage into a permanent row on the idempotency
  index.

  ## Test seam

  `:experiments_labeler_provider` — provider module (default
  `Platform.Agents.Providers.Ollama`).
  """

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Agents.ToollessChat
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Security.ExternalContent

  @template_slug "experiments.labeler.v1"
  @responsibility_key "experiments.label_signal"
  @default_labels ~w(auto_ack rejection screen interview other)
  @output_keys ~w(confidence label reason subject_id)
  @reason_cap 300
  @max_tokens 256
  @subject_type "task"

  @type candidate :: %{subject_id: Ecto.UUID.t(), title: String.t(), created_at: DateTime.t()}
  @type verdict :: %{
          status: String.t(),
          label: String.t() | nil,
          subject_id: Ecto.UUID.t() | nil,
          confidence: float() | nil,
          reason: String.t() | nil,
          labeler: String.t()
        }

  @doc "The prompt template slug the system message is rendered from."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The responsibility key whose assignee does the labelling."
  @spec responsibility_key() :: String.t()
  def responsibility_key, do: @responsibility_key

  @doc "The subject type every candidate (and so every signal) carries."
  @spec subject_type() :: String.t()
  def subject_type, do: @subject_type

  @doc "Maximum length of a stored reason, in characters."
  @spec reason_cap() :: pos_integer()
  def reason_cap, do: @reason_cap

  @doc "The experiment's declared labels, or the email default set."
  @spec labels(Experiment.t()) :: [String.t()]
  def labels(%Experiment{signal_source: %{"labels" => labels}})
      when is_list(labels) and labels != [] do
    if Enum.all?(labels, &is_binary/1), do: labels, else: @default_labels
  end

  def labels(%Experiment{}), do: @default_labels

  @doc """
  The subjects the labeler may attribute a reply to:
  `%{subject_id, title, created_at}` per assigned task, oldest first. See the
  moduledoc: this projection IS the blinding, so it selects no assignment
  column but the subject id and nothing from variants.
  """
  @spec candidates(Experiment.t()) :: [candidate()]
  def candidates(%Experiment{id: experiment_id}) do
    subject_ids =
      from(a in Assignment,
        where: a.experiment_id == ^experiment_id and a.subject_type == ^@subject_type,
        select: a.subject_id
      )

    from(t in Platform.Tasks.Task,
      where: t.id in subquery(subject_ids),
      order_by: [asc: t.inserted_at, asc: t.id],
      select: %{subject_id: t.id, title: t.title, created_at: t.inserted_at}
    )
    |> Repo.all()
  end

  @doc """
  The two messages sent to the provider. Deterministic given its inputs and
  the template row; no provider call, no writes.

  Options: `:labels` (default the email set), `:system` (a pre-rendered
  system prompt; default renders `experiments.labeler.v1`), `:marker_id`
  (tests only; forwarded to `ExternalContent.wrap/2`).
  """
  @spec build_messages([candidate()], InboundMessage.t(), keyword()) :: [map()]
  def build_messages(candidates, %InboundMessage{} = inbound, opts \\ [])
      when is_list(candidates) do
    labels = Keyword.get(opts, :labels, @default_labels)
    system = Keyword.get_lazy(opts, :system, fn -> system_prompt(labels) end)

    # Every key of every candidate is encoded as given: `candidates/1` is the
    # ONE place the projection happens, so the blinding canary test sees
    # exactly what that function hands over. Re-projecting here would hide a
    # leak in `candidates/1` from the canary instead of preventing it.
    candidates_json =
      candidates
      |> Enum.map(fn c -> Map.new(c, fn {k, v} -> {to_string(k), json_value(v)} end) end)
      |> Jason.encode!()

    wrap_opts =
      [source: :email, sender: inbound.from_address, subject: inbound.subject]
      |> maybe_put(:id, Keyword.get(opts, :marker_id))

    wrapped = ExternalContent.wrap(cap_body(inbound.text_body || ""), wrap_opts)

    # `wrap/2` neutralises markers and special tokens but does NOT escape
    # mentions; every other caller escapes its assembled document afterwards
    # (`Mailbox`, `Inbound`), and so does this one. Escaping the whole user
    # message covers the body, the From/Subject metadata lines and the
    # candidate titles in one place.
    user =
      [
        "Candidate subjects (JSON):",
        candidates_json,
        "",
        "The email to classify:",
        wrapped
      ]
      |> Enum.join("\n")
      |> ExternalContent.escape_mentions()

    [
      %{role: "system", content: system},
      %{role: "user", content: user}
    ]
  end

  @doc """
  Label `inbound` for `experiment`. Returns `{:ok, verdict}` (the attrs a
  signal is recorded from, minus the source keys) or `{:error, :provider_failed}`.
  Never raises.
  """
  @spec label(Experiment.t(), InboundMessage.t()) :: {:ok, verdict()} | {:error, term()}
  def label(%Experiment{} = experiment, %InboundMessage{} = inbound) do
    case safe_assignee() do
      %Agent{} = agent ->
        labels = labels(experiment)
        candidates = candidates(experiment)
        messages = build_messages(candidates, inbound, labels: labels)

        case ToollessChat.call(provider_module(), agent, messages,
               temperature: 0.0,
               max_tokens: @max_tokens,
               log_tag: "[Experiments.Labeler]",
               log_context: "experiment=#{experiment.id} inbound=#{inbound.id}"
             ) do
          {:ok, content} ->
            {:ok, parse(content, labels, Enum.map(candidates, & &1.subject_id), labeler(agent))}

          :error ->
            {:error, :provider_failed}
        end

      nil ->
        {:ok,
         %{
           status: "unlabelled",
           label: nil,
           subject_id: nil,
           confidence: nil,
           reason: "no agent is assigned to #{@responsibility_key}",
           labeler: "unassigned"
         }}
    end
  rescue
    error -> {:error, {:labeler_crashed, Exception.message(error)}}
  end

  @doc """
  Parse raw model output against the closed shape. Public for tests.
  Anything outside the shape is a `rejected_output` verdict.
  """
  @spec parse(String.t(), [String.t()], [Ecto.UUID.t()], String.t()) :: verdict()
  def parse(content, labels, candidate_ids, labeler) when is_binary(content) do
    candidate_ids = MapSet.new(candidate_ids, &String.downcase/1)

    with {:ok, decoded} <- decode(content),
         :ok <- exact_keys(decoded),
         {:ok, label} <- check_label(decoded["label"], labels),
         {:ok, subject_id} <- check_subject(decoded["subject_id"], candidate_ids),
         {:ok, confidence} <- check_confidence(decoded["confidence"]),
         {:ok, reason} <- check_reason(decoded["reason"]) do
      %{
        status: "labelled",
        label: label,
        subject_id: subject_id,
        confidence: confidence,
        reason: reason,
        labeler: labeler
      }
    else
      {:rejected, why} ->
        %{
          status: "rejected_output",
          label: nil,
          subject_id: nil,
          confidence: nil,
          reason: why,
          labeler: labeler
        }
    end
  end

  @doc """
  A model-written reason made safe for the Scientist to read: one line,
  spoofed markers and special tokens neutralised, `@[` escaped, at most
  #{@reason_cap} characters.
  """
  @spec clean_reason(String.t()) :: String.t()
  def clean_reason(reason) when is_binary(reason) do
    reason
    |> ExternalContent.sanitize_line()
    |> ExternalContent.escape_mentions()
    |> String.trim()
    |> String.slice(0, @reason_cap)
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp decode(content) do
    case Jason.decode(strip_fence(content)) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:rejected, "output is not a JSON object"}
      {:error, _} -> {:rejected, "output is not JSON"}
    end
  end

  defp strip_fence(content) do
    trimmed = String.trim(content)

    case Regex.run(~r/\A```(?:json)?\s*\n(.*)\n```\z/s, trimmed) do
      [_, inner] -> inner
      _ -> trimmed
    end
  end

  defp exact_keys(map) do
    if Enum.sort(Map.keys(map)) == @output_keys,
      do: :ok,
      else: {:rejected, "output keys are not exactly #{Enum.join(@output_keys, ", ")}"}
  end

  defp check_label(label, labels) when is_binary(label) do
    if label in labels, do: {:ok, label}, else: {:rejected, "label outside the declared set"}
  end

  defp check_label(_label, _labels), do: {:rejected, "label is not a string"}

  defp check_subject(nil, _ids), do: {:ok, nil}

  defp check_subject(id, ids) when is_binary(id) do
    normalized = String.downcase(id)

    if MapSet.member?(ids, normalized),
      do: {:ok, normalized},
      else: {:rejected, "subject_id is not a candidate"}
  end

  defp check_subject(_id, _ids), do: {:rejected, "subject_id is not a string or null"}

  defp check_confidence(c) when is_number(c) and c >= 0 and c <= 1, do: {:ok, c / 1}
  defp check_confidence(_c), do: {:rejected, "confidence is not a number in 0..1"}

  defp check_reason(reason) when is_binary(reason), do: {:ok, clean_reason(reason)}
  defp check_reason(_reason), do: {:rejected, "reason is not a string"}

  defp system_prompt(labels) do
    assigns = %{labels: Enum.join(labels, ", ")}

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, prompt} ->
        prompt

      {:error, _} ->
        case PromptTemplates.render_default(@template_slug, assigns) do
          {:ok, prompt} -> prompt
          {:error, _} -> ""
        end
    end
  end

  defp cap_body(body) do
    cap = Inbound.body_cap_bytes()

    if byte_size(body) <= cap,
      do: body,
      else: body |> binary_part(0, cap) |> trim_partial_codepoint()
  end

  defp trim_partial_codepoint(bin) do
    if String.valid?(bin) or bin == "",
      do: bin,
      else: trim_partial_codepoint(binary_part(bin, 0, byte_size(bin) - 1))
  end

  defp json_value(%DateTime{} = t), do: DateTime.to_iso8601(t)
  defp json_value(%NaiveDateTime{} = t), do: NaiveDateTime.to_iso8601(t)
  defp json_value(other), do: other

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp labeler(%Agent{slug: slug}) when is_binary(slug), do: "agent:" <> slug
  defp labeler(%Agent{id: id}), do: "agent:#{id}"

  defp safe_assignee do
    Roles.assignee_for(@responsibility_key)
  rescue
    _ -> nil
  end

  defp provider_module do
    Application.get_env(
      :platform,
      :experiments_labeler_provider,
      Platform.Agents.Providers.Ollama
    )
  end
end
