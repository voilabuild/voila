CREATE TABLE IF NOT EXISTS images (
	ref                        TEXT    PRIMARY KEY,
	image_digest               BLOB    NOT NULL,
	merged_root_manifest_chunk BLOB    NOT NULL,
	total_size                 INTEGER NOT NULL,
	chunk_count                INTEGER NOT NULL,
	ingested_ns                INTEGER NOT NULL,
	last_used_ns               INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS layers (
	oci_digest     TEXT    NOT NULL PRIMARY KEY,
	manifest_chunk BLOB    NOT NULL,
	created_ns      INTEGER NOT NULL
);
