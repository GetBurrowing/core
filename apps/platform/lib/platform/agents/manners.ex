defmodule Platform.Agents.Manners do
  @moduledoc """
  Shared rules every agent prompt carries, whatever path builds it.

  Today that is one rule, `handoff_rule/0`: when an agent finishes work a
  person asked for, or needs something from them, it tells that person
  directly (a DM or a mention), never "it's in your inbox".

  No single block reaches every agent, so each prompt builder includes the
  rule itself, through `handoff_rule/0` (a fixed frame) or `ensure/1`
  (content an operator or owner may have edited). `prompt_paths/0` lists
  those builders; `Platform.Agents.MannersTest` renders each one and scans
  `lib/` for prompt builders missing from the list, so a new path that does
  not carry the rule goes red.
  """

  @marker "## Handing work to a person"

  @handoff_rule """
  #{@marker}

  When you finish something a person asked for, or need something from them, tell them yourself: a DM, or a mention in the thread where they asked.

  - One line on why it matters to them, tied to what they asked for or are working toward.
  - One tap to act: the link, or a yes/no they can answer.
  - Never hand off with "it's in your inbox", "check your inbox" or "I've filed it". Something filed that nobody hears about is dropped.
  - If they're in a meeting or it's outside their hours, say it once when they're back. Don't repeat it.

  For example: "Sam, the pricing draft you asked for is ready. It answers the churn question. Approve? <link>"
  """

  @doc "The handoff rule, as a Markdown section."
  @spec handoff_rule() :: String.t()
  def handoff_rule, do: @handoff_rule

  @doc "The heading that marks the rule as present."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  `content` with the handoff rule appended, unless it already carries the
  rule's heading. Idempotent: `ensure(ensure(c)) == ensure(c)`. The
  content's trailing whitespace stays at the end.
  """
  @spec ensure(String.t()) :: String.t()
  def ensure(content) when is_binary(content) do
    if String.contains?(content, @marker) do
      content
    else
      # Keep the content's own trailing whitespace at the very end, so a
      # body with no final newline (the federation preamble) still has none.
      body = String.trim_trailing(content)
      tail = binary_part(content, byte_size(body), byte_size(content) - byte_size(body))
      rule = String.trim_trailing(@handoff_rule)

      if body == "", do: rule <> tail, else: body <> "\n\n" <> rule <> tail
    end
  end

  @doc """
  Every prompt builder that must carry the rule, as
  `{id, module, function_name}`.

    * `:native_seed` - the instructions file a new native agent is created with;
    * `:native_start` - the instructions file every native agent starts with
      (reaches agents whose stored file predates the rule);
    * `:burrow_seed` - the Burrow agent's seed, which inherits `:native_seed`;
    * `:built_in_chat` - the fixed frame of the built-in chat agent;
    * `:federation_preamble` - the preamble every `dispatch.*` template
      substitutes through its `federation_preamble` placeholder.
  """
  @spec prompt_paths() :: [{atom(), module(), atom()}]
  def prompt_paths do
    [
      {:native_seed, Platform.Agents.NativeAgents, :identity_template},
      {:native_start, Platform.Agents.NativeAgents, :start_files},
      {:burrow_seed, Platform.Agents.Burrow, :identity_template},
      {:built_in_chat, Platform.Agents.QuickAgent, :build_system_prompt},
      {:federation_preamble, Platform.Orchestration.PromptTemplates, :federation_preamble}
    ]
  end

  @doc """
  `content` with each `{marker, text}` block appended, in order, unless the
  content already carries that block's marker heading. Idempotent, and the
  content's trailing whitespace stays at the end, as with `ensure/1`.
  """
  @spec ensure(String.t(), [{String.t(), String.t()}]) :: String.t()
  def ensure(content, blocks) when is_binary(content) and is_list(blocks) do
    Enum.reduce(blocks, content, fn {marker, text}, acc ->
      if String.contains?(acc, marker), do: acc, else: append_block(acc, text)
    end)
  end

  defp append_block(content, text) do
    body = String.trim_trailing(content)
    tail = binary_part(content, byte_size(body), byte_size(content) - byte_size(body))
    block = String.trim_trailing(text)

    if body == "", do: block <> tail, else: body <> "\n\n" <> block <> tail
  end
end
