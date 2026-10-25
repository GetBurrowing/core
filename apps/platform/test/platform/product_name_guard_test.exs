defmodule Platform.ProductNameGuardTest do
  @moduledoc """
  The product is called Burrow (task 01a14b9e-50a4-7000-996c-429bca872907,
  rename A2). This guard fails when the old product name comes back in
  user-facing code or copy, naming every offending `path:line: text`.

  ## What is scanned

  Every file under these repo-root paths:

    * `apps/platform/lib/**/*.{ex,heex,eex}`;
    * `apps/platform/assets/js/**` and `apps/platform/assets/css/**`, except
      any `vendor/` directory;
    * `apps/platform/priv/prototype/**` and `apps/platform/priv/static/sw.js`;
    * `apps/social/lib/**`;
    * `docs/burrow/**/*.md`, `README.md` and `CONTRIBUTING.md`;
    * `clients/android/**/*.{kt,xml,gradle,kts}` (task 01a14ba9 stage 4) and
      `clients/ios/**/*.{swift,plist,yml,pbxproj,entitlements}` (stage 5),
      except any `node_modules/`, `build/`, `.gradle/`, `.build/`,
      `DerivedData/` or `Pods/` directory.

  The files are enumerated with `Path.wildcard/1`, not `git ls-files`: CI's
  Test job checks the repo out (`actions/checkout`) BEFORE it installs git,
  so that checkout has no `.git` directory for `git ls-files` to read. At the
  commit this guard landed on, none of these paths held an untracked or
  ignored file, so the two enumerations named the same files.

  ## What is forbidden, per line

  `\\bSuite\\b` (case-sensitive), `startup suite` (any case), `Startup Burrow`
  and `Burrow Suite`. Client files (`clients/`) are also matched against
  `\\bSuite[A-Z]` (a `Suite`-prefixed identifier such as `SuiteNativePlugin`)
  and `\\bsuite[-.][a-z]` in any case (a `suite`-named host or key such as
  `suite.example.com` or `SUITE-B.localhost`). Before matching:

    * the GitHub organisation spans `Startup-Suite/`, `github.com/Startup-Suite`
      and `ghcr.io/getburrowing` are removed. The organisation is renamed last,
      by its own ticket;
    * each allowlisted substring for that file is removed, so an allowlisted
      identifier does not hide a second, new occurrence on the same line.

  ## No sibling-ticket skip

  Until task A3b (01a14dce-d2d8-7000-becf-79544fe7cf98) stage 3 moved the
  Android and iOS `InstallStore` tests onto `example.com` stand-ins, lines
  carrying a former default install host were skipped through a list of A3
  digests. That skip excused no scanned line after stage 3, so stage 4
  removed it: every scanned line is now checked.

  ## The allowlist fires in both directions

  `@allowlist` is an explicit list of `{relative_path, exact_substring,
  reason}`. Every entry must still occur on at least one scanned line of its
  file, or the test fails naming it as a stale allowlist entry. So an entry
  cannot outlive the text it excuses.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  # The patterns tested against each line, after the spans below are removed.
  @forbidden [
    ~r/\bSuite\b/,
    ~r/startup suite/i,
    ~r/Startup Burrow/,
    ~r/Burrow Suite/
  ]

  # Extra patterns for client files only. Core keeps `Suite`-prefixed module
  # names that are not product copy (e.g. `Mix.Tasks.Suite.`), so these are
  # not applied there.
  @client_forbidden [~r/\bSuite[A-Z]/, ~r/\bsuite[-.][a-z]/i]

  # GitHub organisation and registry names: renamed with the org, last.
  @org_spans ~r/Startup-Suite\/|github\.com\/Startup-Suite|ghcr\.io\/startup-suite/

  @client_state "Storage key namespace and browser global, kept by stage 2: renaming it orphans state persisted in users' browsers"
  @earlier_name "States the product's earlier name on purpose"
  @org_name "The GitHub organisation's name, renamed with the org by its own ticket"
  @quoted "Quotes the title of an earlier design artefact or memory page verbatim"
  @plugin_wire "Capacitor plugin wire name: core JS older than task 01a14ba9 looks up only SuiteNative, so the app keeps registering it until every install runs the Burrow-first lookup (docs/runbooks/burrow-rename-deferred.md)"

  @android "clients/android/android/app/src"

  @ios "clients/ios/ios"

  @persisted_key "UserDefaults key persisted on users' devices: renaming it silently drops the stored value on upgrade (the installs list, sign-ins, caches), and no iOS test can run here to prove a migration. Migrate in a release with a device-tested migration (docs/runbooks/burrow-rename-deferred.md)"

  @sealed_fixture "Bound to the sealed push_seal_v1.json fixture, whose install host is suite-b.localhost: the expected label is derived from that host, and the fixture stays byte-identical to its core and Android copies until all three are resealed (docs/runbooks/burrow-rename-deferred.md)"

  @allowlist [
    {"README.md", "Burrow used to be called Startup Suite", @earlier_name},
    {"docs/burrow/index.md", "Burrow was called Startup Suite", @earlier_name},
    {"apps/platform/assets/js/client_state.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/canvas_sidebar_resize.js", "Suite.ClientState",
     @client_state},
    {"apps/platform/assets/js/hooks/compose_input.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/done_column_state.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/lazy_inline_canvas.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/meeting_captions.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/meeting_soundboard.js", "Suite.ClientState", @client_state},
    {"apps/platform/assets/js/hooks/sidebar_collapse.js", "Suite.ClientState", @client_state},
    {"apps/platform/lib/mix/tasks/suite.deploy.scope_gate.ex", "Mix.Tasks.Suite.",
     "Mix task module; its name is the `mix suite.deploy.scope_gate` command scripts call"},
    {"apps/platform/lib/mix/tasks/suite.responsibility_reachability.ex", "Mix.Tasks.Suite.",
     "Mix task module; its name is the `mix suite.responsibility_reachability` command scripts call"},
    {"apps/platform/lib/platform/experiments/surfaces/code_mode.ex", "Suite tool",
     "Experiment code-mode-2026-10 is running on this surface; its directives stay byte-identical until it concludes"},
    {"apps/platform/lib/platform/experiments/surfaces/code_mode.ex", "Suite calls",
     "Experiment code-mode-2026-10 is running on this surface; its directives stay byte-identical until it concludes"},
    {"apps/platform/lib/platform/federation/tool_surface.ex", "Startup-Suite feedback repository",
     @org_name},
    {"apps/platform/lib/platform/feedback/github_publisher.ex",
     "Startup-Suite feedback repository", @org_name},
    {"apps/platform/lib/platform/meetings/archive.ex", "Suite / Control Center",
     "Example meeting subtitle quoting a space's own name"},
    {"apps/platform/lib/platform_web/live/meeting_live.ex", "Suite / Control Center",
     "Example meeting subtitle quoting a space's own name"},
    {"apps/platform/lib/platform/push/notification.ex", "Suite iOS v1", @quoted},
    {"apps/platform/lib/platform/push/notification.ex", ~s(compiled `"Suite"`),
     "Describes the old compiled default this code replaced"},
    {"apps/platform/priv/static/sw.js", ~s(`"Suite"` was doing),
     "Describes the old name a renamed install kept showing"},
    {"apps/platform/lib/platform/responsibilities/handlers/agents_goal_heartbeat.ex", ~s(Suite"),
     "Quotes the title of an agent's goal verbatim"},
    {"apps/platform/lib/platform/responsibilities/handlers/architecture_audit_diff.ex",
     "Suite ToolSurface smell", @quoted},
    {"apps/platform/lib/platform/tasks.ex", "[Suite engine quirks]", @quoted},
    {"apps/platform/lib/platform/tasks/plan_engine.ex", "[Suite engine quirks]", @quoted},
    {"apps/platform/lib/platform_web/live/control_center/native_login.ex", ~s("Suite), @quoted},
    {"apps/platform/lib/platform_web/live/org_memory_live/mobile_shell.ex", "Suite tokens",
     @quoted},
    {"#{@android}/main/java/com/koboai/burrow/BurrowNativePlugin.kt", ~s(name = "SuiteNative"),
     @plugin_wire},
    {"#{@android}/main/java/com/koboai/burrow/BurrowNativePlugin.kt", "`SuiteNative`",
     @plugin_wire},
    {"#{@android}/main/java/com/koboai/burrow/NativeBridgeExposure.kt", ~s[listOf("SuiteNative"],
     @plugin_wire},
    {"#{@android}/main/java/com/koboai/burrow/NativeBridgeExposure.kt", "`SuiteNative`",
     @plugin_wire},
    {"#{@android}/main/java/com/koboai/burrow/shortcuts/ConversationNoter.kt",
     "`SuiteNative.donate(detail)`", @plugin_wire},
    {"#{@android}/test/java/com/koboai/burrow/shortcuts/DonateDispatchTest.kt",
     "`SuiteNative.donate`", @plugin_wire},
    # iOS (task 01a14ba9 stage 5): the Capacitor wire names.
    {"#{@ios}/App/App/Plugins/BurrowNativePlugin.swift", ~s(jsName = "SuiteNative"),
     @plugin_wire},
    {"#{@ios}/App/App/Plugins/BurrowNativePlugin.swift", "`SuiteNative`", @plugin_wire},
    # Task 01a1557b stage 2: the native tab bar's doc comments name the wire method.
    {"#{@ios}/App/App/BurrowBridgeViewController.swift", "`SuiteNative.tabBarState`",
     @plugin_wire},
    {"#{@ios}/App/App/NativeTabBar.swift", "`SuiteNative.tabBarState`", @plugin_wire},
    # Task 01a1557b stage 4: the contract scan asserts the hook's plugin lookup.
    {"#{@ios}/App/AppTests/NativeTabBarContractTests.swift", "cap.Plugins?.SuiteNative",
     @plugin_wire},
    {"#{@ios}/App/App/Plugins/BurrowMeetingsPlugin.swift", ~s(jsName = "SuiteMeetings"),
     @plugin_wire},
    {"#{@ios}/App/App/Plugins/BurrowMeetingsPlugin.swift", "`SuiteMeetings`", @plugin_wire},
    {"#{@ios}/App/App/Plugins/BurrowMeetingsPlugin.swift", "`SuiteNative`", @plugin_wire},
    {"#{@ios}/App/App/BurrowBridgeViewController.swift", "`SuiteNative.shouldOverrideLoad`",
     @plugin_wire},
    {"#{@ios}/App/App/BurrowBridgeViewController.swift", "`SuiteNative`", @plugin_wire},
    {"#{@ios}/App/App/BurrowBridgeViewController.swift", "`SuiteNative.installBadges()`",
     @plugin_wire},
    {"#{@ios}/App/App/Meetings/CallController.swift", "`SuiteMeetings.setMuted`", @plugin_wire},
    {"#{@ios}/App/App/Meetings/CallState.swift", "`SuiteMeetings`", @plugin_wire},
    {"#{@ios}/App/AppTests/BurrowMeetingsPluginTests.swift", "`SuiteMeetings`", @plugin_wire},
    {"#{@ios}/Intents/DonationPolicy.swift", "`SuiteNative.donate`", @plugin_wire},
    {"#{@ios}/Shared/InstallUnreadStore.swift", "`SuiteNative.installBadges`", @plugin_wire},
    # iOS: persisted UserDefaults keys, each by its exact code form, so renaming the
    # constant leaves its entry stale and fails the guard.
    {"#{@ios}/Shared/InstallStore.swift", ~s(static let installs = "suite.installs.v1"),
     @persisted_key},
    {"#{@ios}/Shared/InstallStore.swift", ~s(static let selected = "suite.installs.selected.v1"),
     @persisted_key},
    {"#{@ios}/Shared/InstallStore.swift",
     ~s(static let confirmed = "suite.installs.confirmed.v1"), @persisted_key},
    {"#{@ios}/Shared/InstallStore.swift", ~s(static let appInstallID = "suite.app_install_id.v1"),
     @persisted_key},
    {"#{@ios}/Shared/InstallStore.swift",
     ~s(static let defaultsChecked = "suite.installs.defaults_checked.v1"), @persisted_key},
    {"#{@ios}/Shared/InstallStore.swift", "`suite.installs.v1`", @persisted_key},
    {"#{@ios}/Shared/InstallStore.swift", "`suite.installs.selected.v1`", @persisted_key},
    {"#{@ios}/Shared/InstallStore.swift", "`suite.installs.confirmed.v1`", @persisted_key},
    {"#{@ios}/Shared/InstallStore.swift", "`suite.installs.defaults_checked.v1`", @persisted_key},
    {"#{@ios}/App/App/Meetings/RecentCalls.swift", ~s(static let key = "suite.recent_calls.v1"),
     @persisted_key},
    {"#{@ios}/Intents/ApprovalsWidgetModel.swift", ~s(armKey = "suite.widget.arm.v1"),
     @persisted_key},
    {"#{@ios}/Intents/ApprovalsWidgetModel.swift", ~s(marksKey = "suite.widget.rows.v1"),
     @persisted_key},
    {"#{@ios}/Intents/ApprovalsWidgetModel.swift", ~s(keyPrefix = "suite.approvals.v1."),
     @persisted_key},
    {"#{@ios}/Intents/IntentSupport.swift", ~s("suite.intents.last-meeting-space.v1.),
     @persisted_key},
    {"#{@ios}/Intents/ShortcutParameterRefresh.swift",
     ~s(digestPrefix = "suite.shortcuts.digest.v1."), @persisted_key},
    {"#{@ios}/Intents/ShortcutParameterRefresh.swift", ~s(dirtyKey = "suite.shortcuts.dirty.v1"),
     @persisted_key},
    {"#{@ios}/Intents/ShortcutParameterRefresh.swift",
     ~s(refreshedAtKey = "suite.shortcuts.refreshed-at.v1"), @persisted_key},
    {"#{@ios}/App/AppTests/ShortcutParameterRefreshTests.swift",
     ~s[hasPrefix("suite.shortcuts.")], @persisted_key},
    {"#{@ios}/Shared/CountsCache.swift", ~s(keyPrefix = "suite.counts.v1."), @persisted_key},
    {"#{@ios}/Shared/InstallUnreadStore.swift", ~s(keyPrefix = "suite.unread.v1."),
     @persisted_key},
    {"#{@ios}/Shared/ShareSheetModel.swift", ~s("suite.share.last_space.v1.), @persisted_key},
    # iOS: InstallStoreTests.swift reads the store's persisted keys (A3b,
    # 01a14dce stage 3, moved its hosts to burrow.example.com stand-ins).
    {"#{@ios}/App/AppTests/InstallStoreTests.swift", ~s("suite.installs.v1"), @persisted_key},
    {"#{@ios}/App/AppTests/InstallStoreTests.swift", ~s("suite.installs.selected.v1"),
     @persisted_key},
    {"#{@ios}/App/AppTests/InstallStoreTests.swift", ~s("suite.installs.confirmed.v1"),
     @persisted_key},
    # iOS: lines bound to the sealed push fixture's host.
    {"#{@ios}/App/AppTests/PushRelayTests.swift", ~s[.body, "New message in SUITE-B")],
     @sealed_fixture},
    {"#{@ios}/App/AppTests/PushRelayTests.swift", ~s[.subtitle, "SUITE-B")], @sealed_fixture}
  ]

  describe "scan of the repository" do
    test "scans a non-trivial file set" do
      files = scanned_files()

      # A guard whose glob silently matched nothing would pass on every tree.
      assert length(files) > 500, "only #{length(files)} files scanned; a scan root moved?"

      for root <- [
            "apps/platform/lib/",
            "apps/platform/assets/js/",
            "apps/social/lib/",
            "clients/android/android/app/src/main/",
            "clients/android/android/app/src/test/",
            "#{@ios}/App/App/",
            "#{@ios}/App/AppTests/",
            "#{@ios}/Shared/",
            "#{@ios}/BurrowWidgets/"
          ] do
        assert Enum.any?(files, &String.starts_with?(&1, root)), "nothing scanned under #{root}"
      end

      for file <- [
            "README.md",
            "docs/burrow/index.md",
            "apps/platform/priv/static/sw.js",
            "#{@android}/main/java/com/koboai/burrow/BurrowNativePlugin.kt",
            "#{@android}/main/res/values/strings.xml",
            "clients/android/android/app/build.gradle",
            "#{@ios}/App/App/Plugins/BurrowNativePlugin.swift",
            "#{@ios}/App/App/Info.plist",
            "#{@ios}/App/project.yml",
            "#{@ios}/App/App.xcodeproj/project.pbxproj",
            "#{@ios}/BurrowWidgets/BurrowWidgets.entitlements"
          ] do
        assert file in files, "#{file} is not scanned"
      end
    end

    test "no scanned line names the old product, outside the allowlist" do
      offences =
        Enum.flat_map(scanned_files(), fn rel ->
          rel |> read_lines() |> offences(rel, allowed_substrings(rel))
        end)

      assert offences == [], """
      The product is called Burrow. #{length(offences)} line(s) still use the old name.
      Change the copy, or, if the old name is deliberate, add an entry to
      @allowlist in #{Path.relative_to(__ENV__.file, @repo_root)} with a reason:

      #{Enum.join(offences, "\n")}
      """
    end

    test "every allowlist entry still matches a scanned line" do
      files = MapSet.new(scanned_files())

      stale =
        for {rel, substring, _reason} <- @allowlist,
            not (MapSet.member?(files, rel) and
                   Enum.any?(read_lines(rel), &String.contains?(&1, substring))) do
          "stale allowlist entry: #{rel} no longer contains #{inspect(substring)}"
        end

      assert stale == [], Enum.join(stale, "\n")
    end

    test "every allowlist entry has a reason" do
      for {rel, substring, reason} <- @allowlist do
        assert is_binary(reason) and String.trim(reason) != "",
               "#{rel} #{inspect(substring)} has no reason"
      end
    end
  end

  describe "line matcher (planted lines)" do
    test "flags each forbidden form" do
      for line <- [
            "Welcome to Suite.",
            "<p>Sign in to Suite</p>",
            "Startup Suite",
            "startup suite",
            "Startup Burrow",
            "Burrow Suite"
          ] do
        assert offences([line], "planted.ex", []) == ["planted.ex:1: #{line}"],
               "#{inspect(line)} was not flagged"
      end
    end

    test "leaves the English word and identifiers alone" do
      for line <- [
            "the full test suite",
            "a suite of tools",
            "SuiteExecutor runs the stage",
            "suite_run, SUITE_TOKEN and BURROW_TOKEN",
            "Burrow tools"
          ] do
        assert offences([line], "planted.ex", []) == [], "#{inspect(line)} was flagged"
      end
    end

    test "removes the GitHub organisation spans before matching" do
      for line <- [
            "see github.com/Startup-Suite/core",
            "ghcr.io/getburrowing/core:latest",
            "Startup-Suite/feedback issues"
          ] do
        assert offences([line], "planted.ex", []) == [], "#{inspect(line)} was flagged"
      end

      assert offences(["Suite lives at github.com/Startup-Suite/core"], "p.ex", []) ==
               ["p.ex:1: Suite lives at github.com/Startup-Suite/core"]
    end

    test "an allowlisted substring does not hide a second occurrence on its line" do
      assert offences(["uses Suite.ClientState"], "p.js", ["Suite.ClientState"]) == []

      assert offences(["Suite.ClientState for Suite"], "p.js", ["Suite.ClientState"]) ==
               ["p.js:1: Suite.ClientState for Suite"]
    end

    test "client files also flag Suite-prefixed identifiers and suite-named hosts" do
      for line <- [
            "class SuiteNativePlugin : Plugin()",
            "registerPlugin(SuiteFoo::class.java)",
            ~s(private val host = "suite.example.com"),
            ~s(private val a = "suite-a.localhost"),
            ~s[prefs.getString("pushkey.v1.suite-b.localhost")],
            ~s[assertEquals(ALLOW, main("https://SUITE.example.net/"))]
          ] do
        assert offences([line], "clients/android/p.kt", []) == ["clients/android/p.kt:1: #{line}"],
               "#{inspect(line)} was not flagged in a client file"
      end
    end

    test "client patterns leave Burrow names, the English word and other files alone" do
      for line <- [
            "class BurrowNativePlugin : Plugin()",
            ~s(private val host = "burrow.example.com"),
            "the unit test suite passes",
            "UserDefaults(suiteName: group)",
            "SUITE_MENTION and BURROW_MENTION"
          ] do
        assert offences([line], "clients/android/p.kt", []) == [], "#{inspect(line)} was flagged"
      end

      # Core keeps Suite-prefixed module names; the client patterns are not applied there.
      assert offences(["SuiteExecutor runs suite.deploy"], "apps/platform/lib/p.ex", []) == []
    end

    test "iOS files get the client patterns too" do
      for line <- [
            "view.backgroundColor = SuiteColor.surface.uiColor",
            "final class SuiteBridgeViewController: CAPBridgeViewController {",
            "<key>SuiteKeychainAccessGroup</key>",
            "path = SuiteWidgets.appex; sourceTree = BUILT_PRODUCTS_DIR;",
            ~s(private let host = "suite.example.net"),
            ~s(static let installs = "suite.installs.v1")
          ] do
        assert offences([line], "clients/ios/p.swift", []) == ["clients/ios/p.swift:1: #{line}"],
               "#{inspect(line)} was not flagged in an iOS file"
      end

      for line <- [
            "defaults = UserDefaults(suiteName: suiteName)",
            "view.backgroundColor = BurrowColor.surface.uiColor",
            ~s[XCTAssertEqual(category, "SUITE_RING_WAITING")],
            "HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256)"
          ] do
        assert offences([line], "clients/ios/p.swift", []) == [], "#{inspect(line)} was flagged"
      end
    end

    test "an allowlisted persisted key does not hide a renamed type on its line" do
      allowed = [~s(static let installs = "suite.installs.v1")]
      kept = ~s(        static let installs = "suite.installs.v1")
      assert offences([kept], "clients/ios/p.swift", allowed) == []

      renamed_back = kept <> " // SuiteAPIClient"

      assert offences([renamed_back], "clients/ios/p.swift", allowed) ==
               ["clients/ios/p.swift:1: #{String.trim(renamed_back)}"]
    end

    test "an allowlisted wire name does not hide a renamed-back identifier on its line" do
      allowed = [~s(name = "SuiteNative")]
      kept = ~s[@CapacitorPlugin(name = "SuiteNative")]
      assert offences([kept], "clients/android/p.kt", allowed) == []

      renamed_back = kept <> " class SuiteNativePlugin"

      assert offences([renamed_back], "clients/android/p.kt", allowed) ==
               ["clients/android/p.kt:1: #{renamed_back}"]
    end
  end

  # -- scanning ---------------------------------------------------------------

  defp scanned_files do
    [
      "apps/platform/lib/**/*.{ex,heex,eex}",
      "apps/platform/assets/js/**",
      "apps/platform/assets/css/**",
      "apps/platform/priv/prototype/**",
      "apps/platform/priv/static/sw.js",
      "apps/social/lib/**",
      "docs/burrow/**/*.md",
      "README.md",
      "CONTRIBUTING.md",
      "clients/android/**/*.{kt,xml,gradle,kts}",
      "clients/ios/**/*.{swift,plist,yml,pbxproj,entitlements}"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(@repo_root, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, @repo_root))
    |> Enum.reject(&("vendor" in Path.split(&1)))
    |> Enum.reject(&generated_client_path?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Build output and installed packages under a client tree are not source.
  defp generated_client_path?(rel) do
    String.starts_with?(rel, "clients/") and
      Enum.any?(
        Path.split(rel),
        &(&1 in ["node_modules", "build", ".gradle", ".build", "DerivedData", "Pods"])
      )
  end

  defp read_lines(rel), do: @repo_root |> Path.join(rel) |> File.read!() |> String.split("\n")

  defp allowed_substrings(rel), do: for({^rel, s, _} <- @allowlist, do: s)

  # -- matching ---------------------------------------------------------------

  defp offences(lines, rel, allowed) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> offending?(line, allowed, forbidden_for(rel)) end)
    |> Enum.map(fn {line, n} -> "#{rel}:#{n}: #{String.trim(line)}" end)
  end

  defp forbidden_for("clients/" <> _), do: @forbidden ++ @client_forbidden
  defp forbidden_for(_rel), do: @forbidden

  defp offending?(line, allowed, forbidden) do
    stripped =
      Enum.reduce(allowed, Regex.replace(@org_spans, line, ""), &String.replace(&2, &1, ""))

    Enum.any?(forbidden, &Regex.match?(&1, stripped))
  end
end
