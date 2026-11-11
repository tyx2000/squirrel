// Purpose: Hands memory freed after a large, one-off allocation back to the system.

import Darwin

enum MemoryRelief {
    /// The app spends most of its life idle in the menu bar. After a screenshot or a large
    /// clipboard image, malloc keeps the freed pages for reuse that may never come, so the
    /// footprint stays at its peak. This returns them.
    nonisolated static func releaseFreedMemory() {
        malloc_zone_pressure_relief(nil, 0)
    }
}
