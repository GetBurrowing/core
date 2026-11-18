defmodule Platform.Social.Pairing do
  @moduledoc """
  Social Studio slice C, pairing: matches the entries of a clip-tool export
  (`clip project export-intake`) to videos already uploaded to the profile's
  project, and turns confirmed choices into a manifest for
  `Platform.Social.Intake.import_manifest/4`.

  The export knows each clip's SHA-256 and byte size but not a Burrow `file_id`
  (a video gets its id when a person puts it into Burrow). This module closes that
  gap without guessing:

    * a file is a candidate only when it is a live, finalized video in THIS
      profile's project whose `content_hash` and `byte_size` both equal the entry's.
      Never by file name. Another project's file with the same bytes is invisible;
    * one candidate is proposed (`{:one, file}`), several need a person's choice
      (`{:many, files}`), none is `:none` ("No matching uploaded file");
    * entries with identical bytes share one uploaded file, and each is told which
      others it shares it with (`shared_with`), so a screen can say so;
    * `propose/4` writes nothing and decides nothing: it is advice for a person.
      `build_manifest/5` takes the person's explicit choices (`%{external_ref =>
      file_id}`), re-reads the candidates for each chosen entry, and rejects a choice
      that is no longer one (`{ref, :not_a_candidate}`) without losing the others;
    * the manifest it builds carries the expected `sha256` and `size_bytes` with each
      `file_id`, and `Intake` checks them again against the file as it is when the clip
      is written (`:file_changed`). Pairing is never the last check.

  The same authority as an import is needed to look (a live human approver; Studio on;
  `Studio.authorize_studio_actor/2`; and `files.read` on the project, `:no_file_access`
  otherwise), because the answer discloses which files exist in the project. Another org
  reads `:not_found`.

  ## Shapes

      propose/4 -> {:ok, %{entries: [proposal]}}
      proposal  = %{external_ref: String.t() | nil, sha256: String.t() | nil,
                    size_bytes: integer() | nil,
                    match: {:one, file} | {:many, [file]} | :none | {:invalid, :bad_ref | :bad_hash | :bad_size},
                    shared_with: [String.t()]}
      file      = %{id, name, byte_size, content_hash, content_type, inserted_at}

      build_manifest/5 -> {:ok, %{manifest: %{"clips" => [...]}, unresolved: [ref],
                                  invalid: [{index, :bad_ref}], rejected: [{ref, reason}]}}
      reason: :not_a_candidate | :unknown_ref | :invalid_entry

  `invalid` lists entries with no usable `external_ref` by their 0-based position in the export
  (`:bad_ref`), so a mixed export never looks fully resolved while dropping a clip. A ref repeated
  in the export (compared trimmed) refuses the whole call with `:duplicate_external_ref`, as an
  import would.

  What it does not do: it never reads or stores file bytes, never imports, and never
  contacts anyone. The export's own approval claim passes through to intake, which stores
  it as a claim only.
  """

  import Ecto.Query

  alias Platform.Files.File, as: UploadedFile
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Profile, Studio}

  @max_clips 100
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @type file_summary :: %{
          id: Ecto.UUID.t(),
          name: String.t() | nil,
          byte_size: integer(),
          content_hash: String.t(),
          content_type: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @type match ::
          {:one, file_summary()}
          | {:many, [file_summary()]}
          | :none
          | {:invalid, :bad_ref | :bad_hash | :bad_size}

  @doc """
  Proposes a file for each entry of `export`. Refusals of the whole call are intake's:
  `:not_found`, `:studio_disabled`, an approver refusal, `:studio_needs_project`,
  `:no_social_access`, `:no_file_access`; plus `:invalid_export` and `:duplicate_external_ref`.
  """
  @spec propose(Social.scope(), term(), term(), term()) ::
          {:ok, %{entries: [map()]}} | {:error, term()}
  def propose(scope, profile_id, export, user_id) do
    with {:ok, profile} <- authorize(scope, profile_id, user_id),
         {:ok, entries} <- parse(export) do
      read = Enum.map(entries, &read_entry/1)
      {:ok, %{entries: Enum.map(read, &proposal(profile, &1, read))}}
    end
  end

  @doc """
  Builds an intake manifest from `choices` (`%{external_ref => file_id}`). Entries without a
  choice are `unresolved` (never guessed); a choice that is not a current candidate for its
  entry, or names no entry, is `rejected` alone. The other choices still build.
  """
  @spec build_manifest(Social.scope(), term(), term(), map(), term()) ::
          {:ok,
           %{
             manifest: map(),
             unresolved: [String.t()],
             invalid: [{non_neg_integer(), atom()}],
             rejected: [{String.t(), atom()}]
           }}
          | {:error, term()}
  def build_manifest(scope, profile_id, export, choices, user_id) when is_map(choices) do
    with {:ok, profile} <- authorize(scope, profile_id, user_id),
         {:ok, entries} <- parse(export) do
      choices = Map.new(choices, fn {ref, file_id} -> {to_string(ref), file_id} end)
      read = Enum.map(entries, &read_entry/1)
      refs = for %{ref: ref} <- read, is_binary(ref), do: ref

      resolved =
        read |> Enum.with_index() |> Enum.map(fn {e, i} -> resolve(profile, e, choices, i) end)

      {:ok,
       %{
         manifest: %{"clips" => for({:ok, clip} <- resolved, do: clip)},
         unresolved: for({:unresolved, ref} <- resolved, do: ref),
         invalid: for({:invalid, index, why} <- resolved, do: {index, why}),
         rejected:
           for({:rejected, ref, why} <- resolved, do: {ref, why}) ++
             for({ref, _} <- choices, ref not in refs, do: {ref, :unknown_ref})
       }}
    end
  end

  # ── Authority and the export ─────────────────────────────────────────

  defp authorize(scope, profile_id, user_id) do
    with %Profile{} = profile <- Social.get_profile(scope, profile_id) || {:error, :not_found},
         :ok <- if(Studio.enabled?(profile), do: :ok, else: {:error, :studio_disabled}),
         :ok <- Social.approver_check(profile.org_id, profile, user_id),
         :ok <- Studio.authorize_studio_actor(profile, user_id),
         :ok <- Platform.Social.Intake.require_file_access(profile, user_id) do
      {:ok, profile}
    end
  end

  defp parse(export) when is_map(export) do
    case Map.new(export, fn {k, v} -> {to_string(k), v} end) do
      %{"clips" => list} when is_list(list) and list != [] and length(list) <= @max_clips ->
        if Enum.all?(list, &is_map/1),
          do:
            list
            |> Enum.map(fn e -> Map.new(e, fn {k, v} -> {to_string(k), v} end) end)
            |> distinct_refs(),
          else: {:error, :invalid_export}

      _ ->
        {:error, :invalid_export}
    end
  end

  defp parse(_), do: {:error, :invalid_export}

  # Refs are compared trimmed, as Intake does; one choice per ref must mean one entry, and Intake
  # refuses a manifest that repeats a ref. Entries with no usable ref are not counted here: they
  # are reported as invalid, by position.
  defp distinct_refs(entries) do
    refs = for e <- entries, ref = read_entry(e).ref, do: ref

    if length(refs) == length(Enum.uniq(refs)),
      do: {:ok, entries},
      else: {:error, :duplicate_external_ref}
  end

  # What an entry says about its file: a ref, a lower-case SHA-256 and a byte size, or why not.
  defp read_entry(entry) do
    ref = with ref when is_binary(ref) <- entry["external_ref"], do: String.trim(ref)
    hash = with h when is_binary(h) <- entry["sha256"], do: String.downcase(h)
    size = entry["size_bytes"]

    invalid =
      cond do
        not is_binary(ref) or ref == "" -> :bad_ref
        not (is_binary(hash) and Regex.match?(@sha256, hash)) -> :bad_hash
        not (is_integer(size) and size >= 0) -> :bad_size
        true -> nil
      end

    %{
      ref: if(is_binary(ref) and ref != "", do: ref),
      sha256: if(is_binary(hash), do: hash),
      size_bytes: if(is_integer(size), do: size),
      invalid: invalid,
      raw: entry
    }
  end

  # ── Proposals ────────────────────────────────────────────────────────

  defp proposal(profile, entry, all) do
    %{
      external_ref: entry.ref,
      sha256: entry.sha256,
      size_bytes: entry.size_bytes,
      match: match(profile, entry),
      shared_with: shared_with(entry, all)
    }
  end

  defp match(_profile, %{invalid: reason}) when not is_nil(reason), do: {:invalid, reason}

  defp match(profile, entry) do
    case candidates(profile, entry) do
      [] -> :none
      [file] -> {:one, summary(file)}
      files -> {:many, Enum.map(files, &summary/1)}
    end
  end

  defp shared_with(%{invalid: reason}, _all) when not is_nil(reason), do: []

  defp shared_with(entry, all) do
    for other <- all,
        other.invalid == nil,
        other.ref != entry.ref,
        {other.sha256, other.size_bytes} == {entry.sha256, entry.size_bytes},
        do: other.ref
  end

  # Live, finalized videos of THIS profile's project with the entry's exact hash and size.
  defp candidates(%Profile{project_id: project_id}, %{sha256: hash, size_bytes: size}) do
    from(f in UploadedFile,
      where:
        f.project_id == ^project_id and is_nil(f.deleted_at) and f.content_hash == ^hash and
          f.byte_size == ^size and like(f.content_type, "video/%"),
      order_by: [desc: f.inserted_at, asc: f.id]
    )
    |> Repo.all()
    |> Enum.filter(&Platform.Files.finalized_upload?/1)
  end

  defp summary(file) do
    Map.take(file, [:id, :name, :byte_size, :content_hash, :content_type, :inserted_at])
  end

  # ── Choices ──────────────────────────────────────────────────────────

  # An entry with no usable ref cannot be chosen or named: it is reported by its position in the
  # export (0-based), never dropped silently.
  defp resolve(_profile, %{ref: nil, invalid: why}, _choices, index), do: {:invalid, index, why}

  defp resolve(_profile, %{ref: ref, invalid: invalid}, choices, _index)
       when not is_nil(invalid) do
    if Map.has_key?(choices, ref), do: {:rejected, ref, :invalid_entry}, else: {:unresolved, ref}
  end

  defp resolve(profile, %{ref: ref} = entry, choices, _index) do
    case Map.fetch(choices, ref) do
      :error ->
        {:unresolved, ref}

      {:ok, file_id} ->
        if Enum.any?(candidates(profile, entry), &(&1.id == file_id)),
          do: {:ok, intake_entry(entry, file_id)},
          else: {:rejected, ref, :not_a_candidate}
    end
  end

  # The intake entry: the choice, the expected hash and size, and the export's descriptive
  # fields. The export's file names and paths are not carried over.
  defp intake_entry(%{ref: ref, sha256: hash, size_bytes: size, raw: raw}, file_id) do
    %{"external_ref" => ref, "file_id" => file_id, "sha256" => hash, "size_bytes" => size}
    |> put_if("title", if(is_binary(raw["title"]), do: raw["title"]))
    |> put_if("speaker", speakers(raw["speakers"]))
    |> put_if("duration_s", if(is_number(raw["duration_s"]), do: raw["duration_s"]))
    |> put_if("approval_claim", if(is_map(raw["approval_claim"]), do: raw["approval_claim"]))
  end

  defp speakers([_ | _] = list), do: if(Enum.all?(list, &is_binary/1), do: Enum.join(list, ", "))
  defp speakers(_), do: nil

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
