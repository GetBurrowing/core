defmodule Platform.Files.Extractor.HTMLTest do
  @moduledoc """
  The load-bearing assertions here are the ABSENCES — script and style bodies
  must not reach the index. Every one of them is paired with a positive control
  in the same test, because an absence assertion passes for an extractor that
  returns "" and that failure is invisible otherwise.
  """
  use ExUnit.Case, async: true

  alias Platform.Files
  alias Platform.Files.Extractor

  # Sentinels are distinctive strings rather than realistic code, so a hit is
  # unambiguously a leak from the block it was planted in.
  @script_body "zzScriptLeakSentinel()"
  @style_body "zz-style-leak-sentinel"

  @chrome_page """
  <!doctype html>
  <html>
    <head>
      <title>Quarterly report</title>
      <style>.nav { color: red } /* #{@style_body} */</style>
      <script>function boot() { console.log("#{@script_body}"); }</script>
    </head>
    <body>
      <nav class="flex"><a href="/home">Home</a><a href="/about">About</a></nav>
      <main>
        <p>Revenue grew because the pipeline converted earlier.</p>
      </main>
      <script>window.analytics = "#{@script_body}";</script>
    </body>
  </html>
  """

  @structured_page """
  <!doctype html>
  <html>
    <body>
      <h1>Title</h1>
      <p>Intro paragraph.</p>
      <h2>Details</h2>
      <ul>
        <li>First point</li>
        <li>Second point</li>
      </ul>
      <p>See the <a href="https://example.test/docs">docs</a> for more.</p>
    </body>
  </html>
  """

  describe "script and style contents" do
    test "are absent from the output, and the real prose is present" do
      {:ok, %{text: text}} = Extractor.HTML.extract(@chrome_page)

      # POSITIVE CONTROL, first: without this the refutes below pass for an
      # extractor that returns an empty string.
      assert text =~ "Revenue grew because the pipeline converted earlier."

      refute text =~ @script_body,
             "script body leaked into extracted text: #{inspect(text)}"

      refute text =~ @style_body,
             "style body leaked into extracted text: #{inspect(text)}"
    end

    test "markup itself does not survive as text" do
      {:ok, %{text: text}} = Extractor.HTML.extract(@chrome_page)

      assert text =~ "Revenue grew"
      refute text =~ "<div"
      refute text =~ "class=\"flex\""
    end
  end

  describe "structure" do
    test "headings, list items and links render as exact markdown-ish strings" do
      {:ok, %{text: text}} = Extractor.HTML.extract(@structured_page)

      # Exact strings, not substrings of a looser shape: "# Title" would be
      # satisfied by "#Title" or "## Title" under a sloppier assertion.
      lines = String.split(text, "\n")

      assert "# Title" in lines
      assert "## Details" in lines
      assert "- First point" in lines
      assert "- Second point" in lines
      assert text =~ "[docs](https://example.test/docs)"
    end

    test "pages is nil — an HTML document is one flow" do
      assert {:ok, %{pages: nil}} = Extractor.HTML.extract(@structured_page)
    end
  end

  describe "dispatch and ingest intent" do
    # Two DIFFERENT claims. The first says an extractor exists; the second says
    # a freshly uploaded HTML file is actually offered to agents. The second is
    # what unlocks agent reads and does not follow from the first by inspection.
    test "supported_content_type?/1 is true for text/html" do
      assert Extractor.supported_content_type?("text/html")
    end

    test "a fresh HTML file defaults to ingest intent attempt, not human_only" do
      assert Files.default_ingest_intent("text/html") == "attempt"

      # Control: an genuinely unsupported type still defaults to human_only, so
      # the assertion above is not passing because the function returns
      # "attempt" for everything.
      assert Files.default_ingest_intent("application/x-not-a-real-type") == "human_only"
    end
  end

  describe "extract/2 bytes overload — the dispatch seam" do
    # These duplicate the assertions above ON PURPOSE, through the dispatcher
    # rather than the module. The distinction is load-bearing and was found by
    # running the mutation probe: pointing the `text/html` clause at
    # `Extractor.Text` leaves every direct-call assertion GREEN, because a test
    # that calls `Extractor.HTML.extract/1` never crosses the seam the mutation
    # breaks. Only a dispatch-routed test can fail for the reason this stage
    # exists.
    test "routes text/html through the HTML extractor, not the pass-through" do
      {:ok, %{text: text}} = Extractor.extract(@structured_page, "text/html")
      assert text =~ "# Title"
      refute text =~ "<h1>"
    end

    test "script and style bodies do not survive dispatch, and the prose does" do
      {:ok, %{text: text}} = Extractor.extract(@chrome_page, "text/html")

      assert text =~ "Revenue grew because the pipeline converted earlier."

      refute text =~ @script_body,
             "script body reached the index through dispatch: #{inspect(text)}"

      refute text =~ @style_body,
             "style body reached the index through dispatch: #{inspect(text)}"
    end
  end

  describe "degenerate input" do
    test "an empty document yields empty text rather than crashing" do
      assert {:ok, %{text: "", pages: nil}} = Extractor.HTML.extract("")
    end

    test "unclosed tags still yield their text" do
      assert {:ok, %{text: text}} = Extractor.HTML.extract("<p>dangling")
      assert text == "dangling"
    end
  end
end
