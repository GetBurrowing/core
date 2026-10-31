defmodule Platform.Repo.Migrations.AddMinimumNoticeToCalendarBookingLinks do
  @moduledoc """
  Adds a booking link's minimum notice: how soon before a slot a guest may
  still book it. Prototype v4's `Minimum notice` control (2 hours, 4 hours,
  1 day, 2 days).

  Task 01a18d9f-e246-7000-9ce6-e44212812eb0, stage 3. The default 0 keeps
  every existing link's behaviour (any future slot is bookable).
  """
  use Ecto.Migration

  def change do
    alter table(:calendar_booking_links) do
      add(:minimum_notice_minutes, :integer, null: false, default: 0)
    end
  end
end
