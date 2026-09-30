package dev.keybridge.connect;

import static org.junit.Assert.*;

import android.accessibilityservice.AccessibilityService;
import android.app.UiAutomation;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.*;
import org.junit.Test;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public final class SystemFillTest {
  @Test
  public void deliberateAccessibilityFill() throws Exception {
    Configurator.getInstance()
        .setUiAutomationFlags(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
    UiAutomation automation =
        InstrumentationRegistry.getInstrumentation()
            .getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
    UiDevice device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
    device.executeShellCommand("settings delete secure enabled_accessibility_services");
    device.executeShellCommand(
        "settings put secure enabled_accessibility_services"
            + " dev.keybridge.connect/dev.keybridge.connect.KeybridgeAccessibilityService");
    Thread.sleep(2000);
    device.executeShellCommand(
        "settings put secure accessibility_button_targets"
            + " dev.keybridge.connect/dev.keybridge.connect.KeybridgeAccessibilityService");
    Thread.sleep(1000);
    device.executeShellCommand("am force-stop dev.keybridge.fixture");
    device.executeShellCommand("am start -n dev.keybridge.fixture/.LoginActivity");
    UiObject username =
        device.findObject(new UiSelector().resourceId("dev.keybridge.fixture:id/username"));
    assertTrue(username.waitForExists(10000));
    username.setText("dummy0");
    device.findObject(new UiSelector().resourceId("dev.keybridge.fixture:id/password")).click();
    Thread.sleep(1000);
    assertTrue(
        automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_ACCESSIBILITY_BUTTON));
    UiObject auth = device.findObject(new UiSelector().text("Unlock Keybridge Connect"));
    if (auth.waitForExists(4000)) {
      UiObject input = device.findObject(new UiSelector().className("android.widget.EditText"));
      input.click();
      device.executeShellCommand("input text 123456");
      device.pressEnter();
    }
    UiObject row = device.findObject(new UiSelector().textContains("FIXTURE 1"));
    assertTrue(row.waitForExists(10000));
    row.click();
    UiObject fill = device.findObject(new UiSelector().text("Fill password"));
    assertTrue(fill.waitForExists(5000));
    fill.click();
    assertTrue(
        device
            .findObject(new UiSelector().text("Local fill verified; nothing submitted"))
            .waitForExists(10000));
  }
}
