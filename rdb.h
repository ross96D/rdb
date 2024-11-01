#include <stdint.h>

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


struct Result create(char* path);
struct Bytes search(void* db, char* key);
bool insert(void* db, char* key, struct Bytes value);
bool update(void* db, char* key, struct Bytes value);
bool delete(void* db, char* key);
