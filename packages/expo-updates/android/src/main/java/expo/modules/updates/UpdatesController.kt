package expo.modules.updates

import android.content.Context
import android.os.Bundle
import com.facebook.react.ReactApplication
import com.facebook.react.ReactInstanceManager
import com.facebook.react.ReactNativeHost
import expo.modules.kotlin.exception.CodedException
import expo.modules.updates.db.entity.AssetEntity
import expo.modules.updates.db.entity.UpdateEntity
import expo.modules.updates.loader.LoaderTask
import expo.modules.updates.manifest.UpdateManifest
import expo.modules.updates.selectionpolicy.SelectionPolicy
import expo.modules.updates.statemachine.UpdatesStateContext
import java.util.Date

data class UpdatesModuleConstants(
  val launchedUpdate: UpdateEntity?,
  val embeddedUpdate: UpdateEntity?,
  val isEmergencyLaunch: Boolean,
  val isEnabled: Boolean,
  val releaseChannel: String,
  val isUsingEmbeddedAssets: Boolean,
  val runtimeVersion: String?,
  val checkOnLaunch: UpdatesConfiguration.CheckAutomaticallyConfiguration,
  val requestHeaders: Map<String, String>,
  val localAssetFiles: Map<AssetEntity, String>?,
)

sealed class CheckForUpdateResult(private val status: Status) {
  private enum class Status {
    NO_UPDATE_AVAILABLE,
    UPDATE_AVAILABLE,
    ROLL_BACK_TO_EMBEDDED,
    ERROR
  }

  class NoUpdateAvailable(val reason: LoaderTask.RemoteCheckResultNotAvailableReason) : CheckForUpdateResult(Status.NO_UPDATE_AVAILABLE)
  class UpdateAvailable(val updateManifest: UpdateManifest) : CheckForUpdateResult(Status.UPDATE_AVAILABLE)
  class RollBackToEmbedded(val commitTime: Date) : CheckForUpdateResult(Status.ROLL_BACK_TO_EMBEDDED)
  class ErrorResult(val error: Exception, val message: String) : CheckForUpdateResult(Status.ERROR)
}

sealed class FetchUpdateResult(private val status: Status) {
  private enum class Status {
    SUCCESS,
    FAILURE,
    ROLL_BACK_TO_EMBEDDED,
    ERROR
  }

  class Success(val update: UpdateEntity) : FetchUpdateResult(Status.SUCCESS)
  class Failure : FetchUpdateResult(Status.FAILURE)
  class RollBackToEmbedded : FetchUpdateResult(Status.ROLL_BACK_TO_EMBEDDED)
  class ErrorResult(val error: Exception) : FetchUpdateResult(Status.ERROR)
}

interface IUpdatesController {
  val isEmergencyLaunch: Boolean
  val launchAssetFile: String?
  val bundleAssetName: String?

  fun onDidCreateReactInstanceManager(reactInstanceManager: ReactInstanceManager)
  fun start(context: Context)

  interface ModuleCallback<T> {
    fun onSuccess(result: T)
    fun onFailure(exception: CodedException)
  }

  fun getConstantsForModule(context: Context): UpdatesModuleConstants
  fun relaunchReactApplicationForModule(context: Context, callback: ModuleCallback<Unit>)
  fun getNativeStateMachineContext(callback: ModuleCallback<UpdatesStateContext>)
  fun checkForUpdate(context: Context, callback: ModuleCallback<CheckForUpdateResult>) // TODO(wschurman) fix error type in CheckForUpdateResult
  fun fetchUpdate(context: Context, callback: ModuleCallback<FetchUpdateResult>) // TODO(wschurman) fix error type in CheckForUpdateResult
  fun getExtraParams(callback: ModuleCallback<Bundle>)
  fun setExtraParam(key: String, value: String?, callback: ModuleCallback<Unit>)
}

/**
 * Main entry point to expo-updates in normal release builds (development clients, including Expo
 * Go, use a different entry point). Singleton that keeps track of updates state, holds references
 * to instances of other updates classes, and is the central hub for all updates-related tasks.
 *
 * The `start` method in this class should be invoked early in the application lifecycle, via
 * [UpdatesPackage]. It delegates to an instance of [LoaderTask] to start the process of loading and
 * launching an update, then responds appropriately depending on the callbacks that are invoked.
 *
 * This class also provides getter methods to access information about the updates state, which are
 * used by the exported [UpdatesModule]. Such information includes
 * references to: the database, the [UpdatesConfiguration] object, the path on disk to the updates
 * directory, any currently active [LoaderTask], the current [SelectionPolicy], the error recovery
 * handler, and the current launched update. This class is intended to be the source of truth for
 * these objects, so other classes shouldn't retain any of them indefinitely.
 *
 * This class also optionally holds a reference to the app's [ReactNativeHost], which allows
 * expo-updates to reload JS and send events through the bridge.
 */
class UpdatesController {
  companion object {
    private var singletonInstance: IUpdatesController? = null
    @JvmStatic val instance: IUpdatesController
      get() {
        return checkNotNull(singletonInstance) { "UpdatesController.instance was called before the module was initialized" }
      }

    @JvmStatic fun initializeWithoutStarting(context: Context) {
      if (singletonInstance == null) {
        var updatesDirectoryException: Exception? = null
        val updatesDirectory = try {
          UpdatesUtils.getOrCreateUpdatesDirectory(context)
        } catch (e: Exception) {
          updatesDirectoryException = e
          null
        }

        singletonInstance = if (UpdatesConfiguration.canCreateValidConfiguration(context, null) && updatesDirectory != null) {
          val updatesConfiguration = UpdatesConfiguration(context, null)
          EnabledUpdatesController(context, updatesConfiguration, updatesDirectory)
        } else {
          DisabledUpdatesController(context, updatesDirectoryException)
        }
      }
    }

    @JvmStatic fun initializeAsDevLauncherWithoutStarting(context: Context): UpdatesDevLauncherController {
      check(singletonInstance == null) { "UpdatesController must not be initialized prior to calling initializeAsDevLauncherWithoutStarting" }

      var updatesDirectoryException: Exception? = null
      val updatesDirectory = try {
        UpdatesUtils.getOrCreateUpdatesDirectory(context)
      } catch (e: Exception) {
        updatesDirectoryException = e
        null
      }

      val initialUpdatesConfiguration = if (UpdatesConfiguration.canCreateValidConfiguration(context, null)) {
        UpdatesConfiguration(context, null)
      } else {
        null
      }
      val instance = UpdatesDevLauncherController(context, initialUpdatesConfiguration, updatesDirectory, updatesDirectoryException)
      singletonInstance = instance
      return instance
    }

    /**
     * Initializes the UpdatesController singleton. This should be called as early as possible in the
     * application's lifecycle.
     * @param context the base context of the application, ideally a [ReactApplication]
     */
    @JvmStatic fun initialize(context: Context) {
      if (singletonInstance == null) {
        initializeWithoutStarting(context)
        singletonInstance!!.start(context)
      }
    }

    /**
     * Initializes the UpdatesController singleton. This should be called as early as possible in the
     * application's lifecycle. Use this method to set or override configuration values at runtime
     * rather than from AndroidManifest.xml.
     * @param context the base context of the application, ideally a [ReactApplication]
     */
    @JvmStatic fun initialize(context: Context, configuration: Map<String, Any>) {
      if (singletonInstance == null) {
        var updatesDirectoryException: Exception? = null
        val updatesDirectory = try {
          UpdatesUtils.getOrCreateUpdatesDirectory(context)
        } catch (e: Exception) {
          updatesDirectoryException = e
          null
        }

        singletonInstance =
          if (UpdatesConfiguration.canCreateValidConfiguration(context, configuration) && updatesDirectory != null) {
            val updatesConfiguration = UpdatesConfiguration(context, configuration)
            EnabledUpdatesController(context, updatesConfiguration, updatesDirectory)
          } else {
            DisabledUpdatesController(context, updatesDirectoryException)
          }
        singletonInstance!!.start(context)
      }
    }
  }
}
