CREATE TABLE "briefs" (
	"id" text PRIMARY KEY NOT NULL,
	"kind" text NOT NULL,
	"date" text NOT NULL,
	"headline" text NOT NULL,
	"body" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "day_overrides" (
	"date" text PRIMARY KEY NOT NULL,
	"kind" text NOT NULL,
	"note" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "plan_summary" (
	"id" text PRIMARY KEY NOT NULL,
	"missed" jsonb NOT NULL,
	"capacity" jsonb NOT NULL,
	"computed_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "project_placements" (
	"id" text PRIMARY KEY NOT NULL,
	"project_id" text NOT NULL,
	"week_of" text NOT NULL,
	"start_at" timestamp with time zone NOT NULL,
	"end_at" timestamp with time zone NOT NULL,
	"lane" integer,
	"computed_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "projects" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"status" text DEFAULT 'active' NOT NULL,
	"category_id" text,
	"notes" text,
	"next_step" text,
	"parallel" boolean DEFAULT false NOT NULL,
	"weekly_minutes" integer,
	"sort_order" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "routine_occurrences" (
	"id" text PRIMARY KEY NOT NULL,
	"block_id" text NOT NULL,
	"start_at" timestamp with time zone NOT NULL,
	"end_at" timestamp with time zone NOT NULL,
	"computed_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
ALTER TABLE "placements" ADD COLUMN "lane" integer;--> statement-breakpoint
ALTER TABLE "routine_blocks" ADD COLUMN "alternates" jsonb;--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "project_id" text;--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "attention" text;--> statement-breakpoint
ALTER TABLE "project_placements" ADD CONSTRAINT "project_placements_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "projects" ADD CONSTRAINT "projects_category_id_categories_id_fk" FOREIGN KEY ("category_id") REFERENCES "public"."categories"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "briefs_kind_date_idx" ON "briefs" USING btree ("kind","date");--> statement-breakpoint
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
UPDATE "task_recurrences" SET "template" = "template" || '{"projectId":null}'::jsonb WHERE NOT ("template" ? 'projectId');--> statement-breakpoint
UPDATE "task_recurrences" SET "template" = "template" || '{"attention":null}'::jsonb WHERE NOT ("template" ? 'attention');--> statement-breakpoint
INSERT INTO "routine_blocks" ("id", "name", "days", "start_time", "end_time", "allows", "optional", "alternates")
SELECT 'gym', 'Gym', '[1,4,5]'::jsonb, '15:30', '16:45', '[]'::jsonb, false, '[{"day":2,"start":"09:00","end":"10:15"},{"day":3,"start":"09:00","end":"10:15"}]'::jsonb
WHERE EXISTS (SELECT 1 FROM "routine_blocks" WHERE "id" = 'office-tue')
ON CONFLICT ("id") DO NOTHING;--> statement-breakpoint
UPDATE "routine_blocks" SET "start_time" = '09:00', "updated_at" = now() WHERE "id" = 'office-tue' AND "start_time" = '10:15';
