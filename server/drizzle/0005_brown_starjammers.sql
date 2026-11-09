CREATE TABLE "optional_placements" (
	"id" text PRIMARY KEY NOT NULL,
	"task_id" text NOT NULL,
	"block_id" text NOT NULL,
	"start_at" timestamp with time zone NOT NULL,
	"end_at" timestamp with time zone NOT NULL,
	"computed_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
ALTER TABLE "routine_blocks" ADD COLUMN "optional" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "optional_placements" ADD CONSTRAINT "optional_placements_task_id_tasks_id_fk" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE cascade ON UPDATE no action;