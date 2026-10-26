defmodule Platform.Meetings.IntentEval.HarnessTest do
  @moduledoc """
  Coverage for the offline intent-eval harness (task `01a03fbb` stage 4).

  Every guard here is paired with a control that shows it DISCRIMINATING,
  because a guard that fires on everything proves nothing:

    * the cassette-miss failure is paired with a complete-cassette replay
      that succeeds;
    * the prompt-sha recording is paired with two configs pointed at
      deliberately different text, so the assertion is inequality, not
      merely presence;
    * the error-class separation is asserted in BOTH halves — a case
      engineered to error asserts a NON-ZERO error count and that `off_topic`
      was not inflated, and a clean case asserts a ZERO error count with a
      non-zero `off_topic`. Either half alone is passed by an implementation
      that never produces an error row at all.
  """

  use Platform.DataCase, async: false

  alias Platform.Meetings.IntentEval.Cassette
  alias Platform.Meetings.IntentEval.CassetteProvider
  alias Platform.Meetings.IntentEval.Harness
  alias Platform.Orchestration.PromptTemplates

  # A live provider that answers with a well-formed classification. The
  # `answers` map is keyed by chunk text so a fixture can decide per row.
  defmodule StubProvider do
    def chat(_credentials, messages, _opts) do
      chunk =
        Enum.find_value(messages, "", fn
          %{role: "user", content: content} -> content
          _ -> nil
        end)

      answers = Process.get(:stub_answers, %{})

      content =
        Map.get(answers, chunk, ~s({"intent":"off_topic","target_role":"null","confidence":0.1}))

      {:ok, %{content: content, model: "stub", finish_reason: "stop", usage: %{}, raw: %{}}}
    end
  end

  # Fails the test if it is ever called. Every replay assertion uses this as
  # its `:live_module`, so "touched no network" is proved rather than assumed.
  defmodule ForbiddenProvider do
    def chat(_credentials, _messages, _opts) do
      raise "replay reached the live provider — the cassette path is not airtight"
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "intent_eval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "configs"))
    File.mkdir_p!(Path.join(root, "prompts"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # ── fixtures ──────────────────────────────────────────────────────────

  defp write_slice!(root, rows) do
    path = Path.join([root, "slices", "fixture.jsonl"])
    File.mkdir_p!(Path.dirname(path))

    body =
      rows
      |> Enum.map(&[Jason.encode!(&1), "\n"])
      |> IO.iodata_to_binary()

    File.write!(path, body)

    File.write!(
      Path.join(root, "manifest.json"),
      Jason.encode!(%{
        "slices" => [
          %{
            "name" => "fixture",
            "file" => "slices/fixture.jsonl",
            "count" => length(rows),
            "sha256" => Harness.sha256(body)
          }
        ]
      })
    )

    :ok
  end

  defp write_config!(root, name, prompt_source, extra \\ %{}) do
    config =
      Map.merge(
        %{
          "prompt_source" => prompt_source,
          "model" => "stub",
          "base_url" => "http://127.0.0.1:9/v1",
          "temperature" => 0.0,
          "max_tokens" => 64,
          "chat_template_kwargs" => %{"enable_thinking" => false},
          "buffering" => %{"debounce_ms" => 0}
        },
        extra
      )

    File.write!(Harness.config_path(root, name), Jason.encode!(config))
    :ok
  end

  defp write_prompt!(root, file, body) do
    path = Path.join([root, "prompts", file])
    File.write!(path, body)
    path
  end

  defp rows do
    [
      %{
        "id" => "r1",
        "text" => "Designer, make the button teal.",
        "label" => "visual_adjust",
        "slice" => "fixture"
      },
      %{
        "id" => "r2",
        "text" => "Nah, I'm gonna get Sam in here.",
        "label" => "off_topic",
        "slice" => "fixture"
      }
    ]
  end

  # A non-`off_topic` answer must carry a verbatim `evidence_quote` from the
  # chunk or the classifier's evidence gate (task 01a03f57) DEMOTES it to
  # `off_topic`. The default quote below is a substring of the positive
  # fixture row; `off_topic` answers cite nothing, as the prompt requires.
  defp answer(intent, quote \\ "make the button teal"),
    do:
      ~s({"intent":"#{intent}","target_role":"null","confidence":0.8,"evidence_quote":"#{if intent == "off_topic", do: "", else: quote}"})

  # ── cassette round-trip ───────────────────────────────────────────────

  describe "cassette round-trip" do
    test "a recorded run replays to byte-identical outcomes with no live call", %{root: root} do
      write_slice!(root, rows())
      prompt = write_prompt!(root, "p.txt", "classify: {{meeting_transcript_chunk}}")

      write_config!(root, "c", %{"inline_file" => prompt})

      Process.put(:stub_answers, %{
        "Designer, make the button teal." => answer("visual_adjust"),
        "Nah, I'm gonna get Sam in here." => answer("off_topic")
      })

      assert {:ok, recorded} =
               Harness.run("c",
                 root: root,
                 mode: :record,
                 live_module: StubProvider,
                 repo_root: root,
                 write: false
               )

      cassette = Cassette.load(Cassette.path(root, "c"))
      assert map_size(cassette) == 2

      assert {:ok, replayed} =
               Harness.run("c",
                 root: root,
                 mode: :replay,
                 live_module: ForbiddenProvider,
                 repo_root: root,
                 write: false
               )

      assert replayed["summary"] == recorded["summary"]

      assert Enum.map(replayed["rows"], & &1["predicted"]) == ["visual_adjust", "off_topic"]
      assert replayed["manifest"]["mode"] == "replay"
    end

    test "the run file and its manifest record the resolved source and prompt sha", %{root: root} do
      write_slice!(root, rows())
      prompt = write_prompt!(root, "p.txt", "classify: {{meeting_transcript_chunk}}")
      write_config!(root, "c", %{"inline_file" => prompt})
      Process.put(:stub_answers, %{})

      assert {:ok, result} =
               Harness.run("c",
                 root: root,
                 mode: :record,
                 live_module: StubProvider,
                 repo_root: root
               )

      written = result["run_file"] |> File.read!() |> Jason.decode!()
      manifest = written["manifest"]

      assert manifest["prompt"]["source"]["kind"] == "inline_file"
      assert String.match?(manifest["prompt"]["rendered_sha256"], ~r/^[0-9a-f]{64}$/)
      assert String.match?(manifest["config"]["sha256"], ~r/^[0-9a-f]{64}$/)
      assert manifest["base_url_host"] == "127.0.0.1:9"
      assert [%{"name" => "fixture"}] = manifest["slices"]
    end
  end

  # ── endpoint override (task 01a14b9e stage 2) ─────────────────────────

  describe "INTENT_EVAL_BASE_URL" do
    setup %{root: root} do
      previous = System.get_env("INTENT_EVAL_BASE_URL")

      on_exit(fn ->
        if previous,
          do: System.put_env("INTENT_EVAL_BASE_URL", previous),
          else: System.delete_env("INTENT_EVAL_BASE_URL")
      end)

      write_slice!(root, rows())
      prompt = write_prompt!(root, "p.txt", "classify: {{meeting_transcript_chunk}}")
      write_config!(root, "c", %{"inline_file" => prompt})
      Process.put(:stub_answers, %{})
      :ok
    end

    defp manifest_for(root, extra_opts) do
      opts =
        [root: root, mode: :record, live_module: StubProvider, repo_root: root, write: false] ++
          extra_opts

      assert {:ok, result} = Harness.run("c", opts)
      result["manifest"]
    end

    test "overrides the config's base_url, and is recorded as an override", %{root: root} do
      System.put_env("INTENT_EVAL_BASE_URL", " http://192.0.2.30:9/v1 ")
      manifest = manifest_for(root, [])
      assert manifest["base_url_host"] == "192.0.2.30:9"
      assert manifest["base_url_overridden"] == true
    end

    test "an explicit --base-url beats it", %{root: root} do
      System.put_env("INTENT_EVAL_BASE_URL", "http://192.0.2.30:9/v1")
      manifest = manifest_for(root, base_url: "http://192.0.2.40:9/v1")
      assert manifest["base_url_host"] == "192.0.2.40:9"
    end

    test "unset or blank leaves the config's base_url", %{root: root} do
      System.delete_env("INTENT_EVAL_BASE_URL")
      manifest = manifest_for(root, [])
      assert manifest["base_url_host"] == "127.0.0.1:9"
      assert manifest["base_url_overridden"] == false

      System.put_env("INTENT_EVAL_BASE_URL", "   ")
      assert manifest_for(root, [])["base_url_host"] == "127.0.0.1:9"
    end
  end

  # ── replay cache miss ─────────────────────────────────────────────────

  describe "replay cache miss" do
    setup %{root: root} do
      write_slice!(root, rows())
      prompt = write_prompt!(root, "p.txt", "classify: {{meeting_transcript_chunk}}")
      write_config!(root, "c", %{"inline_file" => prompt})
      Process.put(:stub_answers, %{})
      :ok
    end

    test "fails loudly with the missing keys and count, and never calls the provider", %{
      root: root
    } do
      # Record ONE row, then replay the whole two-row slice.
      assert {:ok, _} =
               Harness.run("c",
                 root: root,
                 mode: :record,
                 slice: "fixture",
                 live_module: StubProvider,
                 repo_root: root,
                 write: false
               )

      cassette_path = Cassette.path(root, "c")
      [{key, entry}] = Cassette.load(cassette_path) |> Enum.take(1)
      File.write!(cassette_path, Jason.encode!(entry) <> "\n")

      assert {:error, {:cassette_miss, details}} =
               Harness.run("c",
                 root: root,
                 mode: :replay,
                 live_module: ForbiddenProvider,
                 repo_root: root,
                 write: false
               )

      assert details.count == 1
      assert details.total == 2
      refute key in details.keys
      assert [missing_key] = details.keys
      assert String.match?(missing_key, ~r/^[0-9a-f]{64}$/)

      report = Harness.miss_report(details)
      assert report =~ "1 of 2 rows have no recorded response"
      assert report =~ missing_key
    end

    test "the control: a complete cassette replays instead of failing", %{root: root} do
      assert {:ok, _} =
               Harness.run("c",
                 root: root,
                 mode: :record,
                 live_module: StubProvider,
                 repo_root: root,
                 write: false
               )

      assert {:ok, result} =
               Harness.run("c",
                 root: root,
                 mode: :replay,
                 live_module: ForbiddenProvider,
                 repo_root: root,
                 write: false
               )

      assert result["summary"]["total"] == 2
    end

    test "a miss is never scored as an error row", %{root: root} do
      assert {:error, {:cassette_miss, details}} =
               Harness.run("c",
                 root: root,
                 mode: :replay,
                 live_module: ForbiddenProvider,
                 repo_root: root,
                 write: false
               )

      # No result at all — not a result with two model_error rows in it.
      assert details.count == 2
    end

    test "the provider itself refuses a miss rather than reaching the network" do
      CassetteProvider.arm(%{
        mode: :replay,
        cassette: %{},
        live_module: ForbiddenProvider,
        opts_override: []
      })

      assert_raise CassetteProvider.Miss, ~r/cassette miss for key/, fn ->
        CassetteProvider.chat(%{}, [
          %{role: "system", content: "p"},
          %{role: "user", content: "u"}
        ])
      end
    end
  end

  # ── prompt source attribution ─────────────────────────────────────────

  describe "prompt source" do
    test "a db_slug config and a migration config on different text produce different shas", %{
      root: root
    } do
      slug = "harness.test.prompt.v1"

      {:ok, _} =
        PromptTemplates.create_template(%{
          slug: slug,
          name: "harness test prompt",
          content: "DB BODY — classify: {{meeting_transcript_chunk}}",
          category: "test"
        })

      migration = Path.join(root, "20260101000000_fixture.exs")

      File.write!(migration, """
      defmodule Fixture do
        @new_content \"\"\"
        MIGRATION BODY — classify: {{meeting_transcript_chunk}}
        \"\"\"
      end
      """)

      write_config!(root, "from_db", %{"db_slug" => slug})

      write_config!(root, "from_migration", %{"migration" => "20260101000000_fixture.exs"}, %{
        "prompt_attribute" => "new_content"
      })

      {db_source, db_body} =
        Harness.resolve_prompt!(Harness.load_config!(root, "from_db"), repo_root: root)

      {migration_source, migration_body} =
        Harness.resolve_prompt!(Harness.load_config!(root, "from_migration"), repo_root: root)

      assert db_source["kind"] == "db_slug"
      assert migration_source["kind"] == "migration"
      assert migration_source["attribute"] == "new_content"

      assert db_body =~ "DB BODY"
      assert migration_body =~ "MIGRATION BODY"

      # The whole point of stage 4: two arms that disagree are now
      # distinguishable by one field in the run manifest.
      refute Harness.fingerprint(db_body) == Harness.fingerprint(migration_body)
    end

    test "a db_slug config with no row refuses rather than falling back", %{root: root} do
      write_config!(root, "missing", %{"db_slug" => "no.such.slug.v1"})

      assert_raise ArgumentError, ~r/has no row in prompt_templates/, fn ->
        Harness.resolve_prompt!(Harness.load_config!(root, "missing"), repo_root: root)
      end
    end

    test "a two-keyed prompt_source is refused as ambiguous", %{root: root} do
      write_config!(root, "ambiguous", %{"db_slug" => "a", "inline_file" => "b"})

      assert_raise ArgumentError, ~r/exactly ONE source/, fn ->
        Harness.load_config!(root, "ambiguous")
      end
    end

    test "a non-zero debounce is refused rather than silently ignored", %{root: root} do
      prompt = write_prompt!(root, "p.txt", "x")

      write_config!(root, "buffered", %{"inline_file" => prompt}, %{
        "buffering" => %{"debounce_ms" => 400}
      })

      assert_raise ArgumentError, ~r/debounce_ms must be 0/, fn ->
        Harness.load_config!(root, "buffered")
      end
    end
  end

  # ── error classes ─────────────────────────────────────────────────────

  describe "error classes are first-class outcomes" do
    setup %{root: root} do
      write_slice!(root, rows())
      prompt = write_prompt!(root, "p.txt", "classify: {{meeting_transcript_chunk}}")
      write_config!(root, "c", %{"inline_file" => prompt})
      :ok
    end

    test "an engineered error case counts NON-ZERO errors and does not inflate off_topic", %{
      root: root
    } do
      # Both rows answer with a NUMERIC target_role — well-formed JSON in a
      # shape the prompt's closed enum does not allow, so the classifier
      # still reports it as a parse error.
      #
      # This case used to use a JSON-NULL target_role. That is no longer an
      # error: null is the answer the prompt's own enum instructs for
      # `off_topic`, and rejecting it is the defect task 01a03f57 fixed —
      # the shape that made 83 of 102 correct declines read as parse
      # failures in one instrument. Using it as an error generator here
      # would re-assert the bug.
      Process.put(:stub_answers, %{
        "Designer, make the button teal." =>
          ~s({"intent":"visual_adjust","target_role":42,"confidence":0.9}),
        "Nah, I'm gonna get Sam in here." =>
          ~s({"intent":"off_topic","target_role":42,"confidence":0.9})
      })

      assert {:ok, result} =
               Harness.run("c",
                 root: root,
                 mode: :record,
                 live_module: StubProvider,
                 repo_root: root,
                 write: false
               )

      summary = result["summary"]

      assert summary["error_classes"]["parse_error"] == 2
      assert summary["errors_total"] == 2

      # The row that ANSWERED off_topic errored, so off_topic did not gain a
      # prediction from it. An error is not a decline.
      assert summary["confusion"]["off_topic"] == %{"parse_error" => 1}
      assert summary["per_slice"]["fixture"]["off_topic"] == 0
      assert summary["per_slice"]["fixture"]["fired"] == 0
      assert summary["per_slice"]["fixture"]["errors"] == 2
    end

    test "the clean control: ZERO errors with a non-zero off_topic", %{root: root} do
      Process.put(:stub_answers, %{
        "Designer, make the button teal." => answer("visual_adjust"),
        "Nah, I'm gonna get Sam in here." => answer("off_topic")
      })

      assert {:ok, result} =
               Harness.run("c",
                 root: root,
                 mode: :record,
                 live_module: StubProvider,
                 repo_root: root,
                 write: false
               )

      summary = result["summary"]

      assert summary["errors_total"] == 0

      # `demoted` is deliberately ABSENT here: it is an outcome, not an
      # error class, and it must not share a bucket with the error
      # taxonomy (task 01a04379).
      assert summary["error_classes"] == %{
               "parse_error" => 0,
               "empty_output" => 0,
               "model_error" => 0
             }

      assert summary["per_slice"]["fixture"]["off_topic"] == 1
      assert summary["per_slice"]["fixture"]["fired"] == 1
      assert summary["confusion"]["off_topic"] == %{"off_topic" => 1}
    end

    test "parseable_bodies separates well-formed-JSON refusals from prose that never parsed", %{
      root: root
    } do
      # Both arms below produce `parse_error` on EVERY row, so the outcome
      # class cannot tell them apart — the reviewer found that
      # `broken_always_off_topic` and `broken_malformed_schema` print
      # byte-identical reports. `parseable_bodies` is the number that
      # separates them, and it has to reach the report a human reads.
      valid_json = %{
        "Designer, make the button teal." =>
          ~s({"intent":"visual_adjust","target_role":42,"confidence":0.9}),
        "Nah, I'm gonna get Sam in here." =>
          ~s({"intent":"off_topic","target_role":42,"confidence":0.9})
      }

      prose = %{
        "Designer, make the button teal." => "Sure! I think this is a visual adjustment.",
        "Nah, I'm gonna get Sam in here." => "Honestly, that sounds off topic to me."
      }

      run = fn answers ->
        Process.put(:stub_answers, answers)

        assert {:ok, result} =
                 Harness.run("c",
                   root: root,
                   mode: :record,
                   live_module: StubProvider,
                   repo_root: root,
                   write: false
                 )

        result
      end

      json_run = run.(valid_json)
      prose_run = run.(prose)

      # The class they are indistinguishable on ...
      assert json_run["summary"]["error_classes"]["parse_error"] == 2
      assert prose_run["summary"]["error_classes"]["parse_error"] == 2

      # ... and the number that distinguishes them.
      assert json_run["summary"]["parseable_bodies"] == 2
      assert prose_run["summary"]["parseable_bodies"] == 0

      # It reaches stdout, not just the run JSON. Without this the counter
      # exists and the human still cannot see it.
      assert Harness.report(json_run) =~ "JSON bodies   : 2 of 2"
      assert Harness.report(prose_run) =~ "JSON bodies   : 0 of 2"
    end

    test "empty output and model error land in their own buckets, not off_topic", %{root: root} do
      Process.put(:stub_answers, %{
        "Designer, make the button teal." => "   ",
        "Nah, I'm gonna get Sam in here." => answer("off_topic")
      })

      assert {:ok, result} =
               Harness.run("c",
                 root: root,
                 mode: :record,
                 live_module: StubProvider,
                 repo_root: root,
                 write: false
               )

      summary = result["summary"]

      assert summary["error_classes"]["empty_output"] == 1
      assert summary["error_classes"]["parse_error"] == 0
      assert summary["per_slice"]["fixture"]["off_topic"] == 1
      assert summary["confusion"]["visual_adjust"] == %{"empty_output" => 1}
    end
  end

  # ── the committed reference points ────────────────────────────────────

  # ── demotion is an outcome, not an error class ────────────────────────

  describe "the demoted counter" do
    # Both halves are required and neither is sufficient. The first alone
    # is passed by a counter that increments unconditionally; the second
    # alone is passed by a counter wired to a constant zero — which is
    # precisely what shipped, because the `{:error, {:demoted, _}}` clause
    # that fed it could never match `decide/1`'s atom-only error reasons.
    # Exact values, not `> 0`: a count nobody has watched move is untested.
    setup %{root: root} do
      write_slice!(root, rows())
      prompt = write_prompt!(root, "p.txt", "classify: {{meeting_transcript_chunk}}")
      write_config!(root, "c", %{"inline_file" => prompt})
      :ok
    end

    defp demote_run(root) do
      assert {:ok, result} =
               Harness.run("c",
                 root: root,
                 mode: :record,
                 live_module: StubProvider,
                 repo_root: root,
                 write: false
               )

      result
    end

    test "a positive citing text absent from its chunk is counted: demoted == 1", %{root: root} do
      # r1 answers `visual_adjust` while citing a span that does NOT appear
      # in its chunk, so `evidence_verdict/3` demotes it. r2 answers
      # `off_topic`, which needs no citation and is never demoted.
      Process.put(:stub_answers, %{
        "Designer, make the button teal." => answer("visual_adjust", "paint the sidebar mauve"),
        "Nah, I'm gonna get Sam in here." => answer("off_topic")
      })

      summary = demote_run(root)["summary"]

      assert summary["demoted"] == 1
      assert summary["per_slice"]["fixture"]["demoted"] == 1

      # The demoted row is a SUCCESSFUL off_topic decision — that is what
      # the pipeline actually returned — so it is counted as off_topic and
      # is not an error. Sharing a bucket with the error taxonomy for a
      # value that is structurally not an error is the defect.
      assert summary["errors_total"] == 0
      refute Map.has_key?(summary["error_classes"], "demoted")
      assert summary["per_slice"]["fixture"]["off_topic"] == 2
      assert summary["per_slice"]["fixture"]["fired"] == 0
      assert summary["confusion"]["visual_adjust"] == %{"off_topic" => 1}

      # Per-row, so a run file says WHICH row was downgraded and from what.
      assert Enum.map(demote_run(root)["rows"], & &1["demoted_from"]) == ["visual_adjust", nil]
    end

    test "the control: the same positive citing its chunk verbatim leaves demoted == 0", %{
      root: root
    } do
      # Identical to the case above except the citation is a real substring
      # of r1's chunk. Without this half, a counter that increments on
      # every row — or on every off_topic — passes the case above.
      Process.put(:stub_answers, %{
        "Designer, make the button teal." => answer("visual_adjust", "make the button teal"),
        "Nah, I'm gonna get Sam in here." => answer("off_topic")
      })

      summary = demote_run(root)["summary"]

      assert summary["demoted"] == 0
      assert summary["per_slice"]["fixture"]["demoted"] == 0
      assert summary["per_slice"]["fixture"]["fired"] == 1
      assert summary["per_slice"]["fixture"]["off_topic"] == 1
    end

    test "a genuine off_topic decline is not a demotion", %{root: root} do
      # The nastiest confusion this counter can fall into: a demoted row
      # and a genuine decline both PREDICT off_topic. If `demoted` were
      # read off the prediction rather than off `decide/1`'s
      # `:demoted_from`, this all-declines run would report 2.
      Process.put(:stub_answers, %{
        "Designer, make the button teal." => answer("off_topic"),
        "Nah, I'm gonna get Sam in here." => answer("off_topic")
      })

      summary = demote_run(root)["summary"]

      assert summary["per_slice"]["fixture"]["off_topic"] == 2
      assert summary["demoted"] == 0
    end

    test "the operator report prints the demotion outside the error list", %{root: root} do
      Process.put(:stub_answers, %{
        "Designer, make the button teal." => answer("visual_adjust", "paint the sidebar mauve"),
        "Nah, I'm gonna get Sam in here." => answer("off_topic")
      })

      report = Harness.report(demote_run(root))

      assert report =~ ~r/demoted\s+: 1 positives downgraded to off_topic/

      # The gate that did it is named on the same line. Two gates now
      # demote (citation and addressee) and a bare count cannot say which
      # one a change moved.
      assert report =~ ~s(%{"not_in_chunk" => 1})

      # It must not reappear as an error class row, which is where a
      # permanently-zero column sat for the life of the harness.
      refute report =~ ~r/^\s+demoted\s+: \d+$/m
    end
  end

  describe "committed reference runs" do
    test "both reference cassettes replay with no network and no misses" do
      root = Platform.Meetings.IntentEval.root()

      for config <- ~w(off_topic_default binary_actionable) do
        assert {:ok, result} =
                 Harness.run(config,
                   root: root,
                   mode: :replay,
                   live_module: ForbiddenProvider,
                   repo_root: Path.expand("../../../..", __DIR__),
                   write: false
                 ),
               "#{config} did not replay cleanly"

        # 174 seed rows + the 9-row `delegation_probe` added by task
        # 01a05997 stage 4. Both cassettes were re-recorded over the new
        # rows in that stage, so "no misses" still means the whole set.
        assert result["summary"]["total"] == 183
      end
    end

    test "the off_topic_default reference numbers reproduce from its cassette" do
      root = Platform.Meetings.IntentEval.root()

      {:ok, result} =
        Harness.run("off_topic_default",
          root: root,
          mode: :replay,
          live_module: ForbiddenProvider,
          repo_root: Path.expand("../../../..", __DIR__),
          write: false
        )

      per_slice = result["summary"]["per_slice"]

      # The published figures for this arm. Pinned here so a change to
      # scoring that moves them is a test failure, not a silent
      # re-baseline.
      #
      # BEFORE the frame gate (task 01a04b6b, measured 2026-08-29 at
      # 03ac772d): negatives 8, control 59, probe 11, demoted 0 — the
      # citation gate fired on 0 of 174 rows because all 8 false
      # positives supply valid verbatim quotes.
      #
      # AFTER: negatives 3, control 59, probe 11, demoted 5. The five
      # removals are use/mention failures, listed in the test below.
      #
      # RE-RECORDED (task 01a14dce stage 2, 2026-10-18): real names in the
      # slices and in one prompt exemplar line were replaced with invented
      # ones, which re-keys every row of this cassette, so all 183 rows were
      # asked again on the same local model. negatives 3, control 59 and
      # probe 11 hold; demoted is now 4, because the model itself now
      # declines one row the frame gate used to demote (see the test below).
      # The old prompt and slices asked again the same day reproduced the
      # old numbers exactly, so the move comes from the text change.
      #
      # The two unchanged numbers are the load-bearing half of this
      # assertion, not padding: a gate that demoted everything would take
      # negatives to 0 and look like a triumph. `control_60` and
      # `unaddressed_probe_12` are what makes 3 a fix rather than a
      # collapse, and they are asserted as EQUALITIES for that reason.
      assert per_slice["negatives_102"]["fired"] == 3
      assert per_slice["control_60"]["fired"] == 59
      assert per_slice["unaddressed_probe_12"]["fired"] == 11

      assert per_slice["negatives_102"]["demoted"] == 4
      assert per_slice["control_60"]["demoted"] == 0
      assert per_slice["unaddressed_probe_12"]["demoted"] == 0
    end

    # The frame gate's reach, row by row, read off the committed cassette
    # rather than restated from a report. Mutation M1 — delete the
    # `IntentFrames.cancelling_frame/2` call from
    # `IntentClassifier.evidence_verdict/3` — empties `suppressed` and
    # turns this red, which is the mutation task 01a04b6b's own
    # verification section demands.
    test "the frame gate removes exactly the five use/mention false positives" do
      root = Platform.Meetings.IntentEval.root()

      {:ok, result} =
        Harness.run("off_topic_default",
          root: root,
          mode: :replay,
          live_module: ForbiddenProvider,
          repo_root: Path.expand("../../../..", __DIR__),
          write: false
        )

      negatives = Enum.filter(result["rows"], &(&1["slice"] == "negatives_102"))

      suppressed =
        negatives
        |> Enum.filter(& &1["demoted_from"])
        |> Enum.map(& &1["text"])
        |> Enum.sort()

      # Four since the task 01a14dce re-record. The fifth, the perception
      # row ("We can see the action items up there, ..."), is still
      # declined: the model now answers off_topic itself, so the gate has
      # nothing to demote. The texts are the synthetic stand-ins the
      # pre-public scrub put in place of the recorded removals; each keeps
      # the frame that cancels it (evaluative, epistemic, retraction,
      # delegation).
      assert suppressed == [
               "Hmm, but the interaction design piece is probably wrong.",
               "I wonder if this one is actually briefworthy.",
               "Scratch that. Put down an action item for Sam to own the newsletter draft.",
               "We can ask her to pull it up in here."
             ]

      # The three it does NOT reach, stated rather than left as a
      # residual. A fragment (the content gate's job, bypassed by the
      # harness because `decide/1` is called directly), a chunk whose
      # cancelling material follows the quote and so falls outside
      # forward scope, and a hortative the gate deliberately declines to
      # claim. If a future widening catches one of these, that is a
      # design change and it argues for itself here first.
      still_firing =
        negatives
        |> Enum.filter(&Harness.fired?/1)
        |> Enum.map(& &1["text"])
        |> Enum.sort()

      assert still_firing == [
               "Let's sketch out some kind of roadmap here.",
               "Push it to staging. Ugh, I know, me too. Fine, let's go then.",
               "and schedule them."
             ]
    end

    test "the binary_actionable cassette demotes 92 of its 174 seed rows (93 before the re-record)" do
      # The measurement that settled task 01a04379: demotion was not rare,
      # it was the single largest outcome on this arm, and the report said
      # zero every time. Pinned so the counter cannot silently return to
      # zero on committed data.
      root = Platform.Meetings.IntentEval.root()

      {:ok, result} =
        Harness.run("binary_actionable",
          root: root,
          mode: :replay,
          live_module: ForbiddenProvider,
          repo_root: Path.expand("../../../..", __DIR__),
          write: false
        )

      # Counted over the three SEED slices, which is the population the
      # 93 was measured on. Stating it as a filter rather than re-baselining
      # to 100 keeps the original measurement intact and legible; the
      # delegation rows are asserted separately below so nothing hides.
      seed_demoted =
        result["rows"]
        |> Enum.reject(&(&1["slice"] == "delegation_probe"))
        |> Enum.count(& &1["demoted_from"])

      # 92 since task 01a14dce stage 2: 23 rows whose text named a real
      # person or org were rewritten and asked again; one of them is no
      # longer demoted. The other 160 rows kept their recorded answers
      # (same prompt bytes, same text, same cassette key).
      assert seed_demoted == 92
      assert result["summary"]["errors_total"] == 0

      # Task 01a05997 stage 4: this arm demotes 7 of the 9 delegation rows,
      # so its total is 99 (100 before the task 01a14dce re-record).
      # Pinned so the added rows cannot drift unnoticed.
      assert result["summary"]["demoted"] == 99
    end
  end

  # ── task 01a06575 stage 4 ─────────────────────────────────────────────

  describe "a slice can be in the set and out of the default run" do
    test "`scored_by_default: false` excludes it, and --slice still reaches it", %{root: root} do
      write_two_slices!(root)

      write_config!(root, "cfg", %{
        "inline_file" => write_prompt!(root, "p.txt", "P {{meeting_transcript_chunk}}")
      })

      # The default run sees ONE slice, not both.
      assert Harness.load_rows(root) |> Enum.map(& &1["slice"]) |> Enum.uniq() == ["included"]

      # Naming it explicitly still reaches it — exclusion is a default,
      # not a ban. Without this half, a harness that had simply LOST the
      # slice would pass.
      assert Harness.load_rows(root, "excluded") |> Enum.map(& &1["slice"]) == ["excluded"]

      # And it is named, with its reason, rather than silently dropped.
      assert [%{"name" => "excluded", "reason" => "no cassette anywhere"}] =
               Harness.excluded_slices(root)

      # Nothing is excluded when a slice was named explicitly: the
      # reader asked for exactly this and the list would be noise.
      assert Harness.excluded_slices(root, "excluded") == []
    end

    test "the exclusion is printed in the report, not just recorded", %{root: root} do
      write_two_slices!(root)

      write_config!(root, "cfg", %{
        "inline_file" => write_prompt!(root, "p.txt", "P {{meeting_transcript_chunk}}")
      })

      Process.put(:stub_answers, %{})

      {:ok, result} =
        Harness.run("cfg", root: root, mode: :record, live_module: StubProvider, write: false)

      report = Harness.report(result)
      assert report =~ "EXCLUDED SLICES"
      assert report =~ "excluded (1 rows): no cassette anywhere"
    end
  end

  describe "correction exemplars: the variable the harness used to hardcode" do
    test "the default is the sentinel, byte-for-byte, so published fingerprints still reproduce",
         %{root: root} do
      template = "P {{correction_exemplars}}"

      # `fingerprint/1` is what every committed run manifest recorded.
      assert Harness.fingerprint(template) ==
               Harness.sha256("P (no prior corrections)")

      write_config!(root, "implicit", %{"inline_file" => write_prompt!(root, "p.txt", template)})

      write_config!(
        root,
        "explicit",
        %{"inline_file" => Path.join([root, "prompts", "p.txt"])},
        %{"correction_exemplars" => %{"sentinel" => true}}
      )

      {_source, implicit} =
        Harness.resolve_exemplars!(Harness.load_config!(root, "implicit"), root: root)

      {_source, explicit} =
        Harness.resolve_exemplars!(Harness.load_config!(root, "explicit"), root: root)

      assert implicit == "(no prior corrections)"
      assert explicit == implicit
    end

    test "a file source renders through the LIVE classifier's formatter, not a copy", %{
      root: root
    } do
      exemplars = [
        %{
          "transcript_chunk_excerpt" => "Promote to prod.",
          "classified_intent" => "action_items",
          "correction" => "removed_no_action",
          "reason" => "wrong_target",
          "corrected_intent" => nil,
          "dispatch_outcome" => nil
        }
      ]

      write_exemplars!(root, "corpus.jsonl", exemplars)

      write_config!(
        root,
        "cfg",
        %{"inline_file" => write_prompt!(root, "p.txt", "P {{correction_exemplars}}")},
        %{"correction_exemplars" => %{"file" => "exemplars/corpus.jsonl"}}
      )

      {source, block} = Harness.resolve_exemplars!(Harness.load_config!(root, "cfg"), root: root)

      assert source["kind"] == "file"
      assert source["count"] == 1

      # Byte equality with what the classifier itself would render for
      # the same row. A harness-side re-implementation of this format is
      # how the eval and production end up disagreeing about what the
      # prompt says while both look correct.
      assert block ==
               Platform.Meetings.IntentClassifier.format_correction_exemplars([
                 %{
                   transcript_chunk_excerpt: "Promote to prod.",
                   classified_intent: "action_items",
                   correction: "removed_no_action",
                   reason: "wrong_target",
                   corrected_intent: nil,
                   dispatch_outcome: nil
                 }
               ])

      assert block =~ "producer verdict: removed_no_action (wrong_target)"
      refute block == "(no prior corrections)"
    end

    test "the two exemplar arms are NOT interchangeable — one's cassette misses the other", %{
      root: root
    } do
      write_slice!(root, rows())

      write_exemplars!(root, "corpus.jsonl", [
        %{
          "transcript_chunk_excerpt" => "Promote to prod.",
          "classified_intent" => "action_items",
          "correction" => "removed_no_action",
          "reason" => "wrong_target",
          "corrected_intent" => nil,
          "dispatch_outcome" => nil
        }
      ])

      prompt =
        write_prompt!(root, "p.txt", "P {{correction_exemplars}} {{meeting_transcript_chunk}}")

      write_config!(root, "sentinel", %{"inline_file" => prompt})

      write_config!(root, "withex", %{"inline_file" => prompt}, %{
        "correction_exemplars" => %{"file" => "exemplars/corpus.jsonl"}
      })

      Process.put(:stub_answers, %{})

      # Record against the sentinel arm ...
      assert {:ok, _} =
               Harness.run("sentinel",
                 root: root,
                 mode: :record,
                 live_module: StubProvider,
                 write: false
               )

      File.cp!(Cassette.path(root, "sentinel"), Cassette.path(root, "withex"))

      # ... and the exemplar arm cannot replay it. THIS is the guard that
      # stops the single worst thing this eval could do: score a
      # cassette recorded against one prompt body under a different one,
      # and publish the number as an answer.
      assert {:error, {:cassette_miss, %{count: 2, total: 2}}} =
               Harness.run("withex",
                 root: root,
                 mode: :replay,
                 live_module: ForbiddenProvider,
                 write: false
               )

      # The control: the arm it WAS recorded against replays clean, so
      # the miss above is about the prompt and not about a broken copy.
      File.cp!(Cassette.path(root, "sentinel"), Cassette.path(root, "sentinel2"))
      write_config!(root, "sentinel2", %{"inline_file" => prompt})

      assert {:ok, result} =
               Harness.run("sentinel2",
                 root: root,
                 mode: :replay,
                 live_module: ForbiddenProvider,
                 write: false
               )

      assert result["summary"]["total"] == 2
    end

    test "db_recent RAISES on an empty corpus rather than quietly rendering the sentinel", %{
      root: root
    } do
      write_config!(
        root,
        "cfg",
        %{"inline_file" => write_prompt!(root, "p.txt", "P {{correction_exemplars}}")},
        %{"correction_exemplars" => %{"db_recent" => %{"org_slug" => "acme"}}}
      )

      config = Harness.load_config!(root, "cfg")

      # Production degrades to the sentinel on purpose — a classification
      # must not be dropped because the corpus hiccuped. An EVAL that did
      # the same would publish a number about a prompt it did not send.
      assert_raise ArgumentError, ~r/ZERO corrections/, fn ->
        Harness.resolve_exemplars!(config, root: root)
      end
    end

    test "an ambiguous or unknown exemplar source is refused at load", %{root: root} do
      prompt = write_prompt!(root, "p.txt", "P")

      write_config!(root, "two", %{"inline_file" => prompt}, %{
        "correction_exemplars" => %{"file" => "a", "sentinel" => true}
      })

      assert_raise ArgumentError, ~r/exactly ONE source/, fn ->
        Harness.load_config!(root, "two")
      end

      write_config!(root, "bogus", %{"inline_file" => prompt}, %{
        "correction_exemplars" => %{"whatever" => true}
      })

      assert_raise ArgumentError, ~r/not one of sentinel \| file \| db_recent/, fn ->
        Harness.load_config!(root, "bogus")
      end
    end
  end

  describe "the committed stage-4 additions" do
    test "the new slice is registered, excluded by default, and reachable by name" do
      root = Platform.Meetings.IntentEval.root()

      assert [%{"name" => "unaddressed_meeting_speech_48", "count" => 48}] =
               Harness.excluded_slices(root)

      rows = Harness.load_rows(root, "unaddressed_meeting_speech_48")
      assert length(rows) == 48

      # The row that held the slice's one real utterance until task
      # 01a14dce is IN the set as its hand-written replacement, still at
      # its probe tag. The real row named real people, so it was replaced
      # by an invented one of the same shape and label rather than kept.
      assert [replacement] = Enum.filter(rows, &(&1["probe"] == "former_verbatim"))
      assert replacement["label"] == "action_items"
      assert replacement["origin"] == "hand_written"

      assert replacement["text"] ==
               "was fine um so riley is going to be drafting a couple of new tickets we need to to " <>
                 "write up the notes it'd be also nice if we could um"

      assert Enum.all?(rows, &(&1["origin"] == "hand_written"))

      # And it is not quietly folded into the default run, which would
      # turn every committed replay into a 48-row miss.
      refute Enum.any?(Harness.load_rows(root), &(&1["slice"] == "unaddressed_meeting_speech_48"))
    end

    test "the production-exemplar arm carries eight real removals and a different prompt sha" do
      root = Platform.Meetings.IntentEval.root()

      sentinel =
        Harness.render_prompt("off_topic_default",
          root: root,
          repo_root: Path.expand("../../../..", __DIR__)
        )

      prod =
        Harness.render_prompt("off_topic_default_prod_exemplars",
          root: root,
          repo_root: Path.expand("../../../..", __DIR__)
        )

      # Same prompt BODY — the arms differ in exactly one variable ...
      assert sentinel["template_sha256"] == prod["template_sha256"]
      # ... and that is enough to make them different prompts.
      refute sentinel["rendered_sha256"] == prod["rendered_sha256"]

      assert prod["exemplar_source"]["count"] == 8
      assert prod["exemplar_bytes"] > sentinel["exemplar_bytes"]

      # Every exemplar the live prompt would carry is a REMOVAL. That is
      # the finding: the slot the prompt introduces as "ground truth for
      # this org's vocabulary" is, in practice, eight examples of firing
      # being wrong — pressure toward off_topic that no published run
      # has ever rendered.
      assert prod["exemplar_block"] =~ "removed_no_action"
      refute prod["exemplar_block"] =~ "should have been:"
    end
  end

  # ── stage-4 fixtures ──────────────────────────────────────────────────

  defp write_two_slices!(root) do
    File.mkdir_p!(Path.join(root, "slices"))

    for {name, text} <- [
          {"included", "Designer, make the button teal."},
          {"excluded", "um so riley is going to"}
        ] do
      body =
        Jason.encode!(%{"id" => name, "text" => text, "label" => "off_topic", "slice" => name}) <>
          "\n"

      File.write!(Path.join([root, "slices", "#{name}.jsonl"]), body)
    end

    File.write!(
      Path.join(root, "manifest.json"),
      Jason.encode!(%{
        "slices" => [
          %{
            "name" => "included",
            "file" => "slices/included.jsonl",
            "count" => 1,
            "scored_by_default" => true
          },
          %{
            "name" => "excluded",
            "file" => "slices/excluded.jsonl",
            "count" => 1,
            "scored_by_default" => false,
            "excluded_reason" => "no cassette anywhere"
          }
        ]
      })
    )

    :ok
  end

  defp write_exemplars!(root, file, rows) do
    File.mkdir_p!(Path.join(root, "exemplars"))

    body =
      rows
      |> Enum.map(&[Jason.encode!(&1), "\n"])
      |> IO.iodata_to_binary()

    File.write!(Path.join([root, "exemplars", file]), body)
    :ok
  end
end
