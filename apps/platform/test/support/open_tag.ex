defmodule Platform.OpenTag do
  @moduledoc """
  One reader for the opening tag of a rendered element, shared by the LiveView
  render assertions that need to inspect an element's attribute cluster.

  ## Why this is not `=~` on the whole document

  `assert html =~ "max-w-lg"` passes when the class sits on any element
  anywhere on the page: a sidebar, a modal, a card. Pulling the ONE element's
  open tag out first and asserting on that is what makes the assertion about
  the element the test names.

  ## Why tags, and never attribute order

  Phoenix renders an element's dynamic attributes in non-deterministic order
  across runs, so a regex that spells two attributes in sequence passes or
  fails by luck. Everything here extracts the whole open tag and leaves the
  assertions to the caller, and `class_tokens/1` splits the class attribute so
  a caller asserts on TOKENS rather than on substrings of the class string.
  The token split is load-bearing, not tidiness: `"w-full"` is a substring of
  `max-w-full`, so a substring check for the mobile full-bleed base passes on
  a panel that only carries a max-width.

  Extracted from `tasks_live_test.exs` (task 019f5eb3 stage 3), where
  `open_tag_for/2` was private and the drawer parity guard needed the same
  reader. Test support only; nothing in `lib/` uses it.
  """

  @doc """
  The opening tag of the element carrying `data-role="\#{role}"`, or `nil`.

  Attribute values are HTML-escaped by the renderer, so `>` cannot appear
  inside one and `[^>]*` is a safe bound on the tag.
  """
  def open_tag_for(html, role) do
    case Regex.run(~r/<[a-zA-Z]+[^>]*data-role="#{role}"[^>]*>/, html) do
      [tag] -> tag
      _ -> nil
    end
  end

  @doc """
  Every opening tag whose `class` attribute carries ALL of `tokens`.

  Order-independent in both directions: the tokens may appear in any order in
  the class attribute, and the class attribute may sit anywhere in the tag.
  Use it to find an element that carries no `id` and no `data-role` by the
  class recipe that identifies it.
  """
  def open_tags_with_classes(html, tokens) do
    ~r/<[a-zA-Z][a-zA-Z0-9]*\s[^>]*>/
    |> Regex.scan(html)
    |> Enum.map(fn [tag] -> tag end)
    |> Enum.filter(fn tag ->
      present = class_tokens(tag)
      Enum.all?(tokens, &(&1 in present))
    end)
  end

  @doc """
  The whitespace-separated class tokens of one open tag, `[]` when it has no
  class attribute.
  """
  def class_tokens(tag) when is_binary(tag) do
    case Regex.run(~r/\sclass="([^"]*)"/, tag) do
      [_, class] -> String.split(class, ~r/\s+/, trim: true)
      _ -> []
    end
  end
end
