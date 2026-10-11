import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.viora.viora"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.viora.viora"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 签名：CI 可通过环境变量注入正式证书；未设置时使用仓库内的测试证书。
    // 应用内更新要求新旧版本签名一致，所以测试包必须始终用同一个证书签名。
    signingConfigs {
        create("release") {
            val envStore = System.getenv("VIORA_KEYSTORE_PATH")
            storeFile = if (envStore.isNullOrBlank()) rootProject.file("keystore/viora-test.jks") else File(envStore)
            storePassword = System.getenv("VIORA_KEYSTORE_PASSWORD") ?: "viora-test"
            keyAlias = System.getenv("VIORA_KEY_ALIAS") ?: "viora"
            keyPassword = System.getenv("VIORA_KEY_PASSWORD") ?: "viora-test"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            signingConfig = signingConfigs.getByName("release")
        }
        getByName("profile") {
            // Flutter 在应用本文件前已从默认 debug 类型复制 profile；
            // 后续修改 debug 不会同步它的证书，必须显式设置以支持覆盖安装。
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    // Android TV 默认播放内核（docs/08-player.md）
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-ui:1.10.1")
}
