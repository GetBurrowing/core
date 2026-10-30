defmodule Platform.Repo.Migrations.AddRunIdentityToMeetingCompletionTemplates do
  use Ecto.Migration

  @moduledoc """
  Task 01a18ab4-badb-7000-a966-44ca701a276a stage 1: give the
  `dispatch.scribe_completion` and `dispatch.triage_dispatch` bodies a
  "This run" block that carries every identifier (meeting_id, run_id,
  transcript_id, snapshot_hash, canvas_id, source_transcript_ids), the
  accepted action candidates and the full finalized transcript as
  `{{placeholders}}`, plus the completion tool call naming run_id.

  The live bodies told the agent to read those values "from the attention
  signal", but the burrow-channel plugin forwards only a short whitelist of tag
  attributes and never run_id or the transcript, so the body must carry them.

  The block is inserted right after the FIRST `{{federation_preamble}}` (or
  prepended when the body has none). It does not depend on any exact span of
  the existing body, because the two production installs carry different
  human edits (see 20261018223000). A body that already contains `{{run_id}}`
  is left unchanged, so a second run is a no-op. Only `prompt_templates` rows
  are touched; no `meeting_completion_runs` row is read or written.
  `down/0` is a no-op.
  """
  require Logger
  alias Platform.Orchestration.PromptTemplates

  @slugs ["dispatch.scribe_completion", "dispatch.triage_dispatch"]
  @guard "{{run_id}}"
  @preamble "{{federation_preamble}}"

  @scribe_block ~S"""
  ## This run — every identifier is in this message, not the tag attributes

  - meeting_id={{meeting_id}}, run_id={{run_id}}, transcript_id={{transcript_id}}, snapshot_hash={{snapshot_hash}}
  - canvas_id={{canvas_id}} (blank on the first run means canvas_create; otherwise update that canvas)
  - source_transcript_ids={{source_transcript_ids}}

  Complete this step by calling the MCP tool `meeting_scribe_complete` with meeting_id={{meeting_id}}, run_id={{run_id}}, transcript_id={{transcript_id}}, snapshot_hash={{snapshot_hash}} and the canvas_id you created.

  ### Accepted action candidates

  {{accepted_action_candidates}}

  ### Full finalized transcript (segment_id | time | speaker: text)

  {{completion_transcript}}
  """

  @triage_block ~S"""
  ## This run — every identifier is in this message, not the tag attributes

  - meeting_id={{meeting_id}}, run_id={{run_id}}, transcript_id={{transcript_id}}, snapshot_hash={{snapshot_hash}}
  - canvas_id={{canvas_id}} — the scribe canvas whose `actions` checklist you consume
  - source_transcript_ids={{source_transcript_ids}}

  Complete this step by calling the MCP tool `meeting_triage_file` with meeting_id={{meeting_id}}, run_id={{run_id}}, transcript_id={{transcript_id}}, canvas_id={{canvas_id}}, snapshot_hash={{snapshot_hash}} and action_items.

  ### Candidate provenance

  {{candidate_provenance_instructions}}

  ### Accepted action candidates

  {{accepted_action_candidates}}

  ### Full finalized transcript (segment_id | time | speaker: text)

  {{completion_transcript}}
  """

  # Optional, cosmetic: point the old "read these from the signal" sentence at
  # the new block. Whitespace-tolerant because install bodies are re-wrapped.
  @signal_sentence ~r/`source_transcript_ids`(\s+)from the (?:attention )?signal\./
  @signal_sentence_replacement "`source_transcript_ids`\\1from the `This run` block above."

  @doc "The run-identity block inserted for `slug` (trailing newline trimmed)."
  def block("dispatch.scribe_completion"), do: String.trim_trailing(@scribe_block)
  def block("dispatch.triage_dispatch"), do: String.trim_trailing(@triage_block)

  @doc """
  Pure rewrite of one template body. Returns `content` unchanged when it
  already carries `{{run_id}}`.
  """
  def rewrite(slug, content) when slug in @slugs and is_binary(content) do
    if String.contains?(content, @guard) do
      content
    else
      content |> insert_block(block(slug)) |> retarget_signal_sentence(slug)
    end
  end

  defp insert_block(content, block) do
    case String.split(content, @preamble, parts: 2) do
      [before, rest] -> before <> @preamble <> "\n\n" <> block <> rest
      [_no_preamble] -> block <> "\n\n" <> content
    end
  end

  defp retarget_signal_sentence(content, slug) do
    if Regex.match?(@signal_sentence, content) do
      Regex.replace(@signal_sentence, content, @signal_sentence_replacement, global: false)
    else
      Logger.info(
        "#{inspect(__MODULE__)}: #{slug} has no 'from the signal' sentence to retarget; skipped"
      )

      content
    end
  end

  def up do
    for slug <- @slugs do
      case PromptTemplates.get_template_by_slug(slug) do
        %{content: content} = template when is_binary(content) ->
          updated = rewrite(slug, content)

          if updated != content do
            {:ok, _} =
              PromptTemplates.update_template(template, %{
                content: updated,
                variables: merge_variables(template.variables, slug)
              })
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  # Declare the block's placeholders on the row too, so the admin editor lists
  # them. Existing entries keep their order; only missing names are appended.
  defp merge_variables(existing, slug) do
    existing = existing || []
    names = Regex.scan(~r/\{\{(\w+)\}\}/, block(slug), capture: :all_but_first)
    existing ++ ((names |> List.flatten() |> Enum.uniq()) -- existing)
  end

  def down, do: :ok
end
