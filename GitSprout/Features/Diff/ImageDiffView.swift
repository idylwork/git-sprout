import AppKit
import PDFKit
import SwiftUI

struct ImageDiffView: View {
    var before: ImageContent
    var after: ImageContent

    @State private var mode: ImageDiffMode = .sideBySide
    @State private var split: CGFloat = 0.5

    static func canDisplay(before: ImageContent, after: ImageContent) -> Bool {
        if before == .tooLarge || after == .tooLarge { return true }
        return canOpen(before) || canOpen(after)
    }

    var body: some View {
        let beforeImages = Self.images(from: before)
        let afterImages = Self.images(from: after)
        VStack(spacing: 0) {
            if beforeImages.count == 1, afterImages.count == 1 {
                Picker("Compare", selection: $mode) {
                    ForEach(ImageDiffMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                .padding(8)
                Divider()
            }
            if mode == .swipe, let beforeImage = beforeImages.first, let afterImage = afterImages.first, beforeImages.count == 1, afterImages.count == 1 {
                swipe(before: beforeImage, after: afterImage)
            } else {
                HStack(spacing: 0) {
                    pane(
                        title: String(localized: "Before"),
                        payload: before,
                        images: beforeImages,
                        missingTitle: String(localized: "Added")
                    )
                    Divider()
                    pane(
                        title: String(localized: "After"),
                        payload: after,
                        images: afterImages,
                        missingTitle: String(localized: "Deleted")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func pane(title: String, payload: ImageContent, images: [NSImage], missingTitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
            if images.count > 1 {
                Text(String(localized: "\(images.count) pages"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let image = images.first {
                Text(pixelLabel(image))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ZStack {
                if payload == .tooLarge {
                    ContentUnavailableView("Image is too large to display.", systemImage: "exclamationmark.triangle")
                } else if images.count > 1 {
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                                VStack(spacing: 4) {
                                    Text(String(localized: "Page \(index + 1)"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    fitted(image, fills: false)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } else if let image = images.first {
                    fitted(image, fills: true)
                } else if payload == .absent {
                    ContentUnavailableView(missingTitle, systemImage: "photo")
                } else {
                    ContentUnavailableView("Binary File", systemImage: "doc")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func swipe(before: NSImage, after: NSImage) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack {
                    fitted(after, fills: true)
                    fitted(before, fills: true)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: width * split, height: proxy.size.height)
                        }
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: proxy.size.height)
                        .offset(x: width * split - proxy.size.width / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            split = min(1, max(0, value.location.x / width))
                        }
                )
            }
            HStack(spacing: 8) {
                Text("Before")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $split, in: 0...1)
                    .accessibilityLabel(String(localized: "Swipe"))
                Text("After")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func fitted(_ image: NSImage, fills: Bool) -> some View {
        let pixels = pixelSize(image)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .background(Checkerboard())
            .overlay {
                Rectangle().strokeBorder(Color.primary.opacity(0.15))
            }
            .frame(maxWidth: CGFloat(max(pixels.width, 1)), maxHeight: CGFloat(max(pixels.height, 1)))
            .frame(maxWidth: fills ? .infinity : nil, maxHeight: fills ? .infinity : nil)
    }

    private func pixelLabel(_ image: NSImage) -> String {
        let pixels = pixelSize(image)
        return "\(pixels.width) × \(pixels.height)"
    }

    private func pixelSize(_ image: NSImage) -> (width: Int, height: Int) {
        let width = image.representations.map(\.pixelsWide).max() ?? 0
        let height = image.representations.map(\.pixelsHigh).max() ?? 0
        if width > 0, height > 0 { return (width, height) }
        return (Int(image.size.width.rounded()), Int(image.size.height.rounded()))
    }

    static func images(from payload: ImageContent) -> [NSImage] {
        guard case .data(let data) = payload else { return [] }
        return images(from: data)
    }

    private static func canOpen(_ payload: ImageContent) -> Bool {
        guard case .data(let data) = payload else { return false }
        if let document = pdfDocument(from: data) {
            return document.pageCount > 0
        }
        return NSImage(data: data) != nil
    }

    static func images(from data: Data) -> [NSImage] {
        if let document = pdfDocument(from: data), document.pageCount > 0 {
            let pages = (0..<document.pageCount).compactMap { index -> NSImage? in
                guard let page = document.page(at: index) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let size = NSSize(width: max(bounds.width * 2, 1), height: max(bounds.height * 2, 1))
                return page.thumbnail(of: size, for: .mediaBox)
            }
            if !pages.isEmpty { return pages }
        }
        if let image = NSImage(data: data) {
            return [image]
        }
        return []
    }

    private static func pdfDocument(from data: Data) -> PDFDocument? {
        guard data.prefix(1024).range(of: Data("%PDF".utf8)) != nil else { return nil }
        return PDFDocument(data: data)
    }
}

struct FittedImage: View {
    var data: Data

    var body: some View {
        let images = ImageDiffView.images(from: data)
        if images.isEmpty {
            ContentUnavailableView("Binary File", systemImage: "doc")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if images.count == 1, let image = images.first {
            fittedPreview(image, fills: true)
                .padding(16)
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        VStack(spacing: 4) {
                            Text(String(localized: "Page \(index + 1)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            fittedPreview(image, fills: false)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func fittedPreview(_ image: NSImage, fills: Bool) -> some View {
        let pixels = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width.rounded())
        let height = image.representations.map(\.pixelsHigh).max() ?? Int(image.size.height.rounded())
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .background(Checkerboard())
            .overlay {
                Rectangle().strokeBorder(Color.primary.opacity(0.15))
            }
            .frame(maxWidth: CGFloat(max(pixels, 1)), maxHeight: CGFloat(max(height, 1)))
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : cell
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color(white: 0.82)))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }
}

private enum ImageDiffMode: String, CaseIterable, Identifiable {
    case sideBySide
    case swipe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: String(localized: "Side by Side")
        case .swipe: String(localized: "Swipe")
        }
    }
}
