import SwiftUI

struct TransferManagerView: View {
    @State private var selectedTransferType: TransferType = .download
    
    enum TransferType: String, CaseIterable, Identifiable {
        case download = "下載"
        case upload = "上傳"
        var id: Self { self }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Unified top picker for Transfer Type
            HStack {
                Spacer()
                Picker("傳輸類型", selection: $selectedTransferType) {
                    ForEach(TransferType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .padding(.top, 16)
                Spacer()
            }
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
                .padding(.top, 10)
            
            // Sub-view presentation
            if selectedTransferType == .download {
                DownloadManagerView()
            } else {
                UploadManagerView()
            }
        }
    }
}
