defmodule PlatformWeb.ControlCenter.NativeLoginPanelTest do
  @moduledoc """
  The login pane's step 1 (legacypie, 2026-11-11): for Burrow it links to
  `/setup/connect-ai`, the screen that signs an agent in with a Claude Pro or
  Max plan (task 01a1b365); for any other agent it says the plan sign-in is
  Burrow's only, instead of the stale "not available yet".

  Mutants these name: drop the `connect_ai?` branch → the Burrow case fails;
  link every agent → the other-agent case fails; show the link to a
  non-manager → the locked case fails.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PlatformWeb.ControlCenter.NativeLogin, as: Panel

  @agent %{id: Ecto.UUID.generate(), name: "Burrow", slug: "burrow"}

  defp panel(opts) do
    render_component(
      &Panel.panel/1,
      Keyword.merge(
        [agent: @agent, can_manage?: true, key_set?: false, step: :needs_key, mode: :api_key],
        opts
      )
    )
  end

  test "Burrow's step 1 is a link to Connect your AI" do
    doc = panel(connect_ai?: true) |> LazyHTML.from_fragment()
    [link] = doc |> LazyHTML.query("#native-login-connect-ai") |> Enum.to_list()
    assert LazyHTML.attribute(link, "href") == ["/setup/connect-ai"]
    assert LazyHTML.text(doc) =~ "Use your Claude Pro or Max plan"
    refute LazyHTML.text(doc) =~ "Not available yet"
    # The API key stays as the other way in.
    assert doc |> LazyHTML.query("#native-api-key-form") |> Enum.count() == 1
  end

  test "another agent's step 1 says the plan sign-in is Burrow's only" do
    doc =
      panel(connect_ai?: false, agent: %{@agent | name: "Ada", slug: "ada"})
      |> LazyHTML.from_fragment()

    assert doc |> LazyHTML.query("#native-login-connect-ai") |> Enum.empty?()
    assert LazyHTML.text(doc) =~ "Only Burrow can sign in with a Claude plan"
  end

  test "a non-manager gets no link" do
    doc = panel(connect_ai?: true, can_manage?: false) |> LazyHTML.from_fragment()
    assert doc |> LazyHTML.query("#native-login-connect-ai") |> Enum.empty?()
    assert LazyHTML.text(doc) =~ "Someone who manages Burrow can log it in."
  end

  test "the summary card names the way in" do
    html =
      render_component(&Panel.summary/1,
        agent: @agent,
        can_manage?: true,
        key_set?: false,
        step: :idle,
        mode: :api_key,
        connect_ai?: true
      )

    assert html =~ ~s(href="/setup/connect-ai")
    refute html =~ "not available yet"
  end
end
