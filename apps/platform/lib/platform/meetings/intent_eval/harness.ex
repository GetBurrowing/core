defmodule Platform.Meetings.IntentEval.Harness do
  @moduledoc """
  The offline scoring harness for the labelled intent-classification set
  (task `01a03fbb` stage 4).

  ## Why this exists

  Three measurement runs over the SAME 102 rows reported 7, 8 and an
  unreproducible 23. The discrepancy was not the model: one arm read the
  live `prompt_templates` row while another read a migration heredoc, and
  nothing in either instrument recorded which. So the harness resolves the
  prompt from an EXPLICIT source and records both the resolved source and
  `sha256(rendered_prompt)` into the run manifest. Two runs that disagree
  can now be told apart in one `diff`.

  ## Configs are committed data, not code

  `priv/intent_eval/configs/<name>.json`:

      {"prompt_source": {"db_slug"|"migration"|"inline_file" => ..},
       "model": .., "base_url": .., "temperature": .., "max_tokens": ..,
       "chat_template_kwargs": {..}, "buffering": {..}}

  `prompt_source` is explicit and single-keyed. There is no "whatever the
  runtime would have used" default, because that default is the bug.

  ## It measures the PIPELINE, not the model

  Every row goes through `Platform.Meetings.IntentClassifier.decide/1` — the
  same provider-call → parse → outcome path production walks.
  `parse_error`, `empty_output` and `model_error` are FIRST-CLASS outcome
  classes reported alongside the intent labels. They are never folded into
  `off_topic` and never dropped: a row that errored is not a row that
  declined, and conflating the two is what made 83 of 102 correct declines
  read as parse failures in one instrument.

  `demoted` is counted too, but it is NOT an error class. A positive that
  fails the classifier's evidence gate is a successful classification that
  was downgraded to `off_topic`; the pipeline really did decide `off_topic`,
  so the row keeps that prediction and no error class. `demoted` is a
  separate axis over the `{:ok, _}` outcomes, read from `decide/1`'s
  `:demoted_from`. It lived in the error taxonomy until task `01a04379`,
  where the `{:error, {:demoted, _}}` clause that fed it turned out to be
  structurally unmatchable — `decide/1` returns only atom error reasons —
  so the column read zero on every run ever published while the
  `binary_actionable` cassette demoted 93 of its 174 rows.

  ## Record and replay

  `--record` calls the live endpoint and appends every response to
  `priv/intent_eval/cassettes/<config>.jsonl`. `--replay` (the default when
  a cassette exists) reads only the cassette and touches no network. A
  replay miss FAILS the run, naming the missing keys and their count —
  it never falls through to a live call and never scores the row as an
  error.
  """

  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentEval
  alias Platform.Meetings.IntentEval.Cassette
  alias Platform.Meetings.IntentEval.CassetteProvider
  alias Platform.Orchestration.PromptTemplates

  @error_classes ~w(parse_error empty_output model_error)

  @doc "The outcome classes that are errors, not intents."
  def error_classes, do: @error_classes

  @doc "Directory holding the committed configs."
  def configs_dir(root), do: Path.join(root, "configs")
  def config_path(root, name), do: Path.join(configs_dir(root), "#{name}.json")
  def prompts_dir(root), do: Path.join(root, "prompts")
  def runs_dir(root), do: Path.join(root, "runs")

  # ── config ────────────────────────────────────────────────────────────

  @doc """
  Read and validate a config. Validation is loud on purpose: an unreadable
  or ambiguous `prompt_source` is the exact failure this whole task exists
  to remove, so it stops the run rather than picking a default.
  """
  def load_config!(root, name) do
    path = config_path(root, name)

    unless File.exists?(path) do
      raise ArgumentError, "no config #{inspect(name)} at #{path}"
    end

    raw = File.read!(path)
    config = Jason.decode!(raw)

    validate_prompt_source!(config)
    validate_buffering!(config)

    Map.merge(config, %{
      "name" => name,
      "path" => path,
      "sha256" => sha256(raw)
    })
  end

  defp validate_prompt_source!(config) do
    case Map.get(config, "prompt_source") do
      %{} = source when map_size(source) == 1 ->
        key = source |> Map.keys() |> hd()

        unless key in ~w(db_slug migration inline_file) do
          raise ArgumentError,
                "prompt_source key #{inspect(key)} is not one of db_slug | migration | inline_file"
        end

        :ok

      %{} = ambiguous ->
        raise ArgumentError,
              "prompt_source must name exactly ONE source, got #{inspect(Map.keys(ambiguous))} — " <>
                "an ambiguous source is the defect this harness exists to prevent"

      other ->
        raise ArgumentError,
              "prompt_source is required and must be an object, got #{inspect(other)}"
    end
  end

  # A non-zero debounce would mean the harness is scoring MERGED utterances
  # while the set is labelled per-utterance. Refused rather than silently
  # ignored: a config field that reads as applied but is not is the same
  # class of lie as an implicit prompt source.
  defp validate_buffering!(config) do
    buffering = Map.get(config, "buffering") || %{}

    if Map.get(buffering, "debounce_ms", 0) not in [0, nil] do
      raise ArgumentError,
            "buffering.debounce_ms must be 0 — the eval set is labelled per utterance, so the " <>
              "harness classifies one row at a time and cannot honour a merge window"
    end

    :ok
  end

  # ── prompt resolution ─────────────────────────────────────────────────

  @doc """
  Resolve a config's prompt to `{resolved_source_description, template_body}`.

  `db_slug` reads the LIVE `prompt_templates` row; `migration` extracts a
  heredoc module attribute from a migration file; `inline_file` reads a
  committed text file. The description is recorded verbatim in the manifest.
  """
  def resolve_prompt!(config, opts \\ []) do
    repo_root = Keyword.get(opts, :repo_root, File.cwd!())

    case config["prompt_source"] do
      %{"db_slug" => slug} ->
        case PromptTemplates.get_template_by_slug(slug) do
          nil ->
            raise ArgumentError,
                  "prompt_source db_slug #{inspect(slug)} has no row in prompt_templates — " <>
                    "refusing to fall back to an inline default, which would make the run " <>
                    "unattributable"

          %{content: content} ->
            {%{"kind" => "db_slug", "slug" => slug}, content}
        end

      %{"migration" => relative} ->
        path = Path.expand(relative, repo_root)
        {attribute, body} = extract_migration_heredoc!(path, config["prompt_attribute"])
        {%{"kind" => "migration", "path" => relative, "attribute" => attribute}, body}

      %{"inline_file" => relative} ->
        path = Path.expand(relative, repo_root)

        unless File.exists?(path) do
          raise ArgumentError, "prompt_source inline_file #{relative} does not exist at #{path}"
        end

        {%{"kind" => "inline_file", "path" => relative}, File.read!(path)}
    end
  end

  @doc """
  Pull a heredoc-valued module attribute out of a migration file.

  A migration is Elixir source, not data, so this reads the literal heredoc
  rather than evaluating the module: evaluating would run `up/0` and hit the
  database, which an offline harness must never do.
  """
  def extract_migration_heredoc!(path, attribute \\ nil) do
    unless File.exists?(path) do
      raise ArgumentError, "prompt_source migration #{path} does not exist"
    end

    source = File.read!(path)

    matches =
      Regex.scan(~r/@([a-z_][a-zA-Z0-9_]*)\s+"""\n(.*?)\n\s*"""/s, source)
      |> Enum.map(fn [_, name, body] -> {name, body} end)

    candidates =
      case attribute do
        nil -> matches
        name -> Enum.filter(matches, fn {found, _} -> found == name end)
      end

    case candidates do
      [{name, body} | _] ->
        {name, dedent(body) <> "\n"}

      [] ->
        raise ArgumentError,
              "migration #{path} has no heredoc attribute #{inspect(attribute || "(any)")}"
    end
  end

  # Heredoc bodies in a migration are indented to the `"""` column. Strip
  # the common indent so the extracted text is byte-comparable with the
  # rendered DB row it was written to produce.
  defp dedent(body) do
    lines = String.split(body, "\n")

    indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn line -> String.length(line) - String.length(String.trim_leading(line)) end)
      |> Enum.min(fn -> 0 end)

    lines
    |> Enum.map(fn line -> String.slice(line, indent..-1//1) || "" end)
    |> Enum.join("\n")
  end

  @doc """
  Assigns used to render the prompt for ONE row. Mirrors the classifier's
  own `resolve_prompt/6` so the harness renders the same variables
  production renders.
  """
  def assigns_for(row) do
    prior = row["prior"] || []

    %{
      meeting_transcript_chunk: row["text"],
      transcript_chunk: row["text"],
      speaker: row["speaker"] || "Speaker",
      room_id: "intent-eval",
      context_lines: context_lines(prior),
      context_present: prior != [],
      correction_exemplars: "(no prior corrections)"
    }
  end

  defp context_lines([]), do: "(no prior context)"

  defp context_lines(prior),
    do: prior |> Enum.map(&"- #{&1}") |> Enum.join("\n")

  @doc """
  The prompt FINGERPRINT: the template rendered with an empty utterance and
  the empty-context sentinels.

  Rendering per row would give 174 different shas and fingerprint nothing.
  Rendering the raw template would miss a change in how the harness fills
  it. So the fingerprint is the rendered shape with the row removed — it
  changes when the prompt changes and is stable across rows.
  """
  def fingerprint(template) do
    template
    |> interpolate(assigns_for(%{"text" => "", "prior" => []}))
    |> sha256()
  end

  @doc "`{{key}}` substitution, same semantics as `PromptTemplates.interpolate/2`."
  def interpolate(template, assigns) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _match, key ->
      value =
        case Map.fetch(assigns, safe_atom(key)) do
          {:ok, value} -> value
          :error -> Map.get(assigns, key, "")
        end

      to_string(value)
    end)
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  # ── rows ──────────────────────────────────────────────────────────────

  @doc """
  Every labelled row for a run, in manifest slice order. `--slice` narrows
  to one slice; the per-slice breakdown is reported either way.
  """
  def load_rows(root, slice_filter \\ nil) do
    manifest = IntentEval.read_manifest!(root)

    manifest["slices"]
    |> Enum.filter(fn slice -> is_nil(slice_filter) or slice["name"] == slice_filter end)
    |> case do
      [] ->
        raise ArgumentError,
              "no slice named #{inspect(slice_filter)} in #{IntentEval.manifest_path(root)}"

      slices ->
        Enum.flat_map(slices, fn slice ->
          {_header, rows} = IntentEval.read_jsonl(Path.join(root, slice["file"]))
          Enum.map(rows, &Map.put(&1, "slice", &1["slice"] || slice["name"]))
        end)
    end
  end

  @doc "Slice inventory (name, file, sha256) for the run manifest."
  def slice_manifest(root, slice_filter \\ nil) do
    root
    |> IntentEval.read_manifest!()
    |> Map.fetch!("slices")
    |> Enum.filter(fn slice -> is_nil(slice_filter) or slice["name"] == slice_filter end)
    |> Enum.map(fn slice ->
      %{
        "name" => slice["name"],
        "file" => slice["file"],
        "sha256" => IntentEval.digest(Path.join(root, slice["file"])),
        "count" => slice["count"]
      }
    end)
  end

  # ── the run ───────────────────────────────────────────────────────────

  @doc """
  Run a config over the set.

  Options:

    * `:root` — eval-set root (default the shipped `priv/intent_eval`)
    * `:mode` — `:record` | `:replay` | `:auto` (default `:auto`, which is
      `:replay` when a cassette exists and `:record` when it does not)
    * `:slice` — restrict to one slice
    * `:live_module` — provider used in `:record` mode
    * `:repo_root` — base for relative `migration` / `inline_file` paths
    * `:write` — write the run JSON (default `true`)

  Returns `{:ok, result}` or `{:error, {:cassette_miss, %{count:, keys:, rows:}}}`.
  """
  def run(config_name, opts \\ []) do
    root = Keyword.get_lazy(opts, :root, fn -> IntentEval.root() end)
    repo_root = Keyword.get(opts, :repo_root, File.cwd!())
    slice_filter = Keyword.get(opts, :slice)
    config = load_config!(root, config_name)

    {source, template} = resolve_prompt!(config, repo_root: repo_root)
    rows = load_rows(root, slice_filter)

    cassette_path = Cassette.path(root, config_name)
    cassette = Cassette.load(cassette_path)
    mode = resolve_mode(Keyword.get(opts, :mode, :auto), cassette)

    prepared =
      Enum.map(rows, fn row ->
        prompt = interpolate(template, assigns_for(row))
        Map.merge(row, %{"prompt" => prompt, "key" => Cassette.key(prompt, row["text"])})
      end)

    with :ok <- check_cassette!(mode, prepared, cassette, cassette_path) do
      started_at = DateTime.utc_now()

      CassetteProvider.arm(%{
        mode: mode,
        cassette: cassette,
        live_module: Keyword.get(opts, :live_module, Platform.Agents.Providers.Ollama),
        opts_override: opts_override(config)
      })

      agent = %{
        base_url: config["base_url"],
        model: config["model"],
        vault_key: nil
      }

      scored = Enum.map(prepared, &classify(&1, agent))

      if mode == :record do
        Cassette.append!(cassette_path, CassetteProvider.recorded())
      end

      finished_at = DateTime.utc_now()

      manifest =
        run_manifest(config, source, template, root, slice_filter, mode, started_at, finished_at)

      result = %{
        "manifest" => manifest,
        "summary" => summarise(scored),
        "rows" => Enum.map(scored, &public_row/1)
      }

      path =
        if Keyword.get(opts, :write, true) do
          write_run!(root, config_name, started_at, result)
        end

      {:ok, Map.put(result, "run_file", path)}
    end
  end

  defp resolve_mode(:auto, cassette), do: if(map_size(cassette) == 0, do: :record, else: :replay)
  defp resolve_mode(mode, _cassette) when mode in [:record, :replay], do: mode

  # The replay pre-check. It runs BEFORE any row is classified, so a miss can
  # never be rescued by `decide/1` into `:model_error` and can never be
  # scored. The run stops; the numbers are not produced at all rather than
  # produced wrong.
  defp check_cassette!(:record, _prepared, _cassette, _path), do: :ok

  defp check_cassette!(:replay, prepared, cassette, path) do
    missing = Enum.reject(prepared, &Map.has_key?(cassette, &1["key"]))

    if missing == [] do
      :ok
    else
      {:error,
       {:cassette_miss,
        %{
          count: length(missing),
          total: length(prepared),
          cassette: path,
          keys: Enum.map(missing, & &1["key"]),
          rows: Enum.map(missing, & &1["id"])
        }}}
    end
  end

  defp opts_override(config) do
    [
      temperature: config["temperature"],
      max_tokens: config["max_tokens"],
      chat_template_kwargs: config["chat_template_kwargs"]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp classify(row, agent) do
    outcome =
      IntentClassifier.decide(%{
        provider_module: CassetteProvider,
        agent: agent,
        prompt: row["prompt"],
        chunk_text: row["text"],
        room_id: "intent-eval"
      })

    latency = CassetteProvider.last_latency_ms()
    content = CassetteProvider.last_content()

    {predicted, error_class} =
      case outcome do
        {:ok, %{intent: intent}} -> {intent, nil}
        {:error, class} when is_atom(class) -> {to_string(class), to_string(class)}
      end

    Map.merge(row, %{
      "predicted" => predicted,
      "error_class" => error_class,
      "demoted_from" => demoted_from(outcome),
      "target_role" => target_role(outcome),
      "confidence" => confidence(outcome),
      "response_parseable" => json_object?(content),
      "latency_ms" => latency
    })
  end

  # Did the model emit a JSON object at all? A `parse_error` says the
  # pipeline could not use the answer; it does not say whether the answer was
  # well-formed JSON the schema rejected or prose that was never JSON. Those
  # are different problems and, before this counter, printed the same report.
  defp json_object?(content) when is_binary(content) do
    match?({:ok, %{}}, Jason.decode(content))
  end

  defp json_object?(_), do: false

  # Non-nil ONLY for a row the evidence gate downgraded. It is read from
  # the `{:ok, _}` outcome, not from an error shape: demotion is not an
  # error, and the `{:error, {:demoted, _}}` clause that used to sit in
  # `classify/2` could never match `decide/1`'s atom-only error reasons.
  defp demoted_from({:ok, %{demoted_from: intent}}) when is_binary(intent), do: intent
  defp demoted_from(_), do: nil

  defp target_role({:ok, %{target_role: role}}), do: role
  defp target_role(_), do: nil
  defp confidence({:ok, %{confidence: confidence}}), do: confidence
  defp confidence(_), do: nil

  defp public_row(row), do: Map.drop(row, ["prompt"])

  # ── scoring ───────────────────────────────────────────────────────────

  @doc """
  Score classified rows.

  Error classes are counted in their OWN bucket and appear as their own
  columns in the confusion matrix. They are never added to `off_topic`, and
  they are never dropped from the row count — the three numbers
  (`intent_predictions + errors == total`) have to reconcile or the report
  is hiding something.
  """
  def summarise(scored) do
    labels =
      scored
      |> Enum.flat_map(fn row -> [row["label"], predicted_intent(row)] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "total" => length(scored),
      "labels" => labels,
      "error_classes" => error_counts(scored),
      "errors_total" => Enum.count(scored, & &1["error_class"]),
      # An OUTCOME count, deliberately outside `error_classes`: a demoted
      # row predicted `off_topic` and carries no error class, so it is
      # already counted under `off_topic` and must not be added to
      # `errors_total`. The two taxonomies do not share a bucket.
      "demoted" => demoted_count(scored),
      "parseable_bodies" => Enum.count(scored, & &1["response_parseable"]),
      "per_class" => Map.new(labels, &{&1, class_metrics(scored, &1)}),
      "confusion" => confusion(scored),
      "per_slice" => per_slice(scored),
      "latency_ms" => latency_percentiles(scored)
    }
  end

  defp demoted_count(scored), do: Enum.count(scored, & &1["demoted_from"])

  defp error_counts(scored) do
    Map.new(@error_classes, fn class ->
      {class, Enum.count(scored, &(&1["error_class"] == class))}
    end)
  end

  defp class_metrics(scored, label) do
    # A row whose outcome is an error class predicted NOTHING. It cannot be
    # a true positive or a false positive for any intent; it is a false
    # negative for its gold label, because the gold answer did not come out.
    tp = Enum.count(scored, &(&1["label"] == label and predicted_intent(&1) == label))
    fp = Enum.count(scored, &(&1["label"] != label and predicted_intent(&1) == label))
    fn_ = Enum.count(scored, &(&1["label"] == label and predicted_intent(&1) != label))

    precision = ratio(tp, tp + fp)
    recall = ratio(tp, tp + fn_)

    %{
      "support" => Enum.count(scored, &(&1["label"] == label)),
      "predicted" => tp + fp,
      "true_positives" => tp,
      "false_positives" => fp,
      "false_negatives" => fn_,
      "precision" => precision,
      "recall" => recall,
      "f1" => ratio(2 * precision * recall, precision + recall)
    }
  end

  defp predicted_intent(%{"error_class" => class}) when is_binary(class), do: nil
  defp predicted_intent(%{"predicted" => predicted}), do: predicted

  defp ratio(_num, 0), do: 0.0
  defp ratio(_num, +0.0), do: 0.0
  defp ratio(num, den), do: Float.round(num / den, 4)

  defp confusion(scored) do
    scored
    |> Enum.group_by(& &1["label"])
    |> Map.new(fn {label, rows} ->
      {label, rows |> Enum.frequencies_by(& &1["predicted"])}
    end)
  end

  defp per_slice(scored) do
    scored
    |> Enum.group_by(& &1["slice"])
    |> Map.new(fn {slice, rows} ->
      {slice,
       %{
         "rows" => length(rows),
         "correct" => Enum.count(rows, &(predicted_intent(&1) == &1["label"])),
         "fired" => Enum.count(rows, &fired?/1),
         "off_topic" => Enum.count(rows, &(predicted_intent(&1) == "off_topic")),
         "demoted" => demoted_count(rows),
         "errors" => Enum.count(rows, & &1["error_class"]),
         "error_classes" => error_counts(rows)
       }}
    end)
  end

  @doc """
  Did this row produce a dispatchable intent? An error is NOT a firing and
  NOT a decline — it is its own thing, which is why this is a three-way
  question and not a boolean over two buckets.
  """
  def fired?(row) do
    is_nil(row["error_class"]) and row["predicted"] not in [nil, "off_topic"]
  end

  defp latency_percentiles(scored) do
    samples = scored |> Enum.map(& &1["latency_ms"]) |> Enum.reject(&is_nil/1) |> Enum.sort()

    %{
      "count" => length(samples),
      "p50" => percentile(samples, 0.5),
      "p95" => percentile(samples, 0.95)
    }
  end

  defp percentile([], _q), do: nil

  defp percentile(sorted, q) do
    index = min(length(sorted) - 1, max(0, round(q * (length(sorted) - 1))))
    Enum.at(sorted, index)
  end

  # ── manifest + output ─────────────────────────────────────────────────

  defp run_manifest(config, source, template, root, slice_filter, mode, started_at, finished_at) do
    %{
      "config" => %{
        "name" => config["name"],
        "sha256" => config["sha256"],
        "path" => config["path"]
      },
      "prompt" => %{
        "source" => source,
        "rendered_sha256" => fingerprint(template),
        "template_sha256" => sha256(template),
        "bytes" => byte_size(template)
      },
      "model" => config["model"],
      "base_url_host" => base_url_host(config["base_url"]),
      "temperature" => config["temperature"],
      "max_tokens" => config["max_tokens"],
      "chat_template_kwargs" => config["chat_template_kwargs"],
      "buffering" => config["buffering"],
      "mode" => to_string(mode),
      "slice_filter" => slice_filter,
      "slices" => slice_manifest(root, slice_filter),
      "harness_git_sha" => git_sha(),
      "started_at" => DateTime.to_iso8601(started_at),
      "finished_at" => DateTime.to_iso8601(finished_at),
      "wall_clock_seconds" => DateTime.diff(finished_at, started_at, :millisecond) / 1000
    }
  end

  # Only the HOST is recorded. A base_url can carry a token in its userinfo
  # and a run manifest is a committed artefact.
  defp base_url_host(nil), do: nil

  defp base_url_host(url) do
    case URI.parse(url) do
      %URI{host: host, port: port} when is_binary(host) -> "#{host}:#{port}"
      _ -> "(unparseable)"
    end
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "(unknown)"
    end
  rescue
    _ -> "(unknown)"
  end

  defp write_run!(root, config_name, started_at, result) do
    stamp =
      started_at
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/\.\d+/, "")

    path = Path.join(runs_dir(root), "#{stamp}-#{config_name}.json")
    File.mkdir_p!(runs_dir(root))
    File.write!(path, Jason.encode!(result, pretty: true) <> "\n")
    path
  end

  def sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  # ── human-readable report ─────────────────────────────────────────────

  @doc "Render a run result as the text written to stdout."
  def report(result) do
    manifest = result["manifest"]
    summary = result["summary"]

    [
      "INTENT_EVAL config=#{manifest["config"]["name"]} mode=#{manifest["mode"]} rows=#{summary["total"]}",
      "  prompt source : #{inspect(manifest["prompt"]["source"])}",
      "  prompt sha256 : #{manifest["prompt"]["rendered_sha256"]}",
      "  config sha256 : #{manifest["config"]["sha256"]}",
      "  model         : #{manifest["model"]} @ #{manifest["base_url_host"]}",
      "  harness sha   : #{manifest["harness_git_sha"]}",
      "  wall clock    : #{manifest["wall_clock_seconds"]}s",
      "",
      "OUTCOME CLASSES (errors are NOT declines and are counted separately)",
      "  errors total  : #{summary["errors_total"]}",
      # NOT an error, so it is printed above the error list rather than in
      # it: a demoted row is a successful `off_topic` decision and is
      # already counted as one. See the moduledoc on task 01a04379.
      "  demoted       : #{summary["demoted"]} uncited positives downgraded to off_topic (counted as off_topic, not as errors)",
      # Separates \"the model declines everything in valid JSON\" from \"the
      # model never emits JSON at all\" — identical parse_error counts.
      "  JSON bodies   : #{summary["parseable_bodies"]} of #{summary["total"]} responses parsed as a JSON object",
      Enum.map(@error_classes, fn class ->
        "    #{String.pad_trailing(class, 13)}: #{summary["error_classes"][class]}"
      end),
      "",
      "PER CLASS",
      Enum.map(summary["per_class"], fn {label, metrics} ->
        "  #{String.pad_trailing(label, 20)} support=#{metrics["support"]} " <>
          "P=#{metrics["precision"]} R=#{metrics["recall"]} F1=#{metrics["f1"]}"
      end),
      "",
      "PER SLICE",
      Enum.map(summary["per_slice"], fn {slice, stats} ->
        "  #{String.pad_trailing(slice, 22)} rows=#{stats["rows"]} correct=#{stats["correct"]} " <>
          "fired=#{stats["fired"]} off_topic=#{stats["off_topic"]} " <>
          "demoted=#{stats["demoted"]} errors=#{stats["errors"]}"
      end),
      "",
      "CONFUSION (gold -> predicted, error classes included as their own columns)",
      Enum.map(summary["confusion"], fn {label, predictions} ->
        "  #{String.pad_trailing(label, 20)} #{inspect(predictions)}"
      end),
      "",
      "LATENCY ms p50=#{summary["latency_ms"]["p50"]} p95=#{summary["latency_ms"]["p95"]}",
      "RUN FILE #{result["run_file"]}"
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc "Render a cassette-miss failure. Loud by design: keys and count."
  def miss_report(%{count: count, total: total, cassette: cassette, keys: keys, rows: rows}) do
    """
    INTENT_EVAL REPLAY FAILED — #{count} of #{total} rows have no recorded response.

      cassette: #{cassette}

    A replay run does NOT fall through to a live call and does NOT score a
    missing row as an error. Record the missing rows against the live
    endpoint (--record) or replay a config whose cassette is complete.

    missing row ids : #{Enum.join(Enum.take(rows, 20), ", ")}#{if count > 20, do: " … (#{count} total)", else: ""}
    missing keys    : #{Enum.join(Enum.take(keys, 20), ", ")}#{if count > 20, do: " … (#{count} total)", else: ""}
    """
  end
end
