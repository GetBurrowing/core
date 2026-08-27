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
        "text" => "Nah, I'm gonna get Harper in here.",
        "label" => "off_topic",
        "slice" => "fixture"
      }
    ]
  end

  defp answer(intent),
    do: ~s({"intent":"#{intent}","target_role":"null","confidence":0.8})

  # ── cassette round-trip ───────────────────────────────────────────────

  describe "cassette round-trip" do
    test "a recorded run replays to byte-identical outcomes with no live call", %{root: root} do
      write_slice!(root, rows())
      prompt = write_prompt!(root, "p.txt", "classify: {{meeting_transcript_chunk}}")

      write_config!(root, "c", %{"inline_file" => prompt})

      Process.put(:stub_answers, %{
        "Designer, make the button teal." => answer("visual_adjust"),
        "Nah, I'm gonna get Harper in here." => answer("off_topic")
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
      # Both rows answer with a JSON-null target_role — well-formed JSON the
      # prompt's own enum instructs, which `parse_content/2` rejects. This is
      # the exact shape that made 83 of 102 correct declines read as parse
      # failures in one instrument.
      Process.put(:stub_answers, %{
        "Designer, make the button teal." =>
          ~s({"intent":"visual_adjust","target_role":null,"confidence":0.9}),
        "Nah, I'm gonna get Harper in here." =>
          ~s({"intent":"off_topic","target_role":null,"confidence":0.9})
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
        "Nah, I'm gonna get Harper in here." => answer("off_topic")
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

      assert summary["error_classes"] == %{
               "parse_error" => 0,
               "empty_output" => 0,
               "model_error" => 0,
               "demoted" => 0
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
          ~s({"intent":"visual_adjust","target_role":null,"confidence":0.9}),
        "Nah, I'm gonna get Harper in here." =>
          ~s({"intent":"off_topic","target_role":null,"confidence":0.9})
      }

      prose = %{
        "Designer, make the button teal." => "Sure! I think this is a visual adjustment.",
        "Nah, I'm gonna get Harper in here." => "Honestly, that sounds off topic to me."
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
        "Nah, I'm gonna get Harper in here." => answer("off_topic")
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

        assert result["summary"]["total"] == 174
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

      # The two published figures for this arm: 8 of 102 negatives firing,
      # 59 of 60 control holding (i.e. firing). Pinned here so a change to
      # scoring that moves them is a test failure, not a silent re-baseline.
      assert per_slice["negatives_102"]["fired"] == 8
      assert per_slice["control_60"]["fired"] == 59
    end
  end
end
