---
name: azud-module-creator
description: Creates a new Android module following VIPER + MVVM architecture with Protocols, ViewModel, Presenter, Interactor, Router, Activity, and Screen
disable-model-invocation: true
allowed-tools: Write Bash Read Glob Grep
---

# AZUD Module Creator

You are a Senior Android Developer creating a new VIPER module for the AZUD Kronos project.

## Step 1 — Gather Information

Before generating any code, ask the user these two questions and WAIT for their answers:

1. **Module Name:** What is the name of the module? (PascalCase, e.g., `NotificationsList`, `DeviceSettings`, `UserProfile`)
2. **Module Path:** What is the full filesystem path where the module should be created? (e.g., `app/src/main/java/com/softwareone/azudkronos/presentation/modules/bluetoohdevice/azudinfinity/notifications`)

Do NOT proceed until both answers are provided.

## Step 2 — Derive Naming

From the module name (e.g., `NotificationsList`), derive:
- **Prefix** = the module name as-is (e.g., `NotificationsList`)
- **Package** = derive from the filesystem path by converting the portion after `java/` to dot-separated package (e.g., `com.softwareone.azudkronos.presentation.modules.bluetoohdevice.azudinfinity.notifications`)
- **Log Tag** = a short bracket tag for Logger.log (e.g., `[NotificationsList]`)

Confirm the derived values with the user before proceeding.

## Step 3 — Generate Files

Create exactly these 6 files inside the module path:

```
<module_path>/
├── protocols/{Prefix}Protocols.kt
├── interactor/{Prefix}Interactor.kt
├── presenter/{Prefix}Presenter.kt
├── router/{Prefix}Router.kt
├── viewmodel/{Prefix}ViewModel.kt       (includes UiState, DialogState, and ViewModelFactory)
└── view/{Prefix}Activity.kt             (includes Screen composable and Preview)
```

### File 1: `protocols/{Prefix}Protocols.kt`

```kotlin
package {package}.protocols

interface {Prefix}ViewProtocol {
    fun showLoading(show: Boolean)
    fun showError(message: String)
}

interface {Prefix}PresenterProtocol {
    fun attach(view: {Prefix}ViewProtocol)
    fun detach()
    fun onBackClicked()
}

interface {Prefix}InteractorProtocol {
    // Add suspend functions for data operations here
}

interface {Prefix}RouterProtocol {
    fun goBack()
}
```

### File 2: `viewmodel/{Prefix}ViewModel.kt`

```kotlin
package {package}.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.softwareone.azudkronos.core.storage.Logger
import {package}.interactor.{Prefix}Interactor
import {package}.presenter.{Prefix}Presenter
import {package}.protocols.{Prefix}PresenterProtocol
import {package}.protocols.{Prefix}RouterProtocol
import {package}.protocols.{Prefix}ViewProtocol
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

data class {Prefix}UiState(
    val isLoading: Boolean = false,
    val activeDialog: {Prefix}DialogState = {Prefix}DialogState.None
)

sealed class {Prefix}DialogState {
    object None : {Prefix}DialogState()
    data class Error(val message: String) : {Prefix}DialogState()
}

class {Prefix}ViewModel(
    private val presenter: {Prefix}PresenterProtocol,
    private val router: {Prefix}RouterProtocol
) : ViewModel(), {Prefix}ViewProtocol {

    private val _uiState = MutableStateFlow({Prefix}UiState())
    val uiState: StateFlow<{Prefix}UiState> = _uiState.asStateFlow()

    init {
        presenter.attach(this)
    }

    fun onBackClicked() {
        presenter.onBackClicked()
    }

    fun onDialogDismissed() {
        _uiState.update { it.copy(activeDialog = {Prefix}DialogState.None) }
    }

    override fun showLoading(show: Boolean) {
        _uiState.update { it.copy(isLoading = show) }
    }

    override fun showError(message: String) {
        _uiState.update { it.copy(isLoading = false, activeDialog = {Prefix}DialogState.Error(message)) }
    }

    override fun onCleared() {
        super.onCleared()
        presenter.detach()
    }
}

class {Prefix}ViewModelFactory(
    private val router: {Prefix}RouterProtocol
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        val interactor = {Prefix}Interactor()
        val presenter = {Prefix}Presenter(interactor, router)
        return {Prefix}ViewModel(presenter, router) as T
    }
}
```

### File 3: `presenter/{Prefix}Presenter.kt`

```kotlin
package {package}.presenter

import com.softwareone.azudkronos.core.storage.Logger
import {package}.protocols.{Prefix}InteractorProtocol
import {package}.protocols.{Prefix}PresenterProtocol
import {package}.protocols.{Prefix}RouterProtocol
import {package}.protocols.{Prefix}ViewProtocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel

class {Prefix}Presenter(
    private val interactor: {Prefix}InteractorProtocol,
    private val router: {Prefix}RouterProtocol
) : {Prefix}PresenterProtocol {

    private var view: {Prefix}ViewProtocol? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun attach(view: {Prefix}ViewProtocol) {
        this.view = view
    }

    override fun detach() {
        this.view = null
        scope.cancel()
    }

    override fun onBackClicked() {
        router.goBack()
    }
}
```

### File 4: `interactor/{Prefix}Interactor.kt`

```kotlin
package {package}.interactor

import com.softwareone.azudkronos.core.storage.Logger
import {package}.protocols.{Prefix}InteractorProtocol
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class {Prefix}Interactor : {Prefix}InteractorProtocol {
    // Implement suspend functions from protocol here
    // All operations must use withContext(Dispatchers.IO)
    // Wrap in try/catch, return defaults on failure
}
```

### File 5: `router/{Prefix}Router.kt`

```kotlin
package {package}.router

import android.app.Activity
import com.softwareone.azudkronos.presentation.managers.NavigationManager
import {package}.protocols.{Prefix}RouterProtocol

class {Prefix}Router(private val activity: Activity) : {Prefix}RouterProtocol {

    override fun goBack() {
        NavigationManager.navigateBack(activity)
    }
}
```

### File 6: `view/{Prefix}Activity.kt`

```kotlin
package {package}.view

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.softwareone.azudkronos.R
import com.softwareone.azudkronos.core.base.BaseActivity
import com.softwareone.azudkronos.core.utils.fonts.RalewayTypography
import com.softwareone.azudkronos.presentation.components.topbar.AppTopBar
import {package}.router.{Prefix}Router
import {package}.viewmodel.{Prefix}DialogState
import {package}.viewmodel.{Prefix}UiState
import {package}.viewmodel.{Prefix}ViewModel
import {package}.viewmodel.{Prefix}ViewModelFactory

class {Prefix}Activity : BaseActivity() {

    private val viewModel: {Prefix}ViewModel by viewModels {
        {Prefix}ViewModelFactory(
            router = {Prefix}Router(this)
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val windowInsetsController = WindowCompat.getInsetsController(window, window.decorView)
        windowInsetsController.apply {
            hide(WindowInsetsCompat.Type.navigationBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        setContent {
            val density = LocalDensity.current
            val uiState by viewModel.uiState.collectAsState()
            androidx.compose.runtime.CompositionLocalProvider(
                LocalDensity provides Density(density.density, fontScale = 1.0f)
            ) {
                {Prefix}Screen(
                    context = this,
                    uiState = uiState,
                    onBackClicked = { viewModel.onBackClicked() },
                    onDialogDismissed = { viewModel.onDialogDismissed() }
                )
            }
        }
    }
}

@Composable
fun {Prefix}Screen(
    context: android.content.Context,
    uiState: {Prefix}UiState,
    onBackClicked: () -> Unit,
    onDialogDismissed: () -> Unit
) {
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(colorResource(R.color.azud_primary_light))
    ) {
        val screenHeight = maxHeight
        val screenWidth = maxWidth

        Column(modifier = Modifier.fillMaxSize()) {
            AppTopBar(
                context = context,
                height = screenHeight * 0.13f,
                isHomeView = false,
                onBackClicked = onBackClicked
            )

            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .weight(1f)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = screenWidth * 0.05f)
                ) {
                    Spacer(modifier = Modifier.height(screenHeight * 0.03f))

                    Text(
                        text = "{Prefix}",
                        style = RalewayTypography.titleMedium.copy(
                            fontWeight = FontWeight.Bold,
                            fontSize = (screenWidth.value * 0.055f).sp
                        ),
                        color = colorResource(R.color.azud_primary_a),
                        modifier = Modifier.padding(bottom = screenHeight * 0.02f)
                    )

                    // TODO: Add module-specific content here
                }

                if (uiState.isLoading) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(Color.Black.copy(alpha = 0.5f)),
                        contentAlignment = Alignment.Center
                    ) { SpinnerLoaderView() }
                }
            }
        }

        when (val dialog = uiState.activeDialog) {
            is {Prefix}DialogState.Error -> {
                androidx.compose.material.AlertDialog(
                    onDismissRequest = onDialogDismissed,
                    title = { Text("Error", style = RalewayTypography.labelMedium) },
                    text = { Text(dialog.message, style = RalewayTypography.bodySmall) },
                    confirmButton = {
                        androidx.compose.material.TextButton(onClick = onDialogDismissed) {
                            Text(
                                "Aceptar",
                                style = RalewayTypography.labelSmall,
                                color = colorResource(R.color.azud_primary_b)
                            )
                        }
                    }
                )
            }
            is {Prefix}DialogState.None -> Unit
        }
    }
}

@Preview(showBackground = true, backgroundColor = 0xFFF1F1F1)
@Composable
fun {Prefix}ScreenPreview() {
    {Prefix}Screen(
        context = androidx.compose.ui.platform.LocalContext.current,
        uiState = {Prefix}UiState(),
        onBackClicked = {},
        onDialogDismissed = {}
    )
}
```

## Step 4 — Register in AndroidManifest

After creating all files, add the Activity to `app/src/main/AndroidManifest.xml` near the other azudinfinity activities:

```xml
<activity
    android:name=".{package_dot_path_from_com}.view.{Prefix}Activity"
    android:theme="@style/Theme.AppCompat.Light.NoActionBar"
    android:screenOrientation="portrait"
    tools:ignore="LockedOrientation"
    />
```

## Step 5 — Summary

After generating all files, show the user:
1. List of all created files with their full paths
2. Reminder to add a `Destination` entry in `NavigationManager.kt` if navigation from other modules is needed
3. Reminder that the AndroidManifest was updated

## Rules

- NEVER leave functions without implementation (no empty bodies marked TODO)
- Use `Logger.log("{Log Tag} message")` for all logging
- Use `colorResource(R.color.*)` and `RalewayTypography` / `RobotoMonoTypography`
- Use `BoxWithConstraints` with `maxHeight`/`maxWidth` for responsive layouts
- Presenter must NOT use Android `Context`
- Interactor runs on `Dispatchers.IO`, catches all exceptions, returns safe defaults
- Router navigates exclusively through `NavigationManager`
- All naming must use the correct suffixes: `*Activity`, `*Screen`, `*ViewModel`, `*Presenter`, `*Interactor`, `*Router`, `*UiState`, `*DialogState`
