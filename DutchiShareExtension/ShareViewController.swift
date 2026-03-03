import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let appGroupID = "group.com.taehoonkang.dutchi"
    private var extractedImages: [UIImage] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        showLoadingUI()

        extractImages { [weak self] images in
            guard let self = self else { return }
            guard !images.isEmpty else {
                DispatchQueue.main.async {
                    self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
                return
            }
            self.extractedImages = images

            DispatchQueue.global(qos: .userInitiated).async {
                self.saveImagesToAppGroup(images)
                DispatchQueue.main.async {
                    self.showChoiceUI()
                }
            }
        }
    }

    // MARK: - Loading UI

    private func showLoadingUI() {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - Choice UI

    private func showChoiceUI() {
        view.subviews.forEach { $0.removeFromSuperview() }

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 16
        container.alignment = .fill
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layoutMargins = UIEdgeInsets(top: 32, left: 24, bottom: 32, right: 24)
        container.isLayoutMarginsRelativeArrangement = true
        scroll.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: scroll.topAnchor),
            container.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            container.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])

        // Image previews
        let imageRow = UIStackView()
        imageRow.axis = .horizontal
        imageRow.spacing = 10
        imageRow.distribution = .fillEqually
        imageRow.heightAnchor.constraint(equalToConstant: extractedImages.count == 1 ? 220 : 160).isActive = true

        for image in extractedImages.prefix(4) {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            imageView.layer.borderWidth = 1
            imageView.layer.borderColor = UIColor.separator.cgColor
            imageRow.addArrangedSubview(imageView)
        }
        container.addArrangedSubview(imageRow)

        // Title
        let plural = extractedImages.count == 1 ? "receipt" : "receipts"
        let title = makeLabel(
            "\(extractedImages.count) \(plural) ready for Dutchi",
            font: .systemFont(ofSize: 20, weight: .bold),
            color: .label,
            alignment: .center
        )
        container.addArrangedSubview(title)

        // Subtitle
        let subtitle = makeLabel(
            "Open Dutchi whenever you're ready to process.",
            font: .systemFont(ofSize: 15),
            color: .secondaryLabel,
            alignment: .center
        )
        container.addArrangedSubview(subtitle)
        container.setCustomSpacing(24, after: subtitle)

        // Save for Later button
        let saveButton = makeButton(
            title: "Save for Later",
            background: .systemBlue,
            titleColor: .white,
            action: #selector(saveLaterTapped)
        )
        container.addArrangedSubview(saveButton)

        // Cancel
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.setTitleColor(.secondaryLabel, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 15)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        container.addArrangedSubview(cancel)
    }

    // MARK: - Actions

    @objc private func saveLaterTapped() {
        showSavedConfirmation(message: "Saved! Open Dutchi whenever you are ready.")
    }

    @objc private func cancelTapped() {
        if let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            try? FileManager.default.removeItem(at: containerURL.appendingPathComponent("SharedReceipts"))
            try? FileManager.default.removeItem(at: containerURL.appendingPathComponent("pending_receipts.json"))
        }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - Confirmation Screen

    private func showSavedConfirmation(message: String) {
        DispatchQueue.main.async {
            self.view.subviews.forEach { $0.removeFromSuperview() }

            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 12
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false

            // Checkmark icon
            let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            checkmark.tintColor = .systemGreen
            checkmark.contentMode = .scaleAspectFit
            checkmark.translatesAutoresizingMaskIntoConstraints = false
            checkmark.widthAnchor.constraint(equalToConstant: 52).isActive = true
            checkmark.heightAnchor.constraint(equalToConstant: 52).isActive = true

            let msg = self.makeLabel(
                message,
                font: .systemFont(ofSize: 16, weight: .medium),
                color: .secondaryLabel,
                alignment: .center
            )
            msg.numberOfLines = 0

            stack.addArrangedSubview(checkmark)
            stack.addArrangedSubview(msg)
            self.view.addSubview(stack)

            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: self.view.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 32),
                stack.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -32)
            ])

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, font: UIFont, color: UIColor, alignment: NSTextAlignment) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.textAlignment = alignment
        label.numberOfLines = 0
        return label
    }

    private func makeButton(title: String, background: UIColor, titleColor: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(titleColor, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.backgroundColor = background
        button.layer.cornerRadius = 14
        button.heightAnchor.constraint(equalToConstant: 56).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: - Image Extraction

    private func extractImages(completion: @escaping ([UIImage]) -> Void) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            completion([])
            return
        }
        let allProviders = items.flatMap { $0.attachments ?? [] }
        var images: [UIImage] = []
        let group = DispatchGroup()

        for provider in allProviders {
            let typeIDs = ["public.jpeg", "public.png", "public.image", "public.heic", "public.heif"]
            guard let typeID = typeIDs.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
                defer { group.leave() }
                if let image = item as? UIImage {
                    images.append(image)
                } else if let url = item as? URL, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    images.append(image)
                } else if let data = item as? Data, let image = UIImage(data: data) {
                    images.append(image)
                }
            }
        }

        group.notify(queue: .main) {
            print("Extracted \(images.count) images")
            completion(images)
        }
    }

    // MARK: - Save to App Group

    private func saveImagesToAppGroup(_ images: [UIImage]) {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }

        let folder = containerURL.appendingPathComponent("SharedReceipts")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var savedPaths: [String] = []
        for (index, image) in images.enumerated() {
            if let data = image.jpegData(compressionQuality: 0.8) {
                let filename = "receipt_\(index).jpg"
                try? data.write(to: folder.appendingPathComponent(filename))
                savedPaths.append(filename)
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: savedPaths) {
            try? data.write(to: containerURL.appendingPathComponent("pending_receipts.json"))
            print("Saved \(savedPaths.count) image(s)")
        }
    }
}
