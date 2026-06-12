package net.wilsonschwegler.warbfit.ble

import java.util.UUID

/**
 * Which strap the user is pairing. They pick this before scanning so we look for
 * exactly one device family instead of guessing — a TRACKER 4.0 scan no longer
 * waits forever on a TRACKER 5/MG wrist, and vice versa.
 *
 * This is the user-facing choice; it is deliberately separate from the
 * protocol-layer DeviceFamily (which carries CRC/characteristic detail).
 */
enum class TrackerModel(val displayName: String, val service: UUID) {
    TRACKER4("TRACKER 4.0", TrackerBleClient.TRACKER4_SERVICE),
    TRACKER5_MG("TRACKER 5.0 / MG", TrackerBleClient.TRACKER5_SERVICE),
}
