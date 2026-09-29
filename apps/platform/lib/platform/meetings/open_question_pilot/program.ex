defmodule Platform.Meetings.OpenQuestionPilot.Program do
  @moduledoc """
  Arm B's baseline Imp program for the open_question pilot (task 01a0e8b5):
  `excerpt, participants -> is_question: bool, addressee`.

  Uncompiled: no demos, no optimisation. Stage 4 compiles it; this is the
  shape it starts from.
  """

  @signature "excerpt: str, participants: array[str] -> is_question: bool, addressee: str"

  @instructions """
  Decide whether a meeting utterance is a GENUINE open question: something \
  the speaker is actually asking or that the meeting still has to decide, \
  and that someone could answer. Tag questions seeking agreement, rhetorical \
  questions, questions only reported or quoted, and questions merely \
  embedded in a statement are NOT open questions. `addressee` is the \
  participant the question is put to by name, or "none".\
  """

  @doc "The signature string."
  def signature, do: @signature

  @doc "The baseline program."
  def new, do: @signature |> Imp.signature(@instructions) |> Imp.predict()
end
