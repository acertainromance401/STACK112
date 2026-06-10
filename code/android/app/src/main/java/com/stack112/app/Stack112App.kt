package com.stack112.app

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

private enum class MainTab(
    val labelResId: Int,
    val bodyResId: Int
) {
    HOME(R.string.tab_home, R.string.screen_home),
    OCR(R.string.tab_ocr, R.string.screen_ocr),
    SEARCH(R.string.tab_search, R.string.screen_search),
    REVIEW(R.string.tab_review, R.string.screen_review),
    MYPAGE(R.string.tab_mypage, R.string.screen_mypage)
}

@Composable
fun Stack112App() {
    var selectedTab by rememberSaveable { mutableStateOf(MainTab.HOME) }

    MaterialTheme {
        Scaffold(
            bottomBar = {
                NavigationBar {
                    MainTab.entries.forEach { tab ->
                        NavigationBarItem(
                            selected = selectedTab == tab,
                            onClick = { selectedTab = tab },
                            label = { Text(text = stringResource(tab.labelResId)) },
                            icon = {}
                        )
                    }
                }
            }
        ) { innerPadding ->
            Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                TabScreen(
                    title = stringResource(R.string.android_title),
                    body = stringResource(selectedTab.bodyResId),
                    innerPadding = innerPadding
                )
            }
        }
    }
}

@Composable
private fun TabScreen(
    title: String,
    body: String,
    innerPadding: PaddingValues
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(innerPadding)
            .padding(horizontal = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 28.dp),
            textAlign = TextAlign.Center
        )
        Text(
            text = body,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 16.dp),
            textAlign = TextAlign.Center
        )
    }
}
