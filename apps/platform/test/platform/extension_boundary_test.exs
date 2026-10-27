defmodule Platform.ExtensionBoundaryTest do
  @moduledoc """
  Core never names a build-time module (ADR 0055, task 01a0ee08 stage 3;
  `0055-extension-contract-and-build-time-modules.md § Guardrails`).

  Two layers hold it:

    1. The without-modules compile. `cd apps/platform && MIX_ENV=dev mix
       compile --warnings-as-errors` has no module on its code path, so a
       CODE reference to one is an undefined-module warning, which fails it.
    2. This file: a TEXT scan, for what the compiler cannot see: a module
       named in a string, a `Module.concat/1` piece, an alias that is never
       called, a config value, a comment, a JS import or a test. It reads
       every file under apps/platform/{lib,config,assets/js,assets/css,test}
       and fails on any occurrence of a name a sibling project under `apps/`
       defines, naming file:line.

  ## The name set is DERIVED, never written down

  Every `defmodule` in every sibling project's `lib` and `test` is parsed
  (nesting resolved), so a module added to Play is guarded the day it is
  written, and a prefix like the module's top namespace is not the test: a
  prefix match on one namespace misses a module filed under another, e.g. a
  tool module under the federation namespace or a LiveView hook module under
  the web namespace. The set is:

    * every full module name, matched on word boundaries (with or without an
      `Elixir.` prefix); and
    * every module-owned name SEGMENT, so a `Module.concat/1` of separately
      written pieces is still seen. A segment is module-owned when it is a
      segment of a sibling lib module, is NOT a segment of any module core
      defines or any module on core's code path (Elixir, OTP, deps), and is
      a compound CamelCase word (two or more capitals). The last rule keeps
      one-word segments out: a single capitalised English word collides with
      prose (measured on this tree: `Seed` matched 119 comment lines and
      `Protocol` matched `Postgrex.Protocol`), while a compound one is a
      name. A one-word segment is still caught inside every full name;
    * every OS environment variable name a sibling lib reads, so core cannot
      grow back a read of a module's setting (the module owns its config;
      `0055-extension-contract-and-build-time-modules.md § 8. Configuration that belongs to a module`).

  One exemption, from the segment rule only: `@product_names`, third-party
  product names core shows as plain text (link previews name the site a
  link goes to, `Platform.Chat.LinkSites`). A sibling may name a module
  after the same product, which makes the word a compound segment it
  "owns"; the word in a site label is not a reference to that module. Every
  FULL sibling module name, including any that contains an exempt word, is
  still a needle, and a test below holds that.

  This file contains no module's name, so it cannot trip itself; it derives
  them at run time.

  ## Every silence here has a positive control

  An empty hit list proves nothing unless the scan can hit. So the same
  scanner is run over (a) a sibling project's own lib, which must be full of
  hits, and (b) planted snippets of every shape it claims to catch, built
  from the derived set.
  """

  use ExUnit.Case, async: true

  alias Platform.TestSupport.SourceIndex

  # Headroom, not the fix: the scan is one prefilter pass per file (see
  # `compile/1`). It reads every file under five roots, so a slow CI host
  # gets more than ExUnit's default 60 s.
  @moduletag timeout: 300_000

  @platform_root Path.expand("../..", __DIR__)
  @apps_root Path.expand("..", @platform_root)
  @scan_roots ~w(lib config assets/js assets/css test)
  @scan_exts ~w(.ex .exs .heex .eex .js .mjs .cjs .ts .css .json .md)

  # ── Derivation ───────────────────────────────────────────────────────

  defp sibling_projects do
    @apps_root
    |> File.ls!()
    |> Enum.map(&Path.join(@apps_root, &1))
    |> Enum.reject(&(&1 == @platform_root))
    |> Enum.filter(&File.exists?(Path.join(&1, "mix.exs")))
    |> Enum.sort()
  end

  defp elixir_files(dir),
    do:
      SourceIndex.wildcard(Path.join(dir, "**/*.{ex,exs}"))
      |> Enum.reject(&String.contains?(&1, "/deps/"))

  # Full module names `defmodule` declares in `files`, nesting resolved.
  defp defined_modules(files) do
    files
    |> Enum.flat_map(fn path ->
      path |> SourceIndex.read!() |> Code.string_to_quoted!(file: path) |> collect_modules([])
    end)
    |> Enum.uniq()
  end

  defp collect_modules({:defmodule, _, [name_ast, [do: body]]}, parents) do
    full = parents ++ module_parts(name_ast)
    [Enum.join(full, ".") | collect_modules(body, full)]
  end

  defp collect_modules({_, _, args}, parents) when is_list(args),
    do: Enum.flat_map(args, &collect_modules(&1, parents))

  defp collect_modules(list, parents) when is_list(list),
    do: Enum.flat_map(list, &collect_modules(&1, parents))

  defp collect_modules({a, b}, parents),
    do: collect_modules(a, parents) ++ collect_modules(b, parents)

  defp collect_modules(_other, _parents), do: []

  defp module_parts({:__aliases__, _, parts}), do: Enum.map(parts, &to_string/1)
  defp module_parts(atom) when is_atom(atom), do: atom |> inspect() |> String.split(".")

  defp module_names do
    sibling_projects()
    |> Enum.flat_map(&(elixir_files(Path.join(&1, "lib")) ++ elixir_files(Path.join(&1, "test"))))
    |> defined_modules()
    |> Enum.sort()
  end

  defp core_segments do
    loaded =
      for {name, _path, _loaded} <- :code.all_available(),
          name = to_string(name),
          String.starts_with?(name, "Elixir."),
          do: String.trim_leading(name, "Elixir.")

    ~w(lib test)
    |> Enum.flat_map(&elixir_files(Path.join(@platform_root, &1)))
    |> defined_modules()
    |> Kernel.++(loaded)
    |> Enum.flat_map(&String.split(&1, "."))
    |> MapSet.new()
  end

  defp compound?(segment), do: length(Regex.scan(~r/[A-Z]/, segment)) >= 2

  # Product names shown as text (see moduledoc); segment rule only.
  @product_names ~w(YouTube)

  defp owned_segments do
    core = core_segments()

    sibling_projects()
    |> Enum.flat_map(&elixir_files(Path.join(&1, "lib")))
    |> defined_modules()
    |> Enum.flat_map(&String.split(&1, "."))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(core, &1))
    |> Enum.reject(&(&1 in @product_names))
    |> Enum.filter(&compound?/1)
    |> Enum.sort()
  end

  @env_read ~r/(?:System\.get_env|System\.fetch_env!?|Map\.get\(\s*env\s*,|Map\.fetch!?\(\s*env\s*,)\(?\s*"([A-Z][A-Z0-9_]+)"/

  defp env_var_names do
    sibling_projects()
    |> Enum.flat_map(&elixir_files(Path.join(&1, "lib")))
    |> Enum.flat_map(&Regex.scan(@env_read, SourceIndex.read!(&1), capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp needles, do: needles(module_names(), owned_segments(), env_var_names())

  defp needles(names, segments, envs) do
    Enum.map(names, &{:module, &1}) ++
      Enum.map(segments, &{:segment, &1}) ++
      Enum.map(envs, &{:env_var, &1})
  end

  # A needle can only match a line that contains it as a plain substring, so
  # every needle is first folded into ONE `:binary` pattern: a file or line
  # that contains none of them is passed over in a single pass, and the
  # per-needle word-boundary regexes run only on the few lines that do. That
  # gives exactly the hits a regex per (needle x line) gives, without the
  # cost: one regex per needle per line of apps/platform took the test past
  # ExUnit's 60 s timeout four times in CI (task 01a13aac).
  defp compile(needles) do
    %{
      prefilter: needles |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> :binary.compile_pattern(),
      regexes:
        Enum.map(needles, fn {kind, text} -> {kind, text, ~r/\b#{Regex.escape(text)}\b/} end)
    }
  end

  defp mentions_any?(text, %{prefilter: prefilter}),
    do: :binary.match(text, prefilter) != :nomatch

  # ── Scan ─────────────────────────────────────────────────────────────

  defp scan_files(root) do
    root
    |> Path.join("**/*")
    |> SourceIndex.wildcard(match_dot: true)
    |> Enum.filter(&(File.regular?(&1) and Path.extname(&1) in @scan_exts))
    |> Enum.reject(&String.contains?(&1, "/node_modules/"))
  end

  defp scan_text(text, label, compiled) do
    if mentions_any?(text, compiled) do
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> mentions_any?(line, compiled) end)
      |> Enum.flat_map(fn {line, n} ->
        for {kind, needle, re} <- compiled.regexes,
            Regex.match?(re, line),
            do: "#{label}:#{n}: #{kind} #{needle}: #{String.trim(line)}"
      end)
    else
      []
    end
  end

  defp scan(roots, compiled) do
    for root <- roots,
        file <- scan_files(root),
        hit <- scan_text(SourceIndex.read!(file), rel(file), compiled),
        do: hit
  end

  defp rel(path), do: Path.relative_to(path, @apps_root)

  # ── Tests ────────────────────────────────────────────────────────────

  test "the derived name set is not empty and covers more than one namespace" do
    names = module_names()
    assert sibling_projects() != [], "no sibling Mix project under apps/: nothing to guard"
    assert length(names) >= 10, "only #{length(names)} module names derived: #{inspect(names)}"

    # A prefix is not the test: names sit under at least three different
    # top-level-plus-one namespaces (core, its web layer, mix tasks).
    tops = names |> Enum.map(&(&1 |> String.split(".") |> Enum.take(1))) |> Enum.uniq()
    assert length(tops) >= 3, "derived names span only #{inspect(tops)}"
    assert owned_segments() != []
    assert env_var_names() != []
  end

  test "apps/platform names no module a sibling project defines, in any file it ships or tests" do
    compiled = compile(needles())
    hits = scan(Enum.map(@scan_roots, &Path.join(@platform_root, &1)), compiled)

    assert hits == [],
           """
           apps/platform names a build-time module (ADR 0055: core never names a
           module; it reaches one only through Platform.Extensions):

             #{Enum.join(hits, "\n  ")}

           Route the reference through a Platform.Extension callback, or move
           the file into the module's own project. A test that needs the module
           belongs in that project's test/.
           """
  end

  test "POSITIVE CONTROL: the scan hits a sibling project's own lib" do
    compiled = compile(needles())

    for project <- sibling_projects(), File.dir?(Path.join(project, "lib")) do
      hits = scan([Path.join(project, "lib")], compiled)
      assert length(hits) > 10, "#{rel(project)}/lib scanned with #{length(hits)} hits"
    end
  end

  test "a product-name exemption never hides a full module name" do
    compiled = compile(needles())

    exempted =
      for word <- @product_names,
          name <- module_names(),
          word in String.split(name, "."),
          do: name

    # Non-vacuous: an exemption no sibling module needs is stale; drop it.
    assert exempted != [], "no sibling module carries #{inspect(@product_names)}"

    for name <- exempted do
      assert scan_text("#{name}.fetch(1)", "plant", compiled) != [],
             "the exemption hid the module #{name}"
    end
  end

  test "POSITIVE CONTROL: every planted shape is caught, built from the derived set" do
    # Reuse this test's derivation for the scanner and plants. In particular,
    # owned_segments/0 parses every core declaration; deriving it twice made
    # this positive control exceed its unchanged timeout under suite load.
    # Nothing is cached between tests or runs, so source mutations are re-read.
    names = module_names()
    segments = owned_segments()
    envs = env_var_names()
    compiled = compile(needles(names, segments, envs))
    # A lib module filed OUTSIDE the most common top namespace, so a prefix
    # match on that namespace could not see it.
    common = names |> Enum.map(&hd(String.split(&1, "."))) |> Enum.frequencies()
    {top, _} = Enum.max_by(common, &elem(&1, 1))
    [name | _] = Enum.reject(names, &String.starts_with?(&1, top <> "."))
    [segment | _] = segments
    [env | _] = envs
    parts = String.split(Enum.find(names, &String.contains?(&1, segment)), ".")

    plants = [
      "#{name}.whatever(1)",
      "alias #{name}, as: H",
      ~s(config :platform, :x, "Elixir.#{name}"),
      "Module.concat(#{Enum.join(Enum.map(parts, &inspect/1), ", ")})",
      ~s|System.get_env("#{env}")|,
      "import #{segment} from \"./x\""
    ]

    for plant <- plants do
      assert scan_text(plant, "plant", compiled) != [], "the scan missed: #{plant}"
    end

    assert scan_text("defmodule Platform.Chat do end", "clean", compiled) == []
  end

  test "literal prefilter preserves a module hit and the regex word boundary" do
    compiled = compile([{:module, "NimbusBridge"}])

    assert scan_text("alias NimbusBridge", "positive", compiled) ==
             ["positive:1: module NimbusBridge: alias NimbusBridge"]

    assert scan_text("alias PrefixNimbusBridgeSuffix", "negative", compiled) == []
  end
end
