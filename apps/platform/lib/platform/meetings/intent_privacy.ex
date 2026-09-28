defmodule Platform.Meetings.IntentPrivacy do
  @moduledoc """
  The **candid-register floor** (task `01a0e58f`, acceptance 2 and 3): a
  candid utterance about compensation, a departure, a list of demands or
  a grievance about a named colleague cannot become a dispatched meeting
  intent, however it was classified.

  ## A FLOOR, independent of the classifier

  This is not precision tuning and not a threshold. It takes the
  utterance text and nothing else: no model, no score, no configuration
  read, no dependency on the per-utterance frame and addressee gates
  (`IntentFrames`, `IntentAddressee`), which can be switched off for a
  falsifier run. The floor cannot be switched off. It sits on the
  responsibility side of the pipeline — every meeting-intent handler's
  `gather_context/2` asks it before gathering anything — so a row the
  classifier was certain about is refused exactly like one it was not.

  It is enforced at `gather_context/2` and not at `build_prompt/1`
  because a `build_prompt/1` refusal does not stop a NATIVE dispatch:
  the Router still sends the agent a signal (with a no-work prompt
  status) carrying the meeting space, which invites the agent into it. A
  `gather_context/2` refusal sends nothing.

  ## The classes

  Closed, word-bounded, case-insensitive phrase lexicons, checked in
  this order; the first class that matches is returned.

    * `:compensation` — salary, pay rises and cuts, bonuses, equity,
      severance, counter-offers, "a raise".
    * `:departure` — resigning, handing in one's notice, leaving the
      company, quitting, someone's last day.
    * `:demands` — a list of demands, an ultimatum, someone's demands.
    * `:grievance` — a complaint, undermining, bullying, harassment, a
      performance plan, a firing, and similar — but ONLY in the same
      sentence as a capitalised name token. On its own ("the flaky test
      keeps undermining the build") such a phrase is ordinary process
      talk.

  ### What counts as a name

  A capitalised word (`[A-Z]` followed by lowercase letters) that is not
  a stopword, a weekday or a month. All-caps acronyms (`HR`, `PR`,
  `CI`) are not names. A word that appears capitalised ONLY at the start
  of a sentence does not count: sentence-initial capitalisation is not
  evidence of a name.

  ## Accepted costs and known misses

  A lexical floor has no semantics. "Can you fire off the invite to
  Dana" is refused as a grievance; that cost is pinned in
  `intent_privacy_test.exs`. A grievance whose only name is the
  sentence's first word ("Ines is undermining me") is NOT caught by the
  name rule above; that miss follows from the sentence-initial rule and
  is pinned as well.

  ## Logging

  This module logs nothing. Callers log the reason atom only — never
  the utterance, the matched word or a name.
  """

  @type class :: :compensation | :departure | :demands | :grievance

  @lexicons [
    compensation:
      ~r/\bsalar(y|ies)\b|\bcompensation\b|\bpay\s+(rise|cut|review)s?\b|\bpayrises?\b|\bbonus(es)?\b|\bequity\b|\bstock options?\b|\bseverance\b|\bcounter-?offers?\b|\b(a|my|his|her|their|your) raise\b/iu,
    departure:
      ~r/\bresign(ation|ing|ed)?\b|\bhand(ing|ed|s)? in (my|his|her|their) notice\b|\bleaving the (company|team|org)\b|\bquitting\b|\b(his|her|their|my) last day\b/iu,
    demands: ~r/\blist of demands\b|\bultimatum\b|\b(his|her|their) demands\b/iu
  ]

  @grievance ~r/\bcomplain(t|ed|ing)?\s+about\b|\bundermin\w*|\bcan['’]?t work with\b|\bfed up with\b|\bfrustrated with\b|\breport(ed)?\s+\w+\s+to\s+hr\b|\bhr complaint\b|\bbull(y|ying|ied)\b|\bharass\w*|\bperformance improvement plan\b|\bpip\b|\bdisciplinary\b|\b(fire|fired|let go|sack(ed)?)\b/iu

  @name_token ~r/\b[A-Z][a-z]+(?:['’\-][A-Za-z]+)*\b/u

  @non_names MapSet.new(~w(
    i the a an and but or so if then this that these those there here it its
    we you he she they me him her them us my your his our their
    can could would will should shall may might must do does did is are was were
    be been being have has had not no yes yeah okay ok well just also maybe
    please thanks what who when where why how which let lets
    monday tuesday wednesday thursday friday saturday sunday today tomorrow yesterday
    january february march april may june july august september october november december
  ))

  @doc """
  Is this utterance in a candid register?

  Returns `{:candid, class}` or `:ok`. Pure. Blank and non-binary input
  is `:ok`: the handlers' own blank-excerpt refusal owns that case.
  """
  @spec candid_register(term()) :: :ok | {:candid, class()}
  def candid_register(text) when is_binary(text) do
    if String.trim(text) == "" do
      :ok
    else
      case Enum.find(@lexicons, fn {_class, regex} -> Regex.match?(regex, text) end) do
        {class, _regex} -> {:candid, class}
        nil -> grievance(text)
      end
    end
  end

  def candid_register(_text), do: :ok

  defp grievance(text) do
    names = names_in(text)

    text
    |> String.split(~r/[.!?\n]+/u)
    |> Enum.any?(&(Regex.match?(@grievance, &1) and names_in_sentence?(&1, names)))
    |> case do
      true -> {:candid, :grievance}
      false -> :ok
    end
  end

  # Every name token in the text that appears capitalised somewhere OTHER
  # than the first word of a sentence.
  defp names_in(text) do
    text
    |> String.split(~r/[.!?\n]+/u)
    |> Enum.flat_map(fn sentence ->
      sentence
      |> String.trim_leading()
      |> then(&Regex.scan(@name_token, &1, return: :index))
      |> Enum.reject(fn [{start, _length}] -> start == 0 end)
      |> Enum.map(fn [{start, length}] ->
        sentence |> String.trim_leading() |> binary_part(start, length)
      end)
    end)
    |> Enum.reject(&MapSet.member?(@non_names, String.downcase(&1)))
    |> MapSet.new()
  end

  defp names_in_sentence?(sentence, names) do
    @name_token
    |> Regex.scan(sentence)
    |> List.flatten()
    |> Enum.any?(&MapSet.member?(names, &1))
  end
end
