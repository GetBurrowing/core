defmodule Platform.Chat.Canvas.ScriptedEmbeds do
  @moduledoc """
  Stamps every `embed` node of a canvas document with the prototype version
  its HTML runs as (task 01a1316b-677a; ADR 0057).

  An `embed` with `scripts: true` does not render its `srcdoc` inline. Its
  HTML is published as a single-file prototype owned by (canvas, node)
  through `Platform.Prototypes.publish_embed/1`, and the node carries the
  server-set prop

      "prototype_ref" => %{"prototype_id" => id, "version" => n, "sha256" => hex}

  which `Platform.Chat.Canvas.Kinds.Embed.render/1` frames from the sealed
  `/proto/<id>/<n>/` route, exactly as the `prototype` kind does. Stamping at
  WRITE time rather than looking the version up at render keeps render pure
  (no query per node per patch), keeps every canvas version and
  `canvas.restore` pointing at the HTML that was live then, and costs viewers
  nothing.

  ## The rule, per embed node

    * `scripts: true` — compute sha256(srcdoc). If the node's ref is the one
      this canvas server already verified for that node and sha (the
      `:verified` cache), nothing happens. Otherwise `publish_embed/1`
      answers with the real ref (reusing a version with that sha, or
      publishing N+1) and it REPLACES whatever ref the node carried, so a
      ref sent by a client is never trusted.
    * anything else — any `prototype_ref` is DELETED, so a forged ref on a
      plain embed is inert.

  ## Where it runs

  Every document write: `Platform.Chat.Canvas.Server`'s `apply_patches`
  success arm (which `canvas.patch`, `canvas.restore`, the LiveView and
  `Chat.patch_canvas/3` all reach), and `Platform.Chat`'s
  `create_canvas`, `create_canvas_with_message` and `update_canvas` (when the
  document changes).

  ## Authorization and settings

  `who_may_publish` is NOT applied: the canvas write that carries the HTML
  was already authorized by `Platform.Chat.CanvasAccess` (space membership),
  and that is the authorization for its embed. `Settings.enabled` is applied
  by `publish_embed/1`, and only to a write that needs a NEW version:
  refused as `prototypes_disabled`. A write that leaves every scripted
  node's HTML alone still succeeds while prototypes are off. A space with no
  org cannot own a prototype: `scripted_embed_requires_org`.
  """

  alias Platform.Chat
  alias Platform.Prototypes

  @type ref :: %{required(String.t()) => term()}
  @type verified :: %{optional(String.t()) => {String.t(), ref()}}
  @type error :: %{code: String.t(), message: String.t()}

  @doc """
  Stamp `document`. `ctx`: `:canvas_id`, `:space_id`, `:actor` (an
  attribution map) and optionally `:verified` (the cache the canvas server
  keeps: `%{node_id => {sha, ref}}`).

  Returns `{:ok, document, verified}`, where `verified` holds exactly the
  scripted nodes of the returned document, or `{:error, %{code, message}}`.
  """
  @spec stamp(map(), map()) :: {:ok, map(), verified()} | {:error, error()}
  def stamp(%{"root" => root} = document, ctx) when is_map(root) do
    acc = %{ctx: ctx, cached: Map.get(ctx, :verified) || %{}, verified: %{}, org: :unresolved}

    case stamp_node(root, acc) do
      {:ok, root, acc} -> {:ok, Map.put(document, "root", root), acc.verified}
      {:error, _} = error -> error
    end
  end

  def stamp(document, _ctx), do: {:ok, document, %{}}

  @doc "Does `document` hold any `scripts: true` embed? Cheap, no queries."
  @spec scripted?(term()) :: boolean()
  def scripted?(%{"root" => root}), do: scripted_node?(root)
  def scripted?(_), do: false

  defp scripted_node?(%{"type" => "embed", "props" => %{"scripts" => true}}), do: true

  defp scripted_node?(%{"children" => children}) when is_list(children),
    do: Enum.any?(children, &scripted_node?/1)

  defp scripted_node?(_), do: false

  defp stamp_node(%{} = node, acc) do
    with {:ok, node, acc} <- stamp_self(node, acc) do
      stamp_children(node, acc)
    end
  end

  defp stamp_node(other, acc), do: {:ok, other, acc}

  defp stamp_children(%{"children" => children} = node, acc) when is_list(children) do
    children
    |> Enum.reduce_while({:ok, [], acc}, fn child, {:ok, done, acc} ->
      case stamp_node(child, acc) do
        {:ok, child, acc} -> {:cont, {:ok, [child | done], acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, done, acc} -> {:ok, Map.put(node, "children", Enum.reverse(done)), acc}
      {:error, _} = error -> error
    end
  end

  defp stamp_children(node, acc), do: {:ok, node, acc}

  defp stamp_self(
         %{"type" => "embed", "id" => node_id, "props" => %{"scripts" => true} = props} = node,
         acc
       )
       when is_binary(node_id) do
    html = if is_binary(props["srcdoc"]), do: props["srcdoc"], else: ""
    sha = Prototypes.sha256_hex(html)

    case Map.get(acc.cached, node_id) do
      {^sha, ref} ->
        # Verified earlier by this server for this node and this HTML: the
        # one correct ref is known, whatever the node now carries.
        {:ok, put_ref(node, props, ref), remember(acc, node_id, sha, ref)}

      _ ->
        with {:ok, org_id, acc} <- org_id(acc),
             {:ok, ref} <- publish(acc.ctx, org_id, node_id, html) do
          {:ok, put_ref(node, props, ref), remember(acc, node_id, sha, ref)}
        end
    end
  end

  defp stamp_self(%{"type" => "embed", "props" => %{"prototype_ref" => _} = props} = node, acc),
    do: {:ok, Map.put(node, "props", Map.delete(props, "prototype_ref")), acc}

  defp stamp_self(node, acc), do: {:ok, node, acc}

  defp put_ref(node, props, ref), do: Map.put(node, "props", Map.put(props, "prototype_ref", ref))

  defp remember(acc, node_id, sha, ref),
    do: %{acc | verified: Map.put(acc.verified, node_id, {sha, ref})}

  defp publish(ctx, org_id, node_id, html) do
    case Prototypes.publish_embed(%{
           org_id: org_id,
           space_id: ctx.space_id,
           canvas_id: ctx.canvas_id,
           node_id: node_id,
           html: html,
           actor: Map.get(ctx, :actor) || %{}
         }) do
      {:ok, ref} -> {:ok, ref}
      {:error, {code, message}} -> {:error, %{code: Atom.to_string(code), message: message}}
    end
  end

  # The space's org, read once per stamp and only when a publish is needed.
  defp org_id(%{org: :unresolved, ctx: ctx} = acc) do
    org =
      case Chat.get_space(ctx.space_id) do
        %{org_id: org_id} when is_binary(org_id) -> org_id
        _ -> nil
      end

    org_id(%{acc | org: org})
  end

  defp org_id(%{org: nil}),
    do:
      {:error,
       %{
         code: "scripted_embed_requires_org",
         message:
           "a scripts: true embed needs a space that belongs to an org; " <>
             "drop `scripts` or create the canvas in an org space"
       }}

  defp org_id(%{org: org_id} = acc), do: {:ok, org_id, acc}
end
