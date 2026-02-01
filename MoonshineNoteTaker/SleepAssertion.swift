import Foundation
import IOKit.pwr_mgt

struct SleepAssertion {
    private static var assertionID: IOPMAssertionID = 0
    private static var assertionSuccess: IOReturn?

    /// Disables automatic system and display sleep.
    static func disableSleep(reason: String = "Keeping the screen and system awake for a task") {
        guard assertionSuccess == nil else { return }

        // Create an assertion to prevent display sleep
        assertionSuccess = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )

        // Create an assertion to prevent idle sleep (system sleep)
        // Note: kIOPMAssertionTypeNoIdleSleep might be needed for full system sleep prevention
        // The kIOPMAssertionTypeNoDisplaySleep also helps prevent idle sleep in many cases

        if assertionSuccess == kIOReturnSuccess {
            print("Sleep prevention assertion created successfully.")
        } else {
            print("Failed to create sleep prevention assertion. Error: \(assertionSuccess ?? kIOReturnError)")
        }
    }

    /// Re-enables automatic system and display sleep.
    static func enableSleep() {
        if assertionSuccess != nil {
            _ = IOPMAssertionRelease(assertionID)
            assertionSuccess = nil
            print("Sleep prevention assertion released. System can now sleep normally.")
        }
    }
}
