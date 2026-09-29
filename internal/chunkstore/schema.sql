CREATE TABLE IF NOT EXISTS chunks (
	id           BLOB PRIMARY KEY,
	logical_len  INTEGER NOT NULL,
	stored_len   INTEGER NOT NULL,
	comp_algo    INTEGER NOT NULL,
	created_ns   INTEGER NOT NULL,
	last_access_ns INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS chunks_last_access ON chunks(last_access_ns);
