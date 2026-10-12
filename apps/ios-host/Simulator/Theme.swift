import UIKit
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    init(_ colors:[UIColor]) { super.init(frame:.zero);(layer as! CAGradientLayer).colors = colors.map(\.cgColor) }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
}
@MainActor enum RetroTheme {
    static let blue = UIColor(red:0.25,green:0.38,blue:0.51,alpha:1)
    static func navigation(_ controller:UINavigationController) {
        let appearance = UINavigationBarAppearance();appearance.configureWithOpaqueBackground();appearance.backgroundColor = blue
        appearance.titleTextAttributes = [.foregroundColor:UIColor.white,.font:UIFont.boldSystemFont(ofSize:18)]
        controller.navigationBar.standardAppearance = appearance;controller.navigationBar.scrollEdgeAppearance = appearance;controller.navigationBar.tintColor = .white
    }
    static func button(_ text:String, action:@escaping()->Void) -> UIButton {
        let b = UIButton(type:.system);b.setTitle(text,for:.normal);b.setTitleColor(.white,for:.normal);b.backgroundColor = blue;b.layer.cornerRadius = 8;b.contentEdgeInsets = UIEdgeInsets(top:12,left:18,bottom:12,right:18);b.addAction(UIAction{_ in action()},for:.touchUpInside);return b
    }
}
extension UIViewController {
    func showError(_ error:Error) { let alert = UIAlertController(title:"提示",message:error.localizedDescription,preferredStyle:.alert);alert.addAction(UIAlertAction(title:"好",style:.default));present(alert,animated:true) }
    func sheet(_ title:String,_ message:String? = nil) -> UIAlertController { UIAlertController(title:title,message:message,preferredStyle:.alert) }
    func presentRetro(_ controller:UIViewController) { let nav = UINavigationController(rootViewController:controller);RetroTheme.navigation(nav);nav.modalPresentationStyle = .fullScreen;present(nav,animated:true) }
}
