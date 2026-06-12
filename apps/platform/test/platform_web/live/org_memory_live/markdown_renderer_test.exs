defmodule PlatformWeb.OrgMemoryLive.MarkdownRendererTest do
  @moduledoc """
  T7 stage 4 (task 019e41da-3610-7972-8573-54121ea1f3f5) — unit tests
  for the pure markdown + wikilink renderer. No DB: target resolution
  goes through the lookup map the caller passes in.
  """

  use ExUnit.Case, async: true

  alias PlatformWeb.OrgMemoryLive.MarkdownRenderer

  @lookup %{"org/identity.md" => "org/identity.md"}

  describe "render/2 wikilink swapping" do
    test "resolved link renders an <a class=\"wikilink\"> with the resolved href" do
      html = MarkdownRenderer.render("See [[org/identity.md]] for details.", @lookup)

      assert html =~
               ~s(<a href="/org_memory/org/identity.md" class="wikilink">org/identity.md</a>)
    end

    test "dangling link renders a <span class=\"wikilink-dangling\">" do
      html = MarkdownRenderer.render("See [[ghost]] for details.", %{})

      assert html =~
               ~s(<span class="wikilink-dangling" title="Dangling — page does not exist">ghost</span>)

      refute html =~ "<a "
    end

    test "piped display [[target|label]] renders the label as link text" do
      html = MarkdownRenderer.render("See [[org/identity.md|Who we are]].", @lookup)

      assert html =~
               ~s(<a href="/org_memory/org/identity.md" class="wikilink">Who we are</a>)

      # Piped dangling tokens keep the display text too.
      dangling = MarkdownRenderer.render("See [[ghost|Spooky]].", @lookup)
      assert dangling =~ ~s(<span class="wikilink-dangling")
      assert dangling =~ ">Spooky</span>"
    end

    test "token inside a fenced code block is NOT swapped" do
      content = """
      Before.

      ```
      [[org/identity.md]]
      ```

      After.
      """

      html = MarkdownRenderer.render(content, @lookup)

      refute html =~ "wikilink"
      # The literal token survives inside the rendered code block.
      assert html =~ "[[org/identity.md]]"
      assert html =~ "<pre>"
    end

    test "token inside inline code is NOT swapped" do
      html = MarkdownRenderer.render("Use `[[org/identity.md]]` syntax.", @lookup)

      refute html =~ "wikilink"
      assert html =~ "[[org/identity.md]]"
      assert html =~ "<code"
    end

    test "alias resolution: href uses the resolved file_key, text shows the alias token" do
      lookup = %{"ORG_IDENTITY.md" => "org/identity.md"}

      html = MarkdownRenderer.render("Legacy [[ORG_IDENTITY.md]] link.", lookup)

      assert html =~
               ~s(<a href="/org_memory/org/identity.md" class="wikilink">ORG_IDENTITY.md</a>)
    end
  end

  describe "render/2 pipeline" do
    test "frontmatter is stripped before rendering" do
      content = """
      ---
      preamble: true
      ---
      # Heading

      Body with [[org/identity.md]].
      """

      html = MarkdownRenderer.render(content, @lookup)

      refute html =~ "preamble"
      assert html =~ "<h1>"
      assert html =~ ~s(class="wikilink")
    end

    test "nil and empty content render to empty string" do
      assert MarkdownRenderer.render(nil, @lookup) == ""
      assert MarkdownRenderer.render("", @lookup) == ""
    end
  end
end
