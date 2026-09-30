package dev.keybridge.connect;

import static org.junit.Assert.*;

import android.app.Instrumentation;
import android.content.Intent;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.*;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.Test;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public final class ActionAuthenticationTest {
  final Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
  final UiDevice device = UiDevice.getInstance(instrumentation);

  void awaitCount(AtomicInteger count, int expected) throws Exception {
    long end = System.currentTimeMillis() + 10000;
    while (count.get() != expected && System.currentTimeMillis() < end) Thread.sleep(100);
    assertEquals(expected, count.get());
  }

  void choosePin() throws Exception {
    UiObject pin = device.findObject(new UiSelector().text("Use PIN"));
    if (pin.waitForExists(1500)) pin.click();
  }

  void confirmScreenLock() throws Exception {
    choosePin();
    UiObject input = device.findObject(new UiSelector().className("android.widget.EditText"));
    assertTrue("A fresh OS credential entry is required", input.waitForExists(10000));
    input.click();
    device.executeShellCommand("input text 123456");
    device.pressEnter();
  }

  @Test
  public void eachActionRequiresFreshAuthenticationAndCancellationSharesNothing() throws Exception {
    SheetPreviewActivity activity =
        (SheetPreviewActivity)
            instrumentation.startActivitySync(
                new Intent(instrumentation.getTargetContext(), SheetPreviewActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    AtomicInteger completed = new AtomicInteger(), cancelled = new AtomicInteger();
    ActionAuthentication[] auth = new ActionAuthentication[1];
    instrumentation.runOnMainSync(
        () -> {
          new AccountSheet(activity)
              .message("Authentication test", "Synthetic actions only", "Close", activity::finish);
          auth[0] = new ActionAuthentication(activity);
          auth[0].request(
              "Select account", completed::incrementAndGet, message -> cancelled.incrementAndGet());
        });
    confirmScreenLock();
    awaitCount(completed, 1);
    instrumentation.runOnMainSync(
        () ->
            auth[0].request(
                "Show password",
                completed::incrementAndGet,
                message -> cancelled.incrementAndGet()));
    choosePin();
    UiObject input = device.findObject(new UiSelector().className("android.widget.EditText"));
    assertTrue("Recent success must not skip the next prompt", input.waitForExists(10000));
    device.pressBack();
    if (input.waitUntilGone(1000) == false) device.pressBack();
    awaitCount(cancelled, 1);
    assertEquals("Cancel must not run the password action", 1, completed.get());
    instrumentation.runOnMainSync(
        () ->
            auth[0].request(
                "Copy password",
                completed::incrementAndGet,
                message -> cancelled.incrementAndGet()));
    confirmScreenLock();
    awaitCount(completed, 2);
    instrumentation.runOnMainSync(
        () -> {
          auth[0].cancel();
          activity.finish();
        });
  }
}
