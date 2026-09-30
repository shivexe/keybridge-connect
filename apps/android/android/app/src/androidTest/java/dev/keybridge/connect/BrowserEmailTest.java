package dev.keybridge.connect;

import static org.junit.Assert.*;

import android.app.UiAutomation;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.*;
import org.junit.Test;

public final class BrowserEmailTest {
  @Test
  public void protonEmailFirstShortcut() throws Exception {
    Configurator.getInstance()
        .setUiAutomationFlags(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
    UiAutomation automation =
        InstrumentationRegistry.getInstrumentation()
            .getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
    UiDevice device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
    device.executeShellCommand("am start -n dev.keybridge.connect/.MainActivity");
    Thread.sleep(1000);
    device.executeShellCommand("settings delete secure enabled_accessibility_services");
    Thread.sleep(1000);
    device.executeShellCommand(
        "settings put secure enabled_accessibility_services"
            + " dev.keybridge.connect/dev.keybridge.connect.KeybridgeAccessibilityService");
    device.executeShellCommand(
        "settings put secure accessibility_button_targets"
            + " dev.keybridge.connect/dev.keybridge.connect.KeybridgeAccessibilityService");
    device.executeShellCommand("settings put secure accessibility_enabled 1");
    Thread.sleep(2000);
    device.executeShellCommand(
        "settings put secure accessibility_button_targets"
            + " dev.keybridge.connect/dev.keybridge.connect.KeybridgeAccessibilityService");
    Thread.sleep(1000);
    device.executeShellCommand(
        "am start -a android.intent.action.VIEW -d https://account.protonvpn.com/login -p"
            + " org.mozilla.firefox");
    UiObject username = device.findObject(new UiSelector().resourceId("username"));
    assertTrue("Proton email-only field", username.waitForExists(30000));
    username.click();
    Thread.sleep(1500);
    device.click(device.getDisplayWidth() - 60, 1280);
    UiObject auth = device.findObject(new UiSelector().text("Unlock Keybridge Connect"));
    if (auth.waitForExists(4000)) {
      UiObject usePin = device.findObject(new UiSelector().text("Use PIN"));
      if (usePin.waitForExists(2000)) usePin.click();
      UiObject input = device.findObject(new UiSelector().className("android.widget.EditText"));
      assertTrue(input.waitForExists(5000));
      input.click();
      device.executeShellCommand("input text 123456");
      device.pressEnter();
    }
    UiObject row = device.findObject(new UiSelector().textContains("FIXTURE 1"));
    assertTrue("Account picker", row.waitForExists(10000));
    row.click();
    UiObject fill = device.findObject(new UiSelector().text("Fill username"));
    assertTrue("Username-only confirmation", fill.waitForExists(5000));
    assertFalse(device.findObject(new UiSelector().text("Remember for this account")).exists());
    fill.click();
    UiObject pin = device.findObject(new UiSelector().text("Use PIN"));
    if (pin.waitForExists(4000)) {
      pin.click();
      UiObject input = device.findObject(new UiSelector().className("android.widget.EditText"));
      assertTrue(input.waitForExists(5000));
      assertTrue(input.waitForExists(5000));
      input.click();
      device.executeShellCommand("input text 123456");
      device.pressEnter();
    }
    assertTrue(username.waitForExists(10000));
    long deadline = System.currentTimeMillis() + 10000;
    while (!username.getText().equals("dummy0") && System.currentTimeMillis() < deadline)
      Thread.sleep(100);
    assertEquals("dummy0", username.getText());
    assertTrue(device.findObject(new UiSelector().text("Continue")).exists());
  }
}
