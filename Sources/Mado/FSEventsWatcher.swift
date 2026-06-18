import Foundation
import CoreServices

/// FSEvents が報告する 1 イベント(パスと種別フラグ)。
struct FSEvent {
    let path: String
    let flags: FSEventStreamEventFlags
}

/// FSEvents によるディレクトリ再帰監視。
/// Claude Code 等がターミナルから書き込んだ変更(atomic save の rename 含む)を拾う。
final class FSEventsWatcher {
    private var streamRef: FSEventStreamRef?
    private let onEvents: ([FSEvent]) -> Void

    init?(path: String, onEvents: @escaping ([FSEvent]) -> Void) {
        self.onEvents = onEvents

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            var events: [FSEvent] = []
            events.reserveCapacity(numEvents)
            for i in 0..<numEvents {
                guard let path = cfPaths[i] as? String else { continue }
                events.append(FSEvent(path: path, flags: eventFlags[i]))
            }
            watcher.onEvents(events)
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
