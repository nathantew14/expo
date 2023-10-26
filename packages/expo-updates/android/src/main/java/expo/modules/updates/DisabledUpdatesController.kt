package expo.modules.updates

import android.content.Context
import android.os.Bundle
import android.util.Log
import com.facebook.react.ReactInstanceManager
import expo.modules.kotlin.exception.CodedException
import expo.modules.updates.launcher.Launcher
import expo.modules.updates.launcher.NoDatabaseLauncher
import expo.modules.updates.statemachine.UpdatesStateContext

class UpdatesDisabledException(message: String) : CodedException(message)

class DisabledUpdatesController(context: Context, private val fatalException: Exception?) : IUpdatesController {
  private var isStarted = false
  private var launcher: Launcher? = null
  private var isLoaderTaskFinished = false

  override var isEmergencyLaunch = false
    private set

  /**
   * Returns the path on disk to the launch asset (JS bundle) file for the React Native host to use.
   * Blocks until the configured timeout runs out, or a new update has been downloaded and is ready
   * to use (whichever comes sooner). ReactNativeHost.getJSBundleFile() should call into this.
   *
   * If this returns null, something has gone wrong and expo-updates has not been able to launch or
   * find an update to use. In (and only in) this case, `getBundleAssetName()` will return a nonnull
   * fallback value to use.
   */
  @get:Synchronized
  override val launchAssetFile: String?
    get() {
      while (!isLoaderTaskFinished) {
        try {
          (this as java.lang.Object).wait()
        } catch (e: InterruptedException) {
          Log.e(TAG, "Interrupted while waiting for launch asset file", e)
        }
      }
      return launcher?.launchAssetFile
    }

  /**
   * Returns the filename of the launch asset (JS bundle) file embedded in the APK bundle, which can
   * be read using `context.getAssets()`. This is only nonnull if `getLaunchAssetFile` is null and
   * should only be used in such a situation. ReactNativeHost.getBundleAssetName() should call into
   * this.
   */
  override val bundleAssetName: String?
    get() = launcher?.bundleAssetName

  override fun onDidCreateReactInstanceManager(reactInstanceManager: ReactInstanceManager) {}

  @Synchronized
  override fun start(context: Context) {
    if (isStarted) {
      return
    }
    isStarted = true

    launcher = NoDatabaseLauncher(context, fatalException)
    isEmergencyLaunch = fatalException != null
    notifyController()
    return
  }

  override fun getConstantsForModule(context: Context): UpdatesModuleConstants {
    return UpdatesModuleConstants(
      launchedUpdate = launcher?.launchedUpdate,
      embeddedUpdate = null,
      isEmergencyLaunch = isEmergencyLaunch,
      isEnabled = false,
      releaseChannel = "default", // TODO(wschurman)
      isUsingEmbeddedAssets = launcher?.isUsingEmbeddedAssets ?: false,
      runtimeVersion = null,
      checkOnLaunch = UpdatesConfiguration.CheckAutomaticallyConfiguration.NEVER,
      requestHeaders = mapOf(),
      localAssetFiles = launcher?.localAssetFiles
    )
  }

  override fun relaunchReactApplicationForModule(context: Context, callback: IUpdatesController.ModuleCallback<Unit>) {
    callback.onFailure(UpdatesDisabledException("You cannot reload when expo-updates is not enabled."))
  }

  override fun getNativeStateMachineContext(callback: IUpdatesController.ModuleCallback<UpdatesStateContext>) {
    callback.onFailure(UpdatesDisabledException("You cannot check for updates when expo-updates is not enabled."))
  }

  override fun checkForUpdate(
    context: Context,
    callback: IUpdatesController.ModuleCallback<CheckForUpdateResult>
  ) {
    callback.onFailure(UpdatesDisabledException("You cannot check for updates when expo-updates is not enabled."))
  }

  override fun fetchUpdate(
    context: Context,
    callback: IUpdatesController.ModuleCallback<FetchUpdateResult>
  ) {
    callback.onFailure(UpdatesDisabledException("You cannot fetch update when expo-updates is not enabled."))
  }

  override fun getExtraParams(callback: IUpdatesController.ModuleCallback<Bundle>) {
    callback.onFailure(UpdatesDisabledException("You cannot use extra params when expo-updates is not enabled."))
  }

  override fun setExtraParam(
    key: String,
    value: String?,
    callback: IUpdatesController.ModuleCallback<Unit>
  ) {
    callback.onFailure(UpdatesDisabledException("You cannot use extra params when expo-updates is not enabled."))
  }

  @Synchronized
  private fun notifyController() {
    if (launcher == null) {
      throw AssertionError("UpdatesController.notifyController was called with a null launcher, which is an error. This method should only be called when an update is ready to launch.")
    }
    isLoaderTaskFinished = true
    (this as java.lang.Object).notify()
  }

  companion object {
    private val TAG = DisabledUpdatesController::class.java.simpleName
  }
}
