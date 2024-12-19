// TODO Create logging system similar to std.log.scoped but with out std_options dependency
// TODO Create an action tracking system, contributes to the below TODO
// TODO To improve the cases where a fail occurs we need to implement a diagnostic pattern

const std = @import("std");
const builtin = @import("builtin");
const zart = @import("zart");
const utils = @import("utils.zig");

const Owned = utils.Owned;
const bytes = []const u8;
const Atomic = std.atomic.Value;

const assert = struct {
    fn _assert(ok: bool, comptime fmt: []const u8, args: anytype) void {
        if (!ok) {
            std.debug.print(fmt ++ "\n", args);
            unreachable;
        }
    }
}._assert;

pub const Scope = enum {
    ReduceFile,
    GC,

    pub fn get(self: Scope) @Type(.EnumLiteral) {
        const all = comptime &[_]@Type(.EnumLiteral){ .ReduceFile, .GC };
        for (all) |a| {
            if (std.mem.eql(u8, @tagName(a), @tagName(self))) {
                return a;
            }
        }
        @compileError("scope not found on literals " ++ @tagName(self));
    }

    pub fn log(self: Scope) type {
        return std.log.scoped(self.get());
    }
};

const METADATA_SIZE = 1 << 12;

pub const DB = struct {
    path: bytes,
    allocator: std.mem.Allocator,

    tree: zart.Tree(DataPtr),

    file: std.fs.File,
    file_end_pos: Atomic(u64),

    db_mut: *std.Thread.RwLock,
    deinit_mut: *std.Thread.RwLock,

    gc_data: *GC,

    const GC = struct {
        prev_pos: Atomic(u64) = Atomic(u64).init(0),
        collecting: std.Thread.Mutex = .{},
        _deleted: ?std.ArrayList(bytes) = null,
        _deleted_mut: std.Thread.Mutex = .{},
        has_delete: Atomic(bool) = Atomic(bool).init(false),

        fn deleted(self: *GC) ?*std.ArrayList(bytes) {
            self._deleted_mut.lock();
            defer self._deleted_mut.unlock();
            if (self._deleted) |*d| {
                return d;
            }
            return null;
        }
        fn set_deleted(self: *GC, list: ?std.ArrayList(bytes)) void {
            self._deleted_mut.lock();
            defer self._deleted_mut.unlock();
            self._deleted = list;
        }
    };

    const DataPtr = struct {
        pos: u64,
        size: u64,
        owned: bool,
    };

    const Entry = struct {
        key: []const u8,
        value: []const u8 = undefined,
        value_size: u64,
        pos: u64,
        active: bool,
        file_end_pos: usize,
    };

    pub fn init(allocator: std.mem.Allocator, path: bytes) !DB {
        const tree = zart.Tree(DataPtr).init(allocator);
        var db: DB = .{
            .path = path,
            .allocator = allocator,
            .tree = tree,
            .file = undefined,
            .file_end_pos = undefined,
            .gc_data = undefined,
            .db_mut = undefined,
            .deinit_mut = undefined,
        };
        errdefer db.deinit();

        db.gc_data = try db.allocator.create(GC);
        db.gc_data.* = GC{};

        db.db_mut = try db.allocator.create(std.Thread.RwLock);
        db.db_mut.* = .{};
        db.deinit_mut = try db.allocator.create(std.Thread.RwLock);
        db.deinit_mut.* = .{};

        // TODO add diagnostic for better error logging?
        try db.start();
        return db;
    }

    fn is_closed(self: *DB) bool {
        return @intFromPtr(self.gc_data) == @sizeOf(DB);
    }
    fn assert_open(self: *DB) !void {
        if (self.is_closed()) {
            return error.ClosedDB;
        }
    }

    pub fn deinit(self: *DB) void {
        self.gc_data.collecting.lock();
        self.deinit_mut.lock();

        self.tree_deinit();
        self.allocator.destroy(self.gc_data);
        self.allocator.destroy(self.db_mut);
        self.allocator.destroy(self.deinit_mut);
        self.gc_data = @ptrFromInt(@sizeOf(DB));
    }

    fn tree_deinit(self: *DB) void {
        self.tree.deinit();
    }

    fn start(self: *DB) !void {
        const cwd = std.fs.cwd();
        _ = cwd.statFile(self.path) catch {
            const _mode = if (builtin.os.tag == .windows) 0 else 0o644;
            const file = try cwd.createFile(self.path, .{ .mode = _mode });
            const buff: [METADATA_SIZE]u8 = std.mem.zeroes([METADATA_SIZE]u8);
            const n = try file.write(&buff);
            std.debug.assert(n == METADATA_SIZE);
            file.close();
        };

        self.file = try cwd.openFile(self.path, .{ .mode = .read_write, .lock = .shared });

        try _create_tree(self.allocator, self.file, &self.tree);

        // TODO inside the config it could be saved the gc_prev_pos
        self.file_end_pos.store(try self.file.getEndPos(), .release);
        // set gc_prev_pos
        self.gc_data.prev_pos.store(try self.file.getEndPos(), .release);
    }

    fn _create_tree(allocator: std.mem.Allocator, file: std.fs.File, tree: *zart.Tree(DataPtr)) !void {
        try file.seekTo(METADATA_SIZE);
        while (true) {
            const entry = _read_key_value(allocator, file, false) catch |err| {
                if (err == error.EOF) {
                    break;
                } else {
                    return err;
                }
            };
            // TODO this should be done inside _read_key_value to avoid allocations
            if (!entry.active) {
                allocator.free(entry.key);
                continue;
            }
            _ = tree.set(entry.key, .{
                .owned = true,
                .pos = entry.pos,
                .size = entry.value_size,
            });
        }
    }

    const SetConfig = struct { own: bool = false };
    pub fn set(self: *DB, key: bytes, value: bytes, config: SetConfig) !void {
        try assert_open(self);
        if (!self.deinit_mut.tryLockShared()) {
            return error.ClosedDB;
        }
        defer self.deinit_mut.unlockShared();

        self.db_mut.lock();
        defer self.db_mut.unlock();

        const result = self.tree.get(key);

        if (result) |dataptr| {
            // const entry = result.found;
            if (value.len == dataptr.size) {
                return self._inplace_update(value, dataptr);
            }
            const pos = dataptr.pos;

            // remove older entry
            try self.file.seekTo(pos);
            const n = try self.file.write(&[1]u8{0});
            assert(n == 1, "expected 1 got {d}", .{n});

            try _insert(self, key, value, config);
        } else {
            try _insert(self, key, value, config);
        }
        // TODO for a more robust system, diagnostic pattern comes great in this case
        self.gc_check() catch {};
    }

    fn _insert(self: *DB, key: bytes, value: bytes, config: SetConfig) !void {
        const entry = try self.append(key, value);
        _ = self.tree.set(key, .{
            .owned = config.own,
            .size = entry.value_size,
            .pos = entry.pos,
        });
    }

    fn _inplace_update(self: *DB, value: bytes, data: DataPtr) !void {
        var pos = data.pos;
        // pass the active byte
        pos += 1;
        // pass the value size
        pos += 8;
        try self.file.seekTo(pos);
        const n = try self.file.write(value);
        assert(n == value.len, "update value expected {d} got {d}", .{ value.len, n });
    }

    pub fn search(self: *DB, key: bytes) !?Owned(bytes) {
        try assert_open(self);
        if (!self.deinit_mut.tryLockShared()) {
            return error.ClosedDB;
        }
        defer self.deinit_mut.unlockShared();

        self.db_mut.lockShared();
        defer self.db_mut.unlockShared();

        const result = self.tree.get(key);

        if (result) |dataptr| {
            // const dataptr = v.value;
            try self.file.seekTo(dataptr.pos + 1);

            var sizebuff: [8]u8 = undefined;
            var n = try self.file.read(&sizebuff);
            assert(n == 8, "expected 8 got {d}", .{n});
            const size = std.mem.readInt(u64, &sizebuff, .little);

            const value = try self.allocator.alloc(u8, size);
            n = try self.file.read(value);
            assert(n == size, "expected {d} got {d}", .{ size, n });

            return Owned(bytes).init(self.allocator, value);
        }
        return null;
    }

    pub fn delete(self: *DB, key: bytes) !void {
        try assert_open(self);
        if (!self.deinit_mut.tryLockShared()) {
            return error.ClosedDB;
        }
        defer self.deinit_mut.unlockShared();

        self.db_mut.lock();
        defer self.db_mut.unlock();

        const dataptr = self.tree.delete(key) orelse return;
        self.gc_data.has_delete.store(true, .release);

        try self.file.seekTo(dataptr.pos);
        // set the active byte to false
        _ = try self.file.write(&[_]u8{0});
        if (self.gc_data.deleted()) |deleted| {
            deleted.append(key) catch unreachable;
        }
    }

    /// reads a key value entry on the file on the current position
    /// if the read_value is true the caller should deallocate entry.value
    ///
    /// the caller must ensure the synchronous access to the file
    fn readKeyValue(self: *DB, read_value: bool) !Entry {
        return _read_key_value(self.allocator, self.file, read_value);
    }

    /// reads a key value entry on the file on the current position
    /// if the read_value is true the caller should deallocate entry.value
    ///
    /// the caller must ensure the synchronous access to the file
    fn _read_key_value(allocator: std.mem.Allocator, file: std.fs.File, read_value: bool) !Entry {
        const endPos = try file.getEndPos();

        var result: Entry = undefined;
        var key_size_buff: [8]u8 = undefined;
        var key_size: u64 = undefined;
        var active_buff: [1]u8 = undefined;
        var value_size_buff: [8]u8 = undefined;

        // read key size
        var n = try file.read(&key_size_buff);
        if (n == 0) {
            return error.EOF;
        }

        key_size = std.mem.readInt(u64, &key_size_buff, .little);
        std.debug.assert(key_size > 0 and key_size <= endPos);

        result.key = try allocator.alloc(u8, key_size);
        errdefer allocator.free(result.key);
        // read key
        n = try file.read(@constCast(result.key));
        assert(n == result.key.len, "expected {d} got {d} curr {d} end {d}", .{ result.key.len, n, try file.getPos(), try file.getEndPos() });

        result.pos = try file.getPos();
        // read active
        n = try file.read(&active_buff);
        if (n == 0) {
            return error.UnexpectedEOF;
        }
        result.active = active_buff[0] > 0;

        // value size
        n = try file.read(&value_size_buff);
        if (n == 0) {
            return error.UnexpectedEOF;
        }

        result.value_size = std.mem.readInt(u64, &value_size_buff, .little);
        std.debug.assert(result.value_size > 0 and result.value_size <= endPos);

        if (read_value) {
            // read value
            result.value = try allocator.alloc(u8, result.value_size);
            errdefer allocator.free(result.key);
            n = try file.read(@constCast(result.value));
            assert(n == result.value.len, "expected {d} got {d}", .{ result.value.len, n });
        } else {
            // move offset to end of value
            try file.seekBy(@intCast(result.value_size));
        }
        return result;
    }

    /// append data to the end of the file
    fn append(self: *DB, key: bytes, value: bytes) !Entry {
        const entry = try DB._append(self.file, key, value);
        self.file_end_pos.store(entry.file_end_pos, .release);
        return entry;
    }

    /// caller must ensure sync access to the file
    fn _append(file: std.fs.File, key: bytes, value: bytes) !DB.Entry {
        var result: DB.Entry = .{
            .value_size = value.len,
            .key = key,
            .active = true,
            .pos = undefined,
            .file_end_pos = 0,
        };

        const end = try file.getEndPos();
        try file.seekTo(end);
        result.file_end_pos = end;

        // write key size
        var key_size: [8]u8 = undefined;
        std.mem.writeInt(u64, &key_size, key.len, .little);
        var n = try file.write(&key_size);
        std.debug.assert(n == 8);
        result.file_end_pos += n;

        // write key
        n = try file.write(key);
        std.debug.assert(n == key.len);
        result.file_end_pos += n;

        result.pos = try file.getPos();
        // write active byte
        n = try file.write(&[_]u8{1});
        std.debug.assert(n == 1);
        result.file_end_pos += n;

        // write value size
        var value_size: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_size, value.len, .little);
        n = try file.write(&value_size);
        std.debug.assert(n == 8);
        result.file_end_pos += n;

        // write value
        n = try file.write(value);
        std.debug.assert(n == value.len);
        result.file_end_pos += n;

        return result;
    }

    fn gc_check(self: *DB) !void {
        const end_pos = self.file_end_pos.load(.acquire);
        const gc_prev_pos = self.gc_data.prev_pos.load(.acquire);
        if (end_pos < 2 * gc_prev_pos or !self.gc_data.has_delete.load(.acquire)) {
            return;
        }
        const thread = try std.Thread.spawn(.{}, DB.gc, .{self});
        thread.detach();
    }

    fn gc(self: *DB) void {
        if (!self.gc_data.collecting.tryLock()) {
            return;
        }
        self.gc_data.set_deleted(std.ArrayList(bytes).init(self.allocator));
        // TODO handle errors
        _gc(self) catch |err| {
            @panic(std.fmt.allocPrint(self.allocator, "{}", .{err}) catch unreachable);
        };
    }

    fn _gc(self: *DB) !void {
        // TODO for a more robust system, diagnostic pattern maybe is a good choice in this case
        const cwd = std.fs.cwd();

        defer self.gc_data.collecting.unlock();

        var tempDir = utils.tempDir() catch unreachable;
        defer tempDir.close();

        const prefix_old = "rdb_old_";
        const prefix_new = "rdb_new_";
        var old_filename: [32]u8 = undefined;
        var new_filename: [32]u8 = undefined;

        @memcpy(old_filename[0..8], prefix_old);
        var word = utils.randomWord(24);
        @memcpy(old_filename[8..], word);

        @memcpy(new_filename[0..8], prefix_new);
        word = utils.randomWord(24);
        @memcpy(new_filename[8..], word);

        self.db_mut.lock();
        std.fs.cwd().copyFile(self.path, tempDir, &old_filename, .{}) catch unreachable;
        self.db_mut.unlock();
        defer tempDir.deleteFile(&old_filename) catch {};

        const old_file = tempDir.openFile(&old_filename, .{}) catch unreachable;
        const new_file = tempDir.createFile(&new_filename, .{}) catch unreachable;
        defer tempDir.deleteFile(&new_filename) catch {};

        defer old_file.close();
        defer new_file.close();

        // TODO handle error
        try reduce_file(old_file, new_file);

        self.db_mut.lock();
        defer self.db_mut.unlock();

        const self_end = try self.file.getEndPos();
        const old_end = try old_file.getEndPos();
        if (self_end > old_end) {
            try self.file.seekTo(old_end);
            while (true) {
                const entry_old = self.readKeyValue(true) catch |err| {
                    if (err == error.EOF) {
                        break;
                    } else {
                        return err;
                    }
                };
                _ = try _append(new_file, entry_old.key, entry_old.value);
                self.allocator.free(entry_old.value);
            }
        }

        self.file.close();
        std.fs.cwd().deleteFile(self.path) catch {};
        try tempDir.copyFile(&new_filename, std.fs.cwd(), self.path, .{});

        self.file = try cwd.openFile(self.path, .{ .mode = .read_write, .lock = .shared });
        self.gc_data.prev_pos.store(try self.file.getEndPos(), .release);

        // create tree
        var tree = zart.Tree(DataPtr).init(self.allocator);
        try DB._create_tree(self.allocator, self.file, &tree);
        // change trees
        self.tree_deinit();
        self.tree = tree;

        const deleted = self.gc_data.deleted().?;
        defer deleted.deinit();
        self.gc_data.set_deleted(null);
        self.gc_data.has_delete.store(false, .release);

        for (deleted.items) |key| {
            const result = self.tree.delete(key);
            if (result) |dataptr| {
                try self.file.seekTo(dataptr.pos);
                // set the active byte to false
                _ = try self.file.write(&[_]u8{0});
            }
        }
    }

    fn reduce_file(old_file: std.fs.File, new_file: std.fs.File) !void {
        const old_end_pos = try old_file.getEndPos();

        var n = try old_file.copyRange(0, new_file, 0, METADATA_SIZE);
        assert(n == METADATA_SIZE, "expected {d} got {d}", .{ METADATA_SIZE, n });
        try old_file.seekTo(METADATA_SIZE);

        var old_pos: u64 = METADATA_SIZE;
        var new_pos: u64 = METADATA_SIZE;
        var size_buf: [8]u8 = undefined;
        var size: u64 = undefined;
        var active: [1]u8 = undefined;
        while (old_pos < old_end_pos) {
            var advanced: u64 = 0;

            n = try old_file.read(&size_buf);
            advanced += 8;
            assert(n == 8, "expected 8 got {d} curr {d} end {d}\n", .{ n, try old_file.getPos(), try old_file.getEndPos() });

            size = std.mem.readInt(u64, &size_buf, .little);
            assert(size > 0 and size <= old_end_pos, "expected (0 < x < {d}) got {d} old pos {d}\n", .{ old_end_pos, size, old_pos });
            try old_file.seekBy(@intCast(size));
            advanced += size;

            n = try old_file.read(&active);
            assert(n == 1, "expected 1 got {d} curr {d} end {d}\n", .{ n, try old_file.getPos(), try old_file.getEndPos() });
            advanced += 1;

            n = try old_file.read(&size_buf);
            assert(n == 8, "expected 8 got {d} curr {d} end {d}\n", .{ n, try old_file.getPos(), try old_file.getEndPos() });
            advanced += 8;
            size = std.mem.readInt(u64, &size_buf, .little);
            assert(size > 0 and size <= old_end_pos, "expected (0 < x < {d}) got {d}\n", .{ old_end_pos, size });
            advanced += size;

            if (active[0] > 0) {
                // active true
                // this can write less than advanced TODO handle this case
                n = try old_file.copyRange(old_pos, new_file, new_pos, advanced);
                assert(n == advanced, "expected {d} got {d}\n", .{ advanced, n });
                new_pos += n;
            } else {
                // active false
            }
            old_pos += advanced;
            // on windows copyRange move the file cursor so this check fails. TODO check on windows too
            if (builtin.mode == .Debug and builtin.os.tag == .linux) {
                const currpos = try old_file.getPos();
                assert(currpos + size == old_pos, "current pos + size {d} old_pos updated {d}\n", .{ currpos + size, old_pos });
            }
            try old_file.seekTo(old_pos);
        }
    }
};

const mode = builtin.mode;
const jdz = @import("jdz_allocator");

pub const testing_allocator = allocator_instance.allocator();
var allocator_instance = switch (mode) {
    .Debug => std.heap.GeneralPurposeAllocator(.{}){},
    .ReleaseFast => std.heap.GeneralPurposeAllocator(.{}){},
    .ReleaseSmall => std.heap.GeneralPurposeAllocator(.{}){},
    .ReleaseSafe => std.heap.GeneralPurposeAllocator(.{}){},
};
test "insert-update-search" {
    var db = try DB.init(testing_allocator, "insert-search_test_file");
    defer std.fs.cwd().deleteFile("insert-search_test_file") catch unreachable;

    try db.set("key1", "val1", .{});
    try db.set("key2", "val2", .{});
    if (try db.search("key1")) |v| {
        try std.testing.expectEqualDeep(v.value, "val1");
        v.deinit();
    } else {
        return error.KeyNotFound;
    }
    if (try db.search("key2")) |v| {
        try std.testing.expectEqualDeep(v.value, "val2");
        v.deinit();
    } else {
        return error.KeyNotFound;
    }

    try db.set("key1", "v1", .{});
    try db.set("key2", "v2", .{});
    if (try db.search("key1")) |v| {
        try std.testing.expectEqualDeep(v.value, "v1");
        v.deinit();
    } else {
        return error.KeyNotFound;
    }
    if (try db.search("key2")) |v| {
        try std.testing.expectEqualDeep(v.value, "v2");
        v.deinit();
    } else {
        return error.KeyNotFound;
    }

    db.deinit();
}

fn fuzzy_writes(path: []const u8) !void {
    std.debug.print("fuzzy test writes {s}\n", .{path});
    var db = try DB.init(testing_allocator, path);
    defer db.deinit();
    defer std.fs.cwd().deleteFile(path) catch unreachable;

    const now = std.time.microTimestamp();

    var DefaultPrng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        std.debug.print("seed {d}\n", .{seed});
        break :blk seed;
    });
    const rand = DefaultPrng.random();

    const Values = struct {
        key: std.ArrayList(u8) = std.ArrayList(u8).init(testing_allocator),
        val: std.ArrayList(u8) = std.ArrayList(u8).init(testing_allocator),
    };
    var vals = std.ArrayList(Values).init(testing_allocator);
    defer vals.deinit();
    defer {
        for (vals.items) |v| {
            v.key.deinit();
            v.val.deinit();
        }
    }

    for (0..50_000) |_| {
        var key: [30]u8 = undefined;
        @memcpy(&key, utils.createRandomWord(30, rand));
        var value: [30]u8 = undefined;
        @memcpy(&value, utils.createRandomWord(30, rand));

        try db.set(&key, &value, .{});

        if (rand.boolean()) {
            try db.delete(&key);
            continue;
        }

        var keyA = std.ArrayList(u8).init(testing_allocator);
        try keyA.appendSlice(&key);

        var valA = std.ArrayList(u8).init(testing_allocator);
        try valA.appendSlice(&value);
        try vals.append(.{ .key = keyA, .val = valA });
    }

    for (vals.items, 0..) |v, index| {
        const key: []const u8 = v.key.items;
        const actualN = try db.search(key);
        if (actualN) |actual| {
            try std.testing.expectEqualDeep(actual.value, v.val.items);
            actual.deinit();
        } else {
            std.debug.print("key {s} not found index {d} searched key {s}\n", .{ v.key.items, index, key });
            std.debug.print("is eql {}\n", .{std.mem.eql(u8, v.key.items, key)});
            return error.KeyNotFound;
        }
    }

    std.debug.print("elapsed {d} microseconds\n", .{std.time.microTimestamp() - now});
}

test "fuzzy test writes" {
    try fuzzy_writes("fuzzy_temp_database_test_file");
}

test "fuzzy parallel test writes" {
    var db = try DB.init(testing_allocator, "parallel_temp_database_test_file");
    defer std.fs.cwd().deleteFile("parallel_temp_database_test_file") catch unreachable;
    defer db.deinit();

    const now = std.time.microTimestamp();

    const Values = struct {
        key: std.ArrayList(u8) = std.ArrayList(u8).init(testing_allocator),
        val: std.ArrayList(u8) = std.ArrayList(u8).init(testing_allocator),
    };
    var vals = std.ArrayList(Values).init(testing_allocator);
    defer vals.deinit();
    defer {
        for (vals.items) |v| {
            v.key.deinit();
            v.val.deinit();
        }
    }

    // std.ArrayList
    var mut = std.Thread.Mutex{};

    const insert = struct {
        fn insert(
            Mut: *std.Thread.Mutex,
            Db: *DB,
            Vals: *std.ArrayList(Values),
            start: usize,
            end: usize,
        ) !void {
            var DefaultPrng = std.Random.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.posix.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });
            const Rand = DefaultPrng.random();

            for (start..end) |_| {
                var key: [30]u8 = undefined;
                var value: [30]u8 = undefined;
                @memcpy(&key, utils.createRandomWordZ(30, Rand));
                @memcpy(&value, utils.createRandomWord(30, Rand));

                try Db.set(&key, &value, .{});

                if (Rand.boolean()) {
                    try Db.delete(&key);
                    continue;
                }

                var keyA = std.ArrayList(u8).init(testing_allocator);
                try keyA.appendSlice(&key);

                var valA = std.ArrayList(u8).init(testing_allocator);
                try valA.appendSlice(&value);

                Mut.lock();
                try Vals.append(.{ .key = keyA, .val = valA });
                Mut.unlock();
            }
        }
    }.insert;

    const t0 = try std.Thread.spawn(.{}, insert, .{ &mut, &db, &vals, 0, 1000 });
    const t1 = try std.Thread.spawn(.{}, insert, .{ &mut, &db, &vals, 1000, 2000 });
    const t2 = try std.Thread.spawn(.{}, insert, .{ &mut, &db, &vals, 2000, 3000 });
    const t3 = try std.Thread.spawn(.{}, insert, .{ &mut, &db, &vals, 3000, 4000 });
    const t4 = try std.Thread.spawn(.{}, insert, .{ &mut, &db, &vals, 4000, 5000 });
    const t5 = try std.Thread.spawn(.{}, insert, .{ &mut, &db, &vals, 5000, 6000 });
    const t6 = try std.Thread.spawn(.{}, insert, .{ &mut, &db, &vals, 6000, 7000 });
    const t7 = try std.Thread.spawn(.{}, insert, .{ &mut, &db, &vals, 7000, 8000 });
    const t8 = try std.Thread.spawn(.{}, insert, .{ &mut, &db, &vals, 8000, 9000 });
    const t9 = try std.Thread.spawn(.{}, insert, .{ &mut, &db, &vals, 9000, 10000 });
    t0.join();
    t1.join();
    t2.join();
    t3.join();
    t4.join();
    t5.join();
    t6.join();
    t7.join();
    t8.join();
    t9.join();

    for (vals.items, 0..) |v, index| {
        const key: []const u8 = v.key.items;
        const actualN = try db.search(key);
        if (actualN) |actual| {
            try std.testing.expectEqualDeep(actual.value, v.val.items);
            actual.deinit();
        } else {
            std.debug.print("key {s} not found index {d}\n", .{ v.key.items, index });
            return error.KeyNotFound;
        }
    }

    std.debug.print("parallel elapsed {d} microseconds\n", .{std.time.microTimestamp() - now});
}

test "write file" {
    std.debug.print("Write file test\n", .{});
    var db = try DB.init(testing_allocator, "temp_database_test_file");
    defer std.fs.cwd().deleteFile("temp_database_test_file") catch unreachable;
    defer db.deinit();

    try db.set("key1", "val1", .{});
    try db.set("key2", "val2", .{});
    try db.set("key3", "val3", .{});

    const start_pos = METADATA_SIZE;
    try db.file.seekTo(start_pos);
    const keysize_key_length = 8 + 4;
    const valsize_val_length = 1 + 8 + 4;

    const entry1 = db.readKeyValue(false) catch |err| {
        std.debug.print("read entry1 {}\n", .{err});
        return err;
    };
    const entry2 = db.readKeyValue(false) catch |err| {
        std.debug.print("read entry2 {}\n", .{err});
        return err;
    };
    const entry3 = db.readKeyValue(false) catch |err| {
        std.debug.print("read entry3 {}\n", .{err});
        return err;
    };
    defer db.allocator.free(entry1.key);
    defer db.allocator.free(entry2.key);
    defer db.allocator.free(entry3.key);

    try std.testing.expectEqualDeep(entry1.key, "key1");
    const pos1 = start_pos + keysize_key_length;
    try std.testing.expect(entry1.pos == pos1);
    try std.testing.expect(entry1.value_size == 4);

    try std.testing.expectEqualDeep(entry2.key, "key2");
    const pos2 = pos1 + valsize_val_length + keysize_key_length;
    try std.testing.expect(entry2.pos == pos2);
    try std.testing.expect(entry2.value_size == 4);

    try std.testing.expectEqualDeep(entry3.key, "key3");
    const pos3 = pos2 + valsize_val_length + keysize_key_length;
    try std.testing.expect(entry3.pos == pos3);
    try std.testing.expect(entry3.value_size == 4);
}

test "reduce_file" {
    var db = try DB.init(testing_allocator, "reduce_file_test_file");
    defer db.deinit();
    defer std.fs.cwd().deleteFile("reduce_file_test_file") catch unreachable;

    var delete_list = [_]usize{ 2, 4, 5, 9, 21, 46, 43, 92, 77, 33, 41, 67 };
    std.sort.heap(usize, &delete_list, {}, std.sort.asc(usize));
    const S = struct {
        fn order(context: void, lhs: usize, rhs: usize) std.math.Order {
            _ = context;
            return std.math.order(lhs, rhs);
        }
    };

    for (0..100) |i| {
        const key = try std.fmt.allocPrintZ(testing_allocator, "key{d}", .{i});
        const value = try std.fmt.allocPrint(testing_allocator, "val{d}", .{i});

        try db.set(key, value, .{ .own = true });
    }

    for (delete_list) |i| {
        const key = try std.fmt.allocPrintZ(testing_allocator, "key{d}", .{i});
        try db.delete(key);
        testing_allocator.free(key);
    }

    for (0..100) |i| {
        const key = try std.fmt.allocPrintZ(testing_allocator, "key{d}", .{i});
        const value = try std.fmt.allocPrint(testing_allocator, "val{d}", .{i});
        defer testing_allocator.free(key);
        defer testing_allocator.free(value);

        const actual = try db.search(key);

        if (std.sort.binarySearch(usize, i, &delete_list, {}, S.order) == null) {
            std.testing.expect(actual != null) catch |err| {
                std.debug.print("{s} not found\n", .{key});
                return err;
            };
            defer actual.?.deinit();
            try std.testing.expectEqualDeep(value, actual.?.value);
        } else {
            std.testing.expect(actual == null) catch |err| {
                std.debug.print("{s} was found but should has been deleted\n", .{key});
                return err;
            };
        }
    }

    const new_filepath = "new_reduce_file_test_file";
    const new_file = try std.fs.cwd().createFile(new_filepath, .{});
    defer std.fs.cwd().deleteFile(new_filepath) catch unreachable;

    try DB.reduce_file(db.file, new_file);
    new_file.close();

    var db2 = try DB.init(testing_allocator, new_filepath);
    defer db2.deinit();

    for (0..100) |i| {
        const key = try std.fmt.allocPrintZ(testing_allocator, "key{d}", .{i});
        const value = try std.fmt.allocPrint(testing_allocator, "val{d}", .{i});
        defer testing_allocator.free(key);
        defer testing_allocator.free(value);
        const actual = try db2.search(key);

        if (std.sort.binarySearch(usize, i, &delete_list, {}, S.order) == null) {
            std.testing.expect(actual != null) catch |err| {
                std.debug.print("{s} not found\n", .{key});
                return err;
            };
            defer actual.?.deinit();
            try std.testing.expectEqualDeep(value, actual.?.value);
        } else {
            std.testing.expect(actual == null) catch |err| {
                std.debug.print("{s} was found but should has been deleted\n", .{key});
                return err;
            };
        }
    }
}

test "no losses on shutdown" {
    var db = try DB.init(testing_allocator, "no_losses_on_shutdown");
    defer std.fs.cwd().deleteFile("no_losses_on_shutdown") catch unreachable;

    var keys = std.ArrayList([]u8).init(testing_allocator);
    var values = std.ArrayList([]u8).init(testing_allocator);

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    const iterations = 1000;
    defer arena.deinit();
    for (0..iterations) |i| {
        try keys.append(try std.fmt.allocPrint(arena.allocator(), "key{d}", .{i}));
        try values.append(try std.fmt.allocPrint(arena.allocator(), "val{d}", .{i}));
    }

    var t1 = try std.Thread.spawn(.{}, struct {
        fn f(_db: *DB) void {
            std.time.sleep(10000000);
            _db.deinit();
        }
    }.f, .{&db});

    var count: usize = 0;
    for (0..iterations) |i| {
        std.time.sleep(1);

        db.set(keys.items[i], values.items[i], .{}) catch break;
        count += 1;
    }
    t1.join();

    if (db.set("should_error", "should_error", .{})) {
        return error.NotClosed;
    } else |_| {}

    db = try DB.init(testing_allocator, "no_losses_on_shutdown");
    defer db.deinit();

    for (0..count) |i| {
        const v = try db.search(keys.items[i]) orelse {
            std.debug.print("key not found {s}", .{keys.items[i]});
            return error.NotFound;
        };
        try std.testing.expectEqualDeep(values.items[i], v.value);
    }
    for (count..iterations) |i| {
        try std.testing.expectEqual(null, db.search(keys.items[i]));
    }
}
