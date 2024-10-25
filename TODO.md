## Requirements

- [ ] Mantain an in-memory list of all keys and his asociated pointer to the data on disk
- [ ] Use a single file as the database
- [ ] Work as an append only for fast writes
- [ ] Create a size reducer mecanism to mantain a sane file size when severals inserts are made
- [ ] Create a synchronization mecanism so only one operation per key is allowed

## Maybe
- [ ] Create a mecanism to know if the file is corrupted (something like having a hash)

## file specification
Assume binary protocol is always little endian 

### parts
1. Fixed size (4KB?). Contains the database metadata and/or configuration.
2. Dynamic size. Contains the key-value pair.
   - 8 byte for the size of the key
   - Key bytes
   - 1 byte that say if the key-value is active. <- the ptr is here
   - 8 byte for the size of the value
   - Value bytes

## reducer mecanism
- save pointer to end of file (EOF_PTR)
- create a copy on a temp file
- on parallel reduce the temp file and create an in-memory key-ptr data structure
- stop operations
- append to temp all data that is after the EOF_PTR on the actual file
- replace the actual file with the temp file
- replace the actual in-memory key-ptr data structure with the newly created one
- restart operations
 
## reducer scheduler
- garbage collector like strategy.