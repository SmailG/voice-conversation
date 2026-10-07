// Which physical key types a character in the current keyboard layout, with ⌘ held, so a synthetic
// ⌘V is ⌘V on Dvorak, AZERTY or a "Dvorak – QWERTY ⌘" layout too.

import Carbon

/// The virtual key code that types `character` with ⌘ held in the current layout; nil if no
/// key does (a non-Latin layout: macOS then reads ⌘ shortcuts from the US positions).
func keyCode(typing character: String) -> CGKeyCode? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    let commandState = UInt32((cmdKey >> 8) & 0xFF)
    return data.withUnsafeBytes { bytes -> CGKeyCode? in
        guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
        for code in 0..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), commandState,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1) == character {
                return CGKeyCode(code)
            }
        }
        return nil
    }
}
