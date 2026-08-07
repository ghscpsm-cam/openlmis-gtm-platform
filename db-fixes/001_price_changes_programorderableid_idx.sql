CREATE INDEX CONCURRENTLY IF NOT EXISTS price_changes_programorderableid_idx
ON referencedata.price_changes (programorderableid);
