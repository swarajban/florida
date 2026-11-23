ALTER TABLE "later_items" ADD COLUMN "enriched_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "plan_summary" ADD COLUMN "catch_up_blocks" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "settings" ADD COLUMN "catch_up" jsonb DEFAULT '{"enabled":true,"minutes":30,"windows":[{"days":[0,1,2,3,4,5,6],"start":"18:00","end":"21:00"}]}'::jsonb NOT NULL;