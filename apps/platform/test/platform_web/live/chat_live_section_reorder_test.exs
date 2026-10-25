defmodule PlatformWeb.ChatLiveSectionReorderTest do
  @moduledoc """
  The `Accounts.update_user_preference/3` helper the section order was
  persisted through.

  Burrow redesign 22 stage 2 deleted the desktop channel rail; its drag
  reorder (and `ChatLive.compute_reorder/3`), saved-order hydration and
  per-section drag handles went with it, so the cases that exercised them are
  deleted rather than retargeted
  (the Chat list sorts by recency and has no manual order).
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "reorder_#{suffix}@example.com",
      name: "Reorder Test #{suffix}",
      oidc_sub: "oidc-reorder-#{suffix}",
      avatar_url: nil
    })
  end

  describe "Accounts.update_user_preference/3" do
    test "upserts a single key into the preferences map" do
      user = insert_user("acct1")

      {:ok, updated} =
        Accounts.update_user_preference(user.id, :chat_section_order, ["Globex", "Acme"])

      assert updated.preferences == %{"chat_section_order" => ["Globex", "Acme"]}

      # Idempotent — overwriting the same key works.
      {:ok, updated2} =
        Accounts.update_user_preference(user.id, :chat_section_order, ["Acme", "Globex"])

      assert updated2.preferences == %{"chat_section_order" => ["Acme", "Globex"]}
    end

    test "merges into existing preferences without clobbering siblings" do
      user = insert_user("acct2")

      {:ok, _} = Accounts.update_user_preference(user.id, "theme", "dark")
      {:ok, updated} = Accounts.update_user_preference(user.id, :chat_section_order, ["Globex"])

      assert updated.preferences == %{
               "theme" => "dark",
               "chat_section_order" => ["Globex"]
             }
    end

    test "returns {:error, :not_found} for unknown user" do
      assert {:error, :not_found} =
               Accounts.update_user_preference(
                 Ecto.UUID.generate(),
                 :chat_section_order,
                 ["Hooli"]
               )
    end

    test "get_user_preferences/1 returns %{} for unknown user" do
      assert Accounts.get_user_preferences(Ecto.UUID.generate()) == %{}
      assert Accounts.get_user_preferences(nil) == %{}
    end
  end
end
