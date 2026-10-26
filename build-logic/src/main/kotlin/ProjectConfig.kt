import org.gradle.api.Project

object ProjectConfig {
    const val APP_NAME = "Mishka"
    const val PACKAGE_NAME = "top.yukonga.mishka"
    const val VERSION_NAME = "1.0.0"

    object Android {
        const val TARGET_SDK = 37
        // 最低支持 Android 7.0（API 24）：高版本 API 必须做版本守卫，
        // 跨版本 IO 走 android.system.Os，不用 java.nio.file（脱糖兜底 java.time 等）。
        const val MIN_SDK = 24 // Android 7.0
        const val COMPILE_SDK = 37
        const val COMPILE_SDK_MINOR = 2
    }
}

private const val FALLBACK_VERSION_CODE = 1

/** 提交数作为 versionCode。调用方应只求值一次。 */
fun Project.getGitVersionCode(): Int =
    runCatching {
        providers.exec {
            commandLine("git", "rev-list", "--count", "HEAD")
            isIgnoreExitValue = true
        }.standardOutput.asText.get().trim().toInt()
    }.getOrElse {
        logger.warn("git rev-list failed (${it.message}); versionCode falls back to $FALLBACK_VERSION_CODE")
        FALLBACK_VERSION_CODE
    }
