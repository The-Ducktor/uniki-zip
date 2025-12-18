<file_path>
uniki-zip/src/README.md
</file_path>

<edit_description>
Create a comprehensive README.md file describing how to use the in-memory ZIP reader library
</edit_description>

# Uniki-ZIP: Pure In-Memory ZIP Reader for Zig

A lightweight, pure in-memory ZIP file reader library for Zig that doesn't require writing temporary files to disk. This library provides a clean API for reading ZIP archives directly from memory buffers, supporting both uncompressed (store) and deflate-compressed entries.

## Features

- **Pure In-Memory Operation**: Reads ZIP files directly from memory without disk I/O
- **No Temporary Files**: Unlike Zig's standard `std.zip` which requires `File.Reader`, this library works with byte slices
- **Compression Support**: Handles both store (uncompressed) and deflate-compressed entries
- **Zig 0.15.2 Compatible**: Uses the current Zig standard library APIs
- **Simple API**: Easy-to-use iterator pattern for accessing ZIP entries
- **Memory Efficient**: Only allocates memory for filenames and decompressed data as needed

## Requirements

- Zig 0.15.2 or later
- No external dependencies

## Quick Start

### 1. Add to Your Project

Add this as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .uniki_zip = .{
        .url = "https://github.com/your-repo/uniki-zip/archive/main.tar.gz",
        .hash = "...", // Get this from zig fetch
    },
},
```

Then in your `build.zig`:

```zig
const uniki_zip = b.dependency("uniki_zip", .{});
exe.root_module.addImport("zip", uniki_zip.module("zip_test"));
```

### 2. Basic Usage

```zig
const std = @import("std");
const zip = @import("zip");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Load ZIP file into memory
    const zip_data = try std.fs.cwd().readFileAlloc(allocator, "archive.zip", 100 * 1024 * 1024);
    defer allocator.free(zip_data);

    // Create reader and iterate through entries
    var reader = zip.MemoryZipReader.init(zip_data);
    var iter = try reader.iterate(allocator);

    while (try iter.next()) |entry| {
        defer entry.deinit(allocator);

        std.debug.print("File: {s} ({d} bytes)\n", .{entry.filename, entry.uncompressed_size});

        // Decompress if needed
        if (!entry.isDirectory()) {
            const data = try entry.decompress(&reader, allocator);
            defer allocator.free(data);
            // Use the decompressed data...
        }
    }
}
```

## API Reference

### MemoryZipReader

The main struct for reading ZIP files from memory.

#### `init(data: []const u8) MemoryZipReader`

Creates a new ZIP reader from a byte slice containing ZIP data.

#### `iterate(allocator: std.mem.Allocator) !Iterator`

Returns an iterator for traversing all entries in the ZIP file.

### Iterator

Iterator for ZIP entries.

#### `next() !?Entry`

Returns the next entry in the ZIP file, or `null` if there are no more entries.

### Entry

Represents a single file or directory entry in the ZIP archive.

#### Fields

- `filename: []const u8` - The name of the entry
- `compression_method: u16` - Compression method (0 = store, 8 = deflate)
- `crc32: u32` - CRC32 checksum
- `compressed_size: u32` - Size of compressed data
- `uncompressed_size: u32` - Size of uncompressed data
- `local_header_offset: u32` - Offset to local header in ZIP data

#### Methods

##### `deinit(allocator: std.mem.Allocator)`

Frees memory allocated for the filename. Must be called when done with the entry.

##### `decompress(reader: *MemoryZipReader, allocator: std.mem.Allocator) ![]u8`

Decompresses the entry data. Returns a newly allocated buffer containing the uncompressed data.

##### `isDirectory() bool`

Returns `true` if this entry represents a directory.

##### `compressionMethodName() []const u8`

Returns a string representation of the compression method ("store", "deflate", or "unknown").

##### `getCompressedData(reader: *MemoryZipReader) ![]const u8`

Returns the raw compressed data for this entry (advanced usage).

## Examples

### Reading All Files in a ZIP

```zig
const std = @import("std");
const zip = @import("zip");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const zip_data = try std.fs.cwd().readFileAlloc(allocator, "files.zip", 50 * 1024 * 1024);
    defer allocator.free(zip_data);

    var reader = zip.MemoryZipReader.init(zip_data);
    var iter = try reader.iterate(allocator);

    while (try iter.next()) |entry| {
        defer entry.deinit(allocator);

        if (entry.isDirectory()) continue;

        const content = try entry.decompress(&reader, allocator);
        defer allocator.free(content);

        std.debug.print("Content of {s}:\n{s}\n\n", .{entry.filename, content});
    }
}
```

### Finding a Specific File

```zig
const std = @import("std");
const zip = @import("zip");

pub fn findFile(zip_data: []const u8, filename: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    var reader = zip.MemoryZipReader.init(zip_data);
    var iter = try reader.iterate(allocator);

    while (try iter.next()) |entry| {
        defer entry.deinit(allocator);

        if (std.mem.eql(u8, entry.filename, filename)) {
            return try entry.decompress(&reader, allocator);
        }
    }

    return null; // File not found
}
```

### Listing Directory Contents

```zig
const std = @import("std");
const zip = @import("zip");

pub fn listContents(zip_data: []const u8, allocator: std.mem.Allocator) !void {
    var reader = zip.MemoryZipReader.init(zip_data);
    var iter = try reader.iterate(allocator);

    while (try iter.next()) |entry| {
        defer entry.deinit(allocator);

        const type_str = if (entry.isDirectory()) "directory" else "file";
        std.debug.print("{s}: {s} ({d} bytes)\n", .{
            type_str,
            entry.filename,
            entry.uncompressed_size
        });
    }
}
```

## Building and Running

### Clone and Build

```bash
git clone https://github.com/your-repo/uniki-zip.git
cd uniki-zip
zig build
```

### Run Examples

```bash
# Run the main demo (compares file-based vs memory-based reading)
zig build run

# Run the pure memory example
zig build run-memory

# Run tests
zig build test
```

### Using in Your Project

1. Add the library as a dependency (see Quick Start)
2. Import the module: `const zip = @import("zip");`
3. Use the API as shown in the examples

## Limitations

- Only supports ZIP files with Central Directory at the end (standard ZIP format)
- No support for ZIP64 extensions yet
- No support for encryption
- Limited to compression methods 0 (store) and 8 (deflate)
- Designed for reading, not creating ZIP files

## Error Handling

The library returns standard Zig errors. Common errors include:

- `ZipTooSmall`: ZIP data is too small to be valid
- `EndOfCentralDirectoryNotFound`: Invalid or corrupted ZIP file
- `ZipTruncated`: ZIP file appears to be truncated
- `InvalidCentralDirectorySignature`: Corrupted central directory
- `InvalidLocalHeaderSignature`: Corrupted local file header
- `UnsupportedCompressionMethod`: Entry uses an unsupported compression method

## Performance Notes

- The entire ZIP file is loaded into memory upfront
- Decompression happens on-demand when `decompress()` is called
- Memory usage scales with the size of decompressed data
- For very large ZIP files, consider streaming approaches or memory-mapped files

## Contributing

Contributions are welcome! Please:

1. Follow Zig coding conventions
2. Add tests for new features
3. Update documentation
4. Ensure compatibility with Zig 0.15.2+

## License

This project is released under the MIT License. See LICENSE file for details.

## Changelog

### v0.0.0
- Initial release
- Basic ZIP reading functionality
- Support for store and deflate compression
- Memory-based API compatible with Zig 0.15.2