import SwiftUI
import VisionKit
import Vision
import UniformTypeIdentifiers
import Combine
import PhotosUI
import SafariServices

// MARK: - 1. 核心模型
struct Manual: Identifiable, Codable {
    var id = UUID()
    var title: String
    var createDate: Date
    var pageCount: Int
    var pagesData: [Data]
    var recognizedTexts: [String]
    var customCoverData: Data? 
    
    var equipmentName: String?
    var category: String?
    var tags: [String]?
    
    var coverImage: UIImage? {
        if let customData = customCoverData { return UIImage(data: customData) }
        guard let first = pagesData.first else { return nil }
        return UIImage(data: first)
    }
}

// MARK: - 2. 排序选项
enum SortOption: String, CaseIterable {
    case dateDesc = "最新添加"
    case dateAsc = "最早添加"
    case titleAsc = "名称排序"
}

// MARK: - 3. OCR 核心引擎 (空间排版还原 + 智能提取标题)
struct TextElement { let text: String; let rect: CGRect }
struct OCRHelper {
    static func recognizeText(from image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }
        var result = ""
        let request = VNRecognizeTextRequest { req, _ in
            let observations = req.results as? [VNRecognizedTextObservation] ?? []
            var elements: [TextElement] = []
            for obs in observations {
                if let top = obs.topCandidates(1).first {
                    let rect = CGRect(x: obs.boundingBox.minX, y: 1.0 - obs.boundingBox.maxY, width: obs.boundingBox.width, height: obs.boundingBox.height)
                    elements.append(TextElement(text: top.string, rect: rect))
                }
            }
            elements.sort { $0.rect.minY < $1.rect.minY }
            var lines: [[TextElement]] = []
            for el in elements {
                if lines.isEmpty { lines.append([el]) } else {
                    let lastLineIndex = lines.count - 1; let lastEl = lines[lastLineIndex].last!
                    let yDistance = abs(el.rect.midY - lastEl.rect.midY)
                    let avgHeight = (el.rect.height + lastEl.rect.height) / 2.0
                    if yDistance < avgHeight * 0.6 { lines[lastLineIndex].append(el) } else { lines.append([el]) }
                }
            }
            var finalString = ""; var previousLineMaxY: CGFloat = -1
            for line in lines {
                let sortedLine = line.sorted { $0.rect.minX < $1.rect.minX }
                if previousLineMaxY != -1 {
                    let yGap = sortedLine.first!.rect.minY - previousLineMaxY
                    let avgHeight = sortedLine.map { $0.rect.height }.reduce(0, +) / CGFloat(sortedLine.count)
                    let newlines = max(1, Int(round(yGap / (avgHeight * 1.5))))
                    finalString += String(repeating: "\n", count: min(3, newlines))
                }
                var lineStr = ""; var previousMaxX: CGFloat = -1
                for el in sortedLine {
                    if previousMaxX != -1 {
                        let xGap = el.rect.minX - previousMaxX
                        let charWidth = el.rect.width / CGFloat(max(1, el.text.count))
                        let spaces = max(1, Int(round(xGap / charWidth)))
                        lineStr += String(repeating: " ", count: min(15, spaces))
                    }
                    lineStr += el.text; previousMaxX = el.rect.maxX
                }
                finalString += lineStr; previousLineMaxY = sortedLine.map { $0.rect.maxY }.max() ?? -1
            }
            result = finalString
        }
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        return result
    }
    
    // 【新增】：智能标题提取算法
    static func extractSmartTitle(from texts: [String]) -> String {
        guard let firstPageText = texts.first, !firstPageText.isEmpty else { return "" }
        let lines = firstPageText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        let keywords = ["说明书", "手册", "指南", "使用说明", "安装", "注意事项", "manual", "guide"]
        
        // 策略1：优先寻找含有关键词的行 (比如：大疆无人机使用说明书)
        for line in lines {
            if line.count <= 35 {
                for keyword in keywords {
                    if line.lowercased().contains(keyword) { return line }
                }
            }
        }
        
        // 策略2：如果没有说明书字眼，取第一行长度适中、看起来像商品名的粗体/大字
        for line in lines {
            if line.count >= 2 && line.count <= 25 { return line }
        }
        
        return ""
    }
}

// MARK: - 4. 数据管理中心
class ManualStore: ObservableObject {
    @Published var manuals: [Manual] = [] { didSet { save() } }
    let savePath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ManualsBackup.json")
    init() { load() }
    func load() {
        if let data = try? Data(contentsOf: savePath), let decoded = try? JSONDecoder().decode([Manual].self, from: data) { manuals = decoded }
    }
    func save() { if let encoded = try? JSONEncoder().encode(manuals) { try? encoded.write(to: savePath) } }
    func restore(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([Manual].self, from: data) else { return false }
        DispatchQueue.main.async { self.manuals = decoded }
        return true
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var fileURL: URL
    init(url: URL) { self.fileURL = url }
    init(configuration: ReadConfiguration) throws { fatalError("只用于导出") }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { return try FileWrapper(url: fileURL, options: .immediate) }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let safariVC = SFSafariViewController(url: url)
        safariVC.preferredControlTintColor = .systemBlue
        return safariVC
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - 5. 主界面 UI
struct ContentView: View {
    @StateObject var store = ManualStore()
    @State private var isScanning = false
    @State private var isProcessing = false
    @State private var processingText = ""
    
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedCoverItem: PhotosPickerItem? = nil
    @State private var manualToChangeCover: Manual? = nil
    @State private var isShowingCoverPicker = false
    
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateDesc
    @State private var manualToEdit: Manual? = nil
    @State private var showCategorySheet = false
    
    @State private var isEditingMode = false
    @State private var selectedManualIDs = Set<UUID>()
    
    let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    
    var filteredAndSortedManuals: [Manual] {
        var result = store.manuals
        if !searchText.isEmpty {
            result = result.filter { m in
                let s = searchText.lowercased()
                return m.title.localizedCaseInsensitiveContains(s) || m.recognizedTexts.joined(separator: " ").localizedCaseInsensitiveContains(s) || (m.equipmentName?.localizedCaseInsensitiveContains(s) ?? false) || (m.category?.localizedCaseInsensitiveContains(s) ?? false) || (m.tags?.contains(where: { $0.localizedCaseInsensitiveContains(s) }) ?? false)
            }
        }
        result.sort { a, b in
            switch sortOption {
            case .dateDesc: return a.createDate > b.createDate
            case .dateAsc: return a.createDate < b.createDate
            case .titleAsc: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
        return result
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                
                if filteredAndSortedManuals.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(filteredAndSortedManuals) { manual in
                                if isEditingMode {
                                    ManualCard(manual: manual)
                                        .overlay(
                                            Image(systemName: selectedManualIDs.contains(manual.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 24))
                                                .foregroundColor(selectedManualIDs.contains(manual.id) ? .blue : .gray.opacity(0.8))
                                                .padding(10),
                                            alignment: .bottomTrailing
                                        )
                                        .onTapGesture {
                                            if selectedManualIDs.contains(manual.id) { selectedManualIDs.remove(manual.id) }
                                            else { selectedManualIDs.insert(manual.id) }
                                        }
                                } else {
                                    NavigationLink(destination: ManualDetailView(manual: manual, store: store, searchText: searchText)) {
                                        ManualCard(manual: manual)
                                    }
                                    .contextMenu {
                                        Button { manualToChangeCover = manual; isShowingCoverPicker = true } label: { Label("相册选图作封面", systemImage: "photo.stack") }
                                        Button { manualToEdit = manual } label: { Label("编辑属性", systemImage: "info.circle") }
                                        Button(role: .destructive) {
                                            if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) { withAnimation { store.manuals.remove(at: index) } }
                                        } label: { Label("删除", systemImage: "trash") }
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 100)
                    }
                }
                
                VStack {
                    Spacer()
                    if isEditingMode {
                        HStack {
                            Button(action: {
                                withAnimation {
                                    store.manuals.removeAll { selectedManualIDs.contains($0.id) }
                                    isEditingMode = false
                                    selectedManualIDs.removeAll()
                                }
                            }) {
                                HStack {
                                    Image(systemName: "trash").font(.headline)
                                    Text("删除所选 (\(selectedManualIDs.count))").fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity).padding().background(selectedManualIDs.isEmpty ? Color.gray : Color.red).foregroundColor(.white).cornerRadius(15)
                            }
                            .disabled(selectedManualIDs.isEmpty)
                        }
                        .padding(.horizontal, 24).padding(.bottom, 20)
                    } else {
                        HStack(alignment: .bottom) {
                            HStack(spacing: 15) {
                                Button(action: { isScanning = true }) {
                                    HStack(spacing: 8) { Image(systemName: "camera.viewfinder").font(.system(size: 18, weight: .bold)); Text("扫描").fontWeight(.bold) }
                                    .frame(maxWidth: .infinity).padding(.vertical, 14).background(Color.blue).foregroundColor(.white).clipShape(Capsule()).shadow(radius: 5)
                                }
                                PhotosPicker(selection: $selectedPhotos, matching: .images, photoLibrary: .shared()) {
                                    HStack(spacing: 8) { Image(systemName: "photo.on.rectangle").font(.system(size: 18, weight: .bold)); Text("导入").fontWeight(.bold) }
                                    .frame(maxWidth: .infinity).padding(.vertical, 14).background(Color.indigo).foregroundColor(.white).clipShape(Capsule()).shadow(radius: 5)
                                }
                                .onChange(of: selectedPhotos) { newItems in handlePhotoImport(items: newItems) }
                            }
                            .frame(maxWidth: .infinity)
                            
                            Button(action: { showCategorySheet = true }) {
                                Image(systemName: "square.grid.2x2.fill")
                                    .font(.system(size: 22)).frame(width: 54, height: 54).background(Color.orange).foregroundColor(.white).clipShape(Circle()).shadow(color: .orange.opacity(0.4), radius: 8, x: 0, y: 4)
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("说明书库")
            .searchable(text: $searchText, prompt: "搜索名称、设备、类别或内容...")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button(action: { store.save(); showExporter = true }) { Label("导出备份数据", systemImage: "square.and.arrow.up") }
                        Button(action: { showImporter = true }) { Label("从本地/云盘恢复", systemImage: "square.and.arrow.down") }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 15) {
                        Menu {
                            Picker("排序", selection: $sortOption) { ForEach(SortOption.allCases, id: \.self) { o in Text(o.rawValue).tag(o) } }
                        } label: { Image(systemName: "arrow.up.arrow.down.circle").font(.title3) }
                        
                        Button(action: {
                            withAnimation { isEditingMode.toggle() }
                            if !isEditingMode { selectedManualIDs.removeAll() }
                        }) { Text(isEditingMode ? "完成" : "管理").font(.system(size: 16, weight: .bold)) }
                    }
                }
            }
            .sheet(isPresented: $showCategorySheet) { CategoryListView(store: store, searchText: $searchText) }
            .photosPicker(isPresented: $isShowingCoverPicker, selection: $selectedCoverItem, matching: .images)
            .onChange(of: selectedCoverItem) { newItem in handleCoverSelection(item: newItem) }
            .sheet(isPresented: $isScanning) { DocumentScannerBridge(store: store, isProcessing: $isProcessing, processingText: $processingText) }
            .sheet(item: $manualToEdit) { manual in EditManualInfoSheet(manual: manual, store: store) }
            
            .fileExporter(isPresented: $showExporter, document: BackupDocument(url: store.savePath), contentType: .json, defaultFilename: "Manuals_Backup.json") { result in
                switch result { case .success: showSuccess("导出备份成功！") case .failure: break }
            }
            
            // 【神级修复】：放宽所有的 UTType，允许选中任何文件（.json, .data, .item, .content 等）
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item, .content, .data, .json, .plainText], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                        try? FileManager.default.removeItem(at: tempURL)
                        do {
                            try FileManager.default.copyItem(at: url, to: tempURL)
                            if store.restore(from: tempURL) { showSuccess("恢复成功！加载了 \(store.manuals.count) 份说明书。") } else { showSuccess("恢复失败：文件格式不正确，请选择由本软件导出的 JSON 备份文件。") }
                        } catch { showSuccess("读取文件失败：权限被系统拒绝。") }
                    }
                case .failure: showSuccess("未能获取文件读取权限")
                }
            }
            .alert(isPresented: $showAlert) { Alert(title: Text("系统提示"), message: Text(alertMessage), dismissButton: .default(Text("好的"))) }
            .overlay { if isProcessing { ProcessingOverlay(text: processingText) } }
        }
    }
    
    private func handleCoverSelection(item: PhotosPickerItem?) {
        guard let item = item, let manual = manualToChangeCover else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let uiImage = UIImage(data: data), let compressed = uiImage.jpegData(compressionQuality: 0.6) {
                DispatchQueue.main.async {
                    if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) { store.manuals[index].customCoverData = compressed }
                    self.manualToChangeCover = nil; self.selectedCoverItem = nil
                }
            }
        }
    }

    private func handlePhotoImport(items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isProcessing = true; processingText = "正在解析并提取智能标题..."
        Task {
            var tempPagesData: [Data] = []; var tempTexts: [String] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) {
                    if let compressed = uiImage.jpegData(compressionQuality: 0.7) { tempPagesData.append(compressed) }
                    tempTexts.append(OCRHelper.recognizeText(from: uiImage))
                }
            }
            if !tempPagesData.isEmpty {
                // 【调用智能标题提取算法】
                let smartTitle = OCRHelper.extractSmartTitle(from: tempTexts)
                let finalTitle = smartTitle.isEmpty ? "导入文档 \(Date().formatted(date: .abbreviated, time: .shortened))" : smartTitle
                
                let newManual = Manual(title: finalTitle, createDate: Date(), pageCount: tempPagesData.count, pagesData: tempPagesData, recognizedTexts: tempTexts, equipmentName: smartTitle.isEmpty ? nil : smartTitle)
                
                DispatchQueue.main.async { withAnimation { self.store.manuals.insert(newManual, at: 0) }; self.isProcessing = false; self.selectedPhotos.removeAll() }
            } else { DispatchQueue.main.async { self.isProcessing = false; showSuccess("图片解析失败") } }
        }
    }
    
    private func showSuccess(_ msg: String) { alertMessage = msg; showAlert = true }
    
    var emptyState: some View {
        VStack(spacing: 25) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 70)).foregroundStyle(.linearGradient(colors: [.gray, .gray.opacity(0.4)], startPoint: .top, endPoint: .bottom))
            Text(searchText.isEmpty ? "没有任何归档" : "未搜索到相关内容").font(.title3).fontWeight(.bold)
            Text(searchText.isEmpty ? "数字化您的说明书\n智能提取商品名，一秒完成归档" : "换个关键词试试吧").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
    }
}

// MARK: - 6. 分类面板
struct CategoryListView: View {
    @ObservedObject var store: ManualStore; @Binding var searchText: String; @Environment(\.dismiss) var dismiss
    var groupedManuals: [String: [Manual]] { Dictionary(grouping: store.manuals, by: { guard let cat = $0.category, !cat.isEmpty else { return "未分类" }; return cat }) }
    var body: some View {
        NavigationView {
            List {
                ForEach(groupedManuals.keys.sorted(), id: \.self) { category in
                    Button(action: { searchText = category == "未分类" ? "" : category; dismiss() }) {
                        HStack {
                            Image(systemName: category == "未分类" ? "folder" : "folder.fill").foregroundColor(category == "未分类" ? .gray : .orange).font(.title2)
                            Text(category).font(.headline).foregroundColor(.primary); Spacer()
                            Text("\(groupedManuals[category]?.count ?? 0) 份").foregroundColor(.secondary).font(.subheadline)
                        }.padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("分类检索").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } } }
        }
    }
}

// MARK: - 7. 编辑属性面板 (内置高清搜图引擎)
struct EditManualInfoSheet: View {
    let manual: Manual; @ObservedObject var store: ManualStore; @Environment(\.dismiss) var dismiss
    @State private var title: String = ""; @State private var equipmentName: String = ""
    @State private var category: String = ""; @State private var tagsString: String = ""
    @State private var showSafari = false; @State private var searchURL: URL? = nil
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("基本信息")) {
                    TextField("文档标题 (必填)", text: $title)
                    HStack {
                        TextField("设备名称 (如: 激光切割机)", text: $equipmentName)
                        if !equipmentName.isEmpty {
                            Button(action: {
                                if let encoded = "\(equipmentName) 正视图".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: "https://cn.bing.com/images/search?q=\(encoded)") { searchURL = url; showSafari = true }
                            }) { Image(systemName: "photo.badge.magnifyingglass").foregroundColor(.blue).font(.title3) }.buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    TextField("设备类别 (如: 工业设备)", text: $category)
                }
                Section(header: Text("标签管理"), footer: Text("提示：如果想用网上的图片做封面，点击设备名称右侧的🔍图标，在弹出的网页里长按心仪的图片保存到相册，然后回首页长按卡片修改封面即可。")) {
                    TextField("标签 (如: 保修 危险)", text: $tagsString)
                }
            }
            .navigationTitle("编辑属性").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("保存") { saveChanges() }.fontWeight(.bold) }
            }
            .onAppear { title = manual.title; equipmentName = manual.equipmentName ?? ""; category = manual.category ?? ""; tagsString = (manual.tags ?? []).joined(separator: " ") }
            .sheet(isPresented: $showSafari) { if let url = searchURL { SafariView(url: url).ignoresSafeArea() } }
        }
    }
    private func saveChanges() {
        if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) {
            store.manuals[index].title = title.isEmpty ? "未命名说明书" : title; store.manuals[index].equipmentName = equipmentName.isEmpty ? nil : equipmentName; store.manuals[index].category = category.isEmpty ? nil : category
            let parsedTags = tagsString.replacingOccurrences(of: "，", with: ",").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter { !$0.isEmpty }
            store.manuals[index].tags = parsedTags.isEmpty ? nil : parsedTags
        }
        dismiss()
    }
}

// MARK: - 8. 说明书卡片
struct ManualCard: View {
    let manual: Manual
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let uiImage = manual.coverImage { Image(uiImage: uiImage).resizable().aspectRatio(3/4, contentMode: .fill).frame(maxWidth: .infinity).clipped().cornerRadius(12)
            } else { Rectangle().fill(Color.gray.opacity(0.2)).aspectRatio(3/4, contentMode: .fit).cornerRadius(12) }
            VStack(alignment: .leading, spacing: 6) {
                Text(manual.title).font(.system(size: 15, weight: .bold)).foregroundColor(.primary).lineLimit(1)
                if let category = manual.category, !category.isEmpty {
                    Text(category).font(.system(size: 10, weight: .semibold)).foregroundColor(.blue).padding(.horizontal, 6).padding(.vertical, 2).background(Color.blue.opacity(0.1)).cornerRadius(4)
                }
                if let tags = manual.tags, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 4) { ForEach(tags.prefix(3), id: \.self) { tag in Text("#\(tag)").font(.system(size: 10)).foregroundColor(.orange) } } }
                }
                HStack { Text("\(manual.pageCount) 页"); Spacer(); Text(manual.createDate, style: .date) }.font(.system(size: 11)).foregroundColor(.secondary)
            }.padding(.horizontal, 6)
        }.padding(10).background(Color.white).cornerRadius(18).shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

// MARK: - 9. 详情阅读器
struct ManualDetailView: View {
    let manual: Manual; @ObservedObject var store: ManualStore; var searchText: String
    @Environment(\.presentationMode) var presentationMode; @State private var currentPage = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("第 \(currentPage + 1) / \(manual.pagesData.count) 页").font(.subheadline).fontWeight(.medium).foregroundColor(.secondary).padding(.vertical, 8).padding(.horizontal, 16).background(Color(UIColor.secondarySystemBackground)).clipShape(Capsule())
                Spacer()
            }.padding(.top, 10).padding(.bottom, 5)
            TabView(selection: $currentPage) {
                ForEach(0..<manual.pagesData.count, id: \.self) { index in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 15) {
                            if let uiImage = UIImage(data: manual.pagesData[index]) { Image(uiImage: uiImage).resizable().scaledToFit().cornerRadius(12).shadow(radius: 5) }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text("页面识别内容").font(.caption).fontWeight(.bold).foregroundColor(.blue); Spacer(); if !searchText.isEmpty { Text("关键字高亮中").font(.caption2).foregroundColor(.orange) } }
                                Text(highlightedText(from: manual.recognizedTexts[index], search: searchText)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding().frame(maxWidth: .infinity, alignment: .topLeading).background(Color(UIColor.secondarySystemBackground)).cornerRadius(12)
                        }.padding()
                    }.tag(index)
                }
            }.tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        }
        .navigationTitle(manual.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(role: .destructive, action: { if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) { store.manuals.remove(at: index); presentationMode.wrappedValue.dismiss() } }) { Image(systemName: "trash").foregroundColor(.red) } } }
    }
    private func highlightedText(from text: String, search: String) -> AttributedString {
        var attrString = AttributedString(text); attrString.font = .system(size: 13, design: .monospaced); attrString.foregroundColor = .primary
        guard !search.isEmpty else { return attrString }
        let nsString = text as NSString; var searchRange = NSRange(location: 0, length: nsString.length)
        while searchRange.location < nsString.length {
            let foundRange = nsString.range(of: search, options: .caseInsensitive, range: searchRange)
            if foundRange.location != NSNotFound {
                if let swiftRange = Range(foundRange, in: text), let attrRange = Range(swiftRange, in: attrString) { attrString[attrRange].backgroundColor = .yellow; attrString[attrRange].foregroundColor = .black }
                searchRange.location = foundRange.location + foundRange.length; searchRange.length = nsString.length - searchRange.location
            } else { break }
        }
        return attrString
    }
}

// MARK: - 10. 扫描仪桥接
struct DocumentScannerBridge: UIViewControllerRepresentable {
    var store: ManualStore; @Binding var isProcessing: Bool; @Binding var processingText: String; @Environment(\.presentationMode) var presentationMode
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController { let scanner = VNDocumentCameraViewController(); scanner.delegate = context.coordinator; return scanner }
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        var parent: DocumentScannerBridge; init(_ parent: DocumentScannerBridge) { self.parent = parent }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.processingText = "正在解析并提取智能标题..."; parent.isProcessing = true; parent.presentationMode.wrappedValue.dismiss()
            DispatchQueue.global(qos: .userInitiated).async {
                var tempPagesData: [Data] = []; var tempTexts: [String] = []
                for i in 0..<scan.pageCount { let img = scan.imageOfPage(at: i); if let d = img.jpegData(compressionQuality: 0.7) { tempPagesData.append(d) }; tempTexts.append(OCRHelper.recognizeText(from: img)) }
                
                // 【调用智能标题提取算法】
                let smartTitle = OCRHelper.extractSmartTitle(from: tempTexts)
                let finalTitle = smartTitle.isEmpty ? "新扫描 \(Date().formatted(date: .abbreviated, time: .shortened))" : smartTitle
                
                let newManual = Manual(title: finalTitle, createDate: Date(), pageCount: scan.pageCount, pagesData: tempPagesData, recognizedTexts: tempTexts, equipmentName: smartTitle.isEmpty ? nil : smartTitle)
                
                DispatchQueue.main.async { withAnimation { self.parent.store.manuals.insert(newManual, at: 0) }; self.parent.isProcessing = false }
            }
        }
    }
}

struct ProcessingOverlay: View {
    var text: String
    var body: some View {
        ZStack { Color.black.opacity(0.3).ignoresSafeArea(); VStack(spacing: 15) { ProgressView().scaleEffect(1.5); Text(text).font(.headline).foregroundColor(.white) }.padding(30).background(.ultraThinMaterial).cornerRadius(20).colorScheme(.dark) }
    }
}
