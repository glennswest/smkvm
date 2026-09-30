/// Text and key names → USB HID usages (US layout), for scripted input.
public enum TextKeys {
    public struct Stroke: Equatable, Sendable {
        public let hid: UInt8
        public let shift: Bool
    }

    /// Keystrokes that type `text`. "\n" is Enter, "\t" Tab. Characters with
    /// no US-layout key are skipped and reported in `unsupported`.
    public static func strokes(for text: String) -> (strokes: [Stroke], unsupported: [Character]) {
        var out: [Stroke] = [], bad: [Character] = []
        for ch in text {
            if let s = stroke(ch) { out.append(s) } else { bad.append(ch) }
        }
        return (out, bad)
    }

    static func stroke(_ ch: Character) -> Stroke? {
        switch ch {
        case "a"..."z": return Stroke(hid: 0x04 + UInt8(ch.asciiValue! - 97), shift: false)
        case "A"..."Z": return Stroke(hid: 0x04 + UInt8(ch.asciiValue! - 65), shift: true)
        case "1"..."9": return Stroke(hid: 0x1E + UInt8(ch.asciiValue! - 49), shift: false)
        case "0": return Stroke(hid: 0x27, shift: false)
        case "\n", "\r\n", "\r": return Stroke(hid: 0x28, shift: false)
        case "\t": return Stroke(hid: 0x2B, shift: false)
        default:
            if let (hid, shift) = punctuation[ch] { return Stroke(hid: hid, shift: shift) }
            return nil
        }
    }

    static let punctuation: [Character: (UInt8, Bool)] = [
        " ": (0x2C, false), "-": (0x2D, false), "_": (0x2D, true), "=": (0x2E, false), "+": (0x2E, true),
        "[": (0x2F, false), "{": (0x2F, true), "]": (0x30, false), "}": (0x30, true),
        "\\": (0x31, false), "|": (0x31, true), ";": (0x33, false), ":": (0x33, true),
        "'": (0x34, false), "\"": (0x34, true), "`": (0x35, false), "~": (0x35, true),
        ",": (0x36, false), "<": (0x36, true), ".": (0x37, false), ">": (0x37, true),
        "/": (0x38, false), "?": (0x38, true),
        "!": (0x1E, true), "@": (0x1F, true), "#": (0x20, true), "$": (0x21, true), "%": (0x22, true),
        "^": (0x23, true), "&": (0x24, true), "*": (0x25, true), "(": (0x26, true), ")": (0x27, true),
    ]

    /// Parses a chord like "ctrl+alt+delete", "f2", "shift+tab", "a".
    /// Returns HID usages in press order, or nil if a name is unknown.
    public static func chord(_ spec: String) -> [UInt8]? {
        var keys: [UInt8] = []
        for raw in spec.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { keys.append(0x2E); continue }          // "ctrl++" → the + key
            if let k = names[name] { keys.append(k); continue }
            if name.count == 1, let s = stroke(Character(name)) { keys.append(s.hid); continue }
            if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...24).contains(n) {
                keys.append(n <= 12 ? 0x3A + UInt8(n - 1) : 0x68 + UInt8(n - 13)); continue
            }
            return nil
        }
        return keys.isEmpty ? nil : keys
    }

    public static let names: [String: UInt8] = [
        "enter": 0x28, "return": 0x28, "esc": 0x29, "escape": 0x29, "backspace": 0x2A, "tab": 0x2B,
        "space": 0x2C, "capslock": 0x39, "printscreen": 0x46, "prtsc": 0x46, "scrolllock": 0x47,
        "pause": 0x48, "break": 0x48, "insert": 0x49, "ins": 0x49, "home": 0x4A, "pageup": 0x4B, "pgup": 0x4B,
        "delete": 0x4C, "del": 0x4C, "end": 0x4D, "pagedown": 0x4E, "pgdn": 0x4E,
        "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52, "numlock": 0x53, "menu": 0x65,
        "ctrl": 0xE0, "control": 0xE0, "shift": 0xE1, "alt": 0xE2, "option": 0xE2,
        "win": 0xE3, "super": 0xE3, "cmd": 0xE3, "meta": 0xE3,
        "rctrl": 0xE4, "rshift": 0xE5, "ralt": 0xE6, "altgr": 0xE6, "rwin": 0xE7,
    ]
}
