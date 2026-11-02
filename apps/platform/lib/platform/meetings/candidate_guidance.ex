defmodule Platform.Meetings.CandidateGuidance do
  @moduledoc """
  Single source for the candidate_ids instruction the triage officer is given.

  Both the completion dispatch (`candidate_provenance_instructions`) and the
  `meeting_triage_file` tool description interpolate `sentence/0`, so the two
  cannot drift apart. Prompt-template rows stored in the database are not
  covered by this module and must be kept in line with it by hand.
  """

  @sentence "Every accepted action candidate must be accounted for by a filed item or an explicit exclude/duplicate/conflict decision. Use candidate_ids: [] for novel transcript-only follow-ups. Never infer candidate identity from title similarity. Preserve item_id and candidate_ids on replay."

  @spec sentence() :: String.t()
  def sentence, do: @sentence
end
