defmodule Platform.Meetings.IntentAddressee do
  @moduledoc """
  The **addressee gate**: a deterministic check that a routable answer's
  ADDRESSED NAME appears on the roster the model was shown (task
  `01a05997` stage 5).

  ## The failure this exists to catch

  The e2e reviewer measured, at `temperature: 0` and stable 3/3 on the
  deployed dev environment:

      "Harper, can you write that up?"
        -> action_items, target_role "meeting_scribe",
           assigned_agent_slug "dalton", evidence_quote "write that up"

  Harper is **not on the roster**. The severity is not the mis-binning —
  it is that an off-roster ask RESOLVED ONTO A REAL AGENT and would have
  dispatched work to Dalton.

  ## Why this is not a prompt change

  The rendered prompt already carries the rule verbatim, three times
  (roster-grounded addressing rule at line 15, the `"Nah, I'm gonna get
  Harper in here."` exemplar at line 18, and the contrast restated with
  a second off-roster ask at lines 27–33). The roster IS rendered and IS
  being ignored as a discriminator. A fourth restatement is not a fix,
  and prior stages measured that adding exemplars moved
  willingness-to-fire rather than discrimination. So the instruction is
  converted into a **checkable invariant** enforced after the model
  answers.

  ## The rule

  A routable answer has its `target_role` rewritten to the null sentinel
  iff:

    1. an **addressed name** can be located in the utterance (or in the
       leading vocative of the model's own `evidence_quote`), AND
    2. that name does not appear anywhere in the roster the model was
       shown — matched case-insensitively against agent NAME, agent
       SLUG, ROLE KEY, and the tokens of a snake_cased role key.

  Both halves matter. An utterance with **no vocative at all** is never
  touched: `unaddressed_probe_12` is twelve agent-directed asks that
  name nobody (`"Record the decision: we're shipping Tuesday."`), every
  one a legitimate positive. Over-suppression is the obvious way this
  gate goes wrong, so the vocative detector is deliberately narrow and
  every widening of it has to survive that slice.

  Role keys are in the match set because `control_60` addresses agents
  by ROLE, not by name — `"Designer, make that primary button teal"`,
  `"Scribe, take an action item: ..."`, `"Historian, record the
  decision: ..."`, `"Triage, open question for someone: ..."`. Those are
  the control slice's positives. A gate matching only `agent_name` and
  `agent_slug` would suppress 24 of 60 control rows and read as the
  roster fix destroying the classifier. The invariant is therefore
  stated over the RENDERED ROSTER BLOCK — if the addressed name appears
  in the text the model was shown, it is addressable.

  ## Vocative detection

  Three shapes, all anchored at the START of the utterance (English
  vocatives that carry a delegation are overwhelmingly clause-initial),
  plus a trailing-comma form:

    * **comma vocative** — `Harper, can you write that up?`,
      `Agent Voice, can you hear me?` (up to three capitalised words);
    * **bare vocative + imperative** — `Octavius file a ticket for the
      purse-based meeting problem.` (its positive twin, `Dalton file a
      ticket ...`, is byte-identical but for the name, so a rule that
      cannot see this shape cannot separate the pair at all);
    * **bare vocative + modal** — `Harper can you write that up?`;
    * **trailing vocative** — `... would you, Sam?`

  ### Stopwords are load bearing

  Spoken transcript opens with a discourse marker constantly — `"Yeah,
  ..."`, `"Okay, so ..."`, `"No, actually, never mind. ..."`, `"Um,
  wrong intent."`. 26 of the 102 recorded negatives match the raw
  comma-vocative shape, and every one of them is a marker or a pronoun,
  not a name. Suppressing those rows would MOVE THE NEGATIVES NUMBER IN
  THE GOOD DIRECTION FOR THE WRONG REASON — the gate would be scoring on
  "the utterance started with 'Yeah'", not on the roster. The stopword
  list exists so the measured improvement is attributable to the roster
  and nothing else.

  Likewise `You can see tasks now.` / `We can ask him to bring it in
  here.` / `One take. I'll break back.` / `Let's put together some kind
  of plan here.` are the only four negatives matching the bare shapes,
  and all four are pronouns.

  ## What the gate does to a hit

  It does NOT demote (ruling: task `01a08fde`, 2026-09-11, Rowan: gate).
  Migration `20260902140000` instructs the model that an ask aimed at a
  person KEEPS its intent and takes `target_role: null`; the gate applies
  the same rule to an answer the model got wrong. `IntentClassifier`
  keeps the intent, confidence and verbatim `evidence_quote`, rewrites
  `target_role` to `IntentClassifier.no_target_role/0` (the string
  `"null"`, the one spelling of nobody), and marks the row with
  `addressee_nulled_from: <the role it overwrote>`. `demoted_from` and
  `demotion_reason` stay nil. `verdict/3`'s own return shape is
  unchanged: `:ok | {:off_roster, name}`.

  ## What this does not reach

  A vocative buried mid-utterance with no comma (`"so then Harper file a
  ticket"`) is not detected. That is the conservative direction: a
  missed detection leaves today's behaviour, a false detection strips a
  legitimate ask of its addressee. This module is not a named-entity recogniser and
  should not grow into one — if the vocative surface needs to widen,
  widen it against `unaddressed_probe_12` and `control_60` first.
  """

  @typedoc "A roster entry as returned by `Platform.Agents.Roles.assigned_agents/0`."
  @type roster_entry :: %{
          required(:role_key) => String.t(),
          required(:agent_slug) => String.t(),
          required(:agent_name) => String.t()
        }

  # Sentence-initial discourse markers and pronouns. See "Stopwords are
  # load bearing" above — these are not a convenience list, they are what
  # keeps the measured delta attributable to the roster.
  @stopwords MapSet.new(~w(
    yeah yep yup yes no nah nope okay ok alright right well so um uh oh
    hey hi hello sure look listen anyway actually honestly basically
    please thanks thank sorry wait maybe great cool nice true exactly
    absolutely first second third then now also and but or because
    i you we he she they it one everyone everybody someone somebody
    nobody anyone that this there these those what who when where why
    how let's lets there's here's
  ))

  # Verbs that open an imperative delegation. Kept CLOSED and small: the
  # bare-vocative shape has no comma to lean on, so the verb is the only
  # evidence that the leading capitalised token was an address rather
  # than a sentence's first word.
  @imperative_verbs MapSet.new(~w(
    file open write log capture track note put add make record create
    draft send book schedule flag bump pull set start close take give
    find fix update change swap move remove delete build raise ticket
    handle review check draw sort spin stand
  ))

  @modals MapSet.new(~w(can could would will should please))

  @leading_comma_vocative ~r/^\s*([A-Z][\p{L}'’\-]*(?:\s+[A-Z][\p{L}'’\-]*){0,2})\s*,/u
  @leading_bare_vocative ~r/^\s*([A-Z][\p{L}'’\-]+)\s+([\p{L}'’\-]+)\b/u
  @trailing_comma_vocative ~r/,\s*([A-Z][\p{L}'’\-]+)\s*[.?!]*\s*$/u

  @doc """
  Is this routable answer addressed to somebody who is not on the roster?

  Returns `:ok` when the answer may stand — no addressee was found, or the
  addressee is on the roster — and `{:off_roster, name}` when a located
  addressee appears nowhere in the roster the model was shown.

  A `nil` roster means the caller could not tell us what the model saw.
  That is NOT the same as an empty roster, and it must not be treated as
  one: an unknown roster matches nothing, so gating on it would suppress
  every addressed utterance in the system on the strength of a missing
  argument. `nil` is inert by construction.
  """
  @spec verdict(String.t() | nil, String.t() | nil, [roster_entry()] | nil) ::
          :ok | {:off_roster, String.t()}
  def verdict(_chunk_text, _quote_text, nil), do: :ok

  def verdict(chunk_text, quote_text, roster) when is_list(roster) do
    allowed = roster_tokens(roster)

    [chunk_text, quote_text]
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&addressees/1)
    |> Enum.reduce_while(:ok, fn candidate, _acc ->
      if on_roster?(candidate, allowed) do
        # An on-roster addressee anywhere in the pair settles the
        # question in the PERMISSIVE direction and stops the scan. The
        # gate's job is to catch an ask aimed at a person; an ask that
        # names an agent at all is not that.
        {:halt, :ok}
      else
        {:cont, {:off_roster, candidate}}
      end
    end)
  end

  def verdict(_chunk_text, _quote_text, _roster), do: :ok

  @doc """
  Every string that counts as "on the roster", downcased.

  Agent name, agent slug, role key, and the tokens of a snake_cased role
  key (`meeting_scribe` -> `meeting`, `scribe`), because `control_60`
  addresses agents as `Scribe` / `Historian` / `Triage` / `Designer` and
  those are the slice's positives.
  """
  @spec roster_tokens([roster_entry()]) :: MapSet.t(String.t())
  def roster_tokens(roster) when is_list(roster) do
    roster
    |> Enum.flat_map(fn entry ->
      role_key = to_string(Map.get(entry, :role_key) || Map.get(entry, "role_key") || "")
      slug = to_string(Map.get(entry, :agent_slug) || Map.get(entry, "agent_slug") || "")
      name = to_string(Map.get(entry, :agent_name) || Map.get(entry, "agent_name") || "")

      [role_key, slug, name] ++ String.split(role_key, "_") ++ String.split(name, ~r/\s+/)
    end)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  @doc """
  Locate addressed names in one piece of text.

  Public so the guard test can assert the DETECTOR separately from the
  roster comparison — a gate that silently stopped detecting would
  otherwise pass every roster assertion by finding nothing.
  """
  @spec addressees(String.t()) :: [String.t()]
  def addressees(text) when is_binary(text) do
    [
      comma_vocative(text),
      bare_vocative(text),
      trailing_vocative(text)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def addressees(_text), do: []

  defp comma_vocative(text) do
    case Regex.run(@leading_comma_vocative, text) do
      [_, candidate] -> reject_stopword(candidate)
      _ -> nil
    end
  end

  defp bare_vocative(text) do
    case Regex.run(@leading_bare_vocative, text) do
      [_, candidate, next] ->
        next = String.downcase(next)

        if MapSet.member?(@imperative_verbs, next) or MapSet.member?(@modals, next) do
          reject_stopword(candidate)
        end

      _ ->
        nil
    end
  end

  defp trailing_vocative(text) do
    case Regex.run(@trailing_comma_vocative, text) do
      [_, candidate] -> reject_stopword(candidate)
      _ -> nil
    end
  end

  # A candidate is dropped when ANY of its tokens is a stopword, so
  # "Let's put together ..." and "No, actually ..." are not addresses.
  defp reject_stopword(candidate) do
    tokens =
      candidate
      |> String.trim()
      |> String.split(~r/\s+/)
      |> Enum.map(&String.downcase/1)

    if tokens == [] or Enum.any?(tokens, &MapSet.member?(@stopwords, &1)) do
      nil
    else
      String.trim(candidate)
    end
  end

  defp on_roster?(candidate, allowed) do
    tokens =
      candidate
      |> String.downcase()
      |> String.split(~r/\s+/)

    MapSet.member?(allowed, String.downcase(candidate)) or
      Enum.any?(tokens, &MapSet.member?(allowed, &1))
  end
end
