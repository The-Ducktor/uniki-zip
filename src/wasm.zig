const std = @import("std");
const zip = @import("root.zig");

// Use the WASM page allocator for freestanding environment
const allocator = std.heap.wasm_allocator;

/// Exported function to allocate memory from the host
export fn alloc(len: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Exported function to free memory from the host
export fn free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

/// Example: Get the number of files in a ZIP
export fn get_entry_count(ptr: [*]const u8, len: usize) i32 {
    const data = ptr[0..len];
    const reader = zip.MemoryZipReader.init(data);
    const iter = reader.iterate(allocator) catch return -1;
    return @intCast(iter.total_entries);
}

/// Example: Decompress a file by index
/// Returns a pointer to the data, sets out_len
export fn decompress_entry(zip_ptr: [*]const u8, zip_len: usize, index: usize, out_len: *usize) ?[*]u8 {
    const data = zip_ptr[0..zip_len];
    const reader = zip.MemoryZipReader.init(data);
    var iter = reader.iterate(allocator) catch return null;

    var i: usize = 0;
    while (iter.next() catch return null) |entry| {
        defer entry.deinit(allocator);
        if (i == index) {
            const decompressed = entry.decompress(&reader, allocator) catch return null;
            out_len.* = decompressed.len;
            return decompressed.ptr;
        }
        i += 1;
    }
    return null;
}

// Required for freestanding WASM to handle panics
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = ret_addr;
    while (true) {
        @breakpoint();
    }
}
