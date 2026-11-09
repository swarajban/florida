ALTER TABLE "task_recurrences" ADD COLUMN "revision" text DEFAULT gen_random_uuid()::text NOT NULL;--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "recurrence_revision" text;