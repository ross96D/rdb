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

struct Result create(struct Bytes value);

void close(void* db);

struct OptionalBytes search(void* db, struct Bytes value);

bool insert(void* db, struct Bytes value, struct Bytes value);

bool update(void* db, struct Bytes value, struct Bytes value);

bool remove(void* db, struct Bytes value);

