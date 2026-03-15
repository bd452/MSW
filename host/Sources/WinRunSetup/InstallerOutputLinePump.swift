import Foundation

final class OutputLinePump: @unchecked Sendable {
    private let prefix: String
    private let outputHandler: @Sendable (String) -> Void
    private let lock = NSLock()
    private var buffered = Data()

    init(prefix: String, outputHandler: @escaping @Sendable (String) -> Void) {
        self.prefix = prefix
        self.outputHandler = outputHandler
    }

    func attach(to handle: FileHandle) {
        handle.readabilityHandler = { [weak self] fileHandle in
            guard let self else { return }
            let data = fileHandle.availableData
            if data.isEmpty {
                self.flush()
                fileHandle.readabilityHandler = nil
                return
            }
            self.consume(data)
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffered.append(data)
        let chunk = buffered
        lock.unlock()

        guard let text = String(data: chunk, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return }

        for line in lines.dropLast() where !line.isEmpty {
            outputHandler(prefix + line)
        }

        let remainder = lines.last ?? ""
        lock.lock()
        buffered = Data(remainder.utf8)
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let data = buffered
        buffered.removeAll(keepingCapacity: false)
        lock.unlock()

        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else { return }
        outputHandler(prefix + text)
    }
}
