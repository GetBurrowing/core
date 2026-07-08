defmodule Platform.Security.Scanners.CodeAudit.AstProbes do
  @moduledoc """
  AST-level probes for the code-audit scanner (task `019f3e8e-4406`
  stage 4, ADR-0043).

  Regex patterns can't reason about scope — a call to
  `Plug.Crypto.secure_compare/2` two module clauses away from a
  webhook action shouldn't be treated as covering that action. These
  probes traverse the parsed AST via `Code.string_to_quoted/1` and
  return `[finding]` maps the CodeAudit scanner promotes into
  `FindingFiler.file_finding/1` calls.

  ## Probe contract

  Every probe accepts `%{path: file_path, contents: raw_source, ast:
  parsed_ast}` and returns `{:ok, [%{line: integer, snippet:
  string}]}` — a list of matches with enough context for the
  filer to build a fingerprint + task body.
  """

  @doc """
  Find Phoenix controller actions matching `*_webhook/2` that never
  invoke `Plug.Crypto.secure_compare/2` in the same function body.

  Heuristic — not a proof. False negatives when the verification
  lives in a plug pipeline the AST-walker can't see; false positives
  when a controller genuinely uses a different verifier
  (`ExAws.Utils.hmac256/2` etc.). The task description leans this
  toward high-severity + operator-triage because the base-rate of a
  webhook without ANY signature check is a real deployment smell.
  """
  @spec controller_without_hmac_verify(map()) :: {:ok, [map()]}
  def controller_without_hmac_verify(%{contents: contents, ast: ast, path: path}) do
    findings =
      ast
      |> collect_def_clauses()
      |> Enum.filter(&webhook_action?/1)
      |> Enum.reject(&hmac_verified?/1)
      |> Enum.map(fn %{name: name, line: line} ->
        %{
          line: line,
          snippet: snippet_at(contents, line),
          extra: %{"action" => Atom.to_string(name), "path" => path}
        }
      end)

    {:ok, findings}
  rescue
    _ -> {:ok, []}
  end

  # A no-op probe used to keep the loader's function-exported check
  # honest when the rubric references a probe that hasn't shipped yet.
  # Scanner treats a `{:error, :probe_not_found}` return as a warn +
  # skip.
  @doc false
  def unknown_probe(_ctx), do: {:error, :probe_not_found}

  # ── internals ────────────────────────────────────────────────────────

  # Walk the top-level module and collect every `def name(...)` /
  # `defp name(...)` clause. Each entry captures the clause name +
  # source line + the ast body so `hmac_verified?/1` can peek.
  defp collect_def_clauses(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          {def_kw, meta, [{name, _, args}, [do: body]]} when def_kw in [:def, :defp] ->
            line = Keyword.get(meta, :line, 0)
            arity = if is_list(args), do: length(args), else: 0
            entry = %{name: name, arity: arity, line: line, body: body, def_kw: def_kw}
            {node, [entry | acc]}

          _ ->
            {node, acc}
        end
      end)

    Enum.reverse(acc)
  end

  # A Phoenix controller action for a webhook: publicly-visible `def`
  # (not `defp`), name ends in `_webhook`, arity 2 (conn, params).
  defp webhook_action?(%{def_kw: :def, name: name, arity: 2}) do
    name
    |> Atom.to_string()
    |> String.ends_with?("_webhook")
  end

  defp webhook_action?(_), do: false

  defp hmac_verified?(%{body: body}) do
    {_, hit?} =
      Macro.prewalk(body, false, fn node, acc ->
        {node, acc or verifier_call?(node)}
      end)

    hit?
  end

  # Any of the well-known HMAC-verification shapes.
  #   Plug.Crypto.secure_compare/2
  #   :crypto.hash/2  (a common one-shot verifier — heuristic accept)
  #   any *.verify_signature/1 helper
  #   ExAws.Utils.hmac/2 / hmac256/2
  defp verifier_call?({{:., _, [{:__aliases__, _, [:Plug, :Crypto]}, :secure_compare]}, _, _}),
    do: true

  defp verifier_call?({{:., _, [:crypto, :hash]}, _, _}), do: true
  defp verifier_call?({{:., _, [:crypto, :mac]}, _, _}), do: true

  defp verifier_call?({{:., _, [_mod, fun]}, _, _}) when is_atom(fun) do
    name = Atom.to_string(fun)
    String.contains?(name, "verify_signature") or String.contains?(name, "hmac")
  end

  defp verifier_call?({fun, _, _}) when is_atom(fun) do
    name = Atom.to_string(fun)
    String.contains?(name, "verify_signature")
  end

  defp verifier_call?(_), do: false

  # Pull the source line at `line` (± 2 lines of context) out of the
  # raw contents. Bounds-checked — a probe firing on a synthetic AST
  # without matching source lines returns an empty snippet.
  defp snippet_at(contents, line) when is_integer(line) and line > 0 do
    lines = String.split(contents, "\n")
    total = length(lines)
    start_line = max(line - 2, 1)
    end_line = min(line + 2, total)

    lines
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.with_index(start_line)
    |> Enum.map_join("\n", fn {text, l} -> "#{l}: #{text}" end)
  end

  defp snippet_at(_, _), do: ""
end
