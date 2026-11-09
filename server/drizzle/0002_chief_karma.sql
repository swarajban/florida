CREATE TABLE "task_recurrences" (
	"id" text PRIMARY KEY NOT NULL,
	"rule" jsonb NOT NULL,
	"template" jsonb NOT NULL,
	"from_date" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "recurrence" jsonb;--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "recurrence_series_id" text;--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "recurrence_date" text;--> statement-breakpoint
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_recurrence_series_id_task_recurrences_id_fk" FOREIGN KEY ("recurrence_series_id") REFERENCES "public"."task_recurrences"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "tasks_recurrence_date_idx" ON "tasks" USING btree ("recurrence_series_id","recurrence_date");