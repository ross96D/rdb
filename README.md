# Summary
key-value database, embeddable and single file only with in-memory keys that points to the values on disk.

The database always append to underlying file to avoid complexity and gain performance. This approach has the downside of accumulating garbage, to solve this a background process is run from time to time to cleanup the garbage
