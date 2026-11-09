CREATE TABLE "routine_blocks" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"days" jsonb NOT NULL,
	"start_time" text NOT NULL,
	"end_time" text NOT NULL,
	"allows" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "settings" (
	"id" text PRIMARY KEY NOT NULL,
	"time_zone" text NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "categories" ADD COLUMN "area" text;--> statement-breakpoint
ALTER TABLE "tasks" ADD COLUMN "context" text DEFAULT 'computer' NOT NULL;--> statement-breakpoint
UPDATE "task_recurrences" SET "template" = "template" || '{"context":"computer"}'::jsonb WHERE NOT ("template" ? 'context');