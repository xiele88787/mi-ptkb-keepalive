import Foundation
import CoreBluetooth
import CoreGraphics

setbuf(stdout, nil)
setbuf(stderr, nil)

final class FastReconnectBooster: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var timer: Timer?
    private let targetUUID = UUID(uuidString: "63F7CCA4-11D7-AEA3-9D8D-95A6007901A2")!
    private var lastReArmTime: TimeInterval = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        // Poll every 1.0s to check if peripheral is disconnected while user is present
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func getMouseAndAnyIdle() -> (anyIdle: Double, mouseIdle: Double, displayAsleep: Bool) {
        let anyIdle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!)
        let m1 = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let m2 = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown)
        let m3 = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .scrollWheel)
        let mouseIdle = min(m1, min(m2, m3))
        let dispAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        return (anyIdle, mouseIdle, dispAsleep)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        let found = central.retrievePeripherals(withIdentifiers: [targetUUID])
        if let p = found.first {
            peripheral = p
            p.delegate = self
            print("[cb-fast-reconnect] bound to Mi PTKB (63F7CCA4-...), initial state=\(p.state.rawValue)")
            if p.state != .connected {
                central.connect(p, options: nil)
                lastReArmTime = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    private func tick() {
        guard central.state == .poweredOn else { return }
        if peripheral == nil {
            let found = central.retrievePeripherals(withIdentifiers: [targetUUID])
            peripheral = found.first
            peripheral?.delegate = self
        }
        guard let p = peripheral else { return }

        // Only act when Mi PTKB is DISCONNECTED (in deep sleep or switched to 2.4G)
        guard p.state != .connected else { return }

        let (anyIdle, mouseIdle, displayAsleep) = getMouseAndAnyIdle()
        guard !displayAsleep else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastReArmTime

        // bluetoothd's FastConnectionScanTimer (LeConnectionScanHigh: window=0x30/interval=0x30, 100% duty cycle)
        // expires 5.999 seconds after a connect request.
        // When user recently moved the mouse (<60s) or screen is active, re-arm every 5.2s so LeConnectionScanHigh
        // stays at 100% duty cycle (0ms blind window) with zero battery cost to the sleeping keyboard!
        let reArmInterval = (mouseIdle < 60.0 || anyIdle < 60.0) ? 5.2 : 15.0
        if elapsed >= reArmInterval {
            central.cancelPeripheralConnection(p)
            central.connect(p, options: nil)
            lastReArmTime = now
            if mouseIdle < 5.0 {
                print(String(format: "[cb-fast-reconnect] re-armed LeConnectionScanHigh (100%% duty cycle 30ms/30ms) on mouse activity (mouse_idle=%.1fs)", mouseIdle))
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[cb-fast-reconnect] Mi PTKB connected! Triggering immediate GATT read to wake link")
        peripheral.discoverServices([CBUUID(string: "180F")])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let (_, _, displayAsleep) = getMouseAndAnyIdle()
        print("[cb-fast-reconnect] Mi PTKB entered deep sleep / disconnected. Arming fast reconnect scan...")
        if !displayAsleep {
            central.connect(peripheral, options: nil)
            lastReArmTime = ProcessInfo.processInfo.systemUptime
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svcs = peripheral.services else { return }
        for s in svcs {
            peripheral.discoverCharacteristics([CBUUID(string: "2A19")], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            peripheral.readValue(for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let val = characteristic.value, let first = val.first {
            print("[cb-fast-reconnect] GATT battery read complete: \(first)%%")
        }
    }
}

let booster = FastReconnectBooster()
RunLoop.main.run()
