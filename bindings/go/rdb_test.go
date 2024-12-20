package rdb_test

import (
	"os"
	"testing"

	rdb "github.com/ross96D/rdb-go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func Must[T any](s T, err error) T {
	if err != nil {
		panic(err)
	}
	return s
}

func Get(db rdb.Database, t *testing.T, key string) []byte {
	r, err := db.Get([]byte(key))
	require.NoError(t, err)
	return r.Bytes
}

func TestDatabase(t *testing.T) {
	db, err := rdb.New([]byte("test_db"))
	require.NoError(t, err)
	defer db.Close()
	defer os.Remove("test_db")

	db.Set([]byte("key1"), []byte("value1"))
	db.Set([]byte("key2"), []byte("value2"))
	db.Set([]byte("key3"), []byte("value3"))
	db.Set([]byte("key4"), []byte("value4"))

	assert.Equal(t, []byte("value1"), Get(db, t, "key1"))
	assert.Equal(t, []byte("value2"), Get(db, t, "key2"))
	assert.Equal(t, []byte("value3"), Get(db, t, "key3"))
	assert.Equal(t, []byte("value4"), Get(db, t, "key4"))

	db.Set([]byte("key1"), []byte("val1"))
	db.Set([]byte("key2"), []byte("val2"))
	db.Set([]byte("key3"), []byte("val3"))
	db.Set([]byte("key4"), []byte("val4"))

	assert.Equal(t, []byte("val1"), Get(db, t, "key1"))
	assert.Equal(t, []byte("val2"), Get(db, t, "key2"))
	assert.Equal(t, []byte("val3"), Get(db, t, "key3"))
	assert.Equal(t, []byte("val4"), Get(db, t, "key4"))

	db.Remove([]byte("key1"))
	db.Remove([]byte("key2"))
	db.Remove([]byte("key3"))
	db.Remove([]byte("key4"))

	_, err = db.Get([]byte("key1"))
	assert.Error(t, err)
	_, err = db.Get([]byte("key2"))
	assert.Error(t, err)
	_, err = db.Get([]byte("key3"))
	assert.Error(t, err)
	_, err = db.Get([]byte("key4"))
	assert.Error(t, err)
}
