# Summary
key-value database, embeddable and single file only with in-memory keys that points to the value on disk.

The database work always append to underlying file to avoid complexity and gain performance. This approach has the downside of accumulating garbage a background process is run from time to time to cleanup the garbage
