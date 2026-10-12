import UIKit
@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window:UIWindow?
    func application(_ application:UIApplication,didFinishLaunchingWithOptions options:[UIApplication.LaunchOptionsKey:Any]?) -> Bool {
        window = UIWindow(frame:UIScreen.main.bounds);window?.rootViewController = ShellController();window?.makeKeyAndVisible();return true
    }
}
struct DesktopLayout: Codable {
    var pages:[[String]] = [["notes","calculator","store","beta","settings"]]
    var dock:[String] = ["store","beta","notes","settings"]
    var folders:[String:[String]] = [:]
    var folderNames:[String:String] = [:]
}
@MainActor final class ShellController:UIViewController {
    private var desktop = DesktopLayout()
    private var page = 0
    private var iconEditing = false
    private var lockView:UIView?
    private var sessions:[String:WebRuntime] = [:]
    private var recent:[String] = []
    private let status = UILabel()
    private let grid = UIStackView()
    private let dock = UIStackView()
    private let pager = UILabel()
    private var clock:Timer?
    private let manager = AppManager.shared
    private let system:[String:(String,String)] = ["notes":("备忘录","ios6-notes"),"calculator":("计算器","ios6-calculator"),"store":("App Store","ios6-store"),"beta":("Beta 测试",""),"settings":("设置","ios6-settings")]
    override var prefersStatusBarHidden:Bool { true }
    override func viewDidLoad() {
        super.viewDidLoad()
        if let data = UserDefaults.standard.data(forKey:"desktop"),let layout = try? JSONDecoder().decode(DesktopLayout.self,from:data) { desktop = layout }
        let bg = UIImageView(image:UIImage(named:"ios6-wallpaper"));bg.contentMode = .scaleAspectFill;bg.clipsToBounds = true;bg.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(bg)
        NSLayoutConstraint.activate([bg.topAnchor.constraint(equalTo:view.topAnchor),bg.bottomAnchor.constraint(equalTo:view.bottomAnchor),bg.leadingAnchor.constraint(equalTo:view.leadingAnchor),bg.trailingAnchor.constraint(equalTo:view.trailingAnchor)])
        let content = UIStackView();content.axis = .vertical;content.spacing = 5;content.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(content)
        status.textColor = .white;status.font = .boldSystemFont(ofSize:11);status.textAlignment = .center;status.backgroundColor = UIColor.black.withAlphaComponent(0.35);status.heightAnchor.constraint(equalToConstant:22).isActive = true;content.addArrangedSubview(status)
        status.isUserInteractionEnabled = true;status.addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(lockFromStatus)))
        grid.axis = .vertical;grid.spacing = 8;content.addArrangedSubview(grid)
        let spacer = UIView();content.addArrangedSubview(spacer)
        pager.textAlignment = .center;pager.textColor = .white;content.addArrangedSubview(pager)
        dock.distribution = .fillEqually;dock.spacing = 6;dock.backgroundColor = UIColor.white.withAlphaComponent(0.32);dock.layer.borderColor = UIColor.white.withAlphaComponent(0.62).cgColor;dock.layer.borderWidth = 1;dock.layer.shadowColor = UIColor.black.cgColor;dock.layer.shadowOpacity = 0.35;dock.layer.shadowRadius = 12;dock.isLayoutMarginsRelativeArrangement = true;dock.layoutMargins = UIEdgeInsets(top:8,left:10,bottom:8,right:10);content.addArrangedSubview(dock)
        dock.isUserInteractionEnabled = true;let doubleTap = UITapGestureRecognizer(target:self,action:#selector(showSwitcher));doubleTap.numberOfTapsRequired = 2;dock.addGestureRecognizer(doubleTap)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),content.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor),content.leadingAnchor.constraint(equalTo:view.leadingAnchor),content.trailingAnchor.constraint(equalTo:view.trailingAnchor),spacer.heightAnchor.constraint(greaterThanOrEqualToConstant:4)])
        let left = UISwipeGestureRecognizer(target:self,action:#selector(swipe));left.direction = .left;view.addGestureRecognizer(left)
        let right = UISwipeGestureRecognizer(target:self,action:#selector(swipe));right.direction = .right;view.addGestureRecognizer(right)
        NotificationCenter.default.addObserver(self,selector:#selector(refresh),name:Notification.Name("InstalledChanged"),object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(background),name:UIApplication.didEnterBackgroundNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(memory),name:UIApplication.didReceiveMemoryWarningNotification,object:nil)
        clock = Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self]_ in Task { @MainActor in self?.tick() } };tick();refresh();lock()
    }
    @objc private func background() { sessions.values.forEach{$0.event("pause")} }
    @objc private func memory() { for (id,session) in sessions where session.presentingViewController == nil && session.navigationController?.presentingViewController == nil { session.dispose();sessions.removeValue(forKey:id) } }
    @objc private func lockFromStatus() { lock() }
    @objc private func showSwitcher() { switcher() }
    private func tick() { let f = DateFormatter();f.dateFormat = "HH:mm";status.text = "●●●  Retro6               \(f.string(from:Date()))              ▰  100%";if let label = lockView?.viewWithTag(6) as? UILabel { label.text = f.string(from:Date()) } }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(desktop),forKey:"desktop") }
    private func changePage(_ delta:Int) { page = max(0,min(desktop.pages.count-1,page+delta));refresh() }
    @objc private func swipe(_ gesture:UISwipeGestureRecognizer) { if lockView == nil { changePage(gesture.direction == .left ? 1 : -1) } }
    @objc private func refresh() {
        let ids = Set(manager.apps.map(\.id)+Array(system.keys)+Array(desktop.folders.keys))
        desktop.pages = desktop.pages.map{$0.filter{ids.contains($0)}}
        for key in desktop.folders.keys { desktop.folders[key] = desktop.folders[key]?.filter{ids.contains($0)} }
        desktop.dock = desktop.dock.filter{ids.contains($0)}
        let placed = Set(desktop.pages.flatMap{$0}+desktop.dock+desktop.folders.values.flatMap{$0})
        for a in manager.apps where !placed.contains(a.id) { if desktop.pages.last!.count >= 16 { desktop.pages.append([]) };desktop.pages[desktop.pages.count-1].append(a.id) }
        for (id,s) in sessions where !manager.apps.contains(where:{$0.id == id && $0.buildId == s.app.buildId}) { s.dispose();sessions.removeValue(forKey:id) }
        page = min(page,desktop.pages.count-1);persist()
        grid.arrangedSubviews.forEach{$0.removeFromSuperview()};dock.arrangedSubviews.forEach{$0.removeFromSuperview()}
        let items = desktop.pages[page]
        for row in 0..<4 { let stack = UIStackView();stack.axis = .horizontal;stack.distribution = .fillEqually;stack.spacing = 4
            for col in 0..<4 { let index = row*4+col;if index < items.count { stack.addArrangedSubview(icon(items[index])) } else { let empty = UIView();empty.heightAnchor.constraint(equalToConstant:77).isActive = true;stack.addArrangedSubview(empty) } };grid.addArrangedSubview(stack) }
        for id in desktop.dock { dock.addArrangedSubview(icon(id,docked:true)) }
        pager.text = (0..<desktop.pages.count).map{$0 == page ? "●" : "○"}.joined(separator:"  ")+(iconEditing ? "  长按图标编辑" : "");pager.font = .boldSystemFont(ofSize:12);pager.layer.shadowColor = UIColor.black.cgColor;pager.layer.shadowOpacity = 0.8;pager.layer.shadowRadius = 2
    }
    private func icon(_ id:String,docked:Bool = false) -> UIView {
        let stack = UIStackView();stack.axis = .vertical;stack.alignment = .center;stack.spacing = 4
        let b = UIButton(type:.custom);b.accessibilityIdentifier = id;b.layer.cornerRadius = 12;b.clipsToBounds = true
        b.layer.shadowColor = UIColor.black.cgColor;b.layer.shadowOpacity = 0.4;b.layer.shadowRadius = 3
        let name:String
        if let s = system[id] { name = s.0
            if !s.1.isEmpty { b.setBackgroundImage(UIImage(named:s.1),for:.normal) }
            else { b.setBackgroundImage(RetroTheme.gradient(UIColor(red:0.51,green:0.78,blue:0.97,alpha:1),UIColor(red:0.11,green:0.32,blue:0.69,alpha:1),height:57),for:.normal);b.setImage(UIImage(systemName:"airplane",withConfiguration:UIImage.SymbolConfiguration(pointSize:30,weight:.medium)),for:.normal);b.tintColor = .white }
        }
        else if let folder = desktop.folders[id] { name = desktop.folderNames[id] ?? "文件夹";b.backgroundColor = .darkGray;b.setTitle(folder.isEmpty ? "▦" : "▦ \(folder.count)",for:.normal) }
        else if let a = manager.apps.first(where:{$0.id == id}) { name = a.manifest.name;b.setBackgroundImage(UIImage(contentsOfFile:manager.bundle(a).appendingPathComponent(a.manifest.icon).path),for:.normal) }
        else { name = "未知" }
        b.widthAnchor.constraint(equalToConstant:docked ? 53 : 57).isActive = true;b.heightAnchor.constraint(equalToConstant:docked ? 53 : 57).isActive = true
        b.addAction(UIAction{[weak self]_ in guard let self else{return};self.iconEditing ? self.edit(id) : self.open(id)},for:.touchUpInside)
        b.addGestureRecognizer(UILongPressGestureRecognizer(target:self,action:#selector(longPress)))
        let label = UILabel();label.text = name;label.font = .systemFont(ofSize:docked ? 10 : 11,weight:.medium);label.textAlignment = .center;label.textColor = .white;label.numberOfLines = 1;label.adjustsFontSizeToFitWidth = true;label.shadowColor = .black;label.shadowOffset = CGSize(width:0,height:1)
        stack.addArrangedSubview(b);stack.addArrangedSubview(label);return stack
    }
    @objc private func longPress(_ gesture:UILongPressGestureRecognizer) { if gesture.state == .began, let id = gesture.view?.accessibilityIdentifier { iconEditing = true;edit(id) } }
    private func edit(_ id:String) {
        let alert = sheet("编辑图标")
        alert.addAction(UIAlertAction(title:"移到下一页",style:.default){_ in self.removeFromLayout(id);if self.page+1 >= self.desktop.pages.count { self.desktop.pages.append([]) };let target = self.page+1;if self.desktop.pages[target].count<16 { self.desktop.pages[target].append(id) } else { self.desktop.pages.append([id]) };self.refresh()})
        alert.addAction(UIAlertAction(title:"移到 Dock",style:.default){_ in self.removeFromLayout(id);if self.desktop.dock.count >= 4 { let displaced = self.desktop.dock.removeFirst();self.desktop.pages.append([displaced]) };self.desktop.dock.append(id);self.refresh()})
        if desktop.folders[id] == nil {
            alert.addAction(UIAlertAction(title:"新建文件夹并移入",style:.default){_ in let prompt = self.sheet("文件夹名称");prompt.addTextField{$0.text = "新文件夹"};prompt.addAction(UIAlertAction(title:"创建",style:.default){_ in self.removeFromLayout(id);let fid = "folder-"+UUID().uuidString;self.desktop.folders[fid] = [id];self.desktop.folderNames[fid] = prompt.textFields?.first?.text ?? "文件夹";self.desktop.pages.append([fid]);self.refresh()});prompt.addAction(UIAlertAction(title:"取消",style:.cancel));self.present(prompt,animated:true)})
            for fid in desktop.folders.keys.sorted() { alert.addAction(UIAlertAction(title:"移入 \(desktop.folderNames[fid] ?? "文件夹")",style:.default){_ in self.removeFromLayout(id);self.desktop.folders[fid,default:[]].append(id);self.refresh()}) }
        } else {
            alert.addAction(UIAlertAction(title:"重命名文件夹",style:.default){_ in let p = self.sheet("名称");p.addTextField{$0.text = self.desktop.folderNames[id]};p.addAction(UIAlertAction(title:"保存",style:.default){_ in self.desktop.folderNames[id] = p.textFields?.first?.text;self.refresh()});p.addAction(UIAlertAction(title:"取消",style:.cancel));self.present(p,animated:true)})
            alert.addAction(UIAlertAction(title:"解散文件夹",style:.destructive){_ in let contents = self.desktop.folders.removeValue(forKey:id) ?? [];self.desktop.folderNames.removeValue(forKey:id);self.removeFromLayout(id);self.desktop.pages.append(contents);self.refresh()})
        }
        if let a = manager.apps.first(where:{$0.id == id}) { alert.addAction(UIAlertAction(title:"卸载并删除数据",style:.destructive){_ in do { self.sessions[a.id]?.dispose();self.sessions.removeValue(forKey:a.id);try self.manager.uninstall(a);self.refresh() } catch { self.showError(error) }}) }
        alert.addAction(UIAlertAction(title:"完成编辑",style:.cancel){_ in self.iconEditing = false;self.refresh()});present(alert,animated:true)
    }
    private func removeFromLayout(_ id:String) { desktop.pages = desktop.pages.map{$0.filter{$0 != id}};desktop.dock.removeAll{$0 == id};for f in desktop.folders.keys { desktop.folders[f]?.removeAll{$0 == id} } }
    private func open(_ id:String) {
        if let folder = desktop.folders[id] { let alert = sheet(desktop.folderNames[id] ?? "文件夹");for item in folder { let name = system[item]?.0 ?? manager.apps.first(where:{$0.id == item})?.manifest.name ?? "应用";alert.addAction(UIAlertAction(title:name,style:.default){_ in self.open(item)}) };alert.addAction(UIAlertAction(title:"关闭",style:.cancel));present(alert,animated:true);return }
        switch id {
        case "notes":presentRetro(NotesController())
        case "calculator":presentRetro(CalculatorController())
        case "store":presentRetro(StoreController(beta:false))
        case "beta":presentRetro(StoreController(beta:true))
        case "settings":presentRetro(SettingsController())
        default:
            guard let a = manager.apps.first(where:{$0.id == id}) else { return }
            if a.channel == "beta", let expiry = a.expiresAt, expiry < Date().timeIntervalSince1970 { showError(SimError.message("Beta 测试已过期，请重新获取测试权限"));return }
            if sessions[id] == nil && sessions.count >= 3, let oldest = recent.last(where:{sessions[$0] != nil}) { sessions[oldest]?.dispose();sessions.removeValue(forKey:oldest) }
            let runtime = sessions[id] ?? WebRuntime(app:a);sessions[id] = runtime;runtime.onTerminate = {[weak self] in self?.sessions.removeValue(forKey:id)}
            recent.removeAll{$0 == id};recent.insert(id,at:0);presentRetro(runtime)
        }
    }
    private func switcher() { let a = sheet("最近运行");for id in recent where sessions[id] != nil { a.addAction(UIAlertAction(title:sessions[id]!.app.manifest.name,style:.default){_ in self.open(id)}) };a.addAction(UIAlertAction(title:"退出全部应用",style:.destructive){_ in self.sessions.values.forEach{$0.dispose()};self.sessions.removeAll()});a.addAction(UIAlertAction(title:"关闭",style:.cancel));present(a,animated:true) }
    private func lock() {
        if lockView != nil { return }
        let lock = UIView();lock.backgroundColor = UIColor.black.withAlphaComponent(0.08);lock.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(lock);lockView = lock
        NSLayoutConstraint.activate([lock.topAnchor.constraint(equalTo:view.topAnchor),lock.bottomAnchor.constraint(equalTo:view.bottomAnchor),lock.leadingAnchor.constraint(equalTo:view.leadingAnchor),lock.trailingAnchor.constraint(equalTo:view.trailingAnchor)])
        let header = GradientView([UIColor.black.withAlphaComponent(0.65),UIColor.black.withAlphaComponent(0.12)]);header.translatesAutoresizingMaskIntoConstraints = false;lock.addSubview(header)
        let time = UILabel();time.tag = 6;time.font = .systemFont(ofSize:66,weight:.thin);time.textColor = .white;time.textAlignment = .center;time.shadowColor = .black;time.shadowOffset = CGSize(width:0,height:1)
        let date = UILabel();let df = DateFormatter();df.locale = Locale(identifier:"zh_CN");df.dateFormat = "M月d日 EEEE";date.text = df.string(from:Date());date.textColor = .white;date.textAlignment = .center;date.font = .systemFont(ofSize:17);date.shadowColor = .black;date.shadowOffset = CGSize(width:0,height:1)
        let stack = UIStackView(arrangedSubviews:[time,date]);stack.axis = .vertical;stack.translatesAutoresizingMaskIntoConstraints = false;header.addSubview(stack)
        let footer = GradientView([UIColor.black.withAlphaComponent(0.07),UIColor.black.withAlphaComponent(0.68)]);footer.translatesAutoresizingMaskIntoConstraints = false;lock.addSubview(footer)
        let slider = RetroUnlockSlider();slider.translatesAutoresizingMaskIntoConstraints = false;slider.onUnlock = {[weak self] in self?.unlock()};footer.addSubview(slider)
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo:lock.topAnchor),header.leadingAnchor.constraint(equalTo:lock.leadingAnchor),header.trailingAnchor.constraint(equalTo:lock.trailingAnchor),header.bottomAnchor.constraint(equalTo:lock.safeAreaLayoutGuide.topAnchor,constant:155),stack.bottomAnchor.constraint(equalTo:header.bottomAnchor,constant:-16),stack.leadingAnchor.constraint(equalTo:header.leadingAnchor),stack.trailingAnchor.constraint(equalTo:header.trailingAnchor),footer.bottomAnchor.constraint(equalTo:lock.bottomAnchor),footer.leadingAnchor.constraint(equalTo:lock.leadingAnchor),footer.trailingAnchor.constraint(equalTo:lock.trailingAnchor),footer.heightAnchor.constraint(equalToConstant:150),slider.centerYAnchor.constraint(equalTo:footer.centerYAnchor),slider.leadingAnchor.constraint(equalTo:footer.leadingAnchor,constant:22),slider.trailingAnchor.constraint(equalTo:footer.trailingAnchor,constant:-22),slider.heightAnchor.constraint(equalToConstant:55)])
        tick()
    }
    private func unlock() { UIView.animate(withDuration:0.3,animations:{self.lockView?.alpha = 0}){_ in self.lockView?.removeFromSuperview();self.lockView = nil} }
}
