defmodule Platform.Agents.UnblockAsks.TemplatesTest do
  @moduledoc """
  The unblock ask templates (task 01a1b6de stage 4): data with placeholders
  only. The GitHub write template is pinned word for word, and every
  template string is scanned for real identity (the install identity
  scanner), stray hosts, addresses and unknown placeholders.
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.UnblockAsks.Templates
  alias Platform.Regression.InstallIdentityScanner

  @allowed_hosts ["github.com"]

  defp strings(template) do
    [template.title, template.subtitle, template.success, template.still_missing] ++
      Enum.flat_map(template.steps, &[&1.text, &1.copy]) ++
      if(template.primary, do: [template.primary.label, template.primary.url], else: [])
  end

  defp all_strings do
    (Enum.flat_map(Templates.all(), fn {_name, t} -> strings(t) end) ++
       Map.values(Templates.person_steps()) ++ Templates.secondary())
    |> Enum.filter(&is_binary/1)
  end

  test "the access template is the GitHub write ask, word for word" do
    t = Templates.all()["access"]

    assert t.title == "Give {agent} write access so they can save code to your project"
    assert t.subtitle == "{agent} can read it but not save changes. Takes about 2 minutes."

    assert Enum.map(t.steps, & &1.text) == [
             "Open your project's access settings",
             "Click \"Add people\"",
             "Type {account}",
             "Choose \"Write\", then \"Add\""
           ]

    assert Enum.map(t.steps, & &1.copy) == [nil, nil, "{account}", nil]

    assert t.primary == %{
             label: "Open GitHub access",
             url: "https://github.com/{org}/{repo}/settings/access"
           }

    assert Templates.secondary() == ["I did it, check again", "Not now", "Why?"]
  end

  test "there is one template per blocker class plus the stuck-person template" do
    for class <- ~w(access credentials toolchain spend_consent offline person_setup) do
      assert Map.has_key?(Templates.all(), class), class
    end
  end

  test "templates use only the allowed placeholders" do
    allowed = MapSet.new(Templates.placeholders())

    used =
      all_strings()
      |> Enum.flat_map(&Regex.scan(~r/\{([a-z_]+)\}/, &1, capture: :all_but_first))
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.subset?(used, allowed), inspect(MapSet.difference(used, allowed))
    # Positive control: the scan reads the placeholders it should.
    assert MapSet.member?(used, "account") and MapSet.member?(used, "repo")
  end

  test "no template carries a real name, account, address or host" do
    for text <- all_strings() do
      assert InstallIdentityScanner.hits(text) == [], text
      refute text =~ ~r/@[A-Za-z0-9]/, text

      hosts =
        ~r/\b(?:[a-z0-9-]+\.)+(?:com|net|org|io|ai|dev|app)\b/i
        |> Regex.scan(text)
        |> List.flatten()

      assert Enum.all?(hosts, &(&1 in @allowed_hosts)), text
    end

    # Positive control: the host scan sees the one allowed host.
    assert Enum.any?(all_strings(), &(&1 =~ "github.com"))
  end

  test "rendering fills the placeholders and never leaves one raw" do
    values = %{"agent" => "Agent1", "org" => "acme", "repo" => "site", "account" => "agent1-bot"}
    view = Templates.render("access", values)

    assert view.template == "access"
    assert view.title == "Give Agent1 write access so they can save code to your project"
    assert Enum.at(view.steps, 2) == %{text: "Type agent1-bot", copy: "agent1-bot"}
    assert view.primary.url == "https://github.com/acme/site/settings/access"

    for {class, _} <- Templates.all() do
      rendered = Templates.render(class, %{"steps" => ["notifications"]})
      text = rendered |> Map.take([:title, :subtitle, :success, :still_missing]) |> Map.values()
      refute Enum.any?(text ++ Enum.map(rendered.steps, & &1.text), &(&1 =~ ~r/\{[a-z_]+\}/))
    end
  end

  test "an access refusal with no readable repository renders the generic access ask" do
    view = Templates.render("access", %{"agent" => "Agent1"})
    assert view.template == "access_other"
    assert view.primary == nil
  end

  test "the person template numbers the stuck steps only" do
    view = Templates.render("person_setup", %{"steps" => ["notifications", "ai_login"]})

    assert Enum.map(view.steps, & &1.text) == [
             "Turn on notifications in Settings",
             "Connect your AI login in Settings"
           ]
  end
end
