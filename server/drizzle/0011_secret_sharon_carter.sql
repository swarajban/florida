ALTER TABLE "tasks" ADD COLUMN "someday" boolean DEFAULT false NOT NULL;
--> statement-breakpoint
UPDATE "tasks"
SET "someday" = "category_id" <> 'inbox' AND "due_at" IS NULL AND "start_at" IS NULL AND "pinned_start" IS NULL,
    "updated_at" = greatest(clock_timestamp(), "updated_at" + interval '1 millisecond');
--> statement-breakpoint
UPDATE "task_recurrences"
SET "template" = jsonb_set("template", '{someday}', to_jsonb(
      ("template"->>'categoryId') <> 'inbox' AND ("template"->>'dueAt') IS NULL
      AND ("template"->>'startAt') IS NULL AND ("template"->>'pinnedStart') IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM "tasks"
        WHERE "tasks"."recurrence_series_id" = "task_recurrences"."id"
          AND ("tasks"."due_at" IS NOT NULL OR "tasks"."start_at" IS NOT NULL OR "tasks"."pinned_start" IS NOT NULL)
      )
    )),
    "updated_at" = greatest(clock_timestamp(), "updated_at" + interval '1 millisecond');
