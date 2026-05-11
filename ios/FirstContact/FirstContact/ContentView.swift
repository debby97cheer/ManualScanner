import SwiftUI
import VisionKit
import Vision
import UniformTypeIdentifiers // 用于文件导入导出
import Combine  // <--- 加上这一行，立刻解决报错！

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

// MARK: - 2. 数据管理中心
class ManualStore: ObservableObject {
    @Published var manuals: [Manual] = [] {
        didSet { save() }
    }
    
    // 本地存储路径
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
    
    // 从外部文件恢复数据
    func restore(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Manual].self, from: data) else {
            return false
        }
        DispatchQueue.main.async {
            self.manuals = decoded
        }
        return true
    }
}

// MARK: - 3. 自定义文件文档 (用于导出到 iCloud)
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var fileURL: URL
    
    init(url: URL) { self.fileURL = url }
    init(configuration: ReadConfiguration) throws { fatalError("只用于导出") }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return try FileWrapper(url: fileURL, options: .immediate)
    }
}

// MARK: - 4. 主界面 UI
struct ContentView: View {
    @StateObject var store = ManualStore()
    @State private var isScanning = false
    @State private var isProcessing = false
    
    // 备份与恢复状态
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                
                if store.manuals.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(store.manuals) { manual in
                                NavigationLink(destination: ManualDetailView(manual: manual, store: store)) {
                                    ManualCard(manual: manual)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                
                VStack {
                    Spacer()
                    Button(action: { isScanning = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.viewfinder").font(.system(size: 22, weight: .bold))
                            Text("扫描新说明书").fontWeight(.bold)
                        }
                        .padding(.vertical, 16).padding(.horizontal, 24)
                        .background(Color.blue).foregroundColor(.white).clipShape(Capsule())
                        .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                    }.padding(.bottom, 20)
                }
            }
            .navigationTitle("说明书库")
            .toolbar {
                // 左上角云备份菜单
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button(action: {
                            // 强制保存一次最新状态
                            store.save()
                            showExporter = true
                        }) {
                            Label("备份到 iCloud Drive", systemImage: "icloud.and.arrow.up")
                        }
                        Button(action: { showImporter = true }) {
                            Label("从 iCloud 恢复", systemImage: "icloud.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $isScanning) {
                DocumentScannerBridge(store: store, isProcessing: $isProcessing)
            }
            // 导出文件面板 (备份)
            .fileExporter(isPresented: $showExporter, document: BackupDocument(url: store.savePath), contentType: .json, defaultFilename: "Manuals_Backup_\(Date().formatted(.iso8601.year().month().day())).json") { result in
                switch result {
                case .success:
                    alertMessage = "备份成功！已保存至您选择的目录。"
                    showAlert = true
                case .failure(let error):
                    print(error)
                }
            }
            // 导入文件面板 (恢复)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    // 获取安全访问权限
                    if url.startAccessingSecurityScopedResource() {
                        if store.restore(from: url) {
                            alertMessage = "恢复成功！加载了 \(store.manuals.count) 份说明书。"
                        } else {
                            alertMessage = "恢复失败：文件格式不正确。"
                        }
                        url.stopAccessingSecurityScopedResource()
                    }
                    showAlert = true
                case .failure:
                    alertMessage = "读取文件失败"
                    showAlert = true
                }
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text("系统提示"), message: Text(alertMessage), dismissButton: .default(Text("好的")))
            }
            .overlay { if isProcessing { ProcessingOverlay() } }
        }
    }
    
    var emptyState: some View {
        VStack(spacing: 25) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 70)).foregroundStyle(.linearGradient(colors: [.gray, .gray.opacity(0.4)], startPoint: .top, endPoint: .bottom))
            Text("没有任何归档").font(.title3).fontWeight(.bold)
            Text("将各种产品的说明书数字化\n方便您随时随地查询使用").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
    }
}

// MARK: - 5. 说明书卡片组件
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
                HStack { Text("\(manual.pageCount) 页"); Spacer(); Text(manual.createDate, style: .date) }
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }.padding(.horizontal, 4)
        }.padding(10).background(Color.white).cornerRadius(18).shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

// MARK: - 6. 详情阅读器界面 (增加删除功能)
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
                            Text(manual.recognizedTexts[index]).font(.system(size: 14)).lineSpacing(5).foregroundColor(.primary)
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Color(UIColor.secondarySystemBackground)).cornerRadius(12)
                        Divider().padding(.vertical, 10)
                    }
                }
            }.padding()
        }
        .navigationTitle(manual.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive, action: {
                    if let index = store.manuals.firstIndex(where: { $0.id == manual.id }) {
                        store.manuals.remove(at: index)
                        presentationMode.wrappedValue.dismiss()
                    }
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
    }
}

// MARK: - 7. 扫描仪桥接逻辑
struct DocumentScannerBridge: UIViewControllerRepresentable {
    var store: ManualStore
    @Binding var isProcessing: Bool
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
            parent.isProcessing = true; parent.presentationMode.wrappedValue.dismiss()
            DispatchQueue.global(qos: .userInitiated).async {
                var tempPagesData: [Data] = []; var tempTexts: [String] = []
                for i in 0..<scan.pageCount {
                    let img = scan.imageOfPage(at: i)
                    if let d = img.jpegData(compressionQuality: 0.7) { tempPagesData.append(d) }
                    tempTexts.append(self.ocr(img))
                }
                let newManual = Manual(title: "说明书 \(Date().formatted(date: .abbreviated, time: .shortened))", createDate: Date(), pageCount: scan.pageCount, pagesData: tempPagesData, recognizedTexts: tempTexts)
                DispatchQueue.main.async { self.parent.store.manuals.insert(newManual, at: 0); self.parent.isProcessing = false }
            }
        }

        private func ocr(_ image: UIImage) -> String {
            guard let cgImage = image.cgImage else { return "" }
            var result = ""
            let request = VNRecognizeTextRequest { req, _ in
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                result = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
            request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: cgImage).perform([request])
            return result
        }
    }
}

struct ProcessingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 15) { ProgressView().scaleEffect(1.5); Text("AI 正在解析排版...").font(.headline).foregroundColor(.white) }.padding(30).background(.ultraThinMaterial).cornerRadius(20).colorScheme(.dark)
        }
    }
}
