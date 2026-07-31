defmodule Platform.Tasks.RepoRefTest do
  use ExUnit.Case, async: true

  alias Platform.Tasks.RepoRef

  doctest RepoRef

  describe "normalize/1 — accepted spellings" do
    # Every form that actually reaches this system: `project.repo_url`
    # stores the https form, GitHub webhooks deliver the bare
    # `repository.full_name`, and git remotes / config hand us the rest.
    for {input, expected} <- [
          {"https://github.com/Startup-Suite/core", "Startup-Suite/core"},
          {"https://github.com/Startup-Suite/core/", "Startup-Suite/core"},
          {"https://github.com/Startup-Suite/core.git", "Startup-Suite/core"},
          {"http://github.com/Startup-Suite/core", "Startup-Suite/core"},
          {"https://www.github.com/Startup-Suite/core", "Startup-Suite/core"},
          {"git@github.com:Startup-Suite/core.git", "Startup-Suite/core"},
          {"git@github.com:Startup-Suite/core", "Startup-Suite/core"},
          {"ssh://git@github.com/Startup-Suite/core.git", "Startup-Suite/core"},
          {"Startup-Suite/core", "Startup-Suite/core"},
          {"  Startup-Suite/core  ", "Startup-Suite/core"},
          {"Startup-Suite/claude-code-suite-channel", "Startup-Suite/claude-code-suite-channel"},
          {"https://github.com/Startup-Suite/openclaw-suite-channel",
           "Startup-Suite/openclaw-suite-channel"},
          {"https://github.com/some-owner/dot.name.js", "some-owner/dot.name.js"}
        ] do
      test "normalizes #{inspect(input)}" do
        assert RepoRef.normalize(unquote(input)) == {:ok, unquote(expected)}
      end
    end

    test "preserves the case it was given" do
      assert RepoRef.normalize("https://github.com/Startup-Suite/Core") ==
               {:ok, "Startup-Suite/Core"}
    end
  end

  describe "normalize/1 — refusals" do
    for input <- [
          nil,
          "",
          "   ",
          "not a repo",
          "core",
          "https://github.com/Startup-Suite",
          "https://github.com/Startup-Suite/core/tree/main",
          "https://gitlab.com/Startup-Suite/core",
          "https://example.invalid/Startup-Suite/core",
          "git@gitlab.com:Startup-Suite/core.git",
          123,
          %{"repo_url" => "Startup-Suite/core"},
          ["Startup-Suite/core"]
        ] do
      test "refuses #{inspect(input)}" do
        assert RepoRef.normalize(unquote(Macro.escape(input))) == :error
      end
    end

    test "a refusal is never a guess — a fixture repo_url yields no slug" do
      assert RepoRef.slug("https://example.invalid/acme/widgets") == nil
    end
  end

  describe "slug/1" do
    test "returns the slug or nil" do
      assert RepoRef.slug("https://github.com/Startup-Suite/core.git") == "Startup-Suite/core"
      assert RepoRef.slug("nonsense") == nil
      assert RepoRef.slug(nil) == nil
    end
  end

  describe "same?/2" do
    test "matches the https form against the bare webhook form" do
      assert RepoRef.same?(
               "https://github.com/Startup-Suite/core",
               "Startup-Suite/core"
             )
    end

    test "is case-insensitive (GitHub lookup is)" do
      assert RepoRef.same?("Startup-Suite/Core", "startup-suite/core")
      assert RepoRef.same?("https://github.com/STARTUP-SUITE/CORE", "Startup-Suite/core")
    end

    test "distinguishes different repos in the same org" do
      refute RepoRef.same?(
               "https://github.com/Startup-Suite/core",
               "Startup-Suite/claude-code-suite-channel"
             )
    end

    test "distinguishes same repo name in different orgs" do
      refute RepoRef.same?("Startup-Suite/core", "someone-else/core")
    end

    # A "same repo" answer must be earned by two resolvable identities.
    # `nil == nil` returning true would pass a deploy gate for a repo
    # nobody could name.
    test "never returns true on an unresolvable side" do
      refute RepoRef.same?(nil, nil)
      refute RepoRef.same?("", "")
      refute RepoRef.same?(nil, "Startup-Suite/core")
      refute RepoRef.same?("Startup-Suite/core", nil)
      refute RepoRef.same?("not a repo", "not a repo")
      refute RepoRef.same?(%{}, %{})
    end
  end
end
