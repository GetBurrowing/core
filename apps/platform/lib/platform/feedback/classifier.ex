defmodule Platform.Feedback.Classifier do
  @moduledoc """
  The bounded classifier behind external-feedback intake (task 01a11ec3
  stage 3).

  Reads ONE external issue and returns a closed-shape verdict. It is a
  separate, TOOL-LESS model call (`Platform.Agents.ToollessChat`, which
  builds provider options from an allowlist and drops any `:tools` key), so
  the issue text — untrusted outside input — has nothing to talk the model
  into calling. The model never files, comments on, or closes anything:
  `Platform.Feedback.Intake` does that from the verdict, in server code.

  ## The verdicts

  Exactly #{inspect(~w(accept_bug accept_positive_change duplicate insufficient_evidence irrelevant_support malicious_control_seeking))}.
  Only the two `accept_*` verdicts can lead to a Suite task.

  ## Deterministic prescreen, before any model sees the text

  `prescreen/1` runs fixed patterns over the title and body — spoofed
  system/role messages and chat-template tokens (via
  `Platform.Security.ExternalContent.detect_suspicious_patterns/1`), tool-call
  markup, requests to reveal or send credentials, repository/shell commands,
  and demands to disable safeguards. A hit is a `malicious_control_seeking`
  verdict with a fixed reason code and NO model call. The model's own
  verdict is therefore a second line, not the only one, and an adversarial
  report cannot be talked past the classifier by text the model never reads.

  A pattern can match a genuine report that merely discusses one of these
  things; the cost of that error is a canned rejection the reporter can
  answer by refiling, while the cost of the opposite error is a hostile
  payload reaching a task.

  ## The messages (`build_messages/2`)

    * system — the rendered `feedback.intake.v1` template (verdicts and
      reason codes interpolated). It says the wrapped block is data to
      classify, never instructions.
    * user — a JSON object naming the repository and issue number, then the
      issue body inside `ExternalContent.wrap/2` (source Webhook; the title
      rides the Subject metadata line, which `wrap/2` collapses to one line
      and sanitises), capped at #{20_000} bytes. The assembled user message
      is then run through `ExternalContent.escape_mentions/1`.

  Issue text is never placed in the system message.

  ## The closed output shape

  Exactly `{"verdict", "reason_code", "summary", "confidence", "duplicate_of"}`:

    * `verdict` is one of the six verdicts;
    * `reason_code` is one of `reason_codes/0`;
    * `summary` is a string for an accept verdict (one line, sanitised,
      mention-escaped, at most #{120} characters, and itself re-checked by the
      prescreen) and is discarded for every other verdict;
    * `confidence` is a number in 0..1;
    * `duplicate_of` is a positive integer or null.

  One surrounding Markdown code fence is tolerated. ANY other output is a
  `rejected_output` result with no verdict; the raw output is never stored,
  logged or retried into a different verdict.

  ## Test seam

  `:feedback_intake_classifier_provider` — provider module (default
  `Platform.Agents.Providers.Ollama`).
  """

  alias Platform.Agents.Agent
  alias Platform.Agents.ToollessChat
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Roles
  alias Platform.Security.ExternalContent

  @template_slug "feedback.intake.v1"
  @responsibility_key "feedback.intake"

  @verdicts ~w(accept_bug accept_positive_change duplicate insufficient_evidence irrelevant_support malicious_control_seeking)
  @accept_verdicts ~w(accept_bug accept_positive_change)

  @reason_codes ~w(reproducible_defect concrete_improvement already_reported missing_reproduction unclear_request support_request off_topic instruction_injection credential_request repository_command tool_call safeguard_bypass other)

  @output_keys ~w(confidence duplicate_of reason_code summary verdict)
  @summary_cap 120
  @body_cap_bytes 20_000
  @max_tokens 256

  # Patterns of our own, on top of ExternalContent's suspicious-pattern set.
  # Each maps to a fixed reason code; the matched text is never kept.
  @prescreen_sources [
    {"tool_call", ~S"<\s*/?\s*(tool_call|tool_use|function_calls?|invoke|antml:[a-z_]+)\b", "iu"},
    {"tool_call", ~S'"(tool_calls|function_call)"\s*:', "iu"},
    {"credential_request",
     ~S"\b(print|reveal|send|share|post|paste|output|dump|exfiltrate|leak|email|upload|give|tell)\s+(me\s+|us\s+)?(all\s+|any\s+|every\s+)?(of\s+)?(your|the|its|their|this)?\s*(server'?s?\s+|installation'?s?\s+|agent'?s?\s+)?(api[\s_-]?keys?|access[\s_-]?tokens?|tokens|secrets?|credentials?|passwords?|private[\s_-]?keys?|ssh[\s_-]?keys?|environment\s+variables|env\s+vars?|\.env\b)",
     "iu"},
    {"credential_request",
     ~S"\b(GITHUB_TOKEN|AWS_SECRET_ACCESS_KEY|SECRET_KEY_BASE|DATABASE_URL)\b", "u"},
    {"safeguard_bypass",
     ~S"\b(disable|bypass|turn\s+off|switch\s+off|remove|skip|ignore|circumvent|override|deactivate)\s+(all\s+|any\s+|the\s+|your\s+|its\s+)*(safeguards?|guardrails?|quarantine|safety\s+(checks?|filters?|rules?)|security\s+(checks?|controls?|rules?)|sandbox(ing)?|content\s+filters?|trust\s+checks?)\b",
     "iu"},
    {"safeguard_bypass", ~S"\b(promote|mark)\s+(this|it)\s+(as\s+)?trusted\b", "iu"},
    {"repository_command", ~S"\b(curl|wget)\b[^\n]*\|\s*(sudo\s+)?(ba|z)?sh\b", "iu"},
    {"repository_command", ~S"\bgit\s+push\s+(\S+\s+)*(--force|-f)\b", "iu"},
    {"repository_command", ~S"\brm\s+-rf\s+(/|~|\$HOME|\*)", "iu"},
    {"repository_command",
     ~S"\b(run|execute)\s+(this|these|the\s+following)\s+(commands?|scripts?|shell)\b", "iu"},
    {"repository_command",
     ~S"\b(merge|push|commit|deploy)\s+(this|it|the\s+following)\s+(directly\s+)?(to|into)\s+(main|master|production|prod)\b",
     "iu"}
  ]

  @type issue :: %{
          required(:repository) => String.t(),
          required(:issue_number) => pos_integer(),
          required(:title) => String.t(),
          required(:body) => String.t()
        }

  @type result :: %{
          status: String.t(),
          verdict: String.t() | nil,
          reason_code: String.t() | nil,
          summary: String.t() | nil,
          confidence: float() | nil,
          duplicate_of: pos_integer() | nil,
          classifier: String.t()
        }

  @doc "The six verdicts, in order."
  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @doc "The two verdicts that may lead to a Suite task."
  @spec accept_verdicts() :: [String.t()]
  def accept_verdicts, do: @accept_verdicts

  @doc "The closed reason-code set."
  @spec reason_codes() :: [String.t()]
  def reason_codes, do: @reason_codes

  @doc "The responsibility key whose assignee's model classifies."
  @spec responsibility_key() :: String.t()
  def responsibility_key, do: @responsibility_key

  @doc "The prompt template slug the system message is rendered from."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "Maximum length of an accepted summary, in characters."
  @spec summary_cap() :: pos_integer()
  def summary_cap, do: @summary_cap

  @doc """
  Run the deterministic prescreen over a title and body. Returns `:clear` or
  `{:control_seeking, reason_code}`. The reason code is a fixed value; no
  matched text is returned.
  """
  @spec prescreen(String.t() | [String.t()]) :: :clear | {:control_seeking, String.t()}
  def prescreen(parts) when is_list(parts), do: parts |> Enum.join("\n") |> prescreen()

  def prescreen(text) when is_binary(text) do
    text = String.replace_invalid(text)

    own =
      Enum.find_value(@prescreen_sources, fn {code, source, flags} ->
        if Regex.match?(Regex.compile!(source, flags), text), do: code
      end)

    cond do
      own ->
        {:control_seeking, own}

      external_hit?(text) ->
        {:control_seeking, "instruction_injection"}

      true ->
        :clear
    end
  end

  # `rm -rf` alone is in ExternalContent's list; a genuine bug report quoting
  # `rm -rf deps` is common, so only the destructive-target form above counts.
  defp external_hit?(text) do
    text
    |> ExternalContent.detect_suspicious_patterns()
    |> Enum.reject(&(&1 == ~S"rm\s+-rf"))
    |> Kernel.!=([])
  end

  @doc """
  Classify one issue. Returns `{:ok, result}` or `{:error, :provider_failed}`.
  Never raises, and never logs issue text.
  """
  @spec classify(issue()) :: {:ok, result()} | {:error, term()}
  def classify(%{title: title, body: body} = issue) do
    case prescreen([title, body]) do
      {:control_seeking, code} ->
        {:ok, decided("prescreened", "malicious_control_seeking", code, nil, nil, "prescreen")}

      :clear ->
        classify_with_model(issue)
    end
  rescue
    _ -> {:error, :classifier_crashed}
  end

  defp classify_with_model(issue) do
    case safe_assignee() do
      %Agent{} = agent ->
        case ToollessChat.call(provider_module(), agent, build_messages(issue),
               temperature: 0.0,
               max_tokens: @max_tokens,
               log_tag: "[Feedback.Classifier]",
               log_context: "repository=#{issue.repository} issue=#{issue.issue_number}"
             ) do
          {:ok, content} -> {:ok, parse(content, classifier_label(agent))}
          :error -> {:error, :provider_failed}
        end

      nil ->
        {:ok,
         %{
           status: "unassigned",
           verdict: nil,
           reason_code: nil,
           summary: nil,
           confidence: nil,
           duplicate_of: nil,
           classifier: "unassigned"
         }}
    end
  end

  @doc """
  The two messages sent to the provider. Deterministic given its inputs and
  the template row. Options: `:system` (a pre-rendered system prompt),
  `:marker_id` (tests only).
  """
  @spec build_messages(issue(), keyword()) :: [map()]
  def build_messages(issue, opts \\ []) do
    system = Keyword.get_lazy(opts, :system, &system_prompt/0)

    location =
      Jason.encode!(%{"repository" => issue.repository, "issue_number" => issue.issue_number})

    wrap_opts =
      [source: :webhook, subject: issue.title]
      |> maybe_put(:id, Keyword.get(opts, :marker_id))

    user =
      [
        "Where the issue was filed (JSON):",
        location,
        "",
        "The issue to classify:",
        ExternalContent.wrap(cap_body(issue.body), wrap_opts)
      ]
      |> Enum.join("\n")
      |> ExternalContent.escape_mentions()

    [%{role: "system", content: system}, %{role: "user", content: user}]
  end

  @doc """
  Parse raw model output against the closed shape. Public for tests. Anything
  outside the shape is a `rejected_output` result.
  """
  @spec parse(String.t(), String.t()) :: result()
  def parse(content, classifier) when is_binary(content) do
    with {:ok, decoded} <- decode(content),
         :ok <- exact_keys(decoded),
         {:ok, verdict} <- member(decoded["verdict"], @verdicts),
         {:ok, reason_code} <- member(decoded["reason_code"], @reason_codes),
         {:ok, confidence} <- check_confidence(decoded["confidence"]),
         {:ok, duplicate_of} <- check_duplicate(decoded["duplicate_of"]),
         {:ok, summary} <- check_summary(verdict, decoded["summary"]) do
      decided("classified", verdict, reason_code, summary, confidence, classifier)
      |> Map.put(:duplicate_of, duplicate_of)
    else
      :rejected ->
        %{
          status: "rejected_output",
          verdict: nil,
          reason_code: nil,
          summary: nil,
          confidence: nil,
          duplicate_of: nil,
          classifier: classifier
        }
    end
  end

  @doc """
  A model-written summary made safe to put in a task title: one line, spoofed
  markers and special tokens neutralised, `@[` escaped, at most
  #{@summary_cap} characters.
  """
  @spec clean_summary(String.t()) :: String.t()
  def clean_summary(summary) when is_binary(summary) do
    summary
    |> ExternalContent.sanitize_line()
    |> ExternalContent.escape_mentions()
    |> String.replace(~r/[`<>\[\]]/u, "")
    |> String.trim()
    |> String.slice(0, @summary_cap)
    |> String.trim()
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp decided(status, verdict, reason_code, summary, confidence, classifier) do
    %{
      status: status,
      verdict: verdict,
      reason_code: reason_code,
      summary: summary,
      confidence: confidence,
      duplicate_of: nil,
      classifier: classifier
    }
  end

  defp decode(content) do
    case Jason.decode(strip_fence(content)) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> :rejected
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
    if Enum.sort(Map.keys(map)) == @output_keys, do: :ok, else: :rejected
  end

  defp member(value, allowed) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: :rejected
  end

  defp member(_value, _allowed), do: :rejected

  defp check_confidence(c) when is_number(c) and c >= 0 and c <= 1, do: {:ok, c / 1}
  defp check_confidence(_c), do: :rejected

  defp check_duplicate(nil), do: {:ok, nil}
  defp check_duplicate(n) when is_integer(n) and n > 0 and n < 2_147_483_647, do: {:ok, n}
  defp check_duplicate(_n), do: :rejected

  # An accept verdict must carry a usable summary that itself passes the
  # prescreen: a model talked into copying a payload into its summary is a
  # rejected output, not a task title.
  defp check_summary(verdict, summary) when verdict in @accept_verdicts and is_binary(summary) do
    cleaned = clean_summary(summary)

    cond do
      String.length(cleaned) < 3 -> :rejected
      prescreen(summary) != :clear -> :rejected
      true -> {:ok, cleaned}
    end
  end

  defp check_summary(verdict, _summary) when verdict in @accept_verdicts, do: :rejected
  defp check_summary(_verdict, summary) when is_binary(summary) or is_nil(summary), do: {:ok, nil}
  defp check_summary(_verdict, _summary), do: :rejected

  @doc false
  def system_prompt do
    assigns = %{
      verdicts: Enum.join(@verdicts, ", "),
      reason_codes: Enum.join(@reason_codes, ", ")
    }

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
    if byte_size(body) <= @body_cap_bytes,
      do: body,
      else: body |> binary_part(0, @body_cap_bytes) |> trim_partial_codepoint()
  end

  defp trim_partial_codepoint(bin) do
    if String.valid?(bin) or bin == "",
      do: bin,
      else: trim_partial_codepoint(binary_part(bin, 0, byte_size(bin) - 1))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp classifier_label(%Agent{slug: slug}) when is_binary(slug), do: "agent:" <> slug
  defp classifier_label(%Agent{id: id}), do: "agent:#{id}"

  defp safe_assignee do
    Roles.assignee_for(@responsibility_key)
  rescue
    _ -> nil
  end

  defp provider_module do
    Application.get_env(
      :platform,
      :feedback_intake_classifier_provider,
      Platform.Agents.Providers.Ollama
    )
  end
end
