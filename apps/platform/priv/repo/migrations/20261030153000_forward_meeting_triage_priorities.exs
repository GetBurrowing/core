defmodule Platform.Repo.Migrations.ForwardMeetingTriagePriorities do
  use Ecto.Migration

  @moduledoc """
  Task 01a18b35-249a-7000-97f2-b5acd5c0c99d: add explicit priority forwarding
  and server-owned batch control guidance without overwriting install edits.
  Both installations’ full rows/metadata were audited 2026-10-30: bodies match across
  installs; their skill label wording predates the imperative-title descriptor.
  Preserve that unrelated difference and the 20261030140000 This run block.
  """

  @heading "## Priority forwarding and batch control"
  @block ~S"""
  ## Priority forwarding and batch control

  Copy the parsed note priority into `priority` on every filed `action_items` entry.
  Normalize note strings case-insensitively: `low` → `low`, `medium` → `medium`,
  `high` → `high`, `critical` → `critical`. Missing, nil, malformed or unrecognized
  note priorities default to `medium`. This is a note-parsing fallback only:
  an invalid explicit API priority is refused by `meeting_triage_file`, not silently
  normalized. Send a valid lowercase enum value and preserve canonical run/item
  identities, transcript grounding and candidate provenance.
  The server owns the single batch junk control; do not append another
  "Junk this batch" control, including on replay.
  """

  def rewrite(content) when is_binary(content) do
    if String.contains?(content, @heading) do
      content
    else
      anchor =
        Enum.find(
          ["### Idempotency contract", "## Idempotency", "{{skills_reference}}"],
          &String.contains?(content, &1)
        )

      if anchor do
        String.replace(content, anchor, @block <> "\n" <> anchor, global: false)
      else
        content <> "\n\n" <> @block
      end
    end
  end

  def rewrite_skill(content) do
    content
    |> String.replace(
      ~S(`"high" | "medium" | "low"`),
      ~S(`"low" | "medium" | "high" | "critical"`)
    )
    |> String.replace("`high|medium|low`", "`low|medium|high|critical`")
    |> add_critical_mapping()
    |> rewrite()
  end

  defp add_critical_mapping(content) do
    if String.contains?(content, ~S(- `"critical"` → `critical`)) do
      content
    else
      String.replace(
        content,
        ~S(- `"low"` → `low`),
        ~S(- `"low"` → `low`) <> "\n" <> ~S(- `"critical"` → `critical`)
      )
    end
  end

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug("dispatch.triage_dispatch") do
      %{content: content} = row ->
        updated = rewrite(content)

        if updated != content,
          do: PromptTemplates.update_template(row, %{content: updated}) |> ensure_updated!()

      _ ->
        :ok
    end

    case Platform.Skills.get_skill_by_slug("meeting-triage-officer") do
      %{content: content} = row ->
        updated = rewrite_skill(content)

        if updated != content,
          do: Platform.Skills.update_skill(row, %{content: updated}) |> ensure_updated!()

      _ ->
        :ok
    end

    :ok
  end

  defp ensure_updated!({:ok, _}), do: :ok
  defp ensure_updated!(other), do: raise("triage instruction update failed: #{inspect(other)}")
  def down, do: :ok
end
