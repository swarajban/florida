public enum DayPaging {
    public static func settledIndex(offset: Double, pageWidth: Double, pageCount: Int) -> Int {
        guard pageWidth > 0, pageCount > 0 else { return 0 }
        return min(pageCount - 1, max(0, Int((offset / pageWidth).rounded())))
    }

    public static func targetOffset(proposed: Double, original: Double, pageWidth: Double, pageCount: Int) -> Double {
        guard pageWidth > 0, pageCount > 0 else { return 0 }
        let start = Double(settledIndex(offset: original, pageWidth: pageWidth, pageCount: pageCount)) * pageWidth
        let target = (proposed / pageWidth).rounded() * pageWidth
        return min(Double(pageCount - 1) * pageWidth, max(0, min(start + pageWidth, max(start - pageWidth, target))))
    }
}
