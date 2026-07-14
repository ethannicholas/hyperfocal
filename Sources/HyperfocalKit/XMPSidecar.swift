import Foundation

/// Camera Raw XMP for DNG exports: a DNG deliberately stays linear (tone
/// bakes only into display-referred formats), so edited tone rides along as
/// an XMP packet embedded in the DNG itself — the form Lightroom and Adobe
/// Camera Raw read for DNGs (sidecar .xmp files are only consulted for
/// proprietary raw formats). ToneSettings was designed on Lightroom's
/// slider model (exposure in stops, plus-minus-100 region sliders with the
/// same range masks), so the mapping is direct: the rendered starting point
/// in Adobe tools lands close to what the app showed, with every slider
/// still live.
public enum XMPSidecar {

    /// The XMP body carrying the tone settings as Camera Raw develop
    /// settings (Process Version 2012 — the "2012" parameter names).
    public static func cameraRawXMP(for tone: ToneSettings) -> String {
        func ev(_ v: Double) -> String { String(format: "%+.2f", v) }
        func slider(_ v: Double) -> String { String(format: "%+.0f", v.rounded()) }
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Hyperfocal">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmp:CreatorTool="Hyperfocal"
            crs:Version="15.4"
            crs:ProcessVersion="11.0"
            crs:Exposure2012="\(ev(tone.exposure))"
            crs:Contrast2012="\(slider(tone.contrast))"
            crs:Highlights2012="\(slider(tone.highlights))"
            crs:Shadows2012="\(slider(tone.shadows))"
            crs:Whites2012="\(slider(tone.whites))"
            crs:Blacks2012="\(slider(tone.blacks))"
            crs:HasSettings="True"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
    }

    /// The packet form embedded in files: xpacket wrapper plus padding, per
    /// the XMP spec (padding lets editors update metadata in place).
    static func packet(for tone: ToneSettings) -> [UInt8] {
        let body = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
            + cameraRawXMP(for: tone)
            + "\n"
        let padding = String(repeating: " ", count: 2048)
        return Array((body + padding + "<?xpacket end=\"w\"?>").utf8)
    }

    /// Embeds the tone settings into an already-written DNG as TIFF tag 700
    /// (XMP) on IFD0. IFDs can't grow in place, so IFD0 is rewritten at the
    /// end of the file with the one extra entry and the header's first-IFD
    /// pointer is repointed; every other structure keeps its absolute
    /// offsets. Works identically for the SDK-written and hand-rolled DNGs,
    /// and — unlike a sidecar — needs no sandbox grant beyond the exported
    /// file itself.
    public static func embed(tone: ToneSettings, inDNGAt url: URL) throws {
        var data = try Data(contentsOf: url)
        guard data.count > 8 else { throw EmbedError.notATIFF }
        let littleEndian: Bool
        switch (data[0], data[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw EmbedError.notATIFF
        }
        func u16(_ offset: Int) -> Int {
            let a = Int(data[offset]), b = Int(data[offset + 1])
            return littleEndian ? a | (b << 8) : (a << 8) | b
        }
        func u32(_ offset: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 {
                v |= UInt32(data[offset + (littleEndian ? i : 3 - i)]) << (8 * i)
            }
            return v
        }
        func bytes16(_ v: Int) -> [UInt8] {
            let le: [UInt8] = [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
            return littleEndian ? le : le.reversed()
        }
        func bytes32(_ v: UInt32) -> [UInt8] {
            let le = (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) }
            return littleEndian ? le : le.reversed()
        }

        let ifd0 = Int(u32(4))
        guard ifd0 + 2 <= data.count else { throw EmbedError.notATIFF }
        let count = u16(ifd0)
        let entriesStart = ifd0 + 2
        let ifdEnd = entriesStart + count * 12
        guard ifdEnd + 4 <= data.count else { throw EmbedError.notATIFF }
        let nextIFD = u32(ifdEnd)

        // XMP payload at the end of the file (even-aligned).
        if data.count % 2 == 1 { data.append(0) }
        let xmp = packet(for: tone)
        let xmpOffset = UInt32(data.count)
        data.append(contentsOf: xmp)
        if data.count % 2 == 1 { data.append(0) }

        // New tag 700 entry: type 1 (BYTE) per the XMP spec's TIFF mapping.
        var xmpEntry = [UInt8]()
        xmpEntry += bytes16(700)
        xmpEntry += bytes16(1)
        xmpEntry += bytes32(UInt32(xmp.count))
        xmpEntry += bytes32(xmpOffset)

        // Rebuilt IFD0: existing entries (verbatim — value offsets stay
        // valid) with the new one inserted in ascending tag order.
        var entries = (0..<count).map { i -> [UInt8] in
            Array(data[(entriesStart + i * 12)..<(entriesStart + (i + 1) * 12)])
        }
        guard !entries.contains(where: { entry in u16FromBytes(entry, littleEndian) == 700 })
        else { return }  // already has XMP; leave it
        let insertAt = entries.firstIndex { u16FromBytes($0, littleEndian) > 700 }
            ?? entries.count
        entries.insert(xmpEntry, at: insertAt)

        let newIFDOffset = UInt32(data.count)
        data.append(contentsOf: bytes16(entries.count))
        for entry in entries { data.append(contentsOf: entry) }
        data.append(contentsOf: bytes32(nextIFD))
        data.replaceSubrange(4..<8, with: bytes32(newIFDOffset))
        try data.write(to: url, options: .atomic)
    }

    private static func u16FromBytes(_ entry: [UInt8], _ littleEndian: Bool) -> Int {
        littleEndian ? Int(entry[0]) | (Int(entry[1]) << 8)
                     : (Int(entry[0]) << 8) | Int(entry[1])
    }

    enum EmbedError: Error {
        case notATIFF
    }
}
