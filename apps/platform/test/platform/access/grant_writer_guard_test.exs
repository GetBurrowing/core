defmodule Platform.Access.GrantWriterGuardTest do
  @moduledoc """
  Task 01a1386e-30bd stage 1: `Platform.Access.Changes.commit/4` is the one
  writer to `access_grants`, so every grant change has its ledger row.

  Two scans over `apps/platform/lib`, each with a positive control proving it
  can fire:

    * **No arity-1 grant write outside `lib/platform/access/` and
      `lib/platform/org/wiki/nodes.ex`.** `Grants.grant/1`, `deny/1` and
      `revoke/1` act as `Scope.system/0`; product code must name its actor
      with the arity-2 forms. The scan reads the AST, so a piped call
      (`attrs |> Grants.grant()`) counts with its piped argument.
    * **No module outside `lib/platform/access/` names the `access_grants`
      table** (a raw SQL writer would bypass the ledger). `vault_access_grants`
      is a different table and does not match.
  """

  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  @allowed_arity1 ["platform/access/", "platform/org/wiki/nodes.ex"]
  @writes [:grant, :deny, :revoke]

  defp lib_files do
    Path.wildcard(Path.join(@lib, "**/*.ex"))
    |> Enum.map(&{Path.relative_to(&1, @lib), File.read!(&1)})
  end

  # Every `Grants.<write>(…)` / `Platform.Access.Grants.<write>(…)` call in
  # `source`, as `{fun, arity}`. A piped call counts its piped argument; the
  # pipe's right-hand side is replaced after recording so the same call is
  # not read a second time without it.
  defp grant_writes(source) do
    ast = Code.string_to_quoted!(source, columns: true)

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:|>, meta, [lhs, {{:., _, [aliases, fun]}, _, args}]} = node, acc ->
          if grants_alias?(aliases) and fun in @writes,
            do: {{:|>, meta, [lhs, nil]}, [{fun, length(args) + 1} | acc]},
            else: {node, acc}

        {{:., _, [aliases, fun]}, _, args} = node, acc when is_list(args) ->
          if grants_alias?(aliases) and fun in @writes,
            do: {node, [{fun, length(args)} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp arity1_writes(source), do: Enum.filter(grant_writes(source), &match?({_, 1}, &1))

  defp grants_alias?({:__aliases__, _, parts}),
    do: parts in [[:Grants], [:Platform, :Access, :Grants], [:Access, :Grants]]

  defp grants_alias?(_), do: false

  defp allowed?(rel), do: Enum.any?(@allowed_arity1, &String.starts_with?(rel, &1))

  test "positive control: the scanner sees direct and piped arity-1 writes, not arity-2" do
    source = """
    defmodule Probe do
      alias Platform.Access.Grants
      def a(x), do: Grants.grant(x)
      def b(x), do: x |> Grants.deny()
      def c(x), do: Platform.Access.Grants.revoke(x)
      def d(x, s), do: Grants.grant(x, actor: s)
      def e(x, s), do: x |> Grants.revoke(actor: s)
    end
    """

    assert Enum.sort(arity1_writes(source)) == [deny: 1, grant: 1, revoke: 1]
  end

  test "no arity-1 grant write outside lib/platform/access/ and nodes.ex" do
    offenders =
      for {rel, source} <- lib_files(),
          not allowed?(rel),
          writes = arity1_writes(source),
          writes != [],
          do: {rel, writes}

    assert offenders == [],
           "these modules call an arity-1 Platform.Access.Grants write, which acts as " <>
             "Scope.system/0; pass `actor:` to grant/2, deny/2 or revoke/2: #{inspect(offenders)}"
  end

  test "positive control: the table-name scan matches access_grants and not vault_access_grants" do
    assert table_ref?(~s|Repo.query!("DELETE FROM access_grants WHERE id = $1")|)
    assert table_ref?(~s|schema "access_grants" do|)
    refute table_ref?(~s|schema "vault_access_grants" do|)
    refute table_ref?(~s|create table(:access_grant_changes)|)
  end

  test "no module outside lib/platform/access/ names the access_grants table" do
    offenders =
      for {rel, source} <- lib_files(),
          not String.starts_with?(rel, "platform/access/"),
          table_ref?(source),
          do: rel

    assert offenders == [],
           "these modules name the access_grants table outside Platform.Access, " <>
             "bypassing the ledger writer Platform.Access.Changes.commit/4: #{inspect(offenders)}"
  end

  defp table_ref?(source), do: Regex.match?(~r/(?<![a-z_])access_grants(?![a-z_])/, source)
end
