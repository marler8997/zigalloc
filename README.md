# zialloc

A generic composable allocation library.  See [alloc.zig](alloc.zig) for documentation.

# Where does this fit?

This module is not meant to replace `std.mem.Allocator`, but complement it.

When it comes to allocation, there are many of tradeoffs to consider.  Any fixed allocation interface will have tough decisions to make about allocation alignment, data ownership, interface complexity, etc.  The power of a "generic" library is that it enables many decisions to become "options" available for the application to configure rather than forcing all applications to a particular choice.

This being said, the cost of a generic library is that each option instantiates a new implementation which can result in a explosion of code if too many options are instantiated at once.  The solution is to combine the two methods by implementing generic allocators and providing a fixed interface on top of it.  This provides the best of both worlds, the fixed interface is available if code explosion becomes an issue, and the generic interface is available for those that want zero overhead code tailored for their specific application.

# Next Steps

* get performance data on the standard library when replacing the fixed allocators with the generic ones implemented here
