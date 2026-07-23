import CoreMedia
import Foundation
import ScreenCaptureKit

// System-audio tap: captures EVERYTHING the system plays - regardless of
// which output device it goes to - and streams it as raw PCM (s16le, stereo,
// 44100 Hz) into a fifo, where an audio visualizer (cava's `raw` input)
// reads it. This is the macOS analogue of a PipeWire monitor source, and it
// replaces the loopback-driver + aggregate-output contraption: the real
// output device stays the default, so the hardware volume keys keep working
// and the visualization follows any output.
//
// ScreenCaptureKit delivers system audio under the Screen Recording
// permission of the RESPONSIBLE process - run this as a child of an app that
// holds the grant (the shell), not as a daemon.
final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    private let fifoPath: String
    private var stream: SCStream?
    private var fifoFd: Int32 = -1
    private let sampleRate = 44100

    init(fifoPath: String) {
        self.fifoPath = fifoPath
    }

    func run() -> Int32 {
        // The fifo is our contract with the reader; (re)create it so a stale
        // regular file from a crash never breaks the stream.
        unlink(self.fifoPath)
        guard mkfifo(self.fifoPath, 0o600) == 0 else {
            print("[audio-tap] cannot create fifo at \(self.fifoPath): \(String(cString: strerror(errno)))")
            return 1
        }

        // Open read-write so the open never blocks waiting for a reader and
        // the fifo survives the reader (cava) restarting.
        self.fifoFd = open(self.fifoPath, O_RDWR | O_NONBLOCK)
        guard self.fifoFd >= 0 else {
            print("[audio-tap] cannot open fifo: \(String(cString: strerror(errno)))")
            return 1
        }

        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) {
            content, error in
            guard let display = content?.displays.first, error == nil else {
                print(
                    "[audio-tap] no shareable content (Screen Recording permission?): \(error?.localizedDescription ?? "unknown")"
                )
                exit(1)
            }
            // Audio is what we want; SCK still requires a video-capable
            // filter, so capture the display at a token size and drop the
            // frames (no video output is ever attached).
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = self.sampleRate
            config.channelCount = 2
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            self.stream = stream
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
                stream.startCapture { startError in
                    if let startError {
                        print("[audio-tap] start failed: \(startError.localizedDescription)")
                        exit(1)
                    }
                    print("[audio-tap] streaming system audio -> \(self.fifoPath)")
                }
            } catch {
                print("[audio-tap] stream setup failed: \(error.localizedDescription)")
                exit(1)
            }
        }

        RunLoop.main.run()
        return 0
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcm = Self.interleavedS16(from: sampleBuffer) else { return }
        pcm.withUnsafeBytes { raw in
            // Non-blocking best-effort: with no reader (or a slow one) the
            // samples drop - a visualizer wants NOW, never a backlog.
            _ = Darwin.write(self.fifoFd, raw.baseAddress, raw.count)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[audio-tap] stream stopped: \(error.localizedDescription)")
        exit(1)
    }

    // SCK hands audio as (usually deinterleaved float32) CoreAudio buffers;
    // cava's raw input wants interleaved signed 16-bit. Pure conversion.
    static func interleavedS16(from sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let description = sampleBuffer.formatDescription,
            let asbd = description.audioStreamBasicDescription
        else { return nil }

        var bufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        var bufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)

        // A deinterleaved stereo buffer needs the two-buffer list; retry with
        // room for it.
        let buffers: UnsafeMutableAudioBufferListPointer
        var storage: UnsafeMutablePointer<AudioBufferList>?
        if status == noErr {
            buffers = UnsafeMutableAudioBufferListPointer(&bufferList)
        } else {
            storage = UnsafeMutablePointer<AudioBufferList>.allocate(
                capacity: bufferListSize / MemoryLayout<AudioBufferList>.size + 1)
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: storage!,
                bufferListSize: bufferListSize,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer) == noErr
            else {
                storage?.deallocate()
                return nil
            }
            buffers = UnsafeMutableAudioBufferListPointer(storage!)
        }
        defer { storage?.deallocate() }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat, !buffers.isEmpty else { return nil }

        func floatSamples(_ buffer: AudioBuffer) -> UnsafeBufferPointer<Float32> {
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            return UnsafeBufferPointer(
                start: buffer.mData?.assumingMemoryBound(to: Float32.self), count: count)
        }

        func clamp(_ value: Float32) -> Int16 {
            Int16(max(-1.0, min(1.0, value)) * 32767.0)
        }

        if buffers.count >= 2 {
            // Deinterleaved stereo: zip left/right.
            let left = floatSamples(buffers[0])
            let right = floatSamples(buffers[1])
            let frames = min(left.count, right.count)
            var out = [Int16](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                out[i * 2] = clamp(left[i])
                out[i * 2 + 1] = clamp(right[i])
            }
            return out
        }

        // Interleaved (or mono duplicated to both channels).
        let samples = floatSamples(buffers[0])
        if asbd.mChannelsPerFrame >= 2 {
            return samples.map(clamp)
        }
        var out = [Int16](repeating: 0, count: samples.count * 2)
        for i in 0..<samples.count {
            let v = clamp(samples[i])
            out[i * 2] = v
            out[i * 2 + 1] = v
        }
        return out
    }
}
