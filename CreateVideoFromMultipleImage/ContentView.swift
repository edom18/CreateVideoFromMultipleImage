//
//  ContentView.swift
//  CreateVideoFromMultipleImage
//
//  Created by Kazuya Hiruma on 2025/11/24.
//

import SwiftUI
import AVKit
import AVFoundation

struct ContentView: View {
    @State private var message: String?
    @State private var videoURL: URL?

    private let exporter: ImageToVideoWithAutioExporter = .init()

    var body: some View {
        VStack {
            Text("連番動画クリエーター")
            Button("動画を作成する") {
                Task {
                    await createVideo()
                }
            }
            .padding()
            
            Text(message ?? "")
            
            if message != nil {
                Button("動画を再生") {
                    if let urlString = message, let url = URL(string: urlString) {
                        videoURL = url
                    }
                }
                .frame(width: 150,height: 45)
                .background(Color.blue)
                .foregroundStyle(Color.white)
                .cornerRadius(10.0)
                .padding()
            }
            
            if let videoURL = videoURL {
                VideoPlayer(player: AVPlayer(url: videoURL))
                    .frame(height: 300)
                Button("閉じる") {
                    self.videoURL = nil
                }
                .padding()
            }
        }
        .padding()
    }
    
    private func createVideo() async {
        // 1) 連番画像をDL
        let images = loadSequenceImages(prefix: "image", count: 299)

        // 2) 音声DL
        guard let audioURL = getAudioURL() else {
            return
        }

        // 3) 動画化（出力は一時URL）
        exporter.createVideoWithAudio(from: images, audioURL: audioURL, fps: 30) { success, outputURL in
            if success {
                print("Completed creating video.")
                
                Task { @MainActor in
                    self.message = "✅ 動画を保存しました：\n\(String(describing: outputURL))"
                    if let outputURL {
                        self.message = outputURL.absoluteString
                    }
                }
            }
        }
    }
    
    private func loadSequenceImages(prefix: String, count: Int) -> [UIImage] {
        return (1...count).compactMap { index in
            let name = String(format: "%@%03d.png", prefix, index)
            
            return UIImage(named: name)
        }
    }
    
    private func getAudioURL() -> URL?{
        guard let audioURL = Bundle.main.url(forResource: "BGM", withExtension: "mp3") else {
            print("ファイルが見つかりません")
            return nil
        }
        
        return audioURL
    }
}

#Preview {
    ContentView()
}
