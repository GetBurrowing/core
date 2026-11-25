import Foundation

/// Debug builds only (task 01a20fdd stage 4): the on-device Voice timings the
/// device report needs, appended to `Library/Caches/voice-trace.log` with a
/// monotonic millisecond clock. Ids, counts, states and timings only: never
/// what was said or the reply text. Read it back from the Mac with
/// `xcrun devicectl device copy from --domain-type appDataContainer
/// --domain-identifier com.kobo-ai.burrow --source Library/Caches/voice-trace.log`.
/// Release builds compile every call to nothing.
enum VoiceTrace {
    #if DEBUG
        private static let lock = NSLock()
        private static let url: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("voice-trace.log")

        /// Milliseconds since boot (CLOCK_UPTIME_RAW): comparable across lines.
        static var nowMs: Int { Int(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000) }
    #endif

    static func log(_ line: @autoclosure () -> String) {
        #if DEBUG
            guard let url else { return }
            let entry = "t=\(nowMs) \(line())\n"
            lock.lock()
            defer { lock.unlock() }
            guard let data = entry.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        #endif
    }

    /// The app's phys_footprint in MB (what jetsam counts).
    static func footprintMB() -> Int {
        #if DEBUG
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
        #else
            return 0
        #endif
    }

    /// `-BurrowPocketTTSReset` (Debug): delete the Pocket TTS model files at
    /// launch, so the next pick measures a first-use download again.
    static func resetPocketIfRequested() {
        #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("-BurrowPocketTTSReset") else { return }
            let root = PocketModelStore.defaultRoot()
            let existed = FileManager.default.fileExists(atPath: root.path)
            try? FileManager.default.removeItem(at: root)
            log("pocket reset existed=\(existed)")
        #endif
    }
}
