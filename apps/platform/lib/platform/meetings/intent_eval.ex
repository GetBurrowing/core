defmodule Platform.Meetings.IntentEval do
  @moduledoc """
  The labelled intent-classification evaluation set and the file round-trip
  that maintains it (task `01a03fbb` stage 3).

  ## The set lives in `priv`, not in `test/support`

  `priv/intent_eval/` is committed AND shipped in the release payload.
  `test/support/` is compiled only under `MIX_ENV=test` and never leaves the
  repo, so a benchmark parked there could never be replayed against a running
  release — which is exactly what "did this config change make the classifier
  worse?" needs. The layout is:

      priv/intent_eval/manifest.json          — slice inventory, sha256s, provenance
      priv/intent_eval/slices/*.jsonl         — the labelled rows
      priv/intent_eval/candidates.jsonl       — sampler output (stage 2)
      priv/intent_eval/prelabels.jsonl        — strong-model pre-labels
      priv/intent_eval/adjudication/open.csv  — the human's work queue

  ## The three seed slices are COPIES, and that is recorded

  `negatives_102`, `control_60` and `unaddressed_probe_12` are normalisations
  of three fixtures authored on branch
  `task/01a03f57-362a-709f-801e-fb5cad1195e0`. The originals under
  `test/support/fixtures/` are deliberately left in place — that branch's own
  tests read them and deleting them here would break a sibling. The manifest's
  `provenance.duplicated_from` records the pairing and states which copy is
  canonical (this one). A later cleanup has what it needs; nothing is silently
  forked.

  Every row is normalised to one schema so a scoring run never branches on
  which slice a row came from:

      %{"id" => .., "text" => .., "label" => .., "slice" => .., "prior" => [],
        "origin" => "curated", "source_file" => .., "source_reason" => ..}

  ## Adjudication is a file round-trip on purpose

  `emit_open/2` writes a CSV of ONLY the rows a human needs to look at — where
  the strong model's pre-label disagrees with an existing slice label, or where
  its confidence is under the threshold. A human fills the `human_label` column
  in a spreadsheet and `ingest/3` merges it back. There is no screen, and the
  absence is a decision: a keyboard-driven agree/disagree LiveView is a real
  design surface with no design pass behind it, and the deliverable here is the
  harness and the set. If a screen turns out to be necessary it is a separate
  ticket with a design pass and a `manual_approval` gate.

  ## An agent may not adjudicate its own labels

  `ingest/3` refuses outright — nothing is written — when the ingesting
  identity matches the agent slug that produced the pre-label for any filled
  row. Adjudication exists to catch the pre-labeller being wrong; a
  pre-labeller confirming itself produces a set that agrees with the model by
  construction and measures nothing.

  ## An ingest is all-or-nothing (contract CHANGED, task `01a03fbb` stage 6)

  `ingest/4` originally merged whatever rows were filled and simply left
  `manifest["adjudicated"]` false while any open row was blank. It now refuses
  outright — writing nothing — with `{:error, {:incomplete, outstanding_ids}}`
  when fewer rows are filled than are open.

  The reason is contract consistency, not safety. The CSV is the human's own
  working file on disk, so refusing an incomplete ingest costs them nothing:
  they keep editing the spreadsheet and ingest when it is complete, and
  multi-sitting adjudication is unaffected. What the old behaviour did cost was
  a second refusal path obeying a different rule — the self-adjudication
  refusal writes nothing at all, while a partial CSV half-applied by design.
  Two refusals with two contracts is what bites someone at 2am.

  This does NOT protect against mis-filling: a fully-filled but wrong CSV
  corrupts the set just the same. That hazard is handled by the per-row
  `adjudicated_by` / `adjudicated_at` stamps and by the ingest being
  re-runnable, both of which already exist.

  ## Every pre-label row must carry `agent_slug`

  The self-adjudication check reads `prelabel["agent_slug"]` PER ROW. A
  prelabels file that carries the slug only in its header would pass the check
  by finding no slug to compare, not by finding no conflict — green because of
  what it is not looking at. `open_rows/2` therefore refuses a prelabels file
  with any row missing the slug, for the same reason an ingest with no `--by`
  is refused: an unattributed label is unauditable.
  """

  alias NimbleCSV.RFC4180, as: CSV

  @slices_dir "slices"
  @adjudication_dir "adjudication"
  @manifest_file "manifest.json"
  @open_csv "open.csv"
  @adjudicated_file "adjudicated.jsonl"
  @prelabels_file "prelabels.jsonl"

  @open_columns ~w(id text prior_context model_label model_rationale human_label note)

  @default_confidence_threshold 0.75

  @doc "Columns of `adjudication/open.csv`, in order."
  def open_columns, do: @open_columns

  @doc "Confidence below which a pre-label is sent to a human even when it agrees."
  def default_confidence_threshold, do: @default_confidence_threshold

  @doc """
  The evaluation-set root. Defaults to the shipped `priv/intent_eval`; tests
  pass their own `:root` so they never mutate the committed set.
  """
  def root(opts \\ []) do
    case Keyword.get(opts, :root) do
      root when is_binary(root) -> root
      _ -> Path.join(:code.priv_dir(:platform), "intent_eval")
    end
  end

  def manifest_path(root), do: Path.join(root, @manifest_file)
  def slices_dir(root), do: Path.join(root, @slices_dir)
  def slice_path(root, name), do: Path.join(slices_dir(root), "#{name}.jsonl")
  def adjudication_dir(root), do: Path.join(root, @adjudication_dir)
  def open_csv_path(root), do: Path.join(adjudication_dir(root), @open_csv)
  def adjudicated_path(root), do: Path.join(adjudication_dir(root), @adjudicated_file)
  def prelabels_path(root), do: Path.join(root, @prelabels_file)

  # ── manifest ──────────────────────────────────────────────────────────

  def read_manifest!(root), do: root |> manifest_path() |> File.read!() |> Jason.decode!()

  def write_manifest!(root, manifest) do
    File.mkdir_p!(root)
    File.write!(manifest_path(root), Jason.encode!(manifest, pretty: true) <> "\n")
    manifest
  end

  @doc "Lowercase hex sha256 of a file's bytes."
  def digest(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  @doc """
  Compare every slice file's sha256 against the digest recorded in the
  manifest. This is what makes an unrecorded edit to a slice loud: change one
  byte of a labelled row and the set no longer matches its own inventory.
  """
  def verify_slices(root) do
    manifest = read_manifest!(root)

    mismatched =
      manifest
      |> Map.fetch!("slices")
      |> Enum.filter(fn slice ->
        path = Path.join(root, slice["file"])
        not File.exists?(path) or digest(path) != slice["sha256"]
      end)
      |> Enum.map(& &1["name"])

    if mismatched == [], do: :ok, else: {:error, {:digest_mismatch, mismatched}}
  end

  @doc """
  Recompute every slice digest and row count into the manifest. The deliberate
  counterpart to `verify_slices/1`: editing a slice is legal, editing it
  *without running this* is not.
  """
  def refresh_digests!(root) do
    manifest = read_manifest!(root)

    slices =
      Enum.map(manifest["slices"], fn slice ->
        path = Path.join(root, slice["file"])
        {_header, rows} = read_jsonl(path)

        slice
        |> Map.put("sha256", digest(path))
        |> Map.put("count", length(rows))
      end)

    write_manifest!(root, Map.put(manifest, "slices", slices))
  end

  # ── jsonl ─────────────────────────────────────────────────────────────

  @doc """
  Read a JSONL file as `{header_or_nil, rows}`. The first line is treated as a
  header when it carries `"header": true` — the shape the stage-2 sampler
  writes.
  """
  def read_jsonl(path) do
    decoded =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    case decoded do
      [%{"header" => true} = header | rows] -> {header, rows}
      rows -> {nil, rows}
    end
  end

  def write_jsonl!(path, header, rows) do
    File.mkdir_p!(Path.dirname(path))

    body =
      [header | rows]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&[Jason.encode!(&1), "\n"])
      |> IO.iodata_to_binary()

    File.write!(path, body)
  end

  @doc "Every labelled row across every slice named in the manifest, keyed by id."
  def load_slice_rows(root) do
    root
    |> read_manifest!()
    |> Map.fetch!("slices")
    |> Enum.flat_map(fn slice ->
      {_header, rows} = read_jsonl(Path.join(root, slice["file"]))
      rows
    end)
    |> Map.new(&{&1["id"], &1})
  end

  def read_prelabels(root) do
    path = prelabels_path(root)

    if File.exists?(path) do
      {_header, rows} = read_jsonl(path)
      rows
    else
      []
    end
  end

  def read_adjudicated(root) do
    path = adjudicated_path(root)

    if File.exists?(path) do
      {_header, rows} = read_jsonl(path)
      Map.new(rows, &{&1["id"], &1})
    else
      %{}
    end
  end

  # ── open set ──────────────────────────────────────────────────────────

  @doc """
  Rows a human has to look at: the pre-label disagrees with an existing slice
  label, or its confidence is below `:threshold`. Everything else is left
  alone — the point of a pre-label pass is that the confident agreements never
  reach a person.
  """
  def open_rows(root, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_confidence_threshold)
    slice_rows = load_slice_rows(root)

    root
    |> read_prelabels()
    |> validate_prelabel_slugs!()
    |> Enum.filter(fn prelabel ->
      prior = Map.get(slice_rows, prelabel["id"])
      disagrees?(prior, prelabel) or low_confidence?(prelabel, threshold)
    end)
    |> Enum.map(fn prelabel ->
      prior = Map.get(slice_rows, prelabel["id"], %{})

      %{
        "id" => prelabel["id"],
        "text" => prelabel["text"] || prior["text"] || "",
        "prior_context" => prior_context(prelabel, prior),
        "model_label" => prelabel["label"],
        "model_rationale" => prelabel["rationale"] || "",
        "prelabel_agent" => prelabel["agent_slug"],
        "slice_label" => prior["label"]
      }
    end)
    |> Enum.sort_by(& &1["id"])
  end

  # A prelabels row with no `agent_slug` silently disables the
  # self-adjudication guard: the guard would pass because it found no slug to
  # match, not because there was no conflict. Refuse instead.
  defp validate_prelabel_slugs!(prelabels) do
    missing =
      prelabels
      |> Enum.reject(fn row -> is_binary(row["agent_slug"]) and row["agent_slug"] != "" end)
      |> Enum.map(&(&1["id"] || "<no id>"))
      |> Enum.sort()

    if missing != [] do
      raise ArgumentError,
            "refusing to use prelabels: #{length(missing)} row(s) carry no agent_slug " <>
              "(#{Enum.join(Enum.take(missing, 5), ", ")}). A per-row slug is what the " <>
              "self-adjudication check compares against; without it the check passes because " <>
              "there is nothing to match, not because there is no conflict. A header-only " <>
              "slug is not enough — stamp every row."
    end

    prelabels
  end

  defp disagrees?(nil, _prelabel), do: false
  defp disagrees?(prior, prelabel), do: prior["label"] != prelabel["label"]

  defp low_confidence?(prelabel, threshold) do
    case prelabel["confidence"] do
      value when is_number(value) -> value < threshold
      # A pre-label with no confidence at all is not evidence of agreement.
      _ -> true
    end
  end

  defp prior_context(prelabel, prior) do
    (prelabel["prior"] || prior["prior"] || [])
    |> Enum.map(fn
      %{"text" => text} -> text
      other when is_binary(other) -> other
      other -> inspect(other)
    end)
    |> Enum.join(" ⏎ ")
  end

  @doc """
  Write `adjudication/open.csv`. Returns `{:ok, path, count}`.
  """
  def emit_open(root, opts \\ []) do
    rows = open_rows(root, opts)
    path = open_csv_path(root)
    File.mkdir_p!(Path.dirname(path))

    body =
      [@open_columns | Enum.map(rows, &csv_row/1)]
      |> CSV.dump_to_iodata()
      |> IO.iodata_to_binary()

    File.write!(path, body)
    {:ok, path, length(rows)}
  end

  defp csv_row(row) do
    [
      row["id"],
      row["text"],
      row["prior_context"],
      row["model_label"] || "",
      row["model_rationale"] || "",
      "",
      ""
    ]
  end

  @doc """
  Merge a filled `open.csv` back into the set.

  Refuses, writing nothing, when `adjudicated_by` matches the agent slug that
  produced the pre-label for any filled row, and — since stage 6 — when any
  open row is still blank (`{:error, {:incomplete, ids}}`). An ingest is
  all-or-nothing; see the moduledoc for why the contract changed.
  """
  def ingest(root, csv_path, adjudicated_by, opts \\ []) do
    filled = csv_path |> parse_open_csv() |> Enum.filter(&(String.trim(&1["human_label"]) != ""))
    open = open_rows(root, opts)
    by_id = Map.new(open, &{&1["id"], &1})

    self_adjudicated =
      filled
      |> Enum.filter(fn row ->
        case Map.get(by_id, row["id"]) do
          %{"prelabel_agent" => agent} when is_binary(agent) -> agent == adjudicated_by
          _ -> false
        end
      end)
      |> Enum.map(& &1["id"])

    filled_ids = MapSet.new(filled, & &1["id"])

    outstanding =
      open |> Enum.reject(&MapSet.member?(filled_ids, &1["id"])) |> Enum.map(& &1["id"])

    cond do
      self_adjudicated != [] ->
        {:error, {:self_adjudication, adjudicated_by, Enum.sort(self_adjudicated)}}

      # All-or-nothing, and refused BEFORE anything is written.
      outstanding != [] ->
        {:error, {:incomplete, Enum.sort(outstanding)}}

      true ->
        do_ingest(root, filled, by_id, open, adjudicated_by)
    end
  end

  defp do_ingest(root, filled, by_id, open, adjudicated_by) do
    at = DateTime.utc_now() |> DateTime.to_iso8601()

    merged =
      Enum.reduce(filled, read_adjudicated(root), fn row, acc ->
        open_row = Map.get(by_id, row["id"], %{})

        Map.put(acc, row["id"], %{
          "id" => row["id"],
          "human_label" => String.trim(row["human_label"]),
          "note" => String.trim(row["note"] || ""),
          "model_label" => open_row["model_label"],
          "prelabel_agent" => open_row["prelabel_agent"],
          "adjudicated_by" => adjudicated_by,
          "adjudicated_at" => at
        })
      end)

    rows = merged |> Map.values() |> Enum.sort_by(& &1["id"])

    write_jsonl!(
      adjudicated_path(root),
      %{"header" => true, "count" => length(rows), "kind" => "adjudications"},
      rows
    )

    outstanding = Enum.reject(open, &Map.has_key?(merged, &1["id"]))
    complete? = open != [] and outstanding == []

    manifest =
      root
      |> read_manifest!()
      |> Map.put("adjudicated", complete?)
      |> Map.put("adjudication", %{
        "open" => length(open),
        "adjudicated" => length(rows),
        "outstanding" => Enum.map(outstanding, & &1["id"]),
        "last_ingest_by" => adjudicated_by,
        "last_ingest_at" => at
      })

    write_manifest!(root, manifest)

    {:ok,
     %{
       merged: length(filled),
       open: length(open),
       outstanding: length(outstanding),
       adjudicated: complete?,
       manifest: manifest
     }}
  end

  @doc "Parse a filled `open.csv` into a list of column-keyed maps."
  def parse_open_csv(path) do
    [header | rows] = path |> File.read!() |> CSV.parse_string(skip_headers: false)

    Enum.map(rows, fn row ->
      header |> Enum.zip(pad(row, length(header))) |> Map.new()
    end)
  end

  defp pad(row, size) when length(row) >= size, do: row
  defp pad(row, size), do: row ++ List.duplicate("", size - length(row))
end
