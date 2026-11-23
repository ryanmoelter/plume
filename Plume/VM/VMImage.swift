import Foundation
import Virtualization

/// Turns a Tart VM directory (`config.json`, `disk.img`, `nvram.bin`) into a configuration our own
/// `VZVirtualMachine` boots. `docs/vm-testing.md` records the spike that proved it.
nonisolated enum VMImage {
    struct Failure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    static let worktreeShareName = "worktree"
    static let shareName = "share"

    /// `worktree` is shared read-only and `share` writable, both under `/Volumes/My Shared Files`.
    static func configuration(cloneDirectory: URL, worktree: URL?, share: URL) throws -> VZVirtualMachineConfiguration {
        let config = try TartVMConfig.parse(Data(contentsOf: cloneDirectory.appending(path: TartVMConfig.fileName)))

        let platform = VZMacPlatformConfiguration()
        guard let modelData = config.hardwareModelData, let model = VZMacHardwareModel(dataRepresentation: modelData) else {
            throw Failure(message: "\(cloneDirectory.lastPathComponent) has an unreadable hardwareModel")
        }
        guard model.isSupported else {
            throw Failure(message: "this Mac can't run \(cloneDirectory.lastPathComponent)'s hardware model")
        }
        platform.hardwareModel = model
        guard let ecid = config.ecidData, let identifier = VZMacMachineIdentifier(dataRepresentation: ecid) else {
            throw Failure(message: "\(cloneDirectory.lastPathComponent) has an unreadable ecid")
        }
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: cloneDirectory.appending(path: "nvram.bin"))

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = config.cpuCount
        configuration.memorySize = config.memorySize

        let disk = try VZDiskImageStorageDeviceAttachment(
            url: cloneDirectory.appending(path: "disk.img"), readOnly: false, cachingMode: .automatic, synchronizationMode: .full
        )
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        guard let mac = VZMACAddress(string: config.macAddress) else {
            throw Failure(message: "\(cloneDirectory.lastPathComponent) has an unreadable macAddress \(config.macAddress)")
        }
        network.macAddress = mac
        configuration.networkDevices = [network]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(
            widthInPixels: config.display.width, heightInPixels: config.display.height, pixelsPerInch: 72
        )]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        var directories = [shareName: VZSharedDirectory(url: share, readOnly: false)]
        if let worktree { directories[worktreeShareName] = VZSharedDirectory(url: worktree, readOnly: true) }
        let sharing = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        sharing.share = VZMultipleDirectoryShare(directories: directories)
        configuration.directorySharingDevices = [sharing]

        try configuration.validate()
        return configuration
    }
}
