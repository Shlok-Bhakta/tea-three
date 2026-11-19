import PhotosUI
import SwiftUI
import TeaThreeKit
import UIKit

/// A photo waiting to go out with the next message.
struct PendingPhoto: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    let attachment: OutgoingAttachment

    /// Downscales to 2048 px on the long side and JPEG-encodes, which keeps
    /// phone photos well under T3's 10 MB image limit.
    init?(_ image: UIImage) {
        let longSide = max(image.size.width, image.size.height)
        let scale = min(1, 2048 / max(longSide, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.8) else { return nil }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        thumbnail = resized.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? resized
        attachment = OutgoingAttachment(data: data, name: "photo-\(stamp).jpg", mimeType: "image/jpeg")
    }
}

/// The photo button: take one with the camera or pick from the library.
struct PhotoButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") { showCamera = true }
            }
            Button("Choose from Library", systemImage: "photo.on.rectangle") { showLibrary = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .frame(width: 36, height: 36)
                .background(theme.foreground.opacity(0.07), in: Circle())
        }
        .accessibilityLabel("Attach a photo")
        .photosPicker(isPresented: $showLibrary, selection: $picked, maxSelectionCount: 4, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        model.addPhoto(image)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in model.addPhoto(image) }
                .ignoresSafeArea()
        }
    }
}

/// Thumbnails of the photos that will go with the next message.
struct PendingPhotosStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.pendingPhotos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.pendingPhotos) { photo in
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    model.removePhoto(photo.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 6, y: -6)
                                .accessibilityLabel("Remove photo")
                            }
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
            }
        }
    }
}

/// UIKit's camera, since SwiftUI has no camera view.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPick(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
