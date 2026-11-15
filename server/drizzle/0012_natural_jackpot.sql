CREATE TABLE "schedule_changes" (
	"id" text PRIMARY KEY NOT NULL,
	"task_id" text NOT NULL,
	"before" jsonb NOT NULL,
	"after" jsonb NOT NULL,
	"reason" text NOT NULL,
	"change_type" text NOT NULL,
	"before_unscheduled" jsonb,
	"after_unscheduled" jsonb,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE INDEX "schedule_changes_updated_idx" ON "schedule_changes" USING btree ("updated_at","id");