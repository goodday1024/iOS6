import UIKit
import WebKit
final class ResourceHandler: NSObject, WKURLSchemeHandler {
    let appId: String; let root: URL
    init(appId: String, root: URL) { self.appId = appId;self.root = root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.scheme == "simapp", url.host?.lowercased() == appId.lowercased() else { throw SimError.message("非法资源来源") }
            let path = String(url.path.dropFirst())
            guard safeRelativePath(path) else { throw SimError.message("非法资源路径") }
            let file = root.appendingPathComponent(path).standardizedFileURL
            guard file.path.hasPrefix(root.path+"/") else { throw SimError.message("资源路径逃逸") }
            let ext = file.pathExtension.lowercased()
            let mime = ["html":"text/html","js":"application/javascript","css":"text/css","json":"application/json","png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg","webp":"image/webp","gif":"image/gif","woff":"font/woff","woff2":"font/woff2","mp3":"audio/mpeg","wav":"audio/wav"][ext] ?? "application/octet-stream"
            var data = try Data(contentsOf:file)
            if ext == "html" {
                // The first CSP is inserted before any package markup. Native navigation policy blocks external pages.
                let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src simapp: 'unsafe-inline'; style-src simapp: 'unsafe-inline'; img-src simapp: data:; font-src simapp:; media-src simapp:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'\">"
                data = Data(csp.utf8)+data
            }
            let response = URLResponse(url:url,mimeType:mime,expectedContentLength:data.count,textEncodingName:["html","css","js","json"].contains(ext) ? "utf-8" : nil)
            task.didReceive(response);task.didReceive(data);task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
@MainActor final class WebRuntime: UIViewController, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    let app: InstalledApp
    private(set) var web: WKWebView!
    private var calls: [Date] = []
    var onTerminate: (() -> Void)?
    init(app: InstalledApp) { self.app = app;super.init(nibName:nil,bundle:nil);title = app.manifest.name }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .white
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"主屏幕",style:.plain,target:self,action:#selector(home))
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title:"退出",style:.plain,target:self,action:#selector(terminate)),UIBarButtonItem(title:"反馈",style:.plain,target:self,action:#selector(feedback))]
        let config = WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(ResourceHandler(appId:app.id,root:AppManager.shared.bundle(app)),forURLScheme:"simapp")
        config.userContentController.addScriptMessageHandler(self,contentWorld:.page,name:"simulator")
        if let url = Bundle.main.url(forResource:"sdk",withExtension:"js"), let text = try? String(contentsOf:url,encoding:.utf8) { config.userContentController.addUserScript(WKUserScript(source:text,injectionTime:.atDocumentStart,forMainFrameOnly:true)) }
        web = WKWebView(frame:.zero,configuration:config);web.navigationDelegate = self
        web.scrollView.pinchGestureRecognizer?.isEnabled = false;web.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(web)
        NSLayoutConstraint.activate([web.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),web.leadingAnchor.constraint(equalTo:view.leadingAnchor),web.trailingAnchor.constraint(equalTo:view.trailingAnchor),web.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor)])
        web.load(URLRequest(url:URL(string:"simapp://\(app.id)/\(app.manifest.entry)")!))
    }
    override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated);event("resume") }
    override func viewWillDisappear(_ animated:Bool) { super.viewWillDisappear(animated);event("pause") }
    func event(_ name:String) { web?.evaluateJavaScript("window.dispatchEvent(new Event('simulator:\(name)'))",completionHandler:nil) }
    @objc private func feedback() {
        let p = sheet("提交反馈","点击发送后，将上传应用截图、文字反馈及设备/系统版本。")
        p.addTextField { $0.placeholder = "问题描述" }
        p.addAction(UIAlertAction(title:"发送文字",style:.default){_ in self.sendFeedback(p.textFields?.first?.text ?? "",includeScreenshot:false)})
        p.addAction(UIAlertAction(title:"发送截图与文字",style:.default){_ in self.sendFeedback(p.textFields?.first?.text ?? "",includeScreenshot:true)})
        p.addAction(UIAlertAction(title:"取消",style:.cancel));present(p,animated:true)
    }
    private func sendFeedback(_ content:String,includeScreenshot:Bool) {
        let image = includeScreenshot ? UIGraphicsImageRenderer(bounds:web.bounds).image { _ in web.drawHierarchy(in:web.bounds,afterScreenUpdates:true) }.pngData() : nil
        Task { do {
            let result = try await API.shared.request("/v1/beta/feedback",method:"POST",body:["build_id":app.buildId,"content":content,"device":["model":UIDevice.current.model,"system":UIDevice.current.systemVersion,"simulator":"1.0.0"]]) as? [String:Any]
            if let image,let id = result?["id"] as? String { try await API.shared.uploadScreenshot(feedbackId:id,png:image) }
            showError(SimError.message("反馈已提交"))
        } catch { showError(error) } }
    }
    @objc func home() { dismiss(animated:true) }
    @objc func terminate() { event("terminate");web?.stopLoading();web?.configuration.userContentController.removeScriptMessageHandler(forName:"simulator",contentWorld:.page);onTerminate?();dismiss(animated:true) }
    func dispose() { if isViewLoaded { event("terminate");web.stopLoading();web.configuration.userContentController.removeScriptMessageHandler(forName:"simulator",contentWorld:.page) } }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        guard action.targetFrame?.isMainFrame == true, let url = action.request.url, url.scheme == "simapp", url.host?.lowercased() == app.id.lowercased() else { decisionHandler(.cancel);return }
        decisionHandler(.allow)
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { event("launch") }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) { webView.reload() }
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage,replyHandler:@escaping(Any?,String?)->Void) {
        let id = (message.body as? [String:Any])?["requestId"] as? String ?? ""
        func respond(_ value:Any? = nil, error:String? = nil) {
            var r:[String:Any] = ["requestId":id,"ok":error == nil,"result":value ?? NSNull()]
            if let error { r["error"] = ["code":"BRIDGE_DENIED","message":error] };replyHandler(r,nil)
        }
        do {
            guard message.webView === web, message.frameInfo.isMainFrame, message.frameInfo.request.url?.host?.lowercased() == app.id.lowercased(), message.frameInfo.request.url?.scheme == "simapp", let body = message.body as? [String:Any], (body["protocolVersion"] as? Int) == 1, !id.isEmpty, let method = body["method"] as? String, let params = body["params"] as? [String:Any], try JSONSerialization.data(withJSONObject:body).count <= 65536 else { throw SimError.message("非法桥接消息") }
            calls.removeAll { Date().timeIntervalSince($0) > 60 };guard calls.count < 120 else { throw SimError.message("桥接频率超限") };calls.append(Date())
            if method.hasPrefix("storage.") {
                guard app.manifest.permissions.contains("storage"), let key = params["key"] as? String, !key.isEmpty, key.utf8.count <= 128 else { throw SimError.message("存储权限或键无效") }
                var values = AppManager.shared.storage(app.id)
                switch method {
                case "storage.get":respond(values[key]);return
                case "storage.set":guard let value = params["value"] as? String, value.utf8.count <= 32768 else { throw SimError.message("值超过 32 KiB") };values[key] = value
                case "storage.remove":values.removeValue(forKey:key)
                default:throw SimError.message("不支持的方法")
                }
                try AppManager.shared.writeStorage(values,for:app.id);respond();return
            }
            switch method {
            case "app.getInfo":respond(["id":app.manifest.id,"version":app.version])
            case "app.close":respond();terminate()
            case "ui.setTitle":guard let value = params["title"] as? String, value.count <= 80 else { throw SimError.message("标题无效") };title = value;respond()
            case "ui.alert":guard let value = params["message"] as? String, value.count <= 1000, presentedViewController == nil else { throw SimError.message("弹窗参数无效或已有弹窗") };let alert = UIAlertController(title:app.manifest.name,message:value,preferredStyle:.alert);alert.addAction(UIAlertAction(title:"好",style:.default){ _ in respond() });present(alert,animated:true)
            default:throw SimError.message("不支持的方法")
            }
        } catch { respond(error:error.localizedDescription) }
    }
}
