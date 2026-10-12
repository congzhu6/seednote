import UIKit

enum SeednoteShortcutFile: String, Identifiable {
    case screenshot
    case share

    var id: String { rawValue }

    var resourceName: String {
        switch self {
        case .screenshot: "Seednote-Screenshot-Capture"
        case .share: "Seednote-Share-Capture"
        }
    }

    func bundledURL(in bundle: Bundle = .main) throws -> URL {
        if let url = bundle.url(forResource: resourceName, withExtension: "shortcut") {
            return url
        }
        if let url = bundle.url(forResource: resourceName, withExtension: "shortcut", subdirectory: "Shortcuts") {
            return url
        }
        throw CaptureError.message(L(
            "The bundled shortcut file could not be found. You can still follow the manual setup steps below.",
            "找不到 App 内置的快捷指令文件。你仍可以按下方步骤手动配置。"
        ))
    }
}

/// Hands a bundled local document to an installed app that declares support
/// for the `.shortcut` file type. This is only a handoff; it cannot confirm
/// that the shortcut was added or that a physical trigger works reliably.
@MainActor final class ShortcutDocumentPresenter: NSObject, UIDocumentInteractionControllerDelegate {
    static let shared = ShortcutDocumentPresenter()
    private var interactionController: UIDocumentInteractionController?

    func presentOpenInMenu(for shortcut: SeednoteShortcutFile) throws -> Bool {
        let controller = UIDocumentInteractionController(url: try shortcut.bundledURL())
        controller.delegate = self
        interactionController = controller

        guard let presenter = Self.topViewController() else {
            throw CaptureError.message(L(
                "Seednote could not present the shortcut file. Use Save or share file instead.",
                "Seednote 无法显示快捷指令文件。请改用“存到文件或分享”。"
            ))
        }
        presenter.loadViewIfNeeded()
        return controller.presentOpenInMenu(
            from: CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 1, width: 1, height: 1),
            in: presenter.view,
            animated: true
        )
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let root = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController else { return nil }
        return topViewController(from: root)
    }

    private static func topViewController(from controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController {
            return topViewController(from: visible)
        }
        if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
            return topViewController(from: selected)
        }
        return controller
    }

    func documentInteractionControllerViewControllerForPreview(
        _ controller: UIDocumentInteractionController
    ) -> UIViewController {
        Self.topViewController() ?? UIViewController()
    }
}
