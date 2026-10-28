import CoreGraphics
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import GRPCProtobuf

typealias EmulatorTransport = HTTP2ClientTransport.TransportServices
typealias EmulatorClient = Android_Emulation_Control_EmulatorController.Client<EmulatorTransport>

/// A 1080x2400 RGBA frame is about 9.9 MiB, and 1440x3120 is about 17 MiB on the bytes fallback; the default 4 MiB limit would reject both.
private let maxResponseBytes = 64 * 1024 * 1024
private let shutDownTimeout: Duration = .seconds(3)

private struct BearerTokenInterceptor: ClientInterceptor {
    let token: String

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.addString("Bearer \(token)", forKey: "authorization")
        return try await next(request, context)
    }
}

/// Single consumer: the input pump is the only caller of `next()`.
private final class InputQueue: @unchecked Sendable {
    private var iterator: AsyncStream<GRPCInputEvent>.AsyncIterator

    init(_ stream: AsyncStream<GRPCInputEvent>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> GRPCInputEvent? {
        await iterator.next()
    }
}

public actor EmulatorConnection {
    private let endpoint: EmulatorEndpoint
    private var grpc: GRPCClient<EmulatorTransport>?
    private var closed = false
    private var runTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private let inputQueue: InputQueue
    private nonisolated let inputContinuation: AsyncStream<GRPCInputEvent>.Continuation

    public init(endpoint: EmulatorEndpoint) {
        self.endpoint = endpoint
        let (stream, continuation) = AsyncStream.makeStream(of: GRPCInputEvent.self, bufferingPolicy: .bufferingNewest(512))
        inputQueue = InputQueue(stream)
        inputContinuation = continuation
    }

    public func connect() throws {
        _ = try connectedClient()
    }

    public func status() async throws -> EmulatorStatusSnapshot {
        let client = try connectedClient()
        let status = try await client.getStatus(.init(), options: callOptions())

        var displaySize: CGSize?
        var config = status.platformConfig
        for entry in status.hardwareConfig.entry where config[entry.key] == nil {
            config[entry.key] = entry.value
        }
        if let width = config["hw.lcd.width"].flatMap(Double.init),
           let height = config["hw.lcd.height"].flatMap(Double.init),
           width > 0, height > 0 {
            displaySize = CGSize(width: width, height: height)
        } else if let configurations = try? await client.getDisplayConfigurations(.init(), options: callOptions()),
                  let main = configurations.displays.first(where: { $0.display == 0 }) ?? configurations.displays.first,
                  main.width > 0, main.height > 0 {
            displaySize = CGSize(width: Double(main.width), height: Double(main.height))
        }
        return EmulatorStatusSnapshot(booted: status.booted, version: status.version, displaySize: displaySize)
    }

    public nonisolated func frames(
        maxPixelSize: CGSize,
        useSharedMemory: Bool = true
    ) -> AsyncThrowingStream<EmulatorFrame, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: EmulatorFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task {
            do {
                let client = try await self.emulatorClient()
                try await FramePipeline.run(
                    client: client,
                    maxPixelSize: maxPixelSize,
                    useSharedMemory: useSharedMemory,
                    options: Self.callOptions(),
                    continuation: continuation
                )
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public nonisolated func send(_ input: EmulatorInput) {
        inputContinuation.yield(InputEncoding.event(for: input))
    }

    public nonisolated func press(_ button: HardwareButton, phase: KeyPhase) {
        inputContinuation.yield(InputEncoding.buttonEvent(button, phase: phase))
    }

    public func rotate(to rotation: EmulatorRotation) async throws {
        let client = try connectedClient()
        var model = Android_Emulation_Control_PhysicalModelValue()
        model.target = .rotation
        model.value.data = [0, 0, rotation.zDegrees]
        _ = try await client.setPhysicalModel(model, options: callOptions())
    }

    /// The emulator often exits before it answers, so a dropped connection counts as success.
    public func shutDown() async throws {
        let client = try connectedClient()
        var state = Android_Emulation_Control_VmRunState()
        state.state = .shutdown
        var options = callOptions()
        options.timeout = shutDownTimeout
        do {
            _ = try await client.setVmState(state, options: options)
        } catch let error as RPCError where [.deadlineExceeded, .unavailable, .cancelled, .unknown].contains(error.code) {
        }
    }

    public func close() async {
        closed = true
        inputContinuation.finish()
        inputTask?.cancel()
        inputTask = nil
        grpc?.beginGracefulShutdown()
        let task = runTask
        grpc = nil
        runTask = nil
        task?.cancel()
        await task?.value
    }

    private func emulatorClient() throws -> EmulatorClient {
        try connectedClient()
    }

    private func connectedClient() throws -> EmulatorClient {
        if closed { throw CancellationError() }
        if let grpc {
            return Android_Emulation_Control_EmulatorController.Client(wrapping: grpc)
        }
        let transport = try HTTP2ClientTransport.TransportServices(
            target: .ipv4(address: endpoint.host, port: endpoint.port),
            transportSecurity: .plaintext
        )
        let interceptors: [any ClientInterceptor] = endpoint.token.map { [BearerTokenInterceptor(token: $0)] } ?? []
        let client = GRPCClient(transport: transport, interceptors: interceptors)
        grpc = client
        runTask = Task { try? await client.runConnections() }
        let emulator = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
        startInputPump(emulator)
        return emulator
    }

    private func startInputPump(_ client: EmulatorClient) {
        let queue = inputQueue
        let options = Self.callOptions()
        inputTask = Task {
            while !Task.isCancelled, let first = await queue.next() {
                do {
                    _ = try await client.streamInputEvent(options: options, requestProducer: { writer in
                        try await writer.write(first)
                        while let event = await queue.next() {
                            try await writer.write(event)
                        }
                    })
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    private func callOptions() -> CallOptions { Self.callOptions() }

    private nonisolated static func callOptions() -> CallOptions {
        var options = CallOptions.defaults
        options.maxResponseMessageBytes = maxResponseBytes
        return options
    }
}
