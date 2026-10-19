defmodule Platform.Repo.Migrations.NeutraliseScribeCompletionExamples do
  use Ecto.Migration

  require Logger

  @moduledoc """
  Task 01a14dd9-7172-7000-874c-b9ae3d4c1c83 (Burrow rename A3c), stage 3.

  The `dispatch.scribe_completion` descriptor in
  `Platform.Orchestration.PromptTemplates` named a client org in its
  description and in three example lines of its body. Stage 3 rewrote the
  descriptor with placeholders (Globex, `globex-atlas`). `seed_defaults/0` is
  insert-only and `render_template/2` serves the database row, so installs
  keep the old text until a migration moves the row. This is that migration.

  ## Surgical, by digest, one line at a time

  It never spells the old text. It holds `@line_map`, a frozen map from the
  sha256 of each old line (leading whitespace included, newline excluded) to
  its replacement, and `@old_description_sha256`, the sha256 of the old
  description. The shape follows
  `20260923120000_rewrite_task_ack_preamble_structural_claim` (surgical, a
  no-op where nothing matches) and
  `20261018072000_replace_intent_classify_exemplar_span` (matched by digest).

    * Each content line whose sha256 is a key of `@line_map` is replaced by
      that key's value. Every other line is kept byte for byte, so a hand
      edit elsewhere in the row survives.
    * The description is replaced by `@new_description` only when its sha256
      equals `@old_description_sha256`.
    * No row, or nothing matching: no write. A second run matches nothing, so
      the migration is idempotent.

  The action-item example has two keys. Installs measured on 2026-10-18 hold
  an earlier descriptor's spelling of that line (a different example name),
  not the one the descriptor carried at 87100c4c. Both spellings become the
  current descriptor's line.

  Only digests are logged, never content. `down/0` is a no-op: there is no
  prior text worth restoring.
  """

  @slug "dispatch.scribe_completion"

  @line_map %{
    # the participant-ambiguity example
    "bb575f433e237331d04917ba4112095c8a0c545a79ab6cbebf1c7a85ac387ce9" =>
      ~S|  `user:saru` on the invite (as on the Globex 2026-07-13 meeting) — flag it inline: "attributed|,
    # the action-item label example
    "c98b64449fe4420c8de677e49aa6cfda7f53fe53cfdbcc52baa8c8b3fe81bdbf" =>
      ~S|  Example: `"Alex: draft the Globex Q3 pricing memo by Friday"`.|,
    # the same example as an earlier descriptor spelled it
    "5f7edf242f5159facc089574bfd6402556d082b2511681aef2808f805763dc1e" =>
      ~S|  Example: `"Alex: draft the Globex Q3 pricing memo by Friday"`.|,
    # the JSON template's project_hint
    "facfd446445d5ac6f1b2228a9c99e8b2b2dbc4732048cf2ed0f59f2dc75349f4" =>
      ~S|  "project_hint": "globex-atlas",|
  }

  @old_description_sha256 "6a920b44de116b82efae130ffb72a96fadcb51762db96aeca84b97e8ad6a32d9"

  @new_description ~S|Sent to the scribe agent on `meeting_scribe_completion` attention signals. Instructs the scribe to produce a 5-card meeting summary canvas (Summary / Decisions / Action items / Open questions / Provenance) in the meeting's chat space and hand structured action items off to the triage agent via `dispatch_triage_attention/2`. Codifies the Globex scribe canvas structure proven on the 2026-07-13 meeting.|

  def slug, do: @slug
  def line_map, do: @line_map
  def old_description_sha256, do: @old_description_sha256
  def new_description, do: @new_description

  def up do
    run(@line_map, @old_description_sha256)
    :ok
  end

  def down, do: :ok

  @doc """
  Pure: `content` with every line whose sha256 is a key of `map` replaced by
  that key's value. Lines are split and joined on `"\\n"`, so every other
  byte, including a trailing newline, is unchanged.
  """
  def rewrite(content, map) when is_binary(content) and is_map(map) do
    content
    |> String.split("\n")
    |> Enum.map(fn line -> Map.get(map, sha256(line), line) end)
    |> Enum.join("\n")
  end

  @doc """
  Applies `rewrite/2` with `map` to the `#{@slug}` row's content, and
  replaces its description when the description's sha256 is
  `old_description_sha256`. Public so tests can drive it with digests of
  their own.

  Returns `:rewritten`, `:no_row` or `:no_match`.
  """
  def run(map, old_description_sha256) do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      %{content: content} = template when is_binary(content) ->
        new_content = rewrite(content, map)

        attrs =
          %{}
          |> put_if(new_content != content, :content, new_content)
          |> put_if(
            is_binary(template.description) and
              sha256(template.description) == old_description_sha256,
            :description,
            @new_description
          )

        if attrs == %{} do
          Logger.info(
            "neutralise_scribe_completion_examples: skipping #{@slug}: no line or " <>
              "description matches; row sha256 #{sha256(content)}"
          )

          :no_match
        else
          {:ok, _} = PromptTemplates.update_template(template, attrs)
          :rewritten
        end

      _ ->
        :no_row
    end
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
