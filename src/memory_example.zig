const std = @import("std");
const zip = @import("zip_test");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Pure In-Memory ZIP Reader Demo ===\n\n", .{});

    // Read ZIP file into memory
    const cwd = std.fs.cwd();

    // Try to find the test file in multiple locations
    var zip_filename: []const u8 = "";
    var zip_data: []u8 = undefined;
    var found = false;

    // Try 1: files/c.epub (from project root)
    if (cwd.readFileAlloc(allocator, "files/b.epub", 10 * 1024 * 1024)) |data| {
        zip_filename = "files/b.epub";
        zip_data = data;
        found = true;
    } else |_| {}

    // Try 2: c.epub (from zig-out/bin when running via zig build)
    if (!found) {
        if (cwd.readFileAlloc(allocator, "b.epub", 10 * 1024 * 1024)) |data| {
            zip_filename = "b.epub";
            zip_data = data;
            found = true;
        } else |_| {}
    }

    // Try 3: files/c.epub (if we're in zig-out/bin)
    if (!found) {
        if (cwd.readFileAlloc(allocator, "files/b.epub", 10 * 1024 * 1024)) |data| {
            zip_filename = "files/b.epub";
            zip_data = data;
            found = true;
        } else |_| {}
    }

    if (!found) {
        std.debug.print("Error: Could not find b.epub\n", .{});
        std.debug.print("Please run from the project root or use: zig build run-memory\n", .{});
        return error.FileNotFound;
    }

    defer allocator.free(zip_data);

    std.debug.print("Reading file: {s}\n", .{zip_filename});
    std.debug.print("Loaded ZIP file into memory: {d} bytes\n\n", .{zip_data.len});

    // Create memory ZIP reader using the library API (mutable for EOCD caching)
    var reader = zip.MemoryZipReader.init(zip_data);
    var iter = try reader.iterate();

    std.debug.print("Iterating through ZIP entries:\n", .{});
    std.debug.print("{s}\n", .{"-" ** 60});

    var entry_count: usize = 0;

    while (try iter.next()) |entry| {
        entry_count += 1;
        if (entry_count > 20) {
            std.debug.print("\n... (showing only first 20 entries)\n", .{});
            break;
        }

        std.debug.print("\nFile: {s}\n", .{entry.filename});
        std.debug.print("  Compressed size:   {d} bytes\n", .{entry.compressed_size});
        std.debug.print("  Uncompressed size: {d} bytes\n", .{entry.uncompressed_size});
        std.debug.print("  Compression:       {s}\n", .{entry.compressionMethodName()});
        std.debug.print("  CRC32:             0x{x:0>8}\n", .{entry.crc32});
        std.debug.print("  Is directory:      {}\n", .{entry.isDirectory()});

        // Skip directories
        if (entry.isDirectory()) {
            std.debug.print("  (skipping directory)\n", .{});
            continue;
        }

        // Try to decompress and show content
        const decompressed = entry.decompress(&reader, allocator) catch |err| {
            std.debug.print("  Error decompressing: {}\n", .{err});
            continue;
        };
        defer allocator.free(decompressed);

        std.debug.print("  Content preview:\n", .{});

        // Show first 200 bytes of content
        const preview_len = @min(200, decompressed.len);
        std.debug.print("  {s}", .{decompressed[0..preview_len]});

        if (decompressed.len > preview_len) {
            std.debug.print("... ({d} more bytes)\n", .{decompressed.len - preview_len});
        } else {
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("\n{s}\n", .{"-" ** 60});
    std.debug.print("Done! All data was read from memory without disk I/O.\n", .{});
}
