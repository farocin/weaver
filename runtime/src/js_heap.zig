//! The QuickJS heap of the shared JS runtime. Every widget's allocations live
//! in its own reserved address range, so any pointer names its owner: frees
//! and usable sizes need no per-block header, a widget's memory cap is exact
//! (its range), and a widget's bytes are countable on their own. Runtime-
//! level allocations made outside any widget's turn go to a last, host
//! range.
//!
//! Inside a range, sizes up to 512 bytes come from 1 KiB granules carved
//! into one size class each (16-byte steps up to 128, then quarter steps);
//! larger blocks are runs of whole granules behind a 16-byte length header.
//! A byte per granule, at the start of the range, records what it holds.
//! Freed runs merge with free neighbours, the run at the top of the range
//! returns to it, and pages wholly inside free space are decommitted, so a
//! freed block leaves the working set; `trim` returns small-class granules
//! whose blocks are all free. QuickJS grows its parser and bytecode buffers
//! by repeated realloc; the newest block grows in place.
const std = @import("std");
const builtin = @import("builtin");

pub const Owner = u16;

const granule_bytes: usize = 1024;
const header_bytes: usize = 16;
const small_max: usize = 512;
const class_sizes = [_]u16{ 16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512 };
const page_bytes: usize = std.heap.page_size_min;
const commit_step: usize = 64 * 1024;

/// What a granule below `bump` holds: a small class index, or one of these.
const run_start: u8 = 0xF0;
const run_rest: u8 = 0xF1;
const free_start: u8 = 0xF2;
const free_rest: u8 = 0xF3;

const FreeBlock = struct { next: ?*FreeBlock };
/// Head of a free run, in its first granule; its length is repeated in the
/// last 8 bytes of its last granule so the run after it can find its start.
const FreeRun = struct { prev: ?*FreeRun, next: ?*FreeRun, granules: usize };

const Range = struct {
    /// Granules handed out from the heap area so far; everything above is
    /// untouched.
    bump: usize = 0,
    /// Bytes from the range start committed for bump growth.
    committed: usize = 0,
    /// Usable bytes currently allocated.
    used: usize = 0,
    free_blocks: [class_sizes.len]?*FreeBlock = @splat(null),
    free_runs: ?*FreeRun = null,
};

/// Sizes the heap: `owners` ranges of `range_bytes` each.
pub const Layout = struct {
    owners: usize,
    range_bytes: usize,

    fn granulesPerRange(self: Layout) usize {
        return (self.range_bytes - self.mapBytes()) / granule_bytes;
    }

    fn mapBytes(self: Layout) usize {
        // One byte per granule of the whole range, rounded to a page; the
        // map's own granules are simply never handed out.
        return std.mem.alignForward(usize, self.range_bytes / granule_bytes, page_bytes);
    }
};

pub const Heap = struct {
    layout: Layout,
    base: [*]u8,
    ranges: []Range,
    /// The owner new allocations are charged to.
    current: Owner,

    pub fn init(allocator: std.mem.Allocator, layout: Layout) !Heap {
        const base = try reserve(layout.owners * layout.range_bytes);
        const ranges = try allocator.alloc(Range, layout.owners);
        for (ranges) |*range| range.* = .{};
        return .{ .layout = layout, .base = base, .ranges = ranges, .current = @intCast(layout.owners - 1) };
    }

    pub fn deinit(self: *Heap, allocator: std.mem.Allocator) void {
        release(self.base, self.layout.owners * self.layout.range_bytes);
        allocator.free(self.ranges);
        self.* = undefined;
    }

    /// The owner of runtime-level allocations made outside widget turns.
    pub fn hostOwner(self: *const Heap) Owner {
        return @intCast(self.layout.owners - 1);
    }

    /// Usable bytes `owner` holds now.
    pub fn usedBytes(self: *const Heap, owner: Owner) usize {
        return self.ranges[owner].used;
    }

    /// Bytes of `owner`'s heap area below its top: the most that can be
    /// resident (free runs inside it are mostly decommitted).
    pub fn grownBytes(self: *const Heap, owner: Owner) usize {
        return self.ranges[owner].bump * granule_bytes;
    }

    fn rangeBase(self: *const Heap, owner: Owner) [*]u8 {
        return self.base + @as(usize, owner) * self.layout.range_bytes;
    }

    fn map(self: *const Heap, owner: Owner) [*]u8 {
        return self.rangeBase(owner);
    }

    fn granuleAddress(self: *const Heap, owner: Owner, granule: usize) [*]u8 {
        return self.rangeBase(owner) + self.layout.mapBytes() + granule * granule_bytes;
    }

    fn ownerOf(self: *const Heap, ptr: *const anyopaque) Owner {
        return @intCast((@intFromPtr(ptr) - @intFromPtr(self.base)) / self.layout.range_bytes);
    }

    fn granuleOf(self: *const Heap, owner: Owner, ptr: *const anyopaque) usize {
        return (@intFromPtr(ptr) - @intFromPtr(self.granuleAddress(owner, 0))) / granule_bytes;
    }

    fn runHead(self: *const Heap, owner: Owner, start: usize) *FreeRun {
        return @ptrCast(@alignCast(self.granuleAddress(owner, start)));
    }

    fn runFooter(self: *const Heap, owner: Owner, last: usize) *usize {
        return @ptrCast(@alignCast(self.granuleAddress(owner, last) + granule_bytes - @sizeOf(usize)));
    }

    /// Commit the bump region through `end` bytes from the range start.
    fn ensureCommitted(self: *Heap, owner: Owner, end: usize) bool {
        const range = &self.ranges[owner];
        if (end <= range.committed) return true;
        const target = @min(std.mem.alignForward(usize, end, commit_step), self.layout.range_bytes);
        if (!commit(self.rangeBase(owner) + range.committed, target - range.committed)) return false;
        range.committed = target;
        return true;
    }

    fn commitGranules(self: *Heap, owner: Owner, start: usize, count: usize) bool {
        const first = std.mem.alignBackward(usize, @intFromPtr(self.granuleAddress(owner, start)), page_bytes);
        const end = std.mem.alignForward(usize, @intFromPtr(self.granuleAddress(owner, start + count)), page_bytes);
        return commit(@ptrFromInt(first), end - first);
    }

    /// Decommit the pages wholly inside free granules [start, start+count),
    /// keeping the head and footer pages.
    fn decommitInterior(self: *Heap, owner: Owner, start: usize, count: usize) void {
        const head_end = @intFromPtr(self.granuleAddress(owner, start)) + @sizeOf(FreeRun);
        const footer = @intFromPtr(self.runFooter(owner, start + count - 1));
        const first = std.mem.alignForward(usize, head_end, page_bytes);
        const end = std.mem.alignBackward(usize, footer, page_bytes);
        if (end > first) decommit(@ptrFromInt(first), end - first);
    }

    fn unlink(self: *Heap, owner: Owner, run: *FreeRun) void {
        if (run.prev) |prev| prev.next = run.next else self.ranges[owner].free_runs = run.next;
        if (run.next) |next| next.prev = run.prev;
    }

    /// Record granules [start, start+count) as one free run, merging with
    /// free neighbours, or hand them back to the top of the range.
    fn freeGranules(self: *Heap, owner: Owner, first_granule: usize, first_count: usize) void {
        const range = &self.ranges[owner];
        const granules = self.map(owner);
        var start = first_granule;
        var count = first_count;
        const after = start + count;
        if (after < range.bump and granules[after] == free_start) {
            const next = self.runHead(owner, after);
            self.unlink(owner, next);
            count += next.granules;
        }
        if (start > 0 and (granules[start - 1] == free_start or granules[start - 1] == free_rest)) {
            const previous_count = self.runFooter(owner, start - 1).*;
            start -= previous_count;
            self.unlink(owner, self.runHead(owner, start));
            count += previous_count;
        }
        if (start + count == range.bump) {
            // The top of the range: give it back to the bump region and
            // decommit what is no longer reachable from below.
            range.bump = start;
            const keep = std.mem.alignForward(usize, self.layout.mapBytes() + start * granule_bytes, page_bytes);
            if (range.committed > keep) {
                decommit(self.rangeBase(owner) + keep, range.committed - keep);
                range.committed = keep;
            }
            return;
        }
        granules[start] = free_start;
        @memset(granules[start + 1 .. start + count], free_rest);
        const run = self.runHead(owner, start);
        run.* = .{ .prev = null, .next = range.free_runs, .granules = count };
        if (range.free_runs) |head| head.prev = run;
        range.free_runs = run;
        self.runFooter(owner, start + count - 1).* = count;
        self.decommitInterior(owner, start, count);
    }

    /// `count` contiguous committed granules: a free run that fits, else
    /// fresh ones from the top of the range.
    fn takeGranules(self: *Heap, owner: Owner, count: usize) ?usize {
        const range = &self.ranges[owner];
        var cursor = range.free_runs;
        while (cursor) |run| : (cursor = run.next) {
            if (run.granules < count) continue;
            const start = self.granuleOf(owner, run);
            const remaining = run.granules - count;
            self.unlink(owner, run);
            if (!self.commitGranules(owner, start, run.granules)) return null;
            // Taken before the remainder is freed, so its merge check does
            // not see these granules as a free neighbour.
            @memset(self.map(owner)[start .. start + count], run_rest);
            if (remaining > 0) self.freeGranules(owner, start + count, remaining);
            return start;
        }
        if (range.bump + count > self.layout.granulesPerRange()) return null;
        const start = range.bump;
        if (!self.ensureCommitted(owner, self.layout.mapBytes() + (start + count) * granule_bytes)) return null;
        range.bump += count;
        return start;
    }

    pub fn alloc(self: *Heap, size: usize) ?*anyopaque {
        return self.allocFor(self.current, size);
    }

    fn allocFor(self: *Heap, owner: Owner, size: usize) ?*anyopaque {
        if (size == 0) return null;
        const range = &self.ranges[owner];
        if (size <= small_max) {
            const class = classFor(size);
            if (range.free_blocks[class] == null) {
                const granule = self.takeGranules(owner, 1) orelse return null;
                self.map(owner)[granule] = @intCast(class);
                const block_size: usize = class_sizes[class];
                const first = self.granuleAddress(owner, granule);
                var offset: usize = granule_bytes - granule_bytes % block_size;
                while (offset >= block_size) {
                    offset -= block_size;
                    const block: *FreeBlock = @ptrCast(@alignCast(first + offset));
                    block.next = range.free_blocks[class];
                    range.free_blocks[class] = block;
                }
            }
            const block = range.free_blocks[class].?;
            range.free_blocks[class] = block.next;
            range.used += class_sizes[class];
            return block;
        }
        const count = runGranules(size);
        const start = self.takeGranules(owner, count) orelse return null;
        self.markRun(owner, start, count);
        range.used += count * granule_bytes - header_bytes;
        return self.granuleAddress(owner, start) + header_bytes;
    }

    fn markRun(self: *Heap, owner: Owner, start: usize, count: usize) void {
        const granules = self.map(owner);
        granules[start] = run_start;
        @memset(granules[start + 1 .. start + count], run_rest);
        const header: *usize = @ptrCast(@alignCast(self.granuleAddress(owner, start)));
        header.* = count;
    }

    fn runCount(ptr: *const anyopaque) usize {
        return @as(*const usize, @ptrCast(@alignCast(@as([*]const u8, @ptrCast(ptr)) - header_bytes))).*;
    }

    pub fn usableSize(self: *const Heap, ptr: *const anyopaque) usize {
        const owner = self.ownerOf(ptr);
        const kind = self.map(owner)[self.granuleOf(owner, ptr)];
        if (kind < class_sizes.len) return class_sizes[kind];
        return runCount(ptr) * granule_bytes - header_bytes;
    }

    pub fn free(self: *Heap, ptr: *anyopaque) void {
        const owner = self.ownerOf(ptr);
        const range = &self.ranges[owner];
        const granule = self.granuleOf(owner, ptr);
        const kind = self.map(owner)[granule];
        if (kind < class_sizes.len) {
            const block: *FreeBlock = @ptrCast(@alignCast(ptr));
            block.next = range.free_blocks[kind];
            range.free_blocks[kind] = block;
            range.used -= class_sizes[kind];
            return;
        }
        std.debug.assert(kind == run_start);
        const count = runCount(ptr);
        range.used -= count * granule_bytes - header_bytes;
        self.freeGranules(owner, granule, count);
    }

    /// Give back the small-class granules of `owner` whose blocks are all
    /// free, merging and decommitting them like freed runs. Compiling leaves
    /// many freed small blocks spread across granules a few survivors pin;
    /// without a trim those granules stay resident.
    pub fn trim(self: *Heap, owner: Owner, scratch: std.mem.Allocator) !void {
        const range = &self.ranges[owner];
        if (range.bump == 0) return;
        const free_counts = try scratch.alloc(u8, range.bump);
        defer scratch.free(free_counts);
        for (&range.free_blocks, 0..) |*head, class| {
            @memset(free_counts, 0);
            var cursor = head.*;
            while (cursor) |block| : (cursor = block.next) free_counts[self.granuleOf(owner, block)] += 1;
            const per_granule: u8 = @intCast(granule_bytes / class_sizes[class]);
            var link = head;
            while (link.*) |block| {
                if (free_counts[self.granuleOf(owner, block)] == per_granule) {
                    link.* = block.next;
                } else {
                    link = &block.next;
                }
            }
            for (free_counts, 0..) |count, granule| {
                if (count == per_granule and self.map(owner)[granule] == class) self.freeGranules(owner, granule, 1);
            }
        }
    }

    /// Grow or shrink in the block's own range, so an object stays with the
    /// widget that made it. The block at the top of its range grows in place.
    pub fn realloc(self: *Heap, ptr: ?*anyopaque, size: usize) ?*anyopaque {
        const old = ptr orelse return self.alloc(size);
        if (size == 0) {
            self.free(old);
            return null;
        }
        const usable = self.usableSize(old);
        if (size <= usable) return old;
        const owner = self.ownerOf(old);
        const range = &self.ranges[owner];
        const granule = self.granuleOf(owner, old);
        if (size > small_max and self.map(owner)[granule] == run_start) {
            const count = runCount(old);
            const wanted = runGranules(size);
            if (granule + count == range.bump and granule + wanted <= self.layout.granulesPerRange() and
                self.ensureCommitted(owner, self.layout.mapBytes() + (granule + wanted) * granule_bytes))
            {
                range.bump = granule + wanted;
                self.markRun(owner, granule, wanted);
                range.used += (wanted - count) * granule_bytes;
                return old;
            }
        }
        const moved = self.allocFor(owner, size) orelse return null;
        @memcpy(@as([*]u8, @ptrCast(moved))[0..usable], @as([*]const u8, @ptrCast(old))[0..usable]);
        self.free(old);
        return moved;
    }
};

fn runGranules(size: usize) usize {
    return (size + header_bytes + granule_bytes - 1) / granule_bytes;
}

fn classFor(size: usize) usize {
    for (class_sizes, 0..) |class_size, index| {
        if (size <= class_size) return index;
    }
    unreachable;
}

extern "kernel32" fn VirtualAlloc(address: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(address: ?*anyopaque, size: usize, kind: u32) callconv(.winapi) std.os.windows.BOOL;
const mem_commit: u32 = 0x1000;
const mem_reserve: u32 = 0x2000;
const mem_decommit: u32 = 0x4000;
const mem_release: u32 = 0x8000;
const page_noaccess: u32 = 0x01;
const page_readwrite: u32 = 0x04;

/// Address space only: nothing commits until a range grows into it.
fn reserve(bytes: usize) ![*]u8 {
    if (builtin.os.tag == .windows) {
        const address = VirtualAlloc(null, bytes, mem_reserve, page_noaccess) orelse return error.OutOfMemory;
        return @ptrCast(address);
    }
    const mapped = std.posix.mmap(null, bytes, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = builtin.os.tag == .linux }, -1, 0) catch return error.OutOfMemory;
    return mapped.ptr;
}

fn commit(address: [*]u8, bytes: usize) bool {
    if (bytes == 0) return true;
    if (builtin.os.tag == .windows) return VirtualAlloc(address, bytes, mem_commit, page_readwrite) != null;
    return std.c.mprotect(@ptrCast(@alignCast(address)), bytes, .{ .READ = true, .WRITE = true }) == 0;
}

/// Give pages back: their contents are gone and they leave the working set.
fn decommit(address: [*]u8, bytes: usize) void {
    if (builtin.os.tag == .windows) {
        _ = VirtualFree(address, bytes, mem_decommit);
        return;
    }
    const pages: []align(page_bytes) u8 = @alignCast(address[0..bytes]);
    std.posix.madvise(pages.ptr, pages.len, std.posix.MADV.DONTNEED) catch {};
    _ = std.c.mprotect(pages.ptr, pages.len, .{});
}

fn release(address: [*]u8, bytes: usize) void {
    if (builtin.os.tag == .windows) {
        _ = VirtualFree(address, 0, mem_release);
        return;
    }
    const pages: []align(page_bytes) u8 = @alignCast(address[0..bytes]);
    std.posix.munmap(pages);
}

test "allocations stay in their owner's range and free by address" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 3, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);

    heap.current = 0;
    const a = heap.alloc(24).?;
    const big = heap.alloc(5000).?;
    const pin = heap.alloc(5000).?;
    heap.current = 1;
    const b = heap.alloc(24).?;
    try std.testing.expectEqual(@as(Owner, 0), heap.ownerOf(a));
    try std.testing.expectEqual(@as(Owner, 0), heap.ownerOf(big));
    try std.testing.expectEqual(@as(Owner, 1), heap.ownerOf(b));
    try std.testing.expectEqual(@as(usize, 32), heap.usableSize(a));
    try std.testing.expect(heap.usableSize(big) >= 5000);
    try std.testing.expectEqual(@as(usize, 32) + 2 * heap.usableSize(big), heap.usedBytes(0));
    try std.testing.expectEqual(@as(usize, 32), heap.usedBytes(1));

    // Freed in another owner's turn, still credited to its own range; the
    // same class block and the freed run come back.
    heap.free(a);
    heap.free(big);
    try std.testing.expectEqual(heap.usableSize(pin), heap.usedBytes(0));
    heap.current = 0;
    try std.testing.expectEqual(a, heap.alloc(20).?);
    try std.testing.expectEqual(big, heap.alloc(4000).?);
}

test "free runs merge and the top of the range comes back" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    const first = heap.alloc(3000).?;
    const second = heap.alloc(3000).?;
    const third = heap.alloc(3000).?;
    const grown = heap.grownBytes(0);
    heap.free(first);
    heap.free(second);
    // Two neighbouring 3-granule runs merged: a 6-granule block fits where they were.
    try std.testing.expectEqual(first, heap.alloc(6000).?);
    heap.free(third);
    try std.testing.expect(heap.grownBytes(0) < grown);
}

test "the newest block grows in place" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    var buffer: [*]u8 = @ptrCast(heap.alloc(1000).?);
    @memcpy(buffer[0..5], "hello");
    var size: usize = 1000;
    while (size < 64 * 1024) : (size *= 2) {
        const next: [*]u8 = @ptrCast(heap.realloc(buffer, size * 2).?);
        try std.testing.expectEqual(buffer, next);
        buffer = next;
    }
    try std.testing.expectEqualStrings("hello", buffer[0..5]);
    try std.testing.expect(heap.grownBytes(0) <= 130 * 1024);
}

test "realloc keeps contents and the block's owner" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    const small: [*]u8 = @ptrCast(heap.alloc(10).?);
    @memcpy(small[0..10], "abcdefghij");
    heap.current = 1;
    const grown: [*]u8 = @ptrCast(heap.realloc(small, 3000).?);
    try std.testing.expectEqualStrings("abcdefghij", grown[0..10]);
    try std.testing.expectEqual(@as(Owner, 0), heap.ownerOf(grown));
    try std.testing.expectEqual(@as(usize, 0), heap.usedBytes(1));
}

test "trim gives back small-class granules whose blocks are all free" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    var blocks: [256]*anyopaque = undefined;
    for (&blocks) |*block| block.* = heap.alloc(64).?;
    const keep = heap.alloc(5000).?;
    for (blocks[1..]) |block| heap.free(block);
    const grown = heap.grownBytes(0);
    try heap.trim(0, std.testing.allocator);
    // Every granule but the one still holding blocks[0] came back, and the
    // live block is untouched.
    try std.testing.expectEqual(@as(usize, 64) + heap.usableSize(keep), heap.usedBytes(0));
    const again = heap.alloc(64).?;
    try std.testing.expect(heap.ownerOf(again) == 0);
    heap.free(blocks[0]);
    heap.free(again);
    heap.free(keep);
    try heap.trim(0, std.testing.allocator);
    try std.testing.expect(heap.grownBytes(0) < grown);
}

test "a range refuses past its capacity, the cap" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 256 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    var count: usize = 0;
    while (heap.alloc(4096) != null) count += 1;
    // (256 KiB - a 4 KiB granule map) / 5 granules per 4 KiB block.
    try std.testing.expectEqual(@as(usize, 50), count);
    // The other range is untouched by the first one's exhaustion.
    heap.current = 1;
    try std.testing.expect(heap.alloc(4096) != null);
}

test "random allocations keep their contents and their accounting" {
    var heap = try Heap.init(std.testing.allocator, .{ .owners = 2, .range_bytes = 8 * 1024 * 1024 });
    defer heap.deinit(std.testing.allocator);
    heap.current = 0;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const Live = struct { ptr: [*]u8, size: usize, tag: u8 };
    var live: [256]?Live = @splat(null);
    var expected_used: usize = 0;
    for (0..20_000) |step| {
        const index = random.uintLessThan(usize, live.len);
        if (live[index]) |block| {
            for (block.ptr[0..block.size]) |byte| try std.testing.expectEqual(block.tag, byte);
            expected_used -= heap.usableSize(block.ptr);
            if (random.boolean()) {
                heap.free(block.ptr);
                live[index] = null;
                continue;
            }
            const size = 1 + random.uintLessThan(usize, if (random.uintLessThan(u8, 8) == 0) 40_000 else 600);
            const moved: [*]u8 = @ptrCast(heap.realloc(block.ptr, size).?);
            const kept = @min(size, block.size);
            for (moved[0..kept]) |byte| try std.testing.expectEqual(block.tag, byte);
            @memset(moved[0..size], block.tag);
            live[index] = .{ .ptr = moved, .size = size, .tag = block.tag };
            expected_used += heap.usableSize(moved);
        } else {
            const size = 1 + random.uintLessThan(usize, if (random.uintLessThan(u8, 8) == 0) 40_000 else 600);
            const ptr: [*]u8 = @ptrCast(heap.alloc(size).?);
            const tag: u8 = @truncate(step);
            @memset(ptr[0..size], tag);
            live[index] = .{ .ptr = ptr, .size = size, .tag = tag };
            expected_used += heap.usableSize(ptr);
        }
        try std.testing.expectEqual(expected_used, heap.usedBytes(0));
    }
    for (&live) |*slot| if (slot.*) |block| heap.free(block.ptr);
    try std.testing.expectEqual(@as(usize, 0), heap.usedBytes(0));
}

