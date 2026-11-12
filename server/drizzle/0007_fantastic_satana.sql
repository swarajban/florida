ALTER TABLE "calendars" ADD COLUMN "blocks_scheduling" boolean DEFAULT true NOT NULL;
--> statement-breakpoint
UPDATE "calendars" SET "blocks_scheduling" = "selected", "updated_at" = now();
