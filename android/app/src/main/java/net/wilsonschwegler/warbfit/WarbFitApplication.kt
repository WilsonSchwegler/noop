package net.wilsonschwegler.warbfit

import android.app.Application

/**
 * Application entry point.
 *
 * WarbFit is a fully on-device WHOOP companion: it connects to the strap over BLE and
 * persists everything locally via Room. There is no network layer.
 *
 * This class is intentionally thin. The BLE client ([net.wilsonschwegler.warbfit.ble.WhoopBleClient]) and
 * the data layer ([net.wilsonschwegler.warbfit.data.WhoopRepository]) are owned and held by the
 * [net.wilsonschwegler.warbfit.ui.AppViewModel], scoped to the Activity, so they live exactly as long as
 * the UI that drives them. Put process-wide one-time setup (logging, crash hooks) here
 * if it is ever needed.
 */
class WarbFitApplication : Application()
