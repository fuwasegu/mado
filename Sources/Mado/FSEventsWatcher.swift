import Foundation
import CoreServices

/// FSEvents によるディレクトリ再帰監視。
/// Claude Code 等がターミナルから書き込んだ変更(atomic save の rename 含む)を拾う。
final class FSEventsWatcher {
    private var streamRef: FSEventStreamRef?
    private let onEvents: ([String]) -> Void

    init?(path: String, onEvents: @escaping ([String]) -> Void) {
        self.onEvents = onEvents

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            var paths: [String] = []
            paths.reserveCapacity(numEvents)
            for i in 0..<numEvents {
                if let path = (cfPaths as NSArray)[i] as? String {
                    paths.append(path)
                }
            }
            watcher.onEvents(paths)
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15, // latency: 連続書き込みをまとめる
            flags
        ) else { return nil }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    deinit { stop() }
}
