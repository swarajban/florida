CREATE TABLE "later_items" (
	"id" text PRIMARY KEY NOT NULL,
	"url" text NOT NULL,
	"canonical_url" text NOT NULL,
	"title" text NOT NULL,
	"site" text NOT NULL,
	"kind" text NOT NULL,
	"est_minutes" integer,
	"saved_at" timestamp with time zone NOT NULL,
	"read_at" timestamp with time zone,
	"archived_at" timestamp with time zone,
	"source" text NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE INDEX "later_items_updated_idx" ON "later_items" USING btree ("updated_at");