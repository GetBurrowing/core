defmodule Platform.Chat.ContentRendererTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.ContentRenderer

  describe "render_message/1" do
    test "returns empty for nil" do
      assert {:safe, ""} = ContentRenderer.render_message(nil)
    end

    test "returns empty for empty string" do
      assert {:safe, ""} = ContentRenderer.render_message("")
    end

    test "renders plain text as paragraph" do
      result = render("Hello world")
      assert result =~ "<p>"
      assert result =~ "Hello world"
    end

    test "renders bold and italic" do
      result = render("**bold** and *italic*")
      assert result =~ "<strong>bold</strong>"
      assert result =~ "<em>italic</em>"
    end

    test "renders bullet lists" do
      md = """
      - item one
      - item two
      """

      result = render(md)
      assert result =~ "<ul>"
      assert result =~ "<li>"
      assert result =~ "item one"
      assert result =~ "item two"
    end

    test "renders numbered lists" do
      md = """
      1. first
      2. second
      """

      result = render(md)
      assert result =~ "<ol>"
      assert result =~ "first"
    end

    test "renders inline code" do
      result = render(~S(use `mix test`))
      assert result =~ "<code"
      assert result =~ "mix test"
    end

    test "renders code blocks with language" do
      md = """
      ```elixir
      defmodule Foo do
        def bar
      end
      ```
      """

      result = render(md)
      assert result =~ "code-block-wrapper"
      assert result =~ "CodeBlock"
      assert result =~ ~s[data-language="elixir"]
      assert result =~ "defmodule Foo"
      # Phoenix hooks require a DOM id on each element.
      assert result =~ ~r/<div id="code-block-\d+" phx-hook="CodeBlock"/
    end

    test "renders code blocks without language" do
      md = """
      ```
      some code
      ```
      """

      result = render(md)
      assert result =~ "code-block-wrapper"
      assert result =~ "some code"
      assert result =~ ~r/<div id="code-block-\d+" phx-hook="CodeBlock"/
    end

    test "multiple code blocks get unique ids" do
      md = """
      ```elixir
      one
      ```

      ```elixir
      two
      ```
      """

      result = render(md)

      ids =
        Regex.scan(~r/<div id="(code-block-\d+)" phx-hook="CodeBlock"/, result)
        |> Enum.map(&Enum.at(&1, 1))

      assert length(ids) == 2
      assert Enum.uniq(ids) == ids
    end

    test "renders links with target=_blank" do
      md = ~s{[click here](https://example.com)}
      result = render(md)
      assert result =~ ~s[target="_blank"]
      assert result =~ ~s[rel="noopener noreferrer"]
      assert result =~ "https://example.com"
      assert result =~ "click here"
    end

    test "renders blockquotes" do
      result = render("> important quote")
      assert result =~ "<blockquote>"
      assert result =~ "important quote"
    end

    test "renders horizontal rules" do
      result = render("---")
      assert result =~ "<hr"
    end

    test "renders tables" do
      md = """
      | A | B |
      |---|---|
      | 1 | 2 |
      """

      result = render(md)
      assert result =~ "<table>"
      assert result =~ "<th"
      assert result =~ "<td"
    end

    test "downgrades h1 and h2 to h3" do
      result = render("# Big Header")
      assert result =~ "<h3>"
      refute result =~ "<h1>"

      result2 = render("## Medium Header")
      assert result2 =~ "<h3>"
      refute result2 =~ "<h2>"
    end

    test "keeps h3 as h3" do
      result = render("### Third")
      assert result =~ "<h3>"
    end
  end

  describe "XSS sanitization" do
    test "strips script tags" do
      input = "<script>alert('xss')</script>"
      result = render(input)
      refute result =~ "<script"
      refute result =~ "alert"
    end

    test "strips iframe tags" do
      result = render(~s[<iframe src='evil'></iframe>])
      refute result =~ "<iframe"
    end

    test "strips on-event handlers" do
      result = render(~s[<img src="x" onerror="bad">])
      refute result =~ "onerror"
    end

    test "neutralizes dangerous URL schemes" do
      js_scheme = "javascript" <> ":"
      md = ~s{[click](} <> js_scheme <> ~s{void)}
      result = render(md)
      refute result =~ js_scheme
    end

    test "strips style tags" do
      # Earmark escapes raw HTML style tags; our sanitizer strips any that survive
      result = render("hello <style>body{color: red}</style> world")
      refute result =~ "<style"
      assert result =~ "hello"
    end
  end

  describe "@-mention decoration" do
    test "decorates @mentions in text" do
      result = render("Hello @alice and @bob")
      assert result =~ ~s[class="rounded bg-primary/20 text-primary px-1 font-medium"]
      assert result =~ "@alice"
      assert result =~ "@bob"
    end

    test "preserves mentions inside code" do
      result = render(~S(`@not_a_mention`))
      assert result =~ "@not_a_mention"
    end
  end

  describe "highlight_code/2" do
    test "highlights Elixir code" do
      code = "defmodule Foo do\n  def bar\nend"
      result = ContentRenderer.highlight_code(code, "elixir")
      assert result =~ "<span"
    end

    test "returns escaped code for unknown language" do
      result = ContentRenderer.highlight_code(~s[<b>hi</b>], "unknown")
      refute result =~ "<b>"
      assert result =~ "&lt;b&gt;"
    end
  end

  # Helper to render and extract string from Phoenix.HTML.safe tuple
  defp render(content) do
    case ContentRenderer.render_message(content) do
      {:safe, iodata} -> IO.iodata_to_binary(iodata)
      other -> to_string(other)
    end
  end
end
