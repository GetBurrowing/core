defmodule Platform.Regression.InstallIdentityShapeDiagnosticTest do
  use ExUnit.Case, async: true

  alias Platform.Regression.InstallIdentityScanner, as: Scanner
  @diagnostic Platform.Regression.InstallIdentityShapeDiagnostic

  test "bounded run shapes are useful without disclosing their bytes" do
    describe = fn html, hits -> apply(@diagnostic, :describe, [html, hits]) end
    assert describe.(" abc ", [{1, 3}]) == "whole len=3 chars=lower"
    assert describe.(" Zabc123 ", [{2, 3}]) == "interior len=8 chars=mixed_digits"

    assert describe.(" " <> String.duplicate("a", 140) <> " ", [{70, 3}]) ==
             "interior len=>bound chars=unknown"

    assert describe.("abc", [{9, 3}]) == "unknown len=unknown chars=unknown"

    canary = "CanarySecret123"
    html = " " <> canary <> " "
    output = describe.(html, List.duplicate({2, 3}, 10))
    assert output =~ "+more"
    refute output =~ canary
    refute output =~ "ana"
    refute output =~ html
    assert byte_size(output) < 512

    plant = Scanner.published_org_token()
    html = " " <> plant <> " "
    hits = Scanner.hits(html)
    assert hits == [{1, byte_size(plant)}]
    output = apply(@diagnostic, :when_hits, [html, hits, describe])
    assert output == "whole len=8 chars=lower"
    refute output =~ plant

    forbidden = fn _, _ -> flunk("formatter ran on a clean render") end
    assert apply(@diagnostic, :when_hits, ["clean", [], forbidden]) == ""
    raises = fn _, _ -> raise "private canary" end
    assert apply(@diagnostic, :when_hits, ["abc", [{0, 3}], raises]) == "diagnostic unavailable"
  end

  test "run boundaries and truncated sides use fixed categories" do
    describe = fn html, hits -> apply(@diagnostic, :describe, [html, hits]) end

    cases = [
      {"abcXYZ ", {0, 3}, "interior len=8 chars=mixed"},
      {" XYZabc", {4, 3}, "interior len=8 chars=mixed"},
      {"abc ", {0, 3}, "whole len=3 chars=lower"},
      {" abc", {1, 3}, "whole len=3 chars=lower"},
      {" " <> String.duplicate("x", 70) <> "abc ", {71, 3}, "interior len=>bound chars=unknown"},
      {" abc" <> String.duplicate("x", 70) <> " ", {1, 3}, "interior len=>bound chars=unknown"},
      {" " <> String.duplicate("a", 40) <> " ", {1, 3}, "interior len=>32 chars=lower"},
      {" ab-cd ", {1, 5}, "unknown len=unknown chars=unknown"}
    ]

    for {html, span, expected} <- cases do
      output = describe.(html, [span])
      assert output == expected
      refute output =~ "abc"
      refute output =~ "ab-cd"
    end
  end
end
