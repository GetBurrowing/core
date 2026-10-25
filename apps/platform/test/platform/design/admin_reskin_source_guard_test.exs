defmodule Platform.Design.AdminReskinSourceGuardTest do
  @moduledoc """
  Source guard for the admin re-skin (Burrow redesign 24, task 01a1557a-fe9b
  stage 4; stage 5 widens `@files` to the admin sub-pages).

  Over every file in `@files` it refuses:

    * a bare `hover:` (hover is only `lg:hover:`, so touch never sticks);
    * any text colour other than `text-base-content` and `text-subtle`;
    * opacity on text (`opacity-N`, `group-hover:opacity-…`, or a
      `text-<slot>/N` alpha);
    * a hex literal.

  It also refuses a daisyUI variant that paints hue as text (badge soft,
  outline or dash; link-<hue>; a soft/outline/ghost hued btn).

  Each file is first shown to be the surface it claims to be and to paint the
  permitted slots, so a moved or emptied file fails rather than passing
  vacuously. AdminBrandingLive's App colours preview, between the
  `reskin-guard:preview-begin`/`-end` markers, is the one exempt region: it
  paints the draft palette's own slots by design.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  # {relative path, a marker only that surface carries, whether the surface
  # has a hover at all}. A surface with no hover is still scanned for one;
  # the flag only decides whether `lg:hover:` must be present for the hover
  # check to be non-vacuous on that file.
  @files [
    {"lib/platform_web/live/admin_live.html.heex", ~s(data-admin-card="themes"), true},
    {"lib/platform_web/live/admin_branding_live.html.heex", ~s(data-role="admin-branding"), true},
    {"lib/platform_web/live/admin_orgs_live.html.heex", ~s(data-role="create-org-form"), false},
    {"lib/platform_web/live/admin_federation_live.html.heex", ~s(id="prune-dead-letters"), true},
    {"lib/platform_web/live/admin_prompts_live.html.heex", ~s(data-role="declared-missing-row"),
     true},
    {"lib/platform_web/live/admin_vault_live.html.heex", ~s(data-role="admin-vault"), true},
    {"lib/platform_web/live/admin_vault_live.ex", ~s(data-role="vault-agent-option"), true},
    {"lib/platform_web/live/admin_sign_in_users_live.html.heex",
     ~s(data-role="admin-sign-in-users"), true},
    {"lib/platform_web/live/recovery_live.ex", ~s(data-role="recovery-row"), true},
    {"lib/platform_web/live/recovery_live.html.heex", ~s(data-role="recovery-toast"), true},
    {"lib/platform_web/live/user_access_live.html.heex", ~s(data-role="toggle-show-archived"),
     false},
    {"lib/platform_web/live/external_recovery_live.ex", ~s(data-role="channel-picker"), true},
    {"lib/platform_web/live/external_recovery_live.html.heex", ~s(data-role="org-ambiguous"),
     false},
    {"lib/platform_web/live/access_live.html.heex", ~s(id="access-panel"), false},
    {"lib/platform_web/live/admin_insights_live.ex", ~s(id="admin-insights-form"), false},
    {"lib/platform_web/live/admin_prototypes_live.ex", ~s(id="admin-prototypes-form"), false}
  ]

  # The one exempt region: AdminBrandingLive's App colours preview paints the
  # DRAFT palette's own slots inside data-theme-preview. It is cut out between
  # these markers before scanning, and only in that file.
  @exempt_file "lib/platform_web/live/admin_branding_live.html.heex"
  @exempt ~r/<%!-- reskin-guard:preview-begin.*?reskin-guard:preview-end --%>/s

  # A daisyUI variant that paints hue AS TEXT on a base ground (soft, outline,
  # link, text-hued ghost). Solid fills paint X-content on X, which
  # Platform.Theming.ContrastPairs floors, and are not text colour.
  @hued ~w(primary secondary accent info success warning error neutral)

  # `text-*` utilities that are not colours.
  @non_colour ~w(xs sm base lg xl 2xl 3xl 4xl 5xl 6xl 7xl 8xl 9xl left center right
                 justify start end wrap nowrap balance pretty ellipsis clip)

  @allowed_text ["base-content", "subtle"]

  defp sources do
    for {rel, marker, _hover?} <- @files do
      source = File.read!(Path.join(@root, rel))
      source = if rel == @exempt_file, do: Regex.replace(@exempt, source, ""), else: source
      {rel, marker, source}
    end
  end

  defp text_colours(source) do
    Regex.scan(
      ~r/(?<![\w:\/-])(?:[a-z0-9-]+:)*text-(\[[^\]]*\]|[a-z][a-z0-9-]*(?:\/\d+)?)/,
      source
    )
    |> Enum.map(fn [_, slot] -> slot end)
    |> Enum.reject(&(&1 in @non_colour or String.starts_with?(&1, "[length:")))
    # A bracketed size like text-[15px] is not a colour.
    |> Enum.reject(&Regex.match?(~r/^\[\d+(\.\d+)?(px|rem|em)\]$/, &1))
  end

  test "anti-vacuity: each file is its surface and paints the permitted slots" do
    assert length(@files) == 16
    hover? = Map.new(@files, fn {rel, _, h} -> {rel, h} end)

    for {rel, marker, source} <- sources() do
      assert source =~ marker, "#{rel} no longer carries #{marker}; update @files"

      if hover?[rel] do
        assert source =~ "lg:hover:", "#{rel} has no lg:hover:; the hover check would be vacuous"
      end

      colours = text_colours(source)
      assert "base-content" in colours, rel
      assert "subtle" in colours, rel
    end
  end

  test "anti-vacuity: the exempt region is exactly the branding preview" do
    raw = File.read!(Path.join(@root, @exempt_file))
    [region] = Regex.scan(@exempt, raw) |> List.flatten()
    assert region =~ "data-theme-preview", "the exempt region no longer wraps the preview"
    assert region =~ "text-primary-content", "the preview no longer paints the draft's slots"
    # Nothing but the preview: the region holds no form control or error.
    refute region =~ ~r/data-role="color-(input|save)-error"/

    for {rel, _, _} <- @files, rel != @exempt_file do
      refute File.read!(Path.join(@root, rel)) =~ "reskin-guard:preview-begin", rel
    end
  end

  defp hued_variants(source) do
    for hue <- @hued,
        pat <- [
          ~r/\bbadge-#{hue}\b[^"]*\bbadge-(soft|outline|dash)\b/,
          ~r/\bbadge-(soft|outline|dash)\b[^"]*\bbadge-#{hue}\b/,
          ~r/\b(link|btn-link)-#{hue}\b/,
          ~r/\bbtn-#{hue}\b[^"]*\bbtn-(soft|outline|dash|ghost)\b/,
          ~r/\bbtn-(soft|outline|dash|ghost)\b[^"]*\bbtn-#{hue}\b/
        ],
        Regex.match?(pat, source),
        uniq: true,
        do: hue
  end

  test "no hued daisyUI text variant (soft, outline, link)" do
    for {rel, _, source} <- sources() do
      found = hued_variants(source)
      assert found == [], "#{rel}: hued text variant for #{inspect(found)}"
    end
  end

  test "the hued-variant scan sees one (positive control)" do
    assert hued_variants(~s(class="badge badge-info badge-soft")) == ["info"]
    assert hued_variants(~s(class="btn btn-outline btn-error btn-sm")) == ["error"]
    assert hued_variants(~s(class="link link-primary")) == ["primary"]
    assert hued_variants(~s(class="btn btn-primary btn-sm")) == []
    assert hued_variants(~s(class="badge badge-ghost border-info")) == []
  end

  test "the text-colour scan sees a forbidden slot (positive control)" do
    assert text_colours(~s(class="text-sm text-primary")) == ["primary"]
    assert text_colours(~s(class="lg:hover:text-error")) == ["error"]
    assert text_colours(~s(class="text-base-content/60")) == ["base-content/60"]
    assert text_colours(~s(class="text-[#ff0000] text-[15px]")) == ["[#ff0000]"]
    assert text_colours(~s(class="text-xs text-left")) == []
  end

  test "no bare hover:" do
    for {rel, _, source} <- sources() do
      bare = Regex.scan(~r/(?<![\w:-])hover:[\w\/\[\]-]+/, source) |> List.flatten()
      assert bare == [], "#{rel}: bare hover: #{inspect(bare)}; use lg:hover:"
    end
  end

  test "text colours are text-base-content and text-subtle only" do
    for {rel, _, source} <- sources() do
      off = source |> text_colours() |> Enum.uniq() |> Kernel.--(@allowed_text)
      assert off == [], "#{rel}: text colour(s) #{inspect(off)}; only #{inspect(@allowed_text)}"
    end
  end

  test "no opacity on text" do
    for {rel, _, source} <- sources() do
      opacity = Regex.scan(~r/(?<![\w-])(?:[a-z0-9-]+:)*opacity-\d+/, source) |> List.flatten()
      assert opacity == [], "#{rel}: #{inspect(opacity)}"
      refute source =~ ~r/text-(base-content|subtle)\/\d+/, rel
    end
  end

  test "no hex literal" do
    for {rel, _, source} <- sources() do
      hex = Regex.scan(~r/#[0-9a-fA-F]{3,8}\b/, source) |> List.flatten()
      assert hex == [], "#{rel}: #{inspect(hex)}"
    end
  end
end
