# Summary
key-value database, embedable and single file only with in-memory keys that points to the value on disk.

The database work like an append only file and to avoid a big files of invalid data (cada cierto tiempo se corre una tarea para borrar todos los datos invalidos y actualizar el arbol) 
