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
    private let system:[String:(String,String,UIColor)] = ["notes":("备忘录","note.text",.systemYellow),"calculator":("计算器","plus.forwardslash.minus",.darkGray),"store":("应用商店","a.circle",.systemBlue),"beta":("Beta 测试","airplane",.systemTeal),"settings":("设置","gearshape",.gray)]
    override var preferredStatusBarStyle:UIStatusBarStyle { .lightContent }
    override func viewDidLoad() {
        super.viewDidLoad()
        if let data = UserDefaults.standard.data(forKey:"desktop"),let layout = try? JSONDecoder().decode(DesktopLayout.self,from:data) { desktop = layout }
        let bg = GradientView([UIColor(red:0.36,green:0.53,blue:0.57,alpha:1),UIColor(red:0.08,green:0.18,blue:0.27,alpha:1)]);bg.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(bg);NSLayoutConstraint.activate([bg.topAnchor.constraint(equalTo:view.topAnchor),bg.bottomAnchor.constraint(equalTo:view.bottomAnchor),bg.leadingAnchor.constraint(equalTo:view.leadingAnchor),bg.trailingAnchor.constraint(equalTo:view.trailingAnchor)])
        let content = UIStackView();content.axis = .vertical;content.spacing = 8;content.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(content)
        status.textColor = .white;status.font = .systemFont(ofSize:12);status.textAlignment = .center;content.addArrangedSubview(status)
        grid.axis = .vertical;grid.spacing = 12;content.addArrangedSubview(grid)
        let spacer = UIView();content.addArrangedSubview(spacer)
        pager.textAlignment = .center;pager.textColor = .white;content.addArrangedSubview(pager)
        let controls = UIStackView();controls.distribution = .fillEqually;controls.spacing = 8
        let actions: [(String, () -> Void)] = [("‹",{[weak self] in self?.changePage(-1)}),("最近",{[weak self] in self?.switcher()}),("编辑",{[weak self] in self?.iconEditing.toggle();self?.refresh()}),("锁屏",{[weak self] in self?.lock()}),("›",{[weak self] in self?.changePage(1)})]
        for (title,action) in actions { controls.addArrangedSubview(RetroTheme.button(title,action:action)) };content.addArrangedSubview(controls)
        dock.distribution = .fillEqually;dock.spacing = 12;dock.backgroundColor = UIColor.white.withAlphaComponent(0.2);dock.layer.cornerRadius = 12;dock.isLayoutMarginsRelativeArrangement = true;dock.layoutMargins = UIEdgeInsets(top:10,left:10,bottom:10,right:10);content.addArrangedSubview(dock)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),content.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-10),content.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:14),content.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-14),spacer.heightAnchor.constraint(greaterThanOrEqualToConstant:5)])
        let left = UISwipeGestureRecognizer(target:self,action:#selector(swipe));left.direction = .left;view.addGestureRecognizer(left)
        let right = UISwipeGestureRecognizer(target:self,action:#selector(swipe));right.direction = .right;view.addGestureRecognizer(right)
        NotificationCenter.default.addObserver(self,selector:#selector(refresh),name:Notification.Name("InstalledChanged"),object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(background),name:UIApplication.didEnterBackgroundNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(memory),name:UIApplication.didReceiveMemoryWarningNotification,object:nil)
        clock = Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self]_ in Task { @MainActor in self?.tick() } };tick();refresh();lock()
    }
    @objc private func background() { sessions.values.forEach{$0.event("pause")} }
    @objc private func memory() { for (id,session) in sessions where session.presentingViewController == nil && session.navigationController?.presentingViewController == nil { session.dispose();sessions.removeValue(forKey:id) } }
    private func tick() { let f = DateFormatter();f.dateFormat = "HH:mm";status.text = "Retro6  ▰                     \(f.string(from:Date()))                     ▰";if let label = lockView?.viewWithTag(6) as? UILabel { label.text = f.string(from:Date()) } }
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
        for row in 0..<4 { let stack = UIStackView();stack.axis = .horizontal;stack.distribution = .fillEqually;stack.spacing = 12
            for col in 0..<4 { let index = row*4+col;if index < items.count { stack.addArrangedSubview(icon(items[index])) } else { let empty = UIView();empty.heightAnchor.constraint(equalToConstant:65).isActive = true;stack.addArrangedSubview(empty) } };grid.addArrangedSubview(stack) }
        for id in desktop.dock { dock.addArrangedSubview(icon(id)) }
        pager.text = (0..<desktop.pages.count).map{$0 == page ? "●" : "○"}.joined(separator:"  ")+(iconEditing ? "  点图标编辑" : "")
    }
    private func icon(_ id:String) -> UIView {
        let stack = UIStackView();stack.axis = .vertical;stack.alignment = .center;stack.spacing = 5
        let b = UIButton(type:.custom);b.accessibilityIdentifier = id;b.layer.cornerRadius = 12;b.clipsToBounds = true;b.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor;b.layer.borderWidth = 1
        let name:String
        if let s = system[id] { name = s.0;b.backgroundColor = s.2;b.setImage(UIImage(systemName:s.1,withConfiguration:UIImage.SymbolConfiguration(pointSize:26,weight:.medium)),for:.normal);b.tintColor = .white }
        else if let folder = desktop.folders[id] { name = desktop.folderNames[id] ?? "文件夹";b.backgroundColor = .darkGray;b.setTitle(folder.isEmpty ? "▦" : "▦ \(folder.count)",for:.normal) }
        else if let a = manager.apps.first(where:{$0.id == id}) { name = a.manifest.name;b.setImage(UIImage(contentsOfFile:manager.bundle(a).appendingPathComponent(a.manifest.icon).path),for:.normal) }
        else { name = "未知" }
        b.widthAnchor.constraint(equalToConstant:44).isActive = true;b.heightAnchor.constraint(equalToConstant:44).isActive = true
        b.addAction(UIAction{[weak self]_ in guard let self else{return};self.iconEditing ? self.edit(id) : self.open(id)},for:.touchUpInside)
        b.addGestureRecognizer(UILongPressGestureRecognizer(target:self,action:#selector(longPress)))
        let label = UILabel();label.text = name;label.font = .systemFont(ofSize:11);label.textAlignment = .center;label.textColor = .white;label.numberOfLines = 1;label.adjustsFontSizeToFitWidth = true
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
        let lock = GradientView([UIColor.black.withAlphaComponent(0.4),UIColor(red:0.06,green:0.16,blue:0.24,alpha:1)]);lock.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(lock);lockView = lock
        NSLayoutConstraint.activate([lock.topAnchor.constraint(equalTo:view.topAnchor),lock.bottomAnchor.constraint(equalTo:view.bottomAnchor),lock.leadingAnchor.constraint(equalTo:view.leadingAnchor),lock.trailingAnchor.constraint(equalTo:view.trailingAnchor)])
        let time = UILabel();time.tag = 6;time.font = .systemFont(ofSize:66,weight:.thin);time.textColor = .white;time.textAlignment = .center
        let date = UILabel();date.text = Date().formatted(date:.complete,time:.omitted);date.textColor = .white;date.textAlignment = .center;date.font = .systemFont(ofSize:16)
        let stack = UIStackView(arrangedSubviews:[time,date]);stack.axis = .vertical;stack.translatesAutoresizingMaskIntoConstraints = false;lock.addSubview(stack)
        let slider = UISlider();slider.minimumValue = 0;slider.maximumValue = 1;slider.tintColor = .lightGray;slider.translatesAutoresizingMaskIntoConstraints = false;slider.accessibilityLabel = "滑动解锁";slider.addAction(UIAction{[weak self]_ in if slider.value > 0.95 { self?.unlock() } else { slider.value = 0 } },for:[.touchUpInside,.touchUpOutside]);lock.addSubview(slider)
        let hint = UILabel();hint.text = "滑动解锁  ›";hint.textColor = .white;hint.textAlignment = .center;hint.translatesAutoresizingMaskIntoConstraints = false;lock.addSubview(hint)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:lock.safeAreaLayoutGuide.topAnchor,constant:40),stack.leadingAnchor.constraint(equalTo:lock.leadingAnchor),stack.trailingAnchor.constraint(equalTo:lock.trailingAnchor),slider.bottomAnchor.constraint(equalTo:lock.safeAreaLayoutGuide.bottomAnchor,constant:-55),slider.leadingAnchor.constraint(equalTo:lock.leadingAnchor,constant:40),slider.trailingAnchor.constraint(equalTo:lock.trailingAnchor,constant:-40),hint.topAnchor.constraint(equalTo:slider.bottomAnchor,constant:10),hint.centerXAnchor.constraint(equalTo:lock.centerXAnchor)])
        tick()
    }
    private func unlock() { UIView.animate(withDuration:0.3,animations:{self.lockView?.alpha = 0}){_ in self.lockView?.removeFromSuperview();self.lockView = nil} }
}
