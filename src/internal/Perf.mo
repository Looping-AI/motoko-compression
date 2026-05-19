/// Lightweight profiling probe for hot-path instrumentation.
///
/// Usage (injected transiently by perf scripts — never committed to src):
///   Perf.mark("huffman_encode");
///
/// Each call prints one line to the canister log:
///   [perf] <label> instrs=<N> mem=<N> heap=<N>
///
/// Fields:
///   instrs — IC performance counter 0 (instruction count since last message start)
///   mem    — total Wasm memory pages * 64 KiB (Prim.rts_memory_size)
///   heap   — live heap bytes (Prim.rts_heap_size)
///
/// Collect logs via pic.fetchCanisterLogs() in PocketIC scripts.
/// This module must NOT be imported in src/ at rest.

import IC    "mo:core/InternetComputer";
import Debug "mo:core/Debug";
import Prim  "mo:⛔";

module {

  /// Emit a single profiling snapshot tagged with `tag`.
  public func mark(tag : Text) {
    let instrs = IC.performanceCounter(0);
    let mem    = Prim.rts_memory_size();
    let heap   = Prim.rts_heap_size();
    Debug.print(
      "[perf] " # tag #
      " instrs=" # debug_show instrs #
      " mem="    # debug_show mem    #
      " heap="   # debug_show heap
    );
  };

}
