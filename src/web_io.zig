const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

const is_wasm = builtin.target.cpu.arch.isWasm();

extern "env" fn js_now_ms() u64;
extern "env" fn js_random(ptr: [*]u8, len: usize) void;
extern "env" fn js_open_url(ptr: [*]const u8, len: usize) void;
extern "env" fn js_log(ptr: [*]const u8, len: usize) void;

fn now_ms() u64 {
    if (is_wasm) return js_now_ms();
    return 0;
}

fn fill_random(buffer: []u8) void {
    if (is_wasm) {
        js_random(buffer.ptr, buffer.len);
    } else {
        @memset(buffer, 0);
    }
}

fn open_url(url: []const u8) void {
    if (is_wasm) js_open_url(url.ptr, url.len);
}

pub fn log(message: []const u8) void {
    if (is_wasm) js_log(message.ptr, message.len);
}

const fs_entry_max = 128;

const FsEntry = struct {
    path: []u8,
    bytes: []u8,
};

/// On wasm32-freestanding, File.Handle and Dir.Handle are void, so we cannot
/// use handle values to identify open files. Instead, we track the current
/// open file and directory via indices into our state arrays. This works
/// because the app opens one file/dir at a time in a single-threaded context.
pub const State = struct {
    allocator: std.mem.Allocator,
    entries: [fs_entry_max]FsEntry = undefined,
    entry_count: usize = 0,
    current_file_entry: ?usize = null,
    current_file_cursor: u64 = 0,
    current_file_writable: bool = false,
    current_dir_path: ?[]u8 = null,
    next_atomic: u64 = 0,
};

pub var state: State = .{ .allocator = std.heap.page_allocator };

fn selfFrom(userdata: ?*anyopaque) *State {
    return @ptrCast(@alignCast(userdata));
}

fn find_entry(s: *State, path: []const u8) ?usize {
    var index: usize = 0;
    while (index < s.entry_count) : (index += 1) {
        if (std.mem.eql(u8, s.entries[index].path, path)) return index;
    }
    return null;
}

fn add_entry(s: *State, path: []const u8, initial: []const u8) !usize {
    if (s.entry_count == s.entries.len) return error.NoSpaceLeft;
    if (find_entry(s, path)) |index| return index;
    const index = s.entry_count;
    s.entry_count += 1;
    s.entries[index] = .{
        .path = try s.allocator.dupe(u8, path),
        .bytes = try s.allocator.dupe(u8, initial),
    };
    return index;
}

fn make_file() File {
    if (is_wasm) {
        return .{ .handle = {}, .flags = .{ .nonblocking = false } };
    } else {
        return .{ .handle = 0, .flags = .{ .nonblocking = false } };
    }
}

fn make_dir() Dir {
    if (is_wasm) {
        return .{ .handle = {} };
    } else {
        return .{ .handle = 0 };
    }
}

fn seed_file(s: *State, path: []const u8, bytes: []const u8) !void {
    const index = try add_entry(s, path, bytes);
    s.entries[index].bytes = try s.allocator.dupe(u8, bytes);
}

pub fn seed(path: []const u8, bytes: []const u8) !void {
    try seed_file(&state, path, bytes);
}

// ---- group / async / cancel ----

fn wasmGroupConcurrent(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    _ = userdata;
    _ = group;
    _ = context_alignment;
    start(context.ptr);
}

fn wasmGroupAwait(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
    _ = userdata;
    _ = group;
    _ = token;
}

fn wasmGroupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
    _ = userdata;
    _ = group;
    _ = token;
}

fn wasmRecancel(userdata: ?*anyopaque) void {
    _ = userdata;
}

fn wasmSwapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    _ = userdata;
    return new;
}

fn wasmCheckCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    _ = userdata;
}

fn wasmAwait(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    _ = userdata;
    _ = any_future;
    _ = result;
    _ = result_alignment;
}

fn wasmCancel(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    _ = userdata;
    _ = any_future;
    _ = result;
    _ = result_alignment;
}

// ---- file / dir ----

fn wasmDirOpenFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenFileOptions,
) File.OpenError!File {
    _ = dir;
    const s = selfFrom(userdata);
    const index = find_entry(s, sub_path) orelse return error.FileNotFound;
    s.current_file_entry = index;
    s.current_file_cursor = 0;
    s.current_file_writable = options.mode != .read_only;
    return make_file();
}

fn wasmDirCreateFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.CreateFileOptions,
) File.OpenError!File {
    _ = dir;
    _ = options;
    const s = selfFrom(userdata);
    const index = add_entry(s, sub_path, "") catch return error.NoSpaceLeft;
    s.current_file_entry = index;
    s.current_file_cursor = 0;
    s.current_file_writable = true;
    return make_file();
}

fn wasmDirCreateFileAtomic(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.CreateFileAtomicOptions,
) Dir.CreateFileAtomicError!File.Atomic {
    _ = dir;
    _ = options;
    const s = selfFrom(userdata);
    const hex = std.fmt.hex(s.next_atomic);
    s.next_atomic += 1;
    var tmp_buf: [64]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_buf, ".{s}", .{hex}) catch return error.NameTooLong;
    const dir_path = s.current_dir_path orelse "";
    const sep: []const u8 = if (dir_path.len > 0 and dir_path[dir_path.len - 1] == '/') "" else "/";
    const tmp_path = s.allocator.alloc(u8, dir_path.len + sep.len + tmp_name.len) catch return error.SystemResources;
    @memcpy(tmp_path[0..dir_path.len], dir_path);
    @memcpy(tmp_path[dir_path.len..][0..sep.len], sep);
    @memcpy(tmp_path[dir_path.len + sep.len ..], tmp_name);
    const index = add_entry(s, tmp_path, "") catch {
        s.allocator.free(tmp_path);
        return error.SystemResources;
    };
    s.allocator.free(tmp_path);
    s.current_file_entry = index;
    s.current_file_cursor = 0;
    s.current_file_writable = true;
    const atomic: File.Atomic = .{
        .file = make_file(),
        .file_basename_hex = s.next_atomic - 1,
        .file_open = true,
        .file_exists = true,
        .dir = make_dir(),
        .close_dir_on_deinit = false,
        .dest_sub_path = sub_path,
    };
    return atomic;
}

fn wasmDirOpenDir(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenOptions,
) Dir.OpenError!Dir {
    _ = dir;
    _ = options;
    const s = selfFrom(userdata);
    if (s.current_dir_path) |old| s.allocator.free(old);
    s.current_dir_path = s.allocator.dupe(u8, sub_path) catch return error.SystemResources;
    return make_dir();
}

fn wasmDirCreateDirPath(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
) Dir.CreateDirPathError!Dir.CreatePathStatus {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    return .created;
}

fn wasmDirCreateDirPathOpen(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
    options: Dir.OpenOptions,
) Dir.CreateDirPathOpenError!Dir {
    _ = permissions;
    _ = options;
    const s = selfFrom(userdata);
    _ = dir;
    if (s.current_dir_path) |old| s.allocator.free(old);
    s.current_dir_path = s.allocator.dupe(u8, sub_path) catch return error.SystemResources;
    return make_dir();
}

fn wasmDirClose(userdata: ?*anyopaque, dirs: []const Dir) void {
    _ = dirs;
    const s = selfFrom(userdata);
    if (s.current_dir_path) |p| {
        s.allocator.free(p);
        s.current_dir_path = null;
    }
}

fn wasmDirStatFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.StatFileOptions,
) Dir.StatFileError!File.Stat {
    _ = dir;
    _ = options;
    const s = selfFrom(userdata);
    const index = find_entry(s, sub_path) orelse return error.FileNotFound;
    return stat_for(s, index);
}

fn wasmDirDeleteFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
) Dir.DeleteFileError!void {
    _ = dir;
    const s = selfFrom(userdata);
    const index = find_entry(s, sub_path) orelse return error.FileNotFound;
    s.allocator.free(s.entries[index].path);
    s.allocator.free(s.entries[index].bytes);
    var i = index;
    while (i + 1 < s.entry_count) : (i += 1) {
        s.entries[i] = s.entries[i + 1];
    }
    s.entry_count -= 1;
}

fn wasmDirRename(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenameError!void {
    _ = old_dir;
    _ = new_dir;
    const s = selfFrom(userdata);
    const index = find_entry(s, old_sub_path) orelse return error.FileNotFound;
    s.allocator.free(s.entries[index].path);
    s.entries[index].path = s.allocator.dupe(u8, new_sub_path) catch return error.SystemResources;
}

fn wasmDirRenamePreserve(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenamePreserveError!void {
    _ = old_dir;
    _ = new_dir;
    const s = selfFrom(userdata);
    const index = find_entry(s, old_sub_path) orelse return error.FileNotFound;
    s.allocator.free(s.entries[index].path);
    s.entries[index].path = s.allocator.dupe(u8, new_sub_path) catch return error.SystemResources;
}

fn wasmDirAccess(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.AccessOptions,
) Dir.AccessError!void {
    _ = dir;
    _ = options;
    const s = selfFrom(userdata);
    if (find_entry(s, sub_path) == null) return error.FileNotFound;
}

fn stat_for(s: *State, index: usize) File.Stat {
    if (is_wasm) {
        return .{
            .inode = {},
            .nlink = 0,
            .size = s.entries[index].bytes.len,
            .permissions = .default_file,
            .kind = .file,
            .atime = null,
            .mtime = .{ .nanoseconds = 0 },
            .ctime = .{ .nanoseconds = 0 },
            .block_size = 1,
        };
    } else {
        return .{
            .inode = 0,
            .nlink = 1,
            .size = s.entries[index].bytes.len,
            .permissions = .default_file,
            .kind = .file,
            .atime = null,
            .mtime = .{ .nanoseconds = 0 },
            .ctime = .{ .nanoseconds = 0 },
            .block_size = 1,
        };
    }
}

fn wasmFileStat(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    _ = file;
    const s = selfFrom(userdata);
    const index = s.current_file_entry orelse return error.Unexpected;
    return stat_for(s, index);
}

fn wasmFileLength(userdata: ?*anyopaque, file: File) File.LengthError!u64 {
    _ = file;
    const s = selfFrom(userdata);
    const index = s.current_file_entry orelse return error.Unexpected;
    return s.entries[index].bytes.len;
}

fn wasmFileClose(userdata: ?*anyopaque, files: []const File) void {
    _ = files;
    const s = selfFrom(userdata);
    s.current_file_entry = null;
    s.current_file_cursor = 0;
    s.current_file_writable = false;
}

fn wasmFileReadPositional(
    userdata: ?*anyopaque,
    file: File,
    data: []const []u8,
    offset: u64,
) File.ReadPositionalError!usize {
    _ = file;
    const s = selfFrom(userdata);
    const index = s.current_file_entry orelse return error.Unexpected;
    const bytes = s.entries[index].bytes;
    var copied: usize = 0;
    for (data) |item| {
        if (item.len == 0) continue;
        const start = offset + copied;
        if (start >= bytes.len) break;
        const amount = @min(item.len, bytes.len - start);
        @memcpy(item[0..amount], bytes[@intCast(start)..][0..amount]);
        copied += amount;
        if (copied == item.len) continue;
        break;
    }
    return copied;
}

fn wasmFileWritePositional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) File.WritePositionalError!usize {
    _ = file;
    const s = selfFrom(userdata);
    const index = s.current_file_entry orelse return error.Unexpected;
    const entry = &s.entries[index];
    var total: usize = header.len;
    var i: usize = 0;
    while (i < data.len and i < splat) : (i += 1) {
        total += data[i].len;
    }
    const required: u64 = offset + total;
    if (required > entry.bytes.len) {
        entry.bytes = s.allocator.realloc(entry.bytes, @intCast(required)) catch return error.NoSpaceLeft;
    }
    @memcpy(entry.bytes[@intCast(offset)..][0..header.len], header);
    var written: usize = header.len;
    i = 0;
    while (i < data.len and i < splat) : (i += 1) {
        const chunk = data[i];
        @memcpy(entry.bytes[@intCast(offset + written)..][0..chunk.len], chunk);
        written += chunk.len;
    }
    return written;
}

fn wasmFileSeekBy(
    userdata: ?*anyopaque,
    file: File,
    relative_offset: i64,
) File.SeekError!void {
    _ = file;
    const s = selfFrom(userdata);
    if (s.current_file_entry == null) return error.Unexpected;
    const delta: i64 = @intCast(s.current_file_cursor);
    const next = delta + relative_offset;
    if (next < 0) return error.Unseekable;
    s.current_file_cursor = @intCast(next);
}

fn wasmFileSeekTo(
    userdata: ?*anyopaque,
    file: File,
    absolute_offset: u64,
) File.SeekError!void {
    _ = file;
    const s = selfFrom(userdata);
    if (s.current_file_entry == null) return error.Unexpected;
    s.current_file_cursor = absolute_offset;
}

fn wasmFileSync(userdata: ?*anyopaque, file: File) File.SyncError!void {
    _ = userdata;
    _ = file;
}

fn wasmFileSetLength(userdata: ?*anyopaque, file: File, length: u64) File.SetLengthError!void {
    _ = file;
    const s = selfFrom(userdata);
    const index = s.current_file_entry orelse return error.Unexpected;
    const entry = &s.entries[index];
    if (length < entry.bytes.len) {
        entry.bytes = s.allocator.realloc(entry.bytes, @intCast(length)) catch return error.Unexpected;
    } else if (length > entry.bytes.len) {
        const grown = s.allocator.realloc(entry.bytes, @intCast(length)) catch return error.Unexpected;
        @memset(grown[entry.bytes.len..], 0);
        entry.bytes = grown;
    }
}

// ---- operate (streaming read/write) ----

fn wasmOperate(userdata: ?*anyopaque, op: Io.Operation) Io.Cancelable!Io.Operation.Result {
    const s = selfFrom(userdata);
    switch (op) {
        .file_read_streaming => |frs| {
            const result = read_streaming(s, frs) catch |err| return .{ .file_read_streaming = err };
            return .{ .file_read_streaming = result };
        },
        .file_write_streaming => |fws| {
            const result = write_streaming(s, fws) catch |err| return .{ .file_write_streaming = err };
            return .{ .file_write_streaming = result };
        },
        else => return error.Canceled,
    }
}

fn read_streaming(s: *State, op: Io.Operation.FileReadStreaming) Io.Operation.FileReadStreaming.Error!usize {
    _ = op.file;
    const index = s.current_file_entry orelse return error.InputOutput;
    const bytes = s.entries[index].bytes;
    if (s.current_file_cursor >= bytes.len) return 0;
    var copied: usize = 0;
    for (op.data) |item| {
        if (item.len == 0) continue;
        const start: u64 = s.current_file_cursor + copied;
        if (start >= bytes.len) break;
        const amount = @min(@as(u64, item.len), bytes.len - start);
        @memcpy(item[0..@intCast(amount)], bytes[@intCast(start)..][0..@intCast(amount)]);
        copied += @intCast(amount);
    }
    s.current_file_cursor += copied;
    return copied;
}

fn write_streaming(s: *State, op: Io.Operation.FileWriteStreaming) Io.Operation.FileWriteStreaming.Error!usize {
    _ = op.file;
    const index = s.current_file_entry orelse return error.InputOutput;
    const entry = &s.entries[index];
    var total: usize = op.header.len;
    var i: usize = 0;
    while (i < op.data.len and i < op.splat) : (i += 1) {
        total += op.data[i].len;
    }
    const required: u64 = s.current_file_cursor + total;
    if (required > entry.bytes.len) {
        entry.bytes = s.allocator.realloc(entry.bytes, @intCast(required)) catch return error.NoSpaceLeft;
    }
    @memcpy(entry.bytes[@intCast(s.current_file_cursor)..][0..op.header.len], op.header);
    var written: usize = op.header.len;
    i = 0;
    while (i < op.data.len and i < op.splat) : (i += 1) {
        const chunk = op.data[i];
        @memcpy(entry.bytes[@intCast(s.current_file_cursor + written)..][0..chunk.len], chunk);
        written += chunk.len;
    }
    s.current_file_cursor += written;
    return written;
}

// ---- process / time / random ----

fn wasmProcessSpawn(
    userdata: ?*anyopaque,
    options: std.process.SpawnOptions,
) std.process.SpawnError!std.process.Child {
    _ = userdata;
    if (options.argv.len > 1) {
        open_url(options.argv[1]);
    }
    return .{
        .id = null,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .resource_usage_statistics = .{},
        .request_resource_usage_statistics = false,
    };
}

fn wasmChildWait(
    userdata: ?*anyopaque,
    child: *std.process.Child,
) std.process.Child.WaitError!std.process.Child.Term {
    _ = userdata;
    _ = child;
    return .{ .exited = 0 };
}

fn wasmNow(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    _ = userdata;
    _ = clock;
    return .{ .nanoseconds = @intCast(@as(i64, @intCast(now_ms())) * 1_000_000) };
}

fn wasmRandom(userdata: ?*anyopaque, buffer: []u8) void {
    _ = userdata;
    fill_random(buffer);
}

fn wasmRandomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    _ = userdata;
    fill_random(buffer);
}

// ---- vtable ----

var vtable: Io.VTable = undefined;
var vtable_initialized = false;

pub fn io() Io {
    if (!vtable_initialized) {
        init_vtable();
        vtable_initialized = true;
    }
    return .{ .userdata = @ptrCast(&state), .vtable = &vtable };
}

fn init_vtable() void {
    vtable = std.Io.failing.vtable.*;
    vtable.groupConcurrent = wasmGroupConcurrent;
    vtable.groupAwait = wasmGroupAwait;
    vtable.groupCancel = wasmGroupCancel;
    vtable.recancel = wasmRecancel;
    vtable.swapCancelProtection = wasmSwapCancelProtection;
    vtable.checkCancel = wasmCheckCancel;
    vtable.await = wasmAwait;
    vtable.cancel = wasmCancel;

    vtable.operate = wasmOperate;

    vtable.dirOpenFile = wasmDirOpenFile;
    vtable.dirCreateFile = wasmDirCreateFile;
    vtable.dirCreateFileAtomic = wasmDirCreateFileAtomic;
    vtable.dirOpenDir = wasmDirOpenDir;
    vtable.dirCreateDirPath = wasmDirCreateDirPath;
    vtable.dirCreateDirPathOpen = wasmDirCreateDirPathOpen;
    vtable.dirClose = wasmDirClose;
    vtable.dirStatFile = wasmDirStatFile;
    vtable.dirDeleteFile = wasmDirDeleteFile;
    vtable.dirRename = wasmDirRename;
    vtable.dirRenamePreserve = wasmDirRenamePreserve;
    vtable.dirAccess = wasmDirAccess;

    vtable.fileStat = wasmFileStat;
    vtable.fileLength = wasmFileLength;
    vtable.fileClose = wasmFileClose;
    vtable.fileReadPositional = wasmFileReadPositional;
    vtable.fileWritePositional = wasmFileWritePositional;
    vtable.fileSeekBy = wasmFileSeekBy;
    vtable.fileSeekTo = wasmFileSeekTo;
    vtable.fileSync = wasmFileSync;
    vtable.fileSetLength = wasmFileSetLength;

    vtable.processSpawn = wasmProcessSpawn;
    vtable.childWait = wasmChildWait;

    vtable.now = wasmNow;
    vtable.random = wasmRandom;
    vtable.randomSecure = wasmRandomSecure;
}
