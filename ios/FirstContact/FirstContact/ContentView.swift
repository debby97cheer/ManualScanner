import SwiftUI
import VisionKit
import Vision
import UniformTypeIdentifiers
import Combine
import PhotosUI

// MARK: - 1. 核心模型
struct Manual: Identifiable, Codable {
    var id = UUID()
    var title: String
    var createDate: Date
    var pageCount: Int
    var pagesData: [Data]
    var recognizedTexts: [String]
    
    var coverImage: UIImage? {
        guard let first = pagesData.first else { return nil }
        return UIImage(data: first)
    }
}

// MARK: - 2. 排序选项枚举
enum SortOption: String, CaseIterable {
    case dateDesc = "最新添加"
    case dateAsc = "最早添加"
    case titleAsc = "名称排序"
}

// MARK: - 3. OCR 核心引擎 (独立出来供相册和相机共用)
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
    
    // 云备份与恢复
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    // 相册多图导入
    @State private var selectedPhotos: [PhotosPickerItem] = []
    
    // 搜索、排序与重命名
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateDesc
    @State private var manualToRename: Manual? = nil
    @State private var newManualName = ""
    @State private var showRenameAlert = false
    
    let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    
    // 计算属性：过滤和排序
    var filteredAndSortedManuals: [Manual] {
        var result = store.manuals
        
        // 全文搜索：匹配标题，或者底层的 OCR 正文
        if !searchText.isEmpty {
            result = result.filter { manual in
                manual.title.localizedCaseInsensitiveContains(searchText) ||
                manual.recognizedTexts.joined(separator: " ").localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // 排序
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
                                NavigationLink(destination: ManualDetailView(manual: manual, store: store)) {
                                    ManualCard(manual: manual)
                                }
                                // 添加上下文菜单：长按卡片触发重命名或删除
                                .contextMenu {
                                    Button {
                                        manualToRename = manual
                                        newManualName = manual.title
                                        showRenameAlert = true
                                    } label: {
                                        Label("重命名", systemImage: "pencil")
                                    }
                                    
                                    Button(role: .destructive) {
                                        if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) {
                                            withAnimation { store.manuals.remove(at: index) }
                                        }
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 80) // 给底部悬浮按钮留出空间
                    }
                }
                
                // 底部悬浮双操作按钮
                VStack {
                    Spacer()
                    HStack(spacing: 20) {
                        // 1. 扫描按钮
                        Button(action: { isScanning = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "camera.viewfinder").font(.system(size: 20, weight: .bold))
                                Text("扫描").fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                        }
                        
                        // 2. 相册导入按钮 (支持多选照片)
                        PhotosPicker(selection: $selectedPhotos, matching: .images, photoLibrary: .shared()) {
                            HStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle").font(.system(size: 20, weight: .bold))
                                Text("导入").fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.indigo)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .shadow(color: .indigo.opacity(0.3), radius: 10, x: 0, y: 5)
                        }
                        .onChange(of: selectedPhotos) { newItems in
                            handlePhotoImport(items: newItems)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("说明书库")
            .searchable(text: $searchText, prompt: "搜索名称或文档内容...")
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
                            ForEach(SortOption.allCases, id: \.self) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle").font(.title3)
                    }
                }
            }
            .sheet(isPresented: $isScanning) {
                DocumentScannerBridge(store: store, isProcessing: $isProcessing, processingText: $processingText)
            }
            .fileExporter(isPresented: $showExporter, document: BackupDocument(url: store.savePath), contentType: .json, defaultFilename: "Manuals_Backup.json") { result in
                switch result { case .success: showSuccess("备份成功！") case .failure: break }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    if url.startAccessingSecurityScopedResource() {
                        if store.restore(from: url) { showSuccess("恢复成功！加载了 \(store.manuals.count) 份说明书。") } else { showSuccess("恢复失败：文件格式错误。") }
                        url.stopAccessingSecurityScopedResource()
                    }
                case .failure: showSuccess("读取文件失败")
                }
            }
            // 重命名弹窗
            .alert("重命名说明书", isPresented: $showRenameAlert) {
                TextField("新名称", text: $newManualName)
                Button("取消", role: .cancel) { manualToRename = nil }
                Button("保存") {
                    if let manual = manualToRename, !newManualName.isEmpty {
                        if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) {
                            store.manuals[index].title = newManualName
                        }
                    }
                    manualToRename = nil
                }
            }
            .alert(isPresented: $showAlert) { Alert(title: Text("系统提示"), message: Text(alertMessage), dismissButton: .default(Text("好的"))) }
            .overlay { if isProcessing { ProcessingOverlay(text: processingText) } }
        }
    }
    
    // 处理相册图片导入的核心逻辑
    private func handlePhotoImport(items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isProcessing = true
        processingText = "正在分析相册图片..."
        
        Task {
            var tempPagesData: [Data] = []
            var tempTexts: [String] = []
            
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    if let compressed = uiImage.jpegData(compressionQuality: 0.7) {
                        tempPagesData.append(compressed)
                    }
                    tempTexts.append(OCRHelper.recognizeText(from: uiImage))
                }
            }
            
            if !tempPagesData.isEmpty {
                let newManual = Manual(
                    title: "导入图片 \(Date().formatted(date: .abbreviated, time: .shortened))",
                    createDate: Date(),
                    pageCount: tempPagesData.count,
                    pagesData: tempPagesData,
                    recognizedTexts: tempTexts
                )
                DispatchQueue.main.async {
                    withAnimation { self.store.manuals.insert(newManual, at: 0) }
                    self.isProcessing = false
                    self.selectedPhotos.removeAll() // 清空选择
                }
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
            Text(searchText.isEmpty ? "将各类设备的说明书数字化\n（如激光切割机、冲孔设备等）\n方便随时查阅与管理" : "换个关键词试试吧").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
    }
}

// MARK: - 6. 说明书卡片组件
struct ManualCard: View {
    let manual: Manual
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let uiImage = manual.coverImage {
                Image(uiImage: uiImage).resizable().aspectRatio(3/4, contentMode: .fill).frame(maxWidth: .infinity).clipped().cornerRadius(12)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2)).aspectRatio(3/4, contentMode: .fit).cornerRadius(12)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(manual.title).font(.system(size: 16, weight: .bold)).foregroundColor(.primary).lineLimit(1)
                HStack { Text("\(manual.pageCount) 页"); Spacer(); Text(manual.createDate, style: .date) }.font(.system(size: 12)).foregroundColor(.secondary)
            }.padding(.horizontal, 4)
        }.padding(10).background(Color.white).cornerRadius(18).shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

// MARK: - 7. 详情阅读器界面
struct ManualDetailView: View {
    let manual: Manual
    @ObservedObject var store: ManualStore
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(0..<manual.pagesData.count, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 15) {
                        if let uiImage = UIImage(data: manual.pagesData[index]) {
                            Image(uiImage: uiImage).resizable().scaledToFit().cornerRadius(12).shadow(radius: 5)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("页面识别内容").font(.caption).fontWeight(.bold).foregroundColor(.blue)
                            // 支持文本选中与复制
                            Text(manual.recognizedTexts[index]).font(.system(size: 14)).lineSpacing(5).foregroundColor(.primary).textSelection(.enabled)
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Color(UIColor.secondarySystemBackground)).cornerRadius(12)
                    }
                }
            }.padding()
        }
        .navigationTitle(manual.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 8. 扫描仪桥接逻辑
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
            parent.processingText = "正在解析扫描件排版..."
            parent.isProcessing = true
            parent.presentationMode.wrappedValue.dismiss()
            
            DispatchQueue.global(qos: .userInitiated).async {
                var tempPagesData: [Data] = []; var tempTexts: [String] = []
                for i in 0..<scan.pageCount {
                    let img = scan.imageOfPage(at: i)
                    if let d = img.jpegData(compressionQuality: 0.7) { tempPagesData.append(d) }
                    tempTexts.append(OCRHelper.recognizeText(from: img))
                }
                let newManual = Manual(title: "说明书 \(Date().formatted(date: .abbreviated, time: .shortened))", createDate: Date(), pageCount: scan.pageCount, pagesData: tempPagesData, recognizedTexts: tempTexts)
                DispatchQueue.main.async { withAnimation { self.parent.store.manuals.insert(newManual, at: 0) }; self.parent.isProcessing = false }
            }
        }
    }
}

// MARK: - 9. 辅助加载视图
struct ProcessingOverlay: View {
    var text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 15) { ProgressView().scaleEffect(1.5); Text(text).font(.headline).foregroundColor(.white) }.padding(30).background(.ultraThinMaterial).cornerRadius(20).colorScheme(.dark)
        }
    }
}
