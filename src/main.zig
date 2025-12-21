const std = @import("std");
const zip = @import("zip_test");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Example 1: Read ZIP from a file
    std.debug.print("=== Reading ZIP from file (using std.zip) ===\n", .{});
    try readZipFromFile();

    std.debug.print("\n=== Reading ZIP from memory (workaround with temp file) ===\n", .{});
    // Example 2: Read ZIP from memory using temp file workaround
    const cwd = std.fs.cwd();
    const zip_data = try cwd.readFileAlloc(allocator, "files/b.epub", 100 * 1024 * 1024); // max 100MB
    defer allocator.free(zip_data);

    try readZipFromMemory(zip_data);

    std.debug.print("\n=== Reading ZIP from memory (pure in-memory) ===\n", .{});
    // Example 3: Pure in-memory ZIP reading without temp files
    try readZipFromMemoryPure(allocator, zip_data);
}

fn readZipFromFile() !void {
    const cwd = std.fs.cwd();
    const zipFile = try cwd.openFile("files/b.epub", .{});
    defer zipFile.close();

    var buffer: [4096]u8 = undefined;
    var reader = zipFile.reader(&buffer);

    var iter = try std.zip.Iterator.init(&reader);

    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.uncompressed_size == 0) continue;
        count += 1;
        if (count > 3) break; // Just show first 3 entries

        var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const filename_slice = filename_buf[0..entry.filename_len];
        try reader.interface.readSliceAll(filename_slice);

        std.debug.print("  {s} ({d} bytes)\n", .{ filename_slice, entry.uncompressed_size });
    }
}

fn readZipFromMemory(zip_data: []const u8) !void {
    // Unfortunately, std.zip.Iterator expects specifically a *File.Reader
    // which has a different structure in Zig 0.15.2 and is tightly coupled to files

    // The workaround is to use a different approach:
    // We'll create a temporary file or use the file-based approach

    std.debug.print("Note: In Zig 0.15.2, std.zip.Iterator is tightly coupled to File.Reader.\n", .{});
    std.debug.print("For in-memory ZIP reading, you have a few options:\n", .{});
    std.debug.print("  1. Write to a temporary file first\n", .{});
    std.debug.print("  2. Use a third-party library\n", .{});
    std.debug.print("  3. Implement custom ZIP reading logic\n", .{});
    std.debug.print("  4. Use a newer version of Zig with better API support\n", .{});

    // Here's a demonstration of option 1 - write to temp file:
    const cwd = std.fs.cwd();
    const temp_file = try cwd.createFile("temp_zip.zip", .{ .read = true });
    defer {
        temp_file.close();
        cwd.deleteFile("temp_zip.zip") catch {};
    }

    try temp_file.writeAll(zip_data);
    try temp_file.seekTo(0);

    var buffer: [4096]u8 = undefined;
    var reader = temp_file.reader(&buffer);

    var iter = try std.zip.Iterator.init(&reader);

    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.uncompressed_size == 0) continue;
        count += 1;
        if (count > 3) break; // Just show first 3 entries

        var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const filename_slice = filename_buf[0..entry.filename_len];
        try reader.interface.readSliceAll(filename_slice);

        std.debug.print("  {s} ({d} bytes) [from memory]\n", .{ filename_slice, entry.uncompressed_size });
    }
}

fn readZipFromMemoryPure(allocator: std.mem.Allocator, zip_data: []const u8) !void {
    // Use mutable reader for EOCD caching
    var reader = zip.MemoryZipReader.init(zip_data);
    var iter = try reader.iterate();

    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.uncompressed_size == 0) continue;
        count += 1;

        std.debug.print("  {s} ({d} bytes)\n", .{ entry.filename, entry.uncompressed_size });
        std.debug.print("    Compression: {s}\n", .{entry.compressionMethodName()});
        std.debug.print("    Is directory: {}\n", .{entry.isDirectory()});

        // Example: decompress entries (both store and deflate)
        if (count <= 3) {
            const decompressed = entry.decompress(&reader, allocator) catch |err| {
                std.debug.print("    Error decompressing: {}\n", .{err});
                continue;
            };
            defer allocator.free(decompressed);

            // Show first 100 bytes of content
            const preview_len = @min(100, decompressed.len);
            std.debug.print("    Preview: {s}", .{decompressed[0..preview_len]});
            if (decompressed.len > preview_len) {
                std.debug.print("... ({d} more bytes)\n", .{decompressed.len - preview_len});
            } else {
                std.debug.print("\n", .{});
            }
        }

        if (count >= 5) break; // Show first 5 entries
    }
}
