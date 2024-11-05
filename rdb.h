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

struct Result open(struct Bytes path);

void close(void* db);

struct OptionalBytes get(void* db, struct Bytes key);

bool set(void* db, struct Bytes key, struct Bytes value);

bool remove(void* db, struct Bytes key);

