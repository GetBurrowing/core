defmodule Platform.Security.Scanners.CodeAudit.PatternLoaderTest do
  @moduledoc """
  Tests for `Platform.Security.Scanners.CodeAudit.PatternLoader`
  (task `019f3e8e-4406` stage 4, ADR-0043).
  """
  use ExUnit.Case, async: true

  alias Platform.Security.Scanners.CodeAudit.PatternLoader

  @fixture_root Path.expand("../../../../support/fixtures/security", __DIR__)

  describe "load/1" do
    test "loads the shipped rubric successfully" do
      assert {:ok, patterns} = PatternLoader.load()
      assert length(patterns) > 0

      Enum.each(patterns, fn p ->
        assert is_binary(p.id)
        assert p.severity in [:critical, :high, :medium, :low]
        assert p.kind in [:regex, :ast_probe]
      end)
    end

    test "loads a minimal fixture rubric" do
      path = Path.join(@fixture_root, "patterns_min.yaml")
      assert {:ok, patterns} = PatternLoader.load(path)

      ids = Enum.map(patterns, & &1.id)
      assert "unparameterized_sql" in ids
      assert "missing_webhook_hmac" in ids
    end

    test "returns error for a missing file" do
      assert {:error, _} = PatternLoader.load("/tmp/nonexistent_#{System.unique_integer()}.yaml")
    end

    test "returns error for a rubric with an invalid severity value" do
      path = Path.join(@fixture_root, "patterns_broken.yaml")
      assert {:error, {:invalid_severity, "ULTRACRITICAL"}} = PatternLoader.load(path)
    end

    test "returns error for a rubric without a top-level patterns key" do
      tmp = Path.join(System.tmp_dir!(), "no_patterns_#{System.unique_integer([:positive])}.yaml")
      File.write!(tmp, "other_key: []\n")
      on_exit(fn -> File.rm(tmp) end)

      assert {:error, :missing_patterns_key} = PatternLoader.load(tmp)
    end

    test "returns error for an entry missing required keys" do
      tmp =
        Path.join(System.tmp_dir!(), "missing_keys_#{System.unique_integer([:positive])}.yaml")

      File.write!(tmp, """
      patterns:
        - id: only_id_no_kind
          severity: high
      """)

      on_exit(fn -> File.rm(tmp) end)

      assert {:error, {:missing_pattern_keys, missing, _id}} = PatternLoader.load(tmp)
      assert "kind" in missing
      assert "match" in missing
    end

    test "returns error for an uncompilable regex" do
      tmp = Path.join(System.tmp_dir!(), "bad_regex_#{System.unique_integer([:positive])}.yaml")

      File.write!(tmp, """
      patterns:
        - id: bad_regex
          severity: high
          kind: regex
          match: '('
      """)

      on_exit(fn -> File.rm(tmp) end)

      assert {:error, {:invalid_regex, "(", _}} = PatternLoader.load(tmp)
    end
  end
end
