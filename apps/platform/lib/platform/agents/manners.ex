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

  ## Blocks (task 01a1b6ff)

  A second shared section rides the same paths: the voice block
  (`voice_block/0`, the text in `Platform.Agents.VoiceBlock`). `blocks/0`
  lists both as `{marker, text}`, `ensure/2` inserts each one whose marker
  heading is absent, and `blocks_for/1` says which markers each
  `prompt_paths/0` entry carries:

    * `:native_start` and `:built_in_chat` carry the handoff rule and the
      voice block. Both are generated at the moment the prompt is assembled,
      so the voice block is never stored.
    * `:native_seed` and `:burrow_seed` (the stored seeds) carry the handoff
      rule only; the voice block arrives at start.
    * `:federation_preamble` carries the handoff rule only. Federated
      runtimes are not Burrow-run agents, and a dispatch preamble is task
      work, not conversation.

  Still pure: no Repo, no Experiments. The voice block is an experiment
  surface (`agents.voice_block`); a call site resolves it for its agent and
  passes the text in (`blocks/1`, `blocks_for/2`).
  """

  alias Platform.Agents.VoiceBlock

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

  @doc "The control voice block (`Platform.Agents.VoiceBlock.text/0`)."
  @spec voice_block() :: String.t()
  def voice_block, do: VoiceBlock.text()

  @doc "The shared blocks, as `{marker, text}`: the handoff rule, then the control voice block."
  @spec blocks() :: [{String.t(), String.t()}]
  def blocks, do: blocks(voice_block())

  @doc """
  The shared blocks with `voice_text` (an experiment arm's block, resolved
  by the caller) in place of the control voice block.
  """
  @spec blocks(String.t()) :: [{String.t(), String.t()}]
  def blocks(voice_text) when is_binary(voice_text),
    do: [{@marker, @handoff_rule}, {VoiceBlock.marker(), voice_text}]

  @doc """
  The markers a `prompt_paths/0` id must carry. See the moduledoc for why
  the seeds and the federation preamble carry the handoff rule only.
  """
  @spec blocks_for(atom()) :: [String.t()]
  def blocks_for(path_id) when path_id in [:native_start, :built_in_chat],
    do: [@marker, VoiceBlock.marker()]

  def blocks_for(path_id) when path_id in [:native_seed, :burrow_seed, :federation_preamble],
    do: [@marker]

  @doc "`blocks/1` filtered to the markers `blocks_for/1` names for `path_id`."
  @spec blocks_for(atom(), String.t()) :: [{String.t(), String.t()}]
  def blocks_for(path_id, voice_text) do
    markers = blocks_for(path_id)
    Enum.filter(blocks(voice_text), fn {marker, _text} -> marker in markers end)
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
