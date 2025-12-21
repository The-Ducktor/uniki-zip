//! Benchmark and profiling utility for uniki-zip
//! Measures performance of various operations to identify bottlenecks

const std = @import("std");
const zip = @import("root.zig");

const Timer = std.time.Timer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <zip_file>\n", .{args[0]});
        std.debug.print("Example: {s} test.zip\n", .{args[0]});
        return error.MissingArgument;
    }

    const zip_filename = args[1];

    std.debug.print("=== uniki-zip Benchmark & Profiling ===\n", .{});
    std.debug.print("File: {s}\n\n", .{zip_filename});

    // Load ZIP file into memory
    var load_timer = try Timer.start();
    const zip_data = try std.fs.cwd().readFileAlloc(allocator, zip_filename, 500 * 1024 * 1024);
    defer allocator.free(zip_data);
    const load_time = load_timer.read();

    std.debug.print("File loaded: {d} bytes in {d:.2}ms\n\n", .{
        zip_data.len,
        @as(f64, @floatFromInt(load_time)) / 1_000_000.0,
    });

    // Run benchmarks
    try benchmarkEOCDFind(zip_data);
    try benchmarkIteration(zip_data);
    try benchmarkManifestBuild(zip_data, allocator);
    try benchmarkDecompression(zip_data, allocator);
    try benchmarkBatchDecompression(zip_data, allocator);
    try benchmarkMemoryUsage(zip_data, allocator);
}

fn benchmarkEOCDFind(zip_data: []const u8) !void {
    std.debug.print("--- EOCD Finding Benchmark ---\n", .{});

    // First call (no cache)
    var reader1 = zip.MemoryZipReader.init(zip_data);
    var timer = try Timer.start();
    _ = try reader1.getEndRecord();
    const first_call = timer.read();

    // Second call (cached)
    timer.reset();
    _ = try reader1.getEndRecord();
    const cached_call = timer.read();

    // Multiple calls to verify cache effectiveness
    const iterations = 10000;
    timer.reset();
    for (0..iterations) |_| {
        _ = try reader1.getEndRecord();
    }
    const batch_time = timer.read();
    const avg_cached = @as(f64, @floatFromInt(batch_time)) / @as(f64, @floatFromInt(iterations));

    std.debug.print("  First call (no cache):   {d:.2}µs\n", .{
        @as(f64, @floatFromInt(first_call)) / 1_000.0,
    });
    std.debug.print("  Second call (cached):    {d:.2}µs\n", .{
        @as(f64, @floatFromInt(cached_call)) / 1_000.0,
    });
    std.debug.print("  Average cached ({d}x):    {d:.2}ns\n", .{
        iterations,
        avg_cached,
    });
    std.debug.print("  Speedup: {d:.1}x\n\n", .{
        @as(f64, @floatFromInt(first_call)) / @as(f64, @floatFromInt(cached_call)),
    });
}

fn benchmarkIteration(zip_data: []const u8) !void {
    std.debug.print("--- Iteration Benchmark ---\n", .{});

    var reader = zip.MemoryZipReader.init(zip_data);
    var timer = try Timer.start();
    var iter = try reader.iterate();

    var count: usize = 0;
    var total_compressed: u64 = 0;
    var total_uncompressed: u64 = 0;
    var deflate_count: usize = 0;
    var store_count: usize = 0;
    var dir_count: usize = 0;

    while (try iter.next()) |entry| {
        count += 1;
        total_compressed += entry.compressed_size;
        total_uncompressed += entry.uncompressed_size;

        if (entry.isDirectory()) {
            dir_count += 1;
        } else if (entry.compression_method == 8) {
            deflate_count += 1;
        } else if (entry.compression_method == 0) {
            store_count += 1;
        }
    }

    const iter_time = timer.read();

    std.debug.print("  Total entries: {d}\n", .{count});
    std.debug.print("    Directories: {d}\n", .{dir_count});
    std.debug.print("    Deflate:     {d}\n", .{deflate_count});
    std.debug.print("    Store:       {d}\n", .{store_count});
    std.debug.print("  Total compressed:   {d} bytes\n", .{total_compressed});
    std.debug.print("  Total uncompressed: {d} bytes\n", .{total_uncompressed});
    std.debug.print("  Compression ratio:  {d:.1}%\n", .{
        (@as(f64, @floatFromInt(total_compressed)) / @as(f64, @floatFromInt(total_uncompressed))) * 100.0,
    });
    std.debug.print("  Iteration time: {d:.2}ms\n", .{
        @as(f64, @floatFromInt(iter_time)) / 1_000_000.0,
    });
    std.debug.print("  Per entry: {d:.2}µs\n\n", .{
        (@as(f64, @floatFromInt(iter_time)) / @as(f64, @floatFromInt(count))) / 1_000.0,
    });
}

fn benchmarkManifestBuild(zip_data: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("--- Manifest Build Benchmark ---\n", .{});

    var reader = zip.MemoryZipReader.init(zip_data);
    var timer = try Timer.start();
    var manifest = try reader.buildManifest(allocator);
    defer manifest.deinit();
    const build_time = timer.read();

    const entry_count = manifest.map.count();

    std.debug.print("  Manifest entries: {d}\n", .{entry_count});
    std.debug.print("  Build time: {d:.2}ms\n", .{
        @as(f64, @floatFromInt(build_time)) / 1_000_000.0,
    });
    std.debug.print("  Per entry: {d:.2}µs\n\n", .{
        (@as(f64, @floatFromInt(build_time)) / @as(f64, @floatFromInt(entry_count))) / 1_000.0,
    });
}

fn benchmarkDecompression(zip_data: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("--- Individual Decompression Benchmark ---\n", .{});

    var reader = zip.MemoryZipReader.init(zip_data);
    var iter = try reader.iterate();

    var total_time: u64 = 0;
    var deflate_time: u64 = 0;
    var store_time: u64 = 0;
    var decompress_count: usize = 0;
    var deflate_count: usize = 0;
    var store_count: usize = 0;
    var total_decompressed: u64 = 0;
    var max_time: u64 = 0;
    var max_filename: []const u8 = "";

    // Sample first N files or all if less than N
    const max_samples = 100;
    var sampled: usize = 0;

    while (try iter.next()) |entry| {
        if (entry.isDirectory()) continue;
        if (sampled >= max_samples) break;

        var timer = try Timer.start();
        const decompressed = try entry.decompress(&reader, allocator);
        defer allocator.free(decompressed);
        const decompress_time = timer.read();

        total_time += decompress_time;
        total_decompressed += decompressed.len;
        decompress_count += 1;

        if (entry.compression_method == 8) {
            deflate_time += decompress_time;
            deflate_count += 1;
        } else if (entry.compression_method == 0) {
            store_time += decompress_time;
            store_count += 1;
        }

        if (decompress_time > max_time) {
            max_time = decompress_time;
            max_filename = entry.filename;
        }

        sampled += 1;
    }

    if (decompress_count > 0) {
        std.debug.print("  Files decompressed: {d}\n", .{decompress_count});
        std.debug.print("  Total decompressed: {d} bytes\n", .{total_decompressed});
        std.debug.print("  Total time: {d:.2}ms\n", .{
            @as(f64, @floatFromInt(total_time)) / 1_000_000.0,
        });
        std.debug.print("  Average per file: {d:.2}µs\n", .{
            (@as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(decompress_count))) / 1_000.0,
        });

        if (deflate_count > 0) {
            std.debug.print("  Deflate ({d} files): {d:.2}µs avg\n", .{
                deflate_count,
                (@as(f64, @floatFromInt(deflate_time)) / @as(f64, @floatFromInt(deflate_count))) / 1_000.0,
            });
        }

        if (store_count > 0) {
            std.debug.print("  Store ({d} files): {d:.2}µs avg\n", .{
                store_count,
                (@as(f64, @floatFromInt(store_time)) / @as(f64, @floatFromInt(store_count))) / 1_000.0,
            });
        }

        std.debug.print("  Throughput: {d:.2} MB/s\n", .{
            (@as(f64, @floatFromInt(total_decompressed)) / @as(f64, @floatFromInt(total_time))) * 1000.0,
        });
        std.debug.print("  Slowest file: {s} ({d:.2}ms)\n\n", .{
            max_filename,
            @as(f64, @floatFromInt(max_time)) / 1_000_000.0,
        });
    } else {
        std.debug.print("  No files to decompress\n\n", .{});
    }
}

fn benchmarkBatchDecompression(zip_data: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("--- Batch Decompression Benchmark ---\n", .{});

    var reader = zip.MemoryZipReader.init(zip_data);
    var iter = try reader.iterate();

    // Collect entries using fixed buffer
    const max_batch = 50;
    var entries_buffer: [max_batch]zip.MemoryZipReader.Entry = undefined;
    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.isDirectory()) continue;
        if (count >= max_batch) break;
        entries_buffer[count] = entry;
        count += 1;
    }

    if (count == 0) {
        std.debug.print("  No files to decompress\n\n", .{});
        return;
    }

    const entries = entries_buffer[0..count];

    // Benchmark batch decompression
    var timer = try Timer.start();
    const results = try reader.decompressBatch(entries, allocator);
    const batch_time = timer.read();

    defer {
        for (results) |data| {
            allocator.free(data);
        }
        allocator.free(results);
    }

    var total_size: u64 = 0;
    for (results) |data| {
        total_size += data.len;
    }

    std.debug.print("  Files decompressed: {d}\n", .{results.len});
    std.debug.print("  Total size: {d} bytes\n", .{total_size});
    std.debug.print("  Batch time: {d:.2}ms\n", .{
        @as(f64, @floatFromInt(batch_time)) / 1_000_000.0,
    });
    std.debug.print("  Per file: {d:.2}µs\n", .{
        (@as(f64, @floatFromInt(batch_time)) / @as(f64, @floatFromInt(results.len))) / 1_000.0,
    });
    std.debug.print("  Throughput: {d:.2} MB/s\n\n", .{
        (@as(f64, @floatFromInt(total_size)) / @as(f64, @floatFromInt(batch_time))) * 1000.0,
    });
}

fn benchmarkMemoryUsage(zip_data: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("--- Memory Usage Analysis ---\n", .{});

    var reader = zip.MemoryZipReader.init(zip_data);
    const reader_size = @sizeOf(zip.MemoryZipReader);

    std.debug.print("  MemoryZipReader size: {d} bytes\n", .{reader_size});
    std.debug.print("  Entry struct size: {d} bytes\n", .{@sizeOf(zip.MemoryZipReader.Entry)});
    std.debug.print("  Iterator size: {d} bytes\n", .{@sizeOf(zip.MemoryZipReader.Iterator)});

    // Build manifest to see memory usage
    var manifest = try reader.buildManifest(allocator);
    defer manifest.deinit();

    const entry_count = manifest.map.count();
    const estimated_manifest_size = entry_count * (@sizeOf(zip.MemoryZipReader.Entry) + 64); // rough estimate

    std.debug.print("  Manifest entries: {d}\n", .{entry_count});
    std.debug.print("  Estimated manifest memory: ~{d} KB\n", .{estimated_manifest_size / 1024});
    std.debug.print("  ZIP data size: {d} KB\n", .{zip_data.len / 1024});
    std.debug.print("  Memory overhead: {d:.2}%\n\n", .{
        (@as(f64, @floatFromInt(estimated_manifest_size)) / @as(f64, @floatFromInt(zip_data.len))) * 100.0,
    });
}
