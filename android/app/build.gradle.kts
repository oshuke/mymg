plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mymg.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 17.x 需要 core library desugaring
        // （它把 java.time.* 用到了 desugared 形式以便支持老版本 Android）
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mymg.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_secure_storage 9.x 要求 minSdk >= 23（EncryptedSharedPreferences 用）
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ★ 只为 arm64-v8a 打包原生库（主力机小米 15 = 骁龙 8 Elite = 纯 arm64）。
        //
        //   即使加了 --target-platform android-arm64，某些插件自带的预编译
        //   so（libdartjni.so / libdatastore_shared_counter.so）仍会把自己的
        //   armeabi-v7a / x86_64 目录塞进 APK，后果有两个：
        //     1) 体积平白多出几百 KB；
        //     2) Android 误判本包支持 32 位 ARM，在 v7a 设备上"能装上但一启动就崩"。
        //   这里直接锁死 ABI，既瘦身也避免误装。
        //
        //   ⚠️ 若以后要用 x86_64 模拟器调试，临时在这行加上 "x86_64" 即可。
        ndk {
            abiFilters.add("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // ★ 双保险：上面 defaultConfig.ndk.abiFilters 管不到"插件以 jniLibs 形式
    //   预编译进来的 so"（如 libdartjni.so / libdatastore_shared_counter.so
    //   会把 armeabi-v7a / x86_64 目录一起带进来）。这里在打包阶段直接排除。
    //
    //   留着它们的坏处不只是白占 ~200KB：只要 APK 里出现 lib/armeabi-v7a/，
    //   Android 就会认为本包支持 32 位 ARM，在 v7a 设备上"能装上但一启动就崩"。
    packaging {
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/**",
                "lib/armeabi/**",
                "lib/x86/**",
                "lib/x86_64/**",
                "lib/mips/**",
                "lib/mips64/**",
            )
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
    // flutter_local_notifications 17.x 要求的 desugaring 库
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    // 小组件静默刷新广播里直接 enqueue WorkManager
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}
