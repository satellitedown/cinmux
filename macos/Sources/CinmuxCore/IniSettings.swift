import Foundation

/// The Linux build's QSettings ui.ini in the state directory: `[group]`
/// sections of `key=value` lines. Unknown groups and keys are kept.
public final class IniSettings {
    private let path: String
    private var sections: [(name: String, entries: [(key: String, value: String)])] = []

    public init(path: String) {
        self.path = path
        guard let data = FileManager.default.contents(atPath: path) else { return }
        var current = -1
        for rawLine in String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast())
                if let existing = sections.firstIndex(where: { $0.name == name }) { current = existing }
                else {
                    sections.append((name: name, entries: []))
                    current = sections.count - 1
                }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            if current < 0 {
                sections.append((name: "General", entries: []))
                current = sections.count - 1
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            sections[current].entries.append((key: key, value: value))
        }
    }

    /// The value of "group/key", unquoted as QSettings writes strings with special characters.
    public func value(_ name: String) -> String? {
        let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let section = sections.first(where: { $0.name == parts[0] }),
              let raw = section.entries.last(where: { $0.key == parts[1] })?.value else { return nil }
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        var result = ""
        var escaped = false
        for character in raw.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// QVariant::toBool on a stored string: false only for "", "0" and "false".
    public func bool(_ name: String, _ fallback: Bool) -> Bool {
        guard let raw = value(name) else { return fallback }
        let lowered = raw.lowercased()
        return !(lowered.isEmpty || lowered == "0" || lowered == "false")
    }

    /// QVariant::toInt on a stored string: 0 when it is not a number.
    public func int(_ name: String, _ fallback: Int) -> Int {
        guard let raw = value(name) else { return fallback }
        return Int(raw) ?? 0
    }

    public func set(_ name: String, _ value: String) {
        let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        var stored = value
        if value.contains(where: { $0 == ";" || $0 == "," || $0 == "=" || $0 == "\"" || $0 == "\\" }) || value != value.trimmingCharacters(in: .whitespaces) {
            stored = "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var index = sections.firstIndex(where: { $0.name == parts[0] })
        if index == nil {
            sections.append((name: parts[0], entries: []))
            index = sections.count - 1
        }
        guard let section = index else { return }
        if let entry = sections[section].entries.lastIndex(where: { $0.key == parts[1] }) {
            sections[section].entries[entry].value = stored
        } else {
            sections[section].entries.append((key: parts[1], value: stored))
        }
    }

    /// Writes the file atomically; false when it could not be saved.
    @discardableResult
    public func sync() -> Bool {
        var text = ""
        for (index, section) in sections.enumerated() {
            if index > 0 { text += "\n" }
            text += "[\(section.name)]\n"
            // QSettings keeps a group's keys sorted.
            for entry in section.entries.sorted(by: { $0.key < $1.key }) { text += "\(entry.key)=\(entry.value)\n" }
        }
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
