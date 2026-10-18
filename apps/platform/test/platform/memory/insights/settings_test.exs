defmodule Platform.Memory.Insights.SettingsTest do
  @moduledoc """
  Task 01a13867 stage 3: the `install_insight_settings` singleton.
  Dissemination ships OFF; only a root admin may change it; the deferred
  automatic paths (page edits, tasks) cannot be switched on by anyone.
  """

  use Platform.DataCase, async: false

  import Platform.InsightFixtures
  import Platform.TenancyFixtures

  alias Platform.Memory.Insights.Settings
  alias Platform.Repo

  test "dissemination is off on a fresh install" do
    assert Repo.aggregate(Settings, :count) == 1

    assert %Settings{
             dissemination_enabled: false,
             deliver_briefings: true,
             deliver_questions: true,
             apply_page_edits: false,
             file_tasks: false
           } = Settings.get()
  end

  test "a non-admin cannot update settings" do
    member = person!("member")
    assert Settings.update(member, %{dissemination_enabled: true}) == {:error, :unauthorized}
    refute Settings.get().dissemination_enabled

    # Positive control: a root admin can.
    assert {:ok, %Settings{dissemination_enabled: true}} =
             Settings.update(root_admin!(), %{dissemination_enabled: true})

    assert Settings.get().dissemination_enabled
  end

  test "apply_page_edits=true is refused" do
    admin = root_admin!()

    for field <- [:apply_page_edits, :file_tasks] do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Settings.update(admin, %{field => true})

      assert {"not available yet", _} = changeset.errors[field]
    end

    assert %Settings{apply_page_edits: false, file_tasks: false} = Settings.get()

    # The DB refuses it too, so a raw write cannot turn a deferred path on.
    assert_raise Postgrex.Error, ~r/install_insight_settings_deferred_off/, fn ->
      Repo.query!("UPDATE install_insight_settings SET apply_page_edits = true")
    end
  end
end
