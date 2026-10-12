import UIKit
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    init(_ colors:[UIColor]) { super.init(frame:.zero);(layer as! CAGradientLayer).colors = colors.map(\.cgColor) }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
}
@MainActor enum RetroTheme {
    static let blue = UIColor(red:0.25,green:0.38,blue:0.51,alpha:1)
    static func artwork(_ name:String) -> UIImage? {
        if let image = UIImage(named:name) { return image }
        guard let path = Bundle.main.path(forResource:name,ofType:"jpg") else { return nil }
        return UIImage(contentsOfFile:path)
    }
    static func gradient(_ top:UIColor,_ bottom:UIColor,height:CGFloat = 44) -> UIImage {
        UIGraphicsImageRenderer(size:CGSize(width:2,height:height)).image { context in
            let colors = [top.cgColor,bottom.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,1])!
            context.cgContext.drawLinearGradient(gradient,start:CGPoint(x:0,y:0),end:CGPoint(x:0,y:height),options:[])
        }.resizableImage(withCapInsets:.zero,resizingMode:.stretch)
    }
    static func navigation(_ controller:UINavigationController) {
        let appearance = UINavigationBarAppearance();appearance.configureWithOpaqueBackground()
        appearance.backgroundImage = gradient(UIColor(red:0.64,green:0.71,blue:0.80,alpha:1),UIColor(red:0.34,green:0.44,blue:0.58,alpha:1))
        appearance.shadowColor = UIColor(red:0.15,green:0.20,blue:0.29,alpha:1)
        appearance.titleTextAttributes = [.foregroundColor:UIColor.white,.font:UIFont.boldSystemFont(ofSize:19),.shadow:shadow()]
        controller.navigationBar.standardAppearance = appearance;controller.navigationBar.scrollEdgeAppearance = appearance;controller.navigationBar.tintColor = .white
    }
    static func shadow() -> NSShadow { let s = NSShadow();s.shadowColor = UIColor.black.withAlphaComponent(0.65);s.shadowOffset = CGSize(width:0,height:-1);return s }
    static func button(_ text:String, action:@escaping()->Void) -> UIButton {
        let b = UIButton(type:.system);b.setTitle(text,for:.normal);b.setTitleColor(.white,for:.normal)
        b.setBackgroundImage(gradient(UIColor(red:0.56,green:0.67,blue:0.80,alpha:1),UIColor(red:0.22,green:0.35,blue:0.52,alpha:1)),for:.normal)
        b.layer.cornerRadius = 6;b.clipsToBounds = true;b.layer.borderWidth = 1;b.layer.borderColor = UIColor.black.withAlphaComponent(0.32).cgColor
        b.contentEdgeInsets = UIEdgeInsets(top:10,left:15,bottom:10,right:15);b.addAction(UIAction{_ in action()},for:.touchUpInside);return b
    }
}
final class RetroUnlockSlider:UIControl {
    private let thumb = UILabel()
    private let hint = UILabel()
    var onUnlock:(()->Void)?
    override init(frame:CGRect) {
        super.init(frame:frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.52);layer.cornerRadius = 10;layer.borderWidth = 1;layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        thumb.text = "›";thumb.font = .systemFont(ofSize:37,weight:.light);thumb.textColor = .white;thumb.textAlignment = .center
        thumb.backgroundColor = UIColor(white:0.64,alpha:0.75);thumb.layer.cornerRadius = 8;thumb.clipsToBounds = true
        hint.text = "滑动来解锁";hint.font = .systemFont(ofSize:19,weight:.light);hint.textColor = UIColor.white.withAlphaComponent(0.85);hint.textAlignment = .center
        addSubview(hint);addSubview(thumb);addGestureRecognizer(UIPanGestureRecognizer(target:self,action:#selector(drag(_:))))
        isAccessibilityElement = true;accessibilityLabel = "滑动来解锁";accessibilityTraits = .button
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func layoutSubviews() { super.layoutSubviews();hint.frame = bounds.insetBy(dx:55,dy:0);if thumb.frame == .zero { thumb.frame = CGRect(x:3,y:3,width:55,height:bounds.height-6) } }
    @objc private func drag(_ gesture:UIPanGestureRecognizer) {
        let travel = max(0,bounds.width-61)
        switch gesture.state {
        case .changed: thumb.frame.origin.x = min(travel+3,max(3,gesture.location(in:self).x-27))
        case .ended: if thumb.frame.minX > travel*0.72 { onUnlock?() };fallthrough
        case .cancelled,.failed: UIView.animate(withDuration:0.22){self.thumb.frame.origin.x = 3}
        default:break
        }
    }
    override func accessibilityActivate() -> Bool { onUnlock?();return true }
}
extension UIViewController {
    func showError(_ error:Error) { let alert = UIAlertController(title:"提示",message:error.localizedDescription,preferredStyle:.alert);alert.addAction(UIAlertAction(title:"好",style:.default));present(alert,animated:true) }
    func sheet(_ title:String,_ message:String? = nil) -> UIAlertController { UIAlertController(title:title,message:message,preferredStyle:.alert) }
    func presentRetro(_ controller:UIViewController) { let nav = UINavigationController(rootViewController:controller);RetroTheme.navigation(nav);nav.modalPresentationStyle = .fullScreen;present(nav,animated:true) }
}
