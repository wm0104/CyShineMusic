import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    handleURLs(connectionOptions.urlContexts)
  }

  override func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
    handleURLs(urlContexts)
    super.scene(scene, openURLContexts: urlContexts)
  }

  private func handleURLs(_ urlContexts: Set<UIOpenURLContext>) {
    for context in urlContexts {
      let url = context.url
      if url.isFileURL {
        CyShineIncomingAudio.shared.accept(url: url)
      } else if url.scheme?.lowercased() == cyShineURLScheme {
        _ = CyShineIncomingAudio.handleAppURL(url)
      }
    }
  }
}
