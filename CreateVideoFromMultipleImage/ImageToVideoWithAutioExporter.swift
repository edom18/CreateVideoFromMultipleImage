//
//  ImageToVideoWithAutioExporter.swift
//  VideoCereatorSample
//
//  Created by Kazuya Hiruma on 2025/11/02.
//

import UIKit
import AVFoundation

/// 連番画像から動画を生成する
class ImageToVideoWithAutioExporter {
    func createVideoWithAudio(from images: [UIImage],
                              audioURL: URL,
                              fps: Int32,
                              completion: @escaping (Bool, URL?) -> Void) {
        guard let _ = images.first else {
            completion(false, nil)
            return
        }
        
        // 一時的な動画ファイルの URL（音声合成前）
        let tempOnlyVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_video.mov")
        try? FileManager.default.removeItem(at: tempOnlyVideoURL)

        // 一時的な動画ファイルの URL（音声合成後）
        let resultURL = FileManager.default.temporaryDirectory.appendingPathComponent("result.mov")
        try? FileManager.default.removeItem(at: resultURL)

        // Step 1. 画像のみの動画作成
        createVideo(from: images, fps: fps, outputURL: tempOnlyVideoURL) { success in
            guard success else {
                DispatchQueue.main.async { completion(false, nil) }
                return
            }
            
            Task {
                let videoAsset = AVURLAsset(url: tempOnlyVideoURL)
                let audioAsset = AVURLAsset(url: audioURL)
                
                do {
                    // Async/awaitでdurationを読み込み
                    let videoLength = try await videoAsset.load(.duration)
                    let audioLength = try await audioAsset.load(.duration)
                    let duration = CMTimeMinimum(videoLength, audioLength)
                    
                    let mixComposition = AVMutableComposition()
                    
                    // 映像トラック (modern async loading)
                    let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
                    guard let videoTrack = videoTracks.first else {
                        DispatchQueue.main.async { completion(false, nil) }
                        return
                    }
                    
                    let videoCompositionTrack = mixComposition.addMutableTrack(withMediaType: .video,
                                                                               preferredTrackID: kCMPersistentTrackID_Invalid)
                    
                    do {
                        try videoCompositionTrack?.insertTimeRange(
                            CMTimeRange(start: .zero, duration: videoLength),
                            of: videoTrack,
                            at: .zero
                        )
                    }
                    catch {
                        print("Failed to insert video track. \(error)")
                        DispatchQueue.main.async { completion(false, nil) }
                        return
                    }
                    
                    // 音声トラック
                    if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
                        let audioCompositionTrack = mixComposition.addMutableTrack(withMediaType: .audio,
                                                                                   preferredTrackID: kCMPersistentTrackID_Invalid)
                        
                        do {
                            try audioCompositionTrack?.insertTimeRange(
                                CMTimeRange(start: .zero, end: duration),
                                of: audioTrack,
                                at: .zero
                            )
                        }
                        catch {
                            print("Failed to insert audio track. \(error)")
                        }
                        
                        // 音声が短い場合 → 無音パディングを追加
                        if audioLength < videoLength {
                            let silenceDuration = videoLength - audioLength
                            let silenceTrack = mixComposition.addMutableTrack(withMediaType: .audio,
                                                                              preferredTrackID: kCMPersistentTrackID_Invalid)
                            // 空の音声トラックを追加（無音）
                            silenceTrack?.insertEmptyTimeRange(CMTimeRange(start: audioLength, duration: silenceDuration))
                        }
                    }
                    
                    // Step 3. 書き出し
                    try? FileManager.default.removeItem(at: resultURL)
                    guard let exporter = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality) else {
                        DispatchQueue.main.async { completion(false, nil) }
                        return
                    }
                    
                    do {
                        try await exporter.export(to: resultURL, as: .mov)
                        for await state in exporter.states(updateInterval: 0.2) {
                            switch state {
                            case .exporting(let progress):
                                let progressValue = progress.completedUnitCount / progress.totalUnitCount
                                print("In Progress \(progressValue)")
                            case .pending, .waiting:
                                print("Pending or Waiting to export")
                            default:
                                break
                            }
                        }
                        
                        guard let outputURL = self.saveVideoToDocuments(from: resultURL) else {
                            completion(false, nil)
                            return
                        }
                        
                        completion(true, outputURL)
                    }
                    catch {
                        print("Failed to export video file. \(error)")
                    }
                }
                catch {
                    print("Failed to load durations: \(error)")
                    DispatchQueue.main.async { completion(false, nil) }
                    return
                }
            }
        }
    }
    
    private func createVideo(from images: [UIImage], fps: Int32, outputURL: URL, completion: @escaping (Bool) -> Void) {
        guard let firstImage = images.first else {
            completion(false)
            return
        }
        let size = firstImage.size
        
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height
            ]
            let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput,
                                                               sourcePixelBufferAttributes: [
                                                                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)
                                                               ])
            
            writer.add(writerInput)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            
            let frameDuration = CMTime(value: 1, timescale: fps)
            var frameCount: Int64 = 0
            
            for image in images {
                while !writerInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
                if let buffer = pixelBuffer(from: image, size: size) {
                    adaptor.append(buffer, withPresentationTime: CMTime(value: frameCount, timescale: fps))
                }
                frameCount += 1
            }
            
            writerInput.markAsFinished()
            writer.finishWriting {
                completion(writer.status == .completed)
            }
        }
        catch {
            print("動画作成失敗: \(error)")
            completion(false)
        }
    }
    
    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32ARGB, attrs, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
        context?.translateBy(x: 0, y: size.height)
        context?.scaleBy(x: 1.0, y: -1.0)
        UIGraphicsPushContext(context!)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    
    func saveVideoToDocuments(from tempURL: URL) -> URL? {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        // ファイル名を日付でユニーク化
        let fileName = "video_\(Date().timeIntervalSince1970).mov"
        let destinationURL = documentsURL.appendingPathComponent(fileName)
        
        do {
            try fileManager.copyItem(at: tempURL, to: destinationURL)
            print("Saved a temp video to persistant folder. [\(destinationURL)]")
            return destinationURL
        }
        catch {
            print("Failed to save a temp video to persistant folder.")
            return nil
        }
    }
}
