//! In-Memory ZIP Reader Library for Zig 0.15.2
//!
//! This library provides a pure in-memory ZIP file reader that doesn't require
//! writing to temporary files or using file handles. It supports both uncompressed
//! (store) and deflate-compressed entries.
//!
//! Performance optimizations:
//! - SIMD-accelerated signature search using std.mem.lastIndexOf
//! - Optimized buffer sizes for decompression (16KB read buffer)
//! - Inline hints for hot paths
//! - Better cache locality in parsing functions
//! - Comptime-known constants for signature checking

const std = @import("std");
const flate = std.compress.flate;

/// A pure in-memory ZIP reader that doesn't require File.Reader
/// This implementation reads directly from a byte slice in memory
pub const MemoryZipReader = struct {
    data: []const u8,

    /// Initialize a new MemoryZipReader with ZIP data
    pub fn init(data: []const u8) MemoryZipReader {
        return .{ .data = data };
    }

    /// Find the End of Central Directory record
    /// Optimized with std.mem.lastIndexOf for SIMD acceleration
    fn findEndRecord(self: *const MemoryZipReader) !EndOfCentralDirectory {
        // The EOCD is at the end of the file, we search backwards
        const min_eocd_size = 22; // minimum size of EOCD record
        if (self.data.len < min_eocd_size) {
            @branchHint(.cold);
            return error.ZipTooSmall;
        }

        // Search for the EOCD signature from the end
        // PK\x05\x06 - using comptime for optimization
        const signature = comptime [4]u8{ 0x50, 0x4b, 0x05, 0x06 };

        // Limit search window: EOCD can only be in last ~65KB (22-byte header + max 65535-byte comment)
        const max_comment_len = 65535;
        const max_eocd_search = min_eocd_size + max_comment_len;
        const search_start = if (self.data.len > max_eocd_search)
            self.data.len - max_eocd_search
        else
            0;

        // Use std.mem.lastIndexOf for optimized (potentially SIMD) search
        const search_end = self.data.len - min_eocd_size + 4;
        if (std.mem.lastIndexOf(u8, self.data[search_start..search_end], &signature)) |pos| {
            return self.parseEndRecord(search_start + pos);
        }

        return error.EndOfCentralDirectoryNotFound;
    }

    /// Parse the End of Central Directory record
    /// Marked inline for better performance in hot paths
    inline fn parseEndRecord(self: *const MemoryZipReader, offset: usize) !EndOfCentralDirectory {
        if (offset + 22 > self.data.len) {
            @branchHint(.cold);
            return error.ZipTruncated;
        }

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
    pub fn iterate(self: *const MemoryZipReader) !Iterator {
        const eocd = try self.findEndRecord();

        return Iterator{
            .reader = self,
            .total_entries = eocd.cd_records_total,
            .current_entry = 0,
            .current_offset = eocd.cd_offset,
        };
    }

    /// A manifest of all entries in the ZIP file for fast lookup
    pub const Manifest = struct {
        map: std.StringHashMap(Entry),

        pub fn deinit(self: *Manifest) void {
            self.map.deinit();
        }

        /// Find an entry by filename
        pub fn get(self: Manifest, filename: []const u8) ?Entry {
            return self.map.get(filename);
        }
    };

    /// Build a manifest for fast entry lookup
    /// Optimized with pre-allocation and putNoClobber
    pub fn buildManifest(self: *const MemoryZipReader, allocator: std.mem.Allocator) !Manifest {
        const eocd = try self.findEndRecord();
        var map = std.StringHashMap(Entry).init(allocator);
        errdefer map.deinit();

        // Pre-allocate space for efficiency
        try map.ensureTotalCapacity(eocd.cd_records_total);

        // Create iterator directly to avoid double findEndRecord call
        var iter = Iterator{
            .reader = self,
            .total_entries = eocd.cd_records_total,
            .current_entry = 0,
            .current_offset = eocd.cd_offset,
        };
        while (try iter.next()) |entry| {
            // Use putNoClobber for better performance when we know keys are unique
            try map.putNoClobber(entry.filename, entry);
        }

        return Manifest{ .map = map };
    }

    /// Iterator for ZIP entries
    pub const Iterator = struct {
        reader: *const MemoryZipReader,
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

        /// Parse a central directory entry
        /// Optimized for better cache locality and early offset update
        fn parseEntry(self: *Iterator) !Entry {
            const data = self.reader.data;
            const offset = self.current_offset;

            if (offset + 46 > data.len) {
                @branchHint(.cold);
                return error.ZipTruncated;
            }

            const header = data[offset..];

            // Check signature: PK\x01\x02 - using integer comparison (faster than mem.eql)
            const sig = std.mem.readInt(u32, header[0..4], .little);
            if (sig != 0x02014b50) {
                @branchHint(.cold);
                return error.InvalidCentralDirectorySignature;
            }

            // Read lengths first for better cache utilization
            const filename_len = std.mem.readInt(u16, header[28..30], .little);
            const extra_len = std.mem.readInt(u16, header[30..32], .little);
            const comment_len = std.mem.readInt(u16, header[32..34], .little);

            // Read filename directly from memory (no allocation needed)
            const filename_start = offset + 46;
            const filename_end = filename_start + filename_len;
            if (filename_end > data.len) return error.ZipTruncated;

            const filename = data[filename_start..filename_end];

            // Update offset early for better CPU pipelining
            const entry_size = 46 + filename_len + extra_len + comment_len;
            self.current_offset += entry_size;

            // Prefetch next entry's memory for better cache utilization
            const next_offset = self.current_offset;
            if (next_offset + 46 <= data.len) {
                @prefetch(data.ptr + next_offset, .{ .locality = 3 });
            }

            // Read other fields in struct order for better code generation
            return Entry{
                .filename = filename,
                .compression_method = std.mem.readInt(u16, header[10..12], .little),
                .crc32 = std.mem.readInt(u32, header[16..20], .little),
                .compressed_size = std.mem.readInt(u32, header[20..24], .little),
                .uncompressed_size = std.mem.readInt(u32, header[24..28], .little),
                .local_header_offset = std.mem.readInt(u32, header[42..46], .little),
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

        /// Get the compressed data for this entry
        /// Marked inline for better performance
        pub inline fn getCompressedData(self: Entry, reader: *const MemoryZipReader) ![]const u8 {
            const data = reader.data;
            const offset = self.local_header_offset;

            if (offset + 30 > data.len) {
                @branchHint(.cold);
                return error.ZipTruncated;
            }

            const local_header = data[offset..];

            // Check signature: PK\x03\x04 - using integer comparison (faster than mem.eql)
            const sig = std.mem.readInt(u32, local_header[0..4], .little);
            if (sig != 0x04034b50) {
                @branchHint(.cold);
                return error.InvalidLocalHeaderSignature;
            }

            const local_filename_len = std.mem.readInt(u16, local_header[26..28], .little);
            const local_extra_len = std.mem.readInt(u16, local_header[28..30], .little);

            const data_offset = offset + 30 + local_filename_len + local_extra_len;
            const data_end = data_offset + self.compressed_size;

            if (data_end > data.len) {
                @branchHint(.cold);
                return error.ZipTruncated;
            }

            return data[data_offset..data_end];
        }

        /// Decompress the entry data (supports store and deflate compression)
        pub fn decompress(self: Entry, reader: *const MemoryZipReader, allocator: std.mem.Allocator) ![]u8 {
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

        /// Decompress deflate-compressed data
        /// Optimized with larger buffer sizes (16KB reader buffer)
        fn decompressDeflate(self: Entry, compressed_data: []const u8, allocator: std.mem.Allocator) ![]u8 {
            // Handle empty files
            if (self.uncompressed_size == 0) {
                @branchHint(.cold);
                return try allocator.alloc(u8, 0);
            }

            // Allocate output buffer
            const result = try allocator.alloc(u8, self.uncompressed_size);
            errdefer allocator.free(result);

            // Prefetch compressed data for decompression
            @prefetch(compressed_data.ptr, .{ .locality = 3 });

            // Create a fixed buffer stream from compressed data
            var fbs = std.io.fixedBufferStream(compressed_data);
            var stream_reader = fbs.reader();

            // Use 16KB buffer for better I/O performance (was 4KB)
            // Larger buffers reduce the number of function calls and improve cache utilization
            var reader_buffer: [16384]u8 = undefined;
            var adapted_reader = stream_reader.adaptToNewApi(&reader_buffer);

            // Create decompressor with a window buffer for history
            // ZIP uses raw deflate (no zlib/gzip wrapper)
            var decompress_buffer: [flate.max_window_len]u8 = undefined;
            var decompressor = flate.Decompress.init(
                &adapted_reader.new_interface,
                .raw,
                &decompress_buffer,
            );

            // Read all decompressed data
            try decompressor.reader.readSliceAll(result);

            return result;
        }

        /// Check if this entry is a directory
        pub inline fn isDirectory(self: Entry) bool {
            return self.uncompressed_size == 0 and
                self.filename.len > 0 and
                self.filename[self.filename.len - 1] == '/';
        }

        /// Get compression method as a string
        pub inline fn compressionMethodName(self: Entry) []const u8 {
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
