import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private enum Layout {
        static let contentSpacing: CGFloat = 20
        static let buttonSpacing: CGFloat = 12
        static let horizontalPadding: CGFloat = 24
        static let verticalPadding: CGFloat = 28
        static let buttonHeight: CGFloat = 50
    }

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private lazy var cancelButton = makeButton(title: "Cancel", primary: false, action: #selector(cancel))
    private lazy var addButton = makeButton(title: "Add to Tinfoil", primary: true, action: #selector(addToTinfoil))

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        updateSharedItemDetails()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        titleLabel.text = "Share with Tinfoil"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 3

        activityIndicator.hidesWhenStopped = true

        let buttonStack = UIStackView(arrangedSubviews: [cancelButton, addButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = Layout.buttonSpacing
        buttonStack.distribution = .fillEqually

        let contentStack = UIStackView(arrangedSubviews: [
            titleLabel,
            detailLabel,
            activityIndicator,
            buttonStack,
        ])
        contentStack.axis = .vertical
        contentStack.spacing = Layout.contentSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: Layout.horizontalPadding
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -Layout.horizontalPadding
            ),
            contentStack.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Layout.verticalPadding
            ),
            contentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -Layout.verticalPadding
            ),
            cancelButton.heightAnchor.constraint(equalToConstant: Layout.buttonHeight),
            addButton.heightAnchor.constraint(equalToConstant: Layout.buttonHeight),
        ])
    }

    private func updateSharedItemDetails() {
        guard let provider = sharedItemProvider(),
              let typeIdentifier = supportedTypeIdentifier(for: provider),
              let kind = SharedImportClassifier.kind(
                typeIdentifier: typeIdentifier,
                fileName: provider.suggestedName
              ) else {
            detailLabel.text = SharedImportError.unsupportedType.localizedDescription
            addButton.isEnabled = false
            return
        }

        let itemName = provider.suggestedName ?? (kind == .image ? "Image" : "Document")
        detailLabel.text = "\(itemName)\nIt will be attached when you open Tinfoil."
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        )
    }

    @objc private func addToTinfoil() {
        guard let provider = sharedItemProvider(),
              let typeIdentifier = supportedTypeIdentifier(for: provider) else {
            showError(SharedImportError.unsupportedType)
            return
        }

        setSaving(true)
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            guard let self else { return }

            if let url {
                saveSharedItem(
                    from: url,
                    provider: provider,
                    typeIdentifier: typeIdentifier
                )
            } else {
                loadDataFallback(
                    provider: provider,
                    typeIdentifier: typeIdentifier,
                    underlyingError: error
                )
            }
        }
    }

    private func loadDataFallback(
        provider: NSItemProvider,
        typeIdentifier: String,
        underlyingError: Error?
    ) {
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, error in
            guard let self else { return }
            guard let data else {
                showError(error ?? underlyingError ?? SharedImportError.invalidFile)
                return
            }

            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString.lowercased())
            do {
                try data.write(to: temporaryURL, options: .atomic)
                saveSharedItem(
                    from: temporaryURL,
                    provider: provider,
                    typeIdentifier: typeIdentifier
                )
                try? FileManager.default.removeItem(at: temporaryURL)
            } catch {
                showError(error)
            }
        }
    }

    private func saveSharedItem(
        from sourceURL: URL,
        provider: NSItemProvider,
        typeIdentifier: String
    ) {
        do {
            let store = try SharedImportStore()
            _ = try store.enqueue(
                sourceURL: sourceURL,
                typeIdentifier: typeIdentifier,
                originalFileName: sharedFileName(
                    provider: provider,
                    typeIdentifier: typeIdentifier
                )
            )
            DispatchQueue.main.async { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        } catch {
            showError(error)
        }
    }

    private func sharedItemProvider() -> NSItemProvider? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        guard providers.count == 1 else {
            return nil
        }
        return providers[0]
    }

    private func supportedTypeIdentifier(for provider: NSItemProvider) -> String? {
        if let imageType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            return imageType
        }

        return provider.registeredTypeIdentifiers.first {
            SharedImportClassifier.kind(
                typeIdentifier: $0,
                fileName: provider.suggestedName
            ) == .document
        }
    }

    private func sharedFileName(
        provider: NSItemProvider,
        typeIdentifier: String
    ) -> String {
        if let suggestedName = provider.suggestedName, !suggestedName.isEmpty {
            return suggestedName
        }

        let kind = SharedImportClassifier.kind(typeIdentifier: typeIdentifier, fileName: nil)
        let baseName = kind == .image ? "Shared Image" : "Shared Document"
        guard let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension else {
            return baseName
        }
        return "\(baseName).\(fileExtension)"
    }

    private func setSaving(_ isSaving: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.addButton.isEnabled = !isSaving
            self?.cancelButton.isEnabled = !isSaving
            if isSaving {
                self?.activityIndicator.startAnimating()
            } else {
                self?.activityIndicator.stopAnimating()
            }
        }
    }

    private func showError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            setSaving(false)
            let alert = UIAlertController(
                title: "Unable to Add Attachment",
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private func makeButton(
        title: String,
        primary: Bool,
        action: Selector
    ) -> UIButton {
        var configuration = primary
            ? UIButton.Configuration.filled()
            : UIButton.Configuration.gray()
        configuration.title = title
        configuration.cornerStyle = .large

        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
}
