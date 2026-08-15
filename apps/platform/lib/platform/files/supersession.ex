defmodule Platform.Files.Supersession do
  @moduledoc """
  Reading and ruling on the supersession claims that
  `Platform.Files.Cataloger` records on catalog cards (task 01a0008c
  stage 5).

  ## The claim is metadata, never a gate

  Stage 2 settled the product rule and this module is built to it: the
  claim is **recorded immediately as visible metadata and never blocks
  anything**. A card carrying an unruled claim is written, published,
  indexed and rendered exactly like any other card — the ruling only
  ever *upgrades* it to authoritative. There is deliberately no pending
  queue here, no "awaiting review" status, and nothing that withholds a
  card from the catalog. An unattended queue has to degrade into
  noisier metadata, not a stalled ledger, so the failure mode of nobody
  ever clicking Confirm is a card that keeps wearing the ghost
  treatment forever.

  ## Where the ruling lives

  In the card's own frontmatter, as `supersession_ruling`. Stage 2
  already writes the key with the value `"unruled"` alongside
  `supersedes_file_id` / `supersedes_filename`, so a ruling is an edit
  of an existing key rather than a new column. Three values:

    * `"unruled"`   — recorded, not yet ruled on. The ghost state.
    * `"confirmed"` — a human says the claim is true. Authoritative.
    * `"rejected"`  — a human says it is not true.

  `rule/3` rewrites the one frontmatter line and the one body sentence
  and leaves the rest of the card byte-identical. It does NOT
  regenerate the card: a ruling carries no new information about the
  document, and a regeneration would cost an LLM call and churn the
  page version for a decision the human already made.

  ## Why the path gate is re-checked here

  `Cataloger.write_card/4`'s module docs explain that nothing upstream
  authorizes a wiki-page write — `Wiki.upsert_page/3` performs no
  authorization at all. This module writes through `Wiki.upsert_page/3`
  directly (it needs `:updated_by`, which `write_card/4` does not
  forward), so it re-checks `Cataloger.card_path?/2` itself rather than
  inheriting a gate it stepped around.

  ## Batch reads

  `claims_for_files/1` resolves a whole file list in ONE query. The
  Files surface renders up to 200 rows; a per-row `Wiki.get_page/2`
  would be 200 round-trips to decide whether to draw a badge.
  """

  import Ecto.Query

  alias Platform.Files
  alias Platform.Files.Cataloger
  alias Platform.Files.File, as: PlatformFile
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @unruled "unruled"
  @confirmed "confirmed"
  @rejected "rejected"

  @rulings [@confirmed, @rejected]
  @states [@unruled | @rulings]

  @typedoc """
  A supersession claim as the UI needs it: both ends of it, named from
  the card that records it.

    * `claimant_*` — the document doing the superseding (v1.3). Its card
      is where the claim and the ruling live.
    * `target_*` — the document being superseded (v1.0). This is the row
      the claim is RENDERED on, per the ratified design direction: the
      useful fact is which document is dead, and it is judged with that
      document's own preview in view.

  `ruling` is always one of `states/0` — a card whose frontmatter carries
  no (or an unrecognized) `supersession_ruling` reads as `"unruled"`,
  because an unreadable ruling must degrade to "nobody has ruled" and
  never to "authoritative".
  """
  @type claim :: %{
          claimant_file_id: String.t(),
          claimant_filename: String.t(),
          target_file_id: String.t(),
          target_filename: String.t(),
          ruling: String.t(),
          card_file_key: String.t()
        }

  @doc "The unruled (ghost) state."
  @spec unruled() :: String.t()
  def unruled, do: @unruled

  @doc "The two rulings a human can make."
  @spec rulings() :: [String.t()]
  def rulings, do: @rulings

  @doc "Every value `claim.ruling` can take."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "True when the claim has not been ruled on — the ghost state."
  @spec unruled?(claim() | nil) :: boolean()
  def unruled?(%{ruling: @unruled}), do: true
  def unruled?(_), do: false

  @doc """
  Resolves every supersession claim recorded by the cards of `files`, in
  a single query.

  Returns a map keyed by the **superseded** file's id — the row the
  claim renders on — not by the file whose card records it. Files that
  nothing claims to supersede are simply absent, and the caller renders
  nothing for them.

  One query, not one per row: this surface lists up to 200 files, and a
  per-row `Wiki.get_page/2` would be 200 round-trips to decide whether
  to draw a caption.
  """
  @spec claims_for_files([PlatformFile.t()]) :: %{optional(String.t()) => claim()}
  def claims_for_files(files) when is_list(files) do
    keys =
      for %PlatformFile{card_file_key: key} <- files, is_binary(key), uniq: true, do: key

    case keys do
      [] ->
        %{}

      keys ->
        WikiPage
        |> where([p], p.file_key in ^keys)
        |> Repo.all()
        |> Enum.reduce(%{}, fn page, acc ->
          case claim_from_page(page) do
            nil -> acc
            claim -> Map.put(acc, claim.target_file_id, claim)
          end
        end)
    end
  end

  @doc """
  The supersession claim recorded ON `file`'s own card, or `nil`.

  Note the direction: this is the claim `file` MAKES, not the claim made
  about it. `claims_for_files/1` is the one keyed the other way round.
  """
  @spec claim_for_file(PlatformFile.t()) :: claim() | nil
  def claim_for_file(%PlatformFile{card_file_key: nil}), do: nil

  def claim_for_file(%PlatformFile{card_file_key: key}) when is_binary(key) do
    case Wiki.get_page(key) do
      nil -> nil
      page -> claim_from_page(page)
    end
  end

  @doc """
  The claim recorded on an already-loaded card page, or `nil` when the
  page records none.
  """
  @spec claim_from_page(WikiPage.t()) :: claim() | nil
  def claim_from_page(%WikiPage{frontmatter: frontmatter} = page) when is_map(frontmatter) do
    target_id = Map.get(frontmatter, "supersedes_file_id")
    claimant_id = Map.get(frontmatter, "file_id")

    if binary_present?(target_id) and binary_present?(claimant_id) do
      %{
        claimant_file_id: claimant_id,
        claimant_filename: string_or(frontmatter, "filename", claimant_id),
        target_file_id: target_id,
        target_filename: string_or(frontmatter, "supersedes_filename", target_id),
        ruling: normalize_ruling(Map.get(frontmatter, "supersession_ruling")),
        card_file_key: page.file_key
      }
    end
  end

  def claim_from_page(_), do: nil

  @doc """
  Records a human ruling on `file`'s supersession claim.

  `ruling` is `"confirmed"` or `"rejected"`. Returns the updated claim.

  Errors are all "there is nothing to rule on" shapes —
  `:no_card` (the file has no catalog card yet), `:card_missing` (the
  backlink points at a page that no longer exists), `:no_claim` (the
  card records no supersession claim), or `{:refused_path, key}` (the
  backlink points outside this project's card prefix, which is the
  shape `Cataloger.write_card/4` refuses to write).

  ## Options
    * `:actor_id` — the ruling human's user id, stored as the page's
      `updated_by` so the ruling is attributable.
  """
  @spec rule(PlatformFile.t(), String.t(), keyword()) ::
          {:ok, claim()} | {:error, term()}
  def rule(file, ruling, opts \\ [])

  def rule(%PlatformFile{card_file_key: nil}, ruling, _opts) when ruling in @rulings do
    {:error, :no_card}
  end

  def rule(%PlatformFile{} = file, ruling, opts) when ruling in @rulings do
    with {:ok, page} <- fetch_card(file),
         {:ok, claim} <- fetch_claim(page),
         :ok <- gate_path(page, file) do
      attrs =
        %{content: apply_ruling(page.content, claim, ruling)}
        |> maybe_put_actor(Keyword.get(opts, :actor_id))

      case Wiki.upsert_page(page.file_key, attrs) do
        {:ok, _updated} -> {:ok, %{claim | ruling: ruling}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Records a ruling on an already-resolved claim.

  The verbs live on the SUPERSEDED document's pane but the ruling
  belongs to the claimant's card, so this resolves the claimant from
  the claim rather than making every caller carry both files.

  The claimant id comes out of frontmatter, which is agent-written, so
  it is UUID-guarded before it reaches the repo: a malformed id must
  return "nothing to rule on", not raise `Ecto.Query.CastError`.
  """
  @spec rule_claim(claim(), String.t(), keyword()) :: {:ok, claim()} | {:error, term()}
  def rule_claim(%{claimant_file_id: claimant_id}, ruling, opts \\ []) when ruling in @rulings do
    if Platform.UUID.valid?(claimant_id) do
      case Files.get_file(claimant_id) do
        nil -> {:error, :no_card}
        file -> rule(file, ruling, opts)
      end
    else
      {:error, :no_card}
    end
  end

  @doc """
  The one body sentence a card carries about its supersession claim.

  Shared with `Platform.Files.Cataloger`, which writes the `"unruled"`
  form when it first records the claim. It is shared rather than
  duplicated because a ruling has to REPLACE that sentence: the card
  body is what the Historian reads, and a confirmed claim whose prose
  still says "not yet ruled on" is a lie sitting in the corpus.
  """
  @spec claim_note(String.t(), String.t()) :: String.t()
  def claim_note(filename, @unruled),
    do: "Supersedes: #{filename} (claim not yet ruled on)."

  def claim_note(filename, @confirmed),
    do: "Supersedes: #{filename} (confirmed by a person)."

  def claim_note(filename, @rejected),
    do: "Does not supersede #{filename} (claim ruled not true by a person)."

  # ── Internals ──────────────────────────────────────────────────────────

  defp fetch_card(%PlatformFile{card_file_key: key}) do
    case Wiki.get_page(key) do
      nil -> {:error, :card_missing}
      page -> {:ok, page}
    end
  end

  defp fetch_claim(page) do
    case claim_from_page(page) do
      nil -> {:error, :no_claim}
      claim -> {:ok, claim}
    end
  end

  defp gate_path(page, %PlatformFile{project_id: project_id}) when is_binary(project_id) do
    if Cataloger.card_path?(page.file_key, project_id) do
      :ok
    else
      {:error, {:refused_path, page.file_key}}
    end
  end

  defp gate_path(page, _file), do: {:error, {:refused_path, page.file_key}}

  defp maybe_put_actor(attrs, actor_id) when is_binary(actor_id),
    do: Map.put(attrs, :updated_by, actor_id)

  defp maybe_put_actor(attrs, _), do: attrs

  # Surgical, not a re-render. Only the two places the ruling is stated
  # move; every other byte of the card — the prose the LLM wrote, the
  # frontmatter key order — is preserved. Re-rendering from the parsed
  # frontmatter map would reorder keys on every ruling for no reason.
  defp apply_ruling(content, claim, ruling) do
    content
    |> put_ruling_line(ruling)
    |> String.replace(
      claim_note(claim.target_filename, claim.ruling),
      claim_note(claim.target_filename, ruling)
    )
  end

  @ruling_line ~r/^supersession_ruling:.*$/m
  @file_id_line ~r/^(supersedes_file_id:.*)$/m

  defp put_ruling_line(content, ruling) do
    line = ~s(supersession_ruling: "#{ruling}")

    if Regex.match?(@ruling_line, content) do
      String.replace(content, @ruling_line, line, global: false)
    else
      # A card written before the key existed, or hand-edited. The claim
      # itself proves `supersedes_file_id` is there to anchor to, so the
      # ruling is inserted rather than silently dropped.
      String.replace(content, @file_id_line, "\\1\n" <> line, global: false)
    end
  end

  defp binary_present?(value), do: is_binary(value) and value != ""

  defp string_or(frontmatter, key, fallback) do
    value = Map.get(frontmatter, key)
    if binary_present?(value), do: value, else: fallback
  end

  defp normalize_ruling(ruling) when ruling in @states, do: ruling
  defp normalize_ruling(_), do: @unruled
end
