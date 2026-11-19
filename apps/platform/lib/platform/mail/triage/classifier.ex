defmodule Platform.Mail.Triage.Classifier do
  @moduledoc """
  The mail triage classifier (task 01a1f426 stage 1): does this one inbound
  email need its reader? A deterministic pre-filter first, then, only when
  the pre-filter has no answer, ONE tool-less model call.

  ## The injection boundary

  The model call goes through `Platform.Agents.ToollessChat.call/4` with no
  tools, so the email (untrusted outside input) has nothing to talk the
  model into calling. It is the same boundary as the other tool-less mail
  and issue classifiers on the platform:

    * system — the rendered `mail.triage.classify.v1` template. It says the
      wrapped block is data to classify, never instructions;
    * user — the reader context as JSON (booleans, counts and a relation
      keyword from `Platform.Mail.Triage.Context.model_facts/1`, no ids, no
      text), then the body inside `Platform.Security.ExternalContent.wrap/2`
      (source Email; From and Subject ride `wrap/2`'s metadata lines, which
      apply `sanitize_line/1`), capped at
      `Platform.Mail.Inbound.body_cap_bytes/0`. The assembled user message
      then goes through `ExternalContent.escape_mentions/1`, which `wrap/2`
      does not apply.

  ## The pre-filter (`prefilter/2`, no model call)

  Read from the message's own `raw` headers and the reader's feedback:

    * `List-Unsubscribe` present → `promo`, `rule:list_unsubscribe`;
    * `Precedence: bulk | list | junk` → `promo`, `rule:precedence_bulk`;
    * a noreply / notifications local part → `routine`, `rule:noreply_sender`;
    * two or more `not_important` verdicts from this reader for the sender's
      domain, the latest verdict among them → `routine`,
      `rule:feedback_not_important`.

  None of them applies when the reader is waiting on this sender's reply
  (`waiting_on`), and the header rules do not apply when the reader's latest
  verdict on the sender is `missed`: both go to the model.

  ## The closed output shape

  Exactly `{"tier", "needs", "why", "next_step"}`, nothing else: `tier` in
  top|action|routine|promo, `needs` in reply|decision|plan|none, `why` a
  non-empty string (made one line by `ExternalContent.sanitize_line/1`,
  mention-escaped, capped at 160 characters), `next_step` a string (same
  cleaning) or null. One surrounding Markdown code fence is tolerated. ANY
  other output is `{:rejected, defect}` where `defect` is a fixed string
  naming what was wrong: the raw output is never stored or logged.

  A provider failure is `:error`: the caller stores nothing, so the next run
  retries it.

  ## Floors (`apply_floors/2`, after the model)

  A reply we were waiting on is at least `action` (and `top` when the model
  says `top`). A sender the reader said was `missed` is at least `action`.

  ## Test seam

  `:mail_triage_provider` — provider module (default
  `Platform.Agents.Providers.Ollama`).
  """

  alias Platform.Agents.Agent
  alias Platform.Agents.ToollessChat
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Mail.Triage.{Context, Item}
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Security.ExternalContent

  @template_slug "mail.triage.classify.v1"
  @template_version "v1"
  @output_keys ~w(needs next_step tier why)
  @max_tokens 256
  @header_scan_bytes 65_536

  @noreply_local ~r/\A(no[-_.]?reply|do[-_.]?not[-_.]?reply|notifications?|notify|mailer-daemon|postmaster|bounces?)([+-].*)?\z/

  @type verdict :: %{
          tier: String.t(),
          needs: String.t(),
          why: String.t(),
          next_step: String.t() | nil
        }

  @doc "The prompt template slug the system message is rendered from."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "`agent:<slug>@<template version>` for a model verdict by `agent`."
  @spec classifier_label(Agent.t()) :: String.t()
  def classifier_label(%Agent{slug: slug}) when is_binary(slug),
    do: "agent:#{slug}@#{@template_version}"

  def classifier_label(%Agent{id: id}), do: "agent:#{id}@#{@template_version}"

  @doc """
  The deterministic answer, if there is one: `{:rule, tier, rule_name}` or
  `:model`. See the moduledoc for the rules and their exceptions.
  """
  @spec prefilter(InboundMessage.t(), Context.t()) :: {:rule, String.t(), String.t()} | :model
  def prefilter(%InboundMessage{} = inbound, ctx) do
    cond do
      ctx.waiting_on ->
        :model

      Context.demoted?(ctx) ->
        {:rule, "routine", "feedback_not_important"}

      Context.missed?(ctx) ->
        :model

      true ->
        header_rule(inbound, ctx)
    end
  end

  defp header_rule(inbound, ctx) do
    headers = headers(inbound.raw)
    local = Context.local_part(ctx.address)

    cond do
      Map.has_key?(headers, "list-unsubscribe") ->
        {:rule, "promo", "list_unsubscribe"}

      precedence_bulk?(headers["precedence"]) ->
        {:rule, "promo", "precedence_bulk"}

      is_binary(local) and Regex.match?(@noreply_local, local) ->
        {:rule, "routine", "noreply_sender"}

      true ->
        :model
    end
  end

  defp precedence_bulk?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ~w(bulk list junk)

  defp precedence_bulk?(_), do: false

  @doc """
  The header block of a raw RFC 5322 message as `%{lower-cased name => value}`
  (first occurrence wins, folded lines unfolded). Reads at most the first
  #{@header_scan_bytes} bytes and never the body.
  """
  @spec headers(binary() | nil) :: %{String.t() => String.t()}
  def headers(raw) when is_binary(raw) do
    head = binary_part(raw, 0, min(byte_size(raw), @header_scan_bytes))

    block =
      case :binary.match(head, ["\r\n\r\n", "\n\n"]) do
        {pos, _len} -> binary_part(head, 0, pos)
        :nomatch -> head
      end

    block
    |> String.replace(~r/\r?\n[ \t]+/, " ")
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [name, value] when name != "" ->
          key = name |> String.trim() |> String.downcase()
          if String.contains?(key, " "), do: acc, else: Map.put_new(acc, key, String.trim(value))

        _ ->
          acc
      end
    end)
  end

  def headers(_raw), do: %{}

  @doc """
  The two messages sent to the provider. Deterministic given its inputs
  and the template row. Options: `:system` (pre-rendered), `:marker_id`
  (tests only; forwarded to `ExternalContent.wrap/2`).
  """
  @spec build_messages(InboundMessage.t(), Context.t(), keyword()) :: [map()]
  def build_messages(%InboundMessage{} = inbound, ctx, opts \\ []) do
    system = Keyword.get_lazy(opts, :system, &system_prompt/0)

    wrap_opts =
      [source: :email, sender: inbound.from_address, subject: inbound.subject]
      |> maybe_put(:id, Keyword.get(opts, :marker_id))

    wrapped = ExternalContent.wrap(cap_body(inbound.text_body || ""), wrap_opts)

    user =
      [
        "What we know about this sender, for this reader (JSON):",
        Jason.encode!(Context.model_facts(ctx)),
        "",
        "The email to triage:",
        wrapped
      ]
      |> Enum.join("\n")
      |> ExternalContent.escape_mentions()

    [%{role: "system", content: system}, %{role: "user", content: user}]
  end

  @doc """
  Classify `inbound` with `agent`: `{:ok, verdict}` (floors applied),
  `{:rejected, defect}` or `:error` (provider failure). Never raises.
  """
  @spec classify(Agent.t(), InboundMessage.t(), Context.t()) ::
          {:ok, verdict()} | {:rejected, String.t()} | :error
  def classify(%Agent{} = agent, %InboundMessage{} = inbound, ctx) do
    messages = build_messages(inbound, ctx)

    case ToollessChat.call(provider_module(), agent, messages,
           temperature: 0.0,
           max_tokens: @max_tokens,
           log_tag: "[Mail.Triage.Classifier]",
           log_context: "inbound=#{inbound.id}"
         ) do
      {:ok, content} ->
        case parse(content) do
          {:ok, verdict} -> {:ok, apply_floors(verdict, ctx)}
          {:rejected, defect} -> {:rejected, defect}
        end

      :error ->
        :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Parse raw model output against the closed shape. Public for tests.
  """
  @spec parse(String.t()) :: {:ok, verdict()} | {:rejected, String.t()}
  def parse(content) when is_binary(content) do
    with {:ok, decoded} <- decode(content),
         :ok <- exact_keys(decoded),
         {:ok, tier} <- one_of(decoded["tier"], Item.tiers(), "tier"),
         {:ok, needs} <- one_of(decoded["needs"], Item.needs(), "needs"),
         {:ok, why} <- why(decoded["why"]),
         {:ok, next_step} <- next_step(decoded["next_step"]) do
      {:ok, %{tier: tier, needs: needs, why: why, next_step: next_step}}
    end
  end

  def parse(_content), do: {:rejected, "output is not a string"}

  @doc "Raise `verdict.tier` to the floors the context sets (see the moduledoc)."
  @spec apply_floors(verdict(), Context.t()) :: verdict()
  def apply_floors(verdict, ctx) do
    if ctx.waiting_on || Context.missed?(ctx),
      do: %{verdict | tier: at_least(verdict.tier, "action")},
      else: verdict
  end

  @doc "The more important of `tier` and `floor`."
  @spec at_least(String.t(), String.t()) :: String.t()
  def at_least(tier, floor) do
    if rank(tier) < rank(floor), do: tier, else: floor
  end

  defp rank(tier), do: Enum.find_index(Item.tiers(), &(&1 == tier)) || length(Item.tiers())

  @doc """
  A model-written line made safe to show: one line, spoofed markers and
  special tokens neutralised, mentions escaped, at most 160 characters.
  """
  @spec clean_line(String.t()) :: String.t()
  def clean_line(value) when is_binary(value) do
    value
    |> ExternalContent.sanitize_line()
    |> ExternalContent.escape_mentions()
    |> String.trim()
    |> String.slice(0, Item.why_cap())
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

  defp one_of(value, allowed, name) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: {:rejected, "#{name} outside the allowed set"}
  end

  defp one_of(_value, _allowed, name), do: {:rejected, "#{name} is not a string"}

  defp why(value) when is_binary(value) do
    case clean_line(value) do
      "" -> {:rejected, "why is empty"}
      line -> {:ok, line}
    end
  end

  defp why(_value), do: {:rejected, "why is not a string"}

  defp next_step(nil), do: {:ok, nil}

  defp next_step(value) when is_binary(value) do
    case clean_line(value) do
      "" -> {:ok, nil}
      line -> {:ok, line}
    end
  end

  defp next_step(_value), do: {:rejected, "next_step is not a string or null"}

  defp system_prompt do
    case PromptTemplates.render_template(@template_slug, %{}) do
      {:ok, prompt} ->
        prompt

      {:error, _} ->
        case PromptTemplates.render_default(@template_slug, %{}) do
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp provider_module do
    Application.get_env(:platform, :mail_triage_provider, Platform.Agents.Providers.Ollama)
  end
end
