/// A generic composable allocation library.
///
/// Example:
///
///     // Make an aligned "C heap" allocator that logs on each allocation
///     const a = Alloc.c.log().aligned().slice().init;
///     const s = a.alloc(1234); // s is []u8
///     defer a.dealloc(s);
///
///     // Make an mmap allocator that logs on each allocation
///     const a = Alloc.mmap.log().slice().init;
///     const s = a.alloc(1234); // s is []u8
///     defer a.dealloc(s);
///
///     // Create an allocator that tries to allocate on the stack, then falls back to the C allocator
///     var stackBuffer : [100]u8 = undefiend;
///     const a = Alloc.join(.{
///         Alloc.bumpDown(1, stackBuffer).init,
///         Alloc.c.init,
///     }).slice().init;
///     const s = a.alloc(40);
///     defer a.dealloc(s);
///
/// This library allows every allocator to declare their individual-allocation storage
/// requirements through a custom "Block" type. The Block type stores everything the
/// allocator needs to track individual allocations. It could be just a pointer, or
/// just a slice, or a struct with many fields.
///
/// Using alloctor-defined Block types allows the caller to determine where the Block
/// should be stored and who owns it.  This increases the composibility of allocators
/// as it allows the storage of these blocks to be part of a composable interface.
/// This allows storage for multiple composed allocators to be combined and stored
/// anywhere.
///
/// Most of the allocators in this library can be described as "BlockAllocators", meaning,
/// an allocator that returns and accepts a custom Block type. For applications that want
/// to speak in "slices", the "SliceAllocator" will take any BlockAllocator, and create
/// a slice-based API around it. The SliceAllocator will either function as a straight
/// passthrough to the underlying BlockAllocator, or pad each allocation to store the
/// extra data required for each Block.
///
/// Implementing an Allocator
/// ======================================================================================
/// Every Allocator MUST define a pub struct type named 'Block'.
/// Use the MakeBlockType function to create this type (see MakeBlockType function).
/// Blocks are normally "passed by value" to the allocator, unless the allocator
/// is going to modify it (i.e. extendBlockInPlace).
/// The caller will access the memory pointer through the Block with block.ptr().
/// The pointer may also have an "align(X)" property that indicates all allocations from
/// that allocator will always be aligned by X.
///
/// ### Allocation:
///
///     * allocBlock(len: usize) error{OutOfMemory}!Block
///       assert(len > 0);
///       Allocate `len` bytes.  If Block.hasLen is true, the returned block.len() value must equal `len`.
///
///     * allocOverAlignedBlock(len: usize, alignment: u29) error{OutOfMemory}!Block
///       assert(len > 0);
///       assert(isValidAlign(alignment));
///       assert(alignment > Block.alignment);
///       The "Over" part of "OverAligned" means `alignment` > `Block.alignment`.
///       Use makeAlignAllocator(...) to make an unaligned allocator into one that can make
///       aligned allocations.
///
///     * fuzzyAllocBlock(needLen: usize, wantLen: usize) error{OutOfMemory}!FuzzyResult(Block)
///       assert(needLen > 0);
///       assert(wantLen >= needLen);
///       allocate a block that is at least `needLen` bytes. block.len() will be the actual size
///       reserved for the allocation rather then the size requested and is >= len. Use this if you are
///       going to need some memory but not sure how much you'll need.
///       If the allocator cannot allocate exactly wantLen bytes, it will allocate the next smallest size that
///       is greater than wantLen.  If it cannot, it will allocate the largest size possible that is less than
///       wantLen.
///       I think if an allocator performs 1-byte aligned allocations, it should implement allocBlock, otherwise,
///       it should implement fuzzyAllocBlock.
///       !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///       BumpDownAllocator is a case where it can track 1-byte granular lengths, but aligns as well.  This one
///       could implement both.  However, I could have a wrapper around BumpDownAllocator that translates
///       1-byte-specific lengths to aligned length.  So the core allocator would be fuzzy, and the wrapper
///       would be specific.  I think this might be the right approach.
///       Maybe "SharpAllocator" will take a fuzzy allocator and sharpen it?
///       !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///       TODO: should we just added the needLen and wantLen to allocBlock???
///       Actually, I could make allocBlock optional, and have allocators implmeent fuzzyAllocBlock
///       instead.
///
///     * IDEA: allocMinMax(min: usize, max: usize) error{OutOfMemory}!Block
///
///     * IDEA: allocBlockAvailable(len: usize, available: *[]u8) error{OutOfMemory}!Block
///       Note that an allocator may want to put available in the Block, however, if it doesn't need
///       it then how could it pass this information back to the caller?
///
/// ### Deallocation:
///
///     * deallocBlock(block: Block) void
///       Cannot fail. block must be identical to a block returned by alloc and has maintained any
///       modifications made to it through other allocator functions.
///
///     * deallocAll() void
///       Cannot fail. Deallocates every block in the allocator, but the allocator can still be used.
///
///     * deinitAndDeallocAll() void
///       Cannot fail. Deallocates every block AND deinitializes the allocator so it can no longer be used.
///
/// ### Resizing
///
///     NOTE: I've split extend/retract into separate functions so the allocator can indicate at
///           compile-time whether it supports extend only, retract only, or both.
///
///     * extendBlockInPlace(block: *Block, new_len: usize) error{OutOfMemory}!void
///       assert(new_len > block.len());
///       Extend a block without moving it.
///       Note that block is passed in by reference because the function can modify it.  If it is
///       modified, the caller must pass in the new version for all future calls.
///
///     * retractBlockInPlace(block: *Block, new_len: usize) error{OutOfMemory}!void
///       assert(new_len > 0);
///       assert(new_len < block.len());
///       Retract a block without moving it.
///       Note that retract is equivalent to shrink except that it can fail and will fail if the
///       memory cannot be retracted.  If you just want to make a "best effort" to retract memory,
///       and want the allocator to start tracking the shrunken length, then use shrinkBlockInPlace.
///       Note that block is passed in by reference because the function can modify it.  If it is
///       modified, the caller must pass in the new version for all future calls.
///
///     * Right now this isn't needed, but I'm keeping the doc around it around in case I do need it later
///       resizeBlockNoLenInPlace(block: *Block, new_len: usize) error{OutOfMemory}!void
///       assert(!Block.hasLen);
///       assert(new_len > 0);
///       A allocator may only implement this if Block.hasLen is false.  Otherwise, the caller
///       MUST call either extendBlockInPlace or retractBlockInPlace. This will do the equivalent
///       of either extendBlockInPlace or retractBlockInPlace.
///
///     * TODO: might want to add a method to extend both left and right? expand?
///
/// ### Shrink Block
///
///     * shrinkBlockInPlace(block: *Block, new_len: usize) void
///       assert(new_len > 0); // otherwise, deallocBlock should be called
///       assert(new_len < block.slice.len);
///       Shrink the length of the block.  After this is called, if Block.hasLen is true, then
///       block().len must equal new_len.  This function differs from "retractBlockInPlace" in
///       that it cannot fail. The allocator may or may not be able to use the reclaimed memory,
///       however, once this function is called, the caller does not need to remember the previous
///       length, it is up to the allocator to retain that if it requires it.
///
///       Most allocators likely won't support this directly because it will require extra memory to track
///       any discrepancy between the prevous length and the new shrunken length, in which case
///       you can add support by wrapping any allocator with ShrinkAllocator.
///
/// ### Ownership? (How helpful is this?)
///
///     * IDEA: ownsBlock(block: Block) bool
///       Means the allocator can tell if it owns a block.
///
/// ### Next Block Pointer ??
///
///     * IDEA: nextBlockPtr() [*]u8
///       An allocator could implement this if it's next block pointer is pre-determined.
///       A containing alignment allocator may want to know this to adjust what they need to request for an aligned block.
///     * IDEA: nextBlockPtrWithLen(len: usize) [*]u8
///       Maybe this would be a helpful option as well?
///
/// ### Realloc
///
///     * overrideReallocBlock(block: *Block, new_len: usize) error{OutOfMemory}!void
///       This function is equivalent to C's realloc.
///       This should only be implemented by CAllocator and forwarded by "wrapping allocators".
///       The `reallocBlock` function in this module will implement the `realloc` operation for
///       every allocator using a combination of other operations.  The C allocator is special because
///       it does not support enough operations to support realloc, so we call its realloc function directly.
///
const std = @import("std");
const mem = std.mem;
const os = std.os;
const assert = std.debug.assert;

const testing = std.testing;

/// Creates a Block type that block allocators use to track individual allocations.
pub fn MakeBlockType(
    /// true if the Block tracks slices rather than just pointers.
    comptime hasLen_: bool,
    /// guaranteed alignment for all blocks from the allocator. Must be a power
    /// of 2 that is also >= 1.
    comptime alignment_: u29,
    /// extra data that each block must maintain.
    comptime Extra: type
) type {
    if (!isValidAlign(alignment_)) @compileError("invalid alignment");
    return struct {
        const Buf =
            if (hasLen_) [] align(alignment_) u8
            else         [*]align(alignment_) u8;

        buf: Buf,
        extra: Extra,

        pub const hasLen = hasLen_;
        pub const alignment = alignment_;
        pub const hasExtra = @sizeOf(Extra) != 0;
        pub fn ptr(self: @This()) [*]align(alignment) u8 {
            if (hasLen)
                return self.buf.ptr;
            return self.buf;
        }
        // TODO: will we need to implement ptrRef?
        pub fn slice(self: @This()) []align(alignment) u8 {
            if (!hasLen) @compileError("cannot call .slice() on this Block type because hasLen is false");
            return self.buf;
        }
        pub fn len(self: @This()) usize {
            if (!hasLen) @compileError("cannot call .len() on this Block type because hasLen is false");
            return self.buf.len;
        }
    };
}

/// An allocator Block wrapped in a struct that contains an extra usize field for the length
/// if the Block type does not track the length.
pub fn FuzzyResult(comptime Block: type) type {return struct {
    block: Block,
    extraLen: if (Block.hasLen) struct { } else usize,
    pub fn len(self: @This()) usize {
        return if (Block.hasLen) self.block.len() else self.extraLen;
    }
};}

/// An allocator that always fails.
pub const FailAllocator = struct {
    pub const Block = MakeBlockType(true, 1, struct {});

    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        assert(len > 0);
        return error.OutOfMemory;
    }
    pub fn fuzzyAllocBlock(self: @This(), needLen: usize, wantLen: usize) error{OutOfMemory}!FuzzyResult(Block) {
        assert(needLen > 0);
        assert(wantLen >= needLen);
        return error.OutOfMemory;
    }
    pub fn allocOverAlignedBlock(self: @This(), len: usize, alignment: u29) error{OutOfMemory}!Block {
        assert(len > 0);
        assert(isValidAlign(alignment));
        assert(alignment > Block.alignment);
        return error.OutOfMemory;
    }
    pub const deallocBlock = void;
    pub const deallocAll = void;
    pub const deinitAndDeallocAll = void;
    pub const extendBlockInPlace = void;
    pub const retractBlockInPlace = void;
    pub const overrideReallocBlock = void;
};

pub const CAllocator = struct {
    pub const Block = MakeBlockType(false, 1, struct {});

    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        assert(len > 0);
        const ptr = std.c.malloc(len) orelse return error.OutOfMemory;
        return Block { .buf = @ptrCast([*]u8, ptr), .extra = .{} };
    }
    pub const fuzzyAllocBlock = void;
    pub const allocOverAlignedBlock = void;
    pub fn deallocBlock(self: @This(), block: Block) void {
        std.c.free(block.ptr());
    }
    pub const deallocAll = void;
    pub const deinitAndDeallocAll = void;
    pub const extendBlockInPlace = void;
    pub const retractBlockInPlace = void;
    pub fn overrideReallocBlock(self: @This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        assert(new_len > 0);
        const ptr = std.c.realloc(block.ptr(), new_len)
            orelse return error.OutOfMemory;
        block.buf = @ptrCast([*]u8, ptr);
    }
};

pub const MmapAllocator = struct {
    pub const Block = MakeBlockType(true, mem.page_size, struct {});

    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        assert(len > 0);

        const result = os.mmap(
            null,
            len,
            os.PROT_READ | os.PROT_WRITE,
            os.MAP_PRIVATE | os.MAP_ANONYMOUS,
            -1, 0) catch return error.OutOfMemory;
        return Block { .buf = @alignCast(mem.page_size, result.ptr)[0..len], .extra = .{} };
    }
    // TODO!!! implement fuzzyAllocBlock!!!!! probably remove allocBlock
    pub const fuzzyAllocBlock = void;
    pub const allocOverAlignedBlock = void;
    pub fn deallocBlock(self: @This(), block: Block) void {
        os.munmap(block.slice());
    }
    pub const deallocAll = void;
    pub const deinitAndDeallocAll = void;

    // TODO: move this to std/os/linux.zig
    fn sys_mremap(old_address: [*]align(mem.page_size) u8, old_size: usize, new_size: usize, flags: usize) usize {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TEMPORARY HACK
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        if (std.Target.current.os.tag != .linux) return os.ENOMEM;
        return os.linux.syscall4(.mremap, @ptrToInt(old_address), old_size, new_size, flags);
    }
    fn mremap(buf: []align(mem.page_size) u8, new_len: usize, flags: usize) ![*]u8 {
        const rc = sys_mremap(buf.ptr, buf.len, new_len, flags);
        switch (os.linux.getErrno(rc)) {
            0 => return @intToPtr([*]u8, rc),
            os.EAGAIN => return error.LockedMemoryLimitExceeded,
            os.EFAULT => return error.Fault,
            os.EINVAL => unreachable,
            os.ENOMEM => return error.OutOfMemory,
            else => |err| return os.unexpectedErrno(err),
        }
    }


    pub fn mremapInPlace(block: *Block, new_len: usize) error{OutOfMemory}!void {
        const result = mremap(block.slice(), new_len, 0) catch return error.OutOfMemory;
        assert(result == block.ptr());
        block.buf.len = new_len;
    }
    pub fn extendBlockInPlace(self: @This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        assert(new_len > block.len());
        return mremapInPlace(block, new_len);
    }
    pub fn retractBlockInPlace(self: @This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        assert(new_len > 0);
        assert(new_len < block.len());
        return mremapInPlace(block, new_len);
    }
    pub const overrideReallocBlock = void;
};

/// Simple Fast allocator. Tradeoff is that it can only re-use blocks if they are deallocated
/// in LIFO stack order.
///
/// The Up/Down detail is exposed because they have different behavior.
/// The BumpDownAllocator means that in-place extend/retract is much more limited than
/// an BumpUpAllocator which is only limited by the amount of memory it has.
///
/// I'm not sure what the advantage of a DownwasBumpAllocator is, maybe it is more efficient?
///     see https://fitzgeraldnick.com/2019/11/01/always-bump-downwards.html
///
/// TODO: would it be worth it to create alignForward/alignBackward functions with a comptime alignment?
pub fn makeBumpDownAllocator(comptime alignment: u29, buf: []u8) BumpDownAllocator(alignment) {
    return BumpDownAllocator(alignment).init(buf);
}
pub fn BumpDownAllocator(comptime alignment : u29) type {return struct {
    pub const Block = MakeBlockType(true, alignment, struct {});

    buf: []u8,
    bumpIndex: usize, // MUST ALWAYS be aligned
    pub fn init(buf: []u8) @This() {
        return .{ .buf = buf, .bumpIndex = getStartBumpIndex(buf) };
    }
    // We must ensure bumpIndex is aligned when it is initialized
    fn getStartBumpIndex(buf: []u8) usize {
        const endAddr = @ptrToInt(buf.ptr) + buf.len;
        const alignedEndAddr = mem.alignBackward(endAddr, alignment);
        if (alignedEndAddr < @ptrToInt(buf.ptr)) return 0;
        return alignedEndAddr - @ptrToInt(buf.ptr);
    }
    fn getBlockIndex(self: @This(), block: Block) usize {
        assert(@ptrToInt(block.ptr()) >= @ptrToInt(self.buf.ptr));
        return @ptrToInt(block.ptr()) - @ptrToInt(self.buf.ptr);
    }

    pub fn allocBlock(self: *@This(), len: usize) error{OutOfMemory}!Block {
        assert(len > 0);

        const alignedLen = mem.alignForward(len, alignment);
        if (alignedLen > self.bumpIndex)
            return error.OutOfMemory;
        const bufIndex = self.bumpIndex - alignedLen;
        self.bumpIndex = bufIndex;
        return Block { .buf = @alignCast(alignment, self.buf[bufIndex..bufIndex+len]), .extra = .{} };
    }
    // TODO: implement fuzzyAllocBlock, probably remove allocBlock
    pub const fuzzyAllocBlock = void;
    pub const allocOverAlignedBlock = void;
    pub fn deallocBlock(self: *@This(), block: Block) void {
        if (self.bumpIndex == self.getBlockIndex(block)) {
            self.bumpIndex += mem.alignForward(block.len(), alignment);
        }
    }
    pub fn deallocAll(self: *@This()) void {
        self.bumpIndex = getStartBumpIndex(self.buf);
    }
    pub const deinitAndDeallocAll = void;
    pub fn extendBlockInPlace(self: *@This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        assert(new_len > block.len());
        const alignedLen = mem.alignForward(block.len(), alignment);
        if (new_len > alignedLen)
            return error.OutOfMemory;
        block.buf.len = new_len;
    }
    pub fn retractBlockInPlace(self: *@This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        assert(new_len > 0);
        assert(new_len < block.len());
        // we must ensure that the aligned length remains the same
        // in order ensure that deallocBlock in LIFO order always works
        const minSize = mem.alignBackward(block.len(), alignment) + 1;
        if (new_len < minSize)
            return error.OutOfMemory;
        block.buf.len = new_len;
    }
    pub const overrideReallocBlock = void;
};}

// The windows heap provided by kernel32
pub const WindowsHeapAllocator = struct {
    // TODO: can we assume HeapAlloc will always have a certain alignment?
    pub const Block = MakeBlockType(false, 1, struct {});

    handle: os.windows.HANDLE,

    pub fn init(handle: os.windows.HANDLE) @This() {
        return @This() { .handle = handle };
    }

    /// Type-specific function to be able to pass in windows-specific flags
    pub fn heapAlloc(self: @This(), len: usize, flags: u32) error{OutOfMemory}!Block {
        const result = os.windows.kernel32.HeapAlloc(self.handle, flags, len) orelse return error.OutOfMemory;
        return Block { .buf = @ptrCast([*]u8, result), .extra = .{} };
    }
    /// Type-specific function to be able to pass in windows-specific flags
    pub fn heapFree(self: @This(), block: Block, flags: u32) void {
        os.windows.HeapFree(self.handle, flags, block.ptr());
    }
    const HEAP_REALLOC_IN_PLACE_ONLY : u32 = 0x00000010; // TODO: move this to os.windows
    /// Type-specific function to be able to pass in windows-specific flags
    fn heapReAlloc(self: @This(), block: *Block, new_len: usize, flags: u32) error{OutOfMemory}!void {
        const result = os.windows.kernel32.HeapReAlloc(self.handle,
            flags | HEAP_REALLOC_IN_PLACE_ONLY, block.ptr(), new_len) orelse return error.OutOfMemory;
        assert(@ptrToInt(result) == @ptrToInt(block.ptr()));
    }

    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        // TODO: use HEAP_NO_SERIALIZE flag if we are single-threaded?
        return self.heapAlloc(len, 0);
    }
    pub const allocOverAlignedBlock = void;
    pub fn deallocBlock(self: @This(), block: Block) void {
        // TODO: use HEAP_NO_SERIALIZE flag if we are single-threaded?
        return self.heapFree(block, 0);
    }
    pub const deallocAll = void;
    /// WARNING: if this is the global process heap, you probably don't want to destroy it
    pub fn deinitAndDeallocAll(self: @This()) void {
        os.windows.HeapDestroy(self.handle);
    }
    pub fn extendBlockInPlace(self: @This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        // TODO: use HEAP_NO_SERIALIZE flag if we are single-threaded?
        return self.heapReAlloc(block, new_len, 0);
    }
    pub fn retractBlockInPlace(self: @This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        // TODO: use HEAP_NO_SERIALIZE flag if we are single-threaded?
        return self.heapReAlloc(block, new_len, 0);
    }
    pub const overrideReallocBlock = void;
};

pub fn getProcessHeapWindows() !os.windows.HANDLE {
    return os.windows.kernel32.GetProcessHeap() orelse switch (os.windows.kernel32.GetLastError()) {
        else => |err| return os.windows.unexpectedError(err),
    };
}

/// Global version of WindowsHeapAllocator that doesn't require runtime initialization.
pub const WindowsGlobalHeapAllocator = struct {
    pub const Block = WindowsHeapAllocator.Block;

    pub fn getInstance() WindowsHeapAllocator {
        return WindowsHeapAllocator.init(getProcessHeapWindows() catch unreachable);
    }
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        return try getInstance().allocBlock(len);
    }
    pub const allocOverAlignedBlock = void;
    pub fn deallocBlock(self: @This(), block: Block) void {
        getInstance().deallocBlock(block);
    }
    pub const deallocAll = void;

    /// deinitAndDeallocAll disabled because normally you don't want to destroy the global process
    /// heap. Note that ther user could still call this via: getInstance().deinitAndDeallocAll()
    pub const deinitAndDeallocAll = void;

    pub fn extendBlockInPlace(self: @This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        return try getInstance().extendBlockInPlace(block, new_len);
    }
    pub fn retractBlockInPlace(self: @This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        return try getInstance().retractBlockInPlace(block, new_len);
    }
    pub const overrideReallocBlock = void;
};

test "WindowsHeapAllocator" {
    if (std.Target.current.os.tag != .windows) return;

    testBlockAllocator(&WindowsGlobalHeapAllocator { });
    testBlockAllocator(&makeAlignAllocator(WindowsGlobalHeapAllocator { }));
    testSliceAllocator(&makeSliceAllocator(WindowsGlobalHeapAllocator { }));
    testSliceAllocator(&makeSliceAllocator(makeAlignAllocator(WindowsGlobalHeapAllocator { })));

    // TODO: test private heaps with HeapAlloc
    //{
    //    var a = WindowsHeapAllocator.init(HeapAlloc(...));
    //    defer a.deinitAndDeallocAll();
    //    testBlockAllocator(&a);
    //    ...
    //}
}

// TODO: make SlabAllocator?
// TODO: make a SanityAllocator that saves all the blocks and ensures every call passes in valid blocks.
// TODO: make a LockingAllocator/ThreadSafeAllocator that can wrap any other allocator?

///// Takes care of calling either extendBlockInPlace or retractBlockInPlace
//pub fn resizeBlockInPlace(allocator: var, block: *@TypeOf(allocator.*).Block, new_len: usize) error{OutOfMemory}!void {
//    assert(new_len > 0);
//
//    const T = @TypeOf(allocator.*);
//    if (comptime T.Block.hasLen) {
//        if (implements(T, "resizeBlockNoLenInPlace"))
//            @compileError(@typeName(T) ++ " MUST NOT implement resizeBlockNoLenInPlace because Block.hasLen is true");
//        if (new_len > block.len())
//            return allocator.extendBlockInPlace(block, new_len);
//        if (new_len < block.len())
//            return allocator.retractBlockInPlace(block, new_len);
//        std.debug.panic("resizeBlockInPlace new_len == block.len() ({})", .{new_len});
//    } else {
//        if (!implements(T, "resizeBlockNoLenInPlace"))
//            return error.OutOfMemory;
//        return allocator.resizeBlockNoLenInPlace(block, new_len);
//    }
//}

/// reallocBlock can only be called on an allocator if it implements overrideReallocBlock
/// (i.e. CAllocator or a wrapping allocator) or if Block.hasLen is true.
pub fn reallocBlockSupported(comptime T: type) bool {
    return implements(T, "overrideReallocBlock") or T.Block.hasLen;
}

//!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// TODO: I might just require the client to pass in the original alignment for realloc!!!

/// Equivalent to C's realloc. All allocators will share a common implementation of this except
/// for the C allocator which has its own implementation.
pub fn reallocBlock(allocator: var, block: *@TypeOf(allocator.*).Block, new_len: usize) error{OutOfMemory}!void {
    assert(new_len > 0);

    const T = @TypeOf(allocator.*);

    if (comptime implements(T, "overrideReallocBlock")) {
        return allocator.overrideReallocBlock(block, new_len);
    }

    // We cannot support reallocBlock without knowing the block length because if we need to
    // move the memory, we need to know how big it is to copy the data
    if (!T.Block.hasLen)
        @compileError(@typeName(T) ++ ": cannot call reallocBlock because Block.hasLen is false");

    // I would normally assert here and not support it, but I bet C's realloc is fine with this
    // and we want to match C's realloc
    if (block.len() == new_len)
        return;
    // first try resizing in place to avoid having to copy the data
    if (new_len > block.len()) {
        if (comptime implements(T, "extendBlockInPlace")) {
            if (allocator.extendBlockInPlace(block, new_len)) |_| {
                return;
            } else |_| { }
        }
    } else { // new_len < block.len()
        if (comptime implements(T, "retractBlockInPlace")) {
            if (allocator.retractBlockInPlace(block, new_len)) |_| {
                return;
            } else |_| { }
        }
    }

    // TODO: try expanding the block in both directions, will require a copy but should
    //       be better on the cache and cause less fragmentation

    // fallback to creating a new block and copying the data
    const newBlock = try allocator.allocBlock(new_len);
    @memcpy(newBlock.ptr(), block.ptr(), block.len());
    deallocBlockIfSupported(allocator, block.*);
    block.* = newBlock;
}

pub fn makeLogAllocator(allocator: var) LogAllocator(@TypeOf(allocator)) {
    return LogAllocator(@TypeOf(allocator)) { .allocator = allocator };
}
// TODO: log to an output stream rather than directly to stderr
pub fn LogAllocator(comptime T: type) type {
    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();
        const Block = T.Block;
        allocator: T,
        pub usingnamespace if (!implements(T, "allocBlock")) struct {
            pub const allocBlock = void;
        } else struct {
            pub fn allocBlock(self: SelfRef, len: usize) error{OutOfMemory}!Block {
                std.debug.warn("{}: allocBlock len={}\n", .{@typeName(T), len});
                const result = try self.allocator.allocBlock(len);
                std.debug.warn("{}: allocBlock returning {}\n", .{@typeName(T), result.ptr()});
                return result;
            }
        };
        pub usingnamespace if (!implements(T, "fuzzyAllocBlock")) struct {
            pub const fuzzyAllocBlock = void;
        } else struct {
            pub fn fuzzyAllocBlock(self: SelfRef, needLen: usize, wantLen: usize) error{OutOfMemory}!FuzzyResult(Block) {
                std.debug.warn("{}: fuzzyAllocBlock needLen={} wantLen={}\n", .{@typeName(T), needLen, wantLen});
                const result = try self.allocator.fuzzyAllocBlock(needLen, wantLen);
                std.debug.warn("{}: fuzzyAllocBlock returning {}:{}\n", .{@typeName(T), result.block.ptr(), result.len()});
                return result;
            }
        };
        pub usingnamespace if (!implements(T, "allocOverAlignedBlock")) struct {
            pub const allocOverAlignedBlock = void;
        } else struct {
            pub fn allocOverAlignedBlock(self: SelfRef, len: usize, allocAlign: u29) error{OutOfMemory}!Block {
                std.debug.warn("{}: allocOverAlignedBlock len={} align={}\n", .{@typeName(T), len, allocAlign});
                const result = try self.allocator.allocOverAlignedBlock(len, allocAlign);
                std.debug.warn("{}: allocOverAlignedBlock returning {}\n", .{@typeName(T), result.ptr()});
                return result;
            }
        };

        pub usingnamespace if (!implements(T, "deallocBlock")) struct {
            pub const deallocBlock = void;
        } else struct {
            pub fn deallocBlock(self: SelfRef, block: Block) void {
                if (comptime Block.hasLen) {
                    std.debug.warn("{}: deallocBlock ptr={} len={}\n", .{@typeName(T), block.ptr(), block.len()});
                } else {
                    std.debug.warn("{}: deallocBlock ptr={}\n", .{@typeName(T), block.ptr()});
                }
                return self.allocator.deallocBlock(block);
            }
        };
        pub usingnamespace if (!implements(T, "deallocAll")) struct {
            pub const deallocAll = void;
        } else struct {
            pub fn deallocAll(self: SelfRef) void {
                std.debug.warn("{}: deallocAll\n", .{});
                return self.allocator.deallocAll();
            }
        };
        pub usingnamespace if (!implements(T, "deinitAndDeallocAll")) struct {
            pub const deinitAndDeallocAll = void;
        } else struct {
            pub fn deinitAndDeallocAll(self: SelfRef) void {
                std.debug.warn("{}: deinitAndDeallocAll\n", .{});
                return self.allocator.deinitAndDeallocAll();
            }
        };
        pub usingnamespace if (!implements(T, "extendBlockInPlace")) struct {
            pub const extendBlockInPlace = void;
        } else struct {
            pub fn extendBlockInPlace(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                if (comptime Block.hasLen) {
                    std.debug.warn("{}: extendBlockInPlace {}:{} new_len={}\n", .{@typeName(T), block.ptr(), block.len(), new_len});
                } else {
                    std.debug.warn("{}: extendBlockInPlace {} new_len={}\n", .{@typeName(T), block.ptr(), new_len});
                }
                return try self.allocator.extendBlockInPlace(block, new_len);
            }
        };
        pub usingnamespace if (!implements(T, "retractBlockInPlace")) struct {
            pub const retractBlockInPlace = void;
        } else struct {
            pub fn retractBlockInPlace(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                if (comptime Block.hasLen) {
                    std.debug.warn("{}: retractBlockInPlace {}:{} new_len={}\n", .{@typeName(T), block.ptr(), block.len(), new_len});
                } else {
                    std.debug.warn("{}: retractBlockInPlace {} new_len={}\n", .{@typeName(T), block.ptr(), new_len});
                }
                return try self.allocator.retractBlockInPlace(block, new_len);
            }
        };

        pub usingnamespace if (!implements(T, "overrideReallocBlock")) struct {
            pub const overrideReallocBlock = void;
        } else struct {
            pub fn overrideReallocBlock(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                if (comptime Block.hasLen) {
                    std.debug.warn("{}: overrideReallocBlock {}:{} new_len={}\n", .{@typeName(T), block.ptr(), block.len(), new_len});
                } else {
                    std.debug.warn("{}: overrideReallocBlock {} new_len={}\n", .{@typeName(T), block.ptr(), new_len});
                }
                try self.allocator.overrideReallocBlock(block, new_len);
                std.debug.warn("{}: overrideReallocBlock returning {}\n", .{@typeName(T), block.ptr()});
            }
        };
    };
}

pub fn makeAlignAllocator(allocator: var) AlignAllocator(@TypeOf(allocator)) {
    return AlignAllocator(@TypeOf(allocator)) { .allocator = allocator };
}
pub fn AlignAllocator(comptime T: type) type {
    if (implements(T, "allocOverAlignedBlock"))
        @compileError("cannot wrap '" ++ @typeName(T) ++ "' with AlignAllocator because it already implements allocOverAlignedBlock");
    const ForwardBlock = T.Block;
    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();
        // we need to store alignment if we implement overrideReallocBlock
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // zig's mem.Allocator already passes in the original alignment to realloc
        // so, we could just always require the caller do that for this special case
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        const reallocSupported = implements(T, "overrideReallocBlock");
        const Extra = if (reallocSupported)
            struct { forwardBlock: ForwardBlock, alignment: u29 }
        else
            struct { forwardBlock: ForwardBlock };

        const Block = MakeBlockType(ForwardBlock.hasLen, ForwardBlock.alignment, Extra);
        allocator: T,

        /// returns the offset of the aligned block from the underlying allocated block
        fn getAlignOffset(block: *Block) usize {
            return @ptrToInt(block.ptr()) - @ptrToInt(block.extra.forwardBlock.ptr());
        }

        pub fn allocBlock(self: SelfRef, len: usize) error{OutOfMemory}!Block {
            const forwardBlock = try self.allocator.allocBlock(len);
            if (comptime reallocSupported)
                return Block { .buf = forwardBlock.buf, .extra = .{.forwardBlock = forwardBlock, .alignment = 1} };
            return Block { .buf = forwardBlock.buf, .extra = .{.forwardBlock = forwardBlock} };
        }
        pub usingnamespace if (!implements(T, "fuzzyAllocBlock")) struct {
            pub const fuzzyAllocBlock = void;
        } else struct {
            pub fn fuzzyAllocBlock(self: SelfRef, needLen: usize, wantLen: usize) error{OutOfMemory}!FuzzyResult(Block) {
                const result = try self.allocator.fuzzyAllocBlock(needLen, wantLen);
                //if (comptime reallocSupported)
                //    return Block { .buf = forwardBlock.buf, .extra = .{.forwardBlock = forwardBlock, .alignment = 1} };
                //return Block { .buf = forwardBlock.buf, .extra = .{.forwardBlock = forwardBlock} };
            }
        };
        pub fn allocOverAlignedBlock(self: SelfRef, len: usize, allocAlign: u29) error{OutOfMemory}!Block {
            assert(len > 0);
            assert(isValidAlign(allocAlign));
            assert(allocAlign > Block.alignment);

            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: check if allocator as nextAllocAlign/nextPointer so we can limit how much
            //       we need to allocate
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

            // TODO: if the allocator supports extendBlockInPlace, we could try to allocate a buffer
            //       and extend it if we need more alignment, then if it supports retract we could try
            //       calling retract (note: retract, rather than shrink would be the right choice in
            //       this case, and handling failure by keeping the extra memory for ourselves)

            // at this point all we can do is allocate more to guarantee we'll get an aligend buffer of len bytes.
            // We need to allocate len, plus, the maximum span we would need to drop to find an aligned address.
            // TODO: instead of (- Block.alignment), (- self.allocator.nextAlignment())
            const maxDropLen = allocAlign - Block.alignment;
            const allocLen : usize = len + maxDropLen;
            const forwardBlock = try self.allocator.allocBlock(allocLen);
            const alignedPtr = @alignCast(Block.alignment,
                @intToPtr([*]u8, mem.alignForward(@ptrToInt(forwardBlock.ptr()), allocAlign))
            );
            if (comptime ForwardBlock.hasLen) {
                if (comptime reallocSupported)
                    return Block { .buf = alignedPtr[0..len], .extra = .{.forwardBlock = forwardBlock, .alignment = allocAlign} };
                return Block { .buf = alignedPtr[0..len], .extra = .{.forwardBlock = forwardBlock} };
            }
            if (comptime reallocSupported)
                return Block { .buf = alignedPtr, .extra = .{.forwardBlock = forwardBlock, .alignment = allocAlign } };
            return Block { .buf = alignedPtr, .extra = .{.forwardBlock = forwardBlock} };
        }
        pub usingnamespace if (!implements(T, "deallocBlock")) struct {
            pub const deallocBlock = void;
        } else struct {
            pub fn deallocBlock(self: SelfRef, block: Block) void {
                return self.allocator.deallocBlock(block.extra.forwardBlock);
            }
        };
        pub usingnamespace if (!implements(T, "deallocAll")) struct {
            pub const deallocAll = void;
        } else struct {
            pub fn deallocAll(self: SelfRef) void {
                return self.allocator.deallocAll();
            }
        };
        pub usingnamespace if (!implements(T, "deinitAndDeallocAll")) struct {
            pub const deinitAndDeallocAll = void;
        } else struct {
            pub fn deinitAndDeallocAll(self: SelfRef) void {
                return self.allocator.deinitAndDeallocAll();
            }
        };
        pub usingnamespace if (!implements(T, "extendBlockInPlace")) struct {
            pub const extendBlockInPlace = void;
        } else struct {
            pub fn extendBlockInPlace(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                if (ForwardBlock.hasLen) assert(new_len > block.len());

                const newFullLen = getAlignOffset(block) + new_len;
                // because we may have over-allocated, there could be alot of room available
                // and we MUST check this before calling extendBlockInPlace because the size we request
                // must be larger than what is already allocated
                var extendNeeded = true;
                if (ForwardBlock.hasLen) {
                    if (block.extra.forwardBlock.len() >= newFullLen)
                        extendNeeded = false;
                }
                if (extendNeeded) {
                    try self.allocator.extendBlockInPlace(&block.extra.forwardBlock, newFullLen);
                    if (ForwardBlock.hasLen) {
                        assert(block.extra.forwardBlock.len() == newFullLen);
                    }
                }
                if (ForwardBlock.hasLen)
                    block.buf.len = new_len;
            }
        };
        pub usingnamespace if (!implements(T, "retractBlockInPlace")) struct {
            pub const retractBlockInPlace = void;
        } else struct {
            pub fn retractBlockInPlace(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                assert(new_len > 0);
                if (ForwardBlock.hasLen) assert(new_len < block.len());

                const newFullLen = getAlignOffset(block) + new_len;
                try self.allocator.retractBlockInPlace(&block.extra.forwardBlock, newFullLen);
                if (ForwardBlock.hasLen) {
                    assert(block.extra.forwardBlock.len() == newFullLen);
                }
                block.buf.len = new_len;
            }
        };

        pub usingnamespace if (!reallocSupported) struct {
            pub const overrideReallocBlock = void;
        } else struct {
            // Note that this maintains the alignment from the original allocOverAlignedBlock call
            pub fn overrideReallocBlock(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                assert(new_len > 0);
                const maxDropLen = block.extra.alignment - Block.alignment;
                const allocLen = new_len + maxDropLen;
                try self.allocator.overrideReallocBlock(&block.extra.forwardBlock, allocLen);
                block.buf = @alignCast(Block.alignment,
                    @intToPtr([*]u8, mem.alignForward(@ptrToInt(block.extra.forwardBlock.ptr()), block.extra.alignment))
                );
            }
        };
    };
}

//
// TODO: We could create a PtrAllocator which wraps an allocator with a "pointer-based" API
//       rather than a "slice-based" API.

/// Create a SliceAllocator from a BlockAllocator.
pub fn makeSliceAllocator(allocator: var) SliceAllocator(@TypeOf(allocator)) {
    return SliceAllocator(@TypeOf(allocator)) {
        .allocator = allocator,
    };
}
pub fn SliceAllocator(comptime T: type) type {
    return SliceAllocatorGeneric(T, T.Block.hasExtra);
}

/// NOTE: if the underlying Block type has no extra data, then storing the block isn't necessary, however,
///       the user may choose to store it anyway to support shrinkInPlace or provide extra sanity checking.
pub fn makeSliceAllocatorGeneric(allocator: var, comptime storeBlock: bool) SliceAllocatorGeneric(@TypeOf(allocator), storeBlock) {
    return SliceAllocatorGeneric(@TypeOf(allocator), storeBlock) {
        .allocator = allocator,
    };
}
pub fn SliceAllocatorGeneric(comptime T: type, comptime storeBlock : bool) type {
    if (T.Block.hasExtra and !storeBlock)
        @compileError("storeBlock must be set to true for " ++ @typeName(T) ++ " because it has extra data");
    const Block = if (!storeBlock) T.Block else
        MakeBlockType(T.Block.hasLen, T.Block.alignment, struct { forwardBlock: T.Block });
    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();
        pub const alignment = Block.alignment;
        allocator: T,

        usingnamespace if (!storeBlock) struct {
            /// The size needed to pad each allocation to store the Block
            pub const allocPadding = 0;

            pub fn getConstBlockRef(slice: *const []align(alignment) u8) *const Block {
                if (comptime Block.hasLen)
                    return @ptrCast(*const Block, slice);
                return @ptrCast(*const Block, &slice.ptr);
            }
            pub fn getBlockRef(slice: *[]align(alignment) u8) *Block {
                if (comptime Block.hasLen)
                    return @ptrCast(*Block, slice);
                return @ptrCast(*Block, &slice.ptr);
            }
            pub fn getConstForwardBlockRef(block: *const Block) *const T.Block {
                return block;
            }
            pub fn getForwardBlockRef(block: *Block) *T.Block {
                return block;
            }
        } else struct {
            /// The size needed to pad each allocation to store the Block
            pub const allocPadding = @sizeOf(Block) + @alignOf(Block) - 1;

            pub fn getConstBlockRef(slice: *const []align(alignment) u8) *const Block {
                return getStoredBlockRef(slice.*);
            }
            pub fn getBlockRef(slice: *const []align(alignment) u8) *Block {
                return getStoredBlockRef(slice.*);
            }
            pub fn getConstForwardBlockRef(block: *const Block) *const T.Block {
                return &block.extra.forwardBlock;
            }
            pub fn getForwardBlockRef(block: *Block) *T.Block {
                return &block.extra.forwardBlock;
            }

            // only available if storeBlock is true, can accept non-ref slices
            pub fn getStoredBlockRef(slice: []align(alignment) u8) *Block {
                return @intToPtr(*Block, mem.alignForward(@ptrToInt(slice.ptr) + slice.len, @alignOf(Block)));
            }
            pub fn debugDumpBlock(slice: []align(alignment) u8) void {
                const blockRef = getStoredBlockRef(buf);
                if (ForwardBlock.hasLen) {
                    std.debug.warn("BLOCK: {}:{} forward {}:{}\n", .{blockRef.ptr(), blockRef.len(),
                        blockRef.extra.forwardBlock.ptr(), blockRef.extra.forwardBlock.len()});
                } else {
                    std.debug.warn("BLOCK: {} forward {}\n", .{blockRef.ptr(),
                        blockRef.extra.forwardBlock.ptr()});
                }
            }
        };

        pub fn alloc(self: SelfRef, len: usize) error{OutOfMemory}![]align(alignment) u8 {
            const paddedLen = len + allocPadding;
            const block = try self.allocator.allocBlock(paddedLen);
            if (comptime Block.hasLen) assert(block.len() == paddedLen);
            const slice = block.ptr()[0..len];
            if (comptime storeBlock) {
                if (comptime Block.hasLen) {
                    getStoredBlockRef(slice).* = Block { .buf = slice    , .extra = .{.forwardBlock = block} };
                } else {
                    getStoredBlockRef(slice).* = Block { .buf = slice.ptr, .extra = .{.forwardBlock = block} };
                }
            }
            return slice;
        }
        pub usingnamespace if (!implements(T, "allocOverAlignedBlock")) struct {
            pub const allocOverAligned = void;
        } else struct {
            pub fn allocOverAligned(self: SelfRef, len: usize, allocAlign: u29) error{OutOfMemory}![]align(alignment) u8 {
                assert(len > 0);
                assert(isValidAlign(allocAlign));
                assert(allocAlign > alignment);
                const paddedLen = len + allocPadding;
                const block = try self.allocator.allocOverAlignedBlock(paddedLen, allocAlign);
                if (comptime Block.hasLen) assert(block.len() == paddedLen);
                assert(mem.isAligned(@ptrToInt(block.ptr()), allocAlign));
                const slice = block.ptr()[0..len];
                if (comptime storeBlock) {
                    if (comptime T.Block.hasLen) {
                        getStoredBlockRef(slice).* = Block { .buf = slice    , .extra = .{.forwardBlock = block} };
                    } else {
                        getStoredBlockRef(slice).* = Block { .buf = slice.ptr, .extra = .{.forwardBlock = block} };
                    }
                }
                return slice;
            }
        };
        /// Takes care of calling allocBlock or allocOverAlignedBlock based on `alignment`.
        pub fn allocAligned(self: SelfRef, len: usize, allocAlign: u29) error{OutOfMemory}![]align(alignment) u8 {
            if (allocAlign <= alignment) return self.alloc(len);
            return self.allocOverAligned(len, allocAlign);
        }
        pub fn dealloc(self: SelfRef, slice: []align(alignment) u8) void {
            deallocBlockIfSupported(&self.allocator, getConstForwardBlockRef(getConstBlockRef(&slice)).*);
        }
        pub usingnamespace if (!implements(T, "extendBlockInPlace")) struct {
            pub const extendInPlace = void;
        } else struct {
            pub fn extendInPlace(self: SelfRef, slice: []align(alignment) u8, new_len: usize) error{OutOfMemory}!void {
                assert(new_len > slice.len);
                var mutableSlice = slice;
                var blockRef = getBlockRef(&mutableSlice);
                if (storeBlock) {
                    assert(slice.ptr == blockRef.ptr());
                    if (Block.hasLen) assert(slice.len == blockRef.len());
                }
                const paddedLen = new_len + allocPadding;
                const extendNeeded =
                    if (comptime !storeBlock or !Block.hasLen) true
                    else paddedLen > blockRef.extra.forwardBlock.len();

                if (extendNeeded) {
                    try self.allocator.extendBlockInPlace(getForwardBlockRef(blockRef), paddedLen);
                    if (T.Block.hasLen) {
                        assert(getForwardBlockRef(blockRef).len() == paddedLen);
                    }
                }
                if (storeBlock) {
                    const newBlockRef = getStoredBlockRef(slice.ptr[0..new_len]);
                    // NOTE: must be memcpyAscending in case of overlap
                    memcpyAscending(@ptrCast([*]u8, newBlockRef), @ptrCast([*]u8, blockRef), @sizeOf(Block));
                    assert(newBlockRef.ptr() == slice.ptr);
                    if (Block.hasLen)
                        newBlockRef.buf.len = new_len;
                }
            }
        };
        // TODO: maybe also check if the BlockAllocator implements shrinkBlockInPlace
        pub usingnamespace if (!storeBlock) struct {
            pub const shrinkInPlace = void;
        } else struct {
            pub fn shrinkInPlace(self: SelfRef, slice: []align(alignment) u8, new_len: usize) void {
                assert(new_len > 0);
                assert(new_len < slice.len);
                if (comptime !storeBlock) {
                    // TODO: support the case where self.allocator implements shrinkBlockInPlace
                    @compileError("shrinkInPlace not implemented for SliceAllocator that doesn't store the Block: " ++ @typeName(T));
                } else {
                    // make a copy of the block so we don't lose it during the shrink
                    var block = getStoredBlockRef(slice).*;
                    assert(slice.ptr == block.ptr());
                    if (Block.hasLen)
                        assert(slice.len == block.buf.len);
                    if (comptime false) {//implements(T, "shrinkBlockInPlace")) {
                        const paddedLen = new_len + allocPadding;
                        try self.allocator.shrinkBlockInPlace(&block.extra.forwardBlock, paddedLen);
                        // whether or not the shrink works, we cannot fail and need to track the new length
                        if (Block.hasLen)
                            assert(block.extra.forwardBlock.len() == paddedLen);
                    }
                    if (Block.hasLen)
                        block.buf.len = new_len;
                    getStoredBlockRef(slice.ptr[0..new_len]).* = block;
                }
            }
        };

        pub usingnamespace if (!reallocBlockSupported(T)) struct {
            pub const realloc = void;
        } else struct {
            /// Equivalent to C's realloc
            pub fn realloc(self: SelfRef, slice: []align(alignment) u8, new_len: usize) error{OutOfMemory}![]align(alignment) u8 {
                assert(new_len > 0);
                var oldBlockRef = getConstBlockRef(&slice);
                if (storeBlock) {
                    assert(slice.ptr == oldBlockRef.ptr());
                    if (Block.hasLen) assert(slice.len == oldBlockRef.len());
                }
                const paddedLen = new_len + allocPadding;
                // make a copy of the block, we will need this in case the memory
                // shrinks or is relocated
                var newBlock = oldBlockRef.*;
                try reallocBlock(&self.allocator, getForwardBlockRef(&newBlock), paddedLen);
                if (T.Block.hasLen) {
                    assert(getForwardBlockRef(&newBlock).len() == paddedLen);
                }
                const newSlice = getForwardBlockRef(&newBlock).ptr()[0..new_len];
                if (storeBlock) {
                    newBlock.buf = if (T.Block.hasLen) newSlice else newSlice.ptr;
                    const newBlockRef = getStoredBlockRef(newSlice);
                    newBlockRef.* = newBlock;
                }
                return newSlice;
            }
        };
    };
}

/// TODO: this shouldn't be in this module
fn memcpyAscending(dst: [*]u8, src: [*]u8, len: usize) void {
     {var i : usize = 0; while (i < len) : (i += 1) {
         dst[i] = src[i];
     }}
}

/// Takes care of calling allocBlock or allocOverAlignedBlock based on `alignment`.
pub fn allocAlignedBlock(allocator: var, len: usize, alignment: u29) error{OutOfMemory}!@TypeOf(allocator.*).Block {
    assert(len > 0);
    assert(isValidAlign(alignment));
    return if (alignment <= @TypeOf(allocator.*).Block.alignment)
        allocator.allocBlock(len) else allocator.allocOverAlignedBlock(len, alignment);
}

/// Call deallocBlock only if it is supported by the given allocator, otherwise, do nothing.
pub fn deallocBlockIfSupported(allocator: var, block: @TypeOf(allocator.*).Block) void {
    if (comptime implements(@TypeOf(allocator.*), "deallocBlock")) {
        allocator.deallocBlock(block);
    }
}

// TODO: this function should either be moved somewhere else like std.math, or I should
//       find the existing version of this
fn addRollover(comptime T: type, a: T, b: T) T {
    var result : T = undefined;
    _ = @addWithOverflow(T, a, b, &result);
    return result;
}

pub fn testReadWrite(slice: []u8, seed: u8) void {
    {var i : usize = 0; while (i < slice.len) : (i += 1) {
        slice[i] = addRollover(u8, seed, @intCast(u8, i & 0xFF));
    }}
    {var i : usize = 0; while (i < slice.len) : (i += 1) {
        testing.expect(slice[i] == addRollover(u8, seed, @intCast(u8, i & 0xFF)));
    }}
}

pub fn testBlockAllocator(allocator: var) void {
    const T = @TypeOf(allocator.*);

    // test allocBlock
    if (comptime implements(T, "allocBlock")) {
        {var i: u8 = 1; while (i < 200) : (i += 17) {
            const block = allocator.allocBlock(i) catch continue;
            if (T.Block.hasLen)
                assert(block.len() == i);
            defer deallocBlockIfSupported(allocator, block);
            testReadWrite(block.ptr()[0..i], i);
        }}
    }
    if (comptime implements(T, "fuzzyAllocBlock")) {
        {var i: u8 = 1; while (i < 200) : (i += 17) {
            const fuzzyResult = allocator.fuzzyAllocBlock(i, i+10) catch continue;
            defer deallocBlockIfSupported(allocator, fuzzyResult.block);
            testReadWrite(fuzzyResult.block.ptr()[0..fuzzyResult.len()], i);
        }}
    }
    if (comptime implements(T, "allocOverAlignedBlock")) {
        {var alignment: u29 = 1; while (alignment < 8192) : (alignment *= 2) {
            {var i: u8 = 1; while (i < 200) : (i += 17) {
                const block = allocAlignedBlock(allocator, i, alignment) catch continue;
                defer deallocBlockIfSupported(allocator, block);
                testReadWrite(block.ptr()[0..i], i);
            }}
        }}
    }
    if (comptime implements(T, "deallocAll")) {
        var i: u8 = 1;
        while (i < 200) : (i += 19) {
            const block = allocator.allocBlock(i) catch break;
            testReadWrite(block.ptr()[0..i], i);
        }
        allocator.deallocAll();
    }
    // TODO: deinitAndDeallocAll will need a different function where
    //       we aren't testing a specific instance

    if (comptime implements(T, "extendBlockInPlace")) {
        blk: {
            var block = allocator.allocBlock(1) catch break :blk;
            defer deallocBlockIfSupported(allocator, block);
            testReadWrite(block.ptr()[0..1], 125);

            allocator.extendBlockInPlace(&block, 2) catch break :blk;
            testReadWrite(block.ptr()[0..2], 39);
        }
    }
//    if (comptime implements(T, "shrinkBlockInPlace")) {
//        blk: {
//            var block = allocator.allocBlock(2) catch break :blk;
//            defer deallocBlockIfSupported(allocator, block);
//            testReadWrite(block.ptr()[0..2], 121);
//
//            allocator.shrinkBlockInPlace(&block, 1);
//            testReadWrite(block.ptr()[0..1], 33);
//        }
//    }

    // test reallocBlock
    if (comptime reallocBlockSupported(T)) {
        {var i: u8 = 1; while (i < 200) : (i += 17) {
            var block = allocator.allocBlock(i) catch continue;
            defer deallocBlockIfSupported(allocator, block);
            testReadWrite(block.ptr()[0..i], i);
            reallocBlock(allocator, &block, i + 30) catch continue;
            if (i > 50)
                reallocBlock(allocator, &block, i - 50) catch continue;
        }}
    }
}

fn testSliceAllocator(allocator: var) void {
    const T = @TypeOf(allocator.*);
    {var i: u8 = 1; while (i < 200) : (i += 14) {
        const slice = allocator.alloc(i) catch continue;
        defer allocator.dealloc(slice);
        testReadWrite(slice, i);
    }}
    if (comptime implements(T, "allocOverAligned")) {
        // TODO: test more alignments when implemented
        {var alignment: u8 = 1; while (alignment <= 1) : (alignment *= 2) {
            {var i: u8 = 1; while (i < 200) : (i += 14) {
                const slice = allocator.allocAligned(i, alignment) catch continue;
                defer allocator.dealloc(slice);
                testReadWrite(slice, i);
            }}
        }}
    }
    if (comptime implements(T, "extendInPlace")) {
        {var i: u8 = 1; while (i < 200) : (i += 14) {
            var slice = allocator.alloc(i) catch continue;
            defer allocator.dealloc(slice);
            allocator.extendInPlace(slice, i + 1) catch continue;
            slice = slice.ptr[0..i+1];
            testReadWrite(slice.ptr[0..i+1], i);
        }}
    }
    if (comptime implements(T, "shrinkInPlace")) {
        {var i: u8 = 2; while (i < 200) : (i += 14) {
            var slice = allocator.alloc(i) catch continue;
            defer allocator.dealloc(slice);
            testReadWrite(slice, i);
            allocator.shrinkInPlace(slice, i - 1);
            slice = slice[0..i-1];
            testReadWrite(slice, i);
        }}
    }
    if (comptime implements(T, "realloc")) {
        {var i: u8 = 2; while (i < 200) : (i += 14) {
            var slice = allocator.alloc(i) catch continue;
            defer allocator.dealloc(slice);
            testReadWrite(slice, i);
            slice = allocator.realloc(slice, i + 30) catch continue;
            testReadWrite(slice, i);
            if (i > 50) {
                slice = allocator.realloc(slice, i - 50) catch continue;
                testReadWrite(slice, i);
            }
        }}
    }
}

/// TODO: move this to std.mem?
/// alignment must be a power of 2 and cannot be 0
pub fn isValidAlign(alignment: u29) bool {
    return (alignment != 0) and (alignment & (alignment - 1) == 0);
}

/// TODO: this should be moved somewhere else, maybe std.meta?
///
/// Returns whether type `T` implements function `name`, otherwise, it requires that
/// T explicitly disable support by setting it to `void.
///
/// The advantage of requiring every type `T` to explicitly disable a function is that
/// when new functions are added, every type must address whether or not is is supported.
/// This also protects the system from typos, because if a function name is mispelled
/// then it will result in a compile error rather than a runtime bug from the function being
/// unrecognized.
///
pub fn implements(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, name))
        @compileError(@typeName(T) ++ " does not implement '" ++ name ++
            "' and has not disabled it by declaring 'pub const " ++ name ++ " = void;'");
    switch (@typeInfo(@TypeOf(@field(T, name)))) {
        .Type => {
            if (@field(T, name) != void)
                @compileError(@typeName(T) ++ " expected '" ++ name ++ "' to be 'void' or a function");
            return false;
        },
        else => return true,
    }
}

/// Make an allocator from a chain of method calls.
/// NOTE: this struct is empty, it does not take up any runtime space
pub const Alloc = struct {
    //
    // TODO: should I put all these in this struct, or should they just be global symbols?
    //
    pub const fail = MakeBlockAllocator(FailAllocator) { .init = FailAllocator { } };

    pub usingnamespace if (std.builtin.link_libc) struct {
        pub const c = MakeBlockAllocator(CAllocator)    { .init = CAllocator { } };
    } else struct { };

    pub usingnamespace if (std.Target.current.os.tag == .windows) struct {
        pub const windowsGlobalHeap = MakeBlockAllocator(WindowsGlobalHeapAllocator) { .init = WindowsGlobalHeapAllocator { } };
        pub fn windowsHeap(handle: std.os.windows.HANDLE) MakeBlockAllocator(WindowsHeapAllocator) {
            return MakeBlockAllocator(WindowsHeapAllocator) { .init = WindowsHeapAllocator.init(handle) };
        }
    } else struct {
        pub const mmap = MakeBlockAllocator(MmapAllocator) { .init = MmapAllocator { } };
    };

    pub fn bumpDown(comptime alignment: u29, buf: []u8) MakeBlockAllocator(BumpDownAllocator(alignment)) {
        return .{ .init = makeBumpDownAllocator(alignment, buf) };
    }
};
pub fn MakeBlockAllocator(comptime T: type) type {return struct {
    init: T,
    pub fn aligned(self: @This()) MakeBlockAllocator(AlignAllocator(T)) {
        return .{.init = makeAlignAllocator(self.init) };
    }
    pub fn log(self: @This()) MakeBlockAllocator(LogAllocator(T)) {
        return .{ .init = makeLogAllocator(self.init) };
    }
    // TODO: sliceForceStore? or shrinkableSlice?
    pub fn slice(self: @This()) MakeSliceAllocator(SliceAllocator(T)) {
        return .{ .init = makeSliceAllocator(self.init) };
    }
};}
pub fn MakeSliceAllocator(comptime T: type) type {return struct {
    init: T,
    // TODO: will create some slice wrappers like logging, locking/threadsafe, etc.
};}

test "FailAllocator" {
    testBlockAllocator(&Alloc.fail.init);
    testBlockAllocator(&Alloc.fail.log().init);
    testSliceAllocator(&Alloc.fail.slice().init);
    testSliceAllocator(&Alloc.fail.log().slice().init);
}
test "CAllocator" {
    if (!std.builtin.link_libc) return;
    testBlockAllocator(&Alloc.c.init);
    testBlockAllocator(&Alloc.c.aligned().init);
    testSliceAllocator(&Alloc.c.slice().init);
    testSliceAllocator(&Alloc.c.aligned().slice().init);
}
test "WindowsHeapAllocator" {
    if (std.Target.current.os.tag != .windows) return;
    testBlockAllocator(&Alloc.windowsGlobalHeap.init);
    testBlockAllocator(&Alloc.windowsGlobalHeap.aligned().init);
    testSliceAllocator(&Alloc.windowsGlobalHeap.slice().init);
    testSliceAllocator(&Alloc.windowsGlobalHeap.aligned().slice().init);
}
test "MmapAllocator" {
    if (std.Target.current.os.tag == .windows) return;
    testBlockAllocator(&Alloc.mmap.init);
    testBlockAllocator(&Alloc.mmap.aligned().init);
    testSliceAllocator(&Alloc.mmap.slice().init);
    testSliceAllocator(&Alloc.mmap.aligned().slice().init);
}
test "BumpDownAllocator" {
    var buf: [500]u8 = undefined;
    inline for ([_]u29 {1, 2, 4, 8, 16, 32, 64}) |alignment| {
        testBlockAllocator(&Alloc.bumpDown(alignment, &buf).init);
        testBlockAllocator(&Alloc.bumpDown(alignment, &buf).aligned().init);
        testSliceAllocator(&Alloc.bumpDown(alignment, &buf).slice().init);
        testSliceAllocator(&Alloc.bumpDown(alignment, &buf).aligned().slice().init);
    }
}
