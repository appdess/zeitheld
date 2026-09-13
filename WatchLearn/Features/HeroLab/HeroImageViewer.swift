import SwiftUI
import UIKit

struct HeroImagePresentation: Identifiable {
    let id = UUID()
    let data: Data
    let title: String
}

/// A local viewer: opening, zooming and sharing never starts a cloud request.
struct HeroImageViewer: View {
    let picture: HeroImagePresentation
    let language: LearningLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var showingShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let image = UIImage(data: picture.data) {
                    ZoomableHeroImage(image: image)
                        .accessibilityLabel(picture.title)
                        .accessibilityIdentifier("hero-large-image")
                    Text(language == .german ? "Mit zwei Fingern vergrößern." : "Pinch with two fingers to zoom.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(10)
                    Button {
                        showingShare = true
                    } label: {
                        Label(language == .german ? "Bild speichern oder teilen" : "Save or share picture", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.bottom)
                    .accessibilityIdentifier("hero-large-share")
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(picture.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(language == .german ? "Fertig" : "Done") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("hero-large-close")
                }
            }
        }
        .sheet(isPresented: $showingShare) {
            HeroImageShareSheet(data: picture.data)
                .presentationDetents([.medium, .large])
        }
    }
}

struct HeroImageShareSheet: UIViewControllerRepresentable {
    let data: Data

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let image = UIImage(data: data)
        return UIActivityViewController(activityItems: image.map { [$0] } ?? [], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ZoomableHeroImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> HeroZoomScrollView {
        HeroZoomScrollView(image: image)
    }

    func updateUIView(_ view: HeroZoomScrollView, context: Context) {
        if view.imageView.image !== image {
            view.imageView.image = image
            view.setZoomScale(1, animated: false)
            view.setNeedsLayout()
        }
    }
}

private final class HeroZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView: UIImageView
    private var fittedSize = CGSize.zero

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if fittedSize != bounds.size {
            fittedSize = bounds.size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}
