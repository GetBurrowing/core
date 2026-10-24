defmodule Platform.Social.Extension do
  @moduledoc """
  Social's `Platform.Extension` implementation (ADR 0055), registered by
  config only in a with-Social build (`apps/social/config/config.exs` for the
  module's own runs, `apps/burrow_release/config/config.exs` for the
  with-modules image).

  Task 01a140a8 (Social 1/7) contributes the module's migrations; Social 4/7
  (task 01a140a9-4c70) adds the `social` MCP tool bundle, six tools with no
  publish and no approve tool (`Platform.Social.ToolDefinitions`); Social 2/7
  adds one HTTP route, the signed status webhook at
  `/api/ext/social/webhooks/:profile_id` (`Platform.Social.WebhookPlug`).
  Social 3/7 (task 01a140a9-31b0) adds the `social_post_card` canvas kind
  (the approval card, whose clicks `PlatformWeb.SocialCardComponent`
  handles), the `social_post_approval` inbox kind, and `assets/0` so a
  with-modules build's Tailwind scans the card's classes. Social 7/7 adds
  the Social rail item and the `/m/social` live page
  (`PlatformWeb.SocialLive`). Every other registry is empty on purpose: no
  runtime-channel event, LiveView hook (the card's LiveComponent needs
  none) or experiment metric. Composer 1/5 (task 01a14aca) adds the
  `social.composer.adaptation` experiment surface.
  """

  @behaviour Platform.Extension

  @impl true
  def canvas_kinds, do: [Platform.Social.CanvasKinds.SocialPostCard]

  @deny_publish_or_approve "There is no publish or approve tool: a human approves in Burrow and the platform publishes."

  # Grantable, NOT a default grant (like Play): an admin grants `social` per
  # runtime in its tool profile. Every `social_*` name is Social's, listed
  # or not, so an invented one gets Social's answer, not core's.
  @impl true
  def mcp_tool_bundles do
    [
      %{
        name: "social",
        definitions: Platform.Social.ToolDefinitions.definitions(),
        tool_names: Platform.Social.ToolDefinitions.names(),
        execute: &Platform.Social.Tools.execute/3,
        deny_message: &deny_message/1,
        owns_tool?: &String.starts_with?(&1, "social_")
      }
    ]
  end

  @impl true
  def permissions do
    [
      %{
        module: "social",
        permissions: ["social.use"],
        rail: [%{key: :social, permission: "social.use"}],
        bundles: %{"social" => "social.use"}
      }
    ]
  end

  @doc false
  # The denial text for an unlisted `social_*` name that asks to publish or
  # approve; `nil` (core's wording) for anything else.
  def deny_message(name) when is_binary(name) do
    if name not in Platform.Social.ToolDefinitions.names() and
         (String.contains?(name, "publish") or String.contains?(name, "approve")),
       do: @deny_publish_or_approve
  end

  def deny_message(_), do: nil

  @impl true
  def runtime_channel_events, do: []

  # Owns no event, so core never routes one here; answered anyway, without
  # raising, as the behaviour requires.
  @impl true
  def handle_runtime_event(_event, _runtime_id, _payload), do: {:error, :unknown_event}

  @impl true
  def runtime_disconnected(_runtime_id), do: :ok

  @impl true
  def live_hooks, do: []

  @impl true
  # Composer 1/5 (task 01a14aca): the per-platform adaptation prompt and
  # model. Core's own `@surfaces` list is untouched; `Surfaces.list/0`
  # merges this in.
  def experiment_surfaces, do: [Platform.Social.Composer.AdaptationSurface]

  @impl true
  def experiment_metrics, do: %{}

  # Resolved through the code server, so it is this app's priv in a Mix build
  # and in a release alike (Play's pattern).
  @impl true
  def migrations_path, do: Application.app_dir(:social, "priv/repo/migrations")

  # Build time only (a release host's `mix platform.extensions.assets`): the
  # cover picker's `CoverPicker` hook (task 01a165ec stage 4, Play's
  # pattern), and the templates and hook for Tailwind to scan. No
  # stylesheet.
  @assets_root Path.expand("../../../assets", __DIR__)
  @lib_root Path.expand("../..", __DIR__)

  @impl true
  def assets do
    %{
      js_hooks: Path.join(@assets_root, "js/extension.js"),
      tailwind_sources: [@lib_root, Path.join(@assets_root, "js")]
    }
  end

  # Social 7/7: the Social screen's rail destination
  # (`0055-extension-contract-and-build-time-modules.md § 5. Rail items: which are core and which are module`).
  # A :working item, so on mobile it lands in the More sheet (the bottom bar
  # is core's four primary tiles).
  @impl true
  def rail_items do
    [
      %{
        key: :social,
        label: "Social",
        path: "/m/social",
        hero_icon: "hero-megaphone",
        cluster: :working,
        root_only?: false
      }
    ]
  end

  # Social 7/7: the Social screen, nested by core's generic `/m/<prefix>`
  # page. Core hands it only the user id; `PlatformWeb.SocialLive`
  # re-reads the user and authorizes everything itself.
  @impl true
  def live_pages do
    [
      %{
        prefix: "social",
        live_view: PlatformWeb.SocialLive,
        title: "Social",
        module: :social,
        permission: "social.use"
      }
    ]
  end

  # The vendor's status webhook (Social 2/7), behind core's generic
  # `/api/ext/<prefix>` seam. Core gives it no session and no auth: the
  # plug's signature check is its only authentication.
  @impl true
  def routes, do: [%{prefix: "social", plug: Platform.Social.WebhookPlug, opts: []}]

  # Social 3/7: one inbox row per approver when a post needs approval. A
  # POINTER (it deep-links to the approval card; the decision is on the
  # card), kept listed on open until the post is decided. Core never pushes
  # it, never shows it to an external user, and never lists it as a mobile
  # approval.
  @impl true
  def inbox_kinds do
    [
      %{
        kind: "social_post_approval",
        source_type: "social_post",
        label: "Post needs approval",
        icon: "hero-megaphone",
        stays_listed_on_open: true
      },
      # Social authoring 9/11: one row per approver when an account
      # disconnects (once per disconnect, `Platform.Social.Health`). It links
      # to Connections; opening it acknowledges it.
      %{
        kind: "social_account_disconnected",
        source_type: "social_account",
        label: "Social account disconnected",
        icon: "hero-link-slash",
        stays_listed_on_open: false
      }
    ]
  end
end
