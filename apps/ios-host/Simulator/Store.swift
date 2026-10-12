import UIKit
@MainActor final class StoreController:UITableViewController, UISearchResultsUpdating {
    let beta:Bool
    private var rows:[[String:Any]] = []
    private var filtered:[[String:Any]] = []
    private var installing = Set<String>()
    private let search = UISearchController(searchResultsController:nil)
    init(beta:Bool) { self.beta = beta;super.init(style:.grouped);title = beta ? "Beta 测试" : "App Store" }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();navigationItem.leftBarButtonItem = UIBarButtonItem(title:"主屏幕",style:.plain,target:self,action:#selector(home))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:beta ? "兑换" : "更新",style:.plain,target:self,action:#selector(extra))
        search.searchResultsUpdater = self;search.obscuresBackgroundDuringPresentation = false;search.searchBar.placeholder = "搜索应用或分类";search.searchBar.sizeToFit();tableView.tableHeaderView = search.searchBar;definesPresentationContext = true
        tableView.backgroundColor = UIColor(red:0.86,green:0.88,blue:0.90,alpha:1);tableView.rowHeight = 70
        refreshControl = UIRefreshControl();refreshControl?.addTarget(self,action:#selector(load),for:.valueChanged);load()
        let footer = UILabel(frame:CGRect(x:0,y:0,width:300,height:60));footer.text = "第三方虚拟应用生态，与 Apple 无关联";footer.font = .systemFont(ofSize:11);footer.textColor = .secondaryLabel;footer.textAlignment = .center;tableView.tableFooterView = footer
    }
    @objc func home() { dismiss(animated:true) }
    @objc func load() { Task { do { let data = try await API.shared.request(beta ? "/v1/beta/my-builds" : "/v1/store/featured");rows = data as? [[String:Any]] ?? [];updateSearchResults(for:search) } catch { showError(error) };refreshControl?.endRefreshing() } }
    func updateSearchResults(for searchController:UISearchController) { let q = search.searchBar.text?.lowercased() ?? "";filtered = rows.filter{q.isEmpty || (($0["name"] as? String ?? "")+" "+($0["category"] as? String ?? "")).lowercased().contains(q)};tableView.reloadData() }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { filtered.count }
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath) -> UITableViewCell {
        let a = filtered[indexPath.row];let build = a["build"] as? [String:Any] ?? [:];let id = a["id"] as? String ?? ""
        let cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil);cell.textLabel?.text = a["name"] as? String
        let installed = AppManager.shared.apps.first{$0.id == id};let state = installing.contains(id) ? "安装中…" : installed?.buildId == (build["id"] as? String) ? "已安装" : installed == nil ? "免费" : "可更新"
        cell.detailTextLabel?.text = "\(a["category"] as? String ?? "工具") · \(build["version"] as? String ?? "") · \(state)";cell.accessoryType = .disclosureIndicator
        cell.imageView?.image = UIImage(systemName:beta ? "airplane.circle.fill" : "square.stack.3d.up.fill");cell.imageView?.tintColor = RetroTheme.blue
        return cell
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true);let a = filtered[indexPath.row];let b = a["build"] as? [String:Any] ?? [:];let m = b["manifest"] as? [String:Any] ?? [:]
        let alert = sheet(a["name"] as? String ?? "应用","\(a["description"] as? String ?? "")\n\n权限：\((m["permissions"] as? [String] ?? []).joined(separator:", "))\n隐私：\(a["privacy"] as? String ?? "")\n\n版本：\(b["version"] as? String ?? "")")
        alert.addAction(UIAlertAction(title:"安装 / 更新",style:.default){_ in self.install(a)})
        if beta { alert.addAction(UIAlertAction(title:"提交反馈",style:.default){_ in let p = self.sheet("反馈","请勿包含个人敏感信息");p.addTextField{$0.placeholder = "描述问题或建议"};p.addAction(UIAlertAction(title:"提交",style:.default){_ in Task { do { _ = try await API.shared.request("/v1/beta/feedback",method:"POST",body:["build_id":b["id"] ?? "","content":p.textFields?.first?.text ?? ""]);self.showError(SimError.message("反馈已提交")) } catch { self.showError(error) } } });p.addAction(UIAlertAction(title:"取消",style:.cancel));self.present(p,animated:true)}) }
        else { alert.addAction(UIAlertAction(title:"评价",style:.default){_ in let p = self.sheet("评价");p.addTextField{$0.placeholder = "1–5 星";$0.keyboardType = .numberPad};p.addTextField{$0.placeholder = "评价内容"};p.addAction(UIAlertAction(title:"提交",style:.default){_ in Task { do { _ = try await API.shared.request("/v1/store/apps/\(a["id"] ?? "")/ratings",method:"POST",body:["stars":Int(p.textFields?[0].text ?? "") ?? 0,"text":p.textFields?[1].text ?? ""]);self.load() } catch { self.showError(error) } } });p.addAction(UIAlertAction(title:"取消",style:.cancel));self.present(p,animated:true)}) }
        alert.addAction(UIAlertAction(title:"取消",style:.cancel));present(alert,animated:true)
    }
    private func install(_ a:[String:Any]) {
        guard let id = a["id"] as? String, let build = a["build"] as? [String:Any], let buildId = build["id"] as? String else { return }
        guard !installing.contains(id) else { return };installing.insert(id);tableView.reloadData()
        Task { do { let ticket = try await API.shared.installTicket(appId:id,buildId:buildId);let group = a["group"] as? [String:Any];try await AppManager.shared.install(ticket,betaExpiry:group?["expires"] as? Double);showError(SimError.message("安装完成。返回主屏幕点击图标运行。")) } catch { showError(error) };installing.remove(id);tableView.reloadData() }
    }
    @objc private func extra() {
        if beta { let p = sheet("兑换测试邀请");p.addTextField{$0.placeholder = "一次性邀请码";$0.autocapitalizationType = .none};p.addAction(UIAlertAction(title:"兑换",style:.default){_ in Task { do { _ = try await API.shared.request("/v1/beta/invites/redeem",method:"POST",body:["code":p.textFields?.first?.text ?? ""]);self.load() } catch { self.showError(error) } } });p.addAction(UIAlertAction(title:"取消",style:.cancel));present(p,animated:true) }
        else { Task { do { let result = try await API.shared.request("/v1/store/updates");rows = result as? [[String:Any]] ?? [];title = "可用更新";updateSearchResults(for:search);if rows.isEmpty { showError(SimError.message("所有应用均为最新版本")) } } catch { showError(error) } } }
    }
}
