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
///     var stack_buffer : [100]u8 = undefiend;
///     const a = Alloc.join(.{
///         Alloc.bumpDown(1, stack_buffer).init,
///         Alloc.c.init,
///     }).slice().init;
///     const s = a.alloc(40);
///     defer a.dealloc(s);
///
///     // Create a custom allocator and custom wrapper
///     const MyAllocator = struct { ... };
///     const MyAllocatorWrapper = struct { ... };
///     const a = Alloc.custom(MyAllocator { ... }).aligned()
///         .custom(MyAllocatorWrapper { ... }).exact().slice();
///
/// This library allows every allocator to declare their individual-allocation storage
/// requirements through a custom "Block" type. The Block type can store any data the allocator
/// wants to associate with individual allocations. It could be just a pointer, or
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
/// Check the MakeBlockType function for notes on creating a Block type.
/// Blocks are normally passed by value to the allocator, unless the allocator
/// is going to modify it (i.e. extendBlockInPlace).
/// The caller will access the memory pointer for a block by calling its `ptr()` function.
/// The pointer can have an "align(X)" property to indicate all allocations from will be
/// aligned by X.
///
/// ### Allocation:
///
///     1. fn allocBlock(len: usize) error{OutOfMemory}!Block
///        assert(lenRef.* > 0);
///        Allocate a block of at least `len` bytes. If the `is_exact` field is true, then block.len()
///        will match the requested `len`, otherwise, it may be larger.
///
///     2. const is_exact = true|false;
///        true if all block lengths will exactly match the length requested
///
///     3. fn getAvailableLen(block: Block) usize
///        Return the length of the the memory owned by the given `block` that could be used by the
///        caller starting from block.ptr(). An allocator should only implement this if the full
///        available length from block.ptr() can be larger than block.len().  This would be common if
///        is_exact were true, but there are also cases where it can happen when is_exact is false.
///
///     4. fn getAvailableDownLen(block: Block) usize
///        Return the length of the the memory owned by the given `block` that could be used by the
///        caller that is located below block.ptr().
///
///     5. inexact (field)
///        An allocator whose `is_exact` is true can provide an `inexact` field to create blocks whose
///        length is not exact.  A caller would do this if they want the block length to more closely
///        reflect the full amount of memory available to it.
///
/// ### Aligned Allocation
///
///     NOTE: do not implement this aligned allocation function unless you are a wrapping allocator.
///           all allocators can support aligned allocations by wrapping them with the AlignAllocator
///           (i.e. ".align()")
///
///     Allocator's can declare all blocks to be aligned based on their block pointer's "align(X)" property.
///     If the caller wants to make an allocation that is more aligned than this, they can call
///     "allocOverAlignedBlock".
///     For now the only allocators that should implement this function is the AlignAllocator, and any
///     wrapping allocators.
///
///     * allocOverAlignedBlock(len: usize, alignment: u29) error{OutOfMemory}!Block
///       assert(len > 0);
///       assert(isValidAlign(alignment));
///       assert(alignment > Block.alignment);
///       Allocate a block of at least `len` bytes aligned to `alignment`. The "Over" part of "OverAligned"
///       means `alignment` > `Block.alignment`.
///       If the block is larger than requested, the caller can attempt to retract the block if they know they
///       won't need the extra memory. Note that this is an option purposely left to the caller (see Single Responsibility
///       Principle).
///       NOTE: so far the only allocator that I know of that should implement this is the AlignAllocator and any wrapping allocators.
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
///     extend and retract are separate functions so that an allocator can indicate at
///     compile-time which ones it supports.
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
///     * shrinkBlockInPlace(block: *Block, new_len: usize) void
///       assert(new_len > 0);
///       assert(new_len < block.len());
///       Shrink a block without moving it.
///       Unlink restrictBlockInPlace, this method cannot fail. After calling this, block.len() will
///       be set to `new_len`. The allocator may or may not be able to use the released space.
///       Most allocators will not implement this as it typically requires extra space to store
///       any discrepancy between the caller length and the underlying allocator's length.  Wrap any
///       allocator with ".exact()" to support this.
///
///     * TODO: might want to add a method to extend both left and right? expand?
///
/// ### Introspection ?
///     * UnderlyingAllocator: type
///       One use case for supporting this is detecting whether AlignAllocator has incorrectly
///       wrapped an ExactAllocator.  If you could walk down the allocator type heirarchy,
///       you could verify something like this doesn't happen.
///
/// ### Ownership? (How helpful is this?)
///
///     * IDEA: ownsBlock(block: Block) bool
///       Means the allocator can tell if it owns a block.
///
/// ### ??? Next Block Pointer ???
///
///     * IDEA: nextBlockPtr() [*]u8
///       An allocator could implement this if it's next block pointer is pre-determined.
///       A containing alignment allocator may want to know this to adjust what they need to request for an aligned block.
///     * IDEA: nextBlockPtrWithLen(len: usize) [*]u8
///       Maybe this would be a helpful option as well?
///
/// ### Realloc
///
///     These functions should only be implemented by the CAllocator and wrapping allocators.
///     They can only be called on "exact" allocators.
///
///     * cReallocBlock(block: *Block, current_len: usize, new_len: usize) error{OutOfMemory}!void
///     * cReallocAlignedBlock(block: *Block, current_len: usize, new_len: usize, current_align: u29, min_align: u29) error{OutOfMemory}!void
///       assert(current_len == block.len()) // if block.has_len is true
///       assert(new_len > 0);
///       assert(current_len != new_len);
///       assert(isValidAlign(current_align));
///       assert(mem.isAligned(@ptrToInt(block.ptr()), current_align));
///       assert(isValidAlign(min_align));
///       assert(min_align <= current_align);
///       This function is equivalent to C's realloc.
///       This should only be implemented by CAllocator, AlignAllocator and forwarded by "wrapping allocators".
///       The `reallocAlignedBlock` function in this module will implement the `realloc` operation for
///       every allocator using a combination of other operations.  The C allocator is special because
///       it does not support enough operations to support realloc, so we call its realloc function directly.
///       The current_align value should be the alignment requested when the block was allocated. `min_align`
///       must be <= to current_align, and indicates what alignment must be maintained if the memory is moved.
///
///
/// ### Why does ExactAllocator wrap AlignAllocator instead of the other way around?
/// --------------------------------------------------------------------------------
/// The AlignAllocator turns an "exact" allocator into an "inexact" allocator because it needs to
/// be able to change the length of the allocation to get an aligned address.  This means if an exact
/// allocator is desired, then it should be applied after the align allocator.
///
/// ================================================================================
/// TODO: Should I remove all the asserts inside the function bodies and create an AssertAllocator?
/// ================================================================================
///
const std = @import("std");
const mem = std.mem;
const os = std.os;
const assert = std.debug.assert;

const testing = std.testing;

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

    pub fn mem(allocator: *mem.Allocator, comptime exact: bool) MakeBlockAllocator(MemAllocator(exact)) {
        return .{ .init = MemAllocator(exact).init(allocator) };
    }

    // Support method call syntax to add custom allocators.
    pub fn custom(allocator: anytype) MakeBlockAllocator(@TypeOf(allocator)) {
        return .{ .init = allocator };
    }
};
pub fn MakeBlockAllocator(comptime T: type) type {return struct {
    init: T,

    pub fn arena(self: @This(), comptime alignment: u29) MakeBlockAllocator(ArenaAllocator(T, alignment)) {
        return .{ .init = makeArenaAllocator(alignment, self.init) };
    }

    /// wraps another allocator and adds an extra length field to each block. This extra field enables
    /// allocations of any size (aka "exact allocations") and also enables the "shrinkBockInPlace" operation.
    ///
    /// `exact` should never be wrapped by `aligned`, rather, it should always be the one wrapping `aligned`
    /// (see "Why does ExactAllocator wrap AlignAllocator instead of the other way around?").
    pub fn exact(self: @This()) MakeBlockAllocator(ExactAllocator(T)) {
        return .{ .init = makeExactAllocator(self.init) };
    }

    /// wraps another allocator and adds an extra pointer to each block type.  This extra pointer points to an
    /// address within the memory of the underlying allocator's block memory, usually to an aligned address.
    /// If an "over aligned" allocation is requested, this allocator will over-allocate memory and track the full
    /// allocation along with the aligned offset.  Any time it forwards a call to the underlying allocator, it will pass
    /// the block with full allocation.
    pub fn aligned(self: @This()) MakeBlockAllocator(AlignAllocator(T)) {
        return .{ .init = makeAlignAllocator(self.init) };
    }

    /// wraps another allocator to log every function called on it
    pub fn log(self: @This()) MakeBlockAllocator(LogAllocator(T)) {
        return .{ .init = makeLogAllocator(self.init) };
    }

    /// wraps another allocator to create a "slice based" API rather than a "Block based" one.  If the underlying
    /// allocator's Block type is just a pointer or a slice, then this wrapper just acts as a passthrough, otherwise,
    /// this allocator will pad allocations with enough memory to store the full Block type necessary to manage
    /// allocations.
    pub fn slice(self: @This()) MakeSliceAllocator(SliceAllocator(T)) {
        return .{ .init = makeSliceAllocator(self.init) };
    }

    // TODO: can't get this to work yet
    // Support method call syntax to add custom allocators.
    //pub fn custom(self: @This(), wrapperTypeFunc: anytype) MakeBlockAllocator(@typeInfo(@TypeOf(wrapperTypeFunc)).Fn.return_type.?) {
    //    @compileLog(@TypeOf(wrapperTypeFunc));
    //    return .{ .init = @call(.{}, @typeInfo(@TypeOf(wrapperTypeFunc)).Fn.return_type.?, .{self} ) };
    //}
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

    // test that '.custom' syntax works
    _ = &Alloc.custom(FailAllocator{ }).init;
    // TODO: can't get custom allocator wrappers to work yet
    //_ = &Alloc.fail.custom(LogAllocator).init;
}
test "CAllocator" {
    if (!std.builtin.link_libc) return;
    testBlockAllocator(&Alloc.c.init);
    testBlockAllocator(&Alloc.c.aligned().init);
    testBlockAllocator(&Alloc.c.exact().init);
    testBlockAllocator(&Alloc.c.aligned().exact().init);
    testSliceAllocator(&Alloc.c.slice().init);
    testSliceAllocator(&Alloc.c.exact().slice().init);
    testSliceAllocator(&Alloc.c.aligned().exact().slice().init);
}
test "WindowsHeapAllocator" {
    if (std.Target.current.os.tag != .windows) return;
    testBlockAllocator(&Alloc.windowsGlobalHeap.init);
    testBlockAllocator(&Alloc.windowsGlobalHeap.aligned().init);
    testBlockAllocator(&Alloc.windowsGlobalHeap.aligned().exact().init);
    testSliceAllocator(&Alloc.windowsGlobalHeap.slice().init);
    testSliceAllocator(&Alloc.windowsGlobalHeap.aligned().exact().slice().init);
    // TODO: test private heaps with HeapAlloc
    //{
    //    var a = Alloc.windowsHeap(HeapAlloc(...)).init;
    //    defer a.deinitAndDeallocAll();
    //    testBlockAllocator(&a);
    //    ...
    //}
}

test "MmapAllocator" {
    if (std.Target.current.os.tag == .windows) return;
    testBlockAllocator(&Alloc.mmap.init);
    testBlockAllocator(&Alloc.mmap.aligned().init);
    testBlockAllocator(&Alloc.mmap.aligned().exact().init);
    testSliceAllocator(&Alloc.mmap.exact().slice().init);
    testSliceAllocator(&Alloc.mmap.aligned().exact().slice().init);
}
test "BumpDownAllocator" {
    var buf: [500]u8 = undefined;
    inline for ([_]u29 {1, 2, 4, 8, 16, 32, 64}) |alignment| {
        testBlockAllocator(&Alloc.bumpDown(alignment, &buf).init);
        testBlockAllocator(&Alloc.bumpDown(alignment, &buf).aligned().init);
        testSliceAllocator(&Alloc.bumpDown(alignment, &buf).aligned().exact().slice().init);
        if (comptime alignment == 1) {
            testSliceAllocator(&Alloc.bumpDown(alignment, &buf).slice().init);
        } else {
            testBlockAllocator(&Alloc.bumpDown(alignment, &buf).exact().init);
            testBlockAllocator(&Alloc.bumpDown(alignment, &buf).aligned().exact().init);
            testSliceAllocator(&Alloc.bumpDown(alignment, &buf).exact().slice().init);
        }
    }
}

test "ArenaAllocator" {
    inline for ([_]u29 {1, 2, 4, 8, 16, 32, 64}) |alignment| {
        if (std.Target.current.os.tag == .linux) {
            testBlockAllocator(&Alloc.mmap.arena(alignment).init);
            //testBlockAllocator(&Alloc.mmap.aligned().arena(alignment).init);
            testBlockAllocator(&Alloc.mmap.arena(alignment).aligned().init);
            //testBlockAllocator(&Alloc.mmap.aligned().arena(alignment).init);
        }
        if (std.Target.current.os.tag == .windows) {
            testBlockAllocator(&Alloc.windowsGlobalHeap.arena(alignment).init);
        }
        if (std.builtin.link_libc) {
            testBlockAllocator(&Alloc.c.exact().arena(alignment).init);
        }
    }
}

test "MemAllocator" {
    inline for ([_]bool {false, true}) |exact| {
        testBlockAllocator(&Alloc.mem(std.heap.page_allocator, exact).init);
        if (!exact) {
            testBlockAllocator(&Alloc.mem(std.heap.page_allocator, exact).exact().init);
            testBlockAllocator(&Alloc.mem(std.heap.page_allocator, exact).exact().arena(1).init);
        }
        testBlockAllocator(&Alloc.mem(std.heap.page_allocator, exact).arena(1).init);

        if (exact) {
            testSliceAllocator(&Alloc.mem(std.heap.page_allocator, exact).slice().init);
        } else {
            testSliceAllocator(&Alloc.mem(std.heap.page_allocator, exact).exact().slice().init);
            testSliceAllocator(&Alloc.mem(std.heap.page_allocator, exact).exact().arena(1).slice().init);
        }
        testSliceAllocator(&Alloc.mem(std.heap.page_allocator, exact).arena(1).slice().init);
    }
}

/// Create a Block type from the given block Data type.
/// The Data type must include:
///     pub const has_len    = true|false;
///     pub const alignment = AN_ALIGNMENT_INTEGER;
///
///     // It must implement or disable initBuf
///         pub const initBuf = void;
///     // OR
///         pub fn initBuf(p: [*]align(alignment) u8) Self;
//      // OR if has_len is true
///         pub fn initBuf(p: []align(alignment) u8) Self;
///     // initBuf should exist if and only if the pointer/slice is the only data in the Block type
///
///     // returns a pointer to the memory owned by the block
///     pub fn ptr(self: @This()) [*]align(alignment) u8 { ... }
///     // if has_len is true, a function to return the length of the memory owned by the block
///     // and a function to return the memory owned by the block as a slice
///     pub fn len(self: @This()) usize { ... }
///     pub fn setLen(self: *@This(), new_len: usize) void { ... }
///
pub fn MakeBlockType(comptime Data: type) type {
    if (!isValidAlign(Data.alignment)) @compileError("invalid alignment");
    return struct {
        const Self = @This();

        pub const has_len = Data.has_len;
        pub const alignment = Data.alignment;
        data: Data,

        pub fn init(data: Data) Self { return .{ .data = data }; }

        pub usingnamespace if (!implements(Data, "initBuf")) struct {
            pub const initBuf = void;
        } else struct {
            const Buf = if (has_len) []align(alignment) u8 else [*]align(alignment) u8;
            pub fn initBuf(buf: Buf) Self { return .{ .data = Data.initBuf(buf) }; }
        };
        pub fn ptr(self: Self) [*]align(alignment) u8 { return self.data.ptr(); }

        pub usingnamespace if (!has_len) struct { } else struct {
            pub fn len(self: Self) usize { return self.data.len(); }
            pub fn setLen(self: *Self, new_len: usize) void { self.data.setLen(new_len); }
        };

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            out_stream: anytype
        ) !void {
            if (comptime has_len) {
                try std.fmt.format(out_stream, "{}:{}", .{self.ptr(), self.len()});
            } else {
                try std.fmt.format(out_stream, "{}:{}", .{self.ptr()});
            }
        }
    };
}


/// Creates a simple block type that stores a pointer or a slice and a struct of any extra data.
pub fn MakeSimpleBlockType(
    /// true if the Block tracks slices rather than just pointers.
    comptime has_len_: bool,
    /// guaranteed alignment for all blocks from the allocator. Must be a power
    /// of 2 that is also >= 1.
    comptime alignment_: u29,
    /// extra data that each block must maintain.
    comptime Extra: type
) type {
    const Buf = if (has_len_) [] align(alignment_) u8
                else         [*]align(alignment_) u8;
    const Data = struct {
        const Self = @This();

        pub const has_len = has_len_;
        pub const alignment = alignment_;

        buf: Buf,
        extra: Extra,

        pub usingnamespace if (@sizeOf(Extra) > 0) struct {
            pub const initBuf = void;
        } else struct {
            pub fn initBuf(buf: Buf) Self { return .{ .buf = buf, .extra = .{} }; }
        };

        pub usingnamespace if (!has_len) struct {
            pub fn ptr(self: Self) [*]align(alignment) u8 { return self.buf; }
        } else struct {
            pub fn ptr(self: Self) [*]align(alignment) u8 { return self.buf.ptr; }
            pub fn len(self: Self) usize { return self.buf.len; }
            pub fn setLen(self: *Self, new_len: usize) void { self.buf.len = new_len; }
        };
    };
    return MakeBlockType(Data);
}

/// An allocator that always fails.
pub const FailAllocator = struct {
    pub const Block = MakeSimpleBlockType(true, 1, struct {});

    pub const is_exact = true;
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        assert(len > 0);
        return error.OutOfMemory;
    }
    pub const getAvailableLen = void;
    pub const getAvailableDownLen = void;
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
    pub const shrinkBlockInPlace = void;
    pub const cReallocBlock = void;
    pub const cReallocAlignedBlock = void;
};

pub const CAllocator = struct {
    const Self = @This();
    usingnamespace if (comptime @hasDecl(std.c, "malloc_size")) struct {
        pub const supports_malloc_size = true;
        pub const malloc_size = std.c.malloc_size;
    } else if (comptime @hasDecl(std.c, "malloc_usable_size")) struct {
        pub const supports_malloc_size = true;
        pub const malloc_size = std.c.malloc_usable_size;
    } else struct {
        pub const supports_malloc_size = false;
    };

    pub const Block = MakeSimpleBlockType(false, 8, struct {});

    pub const is_exact = true;
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        assert(len > 0);
        const ptr = std.c.malloc(len) orelse return error.OutOfMemory;
        return Block.initBuf(@ptrCast([*]u8, @alignCast(8, ptr)));
    }
    pub usingnamespace if (!supports_malloc_size) struct {
        pub const getAvailableLen = void;
    } else struct {
        pub fn getAvailableLen(self: Self, block: Block) usize {
            return malloc_size(block.ptr());
        }
    };
    pub const getAvailableDownLen = void;
    pub const allocOverAlignedBlock = void;
    pub fn deallocBlock(self: @This(), block: Block) void {
        std.c.free(block.ptr());
    }
    pub const deallocAll = void;
    pub const deinitAndDeallocAll = void;
    pub const extendBlockInPlace = void;
    pub const retractBlockInPlace = void;
    pub const shrinkBlockInPlace = void;
    pub fn cReallocBlock(self: @This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        assert(new_len > 0);
        const ptr = std.c.realloc(block.ptr(), new_len)
            orelse return error.OutOfMemory;
        block.* = Block.initBuf(@ptrCast([*]align(8) u8, @alignCast(8, ptr)));
    }
    pub const cReallocAlignedBlock = void;
};

pub const MmapAllocator = struct {
    pub const Block = MakeSimpleBlockType(true, mem.page_size, struct {});

    pub const is_exact = false;
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        const aligned_len = mem.alignForward(len, mem.page_size);
        const result = os.mmap(
            null,
            aligned_len,
            os.PROT_READ | os.PROT_WRITE,
            os.MAP_PRIVATE | os.MAP_ANONYMOUS,
            -1, 0) catch return error.OutOfMemory;
        assert(result.len == aligned_len);
        return Block.initBuf(@alignCast(mem.page_size, result.ptr)[0..aligned_len]);
    }
    pub const getAvailableLen = void; // don't need because it's in block.len()
    pub const getAvailableDownLen = void;
    pub const allocOverAlignedBlock = void;
    pub fn deallocBlock(self: @This(), block: Block) void {
        os.munmap(block.data.buf);
    }
    pub const deallocAll = void;
    pub const deinitAndDeallocAll = void;

    // TODO: move this to std/os/linux.zig
    usingnamespace if (std.Target.current.os.tag != .linux) struct { } else struct {
        pub fn sys_mremap(old_address: [*]align(mem.page_size) u8, old_size: usize, new_size: usize, flags: usize) usize {
            return os.linux.syscall4(.mremap, @ptrToInt(old_address), old_size, new_size, flags);
            //return os.linux.syscall5(.mremap, @ptrToInt(old_address), old_size, new_size, flags, 0);
        }
    };
    fn mremap(buf: []align(mem.page_size) u8, new_len: usize, flags: usize) ![*]u8 {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TEMPORARY HACK
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        if (std.Target.current.os.tag != .linux) return error.OutOfMemory;
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
        const result = mremap(block.data.buf, new_len, 0) catch return error.OutOfMemory;
        assert(result == block.ptr());
        block.data.buf.len = new_len;
    }
    pub fn extendBlockInPlace(self: @This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        assert(new_len > block.len());
        const aligned_len = mem.alignForward(new_len, mem.page_size);
        return mremapInPlace(block, aligned_len);
    }
    pub fn retractBlockInPlace(self: @This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        assert(new_len > 0);
        assert(new_len < block.len());
        const aligned_len = mem.alignForward(new_len, mem.page_size);
        if (aligned_len >= block.len()) return error.OutOfMemory;
        return mremapInPlace(block, aligned_len);
    }
    pub const shrinkBlockInPlace = void;
    pub const cReallocBlock = void;
    pub const cReallocAlignedBlock = void;
};

/// Simple Fast allocator. Tradeoff is that it can only re-use blocks if they are deallocated
/// in LIFO stack order.
///
/// The Up/Down detail is exposed because they have different behavior.
/// The BumpDownAllocator means that in-place extend/retract is much more limited than
/// an BumpUpAllocator which is only limited by the amount of memory it has.
///
/// I'm not sure what the advantage of a BumpDownAllocator is, maybe it is more efficient?
///     see https://fitzgeraldnick.com/2019/11/01/always-bump-downwards.html
///
/// TODO: would it be worth it to create alignForward/alignBackward functions with a comptime alignment?
pub fn makeBumpDownAllocator(comptime alignment: u29, buf: []u8) BumpDownAllocator(alignment) {
    return BumpDownAllocator(alignment).init(buf);
}
pub fn BumpDownAllocator(comptime alignment : u29) type {return struct {
    const Self = @This();
    pub const Block = MakeSimpleBlockType(true, alignment, struct {});

    buf: []u8,
    bump_index: usize, // MUST ALWAYS be aligned to `alignment` relative to `buf.ptr`.
    pub fn init(buf: []u8) @This() {
        return .{ .buf = buf, .bump_index = getStartBumpIndex(buf) };
    }
    // We must ensure bump_index is aligned when it is initialized
    fn getStartBumpIndex(buf: []u8) usize {
        if (comptime alignment == 1) return buf.len;

        const end_addr = @ptrToInt(buf.ptr) + buf.len;
        const aligned_end_addr = mem.alignBackward(end_addr, alignment);
        if (aligned_end_addr < @ptrToInt(buf.ptr)) return 0;
        return aligned_end_addr - @ptrToInt(buf.ptr);
    }
    fn getBlockIndex(self: @This(), block: Block) usize {
        assert(@ptrToInt(block.ptr()) >= @ptrToInt(self.buf.ptr));
        return @ptrToInt(block.ptr()) - @ptrToInt(self.buf.ptr);
    }

    pub const is_exact = (alignment == 1);
    fn allocBlock(self: *Self, len: usize) error{OutOfMemory}!Block {
        assert(len > 0);
        const aligned_len = if (comptime is_exact) len else mem.alignForward(len, alignment);
        if (aligned_len > self.bump_index)
            return error.OutOfMemory;
        const buf_index = self.bump_index - aligned_len;
        self.bump_index = buf_index;
        return Block.initBuf(@alignCast(alignment, self.buf[buf_index..buf_index + aligned_len]));
    }
    pub const getAvailableLen = void; // don't need because it will be in block.len
    pub const getAvailableDownLen = void;
    pub const allocOverAlignedBlock = void;
    pub fn deallocBlock(self: *@This(), block: Block) void {
        if (self.bump_index == self.getBlockIndex(block)) {
            assert(mem.isAligned(block.len(), alignment));
            self.bump_index += block.len();
        }
    }
    pub fn deallocAll(self: *@This()) void {
        self.bump_index = getStartBumpIndex(self.buf);
    }
    pub const deinitAndDeallocAll = void;
    /// BumpDown cannot extend/retract blocks, but BumpUp could extend/retract the last one
    pub const extendBlockInPlace = void;
    pub const retractBlockInPlace = void;
    pub const shrinkBlockInPlace = void;
    pub const cReallocBlock = void;
    pub const cReallocAlignedBlock = void;
};}

// The windows heap provided by kernel32
pub const WindowsHeapAllocator = struct {
    // TODO: can we assume HeapAlloc will always have a certain alignment?
    pub const Block = MakeSimpleBlockType(false, 1, struct {});

    handle: os.windows.HANDLE,

    pub fn init(handle: os.windows.HANDLE) @This() {
        return @This() { .handle = handle };
    }

    /// Type-specific function to be able to pass in windows-specific flags
    pub fn heapAlloc(self: @This(), len: usize, flags: u32) error{OutOfMemory}!Block {
        const result = os.windows.kernel32.HeapAlloc(self.handle, flags, len) orelse return error.OutOfMemory;
        return Block.initBuf(@ptrCast([*]u8, result));
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

    pub const is_exact = true;
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        // TODO: use HEAP_NO_SERIALIZE flag if we are single-threaded?
        return self.heapAlloc(len, 0);
    }
    // TODO: if we can get the full size actually available from the allocation, we should implement this
    pub const getAvailableLen = void;
    pub const getAvailableDownLen = void;
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
    pub const shrinkBlockInPlace = void;
    pub const cReallocBlock = void;
    pub const cReallocAlignedBlock = void;
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

    pub const is_exact = true;
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        return try getInstance().allocBlock(len);
    }
    // TODO: implement this if we implement it in WindowsHeapAllocator
    pub const getAvailableLen = void;
    pub const getAvailableDownLen = void;
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
    pub const shrinkBlockInPlace = void;
    pub const cReallocBlock = void;
    pub const cReallocAlignedBlock = void;
    pub const is_exactWrapped = false;
};

// TODO: make SlabAllocator?
// TODO: make a SanityAllocator that saves all the blocks and ensures every call passes in valid blocks.
// TODO: make a LockingAllocator/ThreadSafeAllocator that can wrap any other allocator?

/// Equivalent to C's realloc. All allocators will share a common implementation of this except
/// for the C allocator which will use libc's realloc.
///
/// This function isn't designed very well, it's purposely designed to behave like C's realloc.
/// current_len MUST be the exact length of the given block.  It is passed in because not all blocks
/// support block.len(). We could support current_len being less than block.len(), but that's not how
/// C's realloc behaves, we can create another function if we want that behavior.
///
/// This function is only supported for "exact" allocators.
///
pub fn reallocAlignedBlock(allocator: anytype, block: *@TypeOf(allocator.*).Block, current_len: usize, new_len: usize, current_align: u29, min_align: u29) error{OutOfMemory}!void {
    const T = @TypeOf(allocator.*);
    if (!T.is_exact)
        @compileError("reallocAlignedBlock cannot be called on '" ++ @typeName(T) ++ "' because it is not exact.");
    if (!comptime implements(T, "allocOverAlignedBlock"))
        @compileError("reallocAlignedBlock cannot be called on '" ++ @typeName(T) ++ "' because it is not aligned.");

    if (T.Block.has_len) assert(current_len == block.len());
    assert(new_len > 0);
    assert(current_len != new_len);
    assert(isValidAlign(current_align));
    assert(mem.isAligned(@ptrToInt(block.ptr()), current_align));
    assert(isValidAlign(min_align));
    assert(min_align <= current_align);

    if (comptime implements(T, "cReallocAlignedBlock"))
        return try allocator.cReallocAlignedBlock(block, current_len, new_len, current_align, min_align);
    if (comptime implements(T, "cReallocBlock"))
        @compileError(@typeName(T) ++ " implmeents cReallocBlock but not cReallocAlignedBlock, wrap it with .aligned()");

    // first try resizing in place to avoid having to copy the data and potentially re-align
    if (new_len > current_len) {
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
    const new_block = if (min_align <= T.Block.alignment)
        try allocator.allocBlock(new_len) else try allocator.allocOverAlignedBlock(new_len, min_align);
    if (T.Block.has_len) assert(new_block.len() == new_len);
    assert(mem.isAligned(@ptrToInt(new_block.ptr()), min_align));
    @memcpy(new_block.ptr(), block.ptr(), std.math.min(block.len(), new_len));
    deallocBlockIfSupported(allocator, block.*);
    block.* = new_block;
}

pub fn makeArenaAllocator(comptime alignment: u29, allocator: anytype) ArenaAllocator(@TypeOf(allocator), alignment) {
    return ArenaAllocator(@TypeOf(allocator), alignment).init(allocator);
}
pub fn ArenaAllocator(comptime T: type, comptime alignment: u29) type {
    if (!T.Block.has_len)
        @compileError("arena requires that the underlying allocator Block.has_len is true. You can wrap it with .exact() to support it.");
    //if (implements(T, "allocOverAlignedBlock"))
    //    @compileError("not sure if ArenaAllocator should be able to wrap AlignAllocator");
    return struct {
        const Self = @This();
        const BumpAllocator = BumpDownAllocator(alignment);
        pub const Block = BumpAllocator.Block;
        const ArenaList = std.SinglyLinkedList(BumpDownAllocator(alignment));

        allocator: T,
        arena_list: ArenaList,

        pub fn init(allocator: T) @This() {
            return @This() {
                .allocator = allocator,
                .arena_list = ArenaList { .first = null },
            };
        }

        fn getListNode(self: *Self, block: T.Block) *ArenaList.Node {
            const available_len = getBlockAvailableLenHasLen(&self.allocator, block);
            return @intToPtr(*ArenaList.Node,
                mem.alignBackward(@ptrToInt(block.ptr()) + available_len - @sizeOf(ArenaList.Node), @alignOf(ArenaList.Node))
            );
        }

        pub const is_exact = BumpAllocator.is_exact;
        const alloc_padding =  @sizeOf(ArenaList.Node) + @alignOf(ArenaList.Node) - 1;
        pub fn allocBlock(self: *Self, len: usize) error{OutOfMemory}!Block {
            {var it = self.arena_list.first; while (it) |node| : (it = node.next) {
                return node.data.allocBlock(len) catch continue;
            }}

            // allocate a new arena
            // TODO: do I need to add anything else to padded_len to ensure there is enough
            //       for in the new BumpDownAllocator for len bytes?
            var padded_len = len + @sizeOf(ArenaList.Node) + @alignOf(ArenaList.Node) - 1;
            //std.debug.warn("arena len={} padded={}\n", .{len, padded_len});
            const block = try self.allocator.allocBlock(padded_len);
            const node = self.getListNode(block);
            node.next = self.arena_list.first;
            self.arena_list.first = node;

            const buf_len = @ptrToInt(node) - @ptrToInt(block.ptr());
            assert(buf_len >= len);
            node.* = ArenaList.Node { .data = BumpAllocator.init(block.ptr()[0..buf_len]) };
            return node.data.allocBlock(len);
        }

        comptime { assert(!implements(BumpAllocator, "getAvailableLen")); }
        pub const getAvailableLen = void;

        // disable unless I determine it's ok for ArenaAllocator to wrap AlignAllocator
        pub const allocOverAlignedBlock = void;

        pub const deallocBlock = void;

        // TODO: implement this
        pub const deallocAll = void;
        //pub fn deallocAll(self: *Self) void {
        //    @panic ("not impl");
        //}

        pub usingnamespace if (!implements(T, "deinitAndDeallocAll")) struct {
            pub const deinitAndDeallocAll = void;
        } else struct {
            pub fn deinitAndDeallocAll(self: *Self) void {
                @panic ("not impl");
            }
        };
        // Not supported if we are using BumpDownAllocator, could support on the
        // latest block if using BumpUpAllocator
        pub const extendBlockInPlace = void;
        pub const retractBlockInPlace = void;

        // We can support shrink because we don't support deallocBlock, therefore,
        // we don't need to know the original length.
        pub fn shrinkBlockInPlace(self: *Self, block: *Block, new_len: usize) void {
            block.setLen(new_len);
        }

        // Because ArenaAllocator can't support resize, I don't think ArenaAllocator
        // can support these operations
        // TODO: should we assert an error if the underlying allocator implements these?
        //comptime {
        //    assert(!implements(T, "cReallocBlock"));
        //    assert(!implements(T, "cReallocAlignedBlock"));
        //}
        pub const cReallocBlock = void;
        pub const cReallocAlignedBlock = void;
    };
}


pub fn makeLogAllocator(allocator: anytype) LogAllocator(@TypeOf(allocator)) {
    return LogAllocator(@TypeOf(allocator)) { .allocator = allocator };
}
// TODO: log to an output stream rather than directly to stderr
pub fn LogAllocator(comptime T: type) type {
    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();
        pub const Block = T.Block;
        allocator: T,
        pub const is_exact = T.is_exact;
        pub usingnamespace if (!implements(T, "allocBlock")) struct {
            pub const allocBlock = void;
        } else struct {
            pub fn allocBlock(self: SelfRef, len: usize) error{OutOfMemory}!Block {
                std.debug.warn("{}: allocBlock len={}\n", .{@typeName(T), len});
                const result = try self.allocator.allocBlock(len);
                std.debug.warn("{}: allocBlock returning {}\n", .{@typeName(T), result});
                return result;
            }
        };
        pub usingnamespace if (!implements(T, "getAvailableLen")) struct {
            pub const getAvailableLen = void;
        } else struct {
            pub fn getAvailableLen(self: SelfRef, block: Block) usize {
                const result = try self.allocator.getAvailableLen(block);
            }
        };
        pub usingnamespace if (!implements(T, "getAvailableDownLen")) struct {
            pub const getAvailableDownLen = void;
        } else struct {
            pub fn getAvailableDownLen(self: SelfRef, block: Block) usize {
                const result = try self.allocator.getAvailableDownLen(block);
            }
        };
        pub usingnamespace if (!implements(T, "allocOverAlignedBlock")) struct {
            pub const allocOverAlignedBlock = void;
        } else struct {
            pub fn allocOverAlignedBlock(self: SelfRef, len: usize, alloc_align: u29) error{OutOfMemory}!Block {
                std.debug.warn("{}: allocOverAlignedBlock len={} align={}\n", .{@typeName(T), len, alloc_align});
                const result = try self.allocator.allocOverAlignedBlock(len, alloc_align);
                std.debug.warn("{}: allocOverAlignedBlock returning {}\n", .{@typeName(T), result});
                return result;
            }
        };

        pub usingnamespace if (!implements(T, "deallocBlock")) struct {
            pub const deallocBlock = void;
        } else struct {
            pub fn deallocBlock(self: SelfRef, block: Block) void {
                std.debug.warn("{}: deallocBlock {}\n", .{@typeName(T), block});
                return self.allocator.deallocBlock(block);
            }
        };
        pub usingnamespace if (!implements(T, "deallocAll")) struct {
            pub const deallocAll = void;
        } else struct {
            pub fn deallocAll(self: SelfRef) void {
                std.debug.warn("{}: deallocAll\n", .{@typeName(T)});
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
                std.debug.warn("{}: extendBlockInPlace {} new_len={}\n", .{@typeName(T), block, new_len});
                return try self.allocator.extendBlockInPlace(block, new_len);
            }
        };
        pub usingnamespace if (!implements(T, "retractBlockInPlace")) struct {
            pub const retractBlockInPlace = void;
        } else struct {
            pub fn retractBlockInPlace(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                std.debug.warn("{}: retractBlockInPlace {} new_len={}\n", .{@typeName(T), block, new_len});
                return try self.allocator.retractBlockInPlace(block, new_len);
            }
        };
        pub usingnamespace if (!implements(T, "shrinkBlockInPlace")) struct {
            pub const shrinkBlockInPlace = void;
        } else struct {
            pub fn shrinkBlockInPlace(self: SelfRef, block: *Block, new_len: usize) void {
                std.debug.warn("{}: shrinkBlockInPlace {} new_len={}\n", .{@typeName(T), block, new_len});
                self.allocator.shrinkBlockInPlace(block, new_len);
            }
        };

        pub usingnamespace if (!implements(T, "cReallocBlock")) struct {
            pub const cReallocBlock = void;
        } else struct {
            pub fn cReallocBlock(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                if (T.Block.has_len) assert(block.len() == current_len);
                std.debug.warn("{}: cReallocBlock {} new_len={}\n", .{@typeName(T), block, new_len});
                try self.allocator.cReallocBlock(block, new_len);
                std.debug.warn("{}: cReallocBlock returning {}\n", .{@typeName(T), block});
            }
        };
        pub usingnamespace if (!implements(T, "cReallocAlignedBlock")) struct {
            pub const cReallocAlignedBlock = void;
        } else struct {
            pub fn cReallocAlignedBlock(self: SelfRef, block: *Block, current_len: usize, new_len: usize, current_align: u29, min_align: u29) error{OutOfMemory}!void {
                std.debug.warn("{}: cReallocBlock {} new_len={} align {} > {}\n", .{@typeName(T), block, new_len, current_align, min_align});
                try self.allocator.cReallocAlignedBlock(block, current_len, new_len, current_align, min_align);
                std.debug.warn("{}: cReallocBlock returning {}\n", .{@typeName(T), block});
            }
        };
    };
}


pub fn makeExactAllocator(allocator: anytype) ExactAllocator(@TypeOf(allocator)) {
    return ExactAllocator(@TypeOf(allocator)) { .allocator = allocator };
}
pub fn ExactAllocator(comptime T: type) type {
    if (T.is_exact and implements(T, "shrinkBlockInPlace"))
        @compileError("refusing to wrap " ++ @typeName(T) ++ " with ExactAllocator because it is already exact and already supports shrinkBlockInPlace");

    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();
        pub const Block = MakeBlockType(struct {
            const BlockSelf = @This();

            pub const has_len = true;
            pub const alignment = T.Block.alignment;

            exact_len: usize,
            forward_block: T.Block,

            pub usingnamespace if (T.Block.has_len or !implements(T.Block, "initBuf")) struct {
                pub const initBuf = void;
            } else struct {
                pub fn initBuf(slice: []align(alignment) u8) BlockSelf { return .{
                    .exact_len = slice.len,
                    .forward_block = T.Block.initBuf(slice.ptr)
                };}
            };

            pub fn ptr(self: BlockSelf) [*]align(alignment) u8 { return self.forward_block.ptr(); }
            pub fn len(self: BlockSelf) usize { return self.exact_len; }
            pub fn setLen(self: *BlockSelf, new_len: usize) void { self.exact_len = new_len; }
        });

        allocator: T,

        pub const is_exact = true;
        pub fn allocBlock(self: SelfRef, len: usize) error{OutOfMemory}!Block {
            return Block.init(.{ .exact_len = len, .forward_block = try self.allocator.allocBlock(len)});
        }

        // we can only implement getAvailableLen if allocBlock is implemented
        pub usingnamespace if (implements(T, "getAvailableLen")) struct {
            pub fn getAvailableLen(self: SelfRef, block: Block) usize {
                return self.allocator.getAvailableLen(block.data.forward_block);
            }
        } else if (T.Block.has_len) struct {
            pub fn getAvailableLen(self: SelfRef, block: Block) usize {
                return block.data.forward_block.len();
            }
        } else struct {
            pub const getAvailableLen = void;
        };

        pub fn getAvailableDownLen(self: SelfRef, block: Block) usize {
            @panic("not impl");
        }

        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: make this work
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        pub const inexact = struct {
            pub fn allocBlock(self: SelfRef, len: usize) error{OutOfMemory}!Block {
                @panic("TODO: implement");
            }
        };


        pub usingnamespace if (!implements(T, "allocOverAlignedBlock")) struct {
            pub const allocOverAlignedBlock = void;
        } else struct {
            pub fn allocOverAlignedBlock(self: SelfRef, len: usize, alloc_align: u29) error{OutOfMemory}!Block {
                const forward_block = try self.allocator.allocOverAlignedBlock(len, alloc_align);
                return Block.init(.{
                    .exact_len = len,
                    .forward_block = forward_block,
                });
            }
        };

        pub usingnamespace if (!implements(T, "deallocBlock")) struct {
            pub const deallocBlock = void;
        } else struct {
            pub fn deallocBlock(self: SelfRef, block: Block) void {
                return self.allocator.deallocBlock(block.data.forward_block);
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
                assert(new_len > block.data.exact_len);
                if (new_len > getBlockAvailableLen(&self.allocator, block.data.forward_block, block.data.exact_len)) {
                    try self.allocator.extendBlockInPlace(&block.data.forward_block, new_len);
                    if (T.Block.has_len) {
                        if (T.is_exact) { assert(block.data.forward_block.len() == new_len); }
                        else           { assert(block.data.forward_block.len() >= new_len); }
                    }
                }
                block.data.exact_len = new_len;
            }
        };
        pub usingnamespace if (!implements(T, "retractBlockInPlace")) struct {
            pub const retractBlockInPlace = void;
        } else struct {
            pub fn retractBlockInPlace(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                assert(new_len > 0);
                assert(new_len < block.len());
                try self.allocator.retractBlockInPlace(&block.data.forward_block, new_len);
                if (T.Block.has_len) {
                    if (T.is_exact) { assert(block.data.forward_block.len() == new_len); }
                    else           { assert(block.data.forward_block.len() >= new_len); }
                }
                block.data.exact_len = new_len;
            }
        };

        pub fn shrinkBlockInPlace(self: SelfRef, block: *Block, new_len: usize) void {
            assert(new_len > 0);
            assert(new_len < block.len());
            if (comptime implements(T, "shrinkBlockInPlace")) {
                self.allocator.shrinkBlockInPlace(&block.data.forward_block, new_len);
                if (T.Block.has_len) {
                    if (T.is_exact) { assert(block.data.forward_block.len() == new_len); }
                    else           { assert(block.data.forward_block.len() >= new_len); }
                }
            } else if (comptime implements(T, "retractBlockInPlace")) {
                if (self.retractBlockInPlace(block, new_len)) |_| {
                    if (T.Block.has_len) {
                        if (T.is_exact) { assert(block.data.forward_block.len() == new_len); }
                        else           { assert(block.data.forward_block.len() >= new_len); }
                    }
                } else |e| { } // ignore error
            }
            block.data.exact_len = new_len;
        }

        pub usingnamespace if (!implements(T, "cReallocBlock")) struct {
            pub const cReallocBlock = void;
        } else struct {
            pub fn cReallocBlock(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                if (comptime T.Block.has_len) {
                    if (block.data.forward_block.len() == new_len) return;
                }
                try self.allocator.cReallocBlock(&block.data.forward_block, new_len);
                block.data.exact_len = new_len;
            }
        };
        pub usingnamespace if (!implements(T, "cReallocAlignedBlock")) struct {
            pub const cReallocAlignedBlock = void;
        } else struct {
            pub fn cReallocAlignedBlock(self: SelfRef, block: *Block, current_len: usize, new_len: usize, current_align: u29, min_align: u29) error{OutOfMemory}!void {
                assert(current_len == block.data.exact_len);
                if (comptime T.Block.has_len) {
                    if (block.data.forward_block.len() == new_len) return;
                }
                try self.allocator.cReallocAlignedBlock(&block.data.forward_block, current_len, new_len, current_align, min_align);
                block.data.exact_len = new_len;
            }
        };
    };
}

pub fn makeAlignAllocator(allocator: anytype) AlignAllocator(@TypeOf(allocator)) {
    return AlignAllocator(@TypeOf(allocator)) { .allocator = allocator };
}
pub fn AlignAllocator(comptime T: type) type {
    if (implements(T, "allocOverAlignedBlock"))
        @compileError("refusing to wrap '" ++ @typeName(T) ++ "' with AlignAllocator because it already implements allocOverAlignedBlock");
    if (implements(T, "cReallocAlignedBlock"))
        @compileError("refusing to wrap '" ++ @typeName(T) ++ "' with AlignAllocator because it already implements cReallocAlignedBlock");

    // SEE NOTE: "Why does ExactAllocator wrap AlignAllocator instead of the other way around?"
    // The ArenaAllocator messes up this check
    //if (T.is_exact and implements(T, "shrinkBlockInPlace"))
    //    @compileError("ExactAllocator must wrap AlignAllocator, not the other way around, i.e. .align() must come before .exact()");

    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();

        const BlockData = struct {
            const BlockSelf = @This();

            pub const has_len = T.Block.has_len;
            pub const alignment = T.Block.alignment;

            buf: [*]align(T.Block.alignment) u8,
            forward_block: T.Block,
            // AlignAllocaor can never be represented with just a single pointer/slice
            pub const initBuf = void;
            pub fn ptr(self: BlockSelf) [*]align(alignment) u8 { return self.buf; }
            pub fn len(self: BlockSelf) usize { return self.forward_block.len() - getAlignOffsetData(self); }
            pub fn setLen(self: *BlockSelf, new_len: usize) void {
                self.forward_block.setLen(getAlignOffsetData(self.*) + new_len);
            }
        };
        pub const Block = MakeBlockType(BlockData);
        allocator: T,

        /// returns the offset of the aligned block from the underlying allocated block
        fn getAlignOffsetData(blockData: BlockData) usize {
            return @ptrToInt(blockData.buf) - @ptrToInt(blockData.forward_block.ptr());
        }
        fn getAlignOffset(block: Block) usize { return getAlignOffsetData(block.data); }

        // if the underlying allocator is exact, align allocator remove the exactness
        pub const is_exact = false;
        pub fn allocBlock(self: SelfRef, len: usize) error{OutOfMemory}!Block {
            const forward_block = try self.allocator.allocBlock(len);
            return Block.init(.{ .buf = forward_block.ptr(), .forward_block = forward_block });
        }

        pub usingnamespace if (!implements(T, "getAvailableLen")) struct {
            pub const getAvailableLen = void;
        } else struct {
            pub fn getAvailableLen(self: SelfRef, block: Block) usize {
                return self.allocator.getAvailableLen(block.data.forward_block) - getAlignOffset(block);
            }
        };
        pub fn getAvailableDownLen(self: SelfRef, block: Block) usize {
            return getAlignOffset(block);
        }

        pub fn allocOverAlignedBlock(self: SelfRef, len: usize, alloc_align: u29) error{OutOfMemory}!Block {
            assert(len > 0);
            assert(isValidAlign(alloc_align));
            assert(alloc_align > Block.alignment);

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
            const max_drop_len = alloc_align - Block.alignment;
            var alloc_len = len + max_drop_len;
            const forward_block = try self.allocator.allocBlock(alloc_len);
            const aligned_ptr = @alignCast(Block.alignment,
                @intToPtr([*]u8, mem.alignForward(@ptrToInt(forward_block.ptr()), alloc_align))
            );
            return Block.init(.{ .buf = aligned_ptr, .forward_block = forward_block });
        }

        pub usingnamespace if (!implements(T, "deallocBlock")) struct {
            pub const deallocBlock = void;
        } else struct {
            pub fn deallocBlock(self: SelfRef, block: Block) void {
                return self.allocator.deallocBlock(block.data.forward_block);
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
                const new_aligned_len = getAlignOffset(block.*) + new_len;
                // because we may have over-allocated, there could be alot of room available
                // and we MUST check this before calling extendBlockInPlace because the size we request
                // must be larger than what is already allocated
                var call_extend = if (comptime !T.Block.has_len) true
                    else new_aligned_len > block.data.forward_block.len();
                if (call_extend) {
                    try self.allocator.extendBlockInPlace(&block.data.forward_block, new_aligned_len);
                    if (T.Block.has_len) {
                        if (T.is_exact) { assert(block.data.forward_block.len() == new_aligned_len); }
                        else           { assert(block.data.forward_block.len() >= new_aligned_len); }
                    }
                }
            }
        };
        pub usingnamespace if (!implements(T, "retractBlockInPlace")) struct {
            pub const retractBlockInPlace = void;
        } else struct {
            pub fn retractBlockInPlace(self: SelfRef, block: *Block, new_len: usize) error{OutOfMemory}!void {
                assert(new_len > 0);
                const new_aligned_len = getAlignOffset(block.*) + new_len;
                const call_retract = if (comptime !T.Block.has_len) true
                    else new_aligned_len < block.data.forward_block.len();
                if (call_retract) {
                    try self.allocator.retractBlockInPlace(&block.data.forward_block, new_aligned_len);
                    if (T.Block.has_len) {
                        if (T.is_exact) { assert(block.data.forward_block.len() == new_aligned_len); }
                        else           { assert(block.data.forward_block.len() >= new_aligned_len); }
                    }
                }
            }
        };
        pub usingnamespace if (!implements(T, "shrinkBlockInPlace")) struct {
            pub const shrinkBlockInPlace = void;
        } else struct {
            pub fn shrinkBlockInPlace(self: SelfRef, block: *Block, new_len: usize) void {
                assert(new_len > 0);
                if (T.Block.has_len) assert(new_len < block.len());
                const new_aligned_len = getAlignOffset(block.*) + new_len;
                const call_shrink = if (comptime !T.Block.has_len) true
                    else new_aligned_len < block.data.forward_block.len();
                if (call_shrink) {
                    self.allocator.shrinkBlockInPlace(&block.data.forward_block, new_aligned_len);
                    if (T.Block.has_len) {
                        if (T.is_exact) { assert(block.data.forward_block.len() == new_aligned_len); }
                        else           { assert(block.data.forward_block.len() >= new_aligned_len); }

                    }
                }
            }
        };

        pub const cReallocBlock = void;
        pub usingnamespace if (!implements(T, "cReallocBlock")) struct {
            pub const cReallocAlignedBlock = void;
        } else struct {
            // Note that this maintains the alignment from the original allocOverAlignedBlock call
            pub fn cReallocAlignedBlock(self: SelfRef, block: *Block, current_len: usize, new_len: usize, current_align: u29, min_align: u29) error{OutOfMemory}!void {
                if (T.Block.has_len) assert(current_len == block.len());
                assert(new_len > 0);
                assert(current_len != new_len);
                assert(isValidAlign(current_align));
                assert(mem.isAligned(@ptrToInt(block.ptr()), current_align));
                assert(isValidAlign(min_align));
                assert(min_align <= current_align);

                // TODO: if min_align < current_align, I could try to take back some space instead of calling realloc
                const max_drop_len = if (min_align > Block.alignment) min_align - Block.alignment else 0;
                const alloc_len = new_len + max_drop_len;
                try self.allocator.cReallocBlock(&block.data.forward_block, alloc_len);
                block.data.buf = @alignCast(Block.alignment,
                    @intToPtr([*]u8, mem.alignForward(@ptrToInt(block.data.forward_block.ptr()), min_align))
                );
            }
        };
    };
}

//
// TODO: We could create a PtrAllocator which wraps an allocator with a "pointer-based" API
//       rather than a "slice-based" API.

/// Create a SliceAllocator from a BlockAllocator.
pub fn makeSliceAllocator(allocator: anytype) SliceAllocator(@TypeOf(allocator)) {
    return SliceAllocator(@TypeOf(allocator)) {
        .allocator = allocator,
    };
}
pub fn SliceAllocator(comptime T: type) type {
    return SliceAllocatorGeneric(T, !implements(T.Block, "initBuf"));
}

/// NOTE: if the underlying Block type has no extra data, then storing the block isn't necessary, however,
///       the user may choose to store it anyway to support shrinkInPlace or provide extra sanity checking.
pub fn makeSliceAllocatorGeneric(allocator: anytype, comptime store_block: bool) SliceAllocatorGeneric(@TypeOf(allocator), store_block) {
    return SliceAllocatorGeneric(@TypeOf(allocator), store_block) {
        .allocator = allocator,
    };
}
pub fn SliceAllocatorGeneric(comptime T: type, comptime store_block : bool) type {
    // The purpose of SliceAllocator is to provide a simple slice-based API.  This means it
    // only need to support exact allocation.
    if (!T.is_exact)
        @compileError("SliceAllocator cannot wrap allocator '" ++ @typeName(T) ++ "' where is_exact is false. Wrap it with an ExactAllocator.");
//    if (!implements(T, "shrinkBlockInPlace"))
//        @compileError("SliceAllocator cannot wrap allocator '" ++ @typeName(T) ++ "' that doesn't implement shrinkBlockInPlace. Wrap it with an ExactAllocator.");
    if (!implements(T.Block, "initBuf") and !store_block)
        @compileError("store_block must be set to true for " ++ @typeName(T) ++ " because it has extra data");
    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();
        pub const alignment = T.Block.alignment;
        allocator: T,

        usingnamespace if (!store_block) struct {
            /// The size needed to pad each allocation to store the Block
            pub const alloc_padding = 0;

            const BlockRef = struct {
                block: T.Block,
                pub fn blockPtr(self: *@This()) *T.Block { return &self.block; }
            };
            pub fn getBlockRef(slice: []align(alignment) u8) BlockRef {
                return .{ .block = T.Block.initBuf(if (T.Block.has_len) slice else slice.ptr) };
            }
        } else struct {
            /// The size needed to pad each allocation to store the Block
            pub const alloc_padding = @sizeOf(T.Block) + @alignOf(T.Block) - 1;

            const BlockRef = struct {
                refPtr: *T.Block,
                pub fn blockPtr(self: @This()) *T.Block { return self.refPtr; }
            };
            // only available if store_block is true, can accept non-ref slices
            pub fn getBlockRef(slice: []align(alignment) u8) BlockRef {
                return .{ .refPtr = getStoredBlockRef(slice) };
            }

            // only available if store_block is true, can accept non-ref slices
            pub fn getStoredBlockRef(slice: []align(alignment) u8) *T.Block {
                return @intToPtr(*T.Block, mem.alignForward(@ptrToInt(slice.ptr) + slice.len, @alignOf(T.Block)));
            }
            pub fn debugDumpBlock(slice: []align(alignment) u8) void {
                const block_ptr = getStoredBlockRef(buf);
                if (ForwardBlock.has_len) {
                    std.debug.warn("BLOCK: {}:{}\n", .{block_ptr.ptr(), block_ptr.len()});
                } else {
                    std.debug.warn("BLOCK: {}\n", .{block_ptr.ptr()});
                }
            }
        };

        pub fn alloc(self: SelfRef, len: usize) error{OutOfMemory}![]align(alignment) u8 {
            const padded_len = len + alloc_padding;
            const block = try self.allocator.allocBlock(padded_len);
            if (comptime T.Block.has_len) assert(block.len() == padded_len);
            const slice = block.ptr()[0..len];
            if (store_block)
                getBlockRef(slice).blockPtr().* = block;
            return slice;
        }
        pub usingnamespace if (!implements(T, "allocOverAlignedBlock")) struct {
            pub const allocOverAligned = void;
        } else struct {
            pub fn allocOverAligned(self: SelfRef, len: usize, alloc_align: u29) error{OutOfMemory}![]align(alignment) u8 {
                assert(len > 0);
                assert(isValidAlign(alloc_align));
                assert(alloc_align > alignment);
                const padded_len = len + alloc_padding;
                const block = try self.allocator.allocOverAlignedBlock(padded_len, alloc_align);
                if (comptime T.Block.has_len) assert(block.len() == padded_len);
                assert(mem.isAligned(@ptrToInt(block.ptr()), alloc_align));
                const slice = block.ptr()[0..len];
                if (store_block)
                    getBlockRef(slice).blockPtr().* = block;
                return slice;
            }
        };
        /// Takes care of calling `alloc` or `allocOverAligned` based on `alignment`.
        pub fn allocAligned(self: SelfRef, len: usize, alloc_align: u29) error{OutOfMemory}![]align(alignment) u8 {
            if (alloc_align <= alignment) return self.alloc(len);
            return self.allocOverAligned(len, alloc_align);
        }
        pub fn dealloc(self: SelfRef, slice: []align(alignment) u8) void {
            const block_ptr = getBlockRef(slice).blockPtr();
            if (store_block) {
                assert(block_ptr.ptr() == slice.ptr);
                if (T.Block.has_len) assert(slice.len + alloc_padding == block_ptr.len());
            }
            deallocBlockIfSupported(&self.allocator, block_ptr.*);
        }
        pub usingnamespace if (!implements(T, "extendBlockInPlace")) struct {
            pub const extendInPlace = void;
        } else struct {
            pub fn extendInPlace(self: SelfRef, slice: []align(alignment) u8, new_len: usize) error{OutOfMemory}!void {
                assert(new_len > slice.len);

                var blockRef = getBlockRef(slice);
                const block_ptr = blockRef.blockPtr();
                if (store_block) {
                    assert(slice.ptr == block_ptr.ptr());
                    if (T.Block.has_len) assert(slice.len + alloc_padding == block_ptr.len());
                }
                const new_padded_len = new_len + alloc_padding;
                try self.allocator.extendBlockInPlace(block_ptr, new_padded_len);
                if (T.Block.has_len)
                    assert(block_ptr.len() == new_padded_len);
                if (store_block) {
                    const new_block_ptr = getStoredBlockRef(slice.ptr[0..new_len]);
                    // NOTE: must be memcpyDown in case of overlap
                    memcpyDown(@ptrCast([*]u8, new_block_ptr), @ptrCast([*]u8, block_ptr), @sizeOf(T.Block));
                    assert(new_block_ptr.ptr() == slice.ptr);
                }
            }
        };

        pub usingnamespace if (!implements(T, "shrinkBlockInPlace")) struct {
            pub const shrinkInPlace = void;
        } else struct {
            pub fn shrinkInPlace(self: SelfRef, slice: []align(alignment) u8, new_len: usize) void {
                assert(new_len > 0);
                assert(new_len < slice.len);
                // make a copy of the block so we don't lose it during the shrink
                var block_ref = getBlockRef(slice);
                var block_copy = block_ref.blockPtr().*;
                if (store_block) {
                    assert(slice.ptr == block_copy.ptr());
                    if (T.Block.has_len) assert(slice.len + alloc_padding == block_copy.len());
                }
                const new_padded_len = new_len + alloc_padding;
                self.allocator.shrinkBlockInPlace(&block_copy, new_padded_len);
                if (T.Block.has_len)
                    assert(block_copy.len() == new_padded_len);
                if (store_block) {
                    getStoredBlockRef(slice.ptr[0..new_len]).* = block_copy;
                }
            }
        };

        pub usingnamespace if (!implements(T, "allocOverAlignedBlock")) struct {
            pub const realloc = void;
        } else struct {
            /// Equivalent to C's realloc
            pub fn realloc(self: SelfRef, slice: []align(alignment) u8, new_len: usize, current_align: u29, min_align: u29) error{OutOfMemory}![]align(alignment) u8 {
                assert(new_len > 0);
                // make a copy of the block so we don't lose it during the shrink
                var block_copy = getBlockRef(slice).blockPtr().*;
                assert(slice.ptr == block_copy.ptr());
                const block_len = slice.len + alloc_padding;
                if (T.Block.has_len)
                    assert(block_len == block_copy.len());
                const new_padded_len = new_len + alloc_padding;
                try reallocAlignedBlock(&self.allocator, &block_copy, block_len, new_padded_len, current_align, min_align);
                if (T.Block.has_len)
                    assert(block_copy.len() == new_padded_len);
                const new_slice = block_copy.ptr()[0..new_len];
                if (store_block) {
                    getStoredBlockRef(new_slice).* = block_copy;
                }
                return new_slice;
            }
        };
    };
}

/// Wraps a runtime mem.Allocator instance using the new alloc.zig generic interface
pub fn MemAllocator(comptime exact: bool) type { return struct {
    allocator: *mem.Allocator,
    pub fn init(allocator: *mem.Allocator) @This() { return .{ .allocator = allocator }; }

    pub const Block = MakeSimpleBlockType(true, 1, struct {buf_align: u29});
    pub const is_exact = exact;
    pub fn allocBlock(self: *@This(), len: usize) error{OutOfMemory}!Block {
        assert(len > 0);
        const slice = try self.allocator.allocFn(self.allocator, len, 1, if (is_exact) 0 else 1, 0);
        return Block { .data = .{ .buf = slice, .extra = .{ .buf_align = 1 } }};
    }
    pub const getAvailableLen = void;
    pub const getAvailableDownLen = void;
    pub fn allocOverAlignedBlock(self: *@This(), len: usize, alignment: u29) error{OutOfMemory}!Block {
        assert(len > 0);
        assert(alignment > 1);
        const slice = try self.allocator.allocFn(self.allocator, len, alignment, if (is_exact) 0 else 1, 0);
        return Block { .data = .{ .buf = slice, .extra = .{ .buf_align = alignment } }};
    }
    pub fn deallocBlock(self: *@This(), block: Block) void {
        _ = self.allocator.shrinkBytes(block.data.buf, block.data.extra.buf_align, 0, 0, 0);
    }
    pub const deallocAll = void;
    pub const deinitAndDeallocAll = void;
    pub fn extendBlockInPlace(self: *@This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
        block.setLen(try self.allocator.resizeFn(self.allocator, block.data.buf, block.data.extra.buf_align, new_len, if (is_exact) 0 else 1, 0));
    }
    /// std.mem.Allocator always succeeds when shrinking, so we only need to support shrink, not retract
    pub const retractBlockInPlace = void;
    pub fn shrinkBlockInPlace(self: *@This(), block: *Block, new_len: usize) void {
        block.setLen(self.allocator.shrinkBytes(block.data.buf, block.data.extra.buf_align, new_len, if (is_exact) 0 else 1, 0));
    }
    pub const cReallocBlock = void;
//    pub fn cReallocBlock(self: *@This(), block: *Block, new_len: usize) error{OutOfMemory}!void {
//        const slice = try self.allocator.reallocFn(self.allocator, block.data.buf, block.data.extra.alignment, new_len, 1);
//        assert(slice.len == new_len);
//        block.* = Block { .data = .{ .buf = slice, .extra = .{.alignment = 1} } };
//    }
    pub const cReallocAlignedBlock = void;
//    pub fn cReallocAlignedBlock(self: *@This(), block: *Block, current_len: usize, new_len: usize,
//        current_align: u29, min_align: u29
//    ) error{OutOfMemory}!void {
//        assert(current_len == block.len());
//        assert(new_len > 0);
//        assert(current_len != new_len);
//        assert(isValidAlign(current_align));
//        assert(mem.isAligned(@ptrToInt(block.ptr()), current_align));
//        assert(isValidAlign(min_align));
//        assert(min_align <= current_align);
//        assert(current_len == block.len());
//        const slice = try self.allocator.reallocFn(self.allocator, block.data.buf, block.data.extra.alignment, new_len, min_align);
//        block.* = Block { .data = .{ .buf = slice, .extra = .{.alignment = 1} } };
//    }
};}

/// TODO: these shouldn't be in this module
fn memcpyUp(dst: [*]u8, src: [*]u8, len: usize) void {
     {var i : usize = 0; while (i < len) : (i += 1) {
         dst[i] = src[i];
     }}
}
fn memcpyDown(dst: [*]u8, src: [*]u8, len: usize) void {
     {var i : usize = len; while (i > 0) {
         i -= 1;
         dst[i] = src[i];
     }}
}

/// Common function to get the maximum available length for a block from any allocator
pub fn getBlockAvailableLen(allocator: anytype, block: @TypeOf(allocator.*).Block, alloc_len: usize) usize {
    const T = @TypeOf(allocator.*);
    if (comptime implements(T, "getAvailableLen"))
        return allocator.getAvailableLen(block);
    if (T.Block.has_len) return block.len();
    return alloc_len;
}

/// Common function to get the maximum available length for a block from an allocator where Block.has_len is true
pub fn getBlockAvailableLenHasLen(allocator: anytype, block: @TypeOf(allocator.*).Block) usize {
    const T = @TypeOf(allocator.*);
    if (comptime implements(T, "getAvailableLen"))
        return allocator.getAvailableLen(block);
    return block.len();
}

/// Takes care of calling allocBlock or allocOverAlignedBlock based on `alignment`.
pub fn allocAlignedBlock(allocator: anytype, len: usize, alignment: u29) error{OutOfMemory}!@TypeOf(allocator.*).Block {
    const T = @TypeOf(allocator.*);
    if (comptime !implements(T, "allocOverAlignedBlock"))
        @compileError("allocAlignedBlock cannot be called on '" ++ @typeName(T) ++ "' because it is not aligned.  Wrap it with .aligned()");

    assert(len > 0);
    assert(isValidAlign(alignment));
    return if (alignment <= T.Block.alignment) allocator.allocBlock(len)
        else allocator.allocOverAlignedBlock(len, alignment);
}

/// Call deallocBlock only if it is supported by the given allocator, otherwise, do nothing.
pub fn deallocBlockIfSupported(allocator: anytype, block: @TypeOf(allocator.*).Block) void {
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

pub fn testBlockAllocator(allocator: anytype) void {
    const T = @TypeOf(allocator.*);
    if (comptime implements(T, "allocBlock")) {
        {var i: u8 = 1; while (i < 200) : (i += 17) {
            const block = allocator.allocBlock(i) catch continue;
            if (T.Block.has_len) {
                if (T.is_exact) assert(block.len() == i)
                else assert(block.len() >= i);
            }
            defer deallocBlockIfSupported(allocator, block);
            const available_len = getBlockAvailableLen(allocator, block, i);
            assert(available_len >= i);
            testReadWrite(block.ptr()[0..available_len], i);
        }}
    }
    if (@hasField(T, "inexact")) {
        {var i: u8 = 1; while (i < 200) : (i += 17) {
            const block = allocator.inexact.allocBlock(i) catch continue;
            if (T.Block.has_len) assert(block.len() >= i);
            defer deallocBlockIfSupported(allocator, block);
            const available_len = getBlockAvailableLen(allocator, block, i);
            assert(available_len >= i);
            testReadWrite(block.ptr()[0..available_len], i);
        }}
    }
    if (comptime implements(T, "allocOverAlignedBlock")) {
        {var alignment: u29 = T.Block.alignment * 2; while (alignment < 8192) : (alignment *= 2) {
            {var i: u8 = 1; while (i < 200) : (i += 17) {
                const initial_len : usize = i;
                const block = allocator.allocOverAlignedBlock(initial_len, alignment) catch continue;
                defer deallocBlockIfSupported(allocator, block);
                // todo: test the whole block's available memory
                testReadWrite(block.ptr()[0..initial_len], i);
            }}
        }}
    }
    if (comptime implements(T, "deallocAll")) {
        var i: u8 = 1;
        while (i < 200) : (i += 19) {
            const initial_len : usize = i;
            const block = allocator.allocBlock(initial_len) catch break;
            const avail = getBlockAvailableLen(allocator, block, initial_len);
            testReadWrite(block.ptr()[0..avail], i);
        }
        allocator.deallocAll();
    }
    // TODO: deinitAndDeallocAll will need a different function where
    //       we aren't testing a specific instance

    if (comptime implements(T, "extendBlockInPlace")) {
        {var i: u8 = 1; while (i < 100) : (i += 1) {
            const initial_len : usize = i;
            var block = allocator.allocBlock(initial_len) catch continue;
            defer deallocBlockIfSupported(allocator, block);
            const initial_avail = getBlockAvailableLen(allocator, block, initial_len);
            testReadWrite(block.ptr()[0..initial_avail], 125);
            const extend_len = initial_avail + 1;
            allocator.extendBlockInPlace(&block, extend_len) catch continue;
            {
                const avail = getBlockAvailableLen(allocator, block, extend_len);
                testReadWrite(block.ptr()[0..avail], 39);
            }
        }}
    }
    if (comptime implements(T, "retractBlockInPlace")) {
        {var i: u8 = 2; while (i < 100) : (i += 1) {
            const initial_len : usize = i;
            var block = allocator.allocBlock(initial_len) catch continue;
            defer deallocBlockIfSupported(allocator, block);
            {
                const avail = getBlockAvailableLen(allocator, block, initial_len);
                testReadWrite(block.ptr()[0..avail], 18);
            }
            // TODO: use a loop to slowly retract
            allocator.retractBlockInPlace(&block, 1) catch continue;
            testReadWrite(block.ptr()[0..1], 91);
        }}
    }
    if (comptime implements(T, "shrinkBlockInPlace")) {
        {var i: u8 = 2; while (i < 100) : (i += 1) {
            var block = allocator.allocBlock(i) catch continue;
            defer deallocBlockIfSupported(allocator, block);
            {
                const avail = getBlockAvailableLen(allocator, block, i);
                assert(avail >= i);
                testReadWrite(block.ptr()[0..avail], 18);
            }
            // TODO: use a loop to slowly shrink
            allocator.shrinkBlockInPlace(&block, 1);
            const avail = getBlockAvailableLen(allocator, block, 1);
            assert(avail >= 1);
            testReadWrite(block.ptr()[0..avail], 91);
        }}
    }

    // test reallocBlock
    if (comptime T.is_exact and implements(T, "allocOverAlignedBlock")) {
        {var alignment: u29 = 1; while (alignment <= 8192) : (alignment *= 2) {
            {var i: u8 = 1; while (i < 200) : (i += 17) {
                var len: usize = i;
                var block = allocAlignedBlock(allocator, len, alignment) catch continue;
                if (T.Block.has_len) assert(block.len() == len);
                assert(mem.isAligned(@ptrToInt(block.ptr()), alignment));
                defer deallocBlockIfSupported(allocator, block);
                testReadWrite(block.ptr()[0..len], i);
                {
                    const next_len = len + 10;
                    if (reallocAlignedBlock(allocator, &block, len, next_len, alignment, alignment)) |_| {
                        if (T.Block.has_len) assert(block.len() == next_len);
                        assert(mem.isAligned(@ptrToInt(block.ptr()), alignment));
                        testReadWrite(block.ptr()[0..next_len], 201);
                        len = next_len;
                    } else |_| { }
                }
                while (len > 30) {
                    const next_len = len / 3;
                    if (reallocAlignedBlock(allocator, &block, len, next_len, alignment, alignment)) |_| {
                        if (T.Block.has_len) assert(block.len() == next_len);
                        assert(mem.isAligned(@ptrToInt(block.ptr()), alignment));
                        testReadWrite(block.ptr()[0..next_len], 201);
                        len = next_len;
                    } else |_| break;
                }
            }}
        }}
    }
}

fn testSliceAllocator(allocator: anytype) void {
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
        {var i: u8 = 1; while (i < 200) : (i += 1) {
            var slice = allocator.alloc(i) catch continue;
            defer allocator.dealloc(slice);
            const extend_len = i + 30;
            allocator.extendInPlace(slice, extend_len) catch continue;
            slice = slice.ptr[0..extend_len];
            testReadWrite(slice, extend_len);
        }}
    }
    if (comptime implements(T, "shrinkInPlace")) {
        {var i: u8 = 2; while (i < 200) : (i += 14) {
            var slice = allocator.alloc(i) catch continue;
            assert(slice.len == i);
            defer allocator.dealloc(slice);
            testReadWrite(slice, i);
            while (slice.len >= 2) {
                const next_len = slice.len / 2;
                allocator.shrinkInPlace(slice, next_len);
                slice = slice[0..next_len];
                testReadWrite(slice, i);
            }
        }}
    }
    if (comptime implements(T, "realloc")) {
        {var alignment: u8 = 1; while (alignment <= 1) : (alignment *= 2) {
            {var i: u8 = 2; while (i < 200) : (i += 14) {
                var slice = allocator.allocAligned(i, alignment) catch continue;
                defer allocator.dealloc(slice);
                testReadWrite(slice, i);
                {var j: u8 = 1; while (j <= 27) : (j += 13) {
                    slice = allocator.realloc(slice, slice.len + j, alignment, alignment) catch break;
                    testReadWrite(slice, j);
                }}
                {var j: u8 = 1; while (j <= 40 and j > slice.len) : (j += 13) {
                    slice = allocator.realloc(slice, slice.len + j, alignment, alignment) catch break;
                    testReadWrite(slice, j);
                }}
            }}
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
/// when new functions are added, every type must address whether or not it is supported.
/// This also protects from typo bugs, because if a function name is mispelled then it
/// will result in a compile error rather than a runtime bug from the function being
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
