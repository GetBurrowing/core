defmodule Platform.GamesOrderTest do
  use Platform.DataCase, async: false

  alias Platform.{Games, Tenancy}

  setup do
    old = Application.get_env(:platform, :game_publications)
    on_exit(fn -> Application.put_env(:platform, :game_publications, old || []) end)
    %{org_id: Tenancy.get_org_by_slug!("acme").id}
  end

  defp game(org_id, slug, title, extra) do
    Map.merge(
      %{
        "slug" => slug,
        "published" => true,
        "org_id" => org_id,
        "title" => title,
        "summary" => "A game.",
        "current_version" => "one",
        "releases" => [
          %{
            "version" => "one",
            "attachment_id" => Ecto.UUID.generate(),
            "sha256" => String.duplicate("a", 64),
            "byte_size" => 1000
          }
        ]
      },
      extra
    )
  end

  test "positioned games come first, by position; the rest follow by title", %{org_id: org_id} do
    Application.put_env(:platform, :game_publications, [
      game(org_id, "zeta", "Alpha unpositioned", %{}),
      game(org_id, "sky", "Placeholder: Sky", %{"position" => 1}),
      game(org_id, "voltron", "Voltron", %{"position" => 0}),
      game(org_id, "beta", "Beta unpositioned", %{"position" => "not a number"})
    ])

    assert Enum.map(Games.list_published(), & &1["slug"]) == ["voltron", "sky", "zeta", "beta"]
  end

  test "without positions the order stays by title", %{org_id: org_id} do
    Application.put_env(:platform, :game_publications, [
      game(org_id, "b", "Bravo", %{}),
      game(org_id, "a", "Alpha", %{})
    ])

    assert Enum.map(Games.list_published(), & &1["slug"]) == ["a", "b"]
  end
end
