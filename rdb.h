struct Result
{
    void* database;
    char* error;
};

struct Result create(char* path);
bool insert(struct DB* const a0, char* key, char* value);
bool update(struct DB* const a0, char* key, char* value);
bool delete(struct DB* const a0, char* key);
