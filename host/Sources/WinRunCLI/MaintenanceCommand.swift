import ArgumentParser
import Foundation
import WinRunShared

extension WinRunCLI {
    struct Maintenance: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Boot Windows VM in QEMU for interactive maintenance"
        )

        @Option(help: "Path to Windows disk image")
        var disk: String?

        mutating func run() throws {
            let diskPath = try resolveDiskPath()
            let paths = try resolveQEMUPaths(diskPath: diskPath)

            var args = buildBaseArgs(
                firmware: paths.firmware, nvram: paths.nvram, disk: diskPath)
            appendVirtIOArgs(to: &args, diskDir: diskPath.deletingLastPathComponent())

            print("Starting maintenance QEMU session...")
            print("Disk: \(diskPath.path)")
            print("Close the QEMU window when done.")

            let process = Process()
            process.executableURL = paths.binary
            process.arguments = args

            signal(SIGINT, SIG_IGN)
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler { process.terminate() }
            sigintSource.resume()

            try process.run()
            process.waitUntilExit()

            print("QEMU exited with code \(process.terminationStatus)")
        }

        private func resolveDiskPath() throws -> URL {
            let diskPath: URL
            if let custom = disk {
                diskPath = URL(fileURLWithPath: custom)
            } else {
                let appSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first!
                diskPath = appSupport.appendingPathComponent("WinRun/windows.img")
            }
            guard FileManager.default.fileExists(atPath: diskPath.path) else {
                throw WinRunError.notSupported(
                    feature: "No Windows disk image found at \(diskPath.path). "
                        + "Run setup first.")
            }
            return diskPath
        }

        private struct QEMUPaths {
            let binary: URL
            let firmware: URL
            let nvram: URL
        }

        private func resolveQEMUPaths(diskPath: URL) throws -> QEMUPaths {
            guard let qemu = findExecutable("qemu-system-aarch64") else {
                throw WinRunError.notSupported(
                    feature: "qemu-system-aarch64 not found. Install with: brew install qemu")
            }
            let qemuPrefix = qemu.deletingLastPathComponent().deletingLastPathComponent()
            let firmwarePath = qemuPrefix.appendingPathComponent(
                "share/qemu/edk2-aarch64-code.fd")
            guard FileManager.default.fileExists(atPath: firmwarePath.path) else {
                throw WinRunError.notSupported(
                    feature: "QEMU EFI firmware not found. Reinstall: brew reinstall qemu")
            }
            let nvramPath = diskPath.deletingPathExtension()
                .appendingPathExtension("qemu-nvram")
            if !FileManager.default.fileExists(atPath: nvramPath.path) {
                let varsTemplate = qemuPrefix.appendingPathComponent(
                    "share/qemu/edk2-arm-vars.fd")
                guard FileManager.default.fileExists(atPath: varsTemplate.path) else {
                    throw WinRunError.notSupported(
                        feature: "QEMU EFI vars template not found")
                }
                try FileManager.default.copyItem(at: varsTemplate, to: nvramPath)
            }
            return QEMUPaths(binary: qemu, firmware: firmwarePath, nvram: nvramPath)
        }

        private func buildBaseArgs(firmware: URL, nvram: URL, disk: URL) -> [String] {
            let cpuCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
            return [
                "-M", "virt,highmem=on",
                "-cpu", "host",
                "-accel", "hvf",
                "-m", "4096",
                "-smp", "\(cpuCount)",
                "-drive", "if=pflash,format=raw,file=\(firmware.path),readonly=on",
                "-drive", "if=pflash,format=raw,file=\(nvram.path)",
                "-device", "ramfb",
                "-device", "qemu-xhci",
                "-device", "usb-kbd",
                "-device", "usb-tablet",
                "-drive", "file=\(disk.path),if=virtio,format=raw,discard=on",
                "-nic", "user,model=virtio-net-pci,mac=52:54:00:12:34:56",
            ]
        }

        private func appendVirtIOArgs(to args: inout [String], diskDir: URL) {
            let virtioPath = diskDir.appendingPathComponent("virtio-win.iso")
            if FileManager.default.fileExists(atPath: virtioPath.path) {
                args += [
                    "-drive",
                    "file=\(virtioPath.path),media=cdrom,if=none,id=virtio,"
                        + "readonly=on,file.locking=off",
                    "-device", "usb-storage,drive=virtio",
                ]
            }
        }

        private func findExecutable(_ name: String) -> URL? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            proc.arguments = [name]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = (String(bytes: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
    }
}
