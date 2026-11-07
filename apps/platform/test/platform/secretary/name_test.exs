defmodule Platform.Secretary.NameTest do
  @moduledoc """
  The product name lives in exactly one place, `Platform.Secretary.name/0`
  (task 01a1b721 stage 1), so a rename is one line.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  @home Path.join(@lib, "platform/secretary.ex")
  @literal ~s("Secretary")
  @heex_text ">Secretary<"

  test "the quoted name appears nowhere in lib/ but its home" do
    files = Path.wildcard(Path.join(@lib, "**/*.{ex,heex}"))
    assert length(files) > 100, "the scan read #{length(files)} files"
    assert @home in files

    hits =
      for file <- files,
          file != @home,
          content = File.read!(file),
          String.contains?(content, @literal) or String.contains?(content, @heex_text),
          do: Path.relative_to(file, @lib)

    assert hits == []
    assert File.read!(@home) =~ @literal
    assert Platform.Secretary.name() == "Secretary"
  end
end
