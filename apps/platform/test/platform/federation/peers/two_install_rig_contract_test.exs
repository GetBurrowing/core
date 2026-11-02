defmodule Platform.Federation.Peers.TwoInstallRigContractTest do
  @moduledoc """
  The two-install federation rig (task 01a199b2, ADR 0054;
  `scripts/federation-two-install-rig.sh`) drives each install by evaluating
  `scripts/federation_rig/*.exs` on its running node. Those files are never
  compiled, so a renamed or re-aritied `Platform.*` function they call would
  only surface as an `UndefinedFunctionError` halfway through a rig run on
  moon.

  This test parses every one of them with `Code.string_to_quoted/1`, collects
  each remote call on a `Platform.*` / `PlatformWeb.*` module (plain calls,
  pipes, `&Mod.fun/n` captures, through `alias`), and asserts the function or
  macro is exported at that arity. The fixture cases are the positive
  controls: a call to `Platform.Federation.Peers.nope/0` must be reported, so
  a checker that stopped checking fails here rather than passing everything.
  """

  use ExUnit.Case, async: true

  @rig_dir Path.expand("../../../../../../scripts/federation_rig", __DIR__)

  describe "scripts/federation_rig/*.exs" do
    test "the directory exists and holds rig scripts" do
      assert File.dir?(@rig_dir), "#{@rig_dir} is missing"
      assert rig_files() != [], "no .exs files under #{@rig_dir}"
    end

    test "every Platform.* call in every rig script is exported at its arity" do
      for path <- rig_files() do
        source = File.read!(path)
        calls = platform_calls(source)
        assert calls != [], "#{Path.basename(path)} calls no Platform.* function"

        assert missing(calls) == [],
               "#{Path.basename(path)} calls functions that do not exist: " <>
                 inspect(missing(calls))
      end
    end

    test "identity.exs drives InstallIdentity.ensure!/0" do
      calls = @rig_dir |> Path.join("identity.exs") |> File.read!() |> platform_calls()
      assert {Platform.Federation.Peers.InstallIdentity, :ensure!, 0} in calls
    end
  end

  describe "the checker (positive and negative controls)" do
    test "reports a call to a function that does not exist" do
      assert missing(platform_calls("Platform.Federation.Peers.nope()")) ==
               [{Platform.Federation.Peers, :nope, 0}]
    end

    test "reports a real function called at the wrong arity" do
      assert missing(platform_calls("Platform.Federation.Peers.InstallIdentity.ensure!(:x)")) ==
               [{Platform.Federation.Peers.InstallIdentity, :ensure!, 1}]
    end

    test "reports a missing function reached through an alias" do
      source = """
      alias Platform.Federation.Peers
      alias Platform.Federation.Peers.{Config, InstallIdentity}
      alias Platform.Federation.Peers.InstallIdentity, as: Ident
      Peers.nope()
      Config.enabled?()
      InstallIdentity.ensure!()
      Ident.missing_too(1, 2)
      """

      assert Enum.sort(missing(platform_calls(source))) ==
               Enum.sort([
                 {Platform.Federation.Peers, :nope, 0},
                 {Platform.Federation.Peers.InstallIdentity, :missing_too, 2}
               ])
    end

    test "counts the piped argument and reads captures" do
      source = """
      "x" |> Platform.Federation.Peers.InstallIdentity.sign()
      f = &Platform.Federation.Peers.nope/3
      """

      assert {Platform.Federation.Peers.InstallIdentity, :sign, 1} in platform_calls(source)
      assert missing(platform_calls(source)) == [{Platform.Federation.Peers, :nope, 3}]
    end

    test "passes real calls and ignores non-Platform modules" do
      source = """
      Platform.Federation.Peers.Config.base_url()
      Jason.encode!(%{})
      DateTime.utc_now()
      """

      assert platform_calls(source) == [{Platform.Federation.Peers.Config, :base_url, 0}]
      assert missing(platform_calls(source)) == []
    end
  end

  defp rig_files, do: @rig_dir |> Path.join("*.exs") |> Path.wildcard() |> Enum.sort()

  defp missing(calls) do
    Enum.reject(calls, fn {mod, fun, arity} ->
      Code.ensure_loaded?(mod) and
        (function_exported?(mod, fun, arity) or macro_exported?(mod, fun, arity))
    end)
  end

  defp platform_calls(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, {_aliases, calls}} = Macro.prewalk(ast, {%{}, []}, &collect/2)

    calls |> Enum.reverse() |> Enum.uniq()
  end

  # `alias A.B.C` / `alias A.B.C, as: X`
  defp collect({:alias, _, [{:__aliases__, _, parts} | opts]}, {aliases, calls}) do
    full = expand(parts, aliases)

    short =
      case opts do
        [[as: {:__aliases__, _, [as]}]] -> as
        _ -> List.last(parts)
      end

    {nil, {Map.put(aliases, short, full), calls}}
  end

  # `alias A.B.{C, D}`
  defp collect(
         {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]},
         {aliases, calls}
       ) do
    prefix = expand(base, aliases)

    aliases =
      Enum.reduce(children, aliases, fn {:__aliases__, _, parts}, acc ->
        Map.put(acc, List.last(parts), prefix ++ parts)
      end)

    {nil, {aliases, calls}}
  end

  # `&Mod.fun/n`
  defp collect(
         {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, fun]}, _, []}, arity]}]},
         acc
       )
       when is_atom(fun) and is_integer(arity) do
    {nil, record(acc, parts, fun, arity)}
  end

  # `lhs |> Mod.fun(args)`: the pipe supplies the first argument.
  defp collect(
         {:|>, meta, [lhs, {{:., _, [{:__aliases__, _, parts}, fun]}, _, args}]},
         acc
       )
       when is_atom(fun) and is_list(args) do
    {{:|>, meta, [lhs, args]}, record(acc, parts, fun, length(args) + 1)}
  end

  defp collect({{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node, acc)
       when is_atom(fun) and is_list(args) do
    {node, record(acc, parts, fun, length(args))}
  end

  defp collect(node, acc), do: {node, acc}

  defp record({aliases, calls}, parts, fun, arity) do
    full = expand(parts, aliases)

    case full do
      [root | _] when root in [:Platform, :PlatformWeb] ->
        {aliases, [{Module.concat(full), fun, arity} | calls]}

      _ ->
        {aliases, calls}
    end
  end

  defp expand([head | rest], aliases) do
    case Map.fetch(aliases, head) do
      {:ok, full} -> full ++ rest
      :error -> [head | rest]
    end
  end
end
