//! In-Memory ZIP Reader Library for Zig 0.15.2
//!
//! This library provides a pure in-memory ZIP file reader that doesn't require
//! writing to temporary files or using file handles. It supports both uncompressed
//! (store) and deflate-compressed entries.
//!
//! Example usage:
//! ```zig
//! const std = @import("std");
//! const zip = @import("zip_test");
//!
//! pub fn main() !void {
//!     const allocator = std.heap.page_allocator;
//!
//!     // Load ZIP data into memory
//!     const zip_data = try std.fs.cwd().readFileAlloc(allocator, "files/c.epub", 10 * 1024 * 1024);
//!     defer allocator.free(zip_data);
//!
//!     // Create reader and iterate through entries
//!     var reader = zip.MemoryZipReader.init(zip_data);
//!     var iter = try reader.iterate(allocator);
//!
//!     while (try iter.next()) |entry| {
//!         defer entry.deinit(allocator);
//!
//!         std.debug.print("File: {s}\n", .{entry.filename});
//!
//!         // Decompress the entry
//!         const data = try entry.decompress(&reader, allocator);
//!         defer allocator.free(data);
//!
//!         // Use the decompressed data...
//!     }
//! }
//! ```

const std = @import("std");

/// A pure in-memory ZIP reader that doesn't require File.Reader
/// This implementation reads directly from a byte slice in memory
pub const MemoryZipReader = struct {
    data: []const u8,
    pos: usize = 0,

    /// Initialize a new MemoryZipReader with ZIP data
    pub fn init(data: []const u8) MemoryZipReader {
        return .{ .data = data };
    }

    /// Find the End of Central Directory record
    fn findEndRecord(self: *MemoryZipReader) !EndOfCentralDirectory {
        // The EOCD is at the end of the file, we search backwards
        const min_eocd_size = 22; // minimum size of EOCD record
        if (self.data.len < min_eocd_size) return error.ZipTooSmall;

        // Search for the EOCD signature from the end
        const signature = [4]u8{ 0x50, 0x4b, 0x05, 0x06 }; // PK\x05\x06

        var search_pos: usize = self.data.len - min_eocd_size;
        while (search_pos > 0) : (search_pos -= 1) {
            if (std.mem.eql(u8, self.data[search_pos..][0..4], &signature)) {
                return self.parseEndRecord(search_pos);
            }
            if (search_pos == 0) break;
        }

        return error.EndOfCentralDirectoryNotFound;
    }

    fn parseEndRecord(self: *MemoryZipReader, offset: usize) !EndOfCentralDirectory {
        if (offset + 22 > self.data.len) return error.ZipTruncated;

        const data = self.data[offset..];

        return EndOfCentralDirectory{
            .disk_number = std.mem.readInt(u16, data[4..6], .little),
            .cd_start_disk = std.mem.readInt(u16, data[6..8], .little),
            .cd_records_on_disk = std.mem.readInt(u16, data[8..10], .little),
            .cd_records_total = std.mem.readInt(u16, data[10..12], .little),
            .cd_size = std.mem.readInt(u32, data[12..16], .little),
            .cd_offset = std.mem.readInt(u32, data[16..20], .little),
            .comment_length = std.mem.readInt(u16, data[20..22], .little),
        };
    }

    /// Create an iterator to iterate through all entries in the ZIP file
    pub fn iterate(self: *MemoryZipReader, allocator: std.mem.Allocator) !Iterator {
        const eocd = try self.findEndRecord();

        return Iterator{
            .reader = self,
            .allocator = allocator,
            .cd_offset = eocd.cd_offset,
            .cd_size = eocd.cd_size,
            .total_entries = eocd.cd_records_total,
            .current_entry = 0,
            .current_offset = eocd.cd_offset,
        };
    }

    /// Iterator for ZIP entries
    pub const Iterator = struct {
        reader: *MemoryZipReader,
        allocator: std.mem.Allocator,
        cd_offset: u32,
        cd_size: u32,
        total_entries: u16,
        current_entry: u16,
        current_offset: u32,

        /// Get the next entry, or null if there are no more entries
        pub fn next(self: *Iterator) !?Entry {
            if (self.current_entry >= self.total_entries) return null;

            const entry = try self.parseEntry();
            self.current_entry += 1;

            return entry;
        }

        fn parseEntry(self: *Iterator) !Entry {
            const data = self.reader.data;
            const offset = self.current_offset;

            if (offset + 46 > data.len) return error.ZipTruncated;

            const header = data[offset..];

            // Check signature: PK\x01\x02
            const signature = [4]u8{ 0x50, 0x4b, 0x01, 0x02 };
            if (!std.mem.eql(u8, header[0..4], &signature)) {
                return error.InvalidCentralDirectorySignature;
            }

            const compression_method = std.mem.readInt(u16, header[10..12], .little);
            const crc32 = std.mem.readInt(u32, header[16..20], .little);
            const compressed_size = std.mem.readInt(u32, header[20..24], .little);
            const uncompressed_size = std.mem.readInt(u32, header[24..28], .little);
            const filename_len = std.mem.readInt(u16, header[28..30], .little);
            const extra_len = std.mem.readInt(u16, header[30..32], .little);
            const comment_len = std.mem.readInt(u16, header[32..34], .little);
            const local_header_offset = std.mem.readInt(u32, header[42..46], .little);

            // Read filename
            const filename_start = offset + 46;
            const filename_end = filename_start + filename_len;
            if (filename_end > data.len) return error.ZipTruncated;

            const filename = try self.allocator.dupe(u8, data[filename_start..filename_end]);

            // Update offset for next entry
            self.current_offset += 46 + filename_len + extra_len + comment_len;

            return Entry{
                .filename = filename,
                .compression_method = compression_method,
                .crc32 = crc32,
                .compressed_size = compressed_size,
                .uncompressed_size = uncompressed_size,
                .local_header_offset = local_header_offset,
            };
        }
    };

    /// Represents a single file entry in the ZIP archive
    pub const Entry = struct {
        filename: []const u8,
        compression_method: u16,
        crc32: u32,
        compressed_size: u32,
        uncompressed_size: u32,
        local_header_offset: u32,

        /// Free the memory used by this entry's filename
        pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
            allocator.free(self.filename);
        }

        /// Get the compressed data for this entry
        pub fn getCompressedData(self: Entry, reader: *MemoryZipReader) ![]const u8 {
            const data = reader.data;
            const offset = self.local_header_offset;

            if (offset + 30 > data.len) return error.ZipTruncated;

            const local_header = data[offset..];

            // Check signature: PK\x03\x04
            const signature = [4]u8{ 0x50, 0x4b, 0x03, 0x04 };
            if (!std.mem.eql(u8, local_header[0..4], &signature)) {
                return error.InvalidLocalHeaderSignature;
            }

            const local_filename_len = std.mem.readInt(u16, local_header[26..28], .little);
            const local_extra_len = std.mem.readInt(u16, local_header[28..30], .little);

            const data_offset = offset + 30 + local_filename_len + local_extra_len;
            const data_end = data_offset + self.compressed_size;

            if (data_end > data.len) return error.ZipTruncated;

            return data[data_offset..data_end];
        }

        /// Decompress the entry data (supports store and deflate compression)
        pub fn decompress(self: Entry, reader: *MemoryZipReader, allocator: std.mem.Allocator) ![]u8 {
            const compressed_data = try self.getCompressedData(reader);

            // Compression method: 0 = store (no compression), 8 = deflate
            if (self.compression_method == 0) {
                // No compression, just copy
                return try allocator.dupe(u8, compressed_data);
            } else if (self.compression_method == 8) {
                // Deflate compression
                return try self.decompressDeflate(compressed_data, allocator);
            } else {
                return error.UnsupportedCompressionMethod;
            }
        }

        fn decompressDeflate(self: Entry, compressed_data: []const u8, allocator: std.mem.Allocator) ![]u8 {
            // Allocate output buffer
            const result = try allocator.alloc(u8, self.uncompressed_size);
            errdefer allocator.free(result);

            // Create a fixed buffer stream from compressed data
            var stream = std.io.fixedBufferStream(compressed_data);
            var stream_reader = stream.reader();

            // Adapt the old-style reader to the new API
            var reader_buffer: [4096]u8 = undefined;
            var adapted_reader = stream_reader.adaptToNewApi(&reader_buffer);

            // Create decompressor with a window buffer for history
            // ZIP uses raw deflate (no zlib/gzip wrapper)
            var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompressor = std.compress.flate.Decompress.init(
                &adapted_reader.new_interface,
                .raw,
                &decompress_buffer,
            );

            // Read all decompressed data
            try decompressor.reader.readSliceAll(result);

            return result;
        }

        /// Check if this entry is a directory
        pub fn isDirectory(self: Entry) bool {
            return self.uncompressed_size == 0 and
                self.filename.len > 0 and
                self.filename[self.filename.len - 1] == '/';
        }

        /// Get compression method as a string
        pub fn compressionMethodName(self: Entry) []const u8 {
            return switch (self.compression_method) {
                0 => "store",
                8 => "deflate",
                else => "unknown",
            };
        }
    };

    const EndOfCentralDirectory = struct {
        disk_number: u16,
        cd_start_disk: u16,
        cd_records_on_disk: u16,
        cd_records_total: u16,
        cd_size: u32,
        cd_offset: u32,
        comment_length: u16,
    };
};

// Tests
test "basic library functionality" {
    const testing = std.testing;
    try testing.expect(true);
}

test "read ZIP file from files directory" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Read the c.epub file from the files directory
    const cwd = std.fs.cwd();
    const zip_data = cwd.readFileAlloc(allocator, "files/c.epub", 10 * 1024 * 1024) catch |err| {
        std.debug.print("Could not read files/c.epub: {}\n", .{err});
        std.debug.print("Note: This test requires files/c.epub to be available\n", .{});
        return err;
    };
    defer allocator.free(zip_data);

    // Create reader and verify it can find the End of Central Directory
    var reader = MemoryZipReader.init(zip_data);

    // Try to iterate through entries
    var iter = try reader.iterate(allocator);

    var entry_count: usize = 0;
    while (try iter.next()) |entry| {
        defer entry.deinit(allocator);
        entry_count += 1;
        // Just verify we can read entries
        try testing.expect(entry.filename.len > 0);
    }

    try testing.expect(entry_count > 0);
}
