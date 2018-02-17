//
//  BluetoothManager.swift
//  xDripG5
//
//  Created by Nathan Racklyeft on 10/1/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import CoreBluetooth
import Foundation
import os.log


protocol BluetoothManagerDelegate: class {

    /**
     Tells the delegate that the bluetooth manager has finished connecting to and discovering all required services of its peripheral, or that it failed to do so

     - parameter manager: The bluetooth manager
     - parameter error:   An error describing why bluetooth setup failed
     */
    func bluetoothManager(_ manager: BluetoothManager, isReadyWithError error: Error?)

    /**
     Asks the delegate whether the discovered or restored peripheral should be connected

     - parameter manager:    The bluetooth manager
     - parameter peripheral: The found peripheral

     - returns: True if the peripheral should connect
     */
    func bluetoothManager(_ manager: BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral) -> Bool

    /// Tells the delegate that the bluetooth manager received new data in the control characteristic.
    ///
    /// - parameter manager:                   The bluetooth manager
    /// - parameter didReceiveControlResponse: The data received on the control characteristic
    func bluetoothManager(_ manager: BluetoothManager, didReceiveControlResponse response: Data)
}


class BluetoothManager: NSObject {

    var stayConnected = true

    weak var delegate: BluetoothManagerDelegate?

    private let log = OSLog(category: "BluetoothManager")

    private var manager: CBCentralManager! = nil

    private var peripheral: CBPeripheral? {
        get {
            return peripheralManager?.peripheral
        }
        set {
            guard let peripheral = newValue else {
                peripheralManager = nil
                return
            }

            if let peripheralManager = peripheralManager {
                peripheralManager.peripheral = peripheral
            } else {
                peripheralManager = PeripheralManager(
                    peripheral: peripheral,
                    configuration: .dexcomG5,
                    centralManager: manager
                )
            }
        }
    }

    var peripheralManager: PeripheralManager? {
        didSet {
            oldValue?.delegate = nil
            peripheralManager?.delegate = self
        }
    }

    // MARK: - GCD Management

    private let managerQueue = DispatchQueue(label: "com.loudnate.xDripG5.bluetoothManagerQueue", qos: .utility)

    override init() {
        super.init()

        manager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loudnate.xDripG5"])
    }

    // MARK: - Actions

    func scanForPeripheral(after delay: TimeInterval = 0) {
        guard manager.state == .poweredOn else {
            return
        }

        var connectOptions: [String: Any] = [:]

        #if swift(>=4.0.3)
        if #available(iOS 11.2, watchOS 4.1, *), delay > 0 {
            connectOptions[CBConnectPeripheralOptionStartDelayKey] = delay
        }
        #else
        connectOptions[""] = 0
        #endif

        if let peripheralID = self.peripheral?.identifier, let peripheral = manager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            log.info("Re-connecting to known peripheral %{public}@ in %.1f s", peripheral.identifier.uuidString, delay)
            self.peripheral = peripheral
            self.manager.connect(peripheral, options: connectOptions)
        } else if let peripheral = manager.retrieveConnectedPeripherals(withServices: [
                TransmitterServiceUUID.advertisement.cbUUID,
                TransmitterServiceUUID.cgmService.cbUUID
            ]).first, delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
            log.info("Found system-connected peripheral: %{public}@", peripheral.identifier.uuidString)
            self.peripheral = peripheral
            self.manager.connect(peripheral, options: connectOptions)
        } else {
            log.info("Scanning for peripherals")
            manager.scanForPeripherals(withServices: [
                    TransmitterServiceUUID.advertisement.cbUUID
                ],
                options: nil
            )
        }
    }

    func disconnect() {
        if manager.isScanning {
            manager.stopScan()
        }

        if let peripheral = peripheral {
            manager.cancelPeripheralConnection(peripheral)
        }
    }

    /**
    
     Persistent connections don't seem to work with the transmitter shutoff: The OS won't re-wake the
     app unless it's scanning.
     
     The sleep gives the transmitter time to shut down, but keeps the app running.

     */
    fileprivate func scanAfterDelay() {
        if #available(iOS 11.2, watchOS 4.1, *) {
            self.scanForPeripheral(after: TimeInterval(60 * 3))
        } else {
            DispatchQueue.global(qos: DispatchQoS.QoSClass.utility).async {
                Thread.sleep(forTimeInterval: 2)

                self.scanForPeripheral()
            }
        }
    }

    deinit {
        stayConnected = false
        disconnect()
    }

    // MARK: - Accessors

    var isScanning: Bool {
        return manager.isScanning
    }
}


extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        peripheralManager?.centralManagerDidUpdateState(central)

        switch central.state {
        case .poweredOn:
            scanForPeripheral()
        case .resetting, .poweredOff, .unauthorized, .unknown, .unsupported:
            if central.isScanning {
                central.stopScan()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                if delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
                    log.info("Restoring peripheral from state: %{public}@", peripheral.identifier.uuidString)
                    self.peripheral = peripheral
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
            self.peripheral = peripheral

            central.connect(peripheral, options: nil)

            central.stopScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if central.isScanning {
            central.stopScan()
        }

        peripheralManager?.centralManager(central, didConnect: peripheral)

        if case .poweredOn = manager.state, case .connected = peripheral.state {
            self.delegate?.bluetoothManager(self, isReadyWithError: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Ignore errors indicating the peripheral disconnected remotely, as that's expected behavior
        if let error = error as NSError?, CBError(_nsError: error).code != .peripheralDisconnected {
            log.error("%{public}@: %{public}@", #function, error)
            self.delegate?.bluetoothManager(self, isReadyWithError: error)
        }

        if stayConnected {
            scanAfterDelay()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            self.delegate?.bluetoothManager(self, isReadyWithError: error)
        }

        if stayConnected {
            scanAfterDelay()
        }
    }
}


extension BluetoothManager: PeripheralManagerDelegate {
    func peripheralManager(_ manager: PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {
        
    }

    func peripheralManagerDidUpdateName(_ manager: PeripheralManager) {

    }

    func completeConfiguration(for manager: PeripheralManager) throws {

    }

    func peripheralManager(_ manager: PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic) {
        guard let value = characteristic.value else {
            return
        }

        self.delegate?.bluetoothManager(self, didReceiveControlResponse: value)
    }
}
