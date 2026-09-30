package dev.keybridge.connect;

import static org.junit.Assert.*;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.TextView;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.File;
import java.io.FileOutputStream;
import java.util.*;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public final class AccountSheetTest {
  final Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
  Activity activity;
  AccountSheet sheet;
  boolean selected, filled;

  void snapshot(String name) throws Exception {
    instrumentation.waitForIdleSync();
    Thread.sleep(250);
    instrumentation.runOnMainSync(
        () -> {
          View root = activity.getWindow().getDecorView();
          assertTrue(root.getWidth() > 0 && root.getHeight() > 0);
          Bitmap bitmap =
              Bitmap.createBitmap(root.getWidth(), root.getHeight(), Bitmap.Config.ARGB_8888);
          root.draw(new Canvas(bitmap));
          try (FileOutputStream output =
              new FileOutputStream(new File(activity.getCacheDir(), name + ".png"))) {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output);
          } catch (Exception e) {
            throw new AssertionError(e);
          }
          bitmap.recycle();
        });
  }

  View find(View root, String text) {
    if (root instanceof TextView && ((TextView) root).getText().toString().equals(text))
      return root;
    if (root instanceof ViewGroup)
      for (int i = 0; i < ((ViewGroup) root).getChildCount(); i++) {
        View match = find(((ViewGroup) root).getChildAt(i), text);
        if (match != null) return match;
      }
    return null;
  }

  EditText search(View root) {
    if (root instanceof EditText) return (EditText) root;
    if (root instanceof ViewGroup)
      for (int i = 0; i < ((ViewGroup) root).getChildCount(); i++) {
        EditText match = search(((ViewGroup) root).getChildAt(i));
        if (match != null) return match;
      }
    return null;
  }

  @Test
  public void searchSelectionConfirmationAndErrorScreens() throws Exception {
    activity =
        instrumentation.startActivitySync(
            new Intent(instrumentation.getTargetContext(), SheetPreviewActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    List<JSONObject> rows =
        List.of(
            Protocol.obj("title", "GitHub", "username", "shivansh@example.com"),
            Protocol.obj("title", "GitHub", "username", "work.account@example.com"),
            Protocol.obj(
                "title", "GitHub", "username", "a.long.account.name@engineering.example.com"));
    instrumentation.runOnMainSync(
        () -> {
          sheet = new AccountSheet(activity);
          sheet.accounts(
              "org.mozilla.firefox", "https://github.com", rows, row -> selected = true, null);
        });
    snapshot("picker-light");
    instrumentation.runOnMainSync(
        () -> {
          EditText input = search(sheet.body);
          input.requestFocus();
          activity
              .getSystemService(android.view.inputmethod.InputMethodManager.class)
              .showSoftInput(input, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT);
        });
    Thread.sleep(1200);
    snapshot("picker-search");
    instrumentation.runOnMainSync(
        () -> {
          android.graphics.Rect visible = new android.graphics.Rect();
          assertTrue(find(sheet.body, "shivansh@example.com").getGlobalVisibleRect(visible));
          assertTrue(visible.height() > 0);
          activity
              .getSystemService(android.view.inputmethod.InputMethodManager.class)
              .hideSoftInputFromWindow(search(sheet.body).getWindowToken(), 0);
        });

    instrumentation.runOnMainSync(
        () -> {
          search(sheet.body).setText("work.account");
          assertNotNull(find(sheet.body, "1 available account"));
          View row = find(sheet.body, "work.account@example.com");
          assertNotNull(row);
          ((View) row.getParent().getParent()).performClick();
          assertTrue(selected);
          search(sheet.body).setText("not-present");
          assertNotNull(find(sheet.body, "No matching accounts"));
        });
    snapshot("picker-empty");
    instrumentation.runOnMainSync(
        () ->
            sheet.confirm(
                rows.get(0),
                "org.mozilla.firefox",
                "https://github.com",
                true,
                remember -> filled = true,
                () -> {}));
    snapshot("picker-confirm");
    instrumentation.runOnMainSync(
        () -> {
          find(sheet.body, "Fill password").performClick();
          assertTrue(filled);
          sheet.message(
              "Couldn’t fill this time",
              "The request changed. Return to the website and select the password field again.",
              "Close",
              activity::finish);
        });
    snapshot("picker-error");
    instrumentation.runOnMainSync(activity::finish);
  }
}
