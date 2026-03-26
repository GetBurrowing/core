defmodule Platform.Repo.Migrations.MakePlanApprovedByText do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      current_type text;
    BEGIN
      SELECT data_type
      INTO current_type
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'plans'
        AND column_name = 'approved_by';

      IF current_type IS NULL THEN
        RAISE EXCEPTION 'plans.approved_by column not found';
      ELSIF current_type <> 'text' THEN
        ALTER TABLE plans
          ALTER COLUMN approved_by TYPE text
          USING approved_by::text;
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    DECLARE
      current_type text;
    BEGIN
      SELECT data_type
      INTO current_type
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'plans'
        AND column_name = 'approved_by';

      IF current_type = 'text' THEN
        ALTER TABLE plans
          ALTER COLUMN approved_by TYPE uuid
          USING CASE
            WHEN approved_by IS NULL THEN NULL
            WHEN approved_by ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              THEN approved_by::uuid
            ELSE NULL
          END;
      END IF;
    END
    $$;
    """)
  end
end
