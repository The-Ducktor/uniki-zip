//! Simple example of using the in-memory ZIP reader library
//!
//! This example demonstrates:
//! - Loading a ZIP file into memory
//! - Iterating through entries
//! - Decompressing files (both store and deflate)
//! - Accessing file metadata

const std = @import("std");
const zip = @import("zip_test");

pub fn main() !void {
    // Use a general purpose allocator
    const allocator = std.heap.page_allocator;

    // Read the entire ZIP file into memory
    const zip_data = try std.fs.cwd().readFileAlloc(
        allocator,
        "test_deflate.zip",
        10 * 1024 * 1024, // max 10MB
    );
    defer allocator.free(zip_data);

    std.debug.print("Loaded ZIP: {d} bytes\n\n", .{zip_data.len});

    // Initialize the in-memory ZIP reader
    var reader = zip.MemoryZipReader.init(zip_data);

    // Get an iterator for all entries
    var iter = try reader.iterate();

    // Iterate through all entries
    while (try iter.next()) |entry| {
        std.debug.print("📄 {s}\n", .{entry.filename});
        std.debug.print("   Size: {d} bytes", .{entry.uncompressed_size});

        if (entry.compressed_size != entry.uncompressed_size) {
            const ratio = @as(f64, @floatFromInt(entry.compressed_size)) /
                @as(f64, @floatFromInt(entry.uncompressed_size)) * 100.0;
            std.debug.print(" (compressed to {d:.1}%)", .{ratio});
        }
        std.debug.print("\n", .{});

        std.debug.print("   Compression: {s}\n", .{entry.compressionMethodName()});
        std.debug.print("   CRC32: 0x{x:0>8}\n", .{entry.crc32});

        // Skip directories
        if (entry.isDirectory()) {
            std.debug.print("   (directory)\n\n", .{});
            continue;
        }

        // Decompress the file content
        const content = try entry.decompress(&reader, allocator);
        defer allocator.free(content);

        // Show a preview of the content
        const preview_len = @min(80, content.len);
        std.debug.print("   Preview: {s}", .{content[0..preview_len]});

        if (content.len > preview_len) {
            std.debug.print("...\n", .{});
        } else {
            std.debug.print("\n", .{});
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("✅ Successfully read all entries!\n\n", .{});

    // Demonstrate fast lookup using a manifest
    std.debug.print("--- Manifest Lookup Example ---\n", .{});
    var manifest = try reader.buildManifest(allocator);
    defer manifest.deinit();

    // Try to find a file (adjust name based on your ZIP content)
    const search_name = "hello.txt";
    if (manifest.get(search_name)) |entry| {
        const content = try entry.decompress(&reader, allocator);
        defer allocator.free(content);
        std.debug.print("Found '{s}' via manifest! Content: {s}\n", .{ search_name, content });
    } else {
        std.debug.print("'{s}' not found in manifest.\n", .{search_name});
    }
}
