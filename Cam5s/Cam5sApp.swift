import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import UIKit

// MARK: - 1. App Entry Point
@main
struct Cam5sApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - 2. Authentic 2013 Apple A7 ISP Texture & Color Pipeline
final class ISP5sPipeline {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    
    func processTo5sTexture(rawOrBaseImage: CIImage, hdrEnabled: Bool = false) -> Data? {
        var img = rawOrBaseImage
        let originalExtent = img.extent
        
        // Step 1: Downscale to exact iPhone 5s 8MP resolution (3264 x 2448 / 2448 x 3264)
        let targetLongSide: CGFloat = 3264.0
        let currentLongSide = max(originalExtent.width, originalExtent.height)
        let scale = targetLongSide / currentLongSide
        
        if scale < 1.0 {
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = img
            lanczos.scale = Float(scale)
            lanczos.aspectRatio = 1.0
            img = lanczos.outputImage ?? img
        }
        let extent = img.extent
        
        // Step 2: 2013 Apple ISP Chroma Noise Reduction + Slight Watercolor Micro-Smudge on Foliage/Rocks
        let median = CIFilter.median()
        median.inputImage = img
        let denoisedBase = median.outputImage ?? img
        
        let lumaBlend = CIFilter.luminosityBlendMode()
        lumaBlend.inputImage = img
        lumaBlend.backgroundImage = denoisedBase
        img = lumaBlend.outputImage ?? img
        
        // Step 3: Single-Exposure Tone Curve (No Smart HDR shadow lift; deep mossy rocks & natural sky roll-off)
        let toneCurve = CIFilter.toneCurve()
        toneCurve.inputImage = img
        toneCurve.point0 = CGPoint(x: 0.00, y: 0.01)
        toneCurve.point1 = CGPoint(x: 0.25, y: hdrEnabled ? 0.23 : 0.18) // Crushed shadows like 5s single frame
        toneCurve.point2 = CGPoint(x: 0.50, y: 0.48)
        toneCurve.point3 = CGPoint(x: 0.75, y: 0.78)
        toneCurve.point4 = CGPoint(x: 1.00, y: 0.97)
        img = toneCurve.outputImage ?? img
        
        // Step 4: iPhone 5s Color Science (Cool cyan-tinted overcast skies, muted earthy olive greens)
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = img
        colorMatrix.rVector = CIVector(x: 0.96, y: 0.02, z: 0.00, w: 0)
        colorMatrix.gVector = CIVector(x: 0.01, y: 0.96, z: 0.02, w: 0)
        colorMatrix.bVector = CIVector(x: 0.00, y: 0.03, z: 1.02, w: 0)
        img = colorMatrix.outputImage ?? img
        
        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = img
        colorControls.saturation = 0.87
        colorControls.contrast = 1.05
        img = colorControls.outputImage ?? img
        
        // Step 5: Shadow-Weighted 1.5µm Pixel Luminance Grain (Hits dark foliage/rocks, keeps sky clean)
        if let noiseImg = CIFilter.randomGenerator().outputImage?.cropped(to: extent) {
            let monoNoise = CIFilter.colorMatrix()
            monoNoise.inputImage = noiseImg
            monoNoise.rVector = CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0)
            monoNoise.gVector = CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0)
            monoNoise.bVector = CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0)
            monoNoise.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.05)
            
            let lumaMask = CIFilter.colorControls()
            lumaMask.inputImage = img
            lumaMask.saturation = 0.0
            
            let invertMask = CIFilter.colorInvert()
            invertMask.inputImage = lumaMask.outputImage
            
            if let grain = monoNoise.outputImage, let mask = invertMask.outputImage {
                let maskedGrain = CIFilter.blendWithMask()
                maskedGrain.inputImage = grain
                maskedGrain.backgroundImage = CIImage.empty().cropped(to: extent)
                maskedGrain.maskImage = mask
                
                let softLight = CIFilter.softLightBlendMode()
                softLight.inputImage = maskedGrain.outputImage
                softLight.backgroundImage = img
                img = softLight.outputImage?.cropped(to: extent) ?? img
            }
        }
        
        // Step 6: 5-Element f/2.2 Optical Softness + Classic Radius Unsharp Mask
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = img
        blur.radius = 0.45
        img = blur.outputImage?.cropped(to: extent) ?? img
        
        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = img
        unsharp.radius = 1.4
        unsharp.intensity = 0.48
        img = unsharp.outputImage?.cropped(to: extent) ?? img
        
        // Step 7: Authentic 2013 JPEG Compression (0.85 quality creates subtle 8x8 DCT macroblock texture)
        guard let cgImage = context.createCGImage(img, from: extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    }
}

// MARK: - 3. Hardware Camera Engine (Disables Deep Fusion & Smart HDR)
final class CameraEngine: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.cam5s.session", qos: .userInitiated)
    private let isp = ISP5sPipeline()
    
    @Published var isFlashOn = false
    @Published var isHDROn = false
    @Published var isSquareMode = false
    @Published var isCapturing = false
    @Published var lastThumbnail: UIImage?
    @Published var focusPoint: CGPoint?
    
    private var currentPosition: AVCaptureDevice.Position = .back
    private var currentDevice: AVCaptureDevice?
    
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.sessionQueue.async { self.configureSession() } }
            }
        default: break
        }
    }
    
    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo // Native 4:3 sensor readout
        
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }
        
        currentDevice = device
        
        if let _ = try? device.lockForConfiguration() {
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = false
            }
            device.setExposureTargetBias(-0.2, completionHandler: nil)
            device.unlockForConfiguration()
        }
        
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) {
            session.addOutput(output)
            // Force .speed to bypass Apple's Deep Fusion neural sharpening
            output.maxPhotoQualityPrioritization = .speed
        }
        
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
    }
    
    func focusAndExpose(at devicePoint: CGPoint, viewPoint: CGPoint) {
        DispatchQueue.main.async { self.focusPoint = viewPoint }
        sessionQueue.async {
            guard let device = self.currentDevice,
                  let _ = try? device.lockForConfiguration() else { return }
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.setExposureTargetBias(-0.2, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }
    
    func flipCamera() {
        currentPosition = (currentPosition == .back) ? .front : .back
        sessionQueue.async { self.configureSession() }
    }
    
    func capturePhoto() {
        DispatchQueue.main.async { self.isCapturing = true }
        
        sessionQueue.async {
            let settings: AVCapturePhotoSettings
            
            if let rawFormat = self.output.availableRawPhotoPixelFormatTypes.first {
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            } else if self.output.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
                settings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            } else {
                settings = AVCapturePhotoSettings()
            }
            
            settings.photoQualityPrioritization = .speed
            
            if let device = self.currentDevice, device.isFlashAvailable {
                settings.flashMode = self.isFlashOn ? .on : .off
            }
            
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        defer { DispatchQueue.main.async { self.isCapturing = false } }
        guard error == nil else { return }
        
        var baseCIImage: CIImage?
        let orientation = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32 ?? 6
        
        if photo.isRawPhoto, let rawData = photo.fileDataRepresentation() {
            let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: nil)
            rawFilter?.luminanceNoiseReductionAmount = 0.0
            rawFilter?.colorNoiseReductionAmount = 0.35
            rawFilter?.sharpnessAmount = 0.15
            rawFilter?.localToneMapAmount = 0.0
            baseCIImage = rawFilter?.outputImage?.oriented(forExifOrientation: Int32(orientation))
        } else if let pixelBuffer = photo.pixelBuffer {
            baseCIImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(forExifOrientation: Int32(orientation))
        } else if let data = photo.fileDataRepresentation() {
            baseCIImage = CIImage(data: data)?.oriented(forExifOrientation: Int32(orientation))
        }
        
        guard var ciImg = baseCIImage else { return }
        
        if isSquareMode {
            let side = min(ciImg.extent.width, ciImg.extent.height)
            let cropRect = CGRect(
                x: ciImg.extent.origin.x + (ciImg.extent.width - side) / 2.0,
                y: ciImg.extent.origin.y + (ciImg.extent.height - side) / 2.0,
                width: side,
                height: side
            )
            ciImg = ciImg.cropped(to: cropRect)
        }
        
        guard let jpegData = isp.processTo5sTexture(rawOrBaseImage: ciImg, hdrEnabled: isHDROn),
              let finalUIImage = UIImage(data: jpegData) else { return }
        
        DispatchQueue.main.async {
            self.lastThumbnail = finalUIImage
        }
        
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: jpegData, options: nil)
            })
        }
    }
}

// MARK: - 4. Classic iOS 7 / iPhone 5s Camera UI
struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @State private var showFocusBox = false
    
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Top iOS 7 Black Bar
                HStack {
                    Button {
                        engine.isFlashOn.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 15))
                            Text(engine.isFlashOn ? "On" : "Off")
                                .font(.system(size: 13, weight: .regular))
                        }
                        .foregroundColor(engine.isFlashOn ? Color(red: 1.0, green: 0.8, blue: 0.0) : .white)
                    }
                    
                    Spacer()
                    
                    Button {
                        engine.isHDROn.toggle()
                    } label: {
                        Text(engine.isHDROn ? "HDR On" : "HDR Off")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(engine.isHDROn ? Color(red: 1.0, green: 0.8, blue: 0.0) : .white)
                    }
                    
                    Spacer()
                    
                    Button {
                        engine.flipCamera()
                    } label: {
                        Image(systemName: "camera.rotate")
                            .font(.system(size: 18, weight: .light))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 20)
                .frame(height: 46)
                .background(Color.black)
                
                // 4:3 or 1:1 Viewfinder Frame
                ZStack {
                    CameraPreviewView(engine: engine) { _ in
                        showFocusBox = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                            showFocusBox = false
                        }
                    }
                    
                    if showFocusBox, let pt = engine.focusPoint {
                        Rectangle()
                            .stroke(Color(red: 1.0, green: 0.8, blue: 0.0), lineWidth: 1.2)
                            .frame(width: 72, height: 72)
                            .position(pt)
                    }
                    
                    if engine.isCapturing {
                        Color.black.opacity(0.88).ignoresSafeArea()
                    }
                }
                .frame(
                    width: geo.size.width,
                    height: engine.isSquareMode ? geo.size.width : geo.size.width * (4.0 / 3.0)
                )
                .clipped()
                .animation(.easeInOut(duration: 0.2), value: engine.isSquareMode)
                
                // Bottom iOS 7 Control Deck
                VStack(spacing: 16) {
                    // Sliding Mode Bar
                    HStack(spacing: 28) {
                        Button {
                            engine.isSquareMode = false
                        } label: {
                            Text("PHOTO")
                                .font(.system(size: 12, weight: engine.isSquareMode ? .medium : .bold))
                                .foregroundColor(engine.isSquareMode ? .white.opacity(0.5) : Color(red: 1.0, green: 0.8, blue: 0.0))
                        }
                        
                        Button {
                            engine.isSquareMode = true
                        } label: {
                            Text("SQUARE")
                                .font(.system(size: 12, weight: engine.isSquareMode ? .bold : .medium))
                                .foregroundColor(engine.isSquareMode ? Color(red: 1.0, green: 0.8, blue: 0.0) : .white.opacity(0.5))
                        }
                    }
                    .padding(.top, 12)
                    
                    Spacer()
                    
                    // Shutter & Thumbnail Bar
                    HStack {
                        Group {
                            if let thumb = engine.lastThumbnail {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color(white: 0.14)
                            }
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                        
                        Spacer()
                        
                        Button {
                            engine.capturePhoto()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(Color.white, lineWidth: 5)
                                    .frame(width: 66, height: 66)
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 52, height: 52)
                            }
                        }
                        
                        Spacer()
                        
                        Image(systemName: "camera.filters")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 48, height: 48)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
            .background(Color.black.ignoresSafeArea())
        }
        .statusBar(hidden: true)
        .onAppear {
            engine.start()
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let engine: CameraEngine
    var onTap: (CGPoint) -> Void
    
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = engine.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.onTap = { viewPt, devicePt in
            engine.focusAndExpose(at: devicePt, viewPoint: viewPt)
            onTap(viewPt)
        }
        return view
    }
    
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint, CGPoint) -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let viewPoint = gesture.location(in: self)
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        onTap?(viewPoint, devicePoint)
    }
}
