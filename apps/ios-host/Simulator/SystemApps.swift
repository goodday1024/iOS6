import UIKit
@MainActor final class NotesController:UIViewController,UITextViewDelegate {
    private let text = UITextView()
    override func viewDidLoad() {
        super.viewDidLoad();title = "备忘录"
        let paper = UIGraphicsImageRenderer(size:CGSize(width:2,height:28)).image { context in
            UIColor(red:1,green:0.98,blue:0.82,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:2,height:28))
            UIColor(red:0.65,green:0.75,blue:0.72,alpha:0.55).setFill();context.fill(CGRect(x:0,y:27,width:2,height:1))
        }
        view.backgroundColor = UIColor(patternImage:paper)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"主屏幕",style:.plain,target:self,action:#selector(home))
        text.backgroundColor = .clear;text.font = .systemFont(ofSize:20);text.text = UserDefaults.standard.string(forKey:"system.note");text.delegate = self;text.translatesAutoresizingMaskIntoConstraints = false;text.textContainerInset = UIEdgeInsets(top:18,left:23,bottom:20,right:16);view.addSubview(text)
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo:view.leadingAnchor),text.trailingAnchor.constraint(equalTo:view.trailingAnchor),text.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),text.bottomAnchor.constraint(equalTo:view.keyboardLayoutGuide.topAnchor)])
    }
    func textViewDidChange(_ textView:UITextView) { UserDefaults.standard.set(textView.text,forKey:"system.note") }
    @objc private func home() { text.resignFirstResponder();dismiss(animated:true) }
}
@MainActor final class CalculatorController:UIViewController {
    private let display = UILabel();private var value = "0",lhs:Double?,op:String?,fresh = true
    override func viewDidLoad() {
        super.viewDidLoad();title = "计算器";view.backgroundColor = .darkGray;navigationItem.leftBarButtonItem = UIBarButtonItem(title:"主屏幕",style:.plain,target:self,action:#selector(home))
        let stack = UIStackView();stack.axis = .vertical;stack.spacing = 12;stack.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(stack)
        display.text = value;display.font = .monospacedDigitSystemFont(ofSize:42,weight:.medium);display.textAlignment = .right;display.backgroundColor = UIColor(red:0.75,green:0.81,blue:0.7,alpha:1);display.textColor = .black;display.heightAnchor.constraint(equalToConstant:85).isActive = true;stack.addArrangedSubview(display)
        for keys in [["C","±","%","÷"],["7","8","9","×"],["4","5","6","−"],["1","2","3","+"],["0",".","=","⌫"]] { let row = UIStackView();row.spacing = 10;row.distribution = .fillEqually
            for key in keys { let button = RetroTheme.button(key){[weak self] in self?.press(key)};button.titleLabel?.font = .systemFont(ofSize:28);button.heightAnchor.constraint(equalToConstant:62).isActive = true;row.addArrangedSubview(button) };stack.addArrangedSubview(row) }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:18),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-18),stack.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:18)])
    }
    private func press(_ key:String) {
        if ["÷","×","−","+"].contains(key) { lhs = Double(value);op = key;fresh = true }
        else if key == "=" { if let l = lhs,let op,let n = Double(value) { let result = op == "+" ? l+n : op == "−" ? l-n : op == "×" ? l*n : l/n;value = result.isFinite ? String(format:"%.10g",result) : "错误";self.lhs = nil;self.op = nil;fresh = true } }
        else if key == "C" { value = "0";lhs = nil;op = nil;fresh = true }
        else if key == "±" { value = String(format:"%.10g",-(Double(value) ?? 0)) }
        else if key == "%" { value = String(format:"%.10g",(Double(value) ?? 0)/100) }
        else if key == "⌫" { value = String(value.dropLast());if value.isEmpty { value = "0" } }
        else { if fresh { value = key == "." ? "0." : key;fresh = false } else if value.count < 14 && (key != "." || !value.contains(".")) { value = (value == "0" && key != "." ? "" : value)+key } }
        display.text = value
    }
    @objc private func home() { dismiss(animated:true) }
}
@MainActor final class SettingsController:UITableViewController {
    private let labels = ["服务器地址","可信 Ed25519 公钥","登录 / 注册","退出账号","本地应用与权限","关于 Retro6"]
    init() { super.init(style:.grouped) }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() { super.viewDidLoad();title = "设置";navigationItem.leftBarButtonItem = UIBarButtonItem(title:"主屏幕",style:.plain,target:self,action:#selector(home));tableView.backgroundColor = UIColor(red:0.86,green:0.88,blue:0.90,alpha:1);tableView.register(UITableViewCell.self,forCellReuseIdentifier:"setting") }
    @objc private func home() { dismiss(animated:true) }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { labels.count }
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath) -> UITableViewCell { let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil);c.textLabel?.text = labels[indexPath.row];c.accessoryType = .disclosureIndicator
        if indexPath.row == 0 { c.detailTextLabel?.text = API.shared.baseURL.absoluteString }
        if indexPath.row == 1 { c.detailTextLabel?.text = UserDefaults.standard.string(forKey:"trustedKey") == nil ? "未配置，无法安装应用" : "已固定公钥" }
        if indexPath.row == 2 { c.detailTextLabel?.text = API.shared.token == nil ? "未登录" : "已登录" };return c }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        switch indexPath.row {
        case 0:
            let p = sheet("服务器地址","生产环境必须使用 HTTPS。iOS Simulator 可用 http://localhost:8000；真机连接可信 HTTPS 服务。");p.addTextField{$0.text = API.shared.baseURL.absoluteString;$0.autocapitalizationType = .none;$0.keyboardType = .URL};p.addAction(UIAlertAction(title:"保存",style:.default){_ in let text = p.textFields?.first?.text ?? "";guard let u = URL(string:text),let host = u.host,u.user == nil,u.password == nil,u.query == nil,u.fragment == nil,(u.path == "" || u.path == "/"),(u.scheme == "https" || (u.scheme == "http" && ["localhost","127.0.0.1"].contains(host))) else { self.showError(SimError.message("请使用无路径的 HTTPS 地址，本地开发仅允许 localhost"));return };if text != API.shared.baseURL.absoluteString { API.shared.token = nil;UserDefaults.standard.removeObject(forKey:"trustedKey") };UserDefaults.standard.set(text,forKey:"apiURL");self.tableView.reloadData()});p.addAction(UIAlertAction(title:"取消",style:.cancel));present(p,animated:true)
        case 1:
            let p = sheet("固定签名公钥","部署管理员通过可信渠道提供 /v1/keys 中的 publicKey。请粘贴并核对；不要从不可信 HTTP 服务自动接受。");p.addTextField{$0.text = UserDefaults.standard.string(forKey:"trustedKey");$0.autocapitalizationType = .none;$0.autocorrectionType = .no};p.addAction(UIAlertAction(title:"信任",style:.default){_ in let text = p.textFields?.first?.text ?? "";guard Data(base64Encoded:text)?.count == 32 else { self.showError(SimError.message("公钥必须是 32 字节 Base64"));return };UserDefaults.standard.set(text,forKey:"trustedKey");self.tableView.reloadData()});p.addAction(UIAlertAction(title:"取消",style:.cancel));present(p,animated:true)
        case 2:
            let p = sheet("账号","注册密码至少 10 个字符。");p.addTextField{$0.placeholder = "邮箱";$0.keyboardType = .emailAddress;$0.autocapitalizationType = .none};p.addTextField{$0.placeholder = "密码";$0.isSecureTextEntry = true};p.addTextField{$0.placeholder = "管理员动态口令（可选）";$0.keyboardType = .numberPad}
            for mode in ["login","register"] { p.addAction(UIAlertAction(title:mode == "login" ? "登录" : "注册",style:.default){_ in Task { do { let result = try await API.shared.request("/v1/auth/\(mode)",method:"POST",body:["email":p.textFields?[0].text ?? "","password":p.textFields?[1].text ?? "","otp":p.textFields?[2].text ?? ""]) as? [String:Any];API.shared.token = result?["token"] as? String;self.tableView.reloadData() } catch { self.showError(error) } } }) };p.addAction(UIAlertAction(title:"取消",style:.cancel));present(p,animated:true)
        case 3:Task { _ = try? await API.shared.request("/v1/auth/logout",method:"POST");API.shared.token = nil;tableView.reloadData() }
        case 4:
            let apps = AppManager.shared.apps;let p = sheet("本地应用","\(apps.count) 个应用。更新保留数据，卸载删除数据。长按桌面图标可以编辑与卸载。");for app in apps { p.addAction(UIAlertAction(title:"\(app.manifest.name) · \(app.manifest.permissions.joined(separator:","))",style:.default){_ in let detail = self.sheet(app.manifest.name,"版本 \(app.version) · \(app.channel)\n包 ID \(app.manifest.id)\n私有存储：\(AppManager.shared.storage(app.id).count) 项");detail.addAction(UIAlertAction(title:"卸载，保留数据",style:.destructive){_ in do { try AppManager.shared.uninstall(app,keepData:true) } catch { self.showError(error) } });detail.addAction(UIAlertAction(title:"关闭",style:.cancel));self.present(detail,animated:true)}) };p.addAction(UIAlertAction(title:"关闭",style:.cancel));present(p,animated:true)
        default:showError(SimError.message("Retro6 1.0.0\n独立复古应用生态，非 Apple 官方服务。只运行受限 Web 应用，不运行 IPA。\n界面参考 iOS 6，壁纸与系统图标来源见仓库素材说明。"))
        }
    }
}
