package top.yukonga.mishka.platform

import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * startForegroundService 是 API 26 才有的 API；API 24-25 没有后台启动服务的限制，
 * 直接 startService 即可（服务内部仍按原有逻辑调用 startForeground 挂前台通知）。
 */
internal fun Context.startForegroundServiceCompat(intent: Intent) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        startForegroundService(intent)
    } else {
        startService(intent)
    }
}
