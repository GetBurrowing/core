defmodule Platform.Agents.VoiceCheck do
  @moduledoc """
  The banned phrases and shape checks for the voice an agent Burrow runs
  speaks in. Data only for now; the deterministic check that reads it
  arrives separately.

  The phrases are copied verbatim from the voice proposal's banned-phrase
  groups. They are NOT pasted into any prompt (listing a phrase to a model
  tends to make it say it); `Platform.Agents.VoiceBlock` carries the
  positive instructions instead.

  `default_banned/0` is the control arm's `"banned"` list on the
  `agents.voice_block` experiment surface, and it is also the SHADOW list
  every hit is counted against, whatever an arm carries, so an arm cannot
  win by shrinking its own list.

  `"Claude"`, `"Anthropic"` and `"ChatGPT"` are banned only as
  self-description ("I'm Claude", "as an Anthropic model"), not as words;
  the check treats `self_description_names/0` that way.

  The shape checks are counted, not matched, and are named atoms
  (`shape_checks/0`).
  """

  @groups [
    openers_and_reactions: [
      "Great question",
      "Great!",
      "Lovely!",
      "Perfect!",
      "Absolutely",
      "Certainly",
      "Of course!",
      "Sure thing",
      "Awesome",
      "No worries",
      "Exciting!"
    ],
    assistant_self_talk: [
      "I'd be happy to",
      "Happy to help",
      "I'm here to help",
      "How can I help you today",
      "As an AI",
      "I'm just an AI",
      "AI assistant",
      "language model",
      "Claude",
      "Anthropic",
      "ChatGPT"
    ],
    closers: [
      "Let me know if you have any questions",
      "Is there anything else",
      "Feel free to",
      "Don't hesitate to",
      "Hope this helps",
      "Just let me know"
    ],
    therapy_and_apology: [
      "It sounds like",
      "I hear you",
      "I understand your concern",
      "That's completely valid",
      "I apologize for any inconvenience",
      "Sorry for the confusion",
      "Rest assured"
    ],
    brochure_words: [
      "Let's dive in",
      "Let's get started",
      "delve",
      "journey",
      "seamless",
      "robust",
      "leverage",
      "empower",
      "unlock",
      "elevate",
      "tailored",
      "game-changer",
      "It's worth noting",
      "That said"
    ]
  ]

  @self_description_names ["Claude", "Anthropic", "ChatGPT"]

  # The proposal's sixth group, "Shape checks (counted, not matched)":
  #   :em_dash                    - the em dash character (U+2014)
  #   :multiple_exclamations      - more than one "!" per reply
  #   :consecutive_question_end   - ends on "?" on two turns in a row
  #   :structure_in_short_reply   - bullets or headings in a reply under 80 words
  @shape_checks [
    :em_dash,
    :multiple_exclamations,
    :consecutive_question_end,
    :structure_in_short_reply
  ]

  @doc "The five phrase groups, in the proposal's order, as `{group, phrases}`."
  @spec groups() :: [{atom(), [String.t()]}]
  def groups, do: @groups

  @doc "Every banned phrase, flattened in group order. The control and shadow list."
  @spec default_banned() :: [String.t()]
  def default_banned, do: Enum.flat_map(@groups, fn {_group, phrases} -> phrases end)

  @doc "The names banned only as self-description."
  @spec self_description_names() :: [String.t()]
  def self_description_names, do: @self_description_names

  @doc "The four shape checks, as named atoms."
  @spec shape_checks() :: [atom()]
  def shape_checks, do: @shape_checks
end
