defmodule Platform.Design.CssRules do
  @moduledoc """
  A deliberately small CSS rule reader for design guards over
  `apps/platform/assets/css/app.css`. Test-support only; nothing in `lib/`
  uses it. Sits beside `Platform.Design.WcagContrast` for the same reason:
  a guard that reads the stylesheet is only a guard if it reads the
  stylesheet the way the browser does, and a line grep does not.

  ## What it does

    * `rules/1` — every *style rule* in a stylesheet as
      `%{selector, body, at}`: comments stripped, selector lists split on
      top-level commas into one entry per compound selector, conditional
      at-rules (`@media`, `@supports`, `@layer`, `@container`) descended into
      with their preludes recorded in `at`, and `@keyframes` blocks **skipped
      whole** — their `from`/`to`/`50%` steps are not selectors and an
      `opacity` inside one is a legitimate animation, not a resting fade.
      Read them separately with `keyframes/1`.
    * `matches?/2` — does a selector apply to an element? Handles type,
      `*`, `.class`, `#id`, `[attr]`, `[attr op "v"]`, compounds, selector
      lists, descendant and `>` combinators, and `:not()` / `:is()` /
      `:where()` by evaluation. Everything it cannot evaluate against a
      single element and its ancestors is resolved TOWARDS MATCHING:
      pseudo-classes and pseudo-elements (`:hover`, `:focus-visible`,
      `::before`) match, structural pseudos (`:nth-child()`, `:has()`)
      match, and the sibling combinators `+` / `~` place no constraint on
      the left-hand side. `.x:hover { opacity: .5 }` therefore still fades
      `.x`, and an over-match is a LOUD false positive naming the rule,
      never a silent miss.
    * `declares?/2` — does a rule body declare a property by name, anchored
      so that `--opacity-token:` and `mix-blend-mode:` do not count.

  ## What it refuses to do — on purpose

  Anything `matches?/2` cannot parse **raises** with the selector in the
  message. A silent `false` is a rule the guard cannot see, which is exactly
  the defect class the guards built on this module exist to catch. Likewise
  a style rule whose body contains a nested block raises rather than being
  read as a flat body. Widen the grammar when a raise is hit; never swallow
  it. As of task 01a078d1 the grammar covers every selector in `app.css`.
  """

  @type rule :: %{selector: String.t(), body: String.t(), at: [String.t()]}
  @type element :: %{
          tag: String.t(),
          classes: MapSet.t(String.t()),
          attrs: %{optional(String.t()) => String.t()},
          ancestors: [element]
        }

  @descend ~w(@media @supports @layer @container)

  # ── rules ─────────────────────────────────────────────────────────────────

  @doc "Every style rule in `css`, one entry per compound selector."
  @spec rules(String.t()) :: [rule]
  def rules(css) do
    css
    |> strip_comments()
    |> walk([], [])
    |> Enum.reverse()
  end

  @doc """
  Every `@keyframes` block in `css` as `%{name => [%{step, body}]}`.
  """
  @spec keyframes(String.t()) :: %{
          optional(String.t()) => [%{step: String.t(), body: String.t()}]
        }
  def keyframes(css) do
    css
    |> strip_comments()
    |> collect_keyframes(%{})
  end

  @doc """
  The names of the `@keyframes` a rule body animates with, via `animation`
  or `animation-name`. Only names present in `known` (the keys of
  `keyframes/1`) are returned, because those are the only ones whose steps
  this stylesheet can be asked about.
  """
  @spec animation_names(String.t(), Enumerable.t()) :: [String.t()]
  def animation_names(body, known) do
    known = MapSet.new(known)

    ~r/(?:^|;)\s*animation(?:-name)?\s*:\s*([^;]+)/
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.flat_map(fn [value] -> String.split(value, ~r/[\s,]+/, trim: true) end)
    |> Enum.filter(&MapSet.member?(known, &1))
    |> Enum.uniq()
  end

  @doc "Does `body` declare `property` (by exact name, as a declaration)?"
  @spec declares?(String.t(), String.t()) :: boolean
  def declares?(body, property) do
    Regex.match?(~r/(^|;)\s*#{Regex.escape(property)}\s*:/, body)
  end

  defp strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, "")

  # walk(rest, at_prefix, acc) -> {acc, rest_after_closing_brace} | acc
  defp walk(css, at, acc) do
    case next_token(css) do
      :eof ->
        acc

      {:statement, _prelude, rest} ->
        walk(rest, at, acc)

      {:close, _rest} ->
        # Only reached at top level for a stray `}`; the recursive walker
        # returns through walk_block/3 instead.
        raise ArgumentError, "unbalanced `}` in stylesheet"

      {:block, prelude, rest} ->
        {acc, rest} = handle_block(prelude, rest, at, acc)
        walk(rest, at, acc)
    end
  end

  defp walk_block(css, at, acc) do
    case next_token(css) do
      :eof ->
        raise ArgumentError, "unterminated block under #{inspect(at)}"

      {:statement, _prelude, rest} ->
        walk_block(rest, at, acc)

      {:close, rest} ->
        {acc, rest}

      {:block, prelude, rest} ->
        {acc, rest} = handle_block(prelude, rest, at, acc)
        walk_block(rest, at, acc)
    end
  end

  defp handle_block("@keyframes" <> _, rest, _at, acc) do
    {_body, rest} = take_balanced(rest)
    {acc, rest}
  end

  defp handle_block("@" <> _ = prelude, rest, at, acc) do
    if Enum.any?(@descend, &String.starts_with?(prelude, &1 <> " ")) or prelude in @descend do
      walk_block(rest, at ++ [prelude], acc)
    else
      # @plugin, @theme, @font-face, @property, …: a block of declarations
      # with no selector, so it cannot apply to an element. Skipped.
      {_body, rest} = take_balanced(rest)
      {acc, rest}
    end
  end

  defp handle_block(prelude, rest, at, acc) do
    {body, rest} = take_flat_body(rest, prelude)

    acc =
      prelude
      |> split_top_level(?,)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(acc, fn selector, acc ->
        [%{selector: selector, body: body, at: at} | acc]
      end)

    {acc, rest}
  end

  defp take_flat_body(rest, prelude) do
    {body, rest} = take_balanced(rest)

    if String.contains?(body, "{") do
      raise ArgumentError,
            "nested block inside `#{prelude} { ... }` — CssRules reads flat rule bodies only"
    end

    {String.trim(body), rest}
  end

  # After a `{` has been consumed: return the balanced body and the rest
  # after the matching `}`.
  defp take_balanced(css), do: take_balanced(css, 0, [])

  defp take_balanced(<<?{, rest::binary>>, depth, acc),
    do: take_balanced(rest, depth + 1, [?{ | acc])

  defp take_balanced(<<?}, rest::binary>>, 0, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_balanced(<<?}, rest::binary>>, depth, acc),
    do: take_balanced(rest, depth - 1, [?} | acc])

  defp take_balanced(<<c::utf8, rest::binary>>, depth, acc),
    do: take_balanced(rest, depth, [<<c::utf8>> | acc])

  defp take_balanced(<<>>, _depth, _acc),
    do: raise(ArgumentError, "unterminated block in stylesheet")

  # The next syntactic unit: a `prelude {`, a `prelude;`, a `}`, or eof.
  defp next_token(css), do: next_token(String.trim_leading(css), [])

  defp next_token(<<>>, acc) do
    case acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim() do
      "" ->
        :eof

      dangling ->
        raise ArgumentError, "dangling prelude at end of stylesheet: #{inspect(dangling)}"
    end
  end

  defp next_token(<<?{, rest::binary>>, acc), do: {:block, prelude(acc), rest}
  defp next_token(<<?;, rest::binary>>, acc), do: {:statement, prelude(acc), rest}
  defp next_token(<<?}, rest::binary>>, []), do: {:close, rest}

  defp next_token(<<?}, _::binary>>, acc),
    do: raise(ArgumentError, "prelude without block: #{inspect(prelude(acc))}")

  defp next_token(<<c::utf8, rest::binary>>, acc), do: next_token(rest, [<<c::utf8>> | acc])

  defp prelude(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()

  defp collect_keyframes(css, acc) do
    case Regex.run(~r/@keyframes\s+([\w-]+)\s*\{/, css, return: :index) do
      nil ->
        acc

      [{start, len}, {ns, nl}] ->
        name = binary_part(css, ns, nl)
        rest = binary_part(css, start + len, byte_size(css) - start - len)
        {body, rest} = take_balanced(rest)
        collect_keyframes(rest, Map.put(acc, name, keyframe_steps(body)))
    end
  end

  defp keyframe_steps(body) do
    ~r/([^{}]+)\{([^{}]*)\}/
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [step, decls] -> %{step: String.trim(step), body: String.trim(decls)} end)
  end

  # Split on `sep` outside parentheses, brackets and quotes.
  defp split_top_level(s, sep), do: split_top_level(s, sep, 0, nil, [], [])

  defp split_top_level(<<>>, _sep, _depth, _q, cur, out),
    do: Enum.reverse([IO.iodata_to_binary(Enum.reverse(cur)) | out])

  defp split_top_level(<<c::utf8, rest::binary>>, sep, depth, q, cur, out) do
    ch = <<c::utf8>>

    cond do
      q != nil and c == q ->
        split_top_level(rest, sep, depth, nil, [ch | cur], out)

      q != nil ->
        split_top_level(rest, sep, depth, q, [ch | cur], out)

      c in [?", ?'] ->
        split_top_level(rest, sep, depth, c, [ch | cur], out)

      c in [?(, ?[] ->
        split_top_level(rest, sep, depth + 1, q, [ch | cur], out)

      c in [?), ?]] ->
        split_top_level(rest, sep, depth - 1, q, [ch | cur], out)

      c == sep and depth == 0 ->
        split_top_level(rest, sep, depth, q, [], [IO.iodata_to_binary(Enum.reverse(cur)) | out])

      true ->
        split_top_level(rest, sep, depth, q, [ch | cur], out)
    end
  end

  # ── matches? ──────────────────────────────────────────────────────────────

  @doc """
  Does `selector` (a selector or selector list) apply to `element`? Raises
  on any selector syntax this matcher does not understand — see the
  moduledoc for why that is not a `false`, and for which constructs are
  resolved towards matching.
  """
  @spec matches?(String.t(), element) :: boolean
  def matches?(selector, element) do
    selector
    |> split_top_level(?,)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.any?(fn complex -> complex |> chain!() |> match_chain(element) end)
  end

  @doc """
  Build an `element` from a tag name, a `LazyHTML.attributes/1`-shaped
  attribute list, and its ancestor elements nearest first.
  """
  @spec element(String.t(), [{String.t(), String.t()}], [element]) :: element
  def element(tag, attrs, ancestors \\ []) do
    attrs = Map.new(attrs)

    %{
      tag: tag,
      classes: attrs |> Map.get("class", "") |> String.split() |> MapSet.new(),
      attrs: attrs,
      ancestors: ancestors
    }
  end

  # A complex selector into [{combinator_to_the_right, compound}], left to
  # right; the subject (rightmost) carries `nil`.
  defp chain!(selector) do
    selector
    |> tokenize_complex!()
    |> attach(selector)
  end

  # Tokens: parsed compounds and the combinator atoms between them. Split
  # at depth 0 only, so `:has(> .x)` and `:not(pre code)` stay inside
  # their compound.
  defp tokenize_complex!(selector), do: tokenize_complex!(selector, 0, [], [], selector)

  defp tokenize_complex!(<<>>, 0, cur, out, sel), do: Enum.reverse(flush_compound!(cur, out, sel))

  defp tokenize_complex!(<<>>, _depth, _cur, _out, sel),
    do: raise(ArgumentError, "unbalanced parentheses in #{inspect(sel)}")

  defp tokenize_complex!(<<c::utf8, rest::binary>>, depth, cur, out, sel) do
    cond do
      c == ?\\ ->
        <<n::utf8, rest::binary>> = rest
        tokenize_complex!(rest, depth, [<<c::utf8, n::utf8>> | cur], out, sel)

      c in [?(, ?[] ->
        tokenize_complex!(rest, depth + 1, [<<c::utf8>> | cur], out, sel)

      c in [?), ?]] ->
        tokenize_complex!(rest, depth - 1, [<<c::utf8>> | cur], out, sel)

      depth > 0 ->
        tokenize_complex!(rest, depth, [<<c::utf8>> | cur], out, sel)

      c in [?>, ?+, ?~] ->
        comb = %{?> => :child, ?+ => :sibling, ?~ => :sibling}[c]
        tokenize_complex!(rest, depth, [], [comb | flush_compound!(cur, out, sel)], sel)

      c in [?\s, ?\n, ?\t] ->
        tokenize_complex!(rest, depth, [], [:descendant | flush_compound!(cur, out, sel)], sel)

      true ->
        tokenize_complex!(rest, depth, [<<c::utf8>> | cur], out, sel)
    end
  end

  defp flush_compound!([], out, _sel), do: out

  defp flush_compound!(cur, out, sel),
    do: [compound!(cur |> Enum.reverse() |> IO.iodata_to_binary(), sel) | out]

  @combinators [:child, :descendant, :sibling]

  # Collapse runs of combinators (`a > b` tokenizes as [a, :descendant,
  # :child, :descendant, b]): an explicit combinator wins over whitespace.
  defp attach(tokens, selector) do
    tokens
    |> collapse([])
    |> pair(selector)
  end

  defp collapse([], acc), do: Enum.reverse(acc)

  defp collapse([a | rest], [b | acc]) when a in @combinators and b in @combinators do
    keep = if a == :descendant, do: b, else: a
    collapse(rest, [keep | acc])
  end

  defp collapse([:descendant], acc), do: Enum.reverse(acc)
  defp collapse([:descendant | rest], []), do: collapse(rest, [])
  defp collapse([t | rest], acc), do: collapse(rest, [t | acc])

  defp pair([comp], _selector) when comp not in @combinators, do: [{nil, comp}]

  defp pair([comp, comb, next | rest], selector)
       when comp not in @combinators and comb in @combinators and next not in @combinators,
       do: [{comb, comp} | pair([next | rest], selector)]

  defp pair(_, selector),
    do:
      raise(
        ArgumentError,
        "CssRules.matches?/2 cannot parse the combinators in #{inspect(selector)}"
      )

  # A compound into a list of simple-selector terms.
  defp compound!(compound, selector), do: compound!(compound, selector, [])

  defp compound!(<<>>, _selector, terms), do: Enum.reverse(terms)

  defp compound!("*" <> rest, sel, terms), do: compound!(rest, sel, [:universal | terms])

  defp compound!("::" <> rest, sel, terms) do
    {_name, rest} = ident!(rest, sel)
    compound!(rest, sel, [:matches | terms])
  end

  defp compound!(":" <> rest, sel, terms) do
    {name, rest} = ident!(rest, sel)

    case rest do
      "(" <> _ ->
        {inner, rest} = take_parens!(rest, sel)
        compound!(rest, sel, [pseudo_fn!(name, inner, sel) | terms])

      _ when name == "root" ->
        # The one non-functional pseudo-class that CAN be evaluated here:
        # `:root` is the document element and nothing else.
        compound!(rest, sel, [{:type, "html"} | terms])

      _ ->
        compound!(rest, sel, [:matches | terms])
    end
  end

  defp compound!("." <> rest, sel, terms) do
    {name, rest} = ident!(rest, sel)
    compound!(rest, sel, [{:class, name} | terms])
  end

  defp compound!("#" <> rest, sel, terms) do
    {name, rest} = ident!(rest, sel)
    compound!(rest, sel, [{:attr, "id", "=", name} | terms])
  end

  defp compound!("[" <> rest, sel, terms) do
    {inner, rest} = take_bracket!(rest, sel)

    term =
      ~r/^\s*([\w-]+)\s*(?:([~|^$*]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\s"']+)))?\s*$/
      |> Regex.run(inner)
      |> case do
        nil ->
          raise ArgumentError, "unsupported attribute selector [#{inner}] in #{inspect(sel)}"

        [_, name] ->
          {:attr, name}

        [_, name, "" | _] ->
          {:attr, name}

        [_, name, op | values] ->
          {:attr, name, op, values |> Enum.reject(&(&1 == "")) |> List.first("")}
      end

    compound!(rest, sel, [term | terms])
  end

  defp compound!(other, sel, terms) do
    case ident!(other, sel) do
      {"", _} ->
        raise ArgumentError,
              "CssRules.matches?/2 cannot parse #{inspect(other)} in #{inspect(sel)}"

      {name, rest} ->
        compound!(rest, sel, [{:type, name} | terms])
    end
  end

  # `:not(...)` and `:is()`/`:where()` are evaluated; every other functional
  # pseudo-class (`:nth-child(2)`, `:has(...)`) is resolved towards matching.
  defp pseudo_fn!("not", inner, _sel), do: {:not, inner}
  defp pseudo_fn!(name, inner, _sel) when name in ["is", "where"], do: {:is, inner}
  defp pseudo_fn!(_name, _inner, _sel), do: :matches

  # An identifier with `\x` escapes unescaped.
  defp ident!(s, sel), do: ident!(s, sel, [])

  defp ident!(<<?\\, c::utf8, rest::binary>>, sel, acc),
    do: ident!(rest, sel, [<<c::utf8>> | acc])

  defp ident!(<<c::utf8, rest::binary>>, sel, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?_],
       do: ident!(rest, sel, [<<c::utf8>> | acc])

  defp ident!(rest, _sel, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_parens!("(" <> rest, sel), do: take_until!(rest, ?(, ?), 0, [], sel)
  defp take_bracket!(rest, sel), do: take_until!(rest, ?[, ?], 0, [], sel)

  defp take_until!(<<c::utf8, rest::binary>>, open, close, depth, acc, sel) do
    cond do
      c == close and depth == 0 -> {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
      c == close -> take_until!(rest, open, close, depth - 1, [<<c::utf8>> | acc], sel)
      c == open -> take_until!(rest, open, close, depth + 1, [<<c::utf8>> | acc], sel)
      true -> take_until!(rest, open, close, depth, [<<c::utf8>> | acc], sel)
    end
  end

  defp take_until!(<<>>, _open, close, _depth, _acc, sel),
    do: raise(ArgumentError, "missing `#{<<close::utf8>>}` in #{inspect(sel)}")

  # Right-to-left: the subject compound must match the element itself.
  defp match_chain(chain, element) do
    [{nil, subject} | rest] = Enum.reverse(chain)
    compound_matches?(subject, element) and match_ancestors(rest, element.ancestors)
  end

  defp match_ancestors([], _ancestors), do: true

  # The combinator carried by `comp` sat between it and the compound to
  # its RIGHT (already matched), so `:child` constrains `comp` to the
  # immediate parent; `:sibling` constrains nothing this matcher can see.
  defp match_ancestors([{:child, comp} | rest], [parent | grand]) do
    compound_matches?(comp, parent) and match_ancestors(rest, grand)
  end

  defp match_ancestors([{:child, _} | _], []), do: false

  defp match_ancestors([{:sibling, _comp} | rest], ancestors),
    do: match_ancestors(rest, ancestors)

  defp match_ancestors([{:descendant, comp} | rest] = chain, [anc | grand]) do
    (compound_matches?(comp, anc) and match_ancestors(rest, grand)) or
      match_ancestors(chain, grand)
  end

  defp match_ancestors([{:descendant, _} | _], []), do: false

  defp compound_matches?(terms, element) do
    Enum.all?(terms, fn
      :universal -> true
      :matches -> true
      {:type, tag} -> element.tag == tag
      {:class, c} -> MapSet.member?(element.classes, c)
      {:attr, name} -> Map.has_key?(element.attrs, name)
      {:attr, name, op, value} -> attr_matches?(Map.fetch(element.attrs, name), op, value)
      {:not, inner} -> not matches?(inner, element)
      {:is, inner} -> matches?(inner, element)
    end)
  end

  defp attr_matches?(:error, _op, _value), do: false
  defp attr_matches?({:ok, actual}, "=", value), do: actual == value
  defp attr_matches?({:ok, actual}, "^=", value), do: String.starts_with?(actual, value)
  defp attr_matches?({:ok, actual}, "$=", value), do: String.ends_with?(actual, value)
  defp attr_matches?({:ok, actual}, "*=", value), do: String.contains?(actual, value)
  defp attr_matches?({:ok, actual}, "~=", value), do: value in String.split(actual)

  defp attr_matches?({:ok, actual}, "|=", value),
    do: actual == value or String.starts_with?(actual, value <> "-")
end
