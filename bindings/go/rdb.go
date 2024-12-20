package rdb

/*
#cgo CFLAGS: -g -Wall
#cgo linux,arm64 LDFLAGS: ${SRCDIR}/pkg/native/aarch64-linux/librdb.a
#cgo linux,amd64 LDFLAGS: ${SRCDIR}/pkg/native/x86_64-linux/librdb.a
#cgo windows,amd64 LDFLAGS: -L${SRCDIR}/pkg/native/x86_64-windows -lrbd
#cgo darwin,arm64 LDFLAGS: ${SRCDIR}/pkg/native/aarch64-macos/librdb.a
#cgo darwin,amd64 LDFLAGS: ${SRCDIR}/pkg/native/x86_64-macos/librdb.a

#include <stdlib.h>
#include "./pkg/native/rdb.h"
*/
import "C"
import (
	"errors"
	"unsafe"
)

type ErrNotFound struct{}

func (ErrNotFound) Error() string {
	return "not found"
}

// This bytes are allocated on the C side.
// Keep the original value unmodified so the Free function works as intended
type AllocatedBytes struct {
	Bytes []byte
}

func (b *AllocatedBytes) Free() {}

func toCBytes(str []byte) C.struct_Bytes {
	ptr := unsafe.Pointer(&str[0])
	length := len(str)
	return C.struct_Bytes{
		ptr: (*C.char)(ptr),
		len: C.uint64_t(length),
	}
}

func fromCBytes(b C.struct_Bytes) []byte {
	return C.GoBytes(unsafe.Pointer(b.ptr), C.int(b.len))
}

type Database struct {
	pointer unsafe.Pointer
}

func New(path []byte) (Database, error) {
	r := C.rdb_open(toCBytes(path))
	if r.error != nil {
		return Database{}, errors.New(C.GoString(r.error))
	}
	return Database{pointer: r.database}, nil

}

func (db Database) Set(key []byte, value []byte) bool {
	return bool(C.rdb_set(db.pointer, toCBytes(key), toCBytes(value)))
}

func (db Database) Get(key []byte) (AllocatedBytes, error) {
	ret := C.rdb_get(db.pointer, toCBytes(key))
	if !ret.valid {
		return AllocatedBytes{}, ErrNotFound{}
	}
	return AllocatedBytes{Bytes: fromCBytes(ret.bytes)}, nil
}

func (db Database) Remove(key []byte) bool {
	return bool(C.rdb_remove(db.pointer, toCBytes(key)))
}

func (db Database) Close() {
	C.rdb_close(db.pointer)
}
