defmodule Platform.Meetings.ScribeMisfireCorpus do
  @moduledoc """
  A SYNTHETIC corpus for the scribe misfire rate (task `01a0e58f`,
  acceptance 5), consumed by `scribe_misfire_rate_test.exs`.

  ## What this is, and what it is not

  Every row is synthesised. The shapes were filed from the 2026-09-14
  one-to-one: a commitment verb, a deadline and a named owner, in a
  register that is not a request. Nothing here is taken from a
  transcript, and every name is invented. The only real specimens are
  the two the ticket allows: "Write my strategy" and "Is this a demo?
  No, this is the…".

  It is NOT a production measurement. The rate test drives it through an
  ALWAYS-FIRE stub model, so the number it prints measures the
  deterministic gates (frames, addressee, privacy floor, near-miss) in
  the worst case, not the classifier.

  ## Row shape

  `{shape, intent_the_model_misfires_to, text}`. `negatives/0` is 7
  shapes x 5 rows. `causes/0` is the three causes the task names, one
  row each. `positives/0` are genuine asks that must survive.
  `privacy/0` are candid rows the floor must refuse.

  Every row was read against one question: would this be damaging if the
  person it is about read it? Rows about named people are about work
  logistics only; the candid register lives in `privacy/0`, where the
  point of the row is that it must never be dispatched.
  """

  @type row :: {atom(), String.t(), String.t()}

  @shapes [
    :pseudo_cleft,
    :embedded_wh,
    :tag_question,
    :hypothetical_conditional,
    :imperative,
    :fragment,
    :quotation_as_modifier
  ]

  @negatives [
    # A pseudo-cleft names a need; it assigns nobody.
    {:pseudo_cleft, "action_items", "What we need is someone to own the release notes"},
    {:pseudo_cleft, "action_items", "What I'd argue is we log an action item for the retro"},
    {:pseudo_cleft, "action_items", "What Tobias wants is the deck by Friday"},
    {:pseudo_cleft, "brief_worthy", "What worries me is the demo slipping again"},
    {:pseudo_cleft, "action_items", "All I'm saying is somebody should chase the vendor"},
    # An embedded wh-clause reports uncertainty; it asks nobody.
    {:embedded_wh, "open_question", "I wonder whether the action items are even current"},
    {:embedded_wh, "open_question", "I'm not sure who owns the retro notes"},
    {:embedded_wh, "action_items", "Do you know if Kasia sent the invite"},
    {:embedded_wh, "open_question", "I don't know whether this is an open question anymore"},
    {:embedded_wh, "brief_worthy", "Nobody knows when the migration ships"},
    # A tag question seeks agreement with something already said.
    {:tag_question, "action_items", "We said we'd ship by Friday, didn't we?"},
    {:tag_question, "action_items", "Dana's got the deck, hasn't she?"},
    {:tag_question, "action_items", "That's an action item, isn't it?"},
    {:tag_question, "brief_worthy", "The retro is Thursday, right?"},
    {:tag_question, "action_items", "Marcus owns the runbook, doesn't he?"},
    # A hypothetical conditional describes a world that is not this one.
    {:hypothetical_conditional, "action_items",
     "If we had a scribe we'd log that as an action item"},
    {:hypothetical_conditional, "action_items", "If Rafe were here he'd take the notes"},
    {:hypothetical_conditional, "brief_worthy", "Suppose we moved the launch to October"},
    {:hypothetical_conditional, "action_items",
     "If it slips again we could ask someone to chase it"},
    {:hypothetical_conditional, "brief_worthy", "Were we to cut scope, the brief would change"},
    # An imperative that is idiom, aside or self-talk rather than an ask.
    {:imperative, "action_items", "Write my strategy"},
    {:imperative, "action_items", "Never mind the notes, forget it"},
    {:imperative, "action_items", "Take it easy on the release, honestly"},
    {:imperative, "action_items", "Tell them I said hi"},
    {:imperative, "brief_worthy", "Picture the launch without the demo"},
    # A fragment carries a deadline or an owner with no predicate.
    {:fragment, "action_items", "the notes by Friday"},
    {:fragment, "open_question", "Is this a demo? No, this is the…"},
    {:fragment, "action_items", "owner, deadline, the usual"},
    {:fragment, "action_items", "by end of week, maybe"},
    {:fragment, "action_items", "the retro action items"},
    # A quoted phrase used as a modifier names a KIND of remark.
    {:quotation_as_modifier, "open_question",
     ~s(We keep getting the "can we ship it?" kind of comments)},
    {:quotation_as_modifier, "open_question", ~s(It was a real "who owns this?" moment)},
    {:quotation_as_modifier, "open_question", ~s(Less of the "is it done yet?" energy please)},
    {:quotation_as_modifier, "action_items", ~s(He has a very "let's just ship it" vibe)},
    {:quotation_as_modifier, "action_items", ~s(We had another "whose job is this" conversation)}
  ]

  @causes [
    {:reported_speech, "action_items", "Tobias, can you send the deck over by Friday?"},
    {:speech_act, "action_items", "My contention is we log an action item for the retro"},
    {:quoted_genre, "open_question", ~s(Another "are we there yet?" type of question from Ines)}
  ]

  @positives [
    {:positive, "action_items", "Dana to send the sprint notes to the team by Friday"},
    {:positive, "action_items", "Scribe, log an action item: Ines to send the notes by Friday."},
    {:positive, "action_items", "Marcus will book the retro room for Thursday"},
    {:positive, "action_items", "Kasia owns the runbook update, due Monday"},
    {:positive, "brief_worthy", "Decision: we move the launch to the ninth of October"},
    {:positive, "brief_worthy", "We agreed the pilot ships to three customers first"},
    {:positive, "brief_worthy", "Launch date is locked for the ninth of October"},
    {:positive, "open_question", "Open question: who owns the migration runbook?"},
    {:positive, "open_question", "We still need to decide whether the beta is invite-only"},
    {:positive, "open_question", "Who signs off on the pricing page before launch?"}
  ]

  @privacy [
    {:privacy, "action_items", "Priya to deliver list of demands to Marcus by end of week"},
    {:privacy, "action_items", "Kasia asked about a pay rise before the review"},
    {:privacy, "action_items", "Rafe is handing in his notice on Monday"},
    {:privacy, "action_items", "Ines keeps undermining Tobias in standup"},
    {:privacy, "action_items", "Marcus to send his salary figures to Dana by Friday"}
  ]

  @doc "The seven negative shapes, in corpus order."
  @spec shapes() :: [atom()]
  def shapes, do: @shapes

  @doc "7 shapes x 5 rows = 35 negatives."
  @spec negatives() :: [row()]
  def negatives, do: @negatives

  @doc "One row per named cause: reported speech, speech-act label, quoted genre."
  @spec causes() :: [row()]
  def causes, do: @causes

  @doc "Genuine asks that must survive every gate."
  @spec positives() :: [row()]
  def positives, do: @positives

  @doc "Candid rows the privacy floor must refuse."
  @spec privacy() :: [row()]
  def privacy, do: @privacy

  @doc "The meeting's participants, as the rate test seats them."
  @spec participant_names() :: [String.t()]
  def participant_names, do: ["Priya", "Dana", "Marcus"]
end
