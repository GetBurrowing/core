defmodule Platform.Regression.ProductDocsOptGuardTest do
  @moduledoc """
  The product-owned `burrow/` namespace is guarded in the domain layer
  (`Platform.Org.Wiki` and `Platform.Org.Context`): a write to a `burrow/`
  key is refused with `{:error, :product_owned}` unless the caller passes
  the `:product_docs` opt set to true (task 01a10a44 stage 2).

  That opt is a bypass, so the guard is only as strong as the set of
  callers that pass it. Exactly one may: `Platform.Org.BurrowDocs`, the
  boot sync that mirrors `docs/burrow` into the wiki. This test scans every
  app's `lib/` AS TEXT and fails when the opt appears anywhere else.

  The positive control feeds the same scanner a fixture file carrying the
  opt and asserts the scanner names it, so a green run here cannot be a
  scanner that matches nothing.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @allowed Path.join(@repo_root, "apps/platform/lib/platform/org/burrow_docs.ex")

  # The opt as a keyword pair, and as the two-element tuple / Keyword.put
  # argument shapes, with any whitespace.
  @token ~r/product_docs:\s*true|:product_docs\s*,\s*true/

  defp scanned_files do
    Path.wildcard(Path.join(@repo_root, "apps/*/lib/**/*.{ex,exs,heex}"))
  end

  # Every scanned file carrying the opt, other than the one allowed writer.
  defp offenders(files) do
    files
    |> Enum.reject(&(&1 == @allowed))
    |> Enum.filter(&Regex.match?(@token, File.read!(&1)))
    |> Enum.map(&Path.relative_to(&1, @repo_root))
  end

  test "the scanned set is real and includes the allowed writer" do
    files = scanned_files()
    assert length(files) > 100
    assert @allowed in files
  end

  test "the allowed writer itself carries the opt (the token spelling is live)" do
    assert Regex.match?(@token, File.read!(@allowed))
  end

  test "no file under any app's lib/ other than org/burrow_docs.ex passes the opt" do
    assert offenders(scanned_files()) == []
  end

  @tag :tmp_dir
  test "POSITIVE CONTROL: a fixture carrying the opt is named by the scanner", %{tmp_dir: dir} do
    keyword = Path.join(dir, "fixture_keyword.ex")
    tuple = Path.join(dir, "fixture_tuple.ex")

    File.write!(keyword, ~s|Wiki.upsert_page("burrow/page/x.md", %{}, product_docs:  true)\n|)
    File.write!(tuple, ~s|Keyword.put(opts, :product_docs, true)\n|)

    found = offenders(scanned_files() ++ [keyword, tuple])

    assert Path.relative_to(keyword, @repo_root) in found
    assert Path.relative_to(tuple, @repo_root) in found
    assert length(found) == 2
  end
end
