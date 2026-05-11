import SwiftUI
import VisionKit
import Vision
import UniformTypeIdentifiers
import Combine
import PhotosUI

// MARK: - 1. 核心模型 (新增设备元数据)
struct Manual: Identifiable, Codable {
    var id = UUID()
    var title: String
    var createDate: Date
    var pageCount: Int
    var pagesData: [Data]
    var recognizedTexts: [String]
    var customCoverData: Data? 
    
    // 新增：结构化参数 (设为可选型，完美兼容旧数据)
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

// MARK: - 3. OCR 核心引擎
struct OCRHelper {
    static func recognizeText(from image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }
        var result = ""
        let request = VNRecognizeTextRequest { req, _ in
            let observations = req.results as? [VNRecognizedTextObservation] ?? []
            result = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        return result
    }
}

// MARK: - 4. 数据管理中心
class ManualStore: ObservableObject {
    @Published var manuals: [Manual] = [] {
        didSet { save() }
    }
    
    let savePath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ManualsBackup.json")
    
    init() { load() }
    
    func load() {
        if let data = try? Data(contentsOf: savePath),
           let decoded = try? JSONDecoder().decode([Manual].self, from: data) {
            manuals = decoded
        }
    }
    
    func save() {
        if let encoded = try? JSONEncoder().encode(manuals) {
            try? encoded.write(to: savePath)
        }
    }
    
    func restore(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Manual].self, from: data) else { return false }
        DispatchQueue.main.async { self.manuals = decoded }
        return true
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var fileURL: URL
    init(url: URL) { self.fileURL = url }
    init(configuration: ReadConfiguration) throws { fatalError("只用于导出") }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return try FileWrapper(url: fileURL, options: .immediate)
    }
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
    
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateDesc
    
    // 编辑属性页面状态
    @State private var manualToEdit: Manual? = nil
    
    let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    
    // 多维搜索引擎
    var filteredAndSortedManuals: [Manual] {
        var result = store.manuals
        if !searchText.isEmpty {
            result = result.filter { manual in
                let searchStr = searchText.lowercased()
                
                let matchTitle = manual.title.localizedCaseInsensitiveContains(searchStr)
                let matchText = manual.recognizedTexts.joined(separator: " ").localizedCaseInsensitiveContains(searchStr)
                let matchEquip = manual.equipmentName?.localizedCaseInsensitiveContains(searchStr) ?? false
                let matchCategory = manual.category?.localizedCaseInsensitiveContains(searchStr) ?? false
                let matchTags = manual.tags?.contains(where: { $0.localizedCaseInsensitiveContains(searchStr) }) ?? false
                
                return matchTitle || matchText || matchEquip || matchCategory || matchTags
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
                                NavigationLink(destination: ManualDetailView(manual: manual, store: store, searchText: searchText)) {
                                    ManualCard(manual: manual)
                                }
                                .contextMenu {
                                    Button { manualToChangeCover = manual } label: { Label("修改封面", systemImage: "photo.stack") }
                                    
                                    // 唤起完整编辑面板
                                    Button { manualToEdit = manual } label: { Label("编辑属性", systemImage: "info.circle") }
                                    
                                    Button(role: .destructive) {
                                        if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) {
                                            withAnimation { store.manuals.remove(at: index) }
                                        }
                                    } label: { Label("删除", systemImage: "trash") }
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 80)
                    }
                }
                
                PhotosPicker(selection: $selectedCoverItem, matching: .images, photoLibrary: .shared()) { EmptyView() }
                    .disabled(manualToChangeCover == nil)
                    .onChange(of: selectedCoverItem) { newItem in handleCoverSelection(item: newItem) }
                
                VStack {
                    Spacer()
                    HStack(spacing: 20) {
                        Button(action: { isScanning = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "camera.viewfinder").font(.system(size: 20, weight: .bold))
                                Text("扫描").fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 16).background(Color.blue).foregroundColor(.white).clipShape(Capsule())
                            .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                        }
                        
                        PhotosPicker(selection: $selectedPhotos, matching: .images, photoLibrary: .shared()) {
                            HStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle").font(.system(size: 20, weight: .bold))
                                Text("导入").fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 16).background(Color.indigo).foregroundColor(.white).clipShape(Capsule())
                            .shadow(color: .indigo.opacity(0.3), radius: 10, x: 0, y: 5)
                        }
                        .onChange(of: selectedPhotos) { newItems in handlePhotoImport(items: newItems) }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 20)
                }
            }
            .navigationTitle("说明书库")
            .searchable(text: $searchText, prompt: "搜索名称、设备、类别或内容...")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button(action: { store.save(); showExporter = true }) { Label("备份到 iCloud Drive", systemImage: "icloud.and.arrow.up") }
                        Button(action: { showImporter = true }) { Label("从 iCloud 恢复", systemImage: "icloud.and.arrow.down") }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("排序方式", selection: $sortOption) {
                            ForEach(SortOption.allCases, id: \.self) { option in Text(option.rawValue).tag(option) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down.circle").font(.title3) }
                }
            }
            .sheet(isPresented: $isScanning) { DocumentScannerBridge(store: store, isProcessing: $isProcessing, processingText: $processingText) }
            // 独立编辑面板
            .sheet(item: $manualToEdit) { manual in
                EditManualInfoSheet(manual: manual, store: store)
            }
            .fileExporter(isPresented: $showExporter, document: BackupDocument(url: store.savePath), contentType: .json, defaultFilename: "Manuals_Backup.json") { result in
                switch result { case .success: showSuccess("备份成功！") case .failure: break }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    if url.startAccessingSecurityScopedResource() {
                        if store.restore(from: url) { showSuccess("恢复成功！") } else { showSuccess("恢复失败：文件格式错误。") }
                        url.stopAccessingSecurityScopedResource()
                    }
                case .failure: showSuccess("读取文件失败")
                }
            }
            .alert(isPresented: $showAlert) { Alert(title: Text("系统提示"), message: Text(alertMessage), dismissButton: .default(Text("好的"))) }
            .overlay { if isProcessing { ProcessingOverlay(text: processingText) } }
        }
    }
    
    private func handleCoverSelection(item: PhotosPickerItem?) {
        guard let item = item, let manual = manualToChangeCover else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data),
               let compressed = uiImage.jpegData(compressionQuality: 0.6) {
                DispatchQueue.main.async {
                    if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) { store.manuals[index].customCoverData = compressed }
                    self.manualToChangeCover = nil; self.selectedCoverItem = nil
                }
            }
        }
    }

    private func handlePhotoImport(items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isProcessing = true; processingText = "正在分析相册图片..."
        Task {
            var tempPagesData: [Data] = []; var tempTexts: [String] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) {
                    if let compressed = uiImage.jpegData(compressionQuality: 0.7) { tempPagesData.append(compressed) }
                    tempTexts.append(OCRHelper.recognizeText(from: uiImage))
                }
            }
            if !tempPagesData.isEmpty {
                let newManual = Manual(title: "导入文档 \(Date().formatted(date: .abbreviated, time: .shortened))", createDate: Date(), pageCount: tempPagesData.count, pagesData: tempPagesData, recognizedTexts: tempTexts)
                DispatchQueue.main.async { withAnimation { self.store.manuals.insert(newManual, at: 0) }; self.isProcessing = false; self.selectedPhotos.removeAll() }
            } else {
                DispatchQueue.main.async { self.isProcessing = false; showSuccess("图片解析失败") }
            }
        }
    }
    
    private func showSuccess(_ msg: String) { alertMessage = msg; showAlert = true }
    
    var emptyState: some View {
        VStack(spacing: 25) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 70)).foregroundStyle(.linearGradient(colors: [.gray, .gray.opacity(0.4)], startPoint: .top, endPoint: .bottom))
            Text(searchText.isEmpty ? "没有任何归档" : "未搜索到相关内容").font(.title3).fontWeight(.bold)
            Text(searchText.isEmpty ? "数字化您的说明书\n长按卡片可编辑属性和封面" : "换个关键词试试吧").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
    }
}

// MARK: - 6. 编辑属性面板 (独立 Sheet)
struct EditManualInfoSheet: View {
    let manual: Manual
    @ObservedObject var store: ManualStore
    @Environment(\.dismiss) var dismiss
    
    @State private var title: String = ""
    @State private var equipmentName: String = ""
    @State private var category: String = ""
    @State private var tagsString: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("基本信息")) {
                    TextField("文档标题 (必填)", text: $title)
                    TextField("设备名称 (如: 激光切割机)", text: $equipmentName)
                    TextField("设备类别 (如: 工业设备)", text: $category)
                }
                
                Section(header: Text("标签管理"), footer: Text("多个标签请用空格或逗号隔开，方便日后精准搜索。")) {
                    TextField("标签 (如: 保修 危险 2026采购)", text: $tagsString)
                }
            }
            .navigationTitle("编辑属性")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { saveChanges() }
                        .fontWeight(.bold)
                }
            }
            .onAppear {
                title = manual.title
                equipmentName = manual.equipmentName ?? ""
                category = manual.category ?? ""
                tagsString = (manual.tags ?? []).joined(separator: " ")
            }
        }
    }
    
    private func saveChanges() {
        if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) {
            store.manuals[index].title = title.isEmpty ? "未命名说明书" : title
            store.manuals[index].equipmentName = equipmentName.isEmpty ? nil : equipmentName
            store.manuals[index].category = category.isEmpty ? nil : category
            
            // 解析标签，支持空格和逗号分割
            let parsedTags = tagsString
                .replacingOccurrences(of: "，", with: ",")
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .map(String.init)
                .filter { !$0.isEmpty }
            
            store.manuals[index].tags = parsedTags.isEmpty ? nil : parsedTags
        }
        dismiss()
    }
}

// MARK: - 7. 说明书卡片 (新增标签与类别展示)
struct ManualCard: View {
    let manual: Manual
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let uiImage = manual.coverImage {
                Image(uiImage: uiImage).resizable().aspectRatio(3/4, contentMode: .fill).frame(maxWidth: .infinity).clipped().cornerRadius(12)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2)).aspectRatio(3/4, contentMode: .fit).cornerRadius(12)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(manual.title).font(.system(size: 15, weight: .bold)).foregroundColor(.primary).lineLimit(1)
                
                // 元数据显示区域
                if let category = manual.category, !category.isEmpty {
                    Text(category)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1)).cornerRadius(4)
                }
                
                if let tags = manual.tags, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(tags.prefix(3), id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                
                HStack { Text("\(manual.pageCount) 页"); Spacer(); Text(manual.createDate, style: .date) }
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
        }
        .padding(10).background(Color.white).cornerRadius(18).shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

// MARK: - 8. 详情阅读器
struct ManualDetailView: View {
    let manual: Manual
    @ObservedObject var store: ManualStore
    var searchText: String
    @Environment(\.presentationMode) var presentationMode
    @State private var currentPage = 0
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("第 \(currentPage + 1) / \(manual.pagesData.count) 页")
                    .font(.subheadline).fontWeight(.medium).foregroundColor(.secondary)
                    .padding(.vertical, 8).padding(.horizontal, 16)
                    .background(Color(UIColor.secondarySystemBackground)).clipShape(Capsule())
                Spacer()
            }
            .padding(.top, 10).padding(.bottom, 5)
            
            TabView(selection: $currentPage) {
                ForEach(0..<manual.pagesData.count, id: \.self) { index in
                    VStack(spacing: 15) {
                        if let uiImage = UIImage(data: manual.pagesData[index]) {
                            Image(uiImage: uiImage).resizable().scaledToFit().cornerRadius(12).shadow(radius: 5).frame(maxHeight: UIScreen.main.bounds.height * 0.45)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("页面识别内容").font(.caption).fontWeight(.bold).foregroundColor(.blue)
                                Spacer()
                                if !searchText.isEmpty { Text("关键字高亮中").font(.caption2).foregroundColor(.orange) }
                            }
                            ScrollView {
                                Text(highlightedText(from: manual.recognizedTexts[index], search: searchText)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(UIColor.secondarySystemBackground)).cornerRadius(12)
                    }.padding().tag(index)
                }
            }.tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        }
        .navigationTitle(manual.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive, action: {
                    if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) {
                        store.manuals.remove(at: index); presentationMode.wrappedValue.dismiss()
                    }
                }) { Image(systemName: "trash").foregroundColor(.red) }
            }
        }
    }
    
    private func highlightedText(from text: String, search: String) -> AttributedString {
        var attrString = AttributedString(text)
        attrString.font = .system(size: 14); attrString.foregroundColor = .primary
        guard !search.isEmpty else { return attrString }
        let nsString = text as NSString
        var searchRange = NSRange(location: 0, length: nsString.length)
        while searchRange.location < nsString.length {
            let foundRange = nsString.range(of: search, options: .caseInsensitive, range: searchRange)
            if foundRange.location != NSNotFound {
                if let swiftRange = Range(foundRange, in: text), let attrRange = Range(swiftRange, in: attrString) {
                    attrString[attrRange].backgroundColor = .yellow; attrString[attrRange].foregroundColor = .black
                }
                searchRange.location = foundRange.location + foundRange.length; searchRange.length = nsString.length - searchRange.location
            } else { break }
        }
        return attrString
    }
}

// MARK: - 9. 扫描仪桥接
struct DocumentScannerBridge: UIViewControllerRepresentable {
    var store: ManualStore
    @Binding var isProcessing: Bool
    @Binding var processingText: String
    @Environment(\.presentationMode) var presentationMode
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController(); scanner.delegate = context.coordinator; return scanner
    }
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        var parent: DocumentScannerBridge
        init(_ parent: DocumentScannerBridge) { self.parent = parent }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.processingText = "正在解析中..."; parent.isProcessing = true; parent.presentationMode.wrappedValue.dismiss()
            DispatchQueue.global(qos: .userInitiated).async {
                var tempPagesData: [Data] = []; var tempTexts: [String] = []
                for i in 0..<scan.pageCount {
                    let img = scan.imageOfPage(at: i)
                    if let d = img.jpegData(compressionQuality: 0.7) { tempPagesData.append(d) }
                    tempTexts.append(OCRHelper.recognizeText(from: img))
                }
                let newManual = Manual(title: "新扫描 \(Date().formatted(date: .abbreviated, time: .shortened))", createDate: Date(), pageCount: scan.pageCount, pagesData: tempPagesData, recognizedTexts: tempTexts)
                DispatchQueue.main.async { withAnimation { self.parent.store.manuals.insert(newManual, at: 0) }; self.parent.isProcessing = false }
            }
        }
    }
}

struct ProcessingOverlay: View {
    var text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 15) { ProgressView().scaleEffect(1.5); Text(text).font(.headline).foregroundColor(.white) }.padding(30).background(.ultraThinMaterial).cornerRadius(20).colorScheme(.dark)
        }
    }
}
