CREATE TABLE "calendars" (
	"id" text PRIMARY KEY NOT NULL,
	"account_id" text NOT NULL,
	"google_id" text NOT NULL,
	"summary" text NOT NULL,
	"color" text,
	"access_role" text NOT NULL,
	"selected" boolean DEFAULT true NOT NULL,
	"sync_token" text,
	"channel_id" text,
	"channel_resource_id" text,
	"channel_token" text,
	"channel_expires_at" timestamp with time zone,
	"last_synced_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "categories" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"color" text,
	"schedule_id" text NOT NULL,
	"sort_order" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "events" (
	"id" text PRIMARY KEY NOT NULL,
	"calendar_id" text NOT NULL,
	"google_id" text NOT NULL,
	"status" text NOT NULL,
	"summary" text,
	"location" text,
	"start_at" timestamp with time zone,
	"end_at" timestamp with time zone,
	"all_day" boolean NOT NULL,
	"transparency" text,
	"response_status" text,
	"html_link" text,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "google_accounts" (
	"id" text PRIMARY KEY NOT NULL,
	"email" text NOT NULL,
	"label" text NOT NULL,
	"refresh_token_enc" text NOT NULL,
	"access_token" text,
	"access_token_expires_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "google_accounts_email_unique" UNIQUE("email")
);
--> statement-breakpoint
CREATE TABLE "placements" (
	"id" text PRIMARY KEY NOT NULL,
	"task_id" text NOT NULL,
	"start_at" timestamp with time zone NOT NULL,
	"end_at" timestamp with time zone NOT NULL,
	"pinned" boolean NOT NULL,
	"computed_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "schedules" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"time_zone" text NOT NULL,
	"windows" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "tasks" (
	"id" text PRIMARY KEY NOT NULL,
	"category_id" text NOT NULL,
	"title" text NOT NULL,
	"notes" text,
	"duration_minutes" integer NOT NULL,
	"min_chunk_minutes" integer,
	"priority" text NOT NULL,
	"deadline_type" text NOT NULL,
	"due_at" timestamp with time zone,
	"start_at" timestamp with time zone,
	"schedule_id" text,
	"pinned_start" timestamp with time zone,
	"completed_minutes" integer DEFAULT 0 NOT NULL,
	"completed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "calendars" ADD CONSTRAINT "calendars_account_id_google_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."google_accounts"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "categories" ADD CONSTRAINT "categories_schedule_id_schedules_id_fk" FOREIGN KEY ("schedule_id") REFERENCES "public"."schedules"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "events" ADD CONSTRAINT "events_calendar_id_calendars_id_fk" FOREIGN KEY ("calendar_id") REFERENCES "public"."calendars"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "placements" ADD CONSTRAINT "placements_task_id_tasks_id_fk" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_category_id_categories_id_fk" FOREIGN KEY ("category_id") REFERENCES "public"."categories"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_schedule_id_schedules_id_fk" FOREIGN KEY ("schedule_id") REFERENCES "public"."schedules"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "calendars_account_google_idx" ON "calendars" USING btree ("account_id","google_id");--> statement-breakpoint
CREATE UNIQUE INDEX "events_calendar_google_idx" ON "events" USING btree ("calendar_id","google_id");--> statement-breakpoint
CREATE INDEX "events_updated_at_idx" ON "events" USING btree ("updated_at");--> statement-breakpoint
CREATE INDEX "tasks_updated_at_idx" ON "tasks" USING btree ("updated_at");