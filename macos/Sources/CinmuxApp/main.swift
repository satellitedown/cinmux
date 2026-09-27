import AppKit

// Must precede anything that touches NSFontManager.shared.
NSFontManager.setFontManagerFactory(CascadePreservingFontManager.self)
CinmuxMacApp.main()

/// Keeps a font's fallback cascade when AppKit derives its bold and italic
/// variants. SwiftTerm draws bold text (prompt icons, for one) with those, and
/// the plain conversion would drop the bundled Nerd Font symbols fallback.
final class CascadePreservingFontManager: NSFontManager {
    override func convert(_ font: NSFont, toHaveTrait trait: NSFontTraitMask) -> NSFont {
        let converted = super.convert(font, toHaveTrait: trait)
        guard let cascade = font.fontDescriptor.object(forKey: .cascadeList),
              converted.fontDescriptor.object(forKey: .cascadeList) == nil else { return converted }
        return NSFont(descriptor: converted.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: converted.pointSize) ?? converted
    }
}
