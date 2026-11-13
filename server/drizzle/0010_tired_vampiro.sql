ALTER TABLE "events" ADD COLUMN "auto_blocks_day" boolean;--> statement-breakpoint
ALTER TABLE "events" ADD COLUMN "blocking_reason" text;--> statement-breakpoint
ALTER TABLE "google_accounts" ADD COLUMN "display_name" text;