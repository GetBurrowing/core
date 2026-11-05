defmodule Platform.Org.Wiki.ReadersDependencyTest do
  @moduledoc """
  The `readers:` rule is generic: the Wiki enforces a frontmatter key and
  never reads People policy back. This pins the direction of the dependency
  by reading the two source files.
  """
  use ExUnit.Case, async: true

  @sources [
    "lib/platform/org/wiki/readers.ex",
    "lib/platform/org/wiki.ex"
  ]

  test "Platform.Org.Wiki.Readers and Platform.Org.Wiki reference no Platform.People module" do
    for relative <- @sources do
      path = Path.join(File.cwd!(), relative)
      source = File.read!(path)

      # anti-vacuity: the file we read is the module we mean
      assert source =~ "defmodule Platform.Org.Wiki", relative
      refute source =~ "Platform.People", "#{relative} references a Platform.People module"
    end
  end
end
