#include <stdint.h>
#include <stdbool.h>

struct Result
{
    void* database;
    char* error;
};

struct Bytes
{
    char* ptr;
    uint64_t len;
};

struct OptionalBytes
{
    struct Bytes bytes;
    bool valid;
};

struct Result rdb_open(struct Bytes path);

void rdb_close(void* db);

struct OptionalBytes rdb_get(void* db, struct Bytes key);

bool rdb_set(void* db, struct Bytes key, struct Bytes value);

bool rdb_remove(void* db, struct Bytes key);

