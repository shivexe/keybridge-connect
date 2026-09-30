package dev.keybridge.connect;

import static org.junit.Assert.*;

import org.junit.Test;

public final class UsernameShortcutTest {
  @Test
  public void emailFirstFieldNeverUsesPasswordValue() {
    assertEquals("username", KeybridgeAccessibilityService.fieldKind(false, 1, "username"));
    assertEquals("username", KeybridgeAccessibilityService.fieldKind(false, 0x21, "email"));
    assertEquals("password", KeybridgeAccessibilityService.fieldKind(true, 0x81, "password"));
    for (String id : new String[] {"search", "verification_code", "otp", "card", "message"})
      assertEquals("", KeybridgeAccessibilityService.fieldKind(false, 1, id));
    assertEquals("", KeybridgeAccessibilityService.fieldKind(false, 2, "username"));
    assertEquals("", KeybridgeAccessibilityService.fieldKind(false, 1, null));
  }
}
