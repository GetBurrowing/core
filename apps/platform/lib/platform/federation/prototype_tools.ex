defmodule Platform.Federation.PrototypeTools do
  @moduledoc """
  Definitions of the `prototype` bundle's agent tools (task 01a1316b-4e46
  stage 1, ADR 0057). Mirrors `Platform.Federation.ExperimentTools`: the
  definitions live here, the behaviour in `Platform.Prototypes.Tools`, and
  `Platform.Federation.ToolSurface` carries only the bundle entry, one
  `tools_for_bundle/1` clause and one prefix `execute/3` clause.

  `prototype` is grantable and NOT a default bundle
  (`Platform.Agents.AgentRuntime`). Publishing is additionally gated per
  install by `Platform.Prototypes.Settings` (off by default).

  Only `name`, `description` and the input schema reach `/mcp`, so the
  sandbox boundary is stated in `description`.
  """

  @boundary "Bundles are served at /proto/<id>/<version>/ on this install, only to members of the prototype's org (anyone else gets 404), inside a sandbox: no allow-same-origin, so the document has an opaque origin and cannot read Suite cookies, the Suite page or the Suite API; connect-src 'none' (no fetch/XHR/WebSocket); form-action 'none'; scripts, styles, images and fonts load only from the bundle's own files (plus inline and data:). Script can still navigate its own frame to an outside URL, so this is not exfiltration-proof. Viewers get a short-lived grant URL that works as a bearer link to that one version."

  @doc "The tool definitions, in the ToolSurface rubric shape."
  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "prototype_publish",
        description:
          "Publish a multi-file clickable prototype (HTML/JS/CSS/images) as a new immutable version. Omit prototype_id to create a prototype; pass it to add version N+1 (older versions keep serving). " <>
            @boundary,
        parameters: %{
          org_id: %{
            type: "string",
            required: false,
            description:
              "Org whose members may open it. Required when creating unless space_id is given (then the space's org is used)."
          },
          space_id: %{
            type: "string",
            required: false,
            description:
              "Space the prototype belongs to (you must be a participant). Its org is used when org_id is omitted."
          },
          prototype_id: %{
            type: "string",
            required: false,
            description: "Existing prototype to add a version to. Omit to create a new one."
          },
          name: %{
            type: "string",
            required: false,
            description: "Display name. Required when creating."
          },
          zip_attachment_id: %{
            type: "string",
            required: false,
            description:
              "A zip uploaded with attachment_upload_start (or upload_inline) in a space you are in. Use this for anything large. Exactly one of zip_attachment_id or files."
          },
          files: %{
            type: "object",
            required: false,
            description:
              "Map of relative path => {content: text} or {content_base64: base64}, e.g. {\"index.html\": {\"content\": \"<script src=./app.js></script>\"}, \"app.js\": {\"content\": \"...\"}}."
          },
          entry_path: %{
            type: "string",
            required: false,
            description: "File opened at the version root. Default index.html."
          }
        },
        returns:
          "%{prototype_id, version, url, latest_url, entry_path, file_count, total_bytes} — url is /proto/<id>/<version>/ (relative to this install), latest_url is /proto/<id>/latest/.",
        limitations:
          "Refused with a code and nothing written when: publishing is off for the install (prototypes_disabled), the install policy does not admit you (publish_not_allowed), more files than the cap (too_many_files), uncompressed size over the cap including a zip whose real size exceeds what it declares (bundle_too_large), a path that is absolute, has ../ or ./ segments, a backslash, NUL, ':', '?' or '#' (invalid_path), a symlink zip entry (symlink_entry), ZIP64/encrypted/non-deflate zips (unsupported_zip), or no index.html/entry_path (missing_entry). A tenant agent may only publish into its own org.",
        when_to_use:
          "To share a clickable prototype with an org inside Suite instead of on a public tunnel."
      },
      %{
        name: "prototype_versions",
        description:
          "List a prototype's versions, newest first, with which one latest points at and which were removed by retention.",
        parameters: %{
          prototype_id: %{type: "string", required: true, description: "Prototype UUID."}
        },
        returns:
          "%{prototype_id, name, org_id, latest_version, versions: [%{version, url, entry_path, file_count, total_bytes, published_by, inserted_at, removed_at}], total, has_more} — every version is returned; has_more is always false.",
        limitations:
          "not_found for an unknown id and for a prototype outside your org scope (existence is not disclosed).",
        when_to_use: "Before prototype_rollback, or to find a version's URL."
      },
      %{
        name: "prototype_rollback",
        description:
          "Point a prototype's latest at an earlier version. Nothing is copied; /proto/<id>/latest/ then redirects to that version. Same install policy as publishing.",
        parameters: %{
          prototype_id: %{type: "string", required: true, description: "Prototype UUID."},
          version: %{
            type: "integer",
            required: true,
            description: "Version number to make latest."
          }
        },
        returns: "%{prototype_id, latest_version, url}",
        limitations:
          "Refused for a removed (retention) or unknown version, when publishing is off, or when the install policy does not admit you.",
        when_to_use:
          "When a newer version is broken and the previous one should be what people open."
      }
    ]
  end
end
