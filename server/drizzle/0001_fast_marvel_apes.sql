CREATE TABLE "unscheduled" (
	"task_id" text PRIMARY KEY NOT NULL,
	"reason" text NOT NULL,
	"unplaced_minutes" integer NOT NULL,
	"computed_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
ALTER TABLE "events" ADD COLUMN "description" text;--> statement-breakpoint
ALTER TABLE "events" ADD COLUMN "conference_url" text;--> statement-breakpoint
ALTER TABLE "events" ADD COLUMN "attendees" jsonb;--> statement-breakpoint
ALTER TABLE "events" ADD COLUMN "organizer" jsonb;--> statement-breakpoint
ALTER TABLE "events" ADD COLUMN "event_type" text;--> statement-breakpoint
ALTER TABLE "events" ADD COLUMN "recurring_event_id" text;--> statement-breakpoint
ALTER TABLE "events" ADD COLUMN "ical_uid" text;--> statement-breakpoint
ALTER TABLE "unscheduled" ADD CONSTRAINT "unscheduled_task_id_tasks_id_fk" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE cascade ON UPDATE no action;