ALTER TABLE "tasks" ADD COLUMN "tags" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "waiting_on" text;--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "waiting_until" timestamp with time zone;